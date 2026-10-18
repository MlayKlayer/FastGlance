import AppKit

/// CUPS print queues. Online state comes from the transport: the USB device being present,
/// the Bonjour service being advertised, or CUPS not reporting the printer offline.
@MainActor final class PrinterSource: DeviceSource {
    struct Queue: Equatable {
        let name: String
        var attrs: [String: String]
        var uri: String { attrs["device-uri"] ?? "" }
    }

    let prefix = "printer"
    var onChange: (() -> Void)?
    private var queues: [Queue] = []
    private let usb: USBSource
    private let network: NetworkSource
    private var loading = false

    init(usb: USBSource, network: NetworkSource) {
        self.usb = usb
        self.network = network
    }

    func start() {
        // lpstat + ipptool per queue isn't free: every 30 s while the menu is open, every 5 min otherwise.
        _ = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated {
            guard let self, Notifier.shared.isMenuOpen() || Date().timeIntervalSince(self.loadedAt) >= 300 else { return }
            self.reload()
        } }
        reload()
    }

    private var loadedAt = Date.distantPast

    func reload() {
        guard !loading else { return }
        loading = true
        loadedAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let names = Util.text("/usr/bin/lpstat", ["-e"]).split(separator: "\n").map(String.init)
            let queues = names.map { name in
                Queue(name: name, attrs: Self.parseIPP(Util.text("/usr/bin/ipptool",
                    ["-tv", "ipp://localhost/printers/\(name)", "get-printer-attributes.test"])))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.loading = false
                    if queues != self.queues {
                        self.queues = queues
                        // Claimed USB serials / Bonjour names changed: let those sources drop their duplicates.
                        self.usb.reload()
                        self.network.rebuild()
                        self.onChange?()
                    }
                }
            }
        }
    }

    /// `ipptool -tv` lines like `        marker-levels (1setOf integer) = 80,60`.
    nonisolated static func parseIPP(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.range(of: ") = "), let open = line.range(of: " (") , open.lowerBound < eq.lowerBound else { continue }
            let key = line[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { continue }
            out[key] = String(line[eq.upperBound...])
        }
        return out
    }

    /// Serials of USB printers that have a queue; the USB source leaves those to us.
    var usbSerials: Set<String> { Set(queues.compactMap { Self.usbSerial($0.uri) }) }

    /// Bonjour service names behind `dnssd://` queues; the network source leaves those to us.
    var dnssdNames: Set<String> { Set(queues.compactMap { Self.dnssdName($0.uri) }) }

    nonisolated static func usbSerial(_ uri: String) -> String? {
        guard uri.hasPrefix("usb://") else { return nil }
        return URLComponents(string: uri)?.queryItems?.first { $0.name == "serial" }?.value
    }

    nonisolated static func dnssdName(_ uri: String) -> String? {
        // dnssd://Brother%20HL-L2350DW._ipp._tcp.local./?uuid=...
        guard uri.hasPrefix("dnssd://"), let host = uri.dropFirst(8).split(separator: "/").first else { return nil }
        let decoded = String(host).removingPercentEncoding ?? String(host)
        return decoded.components(separatedBy: "._").first
    }

    private func isOnline(_ q: Queue) -> Bool {
        if let serial = Self.usbSerial(q.uri) { return usb.presentSerials.contains(serial) }
        if let name = Self.dnssdName(q.uri) { return network.liveServiceNames.contains(name) }
        return !(q.attrs["printer-state-reasons"] ?? "").contains("offline")
    }

    var devices: [Device] { queues.map(device) }

    private func device(_ q: Queue) -> Device {
        let a = q.attrs
        let online = isOnline(q)
        let jobs = Int(a["queued-job-count"] ?? "") ?? 0
        let state = (a["printer-state"] ?? "idle").capitalized
        var status = online ? state : "Offline"
        if jobs > 0 { status += " · \(jobs) job\(jobs == 1 ? "" : "s")" }
        let names = (a["marker-names"] ?? "").split(separator: ",").map(String.init)
        let levels = (a["marker-levels"] ?? "").split(separator: ",").compactMap { Int($0) }
        // Negative levels mean "unknown" in IPP.
        let ink = zip(names, levels).filter { $0.1 >= 0 }.map { Battery(label: $0.0, percent: $0.1) }
        let connection = q.uri.split(separator: ":").first.map(String.init) ?? "—"
        return Device(
            id: "printer:\(q.name)", name: a["printer-info"].flatMap { $0.isEmpty ? nil : $0 } ?? q.name, kind: .printer,
            isConnected: online, status: status, batteries: online ? ink : [],
            info: [InfoRow("Model", a["printer-make-and-model"] ?? "—"),
                   InfoRow("Connection", connection.uppercased()),
                   InfoRow("Queue", q.name),
                   InfoRow("Location", a["printer-location"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
                   InfoRow("Accepting jobs", a["printer-is-accepting-jobs"] == "true" ? "Yes" : "No"),
                   InfoRow("State reasons", a["printer-state-reasons"] ?? "—")],
            raw: a.map { InfoRow($0.key, $0.value) }.sorted { $0.key < $1.key })
    }

    func actions(for device: Device) -> [DeviceAction] {
        guard let q = queues.first(where: { "printer:\($0.name)" == device.id }) else { return [] }
        let name = q.name
        var out = [
            DeviceAction(device, "queue", "Open Print Queue", "list.bullet.rectangle") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Print Center.app"))
            },
            DeviceAction(device, "testpage", "Print Test Page", "doc.richtext") { [weak self] in
                Util.run("/usr/bin/lp", ["-d", name, "/usr/share/cups/data/testprint"]) { _ in self?.reload() }
            },
        ]
        if Int(q.attrs["queued-job-count"] ?? "") ?? 0 > 0 {
            out.append(DeviceAction(device, "cancel", "Cancel All Jobs", "xmark.bin") { [weak self] in
                Util.run("/usr/bin/cancel", ["-a", name]) { _ in self?.reload() }
            })
        }
        if let service = Self.dnssdName(q.uri), let ip = network.ip(forServiceName: service) {
            out.append(DeviceAction(device, "web", "Open Web Interface", "safari") { Util.open("http://\(ip)") })
        }
        out.append(DeviceAction(device, "settings", "Printers & Scanners…", "gearshape") {
            Util.open("x-apple.systempreferences:com.apple.Print-Scanner-Settings.extension")
        })
        return out
    }
}
