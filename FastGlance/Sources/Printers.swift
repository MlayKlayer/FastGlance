import SwiftUI

/// CUPS print queues. Online state comes from the transport: the USB device being present,
/// the Bonjour service being advertised, or CUPS not reporting the printer offline.
@MainActor final class PrinterSource: DeviceSource {
    struct Queue: Equatable {
        let name: String
        var attrs: [String: String]
        var jobs: [Job] = []
        var uri: String { attrs["device-uri"] ?? "" }
    }

    struct Job: Equatable, Identifiable {
        let id: Int
        let name: String
        let user: String
        let state: String          // IPP job-state keyword: pending, pending-held, processing, ...
        let reasons: String
        let kilobytes: Int
        let created: Date?
        var isHeld: Bool { state == "pending-held" }
    }

    /// Get-Jobs that names the requesting user: CUPS hides job names and owners from anonymous requests.
    nonisolated private static let jobsTest: String = {
        let path = NSTemporaryDirectory() + "fastglance-get-jobs.test"
        try? """
        {
            OPERATION Get-Jobs
            GROUP operation-attributes-tag
            ATTR charset attributes-charset utf-8
            ATTR language attributes-natural-language en
            ATTR uri printer-uri $uri
            ATTR name requesting-user-name $user
            ATTR keyword requested-attributes job-id,job-state,job-state-reasons,job-name,job-originating-user-name,job-k-octets,time-at-creation
            STATUS successful-ok
        }
        """.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }()

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

    func reloadIfStale(after seconds: TimeInterval = 15) {
        if Date().timeIntervalSince(loadedAt) > seconds { reload() }
    }

    func reload() {
        guard !loading else { return }
        loading = true
        loadedAt = Date()
        DispatchQueue.global(qos: .utility).async {
            let names = Util.text("/usr/bin/lpstat", ["-e"]).split(separator: "\n").map(String.init)
            let queues = names.map { name in
                let uri = "ipp://localhost/printers/\(name)"
                return Queue(name: name, attrs: Self.parseIPP(Util.text("/usr/bin/ipptool", ["-tv", uri, "get-printer-attributes.test"])),
                             jobs: Self.parseJobs(Util.text("/usr/bin/ipptool", ["-tv", uri, Self.jobsTest])))
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

    /// One job per run of attributes; a key repeating means the next job has started.
    nonisolated static func parseJobs(_ text: String) -> [Job] {
        var groups: [[String: String]] = []
        var cur: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.range(of: ") = "), let open = line.range(of: " ("), open.lowerBound < eq.lowerBound else { continue }
            let key = line[..<open.lowerBound].trimmingCharacters(in: .whitespaces)
            guard key.hasPrefix("job-") || key == "time-at-creation" else { continue }
            if cur[key] != nil { groups.append(cur); cur = [:] }
            cur[key] = String(line[eq.upperBound...])
        }
        if !cur.isEmpty { groups.append(cur) }
        return groups.compactMap { g in
            guard let id = g["job-id"].flatMap(Int.init) else { return nil }
            return Job(id: id, name: g["job-name"] ?? "Job \(id)", user: g["job-originating-user-name"] ?? "—",
                       state: g["job-state"] ?? "pending", reasons: g["job-state-reasons"] ?? "",
                       kilobytes: g["job-k-octets"].flatMap(Int.init) ?? 0,
                       created: g["time-at-creation"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)))
        }.sorted { $0.id < $1.id }
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
        if a["printer-state"] == "stopped" { status = online ? "Paused" : "Offline · Paused" }
        if jobs > 0 { status += " · \(jobs) job\(jobs == 1 ? "" : "s")" }
        let names = (a["marker-names"] ?? "").split(separator: ",").map(String.init)
        let levels = (a["marker-levels"] ?? "").split(separator: ",").compactMap { Int($0) }
        // Negative levels mean "unknown" in IPP.
        let ink = zip(names, levels).filter { $0.1 >= 0 }.map { Battery(label: $0.0, percent: $0.1) }
        let connection = q.uri.split(separator: ":").first.map(String.init) ?? "—"
        // Some drivers (this Xerox's among them) always say "offline"; the USB or Bonjour presence above is the real answer.
        let reasons = Self.reasons(a["printer-state-reasons"] ?? "").filter { !(online && $0.key == "offline") }
        let problems = reasons.filter(\.isError).map(\.text)
        if online, let first = problems.first { status = first + (jobs > 0 ? " · \(jobs) job\(jobs == 1 ? "" : "s")" : "") }
        var extra: [InfoRow] = []
        if let serial = Self.usbSerial(q.uri) { extra.append(InfoRow("Serial", serial)) }
        if let t = a["marker-change-time"].flatMap(Double.init), t > 0 {
            extra.append(InfoRow("Supplies reported", Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)))
        }
        return Device(
            id: "printer:\(q.name)", name: a["printer-info"].flatMap { $0.isEmpty ? nil : $0 } ?? q.name, kind: .printer,
            isConnected: online, status: status, batteries: online ? ink : [],
            info: [InfoRow("Model", a["printer-make-and-model"] ?? "—"),
                   InfoRow("Connection", connection.uppercased()),
                   InfoRow("Queue", q.name),
                   InfoRow("Location", a["printer-location"].flatMap { $0.isEmpty ? nil : $0 } ?? "—"),
                   InfoRow("Accepting jobs", a["printer-is-accepting-jobs"] == "true" ? "Yes" : "No"),
                   InfoRow("Status", reasons.isEmpty ? "Ready" : reasons.map(\.text).joined(separator: ", "))] + extra,
            raw: a.map { InfoRow($0.key, $0.value) }.sorted { $0.key < $1.key },
            warning: online && !problems.isEmpty ? problems.joined(separator: ". ") + "." : nil)
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
        let paused = q.attrs["printer-state"] == "stopped"
        out.append(DeviceAction(device, "pause", paused ? "Resume Printer" : "Pause Printer", paused ? "play.circle" : "pause.circle") { [weak self] in
            self?.command(paused ? "/usr/sbin/cupsenable" : "/usr/sbin/cupsdisable", [name], device, paused ? "Resumed" : "Paused · jobs wait in the queue")
        })
        if let service = Self.dnssdName(q.uri), let ip = network.ip(forServiceName: service) {
            out.append(DeviceAction(device, "web", "Open Web Interface", "safari") { Util.open("http://\(ip)") })
        }
        out.append(DeviceAction(device, "settings", "Printers & Scanners…", "gearshape") {
            Util.open("x-apple.systempreferences:com.apple.Print-Scanner-Settings.extension")
        })
        return out
    }

