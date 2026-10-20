import SwiftUI
import Darwin

/// Devices on the local network: Bonjour services for names and types, the ARP table for everything else.
@MainActor final class NetworkSource: NSObject, DeviceSource, NetServiceBrowserDelegate, NetServiceDelegate {
    /// Order is naming priority: the first type a host advertises gives it its name.
    static let serviceTypes = ["_companion-link._tcp.", "_airplay._tcp.", "_googlecast._tcp.", "_sonos._tcp.", "_raop._tcp.",
                               "_spotify-connect._tcp.", "_ipp._tcp.", "_ipps._tcp.", "_printer._tcp.", "_hap._tcp.", "_matter._tcp.",
                               "_smb._tcp.", "_afpovertcp._tcp.", "_rfb._tcp.", "_ssh._tcp.", "_http._tcp."]

    struct Host {
        var ip: String?
        var mac: String?
        var hostName: String?
        var types: Set<String> = []
        var names: [String: String] = [:]  // service type -> Bonjour name
    }

    let prefix = "net"
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []
    /// Bonjour names other sources already show (printer queues); hidden here.
    var claimedServiceNames: () -> Set<String> = { [] }
    private(set) var liveServiceNames: Set<String> = []

    private var browsers: [NetServiceBrowser] = []
    private var services: [NetService] = []
    private var arp: [String: String] = [:]        // ip -> mac, last sweep only
    private var macs: [String: String] = [:]       // ip -> mac, every one seen; kept when scanning is off so ids stay stable
    private var macTried: Set<String> = []
    private var resolvingMACs = false
    private var reverseNames: [String: String] = [:]
    private var triedReverse: Set<String> = []
    private var gateway: String?
    private var ownIPs: Set<String> = []
    private var hosts: [String: Host] = [:]        // device id -> host, for actions
    private var lastSweep = Date.distantPast
    private var sweeping = false

    private let ownHostName = ProcessInfo.processInfo.hostName.lowercased()

