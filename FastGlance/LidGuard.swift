import Foundation
import IOKit
import IOKit.pwr_mgt

/// Unmounts external disks when the Mac goes to sleep because the lid closed, and mounts them back on wake.
/// macOS waits for us (up to ~30 s) before sleeping, so the unmount always finishes first.
@MainActor final class LidGuard {
    // iokit_common_msg() values; the C macros aren't imported into Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let disks: DiskSource
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var ledger = SleepLedger()
    private var pendingDone: (() -> Void)?
    private var generation = 0

    init(disks: DiskSource) {
        self.disks = disks
    }

    func start() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(ctx, &notifyPort, { ctx, _, message, argument in
            let me = Unmanaged<LidGuard>.fromOpaque(ctx!).takeUnretainedValue()
            let notificationID = Int(bitPattern: argument)
            MainActor.assumeIsolated { me.handle(message, notificationID) }
        }, &notifier)
        guard rootPort != 0, let notifyPort else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(), .commonModes)
    }

    private func handle(_ message: UInt32, _ id: Int) {
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, id)  // never veto sleep
        case Self.systemWillSleep:
            guard UserDefaults.standard.bool(forKey: Prefs.unmountOnLidClose), Self.lidClosed() else {
                IOAllowPowerChange(rootPort, id)
                return
            }
            unmountAll { [weak self] in
                guard let self else { return }
                IOAllowPowerChange(rootPort, id)
            }
        case Self.systemHasPoweredOn:
            reportFailures()
            remount()
        default:
            break
        }
    }

    /// Lid closed and sleeping means a real "closed the laptop", not clamshell mode (which doesn't sleep)
    /// and not Apple menu → Sleep with the lid open.
    nonisolated static func lidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) ?? false
    }

    private func unmountAll(then done: @escaping () -> Void) {
        let targets = disks.localVolumes
        for name in disks.verifyingNames { ledger.failed("\(name): left mounted, Verify was running") }
        guard !targets.isEmpty else { return done() }

        let group = DispatchGroup()
        generation += 1
        let gen = generation
        pendingDone = done
        for (url, name, uuid) in targets {
            group.enter()
            // Plain unmount, never forced and never with a system dialog: a busy disk stays mounted and we say so on wake.
            FileManager.default.unmountVolume(at: url, options: [.withoutUI]) { error in
                DispatchQueue.main.async {
                    if let error { self.ledger.failed("\(name): \(error.localizedDescription)") }
                    else if let uuid { self.ledger.unmounted(uuid) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in self?.finish(gen) }
        // Never hold sleep hostage to a hung disk.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finish(gen) }
    }

    /// Runs once per sleep, whichever comes first: all unmounts done or the timeout.
    private func finish(_ gen: Int) {
        guard gen == generation, let done = pendingDone else { return }
        pendingDone = nil
        done()
    }

    private func reportFailures() {
        let failures = ledger.takeFailures()
        guard !failures.isEmpty else { return }
        Notifier.shared.post("Some disks stayed mounted during sleep", failures.joined(separator: "\n"))
    }

    private func remount() {
        let uuids = ledger.takeRemounts()
        guard !uuids.isEmpty else { return }
        // By volume UUID: BSD names like disk4s1 can change when USB re-enumerates after wake.
        // Give USB a moment to come back; disks that were unplugged just fail quietly.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            for uuid in uuids { _ = Util.output("/usr/sbin/diskutil", ["mount", uuid]) }
        }
    }
}

/// What happened to disks across sleep. Cleared only on full wake, so a dark wake (Power Nap)
/// followed by another sleep message can't forget disks that still need mounting.
struct SleepLedger {
    private(set) var toRemount: [String] = []
    private(set) var failures: [String] = []

    mutating func unmounted(_ uuid: String) { if !toRemount.contains(uuid) { toRemount.append(uuid) } }
    mutating func failed(_ message: String) { failures.append(message) }
    mutating func takeRemounts() -> [String] { defer { toRemount = [] }; return toRemount }
    mutating func takeFailures() -> [String] { defer { failures = [] }; return failures }
}
