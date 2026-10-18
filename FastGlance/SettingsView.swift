import SwiftUI
import ServiceManagement

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