    // MARK: - Jobs

    func jobs(for device: Device) -> [Job] {
        queues.first { "printer:\($0.name)" == device.id }?.jobs ?? []
    }

    func hold(_ job: Job, _ device: Device) {
        guard let q = queue(device) else { return }
        command("/usr/bin/lp", ["-i", "\(q)-\(job.id)", "-H", "hold"], device, "Held “\(job.name)”")
    }

    func release(_ job: Job, _ device: Device) {
        guard let q = queue(device) else { return }
        command("/usr/bin/lp", ["-i", "\(q)-\(job.id)", "-H", "resume"], device, "Released “\(job.name)”")
    }

    func cancel(_ job: Job, _ device: Device) {
        guard let q = queue(device) else { return }
        command("/usr/bin/cancel", ["\(q)-\(job.id)"], device, "Cancelled “\(job.name)”")
    }

    private func queue(_ device: Device) -> String? {
        queues.first { "printer:\($0.name)" == device.id }?.name
    }

    /// CUPS commands answer in a line on failure (not allowed, job already finished); that line is what the row shows.
    private func command(_ path: String, _ args: [String], _ device: Device, _ success: String) {
        let (id, name) = (device.id, device.name)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Util.exec(path, args)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if r.status == 0 {
                        Notifier.shared.report(id, name, success)
                    } else {
                        // "/usr/bin/cancel: cancel-job failed: Job #274 is already canceled" → from "cancel-job failed" on.
                        let line = DiskSource.lastLine(r.output)
                        let message = line.hasPrefix("/") ? line.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? line : line
                        Notifier.shared.report(id, name, "Failed: \(message)", failed: true)
                    }
                    self.reload()
                }
            }
        }
    }

    func tools(for device: Device) -> [DeviceTool] {
        guard device.isConnected || !jobs(for: device).isEmpty else { return [] }
        return [DeviceTool(id: "printer.jobs", title: "Print Jobs", symbol: "list.bullet.rectangle") { [unowned self] in
            AnyView(PrintJobsTool(printers: self, device: device, jobs: jobs(for: device)))
        }]
    }

    // MARK: - Status and capabilities

    struct Reason: Equatable {
        let key: String
        let text: String
        let isError: Bool
    }

    /// `printer-state-reasons` keywords in words. The -report/-warning/-error suffix is the severity; only errors are problems.
    nonisolated static func reasons(_ value: String) -> [Reason] {
        let words = ["media-jam": "Paper jam", "media-empty": "Out of paper", "media-needed": "Load paper",
                     "media-low": "Paper low", "toner-empty": "Out of toner", "toner-low": "Toner low",
                     "marker-supply-empty": "Out of ink or toner", "marker-supply-low": "Ink or toner low",
                     "marker-waste-full": "Waste container full", "marker-waste-almost-full": "Waste container almost full",
                     "door-open": "Door open", "cover-open": "Cover open", "input-tray-missing": "Paper tray missing",
                     "output-area-full": "Output tray full", "output-area-almost-full": "Output tray almost full",
                     "offline": "Printer reports offline", "paused": "Paused", "shutdown": "Shut down",
                     "connecting-to-device": "Connecting", "timed-out": "Not responding", "stopped-partly": "Partly stopped",
                     "spool-area-full": "Print queue full", "cups-missing-filter": "Driver filter missing",
                     "cups-insecure-filter": "Driver filter rejected", "moving-to-paused": "Pausing",
                     "fuser-over-temp": "Fuser too hot", "fuser-under-temp": "Fuser warming up",
                     "developer-low": "Developer low", "developer-empty": "Developer empty", "opc-near-eol": "Drum nearly worn out",
                     "opc-life-over": "Drum worn out", "interlock-open": "Interlock open", "other": "Other problem"]
        return value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "none" }
            .map { k in
                var base = k
                var severity = "error"  // a reason without a suffix is an error per RFC 8011
                for suffix in ["-report", "-warning", "-error"] where base.hasSuffix(suffix) {
                    base = String(base.dropLast(suffix.count))
                    severity = String(suffix.dropFirst())
                }
                let text = words[base] ?? base.replacingOccurrences(of: "-", with: " ").capitalized
                // "Paused" is the user's own choice and "Printer reports offline" duplicates the row's state.
                let isError = severity == "error" && !["paused", "moving-to-paused", "offline", "connecting-to-device"].contains(base)
                return Reason(key: base, text: severity == "warning" ? text + " (warning)" : text, isError: isError)
            }
    }

    /// "iso_a4_210x297mm" → "A4", "na_letter_8.5x11in" → "Letter", "jis_b5_182x257mm" → "JIS B5".
    nonisolated static func mediaName(_ keyword: String) -> String {
        let parts = keyword.split(separator: "_").map(String.init)
        guard parts.count >= 3 else { return keyword }
        let name = parts[1...(parts.count - 2)].joined(separator: " ")
        let pretty = name.count <= 3 ? name.uppercased() : name.prefix(1).uppercased() + name.dropFirst()
        if parts[0] == "custom" { return "Custom (\(name))" }
        return parts[0] == "jis" ? "JIS " + pretty : pretty
    }

    nonisolated static func keywordName(_ k: String) -> String {
        let known = ["one-sided": "One-sided", "two-sided-long-edge": "Two-sided (long edge)", "two-sided-short-edge": "Two-sided (short edge)",
                     "monochrome": "Black & white", "color": "Color", "auto": "Automatic", "auto-monochrome": "Automatic black & white",
                     "process-monochrome": "Process black & white", "face-down": "Face down", "face-up": "Face up"]
        return known[k] ?? k.replacingOccurrences(of: "-", with: " ").capitalized
    }

    func sections(for device: Device) -> [InfoSection] {
        guard let q = queues.first(where: { "printer:\($0.name)" == device.id }) else { return [] }
        return Self.sections(q.attrs)
    }

    nonisolated static func sections(_ a: [String: String]) -> [InfoSection] {
        func list(_ key: String, _ f: (String) -> String = { $0 }) -> String? {
            a[key].map { $0.split(separator: ",").map { f(String($0)) }.joined(separator: ", ") }.flatMap { $0.isEmpty ? nil : $0 }
        }
        var caps: [InfoRow] = []
        func add(_ title: String, _ value: String?) { if let value { caps.append(InfoRow(title, value)) } }
        add("Paper sizes", list("media-supported", mediaName))
        add("Default paper", a["media-default"].map(mediaName))
        add("Paper sources", list("media-source-supported", keywordName))
        add("Sides", list("sides-supported", keywordName))
        add("Color", list("print-color-mode-supported", keywordName))
        add("Resolution", list("printer-resolution-supported"))
        add("Quality", list("print-quality-supported"))
        add("Output bin", list("output-bin-supported", keywordName))
        add("Copies", a["copies-supported"])
        add("Pages per sheet", list("number-up-supported"))
        add("Hold jobs", a["job-hold-until-supported"].map { $0.contains("indefinite") ? "Supported" : "Not supported" })

        var supplies: [InfoRow] = []
        let names = (a["marker-names"] ?? "").split(separator: ",").map(String.init)
        let levels = (a["marker-levels"] ?? "").split(separator: ",").map { Int($0) ?? -1 }
        let types = (a["marker-types"] ?? "").split(separator: ",").map(String.init)
        let lows = (a["marker-low-levels"] ?? "").split(separator: ",").map { Int($0) ?? -1 }
        for (i, name) in names.enumerated() {
            let level = i < levels.count ? levels[i] : -1
            var value = level >= 0 ? "\(level)%" : level == -3 ? "Has some left" : "Unknown"
            if i < types.count { value += " · " + keywordName(types[i]) }
            if i < lows.count, lows[i] > 0 { value += " · low below \(lows[i])%" }
            supplies.append(InfoRow(name, value))
        }
        if let t = a["marker-change-time"].flatMap(Double.init), t > 0 {
            supplies.append(InfoRow("Last reported", Date(timeIntervalSince1970: t).formatted(date: .abbreviated, time: .shortened)))
        }

        var status: [InfoRow] = [InfoRow("State", (a["printer-state"] ?? "—").capitalized)]
        let reasons = reasons(a["printer-state-reasons"] ?? "")
        status.append(InfoRow("Reasons", reasons.isEmpty ? "None" : reasons.map(\.text).joined(separator: ", ")))
        if let m = a["printer-state-message"], !m.isEmpty { status.append(InfoRow("Message", m)) }
        if let n = a["queued-job-count"] { status.append(InfoRow("Jobs in queue", n)) }
        if let s = a["printer-is-shared"] { status.append(InfoRow("Shared", s == "true" ? "Yes" : "No")) }
        if let u = a["device-uri"] { status.append(InfoRow("Device URI", u)) }

        return [InfoSection(title: "Capabilities", rows: caps), InfoSection(title: "Supplies", rows: supplies),
                InfoSection(title: "Status", rows: status)].filter { !$0.rows.isEmpty }
    }
}

