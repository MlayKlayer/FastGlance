import UserNotifications
import Foundation

@MainActor final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var lowWarned = Set<String>()
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

    func handle(old: [Device], new: [Device]) {
        let d = UserDefaults.standard
        let muted = Prefs.kinds(Prefs.mutedKinds)
        let wasConnected = Set(old.filter(\.isConnected).map(\.id))
        let isConnected = Set(new.filter(\.isConnected).map(\.id))

        if Date() > quietUntil, d.bool(forKey: Prefs.notifyConnections) {
            for dev in new where dev.isConnected && !wasConnected.contains(dev.id) && !muted.contains(dev.kind) {
                post("\(dev.name) connected", dev.kind.title)
            }
            for dev in old where dev.isConnected && !isConnected.contains(dev.id) && !muted.contains(dev.kind) {
                post("\(dev.name) disconnected", dev.kind.title)
            }
        }

        let threshold = d.integer(forKey: Prefs.batteryThreshold)
        for dev in new where dev.isConnected {
            guard let low = dev.lowestBattery else { continue }
            if low <= threshold, !lowWarned.contains(dev.id) {
                lowWarned.insert(dev.id)
                if d.bool(forKey: Prefs.notifyBattery) { post("\(dev.name) battery low", "\(low)% remaining") }
            } else if low > threshold + 5 {
                lowWarned.remove(dev.id)  // charged again; warn on the next drop
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])  // show even while the popover has focus
    }
}
