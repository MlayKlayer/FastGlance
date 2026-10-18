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
