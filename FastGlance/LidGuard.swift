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
    /// BSD names we unmounted, to mount back if still plugged in.
    private var unmounted: [String] = []
    private var failures: [String] = []
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
        unmounted = []
        failures = []
        guard !targets.isEmpty else { return done() }

        let group = DispatchGroup()
        generation += 1
        let gen = generation
        pendingDone = done
        for (url, name) in targets {
            group.enter()
            let bsd = USBDoctor.bsdName(forVolume: url)
            // Plain unmount, never forced: an open file means the disk stays mounted and we say so on wake.
            FileManager.default.unmountVolume(at: url, options: []) { error in
                DispatchQueue.main.async {
                    if let error { self.failures.append("\(name): \(error.localizedDescription)") }
                    else if let bsd { self.unmounted.append(bsd) }
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
        guard !failures.isEmpty else { return }
        Notifier.shared.post("Some disks stayed mounted during sleep", failures.joined(separator: "\n"))
        failures = []
    }

    private func remount() {
        let names = unmounted
        unmounted = []
        guard !names.isEmpty else { return }
        // Give USB a moment to come back after wake; disks that were unplugged just fail quietly.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            for bsd in names { _ = Util.output("/usr/sbin/diskutil", ["mount", bsd]) }
        }
    }
}
