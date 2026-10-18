import GameController
import CoreHaptics

/// Extra controls for Bluetooth game controllers, matched to the Bluetooth row by name.
@MainActor enum Gamepads {
    static let lightColors: [(name: String, r: Float, g: Float, b: Float)] = [
        ("Blue", 0, 0.25, 1), ("Red", 1, 0, 0), ("Green", 0, 1, 0.1), ("Purple", 0.6, 0, 1),
        ("Orange", 1, 0.4, 0), ("White", 1, 1, 1), ("Off", 0, 0, 0),
    ]
    private static var engines: [CHHapticEngine] = []

    static func start(onChange: @escaping () -> Void) {
        GCController.shouldMonitorBackgroundEvents = true
        for name in [NSNotification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in onChange() }
        }
    }

    static func controller(named name: String) -> GCController? {
        GCController.controllers().first { $0.vendorName == name }
    }

    static func battery(_ c: GCController) -> [Battery] {
        guard let b = c.battery, b.batteryState != .unknown else { return [] }
        return [Battery(label: "", percent: Int((b.batteryLevel * 100).rounded()))]
    }

    static func controls(_ c: GCController, deviceID: String) -> [DeviceControl] {
        guard let light = c.light else { return [] }
        return [DeviceControl(id: "\(deviceID)|light", title: "Light", symbol: "lightbulb", kind: .picker(
            options: lightColors.map(\.name),
            get: {
                let cur = light.color
                return lightColors.firstIndex { abs($0.r - cur.red) + abs($0.g - cur.green) + abs($0.b - cur.blue) < 0.1 } ?? 0
            },
            set: { i in let c = lightColors[i]; light.color = GCColor(red: c.r, green: c.g, blue: c.b) }))]
    }

    static func vibrate(_ c: GCController) {
        guard let engine = c.haptics?.createEngine(withLocality: .default) else {
            Notifier.shared.post("No vibration", "\(c.vendorName ?? "This controller") doesn't support haptics on macOS.")
            return
        }
        do {
            try engine.start()
            let event = CHHapticEvent(eventType: .hapticContinuous,
                                      parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)],
                                      relativeTime: 0, duration: 0.6)
            try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: 0)
            engines.append(engine)  // keep alive until the pulse ends
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                engine.stop()
                engines.removeAll { $0 === engine }
            }
        } catch {
            Notifier.shared.post("Vibration failed", error.localizedDescription)
        }
    }
}
