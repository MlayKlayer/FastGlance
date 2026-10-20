import SwiftUI
import Charts
import CoreWLAN
import Darwin

/// Parsers and system reads shared by the network tools. Pure where possible, so they can be tested.
enum NetTools {
    enum PingSample: Equatable {
        case reply(Double)
        case lost
    }

    /// One line of `ping` output: "64 bytes from …: icmp_seq=0 ttl=64 time=4.567 ms" or "Request timeout for icmp_seq 3".
    static func pingSample(_ line: String) -> PingSample? {
        if line.hasPrefix("Request timeout") { return .lost }
        guard line.contains("bytes from"), let r = line.range(of: "time=") else { return nil }
        let rest = line[r.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(rest).map(PingSample.reply)
    }

    struct PingStats: Equatable {
        let average: Double?
        let jitter: Double?
        let loss: Double  // 0...1
        let minimum: Double?
        let maximum: Double?
    }

    /// Jitter is the mean difference between consecutive replies (RFC 3550's idea, without the smoothing).
    static func stats(_ samples: [PingSample]) -> PingStats {
        let times = samples.compactMap { if case let .reply(t) = $0 { t } else { nil } }
        let diffs = zip(times, times.dropFirst()).map { abs($1 - $0) }
        return PingStats(average: times.isEmpty ? nil : times.reduce(0, +) / Double(times.count),
                         jitter: diffs.isEmpty ? nil : diffs.reduce(0, +) / Double(diffs.count),
                         loss: samples.isEmpty ? 0 : Double(samples.count - times.count) / Double(samples.count),
                         minimum: times.min(), maximum: times.max())
    }

    /// The default resolver's servers and search domains from `scutil --dns` (resolver #1, before the scoped ones).
    static func dns(_ text: String) -> (servers: [String], domains: [String]) {
        var servers: [String] = []
        var domains: [String] = []
        var inFirst = false
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") {
                if inFirst { break }
                inFirst = line == "resolver #1"
                continue
            }
            if line.hasPrefix("DNS configuration (for scoped") { break }
            guard inFirst, let colon = line.range(of: " : ") else { continue }
            let value = String(line[colon.upperBound...])
            if line.hasPrefix("nameserver[") { servers.append(value) }
            if line.hasPrefix("search domain[") { domains.append(value) }
        }
        return (servers, domains)
    }

    /// ";; Query time: 23 msec" from dig.
    static func digQueryTime(_ text: String) -> Int? {
        guard let line = text.split(separator: "\n").first(where: { $0.contains("Query time:") }) else { return nil }
        return line.split(separator: " ").compactMap { Int($0) }.first
    }

    struct Share: Equatable, Identifiable {
        let name: String
        let type: String
        let comment: String
        var id: String { name }
    }

    /// `smbutil view` table rows between the dashed rule and "N shares listed". Names may contain spaces; the type column anchors.
    static func smbShares(_ text: String) -> [Share] {
        var out: [Share] = []
        var inTable = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("---") { inTable = true; continue }
            guard inTable, !line.contains("shares listed"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let parts = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let typeIndex = parts.firstIndex(where: { ["Disk", "Pipe", "Printer", "Device"].contains($0) }), typeIndex > 0 else { continue }
            out.append(Share(name: parts[..<typeIndex].joined(separator: " "), type: parts[typeIndex],
                             comment: parts[(typeIndex + 1)...].joined(separator: " ")))
        }
        return out
    }

    /// How many visible networks share each channel. A rough sign of crowding, not measured airtime.
    static func channelCounts(_ channels: [(number: Int, band: String)]) -> [String: Int] {
        channels.reduce(into: [:]) { $0["\($1.band)/\($1.number)", default: 0] += 1 }
    }

    /// Addresses, MAC and MTU of one interface, from getifaddrs.
    static func interfaceRows(_ iface: String) -> [InfoRow] {
        var v4: [String] = [], v6: [String] = []
        var mac: String?
        var mtu: UInt32?
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var cur = list
        while let ifa = cur?.pointee {
            defer { cur = ifa.ifa_next }
            guard String(cString: ifa.ifa_name) == iface, let addr = ifa.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            switch Int32(addr.pointee.sa_family) {
            case AF_INET, AF_INET6:
                let len = socklen_t(addr.pointee.sa_family == sa_family_t(AF_INET) ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                guard getnameinfo(addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let ip = String(cString: host)
                if addr.pointee.sa_family == sa_family_t(AF_INET) {
                    var maskText = ""
                    if let m = ifa.ifa_netmask {
                        let bits = m.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }.nonzeroBitCount
                        maskText = "/\(bits)"
                    }
                    v4.append(ip + maskText)
                } else {
                    v6.append(ip.components(separatedBy: "%").first ?? ip)
                }
            case AF_LINK:
                if let data = ifa.ifa_data { mtu = data.assumingMemoryBound(to: if_data.self).pointee.ifi_mtu }
                mac = addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { dl -> String? in
                    let d = dl.pointee
                    guard d.sdl_alen == 6 else { return nil }
                    return withUnsafeBytes(of: d.sdl_data) { bytes in
                        (0..<6).map { String(format: "%02X", bytes[Int(d.sdl_nlen) + $0]) }.joined(separator: ":")
                    }
                }
            default: break
            }
        }
        var rows: [InfoRow] = []
        if !v4.isEmpty { rows.append(InfoRow("IPv4", v4.joined(separator: ", "))) }
        if !v6.isEmpty { rows.append(InfoRow("IPv6", v6.joined(separator: "\n"))) }
        if let mac { rows.append(InfoRow("This Mac's MAC", mac)) }
        if let mtu { rows.append(InfoRow("MTU", "\(mtu) bytes")) }
        return rows
    }
}

