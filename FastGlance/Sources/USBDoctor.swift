import IOKit
import Foundation

/// Explains how a USB device or disk is really connected and why it might be slow.
enum USBDoctor {
    struct Report: Equatable {
        var link: String
        var via: [String] = []      // hubs between the device and the Mac
        var warning: String? = nil
        var note: String? = nil
    }

    struct Hub: Equatable {
        let name: String
        let speed: Int?
    }

    static func linkName(_ speed: Int?) -> String {
        switch speed {
        case 0: "USB 1.0 · 1.5 Mb/s"
        case 1: "USB 1.1 · 12 Mb/s"
        case 2: "USB 2.0 · 480 Mb/s"
        case 3: "USB 3.2 Gen 1 · 5 Gb/s"
        case 4: "USB 3.2 Gen 2 · 10 Gb/s"
        case 5: "USB 3.2 Gen 2×2 · 20 Gb/s"
        default: "USB · unknown speed"
        }
    }

    /// Pure decision logic.
    /// - bcdUSB 0x0210 is what USB 3 devices report while running at USB 2 speed (USB 3.x spec 9.6.1),
    ///   so 0x0210 at high speed means "could be faster".
    static func assess(speed: Int?, bcdUSB: Int?, isStorage: Bool, hubs: [Hub]) -> Report {
        var r = Report(link: linkName(speed), via: hubs.map(\.name))
        let usb3Capable = (bcdUSB ?? 0) >= 0x0300 || bcdUSB == 0x0210
        let wantsSpeed = isStorage || usb3Capable
        guard let speed else { return r }

        if speed <= 2, wantsSpeed, let slowHub = hubs.first(where: { ($0.speed ?? 3) <= 2 }) {
            r.warning = "Connected through \(slowHub.name), a USB 2 hub, which caps it at 480 Mb/s. Plug it straight into the Mac or into a USB 3 hub."
        } else if speed == 2, usb3Capable {
            r.warning = "This device supports USB 3 but is running at USB 2 speed (480 Mb/s). Usually the cable is USB 2-only — often a charging cable. Try a USB 3 / USB-C data cable or another port."
        } else if speed <= 1, isStorage {
            r.warning = "This drive is running at USB 1 speed and will be extremely slow. Try another port or cable."
        } else if speed == 2, isStorage {
            r.note = "This is a USB 2 drive: 480 Mb/s (about 40 MB/s) is its maximum."
        }
        return r
    }

    // MARK: - Registry

    static func props(_ entry: io_registry_entry_t) -> [String: Any] {
        var cf: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &cf, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return cf?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    static func speed(_ p: [String: Any]) -> Int? {
        p["USBSpeed"] as? Int ?? p["Device Speed"] as? Int
    }

    private static func name(_ p: [String: Any]) -> String {
        (p["USB Product Name"] as? String) ?? (p["kUSBProductString"] as? String) ?? "a hub"
    }

    /// Hubs above a USB device, nearest first.
    static func hubs(above service: io_registry_entry_t) -> [Hub] {
        var out: [Hub] = []
        var cur = service
        IOObjectRetain(cur)
        while true {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) == KERN_SUCCESS else { break }
            IOObjectRelease(cur)
            cur = parent
            if IOObjectConformsTo(cur, "IOUSBHostDevice") != 0 {
                let p = props(cur)
                if p["bDeviceClass"] as? Int == 9 { out.append(Hub(name: name(p), speed: speed(p))) }
            }
        }
        IOObjectRelease(cur)
        return out
    }

    static func report(usbDevice service: io_service_t, props p: [String: Any], isStorage: Bool) -> Report {
        assess(speed: speed(p), bcdUSB: p["bcdUSB"] as? Int, isStorage: isStorage, hubs: hubs(above: service))
    }

    /// For a mounted volume: walks from its BSD disk up to the bus it hangs off.
    static func report(bsdName: String) -> Report? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        guard service != 0 else { return nil }
        var cur: io_registry_entry_t = service
        while true {
            if IOObjectConformsTo(cur, "IOUSBHostDevice") != 0 {
                let r = report(usbDevice: cur, props: props(cur), isStorage: true)
                IOObjectRelease(cur)
                return r
            }
            if IOObjectConformsTo(cur, "IOHDIXHDDrive") != 0 {
                IOObjectRelease(cur)
                return Report(link: "Disk image")
            }
            if IOObjectConformsTo(cur, "IOThunderboltPort") != 0 || IOObjectConformsTo(cur, "IOPCIDevice") != 0 {
                IOObjectRelease(cur)
                return Report(link: "Thunderbolt / PCIe")
            }
            var parent: io_registry_entry_t = 0
            let ok = IORegistryEntryGetParentEntry(cur, kIOServicePlane, &parent) == KERN_SUCCESS
            IOObjectRelease(cur)
            guard ok else { return nil }
            cur = parent
        }
    }

    /// "/Volumes/X" -> "disk4s1"
    static func bsdName(forVolume url: URL) -> String? {
        var s = statfs()
        guard statfs(url.path, &s) == 0 else { return nil }
        let from = withUnsafeBytes(of: &s.f_mntfromname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return from.hasPrefix("/dev/") ? String(from.dropFirst(5)) : nil
    }
}
