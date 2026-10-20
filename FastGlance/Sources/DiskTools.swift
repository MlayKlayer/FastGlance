import SwiftUI
import IOKit

/// Verify Volume: read-only check through `diskutil verifyVolume`, behind a confirmation that names what it affects.
struct VerifyTool: View {
    let disks: DiskSource
    let device: Device
    let running: Bool
    let result: DiskSource.VerifyResult?
    @State private var users: [String] = []
    @State private var checking = false
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checks the file system's structures and reports problems. Nothing on the volume is changed.")
            // Verified on exFAT and APFS images: only the startup volume is checked live.
            Text("macOS unmounts the volume for the check and mounts it again afterwards. Apps using it lose access until the check finishes.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Verify…") { prepare() }.disabled(running || checking)
                if running || checking {
                    ProgressView().controlSize(.small)
                    Text(running ? "Verifying… large volumes can take a few minutes." : "Checking which apps use it…").foregroundStyle(.secondary)
                }
            }
            if let result, !running {
                Label(result.ok ? "No problems found" : "Problems found",
                      systemImage: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(result.ok ? .green : .orange)
                if !result.summary.isEmpty {
                    Text(result.summary).font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
                }
                Text("Checked \(result.date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                if !result.ok {
                    HStack {
                        Text("FastGlance doesn't repair volumes. Back up what you need, then use First Aid in Disk Utility.")
                            .font(.caption)
                        Button("Open Disk Utility") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                        }
                    }
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Verify \(device.name)?", isPresented: $confirm) {
            Button("Verify") { disks.verify(device) }
        } message: {
            Text(message)
        }
    }

    private var message: String {
        var parts: [String] = []
        if !users.isEmpty { parts.append("In use by \(users.joined(separator: ", ")).") }
        parts.append(users.isEmpty
                     ? "It will be unmounted during the check. Nothing on it is changed."
                     : "It will be unmounted during the check; save your work in those apps first. Nothing on it is changed.")
        return parts.joined(separator: " ")
    }

    private func prepare() {
        guard disks.isMounted(device) else { users = []; confirm = true; return }
        checking = true
        disks.users(of: device) { found in
            users = found
            checking = false
            confirm = true
        }
    }
}

/// Live read/write throughput of the physical disk, from the block storage driver's counters. Samples only while shown.
struct DiskActivityTool: View {
    let bsd: String
    @State private var last: (date: Date, stats: Stats)?
    @State private var rates: (read: Double, write: Double, readOps: Double, writeOps: Double)?
    @State private var totals: Stats?

    struct Stats {
        var read = 0, written = 0, readOps = 0, writeOps = 0
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Group {
                if let totals {
                    InfoGrid(rows: [
                        InfoRow("Reading", rates.map { "\(Util.bytes(Int($0.read)))/s · \(Int($0.readOps)) ops/s" } ?? "…"),
                        InfoRow("Writing", rates.map { "\(Util.bytes(Int($0.write)))/s · \(Int($0.writeOps)) ops/s" } ?? "…"),
                        InfoRow("Read since attached", Util.bytes(totals.read)),
                        InfoRow("Written since attached", Util.bytes(totals.written)),
                    ])
                } else {
                    Text("This disk doesn't report activity counters.").foregroundStyle(.secondary)
                }
            }
            .task(id: ctx.date) { sample() }
        }
    }

    private func sample() {
        guard let s = Self.stats(bsd) else { totals = nil; return }
        let now = Date()
        if let last {
            let dt = max(now.timeIntervalSince(last.date), 0.1)
            rates = (Double(s.read - last.stats.read) / dt, Double(s.written - last.stats.written) / dt,
                     Double(s.readOps - last.stats.readOps) / dt, Double(s.writeOps - last.stats.writeOps) / dt)
        }
        last = (now, s)
        totals = s
    }

    /// IOMedia for the whole disk → its IOBlockStorageDriver parent → "Statistics".
    static func stats(_ bsd: String) -> Stats? {
        var entry = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard entry != 0 else { return nil }
        while entry != 0 {
            if IOObjectConformsTo(entry, "IOBlockStorageDriver") != 0 {
                defer { IOObjectRelease(entry) }
                guard let dict = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { return nil }
                func n(_ k: String) -> Int { (dict[k] as? NSNumber)?.intValue ?? 0 }
                return Stats(read: n("Bytes (Read)"), written: n("Bytes (Write)"), readOps: n("Operations (Read)"), writeOps: n("Operations (Write)"))
            }
            var parent: io_registry_entry_t = 0
            let ok = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS
            IOObjectRelease(entry)
            entry = ok ? parent : 0
        }
        return nil
    }
}