// MARK: - Latency

/// Streams `ping -i 1` while someone is looking. `-t 300` caps each run, so a ping never outlives the app by long.
@MainActor final class PingMonitor: ObservableObject {
    let target: String
    @Published private(set) var samples: [NetTools.PingSample] = []
    nonisolated(unsafe) private var process: Process?
    private var wanted = false

    init(target: String) { self.target = target }

    deinit { process?.terminate() }  // the view went away without onDisappear

    func start() {
        wanted = true
        guard process == nil else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-i", "1", "-t", "300", target]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        let buffer = LineBuffer()
        let me = WeakMonitor(self)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let found = buffer.lines(data).compactMap(NetTools.pingSample)
            guard !found.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { me.value?.add(found) } }
        }
        p.terminationHandler = { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let m = me.value else { return }
                    m.process = nil
                    if m.wanted { m.start() }
                }
            }
        }
        do { try p.run(); process = p } catch { NSLog("FastGlance: ping failed: \(error)") }
    }

    func stop() {
        wanted = false
        process?.terminate()
        process = nil
    }

    private func add(_ s: [NetTools.PingSample]) {
        samples = Array((samples + s).suffix(60))
    }
}

/// Lets the pipe and termination handlers reach the monitor without keeping it alive.
private final class WeakMonitor: @unchecked Sendable {
    weak var value: PingMonitor?
    init(_ value: PingMonitor) { self.value = value }
}

/// Splits a byte stream into lines, keeping a partial last line for the next read.
private final class LineBuffer: @unchecked Sendable {
    private var pending = ""
    private let lock = NSLock()
    func lines(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending += String(decoding: data, as: UTF8.self)
        var parts = pending.components(separatedBy: "\n")
        pending = parts.removeLast()
        return parts
    }
}

struct PingPanel: View {
    let title: String
    let target: String
    @StateObject private var monitor: PingMonitor

    init(title: String, target: String) {
        self.title = title
        self.target = target
        _monitor = StateObject(wrappedValue: PingMonitor(target: target))
    }

