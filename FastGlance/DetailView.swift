import SwiftUI

final class DetailSelection: ObservableObject {
    @Published var deviceID: String?
}

struct DetailView: View {
    @EnvironmentObject var hub: DeviceHub
    @EnvironmentObject var selection: DetailSelection
    @State private var filter = 0  // 0 all, 1 connected, 2 offline, 3 hidden
    @State private var query = ""

    private var listed: [Device] {
        hub.devices.filter {
            (filter == 3 ? $0.isHidden : filter == 0 || (filter == 1) == $0.isConnected) && Search.matches($0, Search.words(query))
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection.deviceID) {
                ForEach(DeviceKind.grouped(listed), id: \.kind) { kind, devices in
                    Section(kind.title) {
                        ForEach(devices) { d in
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(d.name).lineLimit(1)
                                    Text(d.isConnected ? "Connected" : Util.ago(d.lastConnected)).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: d.icon).foregroundStyle(d.isConnected ? Color.accentColor : .secondary)
                            }
                            .tag(d.id)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .sidebar)
            .safeAreaInset(edge: .top) {
                Picker("", selection: $filter) {
                    Text("All").tag(0)
                    Text("Connected").tag(1)
                    Text("Offline").tag(2)
                    Text("Hidden").tag(3)
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.top, 4)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            if let id = selection.deviceID, let d = hub.devices.first(where: { $0.id == id }) {
                DeviceCard(device: d).id(d.id)
            } else {
                ContentUnavailableView("Select a device", systemImage: "rectangle.connected.to.line.below",
                                       description: Text("Every device that was ever connected to this Mac is listed here."))
            }
        }
    }
}

struct DeviceCard: View {
    @EnvironmentObject var hub: DeviceHub
    let device: Device
    @AppStorage(Prefs.batteryThreshold) private var threshold = 20
    @State private var confirmForget = false
    @State private var name = ""

    var body: some View {
        let actions = hub.actions(for: device)
        let controls = hub.controls(for: device)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let warning = device.warning {
                    Label {
                        Text(warning).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                }

                if !device.batteries.isEmpty {
                    GroupBox("Battery") {
                        HStack(spacing: 24) {
                            ForEach(device.batteries, id: \.self) { b in
                                Gauge(value: Double(b.percent), in: 0...100) {
                                    Text(b.label.isEmpty ? "Battery" : b.label)
                                } currentValueLabel: {
                                    Text("\(b.percent)%")
                                }
                                .gaugeStyle(.accessoryCircularCapacity)
                                .tint(b.percent <= threshold ? .orange : .green)
                            }
                            Spacer()
                        }
                        .padding(6)
                    }
                }

                if let used = hub.disks.usage(device) {
                    GroupBox("Capacity") {
                        ProgressView(value: used) { Text(device.status ?? "") }.padding(6)
                    }
                }

                if !controls.isEmpty {
                    GroupBox("Controls") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(controls) { ControlView(control: $0) }
                        }
                        .padding(6)
                    }
                }

                if !actions.isEmpty {
                    GroupBox("Actions") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(actions) { a in
                                HStack(spacing: 4) {
                                    Button(action: a.run) {
                                        Label(a.title, systemImage: a.symbol).frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    Button { hub.togglePin(a) } label: {
                                        Image(systemName: hub.isPinned(a) ? "pin.fill" : "pin")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(hub.isPinned(a) ? "Unpin from menu" : "Pin to menu")
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox("Information") {
                    InfoGrid(rows: [InfoRow("Category", device.kind.title),
                                    InfoRow("Last connected", device.isConnected ? "Now" : (device.lastConnected?.formatted(date: .abbreviated, time: .shortened) ?? "Unknown"))]
                             + device.info)
                        .padding(6)
                }

                if !device.raw.isEmpty {
                    GroupBox {
                        DisclosureGroup("Raw properties (\(device.raw.count))") {
                            InfoGrid(rows: device.raw).padding(.top, 6)
                            Button("Copy All") {
                                Util.copy(device.raw.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                            }
                            .padding(.top, 4)
                        }
                        .padding(6)
                    }
                }

                if !device.isConnected && hub.isKnownToSystem(device) {
                    Text(device.kind == .printer
                         ? "To remove this printer, delete it in Printers & Scanners."
                         : "macOS still has this device paired. To remove it, unpair it in Bluetooth Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else if !device.isConnected {
                    HStack {
                        Spacer()
                        Button("Forget Device…", role: .destructive) { confirmForget = true }
                    }
                    .confirmationDialog("Forget \(device.name)?", isPresented: $confirmForget) {
                        Button("Forget", role: .destructive) { hub.forget(device) }
                    } message: {
                        Text("It is removed from FastGlance's history. Bluetooth pairing is not affected.")
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image(systemName: device.icon)
                .font(.system(size: 30))
                .frame(width: 64, height: 64)
                .foregroundStyle(device.isConnected ? Color.accentColor : .secondary)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $name)
                    .font(.title2.bold()).textFieldStyle(.plain)
                    .onSubmit { hub.rename(device, to: name) }
                    .onAppear { name = device.name }
                    .onChange(of: device.name) { name = device.name }
                    .help("Rename: type and press Return. Clear the name to go back to the system's.")
                HStack(spacing: 6) {
                    Circle().fill(device.isConnected ? .green : .secondary.opacity(0.5)).frame(width: 8, height: 8)
                    Text(device.isConnected ? (device.status ?? "Connected") : Util.ago(device.lastConnected))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Show in menu", isOn: Binding(get: { !device.isHidden }, set: { hub.setHidden(device, !$0) }))
                .toggleStyle(.switch).controlSize(.small)
        }
    }
}

struct InfoGrid: View {
    let rows: [InfoRow]
    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows, id: \.self) { r in
                GridRow {
                    Text(r.key).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(r.value).textSelection(.enabled).lineLimit(3)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
