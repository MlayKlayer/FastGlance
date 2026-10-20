import SwiftUI

enum DeviceKind: String, Codable, CaseIterable, Identifiable {
    case internet
    case headphones, speaker, mouse, keyboard, trackpad, gamepad, phone, watch, computer, bluetooth
    case audio, storage, display, camera, usb
    case printer, media, smartHome, router, network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .internet: "Internet"
        case .headphones: "Headphones"
        case .speaker: "Speakers"
        case .mouse: "Mice"
        case .keyboard: "Keyboards"
        case .trackpad: "Trackpads"
        case .gamepad: "Game Controllers"
        case .phone: "Phones & Tablets"
        case .watch: "Watches"
        case .computer: "Computers"
        case .bluetooth: "Other Bluetooth"
        case .audio: "Audio"
        case .storage: "Storage"
        case .display: "Displays"
        case .camera: "Cameras"
        case .usb: "Other USB"
        case .printer: "Printers"
        case .media: "TVs & AirPlay"
        case .smartHome: "Smart Home"
        case .router: "Routers"
        case .network: "Network Devices"
        }
    }

    var symbol: String {
        switch self {
        case .internet: "globe"
        case .headphones: "headphones"
        case .speaker: "hifispeaker"
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .gamepad: "gamecontroller"
        case .phone: "iphone"
        case .watch: "applewatch"
        case .computer: "laptopcomputer"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .audio: "speaker.wave.2"
        case .storage: "externaldrive"
        case .display: "display"
        case .camera: "web.camera"
        case .usb: "cable.connector"
        case .printer: "printer"
        case .media: "tv"
        case .smartHome: "house"
        case .router: "wifi.router"
        case .network: "network"
        }
    }

    var order: Int { Self.allCases.firstIndex(of: self)! }

    static func grouped(_ devices: [Device]) -> [(kind: DeviceKind, devices: [Device])] {
        Dictionary(grouping: devices, by: \.kind).sorted { $0.key.order < $1.key.order }.map { ($0.key, $0.value) }
    }
}

struct Battery: Hashable {
    var label: String  // "" for a single battery, otherwise "L", "R", "Case"
    var percent: Int
}

struct InfoRow: Hashable {
    let key: String
    let value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }
}

struct Device: Identifiable, Hashable {
    /// Stable across launches, prefixed with the source ("bt:", "usb:", ...).
    let id: String
    var name: String
    var kind: DeviceKind
    var isConnected: Bool
    var status: String? = nil
    var batteries: [Battery] = []
    var info: [InfoRow] = []
    var raw: [InfoRow] = []
    var lastConnected: Date? = nil
    /// Overrides the kind's icon, e.g. a microphone among audio devices.
    var symbol: String? = nil
    /// Something the user should fix, e.g. a fast drive stuck on a USB 2 cable.
    var warning: String? = nil
    /// Hidden from the menu and its notifications, still listed in the device window.
    var isHidden = false

    var icon: String { symbol ?? kind.symbol }

    /// The AirPods case is excluded: a low case shouldn't raise alerts while the buds are full.
    var lowestBattery: Int? { batteries.filter { $0.label != "Case" }.map(\.percent).min() }
}

struct DeviceAction: Identifiable {
    let id: String  // "<deviceID>|<key>", stable so it can be pinned
    let title: String
    let symbol: String
    let run: () -> Void
}

extension DeviceAction {
    init(_ device: Device, _ key: String, _ title: String, _ symbol: String, run: @escaping () -> Void) {
        self.init(id: "\(device.id)|\(key)", title: title, symbol: symbol, run: run)
    }
}

struct DeviceControl: Identifiable {
    enum Kind {
        case slider(get: () -> Double, set: (Double) -> Void)
        case toggle(get: () -> Bool, set: (Bool) -> Void)
        case picker(options: [String], get: () -> Int, set: (Int) -> Void)
    }
    let id: String
    let title: String
    let symbol: String
    let kind: Kind
}

/// A titled group of read-only rows in the inspector's Advanced tab.
struct InfoSection: Identifiable {
    let title: String
    let rows: [InfoRow]
    var id: String { title }
}

/// A live or interactive tool in the inspector's Controls & Diagnostics tab (a print queue, a latency monitor).
/// Tools are collapsible; a collapsed tool's view is never built, so it does no work.
struct DeviceTool: Identifiable {
    /// Per kind of tool, not per device ("printer.jobs"), so the expanded state carries over between devices.
    let id: String
    let title: String
    let symbol: String
    let view: () -> AnyView
}

@MainActor protocol DeviceSource: AnyObject {
    var prefix: String { get }
    var devices: [Device] { get }
    var onChange: (() -> Void)? { get set }
    func start()
    /// First action is the primary one shown inline in the menu.
    func actions(for device: Device) -> [DeviceAction]
    func controls(for device: Device) -> [DeviceControl]
    func sections(for device: Device) -> [InfoSection]
    func tools(for device: Device) -> [DeviceTool]
}

extension DeviceSource {
    func controls(for device: Device) -> [DeviceControl] { [] }
    func sections(for device: Device) -> [InfoSection] { [] }
    func tools(for device: Device) -> [DeviceTool] { [] }
}
