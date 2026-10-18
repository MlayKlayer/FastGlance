import SwiftUI

struct MenuView: View {
    @EnvironmentObject var hub: DeviceHub
    let openDetail: (String?) -> Void
    let openSettings: () -> Void

    @State private var query = ""
    @State private var expanded: String?
    @State private var selected = 0
    @AppStorage("showOffline") private var showOffline = false
    @AppStorage(Prefs.hiddenKinds) private var hiddenRaw = ""
    @AppStorage(Prefs.hotkeys) private var hotkeys = true

    private var shown: [Device] {
        let hidden = Set(hiddenRaw.split(separator: ",").map(String.init))
        return hub.devices.filter { !$0.isHidden && !hidden.contains($0.kind.rawValue) }
    }

    private var visible: [Device] {
        let words = Search.words(query)
        return shown.filter { Search.matches($0, words) }
    }

    private var results: [(device: Device, action: DeviceAction)] {
        let words = Search.words(query)
        guard !words.isEmpty else { return [] }
        return Array(Search.actions(words, in: shown.map { ($0, hub.actions(for: $0)) }).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            TextField("Search devices and actions", text: $query)
                .textFieldStyle(.roundedBorder)
                .onChange(of: query) { selected = 0 }
                .onSubmit {
                    let r = results
                    if r.indices.contains(selected) { r[selected].action.run() }
                }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.escape) {
                    guard !query.isEmpty else { return .ignored }  // empty field: let the popover close
                    query = ""
                    return .handled
                }
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }.scrollIndicators(.automatic)
            }
            .frame(maxHeight: 540)
        }
        .padding(12)
        .frame(width: 370)
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let n = results.count
        guard n > 0 else { return .ignored }
        selected = (selected + step + n) % n
        return .handled
    }

    private var header: some View {
        HStack(spacing: 2) {
            Text("FastGlance").font(.headline)
            Spacer()
            let muted = hub.audio.isMicMuted
            IconButton(symbol: muted ? "mic.slash.fill" : "mic", help: muted ? "Unmute microphone" : "Mute microphone everywhere",
                       tint: muted ? .red : nil) { hub.audio.toggleMic() }
            if hub.disks.hasEjectable {
                IconButton(symbol: "eject", help: "Eject all disks") { hub.disks.ejectAll() }
            }
            IconButton(symbol: "macwindow", help: "Open device window") { openDetail(nil) }
            IconButton(symbol: "gearshape", help: "Settings") { openSettings() }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            let pinned = hub.pinList
            if !pinned.isEmpty && query.isEmpty {
                SectionTitle("Pinned")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 6)], spacing: 6) {
                    ForEach(pinned) { p in
                        PinChip(title: p.title, subtitle: p.subtitle, symbol: p.symbol, run: p.action?.run,
                                shortcut: hotkeys && p.slot < 9 ? "⌃⌥\(p.slot + 1)" : nil)
                    }
                }
            }

            let found = results
            if !found.isEmpty {
                SectionTitle("Actions")
                ForEach(Array(found.enumerated()), id: \.element.action.id) { i, item in
                    PinChip(title: item.action.title, subtitle: item.device.name, symbol: item.action.symbol, run: item.action.run,
                            shortcut: i == selected ? "↩" : nil, highlighted: i == selected)
                }
            }

            let online = visible.filter(\.isConnected)
            if online.isEmpty && found.isEmpty {
                Text(query.isEmpty ? "No devices connected" : "No matches").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(DeviceKind.grouped(online), id: \.kind) { kind, devices in
                SectionTitle(kind.title)
                ForEach(devices) { DeviceRow(device: $0, expanded: $expanded, openDetail: openDetail) }
            }

            let offline = visible.filter { !$0.isConnected }
            if !offline.isEmpty {
                Divider()
                Button {
                    withAnimation(.snappy) { showOffline.toggle() }
                } label: {
                    HStack {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(showOffline || !query.isEmpty ? 90 : 0))
                        Text("Recently Seen (\(offline.count))")
                        Spacer()
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showOffline || !query.isEmpty {
                    ForEach(offline.sorted { ($0.lastConnected ?? .distantPast) > ($1.lastConnected ?? .distantPast) }) {
                        DeviceRow(device: $0, expanded: $expanded, openDetail: openDetail)
                    }
                }
            }
        }
    }
}

/// Every word of the query has to appear somewhere: "eject ssd", "192.168.1", "headphones".
enum Search {
    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Name, category and details (addresses, serials).
    static func text(_ d: Device) -> String {
        ([d.name, d.kind.title] + d.info.map(\.value)).joined(separator: " ").lowercased()
    }

    static func matches(_ d: Device, _ words: [String]) -> Bool {
        let t = text(d)
        return words.allSatisfy(t.contains)
    }

