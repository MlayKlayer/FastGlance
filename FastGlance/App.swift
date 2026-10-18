import AppKit
import SwiftUI
import AVFoundation

@main
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    // Hosted unit tests must not start hardware discovery, prompt for permissions,
    // register hotkeys, or write the user's device history.
    private let isRunningTests = NSClassFromString("XCTestCase") != nil
    private lazy var hub = DeviceHub()
    private let selection = DetailSelection()
    private var status: StatusController!
    private var windows: [String: NSWindow] = [:]
    private lazy var lidGuard = LidGuard(disks: hub.disks)

    func applicationDidFinishLaunching(_ note: Notification) {
        guard !isRunningTests else { return }
        Prefs.register()
        NSApp.mainMenu = Self.mainMenu()
        Notifier.shared.start()
        status = StatusController(hub: hub, menu: MenuView(openDetail: { [weak self] in self?.openDetail($0) },
                                                           openSettings: { [weak self] in self?.openSettings() }))
        status.openDetail = { [weak self] in self?.openDetail(nil) }
        status.openSettings = { [weak self] in self?.openSettings() }
        hub.onRefresh = { [weak self] old, new in
            Notifier.shared.handle(old: old, new: new)
            self?.status.update(old: old, new: new)
        }
        hub.cameras.openPreview = { [weak self] in self?.openCamera($0) }
        Hotkeys.shared.handler = { [weak self] id in self?.hotkey(id) }
        applyHotkeys()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyHotkeys() }
        }
        hub.start()
        lidGuard.start()
    }

    private func applyHotkeys() {
        Hotkeys.shared.set(enabled: UserDefaults.standard.bool(forKey: Prefs.hotkeys))
    }

    private func hotkey(_ id: UInt32) {
        if id == Hotkeys.micID {
            hub.audio.toggleMic()
            Notifier.shared.post(hub.audio.isMicMuted ? "Microphone muted" : "Microphone on", "")
        } else if let pin = hub.pinnedAction(slot: Int(id) - 1) {
            pin.action.run()
        } else {
            NSSound.beep()
            return
        }
        status.flash()
    }

    func applicationWillTerminate(_ note: Notification) {
        guard !isRunningTests else { return }
        hub.saveHistory()
    }

    // MARK: - Windows

    func openDetail(_ id: String?) {
        status.closePopover()
        if let id { selection.deviceID = id }
        show("detail", title: "FastGlance", size: NSSize(width: 860, height: 600), resizable: true,
             DetailView().environmentObject(hub).environmentObject(selection))
    }

    @objc func openSettings() {
        status.closePopover()
        show("settings", title: "FastGlance Settings", size: NSSize(width: 460, height: 600), resizable: false,
             SettingsView().environmentObject(hub))
    }

    private func openCamera(_ camera: AVCaptureDevice) {
        windows["camera"]?.close()  // one preview at a time
        show("camera", title: camera.localizedName, size: NSSize(width: 640, height: 400), resizable: true,
             CameraPreview(device: camera).frame(minWidth: 320, minHeight: 200))
    }

    private func show(_ key: String, title: String, size: NSSize, resizable: Bool, _ view: some View) {
        // A menu bar app's windows open behind other apps unless it becomes a regular app while they're open.
        NSApp.setActivationPolicy(.regular)
        let window = windows[key] ?? {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            if resizable { style.insert(.resizable) }
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            w.title = title
            w.contentViewController = NSHostingController(rootView: view)
            w.setContentSize(size)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName(key)
            windows[key] = w
            return w
        }()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ note: Notification) {
        let closing = note.object as? NSWindow
        if let closing, closing === windows["camera"] {
            // Drop the view so the capture session stops and the camera light goes off.
            closing.contentViewController = nil
            windows["camera"] = nil
        }
        if !windows.values.contains(where: { $0 !== closing && $0.isVisible }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = {
            let m = NSMenu()
            m.addItem(withTitle: "Settings…", action: #selector(AppDelegate.openSettings), keyEquivalent: ",")
            m.addItem(.separator())
            m.addItem(withTitle: "Quit FastGlance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            return m
        }()
        let editItem = NSMenuItem()
        editItem.submenu = {
            let m = NSMenu(title: "Edit")
            m.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            m.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
            m.addItem(.separator())
            m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            return m
        }()
        let windowItem = NSMenuItem()
        windowItem.submenu = {
            let m = NSMenu(title: "Window")
            m.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            m.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            return m
        }()
        [appItem, editItem, windowItem].forEach(main.addItem)
        return main
    }
}
