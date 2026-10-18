import AppKit
import SwiftUI

/// The menu bar icon: quiet by default, a dot when something needs attention.
@MainActor final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let hub: DeviceHub
    var openDetail: () -> Void = {}
    var openSettings: () -> Void = {}

    init(hub: DeviceHub, menu: MenuView) {
        self.hub = hub
        super.init()
        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: menu.environmentObject(hub))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        if let button = item.button {
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }
        Notifier.shared.isMenuOpen = { [weak self] in self?.popover.isShown == true }
        render()
        // Icon settings take effect immediately.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
    }

    func closePopover() { popover.performClose(nil) }

    @objc private func clicked() {
        guard let event = NSApp.currentEvent, let button = item.button else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else if event.modifierFlags.contains(.option) {
            if let first = hub.pinnedAction(slot: 0) {
                first.action.run()
                flash()
            } else {
                NSSound.beep()
            }
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            hub.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Open FastGlance", openDetail))
        menu.addItem(ClosureMenuItem("Settings…", openSettings))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit FastGlance", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    func update(old: [Device], new: [Device]) {
        render()
        let before = Set(old.filter(\.isConnected).map(\.id))
        let after = Set(new.filter(\.isConnected).map(\.id))
        if !old.isEmpty && before != after { flash() }
    }

    private func render() {
        guard let button = item.button else { return }
        let d = UserDefaults.standard
        let connected = hub.devices.filter(\.isConnected)
        let powered = connected.filter { $0.kind != .printer && !$0.isHidden }  // ink isn't a battery
        let threshold = d.integer(forKey: Prefs.batteryThreshold)

        let dot: NSColor? = hub.audio.isMicMuted ? .systemRed
            : powered.contains { ($0.lowestBattery ?? 100) <= threshold } ? .systemOrange : nil
        button.image = Self.icon(dot: dot)

        var text = ""
        switch d.string(forKey: Prefs.iconMode) {
        case "lowest":
            if let low = powered.compactMap(\.lowestBattery).min() { text = "\(low)%" }
        case "device":
            let id = d.string(forKey: Prefs.iconDeviceID)
            if let low = connected.first(where: { $0.id == id })?.lowestBattery { text = "\(low)%" }
        default: break
        }
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .baselineOffset: 0.5,
        ])
        let names = connected.map(\.name).prefix(8).joined(separator: ", ")
        button.toolTip = connected.isEmpty ? "FastGlance" : "FastGlance — \(connected.count) connected: \(names)"
    }

    private static func icon(dot: NSColor?) -> NSImage {
        let symbol = NSImage(named: "MenuIcon")!  // template SVG in Assets.xcassets
        symbol.accessibilityDescription = "FastGlance"
        guard let dot else {
            symbol.isTemplate = true
            return symbol
        }
        // With a coloured dot the image can't be a template, so tint the glyph for the current appearance at draw time.
        let size = NSSize(width: symbol.size.width + 3, height: symbol.size.height)
        return NSImage(size: size, flipped: false) { rect in
            let glyph = NSImage(size: symbol.size, flipped: false) { r in
                symbol.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            glyph.draw(in: NSRect(origin: .zero, size: symbol.size))
            let d: CGFloat = 6.5
            let circle = NSBezierPath(ovalIn: NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d))
            dot.setFill()
            circle.fill()
            return true
        }
    }

    func flash() {
        guard let button = item.button else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            button.animator().alphaValue = 0.25
        }, completionHandler: {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                button.animator().alphaValue = 1
            }
        })
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
