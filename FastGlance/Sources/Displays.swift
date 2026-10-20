import AppKit
import SwiftUI
import CoreGraphics

@MainActor final class DisplaySource: DeviceSource {
    let prefix = "display"
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []
    private var ids: [String: CGDirectDisplayID] = [:]

    // DDC for external monitors: services per display, cached values, coalesced writes.
    private var ddc: [CGDirectDisplayID: CFTypeRef] = [:]
    private var ddcValues: [CGDirectDisplayID: [UInt8: (current: UInt16, max: UInt16)]] = [:]
    private var ddcPending: [String: UInt16] = [:]
    private let ddcQueue = DispatchQueue(label: "FastGlance.ddc")

    // Brightness sync: external monitors follow the built-in display.
    private var lastMaster: Float?
    private var lastWritten: [CGDirectDisplayID: Double] = [:]
    static let offsets = [-0.3, -0.2, -0.1, 0, 0.1, 0.2, 0.3]

    func start() {
        _ = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncBrightness() }
        }
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
        for d in Self.online().sorted(by: { CGDisplayUnitNumber($0) < CGDisplayUnitNumber($1) }) {
            let builtin = CGDisplayIsBuiltin(d) != 0
            var id = builtin ? "display:builtin" : "display:\(CGDisplayVendorNumber(d)):\(CGDisplayModelNumber(d)):\(CGDisplaySerialNumber(d))"
            // Identical monitors without a serial number would collide; the later one also gets its unit number.
            // unit numbers follow the port, so swapping cables swaps the two monitors' pins and offsets.
            if nextIDs[id] != nil { id += ":\(CGDisplayUnitNumber(d))" }
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
        if next != devices { devices = next; onChange?(); refreshDDC() }
    }

    private func refreshDDC() {
        let externals = Self.online().filter { CGDisplayIsBuiltin($0) == 0 }.sorted { CGDisplayUnitNumber($0) < CGDisplayUnitNumber($1) }
        let services = DDC.externalServices()
        let ids = externals.map { DDC.Identity(vendor: Int(CGDisplayVendorNumber($0)), product: Int(CGDisplayModelNumber($0)),
                                               serial: Int(CGDisplaySerialNumber($0))) }
        ddc = Dictionary(uniqueKeysWithValues: DDC.pair(displays: ids, services: services.map(\.identity)).map {
            (externals[$0.key], services[$0.value].ref)
        })
        let targets = ddc
        ddcQueue.async {
            var values: [CGDirectDisplayID: [UInt8: (current: UInt16, max: UInt16)]] = [:]
            for (display, svc) in targets {
                for code in [DDC.brightness, DDC.contrast, DDC.volume, DDC.input] {
                    if let v = DDC.read(svc, code) { values[display, default: [:]][code] = v }
                }
            }
            let snapshot = values
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.ddcValues = snapshot
                    self.lastMaster = nil  // push the current brightness to newly found monitors
                    self.onChange?()
                }
            }
        }
    }

    private func ddcSet(_ d: CGDirectDisplayID, _ code: UInt8, _ value: UInt16) {
        ddcValues[d]?[code]?.current = value
        let key = "\(d)-\(code)"
        let alreadyQueued = ddcPending[key] != nil
        ddcPending[key] = value
        guard !alreadyQueued, let svc = ddc[d] else { return }
        // A slider fires many values; only the latest one is sent.
        ddcQueue.async {
            usleep(40_000)
            let v = DispatchQueue.main.sync { MainActor.assumeIsolated { self.ddcPending.removeValue(forKey: key) } }
            if let v { DDC.write(svc, code, v) }
        }
    }

    private func ddcSlider(_ device: Device, _ d: CGDirectDisplayID, _ code: UInt8, _ title: String, _ symbol: String) -> DeviceControl? {
        guard let v = ddcValues[d]?[code], v.max > 0 else { return nil }
        return DeviceControl(id: "\(device.id)|ddc\(code)", title: title, symbol: symbol, kind: .slider(
            get: { [weak self] in Double(self?.ddcValues[d]?[code]?.current ?? v.current) / Double(v.max) },
            set: { [weak self] in self?.ddcSet(d, code, UInt16(($0 * Double(v.max)).rounded())) }))
    }

    private func offset(_ deviceID: String) -> Double {
        UserDefaults.standard.double(forKey: "brightnessOffset.\(deviceID)")
    }

    /// Polls the built-in brightness (cheap) and mirrors real changes, rate-limited so DDC writes stay rare.
    private func syncBrightness() {
        guard ids.count > 1, UserDefaults.standard.bool(forKey: Prefs.syncBrightness),
              let builtin = ids["display:builtin"], let master = DisplayBrightness.get(builtin) else { return }
        if let last = lastMaster, abs(last - master) < 0.01 { return }
        lastMaster = master
        for (key, d) in ids where d != builtin {
            let target = min(max(Double(master) + offset(key), 0), 1)
            if let written = lastWritten[d], abs(written - target) < 0.02 { continue }
            if DisplayBrightness.get(d) != nil {
                DisplayBrightness.set(d, Float(target))
            } else if let v = ddcValues[d]?[DDC.brightness], v.max > 0 {
                ddcSet(d, DDC.brightness, UInt16((target * Double(v.max)).rounded()))
            } else {
                continue
            }
            lastWritten[d] = target
        }
    }

    private func currentInput(_ d: CGDirectDisplayID) -> UInt16? {
        ddcValues[d]?[DDC.input].map { $0.current & 0xFF }
    }

    func actions(for device: Device) -> [DeviceAction] {
        guard let d = ids[device.id] else { return [] }
        // Already-active choices stay listed (last, with a checkmark) so a pin to them never goes missing.
        var out: [DeviceAction] = []
        var active: [DeviceAction] = []
        if ids.count > 1 {
            let isMain = CGDisplayIsMain(d) != 0
            let main = DeviceAction(device, "main", "Make Main Display", isMain ? "checkmark.circle" : "menubar.rectangle") { [weak self] in self?.makeMain(d) }
            if isMain { active.append(main) } else { out.append(main) }
            let mirrored = CGDisplayMirrorsDisplay(d) != kCGNullDirectDisplay
            out.append(DeviceAction(device, "mirror", mirrored ? "Stop Mirroring" : "Mirror Main Display", "rectangle.on.rectangle") { [weak self] in
                self?.setMirror(d, on: !mirrored)
            })
        }
        if let current = currentInput(d) {  // a successful read, not just an AV service: DDC really works
            for input in DDC.inputs {
                let isCurrent = input.code == current
                let a = DeviceAction(device, "input\(input.code)", "Switch to \(input.name)", isCurrent ? "checkmark.circle" : "arrow.left.arrow.right.square") { [weak self] in
                    self?.ddcSet(d, DDC.input, input.code)
                }
                if isCurrent { active.append(a) } else { out.append(a) }
            }
        }
        out.append(DeviceAction(device, "settings", "Displays Settings…", "gearshape") {
            Util.open("x-apple.systempreferences:com.apple.Displays-Settings.extension")
        })
        return out + active
    }

    func controls(for device: Device) -> [DeviceControl] {
        guard let d = ids[device.id] else { return [] }
        var out: [DeviceControl] = []
        if DisplayBrightness.get(d) != nil {
            out.append(DeviceControl(id: "\(device.id)|brightness", title: "Brightness", symbol: "sun.max", kind: .slider(
                get: { Double(DisplayBrightness.get(d) ?? 0) },
                set: { DisplayBrightness.set(d, Float($0)) })))
        } else if let c = ddcSlider(device, d, DDC.brightness, "Brightness", "sun.max") {
            out.append(c)
        }
        let canSync = CGDisplayIsBuiltin(d) == 0 && (DisplayBrightness.get(d) != nil || ddcValues[d]?[DDC.brightness] != nil)
        if canSync && UserDefaults.standard.bool(forKey: Prefs.syncBrightness) {
            let key = "brightnessOffset.\(device.id)"
            out.append(DeviceControl(id: "\(device.id)|syncoffset", title: "Sync offset", symbol: "sun.max.trianglebadge.exclamationmark", kind: .picker(
                options: Self.offsets.map { $0 == 0 ? "Same as Mac" : String(format: "%+.0f%%", $0 * 100) },
                get: { Self.offsets.firstIndex(of: UserDefaults.standard.double(forKey: key)) ?? 3 },
                set: { [weak self] in
                    UserDefaults.standard.set(Self.offsets[$0], forKey: key)
                    self?.lastMaster = nil
                    self?.lastWritten[d] = nil
                })))
        }
        out += [ddcSlider(device, d, DDC.contrast, "Contrast", "circle.lefthalf.filled"),
                ddcSlider(device, d, DDC.volume, "Speaker volume", "speaker.wave.2")].compactMap { $0 }
        if currentInput(d) != nil {
            out.append(DeviceControl(id: "\(device.id)|input", title: "Input", symbol: "arrow.left.arrow.right.square", kind: .picker(
                options: DDC.inputs.map(\.name),
                get: { [weak self] in DDC.inputs.firstIndex { $0.code == self?.currentInput(d) } ?? 0 },
                set: { [weak self] in self?.ddcSet(d, DDC.input, DDC.inputs[$0].code) })))
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

    func tools(for device: Device) -> [DeviceTool] {
        guard let d = ids[device.id] else { return [] }
        let screen = Self.screen(d)
        return [DeviceTool(id: "display.patterns", title: "Test Patterns", symbol: "square.grid.3x3.middle.filled") {
            AnyView(TestPatternTool(screen: screen))
        }]
    }

    func sections(for device: Device) -> [InfoSection] {
        guard let d = ids[device.id], let mode = CGDisplayCopyDisplayMode(d) else { return [] }
        let screen = Self.screen(d)
        let native = Self.nativeWidthHeight(d) ?? (mode.pixelWidth, mode.pixelHeight)
        var panel = [InfoRow("Native resolution", "\(native.0) × \(native.1) px"),
                     InfoRow("Rendered at", "\(mode.pixelWidth) × \(mode.pixelHeight) px"),
                     InfoRow("Looks like", "\(mode.width) × \(mode.height)"),
                     InfoRow("HiDPI", mode.pixelWidth > mode.width ? String(format: "Yes (%g×)", Double(mode.pixelWidth) / Double(mode.width)) : "No")]
        if let ppi = Self.ppi(pixels: native.0, mm: CGDisplayScreenSize(d).width) {
            panel.append(InfoRow("Pixel density", String(format: "%.0f ppi", ppi)))
        }
        var color: [InfoRow] = []
        if let screen {
            let fastest = (1 / screen.minimumRefreshInterval).rounded(), slowest = (1 / screen.maximumRefreshInterval).rounded()
            panel.append(InfoRow("Refresh", fastest > slowest ? "Adaptive, \(Int(slowest))–\(Int(fastest)) Hz" : "\(Int(fastest)) Hz"))
            if screen.safeAreaInsets.top > 0 { panel.append(InfoRow("Camera housing", "Yes, \(Int(screen.safeAreaInsets.top)) pt")) }
            let potential = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
            color = [InfoRow("Colour space", screen.colorSpace?.localizedName ?? "—"),
                     InfoRow("Wide colour (P3)", screen.canRepresent(.p3) ? "Yes" : "No"),
                     InfoRow("Bits per channel", "\(screen.depth.bitsPerSample)"),
                     InfoRow("Extended range (EDR)", Self.edrText(potential: Double(potential)))]
            if potential > 1 {
                color.append(InfoRow("EDR headroom now", String(format: "%.1f×", screen.maximumExtendedDynamicRangeColorComponentValue)))
                if screen.maximumReferenceExtendedDynamicRangeColorComponentValue > 0 { color.append(InfoRow("Reference mode", "On")) }
            }
        }
        let current = (mode.width, mode.height, Int(mode.refreshRate.rounded()))
        let modes = Self.modes(d).map { m in
            let hz = Int(m.refreshRate.rounded())
            let notes = [hz > 0 ? "\(hz) Hz" : nil, m.pixelWidth > m.width ? "HiDPI" : nil,
                         (m.width, m.height, hz) == current ? "Current" : nil].compactMap { $0 }
            return InfoRow("\(m.width) × \(m.height)", notes.joined(separator: " · "))
        }
        return [InfoSection(title: "Panel", rows: panel)]
            + (color.isEmpty ? [] : [InfoSection(title: "Colour & HDR", rows: color)])
            + (modes.isEmpty ? [] : [InfoSection(title: "Modes (\(modes.count))", rows: modes)])
    }

    static func screen(_ d: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == d }
    }

    /// The panel's own pixel grid: the mode IOKit flags native (kDisplayModeNativeFlag, not exported to Swift).
    private static func nativeWidthHeight(_ d: CGDirectDisplayID) -> (Int, Int)? {
        allModes(d).filter { $0.ioFlags & 0x0200_0000 != 0 }.max { $0.pixelWidth < $1.pixelWidth }.map { ($0.pixelWidth, $0.pixelHeight) }
    }

    nonisolated static func ppi(pixels: Int, mm: Double) -> Double? {
        mm > 1 && pixels > 0 ? Double(pixels) / (mm / 25.4) : nil
    }

    /// EDR headroom: how much brighter than SDR white HDR content may go. XDR panels reach 16×; other Macs
    /// get a little from spare backlight, and it shrinks as brightness goes up.
    nonisolated static func edrText(potential: Double) -> String {
        potential > 1.01 ? String(format: "Up to %.1f× SDR white", potential) : "None (SDR only)"
    }

    /// Every mode, HiDPI ones included: without the option the list has only 1:1 modes, and not the scaled one in use.
    private static func allModes(_ d: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return CGDisplayCopyAllDisplayModes(d, options) as? [CGDisplayMode] ?? []
    }

    /// Usable modes, largest first, one per resolution/refresh pair; the HiDPI variant wins over its blurry 1:1 twin.
    private static func modes(_ d: CGDirectDisplayID) -> [CGDisplayMode] {
        var seen = Set<String>()
        return allModes(d).filter { $0.isUsableForDesktopGUI() }
            .sorted { ($0.width, $0.refreshRate, $0.pixelWidth) > ($1.width, $1.refreshRate, $1.pixelWidth) }
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
