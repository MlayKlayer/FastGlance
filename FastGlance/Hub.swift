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
    static let pinLabels = "pinLabels"          // [pin id: the user's own title]
    static let pinTitles = "pinTitles"          // [pin id: action title when pinned], shown while it can't run
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
    @Published private(set) var pinLabels = UserDefaults.standard.dictionary(forKey: Prefs.pinLabels) as? [String: String] ?? [:]
    private var pinTitles = UserDefaults.standard.dictionary(forKey: Prefs.pinTitles) as? [String: String] ?? [:]
    /// Bumped on every refresh so views re-read action titles and mic state.
    @Published private(set) var revision = 0

    let audio = AudioSource()
    let disks = DiskSource()
    let bluetooth: BluetoothSource
    let network = NetworkSource()
    let cameras = CameraSource()
    private let printers: PrinterSource
    private let sources: [DeviceSource]
    private var history = DeviceHistory.load()
    private var refreshQueued = false
    var onRefresh: ((_ old: [Device], _ new: [Device]) -> Void)?

    init() {
        bluetooth = BluetoothSource(audio: audio)
        let usb = USBSource()
        let printers = PrinterSource(usb: usb, network: network)
        self.printers = printers
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

    /// Slower sources freshen up when someone is about to look.
    func menuWillOpen() {
        bluetooth.refreshIfStale()
        printers.reloadIfStale()
        network.sweepIfDue(maxAge: 30)
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
        for i in all.indices {
            guard let e = history.entries[all[i].id] else { continue }
            if let nick = e.nickname {
                all[i].info.insert(InfoRow("System name", all[i].name), at: 0)
                all[i].name = nick
            }
            all[i].isHidden = e.hidden ?? false
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
        pins.filter { $0.hasPrefix(d.id + "|") }.forEach(removePin)
        refresh()
    }

    /// An empty name, or the system's own, goes back to the system name.
    func rename(_ d: Device, to name: String) {
        guard history.entries[d.id] != nil else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        history.entries[d.id]?.nickname = name.isEmpty || name == history.entries[d.id]?.name ? nil : name
        history.save()
        refresh()
    }

    func setHidden(_ d: Device, _ hidden: Bool) {
        guard history.entries[d.id] != nil else { return }
        history.entries[d.id]?.hidden = hidden ? true : nil
        history.save()
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
        if pins.contains(a.id) { return removePin(a.id) }
        pins.append(a.id)
        pinTitles[a.id] = a.title
        savePins()
    }

    func removePin(_ id: String) {
        pins.removeAll { $0 == id }
        pinLabels[id] = nil
        pinTitles[id] = nil
        savePins()
    }

    /// Reordering also moves the ⌃⌥N shortcuts, which follow the order.
    func movePins(from: IndexSet, to: Int) {
        pins.move(fromOffsets: from, toOffset: to)
        savePins()
    }

    func setPinLabel(_ id: String, _ label: String) {
        // Stored as typed (trimming per keystroke would eat the space before the next word).
        pinLabels[id] = label.allSatisfy(\.isWhitespace) ? nil : label
        savePins()
    }

    private func savePins() {
        let d = UserDefaults.standard
        d.set(pins, forKey: Prefs.pins)
        d.set(pinLabels, forKey: Prefs.pinLabels)
        d.set(pinTitles, forKey: Prefs.pinTitles)
    }

    struct Pin: Identifiable {
        let id: String
        /// Position in `pins`, which is what ⌃⌥N and option-click use, so a pin that can't run never shifts the others.
        let slot: Int
        let label: String?
        let defaultTitle: String
        let device: Device?
        /// nil while it can't run.
        let action: DeviceAction?

        var title: String { label ?? defaultTitle }
        var symbol: String { action?.symbol ?? "pin.slash" }
        var subtitle: String {
            guard action == nil else { return device?.name ?? "" }
            guard let device else { return "Device not found" }
            return "\(device.name) · \(device.isConnected ? "not available now" : "offline")"
        }
    }

    /// Every pin, including the ones that can't run right now.
    var pinList: [Pin] {
        pins.enumerated().map { slot, id in
            let device = devices.first { $0.id == id.split(separator: "|").first.map(String.init) }
            let action = device.flatMap { d in actions(for: d).first { $0.id == id } }
            return Pin(id: id, slot: slot, label: pinLabels[id], defaultTitle: action?.title ?? pinTitles[id] ?? "Action",
                       device: device, action: action)
        }
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