    var body: some View {
        let s = NetTools.stats(monitor.samples)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).bold()
                Text(target).foregroundStyle(.secondary)
                Spacer()
                Text(Self.summary(s, count: monitor.samples.count)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Chart {
                ForEach(Array(monitor.samples.enumerated()), id: \.offset) { i, sample in
                    switch sample {
                    case let .reply(ms): BarMark(x: .value("Ping", i), y: .value("ms", ms)).foregroundStyle(Color.accentColor)
                    case .lost: RuleMark(x: .value("Ping", i)).foregroundStyle(.red.opacity(0.5))
                    }
                }
            }
            .chartXScale(domain: 0...59)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() } }
            .frame(height: 70)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    static func summary(_ s: NetTools.PingStats, count: Int) -> String {
        guard count > 0 else { return "Waiting for replies…" }
        func ms(_ v: Double?) -> String { v.map { String(format: "%.1f ms", $0) } ?? "—" }
        return "avg \(ms(s.average)) · jitter \(ms(s.jitter)) · loss \(Int((s.loss * 100).rounded()))% of \(count)"
    }
}

/// Router latency always; the internet only when the user asks, with the target named.
struct LatencyTool: View {
    let gateway: String?
    let gatewayTitle: String
    @State private var internet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let gateway {
                PingPanel(title: gatewayTitle, target: gateway).id(gateway)
            } else {
                Text("No router address yet.").foregroundStyle(.secondary)
            }
            Toggle("Also measure the internet (pings 1.1.1.1, Cloudflare's public DNS)", isOn: $internet)
            if internet { PingPanel(title: "Internet", target: "1.1.1.1") }
            Text("A steady router with a slow or lossy internet line points beyond your own network.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Traffic

struct TrafficTool: View {
    let iface: String
    @State private var last: (date: Date, received: UInt64, sent: UInt64)?
    @State private var rates: (down: Double, up: Double)?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            InfoGrid(rows: [
                InfoRow("Download", rates.map { "\(Util.bytes(Int($0.down)))/s" } ?? "…"),
                InfoRow("Upload", rates.map { "\(Util.bytes(Int($0.up)))/s" } ?? "…"),
                InfoRow("Received since start-up", last.map { Util.bytes(Int($0.received)) } ?? "—"),
                InfoRow("Sent since start-up", last.map { Util.bytes(Int($0.sent)) } ?? "—"),
            ])
            .task(id: ctx.date) { sample() }
        }
    }

    private func sample() {
        guard let now = InternetSource.interfaceBytes(iface) else { return }
        let date = Date()
        if let last, now.received >= last.received, now.sent >= last.sent {
            let dt = max(date.timeIntervalSince(last.date), 0.1)
            rates = (Double(now.received - last.received) / dt, Double(now.sent - last.sent) / dt)
        }
        last = (date, now.received, now.sent)
    }
}

// MARK: - Wi-Fi scan

struct WiFiScanTool: View {
    struct Row: Identifiable {
        let id = UUID()
        let ssid: String?
        let channel: Int
        let band: String
        let rssi: Int
        let noise: Int
        let isCurrent: Bool
    }

    @State private var rows: [Row] = []
    @State private var scanning = false
    @State private var failure: String?
    @State private var scannedAt: Date?

