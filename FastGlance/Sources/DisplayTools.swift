import SwiftUI

/// Full-screen test patterns for spotting dead or stuck pixels, banding and uneven backlight.
enum TestPattern: Int, CaseIterable {
    case black, white, gray, red, green, blue, grayGradient, colorGradients, graySteps

    var title: String {
        switch self {
        case .black: "Black"
        case .white: "White"
        case .gray: "50% Gray"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .grayGradient: "Gray Gradient"
        case .colorGradients: "Color Gradients"
        case .graySteps: "Gray Steps"
        }
    }

    var purpose: String {
        switch self {
        case .black: "Stuck bright pixels, backlight bleed"
        case .white: "Dead dark pixels, dust, tint"
        case .gray: "Uneven brightness, dirty-screen effect"
        case .red, .green, .blue: "Stuck subpixels"
        case .grayGradient, .colorGradients: "Banding (visible steps in a smooth ramp)"
        case .graySteps: "Shadow and highlight detail: every step should be distinct"
        }
    }

    // Display P3 primaries: sRGB red on a P3 panel also lights green and blue subpixels, hiding a stuck one.
    // On an sRGB monitor they clip to its own primaries, which is what we want there too.
    private static let p3Red = Color(.displayP3, red: 1, green: 0, blue: 0)
    private static let p3Green = Color(.displayP3, red: 0, green: 1, blue: 0)
    private static let p3Blue = Color(.displayP3, red: 0, green: 0, blue: 1)

    @ViewBuilder var view: some View {
        switch self {
        case .black: Color.black
        case .white: Color.white
        case .gray: Color(white: 0.5)
        case .red: Self.p3Red
        case .green: Self.p3Green
        case .blue: Self.p3Blue
        case .grayGradient: LinearGradient(colors: [.black, .white], startPoint: .leading, endPoint: .trailing)
        case .colorGradients:
            VStack(spacing: 0) {
                ForEach([Self.p3Red, Self.p3Green, Self.p3Blue, .white], id: \.self) {
                    LinearGradient(colors: [.black, $0], startPoint: .leading, endPoint: .trailing)
                }
            }
        case .graySteps:
            HStack(spacing: 0) {
                ForEach(0..<17) { Color(white: Double($0) / 16) }
            }
        }
    }
}

/// The Diagnostics tool: pick a pattern, show it full screen on this display.
struct TestPatternTool: View {
    let screen: NSScreen?
    @State private var start = TestPattern.black

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fills this display with solid colours and ramps. Change pattern with ← → or a click; Esc exits.")
            HStack(spacing: 8) {
                Picker("Start with", selection: $start) {
                    ForEach(TestPattern.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Button("Show Full Screen") { if let screen { PatternWindow.show(on: screen, start: start) } }
                    .disabled(screen == nil)
            }
            Text(screen == nil ? "This display has no screen of its own (it may be mirrored)." : start.purpose)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A borderless window over the whole screen, menu bar and notch included. One at a time.
final class PatternWindow: NSWindow {
    private static var current: PatternWindow?
    private var index: Int
    private var observer: NSObjectProtocol?

    static func show(on screen: NSScreen, start: TestPattern) {
        current?.close()
        let w = PatternWindow(screen: screen, index: start.rawValue)
        current = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        NSCursor.hide()
    }

    private init(screen: NSScreen, index: Int) {
        self.index = index
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)
        render()
        // An unplugged or rearranged display would leave the pattern on the wrong screen.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    override var canBecomeKey: Bool { true }

    private func render() {
        contentView = NSHostingView(rootView: PatternScreen(pattern: TestPattern.allCases[index]))
    }

    private func step(_ by: Int) {
        let n = TestPattern.allCases.count
        index = (index + by + n) % n
        render()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: close()                // Esc
        case 123, 126: step(-1)         // ← ↑
        case 124, 125, 49: step(1)      // → ↓ Space
        default: super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) { step(1) }
    override func rightMouseDown(with event: NSEvent) { step(-1) }
    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        guard Self.current === self else { return super.close() }
        Self.current = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        NSCursor.unhide()
        super.close()
    }
}

/// The pattern plus a hint that fades after two seconds, so it doesn't hide pixels for long.
private struct PatternScreen: View {
    let pattern: TestPattern
    @State private var hint = true

    var body: some View {
        pattern.view
            .ignoresSafeArea()
            .overlay(alignment: .bottom) {
                if hint {
                    Text("\(pattern.title) — ← → or click to change, Esc to exit")
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(40)
                        .transition(.opacity)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { hint = false }
            }
    }
}