    func start() {
        ownIPs = Self.ownIPv4s()  // before Bonjour answers, so this Mac never shows up as a device
        for type in Self.serviceTypes {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(b)
        }
        _ = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sweepIfDue() }
        }
        sweepIfDue()
    }

    // MARK: - Bonjour

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            service.delegate = self
            service.resolve(withTimeout: 10)
            services.append(service)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        MainActor.assumeIsolated {
            services.removeAll { $0 == service }
            if !moreComing { rebuild() }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        MainActor.assumeIsolated { rebuild() }
    }

    // MARK: - ARP sweep

    /// `maxAge` overrides the configured interval, e.g. to freshen up when the menu opens.
    func sweepIfDue(maxAge: TimeInterval? = nil) {
        let d = UserDefaults.standard
        guard d.bool(forKey: Prefs.networkScan) else {
            if !arp.isEmpty { arp = [:]; rebuild() }
            return
        }
        guard !sweeping, Date().timeIntervalSince(lastSweep) >= maxAge ?? d.double(forKey: Prefs.networkScanInterval) else { return }
        sweeping = true
        lastSweep = Date()
        let tried = triedReverse
        DispatchQueue.global(qos: .utility).async {
            let iface = Self.primaryIPv4()
            if let iface {
                // A datagram to every address makes the kernel ARP for it; replies land in the ARP table.
                Self.udpSend([0], to: Self.subnetHosts(ip: iface.ip, mask: iface.mask), port: 9)
                Thread.sleep(forTimeInterval: 1.5)
            }
            let table = Self.parseARP(Util.text("/usr/sbin/arp", ["-an"]))
            let gw = Self.parseGateway(Util.text("/sbin/route", ["-n", "get", "default"]))
            let names = Dictionary(uniqueKeysWithValues: table.keys.filter { !tried.contains($0) }.compactMap { ip in
                Self.reverseDNS(ip).map { (ip, $0) }
            })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.sweeping = false
                    self.arp = table
                    self.macs.merge(table) { $1 }
                    self.gateway = gw
                    self.triedReverse.formUnion(table.keys)
                    self.reverseNames.merge(names) { $1 }
                    self.rebuild()
                }
            }
        }
    }

    // MARK: - Merge

    func rebuild() {
        // A new network (or a new address on this one) means the cached IP -> MAC pairs may belong to other devices now.
        // two networks that both hand this Mac the same IP keep the cache; a DHCP reshuffle there can mislabel a host.
        let own = Self.ownIPv4s()
        if own != ownIPs { ownIPs = own; macs = [:]; macTried = [] }
        let claimed = claimedServiceNames()
        liveServiceNames = Set(services.map(\.name))
        var byKey: [String: Host] = [:]
        var claimedKeys = Set<String>()
        for s in services {
            let ips = Self.ipv4(s.addresses ?? [])
            let host = s.hostName?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !ips.contains(where: ownIPs.contains), host != ownHostName else { continue }  // this Mac
            guard let key = ips.first ?? s.hostName else { continue }       // not resolved yet
            var h = byKey[key] ?? Host(ip: ips.first, hostName: s.hostName)
            h.types.insert(s.type)
            h.names[s.type] = s.name
            byKey[key] = h
            if claimed.contains(s.name) { claimedKeys.insert(key) }
        }
        // ARP entries outlive a device by up to ~20 min, so "online" lags on disconnect. Probe each host if that matters.
        for ip in arp.keys where byKey[ip] == nil && !ownIPs.contains(ip) {
            byKey[ip] = Host(ip: ip)
        }

        var nextHosts: [String: Host] = [:]
        var next: [Device] = []
        var unknownMAC: [String] = []
        // The gateway is shown by the Internet row (router or iPhone hotspot).
        for (key, var h) in byKey where !claimedKeys.contains(key) && (h.ip == nil || h.ip != gateway) {
            if let ip = h.ip {
                h.mac = macs[ip]
                // The id comes from the MAC, so look it up before showing the host instead of renaming it later.
                if h.mac == nil && !macTried.contains(ip) { unknownMAC.append(ip); continue }
            }
            let id = h.mac.map { "net:\($0)" } ?? "net:host:\(h.hostName ?? key)"
            nextHosts[id] = h
            next.append(device(id: id, h))
        }
        hosts = nextHosts
        next.sort { $0.id < $1.id }
        if next != devices { devices = next; onChange?() }
        if !unknownMAC.isEmpty && !resolvingMACs { lookUpMACs(unknownMAC) }
    }

    /// One datagram to each Bonjour host makes the kernel ARP for it, even with network scanning off.
    private func lookUpMACs(_ ips: [String]) {
        resolvingMACs = true
        DispatchQueue.global(qos: .utility).async {
            Self.udpSend([0], to: ips, port: 9)
            Thread.sleep(forTimeInterval: 1)
            let table = Self.parseARP(Util.text("/usr/sbin/arp", ["-an"]))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.resolvingMACs = false
                    self.macTried.formUnion(ips)
                    self.macs.merge(table) { $1 }
                    self.rebuild()
                }
            }
        }
    }

    private func device(id: String, _ h: Host) -> Device {
        let isGateway = h.ip != nil && h.ip == gateway
        let bonjourName = Self.serviceTypes.lazy.compactMap { h.names[$0] }.first
        let name = bonjourName
            ?? h.ip.flatMap { reverseNames[$0] }
            ?? h.hostName.map { $0.replacingOccurrences(of: ".local.", with: "") }
            ?? (isGateway ? "Router" : "Device \(h.ip ?? "?")")
        var info: [InfoRow] = []
        if let ip = h.ip { info.append(InfoRow("IP address", ip)) }
        if let mac = h.mac { info.append(InfoRow("MAC address", mac.uppercased() + (Self.isPrivateMAC(mac) ? " (private)" : ""))) }
        if let host = h.hostName { info.append(InfoRow("Hostname", host)) }
        if isGateway { info.append(InfoRow("Role", "Default gateway")) }
        if !h.types.isEmpty { info.append(InfoRow("Services", h.types.map(Self.serviceLabel).sorted().joined(separator: ", "))) }
        let labels = h.types.map(Self.serviceLabel).sorted().prefix(3)
        return Device(id: id, name: name, kind: Self.kind(h.types, name: name, isGateway: isGateway), isConnected: true,
                      status: ([h.ip ?? h.hostName ?? ""] + labels).filter { !$0.isEmpty }.joined(separator: " · "),
                      info: info, raw: h.names.map { InfoRow($0.key, $0.value) }.sorted { $0.key < $1.key })
    }

    nonisolated static func kind(_ types: Set<String>, name: String, isGateway: Bool) -> DeviceKind {
        func has(_ t: [String]) -> Bool { !types.isDisjoint(with: t) }
        if has(["_ipp._tcp.", "_ipps._tcp.", "_printer._tcp."]) { return .printer }
        if name.contains("iPhone") || name.contains("iPad") { return .phone }
        if name.contains("Mac") || has(["_smb._tcp.", "_afpovertcp._tcp.", "_rfb._tcp.", "_ssh._tcp."]) { return .computer }
        if has(["_airplay._tcp.", "_raop._tcp.", "_googlecast._tcp.", "_sonos._tcp.", "_spotify-connect._tcp."]) { return .media }
        if has(["_hap._tcp.", "_matter._tcp."]) { return .smartHome }
        return isGateway ? .router : .network
    }

    nonisolated static func serviceLabel(_ type: String) -> String {
        switch type {
        case "_companion-link._tcp.": "Apple device"
        case "_airplay._tcp.", "_raop._tcp.": "AirPlay"
        case "_googlecast._tcp.": "Chromecast"
        case "_sonos._tcp.": "Sonos"
        case "_spotify-connect._tcp.": "Spotify Connect"
        case "_ipp._tcp.", "_ipps._tcp.", "_printer._tcp.": "Printer"
        case "_hap._tcp.": "HomeKit"
        case "_matter._tcp.": "Matter"
        case "_smb._tcp.": "File sharing"
        case "_afpovertcp._tcp.": "AFP"
        case "_rfb._tcp.": "Screen sharing"
        case "_ssh._tcp.": "SSH"
        case "_http._tcp.": "Web"
        default: type
        }
    }

    func ip(forServiceName name: String) -> String? {
        services.first { $0.name == name }.flatMap { Self.ipv4($0.addresses ?? []).first }
    }

    // MARK: - Actions

    func actions(for device: Device) -> [DeviceAction] {
        let h = hosts[device.id]
        let mac = h?.mac ?? (device.id.hasPrefix("net:host:") ? nil : String(device.id.dropFirst(4)))
        var out: [DeviceAction] = []
        if let h, device.isConnected, let ip = h.ip {
            let target = h.hostName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? ip
            if h.types.contains("_http._tcp.") || device.kind == .router || device.kind == .printer {
                out.append(DeviceAction(device, "web", "Open Web Interface", "safari") { Util.open("http://\(ip)") })
            }
            if h.types.contains("_smb._tcp.") {
                out.append(DeviceAction(device, "smb", "Open in Finder", "folder") { Util.open("smb://\(target)") })
            }
            if h.types.contains("_rfb._tcp.") {
                out.append(DeviceAction(device, "vnc", "Screen Sharing", "rectangle.on.rectangle") { Util.open("vnc://\(target)") })
            }
            if h.types.contains("_ssh._tcp.") {
                out.append(DeviceAction(device, "ssh", "SSH in Terminal", "terminal") { Util.open("ssh://\(target)") })
            }
            out.append(DeviceAction(device, "ping", "Ping", "waveform.path.ecg") { Self.ping(ip, device) })
            out.append(DeviceAction(device, "copyip", "Copy IP Address", "doc.on.doc") { Util.copy(ip) })
        }
        if let mac {
            let wake = DeviceAction(device, "wake", "Wake (Wake-on-LAN)", "power") {
                guard let packet = Self.magicPacket(mac) else { return }
                DispatchQueue.global().async { Self.udpSend(packet, to: Self.broadcastTargets(), port: 9, broadcast: true) }
                Notifier.shared.report(device.id, device.name, "Wake signal sent", notify: true)
            }
            // Offline: waking is the point. Online: it's just one more option.
            if device.isConnected { out.append(wake) } else { out.insert(wake, at: 0) }
            out.append(DeviceAction(device, "copymac", "Copy MAC Address", "doc.on.doc") { Util.copy(mac.uppercased()) })
        }
        return out
    }

    func sections(for device: Device) -> [InfoSection] {
        guard let h = hosts[device.id] else { return [] }
        let rows = services.filter { h.types.contains($0.type) && h.names[$0.type] == $0.name }
            .sorted { ($0.type, $0.name) < ($1.type, $1.name) }
            .map { s -> InfoRow in
                let txt = s.txtRecordData().map(Self.txtText) ?? ""
                let value = [s.name, s.port > 0 ? "port \(s.port)" : nil, txt.isEmpty ? nil : txt].compactMap { $0 }.joined(separator: " · ")
                return InfoRow(Self.serviceLabel(s.type), value)
            }
        return rows.isEmpty ? [] : [InfoSection(title: "Bonjour Services", rows: rows)]
    }

    func tools(for device: Device) -> [DeviceTool] {
        guard device.isConnected, let h = hosts[device.id], let ip = h.ip else { return [] }
        var out = [DeviceTool(id: "lan.latency", title: "Latency", symbol: "waveform.path.ecg") {
            AnyView(PingPanel(title: "Ping", target: ip).id(ip))
        }]
        if h.types.contains("_smb._tcp.") {
            let target = h.hostName.map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 } ?? ip
            out.append(DeviceTool(id: "lan.smb", title: "Shared Folders", symbol: "folder") { AnyView(SMBSharesTool(host: target)) })
        }
        return out
    }

    /// TXT records as "key=value" pairs; binary values show as their size. Parsed by hand (RFC 6763 length-prefixed strings):
    /// `NetService.dictionary(fromTXTRecord:)` returns NSNull for keys without a value and crashes when bridged.
    nonisolated static func txtText(_ data: Data) -> String {
        let bytes = [UInt8](data)
        var pairs: [(String, String?)] = []
        var i = 0
        while i < bytes.count {
            let len = Int(bytes[i])
            let end = min(i + 1 + len, bytes.count)
            let entry = Array(bytes[(i + 1)..<end])
            i = end
            guard !entry.isEmpty else { continue }
            let eq = entry.firstIndex(of: UInt8(ascii: "="))
            let key = String(decoding: entry[..<(eq ?? entry.count)], as: UTF8.self)
            guard !key.isEmpty else { continue }
            guard let eq else { pairs.append((key, nil)); continue }
            let value = Array(entry[(eq + 1)...])
            let printable = value.allSatisfy { $0 >= 0x20 && $0 != 0x7F } && String(bytes: value, encoding: .utf8) != nil
            pairs.append((key, printable ? String(decoding: value, as: UTF8.self) : "<\(value.count) bytes>"))
        }
        let text = pairs.sorted { $0.0 < $1.0 }.map { key, value in value.map { "\(key)=\($0)" } ?? key }.joined(separator: ", ")
        return text.count > 400 ? String(text.prefix(400)) + "…" : text
    }

    static func ping(_ ip: String, _ device: Device) {
        let (id, name) = (device.id, device.name)
        Notifier.shared.report(id, name, "Pinging…")
        Util.run("/sbin/ping", ["-c", "3", "-t", "5", ip]) { data in
            let text = String(decoding: data, as: UTF8.self)
            // "round-trip min/avg/max/stddev = 1.1/2.2/3.3/0.4 ms"
            if let line = text.split(separator: "\n").first(where: { $0.contains("min/avg/max") }),
               let avg = line.split(separator: "=").last?.split(separator: "/").dropFirst().first {
                Notifier.shared.report(id, name, "Replied · \(avg.trimmingCharacters(in: .whitespaces)) ms", notify: true)
            } else {
                // Some devices ignore ping even when online.
                Notifier.shared.report(id, name, "No reply to ping", failed: true) { ping(ip, device) }
            }
        }
    }

    // MARK: - Parsing & sockets (pure, testable)

    /// `arp -an` lines like `? (192.168.1.1) at 0:11:2:33:44:55 on en0 ifscope [ethernet]`.
    nonisolated static func parseARP(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.contains("incomplete") && !line.contains("permanent") {
            let parts = line.split(separator: " ")
            guard let at = parts.firstIndex(of: "at"), at + 1 < parts.count, at >= 1 else { continue }
            let ip = parts[at - 1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            guard let first = ip.split(separator: ".").first.flatMap({ Int($0) }), !(224...239).contains(first),
                  let mac = normalizeMAC(String(parts[at + 1])), mac != "ff:ff:ff:ff:ff:ff" else { continue }
            out[ip] = mac
        }
        return out
    }

    nonisolated static func normalizeMAC(_ s: String) -> String? {
        let parts = s.lowercased().split(whereSeparator: { $0 == ":" || $0 == "-" })
        guard parts.count == 6, parts.allSatisfy({ $0.count <= 2 && UInt8($0, radix: 16) != nil }) else { return nil }
        return parts.map { $0.count == 1 ? "0\($0)" : String($0) }.joined(separator: ":")
    }

    /// Randomised per-network addresses (iPhones, Android) set the "locally administered" bit.
    nonisolated static func isPrivateMAC(_ mac: String) -> Bool {
        UInt8(mac.prefix(2), radix: 16).map { $0 & 0x02 != 0 } ?? false
    }

    nonisolated static func magicPacket(_ mac: String) -> [UInt8]? {
        guard let norm = normalizeMAC(mac) else { return nil }
        let bytes = norm.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return [UInt8](repeating: 0xFF, count: 6) + Array([[UInt8]](repeating: bytes, count: 16).joined())
    }

    nonisolated static func parseGateway(_ text: String) -> String? {
        text.split(separator: "\n").first { $0.contains("gateway:") }?
            .split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func ipv4(_ addresses: [Data]) -> [String] {
        addresses.compactMap { d in
            d.withUnsafeBytes { raw -> String? in
                guard raw.count >= MemoryLayout<sockaddr_in>.size else { return nil }
                var sin = raw.loadUnaligned(as: sockaddr_in.self)
                guard sin.sin_family == sa_family_t(AF_INET) else { return nil }
                return ntop(&sin.sin_addr)
            }
        }
    }

    nonisolated private static func ntop(_ addr: inout in_addr) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }

    /// The first up, non-loopback IPv4 on an `en` interface, as host-order integers.
    nonisolated static func primaryIPv4() -> (ip: UInt32, mask: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cur = list
        while let ifa = cur?.pointee {
            defer { cur = ifa.ifa_next }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET), let mask = ifa.ifa_netmask,
                  ifa.ifa_flags & UInt32(IFF_UP) != 0, ifa.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            return (ip, m)
        }
        return nil
    }

    /// Every IPv4 address on this Mac with its interface name.
    nonisolated static func interfaceIPv4s() -> [(iface: String, ip: String)] {
        var out: [(String, String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return out }
        defer { freeifaddrs(list) }
        var cur = list
        while let ifa = cur?.pointee {
            defer { cur = ifa.ifa_next }
            if let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                var a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                out.append((String(cString: ifa.ifa_name), ntop(&a)))
            }
        }
        return out
    }

    nonisolated static func ownIPv4s() -> Set<String> { Set(interfaceIPv4s().map(\.ip)) }

    /// Every host address in the subnet, capped at a /22 around this Mac so big networks stay cheap.
    nonisolated static func subnetHosts(ip: UInt32, mask: UInt32) -> [String] {
        let m = max(mask, 0xFFFF_FC00)
        let net = ip & m
        let bcast = net | ~m
        guard bcast > net + 1 else { return [] }
        return (net + 1 ..< bcast).filter { $0 != ip }.map(dotted)
    }

    nonisolated static func dotted(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }

    nonisolated static func broadcastTargets() -> [String] {
        var out = ["255.255.255.255"]
        if let i = primaryIPv4() { out.append(dotted((i.ip & i.mask) | ~i.mask)) }
        return out
    }

    nonisolated static func udpSend(_ payload: [UInt8], to ips: [String], port: UInt16, broadcast: Bool = false) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var on: Int32 = 1
        if broadcast { setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size)) }
        for ip in ips {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { continue }
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, payload, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    nonisolated static func reverseDNS(_ ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(cString: host)
        return name.split(separator: ".").first.map(String.init)  // "living-room-tv.lan" -> "living-room-tv"
    }
}