    var body: some View {
        let counts = NetTools.channelCounts(rows.map { ($0.channel, $0.band) })
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(scanning ? "Scanning…" : "Scan Again") { scan() }.disabled(scanning)
                if scanning { ProgressView().controlSize(.small) }
                if let scannedAt, !scanning {
                    Text("\(rows.count) networks · \(scannedAt.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary)
                }
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            if !rows.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                    GridRow {
                        Text("Network"); Text("Channel"); Text("Signal"); Text("Networks on channel")
                    }
                    .font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(rows) { r in
                        GridRow {
                            Text((r.ssid ?? "Name hidden") + (r.isCurrent ? "  ✓" : "")).lineLimit(1)
                                .fontWeight(r.isCurrent ? .semibold : .regular)
                                .foregroundStyle(r.ssid == nil ? .secondary : .primary)
                            Text("\(r.channel) · \(r.band)")
                            Text("\(r.rssi) dBm")
                            Text("\(counts["\(r.band)/\(r.channel)"] ?? 1)")
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
            Text("“Networks on channel” counts the networks this Mac can see. It isn't measured airtime: a channel with one busy network can be more crowded than one with five quiet ones. Scanning briefly pauses Wi-Fi traffic.")
                .font(.caption).foregroundStyle(.secondary)
            if rows.contains(where: { $0.ssid == nil }) {
                Text("macOS hides network names from apps without Location access.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if scannedAt == nil { scan() } }
    }

    private func scan() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let iface = CWWiFiClient.shared().interface()
            let currentChannel = iface?.wlanChannel()?.channelNumber
            let currentSSID = iface?.ssid()
            var found: [Row] = []
            var error: String?
            do {
                let networks = try iface?.scanForNetworks(withName: nil) ?? []
                found = networks.compactMap { n in
                    guard let ch = n.wlanChannel else { return nil }
                    return Row(ssid: n.ssid, channel: ch.channelNumber, band: InternetSource.bandName(ch.channelBand),
                               rssi: n.rssiValue, noise: n.noiseMeasurement,
                               isCurrent: n.ssid != nil && n.ssid == currentSSID && ch.channelNumber == currentChannel)
                }.sorted { $0.rssi > $1.rssi }
            } catch let e {
                error = "Couldn't scan: \(e.localizedDescription)"
            }
            if iface == nil { error = "No Wi-Fi interface." }
            DispatchQueue.main.async {
                rows = Array(found.prefix(40))
                failure = error
                scanning = false
                scannedAt = Date()
            }
        }
    }
}

// MARK: - DNS

struct DNSTool: View {
    let servers: [String]
    @State private var times: [String: String] = [:]
    @State private var measuring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if servers.isEmpty {
                Text("No DNS servers configured.").foregroundStyle(.secondary)
            } else {
                InfoGrid(rows: servers.map { InfoRow($0, times[$0] ?? "—") })
                HStack {
                    Button("Measure Response Time") { measure() }.disabled(measuring)
                    if measuring { ProgressView().controlSize(.small) }
                }
                Text("Looks up apple.com once through each server.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func measure() {
        measuring = true
        let servers = servers
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String: String] = [:]
            for s in servers {
                let r = Util.exec("/usr/bin/dig", ["@\(s)", "apple.com", "+tries=1", "+time=2"], timeout: 5)
                out[s] = NetTools.digQueryTime(r.output).map { "\($0) ms" } ?? "No answer"
            }
            DispatchQueue.main.async {
                times = out
                measuring = false
            }
        }
    }
}

// MARK: - SMB shares

struct SMBSharesTool: View {
    let host: String
    @State private var shares: [NetTools.Share]?
    @State private var failure: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(shares == nil ? "List Shares" : "Refresh") { load() }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            if let shares {
                if shares.isEmpty { Text("No shares visible to a guest.").foregroundStyle(.secondary) }
                ForEach(shares.filter { $0.type == "Disk" }) { s in
                    HStack {
                        Image(systemName: "folder")
                        Text(s.name)
                        if !s.comment.isEmpty { Text(s.comment).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Open") {
                            let path = s.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s.name
                            Util.open("smb://\(host)/\(path)")
                        }
                    }
                    .controlSize(.small)
                }
            }
            Text("Lists what the device shares with guests, without signing in. Opening a share may ask for a password.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() {
        loading = true
        let host = host
        DispatchQueue.global(qos: .userInitiated).async {
            // -G guest, -N never prompt for a password.
            let r = Util.exec("/usr/bin/smbutil", ["view", "-G", "-N", "//\(host)"], timeout: 10)
            let list = NetTools.smbShares(r.output)
            DispatchQueue.main.async {
                loading = false
                if r.status == 0 || !list.isEmpty {
                    shares = list
                    failure = nil
                } else {
                    shares = nil
                    failure = "Couldn't list shares: \(DiskSource.lastLine(r.output))"
                }
            }
        }
    }
}
