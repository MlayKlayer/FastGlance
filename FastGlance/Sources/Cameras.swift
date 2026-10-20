import AVFoundation
import SwiftUI

@MainActor final class CameraSource: DeviceSource {
    let prefix = "camera"
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []
    /// Set by the app: opens a preview window for a camera.
    var openPreview: (AVCaptureDevice) -> Void = { _ in }
    private var cameras: [AVCaptureDevice] = []
    private var observers: [NSKeyValueObservation] = []

    func start() {
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        }
        reload()
    }

    func reload() {
        cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                   mediaType: .video, position: .unspecified).devices
        // "In use" lets you see at a glance which camera an app has open.
        observers = cameras.map {
            $0.observe(\.isInUseByAnotherApplication) { [weak self] _, _ in
                guard let self else { return }
                DispatchQueue.main.async { self.rebuild() }
            }
        }
        rebuild()
    }

    private func rebuild() {
        let next = cameras.map { c in
            Device(id: "camera:\(c.uniqueID)", name: c.localizedName, kind: .camera, isConnected: true,
                   status: c.isInUseByAnotherApplication ? "In use by an app" : "Not in use",
                   info: [InfoRow("Manufacturer", c.manufacturer.isEmpty ? "—" : c.manufacturer),
                          InfoRow("Model", c.modelID),
                          InfoRow("Type", Self.typeName(c.deviceType)),
                          InfoRow("In use", c.isInUseByAnotherApplication ? "Yes" : "No")],
                   raw: [InfoRow("Unique ID", c.uniqueID)])
        }
        if next != devices { devices = next; onChange?() }
    }

    private static func typeName(_ t: AVCaptureDevice.DeviceType) -> String {
        switch t {
        case .builtInWideAngleCamera: "Built-in"
        case .continuityCamera: "Continuity Camera (iPhone)"
        default: "External"
        }
    }

    func sections(for device: Device) -> [InfoSection] {
        guard let c = cameras.first(where: { "camera:\($0.uniqueID)" == device.id }) else { return [] }
        func dims(_ f: AVCaptureDevice.Format) -> CMVideoDimensions { CMVideoFormatDescriptionGetDimensions(f.formatDescription) }
        // One row per resolution and pixel format, largest first; frame rates merged across duplicates.
        var rates: [String: [Double]] = [:]
        var order: [(key: String, pixels: Int32)] = []
        for f in c.formats {
            let d = dims(f)
            let key = "\(d.width) × \(d.height) · \(Self.fourCC(CMFormatDescriptionGetMediaSubType(f.formatDescription)))"
            if rates[key] == nil { order.append((key, d.width * d.height)) }
            rates[key, default: []] += f.videoSupportedFrameRateRanges.flatMap { [$0.minFrameRate, $0.maxFrameRate] }
        }
        let formats = order.sorted { $0.pixels > $1.pixels }.map { e in
            let r = rates[e.key] ?? []
            let lo = Int((r.min() ?? 0).rounded()), hi = Int((r.max() ?? 0).rounded())
            return InfoRow(e.key, lo == hi ? "\(hi) fps" : "\(lo)–\(hi) fps")
        }
        let active = dims(c.activeFormat)
        let caps = [
            InfoRow("Active format", "\(active.width) × \(active.height) · \(Self.fourCC(CMFormatDescriptionGetMediaSubType(c.activeFormat.formatDescription)))"),
            InfoRow("Autofocus", c.isFocusModeSupported(.continuousAutoFocus) || c.isFocusModeSupported(.autoFocus) ? "Yes" : "No"),
            InfoRow("Auto exposure", c.isExposureModeSupported(.continuousAutoExposure) ? "Yes" : "No"),
            InfoRow("Auto white balance", c.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) ? "Yes" : "No"),
            InfoRow("Transport", Self.transportName(FourCharCode(truncatingIfNeeded: c.transportType))),
        ]
        return [InfoSection(title: "Capabilities", rows: caps)] + (formats.isEmpty ? [] : [InfoSection(title: "Formats", rows: formats)])
    }

    nonisolated static func transportName(_ code: FourCharCode) -> String {
        switch fourCC(code) {
        case "bltn": "Built-in"
        case "usb": "USB"
        case "thun": "Thunderbolt"
        case "virt": "Virtual"
        case "0x00000000": "—"
        case let other: other
        }
    }

    /// 0x34323076 → "420v". Unprintable codes come back as hex.
    nonisolated static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(format: "0x%08X", code) }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }

    func actions(for device: Device) -> [DeviceAction] {
        guard let cam = cameras.first(where: { "camera:\($0.uniqueID)" == device.id }) else { return [] }
        return [
            DeviceAction(device, "preview", "Preview", "eye") { [weak self] in self?.preview(cam) },
            DeviceAction(device, "photobooth", "Open Photo Booth", "camera") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Photo Booth.app"))
            },
            DeviceAction(device, "privacy", "Camera Privacy…", "hand.raised") {
                Util.open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
            },
        ]
    }

    private func preview(_ cam: AVCaptureDevice) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            openPreview(cam)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { if ok { self.openPreview(cam) } }
            }
        default:
            Notifier.shared.post("Camera access is off", "Allow FastGlance in Privacy & Security → Camera.")
        }
    }
}

/// Live, mirrored camera preview. The session stops when the window's view goes away.
struct CameraPreview: NSViewRepresentable {
    let device: AVCaptureDevice

    final class Coordinator { var session: AVCaptureSession? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let session = AVCaptureSession()
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) { session.addInput(input) }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let conn = layer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        view.layer = layer
        view.wantsLayer = true
        context.coordinator.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        let session = coordinator.session
        DispatchQueue.global(qos: .userInitiated).async { session?.stopRunning() }
    }
}