    /// Actions whose title has at least one of the words, with the rest found in the title or the device.
    /// Titles where a word starts a title word come first: "connect" ranks Connect above Disconnect.
    static func actions(_ words: [String], in items: [(Device, [DeviceAction])]) -> [(device: Device, action: DeviceAction)] {
        var strong: [(device: Device, action: DeviceAction)] = [], weak = strong
        for (d, actions) in items {
            let dt = text(d)
            for a in actions {
                let title = a.title.lowercased()
                guard words.contains(where: title.contains), words.allSatisfy({ title.contains($0) || dt.contains($0) }) else { continue }
                let titleWords = title.split { !$0.isLetter && !$0.isNumber }
                if words.contains(where: { w in titleWords.contains { $0.hasPrefix(w) } }) { strong.append((d, a)) } else { weak.append((d, a)) }
            }
        }
        return strong + weak
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 22).foregroundStyle(tint ?? .primary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

struct PinChip: View {
    let title: String
    let subtitle: String
    let symbol: String
    /// nil: shown dimmed, can't run right now.
    let run: (() -> Void)?
    var shortcut: String? = nil
    var highlighted = false
    var body: some View {
        Button { run?() } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).frame(width: 16)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.caption.weight(.medium)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let shortcut { Text(shortcut).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(highlighted ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary.opacity(0.6)),
                        in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(run == nil)
        .opacity(run == nil ? 0.5 : 1)
        .help(subtitle)
    }
}

struct BatteryText: View {
    let batteries: [Battery]
    @AppStorage(Prefs.batteryThreshold) private var threshold = 20
    var body: some View {
        HStack(spacing: 6) {
            ForEach(batteries, id: \.self) { b in
                HStack(spacing: 2) {
                    if !b.label.isEmpty { Text(b.label).foregroundStyle(.secondary) }
                    Text("\(b.percent)%").foregroundStyle(b.percent <= threshold ? .orange : .primary)
                }
            }
        }
        .font(.caption.monospacedDigit())
    }
}

struct DeviceRow: View {
    @EnvironmentObject var hub: DeviceHub
    let device: Device
    @Binding var expanded: String?
    let openDetail: (String?) -> Void
    @State private var hover = false
    @ObservedObject private var notifier = Notifier.shared

    private var subtitle: String {
        device.isConnected ? (device.status ?? "Connected") : Util.ago(device.lastConnected)
    }

    var body: some View {
        let actions = hub.actions(for: device)
        let isOpen = expanded == device.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: device.icon)
                    .frame(width: 22)
                    .foregroundStyle(device.isConnected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).lineLimit(1)
                    if let status = notifier.statuses[device.id] {
                        HStack(spacing: 6) {
                            Text(status.text).foregroundStyle(status.failed ? .red : .secondary).lineLimit(1).help(status.text)
                            if let retry = status.retry { Button("Retry", action: retry).buttonStyle(.link) }
                        }
                        .font(.caption)
                    } else {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let warning = device.warning {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(warning)
                }
                if !device.batteries.isEmpty { BatteryText(batteries: device.batteries) }
                if let primary = actions.first {
                    Button(action: primary.run) { Image(systemName: primary.symbol).frame(width: 22, height: 22) }
                        .buttonStyle(.borderless)
                        .help(primary.title)
                }
                ActionMenu(device: device, actions: actions, openDetail: openDetail)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy) { expanded = isOpen ? nil : device.id } }

            if isOpen {
                ExpandedRow(device: device, actions: actions, openDetail: openDetail)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .background(hover || isOpen ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 8))
        .onHover { hover = $0 }
    }
}

struct ActionMenu: View {
    @EnvironmentObject var hub: DeviceHub
    let device: Device
    let actions: [DeviceAction]
    let openDetail: (String?) -> Void

    var body: some View {
        Menu {
            ForEach(actions) { a in
                Button(action: a.run) { Label(a.title, systemImage: a.symbol) }
            }
            if !actions.isEmpty {
                Divider()
                Menu("Pin to Menu") {
                    ForEach(actions) { a in
                        Button { hub.togglePin(a) } label: {
                            Label(a.title, systemImage: hub.isPinned(a) ? "checkmark" : a.symbol)
                        }
                    }
                }
            }
            Button("Rename…") { openDetail(device.id) }
            Button("Hide from Menu") { hub.setHidden(device, true) }
            Button("Copy Name") { Util.copy(device.name) }
            Divider()
            Button("Details…") { openDetail(device.id) }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct ExpandedRow: View {
    @EnvironmentObject var hub: DeviceHub
    let device: Device
    let actions: [DeviceAction]
    let openDetail: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = device.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let used = hub.disks.usage(device) {
                ProgressView(value: used).tint(used > 0.9 ? .orange : .accentColor)
            }
            ForEach(hub.controls(for: device)) { ControlView(control: $0) }
            FlowButtons(actions: Array(actions.dropFirst()))
            Button("Details…") { openDetail(device.id) }
                .buttonStyle(.link).font(.caption)
        }
        .padding(.leading, 32)
    }
}

struct FlowButtons: View {
    let actions: [DeviceAction]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(actions) { a in
                Button(action: a.run) {
                    Label(a.title, systemImage: a.symbol).font(.caption).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .controlSize(.small)
            }
        }
    }
}

struct ControlView: View {
    let control: DeviceControl
    @State private var value = 0.0
    @State private var index = 0
    @State private var on = false
    @State private var dragging = false
    /// Re-reads the hardware while visible, so changes made elsewhere (keyboard, other apps) show up.
    private static let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch control.kind {
            case let .slider(_, set):
                HStack(spacing: 8) {
                    Image(systemName: control.symbol).frame(width: 18).foregroundStyle(.secondary).help(control.title)
                    Slider(value: Binding(get: { value }, set: { value = $0; set($0) }), in: 0...1) { dragging = $0 }
                        .controlSize(.small)
                    Text("\(Int(value * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                }
            case let .toggle(_, set):
                Toggle(isOn: Binding(get: { on }, set: { on = $0; set($0) })) { Label(control.title, systemImage: control.symbol) }
            case let .picker(options, _, set):
                Picker(selection: Binding(get: { index }, set: { index = $0; set($0) })) {
                    ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
                } label: {
                    Label(control.title, systemImage: control.symbol).font(.caption)
                }
                .controlSize(.small)
            }
        }
        .onAppear(perform: read)
        .onReceive(Self.tick) { _ in read() }
    }

    private func read() {
        switch control.kind {
        case let .slider(get, _): if !dragging { value = get() }
        case let .toggle(get, _): on = get()
        case let .picker(_, get, _): index = get()
        }
    }
}
