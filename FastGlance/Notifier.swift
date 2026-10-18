import UserNotifications
import Foundation

/// What an action is doing or how it ended, shown under the device in the menu.
struct ActionStatus {
    let id = UUID()
    let text: String
    var failed = false
    var retry: (() -> Void)?
}

@MainActor final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Keyed by device id.
    @Published private(set) var statuses: [String: ActionStatus] = [:]
    var isMenuOpen: () -> Bool = { false }

    private var lowWarned = Set<String>()
    private var linkWarned = Set<String>()
    private var events: [(device: Device, connected: Bool)] = []
    private var quietUntil = Date().addingTimeInterval(6)  // sources report their initial state at launch

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error { NSLog("FastGlance: notification auth failed: \(error)") }
        }
    }

    func post(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Text ending in "…" means still running; anything else clears itself after a few seconds.
    /// With the menu closed (a hotkey, option-click) failures, and results that are the point of the action, go out as notifications.
    func report(_ deviceID: String, _ name: String, _ text: String, failed: Bool = false, notify: Bool = false, retry: (() -> Void)? = nil) {
        let busy = text.hasSuffix("…")
        if !busy, failed || notify, !isMenuOpen() { post(name, text) }
        let status = ActionStatus(text: text, failed: failed, retry: retry)
        statuses[deviceID] = status
        DispatchQueue.main.asyncAfter(deadline: .now() + (busy ? 30 : failed ? 10 : 5)) { [weak self] in
            if self?.statuses[deviceID]?.id == status.id { self?.statuses[deviceID] = nil }
        }
    }

    func handle(old: [Device], new: [Device]) {
        let d = UserDefaults.standard
        let muted = Prefs.kinds(Prefs.mutedKinds)
        let wasConnected = Set(old.filter(\.isConnected).map(\.id))
        let isConnected = Set(new.filter(\.isConnected).map(\.id))

        if Date() > quietUntil, d.bool(forKey: Prefs.notifyConnections) {
            let before = events.count
            events += new.filter { $0.isConnected && !wasConnected.contains($0.id) && !muted.contains($0.kind) }.map { ($0, true) }
            events += old.filter { $0.isConnected && !isConnected.contains($0.id) && !muted.contains($0.kind) }.map { ($0, false) }
            // A dock brings many devices at once: collect for a moment, then say it in one notification.
            if before == 0 && !events.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    for n in Self.summarize(events) { post(n.title, n.body) }
                    events = []
                }
            }
        }

        // Slow-link warnings: once per device per launch, only for devices plugged in while we're running.
        for dev in new where dev.isConnected && dev.warning != nil && !wasConnected.contains(dev.id) && Date() > quietUntil {
            if linkWarned.insert(dev.id).inserted { post("\(dev.name) is running slow", dev.warning!) }
        }

        let threshold = d.integer(forKey: Prefs.batteryThreshold)
        for dev in new where dev.isConnected {
            guard let low = dev.lowestBattery else { continue }
            if low <= threshold, !lowWarned.contains(dev.id) {
                lowWarned.insert(dev.id)
                if d.bool(forKey: Prefs.notifyBattery) {
                    post(dev.kind == .printer ? "\(dev.name) is low on ink" : "\(dev.name) battery low", "\(low)% remaining")
                }
            } else if low > threshold + 5 {
                lowWarned.remove(dev.id)  // charged again; warn on the next drop
            }
        }
    }

    /// One notification per device, or one for the lot when more than two changed together.
    /// A device that came and went (or went and came back) inside the window says nothing.
    nonisolated static func summarize(_ events: [(device: Device, connected: Bool)]) -> [(title: String, body: String)] {
        var first: [String: Bool] = [:], last: [String: (device: Device, connected: Bool)] = [:], order: [String] = []
        for e in events {
            if first[e.device.id] == nil { first[e.device.id] = e.connected; order.append(e.device.id) }
            last[e.device.id] = e
        }
        let settled = order.compactMap { id in last[id].flatMap { $0.connected == first[id] ? $0 : nil } }
        func group(_ connected: Bool, _ verb: String) -> [(title: String, body: String)] {
            let list = settled.filter { $0.connected == connected }.map(\.device)
            return list.count > 2 ? [("\(list.count) devices \(verb)", list.map(\.name).joined(separator: ", "))]
                : list.map { ("\($0.name) \(verb)", $0.kind.title) }
        }
        return group(true, "connected") + group(false, "disconnected")
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])  // show even while the popover has focus
    }
}
