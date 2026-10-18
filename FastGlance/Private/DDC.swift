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

    static var isAvailable: Bool { create != nil && readI2C != nil && writeI2C != nil }

    private static let chip: UInt32 = 0x37
    private static let offset: UInt32 = 0x51

    struct Identity: Equatable {
        var vendor: Int?
        var product: Int?
        var serial: Int?
    }

    struct Service {
        let ref: CFTypeRef
        let identity: Identity
    }

    /// AV services of external displays, each tagged with the EDID identity of the framebuffer that precedes it
    /// in the registry (the same walk MonitorControl uses), so two monitors can't be swapped.
    static func externalServices() -> [Service] {
        guard let create else { return [] }
        var iter: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iter) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iter) }
        var out: [Service] = []
        var last = Identity()
        while case let e = IOIteratorNext(iter), e != 0 {
            defer { IOObjectRelease(e) }
            if let attrs = IORegistryEntryCreateCFProperty(e, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let product = attrs["ProductAttributes"] as? [String: Any] {
                last = Identity(vendor: product["LegacyManufacturerID"] as? Int, product: product["ProductID"] as? Int,
                                serial: product["SerialNumber"] as? Int)
            }
            guard IOObjectConformsTo(e, "DCPAVServiceProxy") != 0,
                  IORegistryEntryCreateCFProperty(e, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String == "External",
                  let svc = create(kCFAllocatorDefault, e)?.takeRetainedValue() else { continue }
            out.append(Service(ref: svc, identity: last))
            last = Identity()
        }
        return out
    }

    /// Pairs displays with services: exact EDID match first, then whatever is left in order.
    /// Returns display index -> service index.
    static func pair(displays: [Identity], services: [Identity]) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var free = Array(services.indices)
        func matches(_ d: Identity, _ s: Identity) -> Bool {
            guard d.vendor != nil, d.vendor == s.vendor, d.product == s.product else { return false }
            let ds = d.serial ?? 0, ss = s.serial ?? 0
            return ds == 0 || ss == 0 || ds == ss
        }
        // Serial-exact matches first so two identical models with different serials pair correctly.
        for strict in [true, false] {
            for (i, d) in displays.enumerated() where result[i] == nil {
                if let k = free.firstIndex(where: { matches(d, services[$0]) && (!strict || (d.serial ?? 0) == (services[$0].serial ?? 0)) }) {
                    result[i] = free.remove(at: k)
                }
            }
        }
        for i in displays.indices where result[i] == nil {
            guard !free.isEmpty else { break }
            result[i] = free.removeFirst()
        }
        return result
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
