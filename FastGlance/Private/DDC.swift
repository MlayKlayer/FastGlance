import Foundation
import IOKit

/// DDC/CI to external monitors over the private IOAVService API (Apple Silicon).
/// Loaded dynamically: if a macOS update removes it, every call reports "unavailable".
enum DDC {
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12
    static let volume: UInt8 = 0x62
    static let input: UInt8 = 0x60

    /// Common MCCS input codes. Some monitors use vendor-specific values for USB-C.
    static let inputs: [(name: String, code: UInt16)] = [
        ("DisplayPort 1", 0x0F), ("DisplayPort 2", 0x10), ("HDMI 1", 0x11), ("HDMI 2", 0x12), ("USB-C", 0x1B),
    ]

    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
    private static let create = handle.flatMap { dlsym($0, "IOAVServiceCreateWithService") }.map { unsafeBitCast($0, to: Create.self) }
    private static let readI2C = handle.flatMap { dlsym($0, "IOAVServiceReadI2C") }.map { unsafeBitCast($0, to: Transfer.self) }
    private static let writeI2C = handle.flatMap { dlsym($0, "IOAVServiceWriteI2C") }.map { unsafeBitCast($0, to: Transfer.self) }

    private static let chip: UInt32 = 0x37
    private static let offset: UInt32 = 0x51

    /// AV services of external displays, in registry order.
    static func externalServices() -> [CFTypeRef] {
        guard let create else { return [] }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [CFTypeRef] = []
        while case let s = IOIteratorNext(iter), s != 0 {
            let location = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
            if location == "External", let svc = create(kCFAllocatorDefault, s)?.takeRetainedValue() { out.append(svc) }
            IOObjectRelease(s)
        }
        return out
    }

    /// Blocking (tens of ms); call off the main thread.
    @discardableResult
    static func write(_ service: CFTypeRef, _ code: UInt8, _ value: UInt16) -> Bool {
        guard let writeI2C else { return false }
        var packet: [UInt8] = [0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0]
        packet[5] = checksum(packet.dropLast())
        for _ in 0..<3 {
            if writeI2C(service, chip, offset, &packet, UInt32(packet.count)) == kIOReturnSuccess { return true }
            usleep(20_000)
        }
        return false
    }

    /// Blocking (~100 ms); call off the main thread.
    static func read(_ service: CFTypeRef, _ code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard let readI2C, let writeI2C else { return nil }
        for _ in 0..<3 {
            var request: [UInt8] = [0x82, 0x01, code, 0]
            request[3] = request.dropLast().reduce(UInt8(0x6E), ^)  // single-byte requests seed with 0x6E only (as MonitorControl does)
            guard writeI2C(service, chip, offset, &request, UInt32(request.count)) == kIOReturnSuccess else { usleep(20_000); continue }
            usleep(50_000)  // monitors need time to answer
            var reply = [UInt8](repeating: 0, count: 11)
            if readI2C(service, chip, 0, &reply, UInt32(reply.count)) == kIOReturnSuccess, let v = parseReply(reply, code: code) {
                return v
            }
            usleep(20_000)
        }
        return nil
    }

    /// Reply: [src, len, 0x02, result, vcp, type, maxH, maxL, curH, curL, checksum]
    static func parseReply(_ r: [UInt8], code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard r.count >= 11, r[2] == 0x02, r[3] == 0x00, r[4] == code else { return nil }
        return (UInt16(r[8]) << 8 | UInt16(r[9]), UInt16(r[6]) << 8 | UInt16(r[7]))
    }

    static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(UInt8(0x6E ^ 0x51), ^)
    }
}
