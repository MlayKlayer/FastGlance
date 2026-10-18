import Foundation

enum Prefs {
    static let iconMode = "iconMode"            // "none" | "lowest" | "device"
    static let iconDeviceID = "iconDeviceID"
    static let notifyConnections = "notifyConnections"
    static let notifyBattery = "notifyBattery"
    static let batteryThreshold = "batteryThreshold"
    static let hiddenKinds = "hiddenKinds"      // comma-separated DeviceKind raw values
    static let mutedKinds = "notifyMutedKinds"
    static let pins = "pins"                    // [String] of DeviceAction ids
    static let networkScan = "networkScan"
    static let networkScanInterval = "networkScanInterval"  // seconds
    static let hotkeys = "hotkeys"
    static let unmountOnLidClose = "unmountOnLidClose"
    static let syncBrightness = "syncBrightness"

    static func register() {
        UserDefaults.standard.register(defaults: [
            iconMode: "lowest", notifyConnections: true, notifyBattery: true, batteryThreshold: 20,
            mutedKinds: "camera,computer,internet,media,network,phone,router,smartHome,watch", hiddenKinds: "",
            networkScan: true, networkScanInterval: 60.0, hotkeys: true, unmountOnLidClose: true, syncBrightness: true,
        ])
    }

    static func kinds(_ key: String) -> Set<DeviceKind> {
        Set((UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").compactMap { DeviceKind(rawValue: String($0)) })
    }
}

/// Merges every source with the remembered history and owns pins.
@MainActor final class DeviceHub: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published private(set) var pins: [String] = UserDefaults.standard.stringArray(forKey: Prefs.pins) ?? []
    /// Bumped on every refresh so views re-read action titles and mic state.
    @Published private(set) var revision = 0

    let audio = AudioSource()
    let disks = DiskSource()
    let bluetooth: BluetoothSource
    let network = NetworkSource()
    let cameras = CameraSource()
    private let sources: [DeviceSource]
    private var history = DeviceHistory.load()
    private var refreshQueued = false
    var onRefresh: ((_ old: [Device], _ new: [Device]) -> Void)?

    init() {
        bluetooth = BluetoothSource(audio: audio)
        let usb = USBSource()
        let printers = PrinterSource(usb: usb, network: network)
        usb.claimedSerials = { [weak printers] in printers?.usbSerials ?? [] }
        network.claimedServiceNames = { [weak printers] in printers?.dnssdNames ?? [] }
        sources = [InternetSource(), bluetooth, audio, usb, disks, DisplaySource(), cameras, printers, network]
    }

    func start() {
        for s in sources {
            s.onChange = { [weak self] in self?.queueRefresh() }
            s.start()
        }
        refresh()
    }

    private func queueRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshQueued = false
            self?.refresh()
        }
    }

    func refresh() {
        let live = sources.flatMap(\.devices)
        let now = Date()
        let structural = history.record(live, now: now)
        let wasConnected = Set(devices.filter(\.isConnected).map(\.id))
        history.markDisconnected(wasConnected.subtracting(live.filter(\.isConnected).map(\.id)), now: now)
        let liveIDs = Set(live.map(\.id))
        var all = live.map { d -> Device in
            var d = d
            d.lastConnected = history.entries[d.id]?.lastConnected
            return d
        }
        all += history.entries.values.filter { !liveIDs.contains($0.id) }.map {
            Device(id: $0.id, name: $0.name, kind: $0.kind, isConnected: false, lastConnected: $0.lastConnected)
        }
        all.sort { ($0.kind.order, $0.name.localizedLowercase) < ($1.kind.order, $1.name.localizedLowercase) }

        let old = devices
        let connectionsChanged = Set(old.filter(\.isConnected).map(\.id)) != Set(all.filter(\.isConnected).map(\.id))
        if structural || connectionsChanged { history.save() }
        if all != devices { devices = all }
        revision &+= 1
        onRefresh?(old, all)
    }

    func saveHistory() {
        history.record(sources.flatMap(\.devices).filter(\.isConnected), now: Date())
        history.save()
    }

    func source(for d: Device) -> DeviceSource? {
        sources.first { d.id.hasPrefix($0.prefix + ":") }
    }

    func actions(for d: Device) -> [DeviceAction] {
        (source(for: d)?.actions(for: d) ?? []).map { a in
            // Every action refreshes afterwards so titles like Mute/Unmute stay current.
            DeviceAction(id: a.id, title: a.title, symbol: a.symbol) { [weak self] in
                a.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
            }
        }
    }

    func controls(for d: Device) -> [DeviceControl] {
        source(for: d)?.controls(for: d) ?? []
    }

    /// Offline but still reported by a source (a paired Bluetooth device, an installed printer): forgetting it here can't stick.
    func isKnownToSystem(_ d: Device) -> Bool {
        source(for: d)?.devices.contains { $0.id == d.id } ?? false
    }

    func forget(_ d: Device) {
        history.entries[d.id] = nil
        history.save()
        pins.removeAll { $0.hasPrefix(d.id + "|") }
        savePins()
        refresh()
    }

    func clearHistory() {
        history = DeviceHistory()
        history.save()
        refresh()
    }

    // MARK: - Pins

    func isPinned(_ a: DeviceAction) -> Bool { pins.contains(a.id) }

    func togglePin(_ a: DeviceAction) {
        if let i = pins.firstIndex(of: a.id) { pins.remove(at: i) } else { pins.append(a.id) }
        savePins()
    }

    private func savePins() { UserDefaults.standard.set(pins, forKey: Prefs.pins) }

    /// Pins that can run right now. `slot` is the pin's position in `pins`, which is what ⌃⌥N and option-click use,
    /// so a pin that can't run at the moment never shifts the others onto the wrong shortcut.
    var pinnedActions: [(slot: Int, device: Device, action: DeviceAction)] {
        pins.indices.compactMap { slot in pinnedAction(slot: slot).map { (slot, $0.device, $0.action) } }
    }

    func pinnedAction(slot: Int) -> (device: Device, action: DeviceAction)? {
        Self.resolve(pin: pins.indices.contains(slot) ? pins[slot] : nil, devices: devices, actions: actions(for:))
    }

    static func resolve(pin: String?, devices: [Device], actions: (Device) -> [DeviceAction]) -> (device: Device, action: DeviceAction)? {
        guard let pin, let deviceID = pin.split(separator: "|").first.map(String.init),
              let device = devices.first(where: { $0.id == deviceID }),
              let action = actions(device).first(where: { $0.id == pin }) else { return nil }
        return (device, action)
    }
}
