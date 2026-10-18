import AppKit
import CoreGraphics

@MainActor final class DisplaySource: DeviceSource {
    let prefix = "display"
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []
    private var ids: [String: CGDirectDisplayID] = [:]

    func start() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    private static func online() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var list = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &list, &count)
        return Array(list.prefix(Int(count)))
    }

    func reload() {
        let names = Dictionary(NSScreen.screens.compactMap { s in
            (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { ($0, s.localizedName) }
        }, uniquingKeysWith: { a, _ in a })
        var next: [Device] = []
        var nextIDs: [String: CGDirectDisplayID] = [:]
        for d in Self.online() {
            let builtin = CGDisplayIsBuiltin(d) != 0
            let id = builtin ? "display:builtin" : "display:\(CGDisplayVendorNumber(d)):\(CGDisplayModelNumber(d)):\(CGDisplaySerialNumber(d))"
            nextIDs[id] = d
            let mode = CGDisplayCopyDisplayMode(d)
            let res = mode.map { "\($0.width) × \($0.height)" } ?? "—"
            let hz = mode.map { $0.refreshRate > 0 ? "\(Int($0.refreshRate.rounded())) Hz" : "" } ?? ""
            let mirrored = CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay
            var status = [res, hz].filter { !$0.isEmpty }.joined(separator: " @ ")
            if CGDisplayIsMain(d) != 0 { status += " · Main" }
            if mirrored { status += " · Mirrored" }
            let mm = CGDisplayScreenSize(d)
            let inches = (mm.width * mm.width + mm.height * mm.height).squareRoot() / 25.4
            next.append(Device(
                id: id, name: names[d] ?? (builtin ? "Built-in Display" : "Display"), kind: .display, isConnected: true,
                status: status,
                info: [InfoRow("Resolution", res), InfoRow("Refresh rate", hz.isEmpty ? "—" : hz),
                       InfoRow("Size", inches > 1 ? String(format: "%.1f\"", inches) : "—"),
                       InfoRow("Built-in", builtin ? "Yes" : "No"),
                       InfoRow("Rotation", "\(Int(CGDisplayRotation(d)))°")],
                raw: [InfoRow("Display ID", "\(d)"), InfoRow("Vendor", "\(CGDisplayVendorNumber(d))"),
                      InfoRow("Model", "\(CGDisplayModelNumber(d))"), InfoRow("Serial", "\(CGDisplaySerialNumber(d))")]))
        }
        ids = nextIDs
        if next != devices { devices = next; onChange?() }
    }

    func actions(for device: Device) -> [DeviceAction] {
        guard let d = ids[device.id] else { return [] }
        var out: [DeviceAction] = []
        if CGDisplayIsMain(d) == 0 {
            out.append(DeviceAction(device, "main", "Make Main Display", "menubar.rectangle") { [weak self] in self?.makeMain(d) })
        }
        if ids.count > 1 {
            let mirrored = CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay
            out.append(DeviceAction(device, "mirror", mirrored ? "Stop Mirroring" : "Mirror Main Display", "rectangle.on.rectangle") { [weak self] in
                self?.setMirror(d, on: !mirrored)
            })
        }
        out.append(DeviceAction(device, "settings", "Displays Settings…", "gearshape") {
            Util.open("x-apple.systempreferences:com.apple.Displays-Settings.extension")
        })
        return out
    }

    func controls(for device: Device) -> [DeviceControl] {
        guard let d = ids[device.id] else { return [] }
        var out: [DeviceControl] = []
        if DisplayBrightness.get(d) != nil {
            out.append(DeviceControl(id: "\(device.id)|brightness", title: "Brightness", symbol: "sun.max", kind: .slider(
                get: { Double(DisplayBrightness.get(d) ?? 0) },
                set: { DisplayBrightness.set(d, Float($0)) })))
        }
        let modes = Self.modes(d)
        if modes.count > 1 {
            out.append(DeviceControl(id: "\(device.id)|mode", title: "Resolution", symbol: "aspectratio", kind: .picker(
                options: modes.map { "\($0.width) × \($0.height)" + ($0.refreshRate > 0 ? " @ \(Int($0.refreshRate.rounded())) Hz" : "") },
                get: {
                    guard let cur = CGDisplayCopyDisplayMode(d) else { return 0 }
                    return modes.firstIndex { $0.width == cur.width && $0.height == cur.height && $0.refreshRate == cur.refreshRate } ?? 0
                },
                set: { CGDisplaySetDisplayMode(d, modes[$0], nil) })))
        }
        return out
    }

    /// Usable modes, largest first, one per resolution/refresh pair.
    private static func modes(_ d: CGDirectDisplayID) -> [CGDisplayMode] {
        let all = CGDisplayCopyAllDisplayModes(d, nil) as? [CGDisplayMode] ?? []
        var seen = Set<String>()
        return all.filter { $0.isUsableForDesktopGUI() }
            .sorted { ($0.width, $0.refreshRate) > ($1.width, $1.refreshRate) }
            .filter { seen.insert("\($0.width)x\($0.height)@\(Int($0.refreshRate))").inserted }
    }

    private func makeMain(_ d: CGDirectDisplayID) {
        // The main display is the one at the origin; shift every display by the new main's offset.
        let origin = CGDisplayBounds(d).origin
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for other in Self.online() where CGDisplayMirrorsDisplay(other) == kCGNullDirectDisplay {
            let b = CGDisplayBounds(other).origin
            CGConfigureDisplayOrigin(config, other, Int32(b.x - origin.x), Int32(b.y - origin.y))
        }
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    private func setMirror(_ d: CGDirectDisplayID, on: Bool) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayMirrorOfDisplay(config, d, on ? CGMainDisplayID() : kCGNullDirectDisplay)
        CGCompleteDisplayConfiguration(config, .permanently)
    }
}
