import IOBluetooth
import AppKit

@MainActor final class BluetoothSource: NSObject, DeviceSource {
    let prefix = "bt"
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []

    private let audio: AudioSource
    /// From `system_profiler`, keyed by lowercased dash-separated address.
    private var batteries: [String: [Battery]] = [:]
    private var extraInfo: [String: [InfoRow]] = [:]
    private var playHerePending: Set<String> = []
    private var timers: [Timer] = []
    private var connectNote: IOBluetoothUserNotification?

    init(audio: AudioSource) {
        self.audio = audio
    }

    func start() {
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(didConnect(_:device:)))
        // Polling catches state the notifications miss (renames, devices paired elsewhere).
        timers.append(.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.reload() } })
        timers.append(.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            // system_profiler is not free; only poll while something can report a battery.
            if self?.devices.contains(where: \.isConnected) == true { self?.refreshProfiler() }
        } })
        Gamepads.start { [weak self] in self?.reload() }
        reload()
        refreshProfiler()
    }

    @objc private func didConnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(didDisconnect(_:device:)))
        reload()
        // Battery levels show up a few seconds after the link comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in self?.refreshProfiler() }
    }

    @objc private func didDisconnect(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        reload()
    }

    func reload() {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let next = paired.compactMap { d -> Device? in
            guard let addr = d.addressString?.lowercased() else { return nil }
            let connected = d.isConnected()
            var dev = Device(id: "bt:\(addr)", name: d.name ?? addr.uppercased(), kind: Self.kind(d), isConnected: connected)
            if connected {
                dev.batteries = batteries[addr] ?? []
                if dev.batteries.isEmpty, dev.kind == .gamepad, let pad = Gamepads.controller(named: dev.name) {
                    dev.batteries = Gamepads.battery(pad)  // system_profiler doesn't report DualSense/Xbox battery
                }
                let isOutput = audio.outputs(forBluetoothAddress: addr).contains { $0.id == audio.defaultOutput }
                dev.status = isOutput ? "Connected · Playing here" : "Connected"
            }
            dev.info = [InfoRow("Address", addr.replacingOccurrences(of: "-", with: ":").uppercased()),
                        InfoRow("Class", String(format: "0x%06X", d.classOfDevice))]
                + (extraInfo[addr] ?? [])
            dev.raw = [InfoRow("Major class", "\(d.deviceClassMajor)"), InfoRow("Minor class", "\(d.deviceClassMinor)"),
                       InfoRow("Last inquiry", d.recentAccessDate().map { "\($0)" } ?? "—")]
            return dev
        }
        if next != devices { devices = next; onChange?() }
    }

    /// `system_profiler` is the one public place that reports AirPods L/R/case and HID battery levels.
    private func refreshProfiler() {
        Util.run("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"]) { [weak self] data in
            guard let self else { return }
            let parsed = Self.parseProfiler(data)
            batteries = parsed.batteries
            extraInfo = parsed.info
            reload()
        }
    }

    nonisolated static func parseProfiler(_ data: Data) -> (batteries: [String: [Battery]], info: [String: [InfoRow]]) {
        var batteries: [String: [Battery]] = [:]
        var info: [String: [InfoRow]] = [:]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return ([:], [:]) }
        let labels = [("device_batteryLevelMain", ""), ("device_batteryLevel", ""), ("device_batteryLevelLeft", "L"),
                      ("device_batteryLevelRight", "R"), ("device_batteryLevelCase", "Case")]
        let infoKeys = [("device_vendorID", "Vendor ID"), ("device_productID", "Product ID"), ("device_firmwareVersion", "Firmware"),
                        ("device_serialNumber", "Serial"), ("device_minorType", "Type"), ("device_rssi", "Signal (RSSI)")]
        for controller in controllers {
            for group in ["device_connected", "device_not_connected"] {
                for entry in controller[group] as? [[String: Any]] ?? [] {
                    for (_, value) in entry {
                        guard let props = value as? [String: Any],
                              let address = props["device_address"] as? String else { continue }
                        let addr = address.lowercased().replacingOccurrences(of: ":", with: "-")
                        batteries[addr] = labels.compactMap { key, label in
                            (props[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) }.map { Battery(label: label, percent: $0) }
                        }
                        info[addr] = infoKeys.compactMap { key, title in (props[key] as? String).map { InfoRow(title, $0) } }
                    }
                }
            }
        }
        return (batteries, info)
    }

    static func kind(_ d: IOBluetoothDevice) -> DeviceKind {
        // Apple devices often report a generic class; their names are reliable.
        let name = d.name ?? ""
        if name.contains("iPhone") || name.contains("iPad") { return .phone }
        if name.contains("Apple Watch") { return .watch }
        let minor = Int(d.deviceClassMinor)
        switch Int(d.deviceClassMajor) {
        case 0x04: // audio/video
            return [0x05, 0x07, 0x0A].contains(minor) ? .speaker : .headphones
        case 0x05: // peripheral
            if minor & 0x0F == 0x01 || minor & 0x0F == 0x02 { return .gamepad }
            if minor & 0x10 != 0 { return .keyboard }
            if minor & 0x20 != 0 { return (d.name ?? "").localizedCaseInsensitiveContains("trackpad") ? .trackpad : .mouse }
            return .bluetooth
        case 0x02: return .phone
        case 0x01: return .computer
        case 0x07: return .watch
        default: return .bluetooth
        }
    }

    // MARK: - Actions

    private func address(_ device: Device) -> String { String(device.id.dropFirst(3)) }

    func actions(for device: Device) -> [DeviceAction] {
        let addr = address(device)
        let isAudio = device.kind == .headphones || device.kind == .speaker
        // Pinnable actions keep the same id in every state (titles flip instead), so a pin never goes missing.
        var out: [DeviceAction] = []
        let output = audio.outputs(forBluetoothAddress: addr).first
        if isAudio {
            let playHere = DeviceAction(device, "playhere", "Play Here", "play.circle") { [weak self] in
                self?.playHerePending.insert(addr)
                self?.connect(addr)  // already connected: just routes audio
            }
            let playingHere = device.isConnected && output?.id == audio.defaultOutput
            if !playingHere { out.append(playHere) }
            if let output, device.isConnected {
                out += audio.actions(for: output, device: device).filter { !$0.id.hasSuffix("|output") }  // Play Here covers it
            }
            if playingHere { out.append(playHere) }
        }
        if device.isConnected, device.kind == .gamepad, let pad = Gamepads.controller(named: device.name) {
            out.append(DeviceAction(device, "vibrate", "Test Vibration", "waveform") { Gamepads.vibrate(pad) })
        }
        let connected = device.isConnected
        out.append(DeviceAction(device, "connection", connected ? "Disconnect" : "Connect", connected ? "xmark.circle" : "link") { [weak self] in
            if connected {
                IOBluetoothDevice(addressString: addr)?.closeConnection()
                self?.reload()
            } else {
                self?.connect(addr)
            }
        })
        out.append(DeviceAction(device, "settings", "Bluetooth Settings…", "gearshape") {
            Util.open("x-apple.systempreferences:com.apple.BluetoothSettings")
        })
        return out
    }

    func controls(for device: Device) -> [DeviceControl] {
        if device.isConnected, device.kind == .gamepad, let pad = Gamepads.controller(named: device.name) {
            return Gamepads.controls(pad, deviceID: device.id)
        }
        guard device.isConnected, let a = audio.outputs(forBluetoothAddress: address(device)).first else { return [] }
        return audio.controls(for: a)
    }

    private func connect(_ addr: String) {
        guard let d = IOBluetoothDevice(addressString: addr) else { return }
        if d.isConnected() {
            connectionComplete(d, status: kIOReturnSuccess)
        } else if d.openConnection(self) != kIOReturnSuccess {
            playHerePending.remove(addr)
            Notifier.shared.post("Couldn't connect", d.name ?? addr)
        }
    }

    /// IOBluetoothDevice async-connect delegate callback.
    @objc func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        guard let addr = device.addressString?.lowercased() else { return }
        reload()
        guard status == kIOReturnSuccess else {
            playHerePending.remove(addr)
            Notifier.shared.post("Couldn't connect", device.name ?? addr)
            return
        }
        if playHerePending.contains(addr) { routeAudio(addr, tries: 20) }
    }

    /// The CoreAudio device appears a moment after the Bluetooth link.
    private func routeAudio(_ addr: String, tries: Int) {
        if let out = audio.outputs(forBluetoothAddress: addr).first {
            playHerePending.remove(addr)
            audio.setDefault(output: out.id)
        } else if tries > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.routeAudio(addr, tries: tries - 1) }
        } else {
            playHerePending.remove(addr)
        }
    }
}