/// Jobs in the queue with Hold / Release / Cancel each. Refreshes every few seconds while open.
struct PrintJobsTool: View {
    let printers: PrinterSource
    let device: Device
    let jobs: [PrinterSource.Job]
    @State private var confirmCancel: PrinterSource.Job?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { ctx in
            Group {
                if jobs.isEmpty {
                    Text("No jobs waiting.").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(jobs) { job in row(job) }
                        Text("Held jobs stay in the queue until you release them.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .task(id: ctx.date) { printers.reloadIfStale(after: 4) }
        }
        .confirmationDialog("Cancel “\(confirmCancel?.name ?? "")”?", isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } })) {
            Button("Cancel Job", role: .destructive) { if let j = confirmCancel { printers.cancel(j, device) } }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("The job is removed from the queue.")
        }
    }

    private func row(_ job: PrinterSource.Job) -> some View {
        HStack(spacing: 10) {
            Image(systemName: job.isHeld ? "pause.circle.fill" : job.state == "processing" ? "printer.fill" : "clock")
                .foregroundStyle(job.isHeld ? .orange : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name).lineLimit(1)
                Text(Self.subtitle(job)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if job.isHeld {
                Button("Release") { printers.release(job, device) }
            } else if job.state == "pending" || job.state == "processing" {
                Button("Hold") { printers.hold(job, device) }
            }
            Button("Cancel…") { confirmCancel = job }
        }
        .controlSize(.small)
    }

    static func subtitle(_ job: PrinterSource.Job) -> String {
        let state = ["pending": "Waiting", "pending-held": "Held", "processing": "Printing", "processing-stopped": "Stopped",
                     "canceled": "Cancelled", "aborted": "Aborted", "completed": "Done"][job.state] ?? job.state
        var parts = ["#\(job.id)", state, job.user]
        if job.kilobytes > 0 { parts.append(Util.bytes(job.kilobytes * 1024)) }
        if let d = job.created { parts.append(d.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: " · ")
    }
}
