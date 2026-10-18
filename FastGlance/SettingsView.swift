import SwiftUI
import ServiceManagement
import CoreBluetooth
import CoreLocation
import AVFoundation
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var hub: DeviceHub
    @AppStorage(Prefs.iconMode) private var iconMode = "lowest"
    @AppStorage(Prefs.iconDeviceID) private var iconDeviceID = ""
    @AppStorage(Prefs.notifyConnections) private var notifyConnections = true
    @AppStorage(Prefs.notifyBattery) private var notifyBattery = true
    @AppStorage(Prefs.batteryThreshold) private var threshold = 20
    @AppStorage(Prefs.hiddenKinds) private var hiddenRaw = ""
    @AppStorage(Prefs.mutedKinds) private var mutedRaw = ""
    @AppStorage(Prefs.networkScan) private var networkScan = true
    @AppStorage(Prefs.hotkeys) private var hotkeys = true
    @AppStorage(Prefs.unmountOnLidClose) private var unmountOnLidClose = true
    @AppStorage(Prefs.syncBrightness) private var syncBrightness = true
    @AppStorage(Prefs.networkScanInterval) private var scanInterval = 60.0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }

            Section {
                if hub.pinList.isEmpty {
                    Text("Pin actions from a device's ••• menu or its details.").foregroundStyle(.secondary)
                }
                ForEach(hub.pinList) { p in
                    HStack(spacing: 8) {
                        Text(p.slot < 9 ? "⌃⌥\(p.slot + 1)" : "").font(.caption.monospaced()).foregroundStyle(.tertiary).frame(width: 30)
                        Image(systemName: p.symbol).frame(width: 18).foregroundStyle(p.action == nil ? .secondary : .primary)
                        VStack(alignment: .leading, spacing: 1) {
                            TextField("Title", text: Binding(get: { p.label ?? "" }, set: { hub.setPinLabel(p.id, $0) }),
                                      prompt: Text(p.defaultTitle))
                                .textFieldStyle(.plain)
                            Text(p.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Button { hub.removePin(p.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Unpin")
                    }
                    .contextMenu {
                        Button("Move Up") { hub.movePins(from: [p.slot], to: p.slot - 1) }.disabled(p.slot == 0)
                        Button("Move Down") { hub.movePins(from: [p.slot], to: p.slot + 2) }.disabled(p.slot == hub.pins.count - 1)
                        Button("Unpin") { hub.removePin(p.id) }
                    }
                }
                .onMove(perform: hub.movePins)
            } header: {
                Text("Pinned actions")
            } footer: {
                Text("Drag to reorder (or right-click). Click a title to rename it; clear it to use the action's own.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Keyboard shortcuts", isOn: $hotkeys)
            } footer: {
                Text("⌃⌥1 … ⌃⌥9 run your pinned actions in order. ⌃⌥M mutes or unmutes the microphone. Works from any app.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Show next to icon", selection: $iconMode) {
                    Text("Nothing").tag("none")
                    Text("Lowest battery").tag("lowest")
                    Text("Battery of one device").tag("device")
                }
                if iconMode == "device" {
                    Picker("Device", selection: $iconDeviceID) {
                        Text("Choose…").tag("")
                        ForEach(hub.devices.filter { $0.id.hasPrefix("bt:") }) { Text($0.name).tag($0.id) }
                    }
                }
            } header: {
                Text("Menu bar icon")
            } footer: {
                Text("An orange dot means a battery is low, a red dot means the microphone is muted. Option-click the icon to run your first pinned action; right-click for this menu.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle("Device connected or disconnected", isOn: $notifyConnections)
                Toggle("Low battery", isOn: $notifyBattery)
                Stepper("Low battery at \(threshold)%", value: $threshold, in: 5...50, step: 5)
                DisclosureGroup("Notify for these types") {
                    KindToggles(raw: $mutedRaw)
                }
                .disabled(!notifyConnections)
            }

            Section {
                Toggle("Scan local network", isOn: $networkScan)
                Picker("Scan every", selection: $scanInterval) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                }
                .disabled(!networkScan)
            } header: {
                Text("Local network")
            } footer: {
                Text("Bonjour devices always show up. Scanning also finds devices that don't advertise themselves. Everything stays on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Unmount external disks when the lid closes", isOn: $unmountOnLidClose)
            } header: {
                Text("Disks")
            } footer: {
                Text("Before the Mac sleeps from closing the lid, disks are safely unmounted (never forced), so you can unplug them without a warning. If a disk is still connected when the Mac wakes, it mounts again. With an external display and the lid closed, the Mac stays awake and disks are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Match external displays to this Mac's brightness", isOn: $syncBrightness)
            } header: {
                Text("Displays")
            } footer: {
                Text("External monitors follow the built-in display, including automatic brightness. Fine-tune each monitor with its offset in the display's controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Devices") {
                DisclosureGroup("Show in menu") {
                    KindToggles(raw: $hiddenRaw)
                }
                Button("Clear Device History…", role: .destructive) { confirmClear = true }
                    .confirmationDialog("Clear history of all devices?", isPresented: $confirmClear) {
                        Button("Clear", role: .destructive) { hub.clearHistory() }
                    } message: {
                        Text("Devices that are not connected right now will disappear from FastGlance.")
                    }
            }

            AccessSection()

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 600)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// One toggle per device type; `raw` stores the types that are switched OFF.
struct KindToggles: View {
    @Binding var raw: String

    var body: some View {
        ForEach(DeviceKind.allCases) { kind in
            Toggle(isOn: Binding(
                get: { !off.contains(kind.rawValue) },
                set: { on in
                    var s = off
                    if on { s.remove(kind.rawValue) } else { s.insert(kind.rawValue) }
                    raw = s.sorted().joined(separator: ",")
                })) {
                Label(kind.title, systemImage: kind.symbol)
            }
        }
    }

    private var off: Set<String> { Set(raw.split(separator: ",").map(String.init)) }
}

/// What macOS lets FastGlance do, and where to change it.
struct AccessSection: View {
    @State private var notifications = UNAuthorizationStatus.notDetermined

    var body: some View {
        Section {
            let bt = CBManager.authorization
            AccessRow(title: "Bluetooth", purpose: "List, connect and read battery of Bluetooth devices",
                      state: bt == .allowedAlways ? .allowed : bt == .notDetermined ? .notAsked : .denied, pane: "Privacy_Bluetooth")
            let loc = CLLocationManager().authorizationStatus
            AccessRow(title: "Location", purpose: "Show the Wi-Fi network name (macOS ties it to location)",
                      state: [.authorizedAlways, .authorized].contains(loc) ? .allowed : loc == .notDetermined ? .notAsked : .denied,
                      pane: "Privacy_LocationServices")
            let cam = AVCaptureDevice.authorizationStatus(for: .video)
            AccessRow(title: "Camera", purpose: "Camera preview",
                      state: cam == .authorized ? .allowed : cam == .notDetermined ? .notAsked : .denied, pane: "Privacy_Camera")
            AccessRow(title: "Notifications", purpose: "Connection, battery and action alerts",
                      state: [.authorized, .provisional].contains(notifications) ? .allowed : notifications == .notDetermined ? .notAsked : .denied,
                      url: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
            AccessRow(title: "Display brightness", purpose: "Built-in and Apple displays (private macOS API)",
                      state: DisplayBrightness.isAvailable ? .available : .unavailable)
            AccessRow(title: "Monitor control (DDC)", purpose: "Brightness, volume and input of external monitors",
                      state: DDC.isAvailable ? .available : .unavailable)
        } header: {
            Text("Access")
        } footer: {
            Text("Everything else keeps working without these; only the matching features switch off.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await reload() }
        // Coming back from System Settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await reload() } }
    }

    private func reload() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

struct AccessRow: View {
    enum State { case allowed, denied, notAsked, available, unavailable }
    let title: String
    let purpose: String
    let state: State
    var pane: String? = nil
    var url: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(purpose).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .allowed: Text("Allowed").foregroundStyle(.secondary)
            case .available: Text("Available").foregroundStyle(.secondary)
            case .notAsked: Text("Not asked yet").foregroundStyle(.secondary)
            case .unavailable: Text("Unavailable on this macOS").foregroundStyle(.orange)
            case .denied:
                Button("Allow in Settings…") {
                    Util.open(url ?? "x-apple.systempreferences:com.apple.preference.security?\(pane ?? "")")
                }
            }
        }
    }
}
