import CoreGraphics
import Foundation

/// Private DisplayServices API: brightness for the built-in display and Apple displays.
/// Loaded dynamically so a future macOS that drops it just reports "unavailable".
enum DisplayBrightness {
    private typealias Getter = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Getter.self) }
    private static let setter = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Setter.self) }

    static var isAvailable: Bool { getter != nil && setter != nil }

    static func get(_ display: CGDirectDisplayID) -> Float? {
        var v: Float = 0
        guard let getter, getter(display, &v) == 0 else { return nil }
        return v
    }

    static func set(_ display: CGDirectDisplayID, _ value: Float) {
        _ = setter?(display, min(max(value, 0), 1))
    }
}
