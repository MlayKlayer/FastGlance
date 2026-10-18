import IOKit
import IOKit.usb
import AppKit

private func drain(_ it: io_iterator_t) {
    while case let s = IOIteratorNext(it), s != 0 { IOObjectRelease(s) }
}

@MainActor final class USBSource: DeviceSource {
    let prefix = "usb"
    var onChange: (() -> Void)?
    private(set) var devices: [Device] = []
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    func start() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var it: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, IOServiceMatching("IOUSBHostDevice"), { ctx, it in
                drain(it)
                let me = Unmanaged<USBSource>.fromOpaque(ctx!).takeUnretainedValue()
                MainActor.assumeIsolated { me.scheduleReload() }
            }, ctx, &it)
            drain(it)  // arms the notification
            iterators.append(it)
        }
        reload()
    }

    private func scheduleReload() {
        // Terminated devices can linger in the registry for a moment.
        reload()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.reload() }
    }

    func reload() {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        var next: [Device] = []
        while case let service = IOIteratorNext(iter), service != 0 {
            if let d = device(service) { next.append(d) }
            IOObjectRelease(service)
        }
        if next != devices { devices = next; onChange?() }
    }

    private static func props(_ entry: io_registry_entry_t) -> [String: Any] {
        var cf: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &cf, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return [:] }
        return cf?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private func interfaces(_ service: io_service_t) -> [(cls: Int, proto: Int)] {
        var out: [(Int, Int)] = []
        var it: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        while case let child = IOIteratorNext(it), child != 0 {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                let p = Self.props(child)
                if let cls = p["bInterfaceClass"] as? Int { out.append((cls, p["bInterfaceProtocol"] as? Int ?? 0)) }
            }
            IOObjectRelease(child)
        }
        return out
    }

    private func device(_ service: io_service_t) -> Device? {
        let p = Self.props(service)
        let deviceClass = p["bDeviceClass"] as? Int ?? 0
        guard deviceClass != 9 else { return nil }  // hubs
        let ifaces = interfaces(service)
        let classes = Set(ifaces.map(\.cls))
        // Storage and audio functions are shown by their own sources, with better controls.
        guard !classes.contains(8), !classes.contains(1) else { return nil }

        let vendorID = p["idVendor"] as? Int ?? 0
        let productID = p["idProduct"] as? Int ?? 0
        let name = (p["USB Product Name"] as? String) ?? (p["kUSBProductString"] as? String) ?? String(format: "USB Device %04X:%04X", vendorID, productID)
        let vendor = (p["USB Vendor Name"] as? String) ?? (p["kUSBVendorString"] as? String)
        let serial = (p["USB Serial Number"] as? String) ?? (p["kUSBSerialNumberString"] as? String)
        let location = p["locationID"] as? Int ?? 0

        let kind: DeviceKind
        if vendorID == 0x05AC, name.contains("iPhone") || name.contains("iPad") { kind = .phone }
        else if classes.contains(14) { kind = .camera }
        else if ifaces.contains(where: { $0.cls == 3 && $0.proto == 1 }) { kind = .keyboard }
        else if ifaces.contains(where: { $0.cls == 3 && $0.proto == 2 }) { kind = .mouse }
        else { kind = .usb }

        let speed = Self.speedName(p["Device Speed"] as? Int ?? p["USBSpeed"] as? Int)
        var info = [InfoRow("Vendor", vendor ?? "—"),
                    InfoRow("Vendor ID", String(format: "0x%04X", vendorID)),
                    InfoRow("Product ID", String(format: "0x%04X", productID)),
                    InfoRow("Speed", speed),
                    InfoRow("Location", String(format: "0x%08X", location))]
        if let serial { info.append(InfoRow("Serial", serial)) }
        if let ma = p["UsbPowerSinkAllocation"] as? Int ?? p["kUSBCurrentAvailable"] as? Int { info.append(InfoRow("Power", "\(ma) mA")) }

        let raw = p.map { InfoRow($0.key, "\($0.value)") }.sorted { $0.key < $1.key }
        let stable = serial.map { "\($0)" } ?? String(format: "loc%08X", location)
        return Device(id: String(format: "usb:%04x:%04x:", vendorID, productID) + stable, name: name, kind: kind,
                      isConnected: true, status: [vendor, speed].compactMap { $0 }.joined(separator: " · "), info: info, raw: raw)
    }

    static func speedName(_ s: Int?) -> String {
        switch s {
        case 0: "Low speed (1.5 Mb/s)"
        case 1: "Full speed (12 Mb/s)"
        case 2: "High speed (480 Mb/s)"
        case 3: "SuperSpeed (5 Gb/s)"
        case 4: "SuperSpeed+ (10 Gb/s)"
        case 5: "SuperSpeed+ (20 Gb/s)"
        default: "Unknown"
        }
    }

    func actions(for device: Device) -> [DeviceAction] {
        var out: [DeviceAction] = []
        if device.kind == .phone {
            out.append(DeviceAction(device, "photos", "Import Photos", "photo.on.rectangle") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Image Capture.app"))
            })
            out.append(DeviceAction(device, "finder", "Open in Finder", "folder") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
            })
        }
        let ids = device.info.filter { $0.key.hasSuffix(" ID") }.map(\.value).joined(separator: ":")
        out.append(DeviceAction(device, "copyids", "Copy Vendor:Product ID", "doc.on.doc") { Util.copy(ids) })
        return out
    }
}
