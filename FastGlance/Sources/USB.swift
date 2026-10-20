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
    private var details: [String: [InfoSection]] = [:]
    /// Serials of every attached USB device, including ones shown by other sources.
    private(set) var presentSerials: Set<String> = []
    /// Serials another source shows instead (printers with a CUPS queue).
    var claimedSerials: () -> Set<String> = { [] }
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
        var nextDetails: [String: [InfoSection]] = [:]
        var serials = Set<String>()
        let claimed = claimedSerials()
        while case let service = IOIteratorNext(iter), service != 0 {
            let p = USBDoctor.props(service)
            let serial = (p["USB Serial Number"] as? String) ?? (p["kUSBSerialNumberString"] as? String)
            if let serial { serials.insert(serial) }
            if serial.map({ !claimed.contains($0) }) ?? true, let d = device(service, p) {
                next.append(d)
                nextDetails[d.id] = Self.describe(service, p)
            }
            IOObjectRelease(service)
        }
        let serialsChanged = serials != presentSerials
        presentSerials = serials
        details = nextDetails
        if next != devices || serialsChanged { devices = next; onChange?() }
    }

    private func interfaces(_ service: io_service_t) -> [(cls: Int, proto: Int)] {
        var out: [(Int, Int)] = []
        var it: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        while case let child = IOIteratorNext(it), child != 0 {
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                let p = USBDoctor.props(child)
                if let cls = p["bInterfaceClass"] as? Int { out.append((cls, p["bInterfaceProtocol"] as? Int ?? 0)) }
            }
            IOObjectRelease(child)
        }
        return out
    }

    private func device(_ service: io_service_t, _ p: [String: Any]) -> Device? {
        let deviceClass = p["bDeviceClass"] as? Int ?? 0
        guard deviceClass != 9 else { return nil }  // hubs
        let ifaces = interfaces(service)
        let classes = Set(ifaces.map(\.cls))
        // Storage, audio and camera functions are shown by their own sources, with better controls.
        guard !classes.contains(8), !classes.contains(1), !classes.contains(14) else { return nil }  // + cameras

        let vendorID = p["idVendor"] as? Int ?? 0
        let productID = p["idProduct"] as? Int ?? 0
        let name = (p["USB Product Name"] as? String) ?? (p["kUSBProductString"] as? String) ?? String(format: "USB Device %04X:%04X", vendorID, productID)
        let vendor = (p["USB Vendor Name"] as? String) ?? (p["kUSBVendorString"] as? String)
        let serial = (p["USB Serial Number"] as? String) ?? (p["kUSBSerialNumberString"] as? String)
        let location = p["locationID"] as? Int ?? 0

        let kind: DeviceKind
        if vendorID == 0x05AC, name.contains("iPhone") || name.contains("iPad") { kind = .phone }
        else if classes.contains(7) { kind = .printer }
        else if ifaces.contains(where: { $0.cls == 3 && $0.proto == 1 }) { kind = .keyboard }
        else if ifaces.contains(where: { $0.cls == 3 && $0.proto == 2 }) { kind = .mouse }
        else { kind = .usb }

        let doctor = USBDoctor.report(usbDevice: service, props: p, isStorage: false)
        let speed = doctor.link
        var info = [InfoRow("Vendor", vendor ?? "—"),
                    InfoRow("Vendor ID", String(format: "0x%04X", vendorID)),
                    InfoRow("Product ID", String(format: "0x%04X", productID)),
                    InfoRow("Connection", speed),
                    InfoRow("Location", String(format: "0x%08X", location))]
        if !doctor.via.isEmpty { info.append(InfoRow("Through", doctor.via.joined(separator: " → "))) }
        if let serial { info.append(InfoRow("Serial", serial)) }
        if let ma = p["UsbPowerSinkAllocation"] as? Int ?? p["kUSBCurrentAvailable"] as? Int { info.append(InfoRow("Power", "\(ma) mA")) }

        let raw = p.map { InfoRow($0.key, "\($0.value)") }.sorted { $0.key < $1.key }
        let stable = serial.map { "\($0)" } ?? String(format: "loc%08X", location)
        return Device(id: String(format: "usb:%04x:%04x:", vendorID, productID) + stable, name: name, kind: kind,
                      isConnected: true, status: [vendor, speed].compactMap { $0 }.joined(separator: " · "), info: info, raw: raw,
                      warning: doctor.warning)
    }

    func sections(for device: Device) -> [InfoSection] { details[device.id] ?? [] }

    /// Descriptor fields, interfaces and the drivers bound to them, read from the IORegistry.
    private static func describe(_ service: io_service_t, _ p: [String: Any]) -> [InfoSection] {
        func int(_ props: [String: Any], _ key: String) -> Int { props[key] as? Int ?? 0 }
        var descriptor: [InfoRow] = []
        if let v = p["bcdUSB"] as? Int { descriptor.append(InfoRow("USB version", bcd(v))) }
        if let v = p["bcdDevice"] as? Int { descriptor.append(InfoRow("Device release", bcd(v))) }
        descriptor.append(InfoRow("Device class", className(int(p, "bDeviceClass"), int(p, "bDeviceSubClass"), int(p, "bDeviceProtocol"))))
        if let v = p["bNumConfigurations"] as? Int { descriptor.append(InfoRow("Configurations", "\(v)")) }
        if let v = p["bMaxPacketSize0"] as? Int { descriptor.append(InfoRow("Control packet size", "\(v) bytes")) }
        let ownDrivers = children(service).compactMap { c -> String? in
            if IOObjectConformsTo(c, "IOUSBHostInterface") != 0 { IOObjectRelease(c); return nil }
            return objectClass(c)
        }
        let drivers = Array(Set(ownDrivers.filter { !$0.hasSuffix("UserClient") })).sorted()  // user clients are apps talking to it
        if !drivers.isEmpty { descriptor.append(InfoRow("Device driver", drivers.joined(separator: ", "))) }

        var interfaces: [InfoRow] = []
        var it: io_iterator_t = 0
        if IORegistryEntryCreateIterator(service, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS {
            while case let child = IOIteratorNext(it), child != 0 {
                if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                    let ip = USBDoctor.props(child)
                    let drivers = children(child).map(objectClass).filter { !$0.hasSuffix("UserClient") }
                    var value = className(int(ip, "bInterfaceClass"), int(ip, "bInterfaceSubClass"), int(ip, "bInterfaceProtocol"))
                    value += " · \(int(ip, "bNumEndpoints")) endpoint\(int(ip, "bNumEndpoints") == 1 ? "" : "s")"
                    value += " · " + (drivers.isEmpty ? "no driver" : drivers.joined(separator: ", "))
                    interfaces.append(InfoRow("Interface \(int(ip, "bInterfaceNumber"))", value))
                }
                IOObjectRelease(child)
            }
            IOObjectRelease(it)
        }
        return [InfoSection(title: "Descriptor", rows: descriptor)]
            + (interfaces.isEmpty ? [] : [InfoSection(title: "Interfaces & Drivers", rows: interfaces.sorted { $0.key < $1.key })])
    }

    /// Direct children in the service plane; the caller releases each one.
    private static func children(_ entry: io_registry_entry_t) -> [io_registry_entry_t] {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var out: [io_registry_entry_t] = []
        while case let c = IOIteratorNext(it), c != 0 { out.append(c) }
        return out
    }

    /// The registry class name; releases `entry`.
    private static func objectClass(_ entry: io_registry_entry_t) -> String {
        defer { IOObjectRelease(entry) }
        var buf = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &buf)
        return String(cString: buf)
    }

    /// 0x0210 → "2.10".
    nonisolated static func bcd(_ v: Int) -> String { String(format: "%x.%02x", v >> 8, v & 0xFF) }

    /// USB-IF class codes, with the HID boot protocols spelled out.
    nonisolated static func className(_ cls: Int, _ sub: Int, _ proto: Int) -> String {
        let names = [0: "Defined per interface", 1: "Audio", 2: "Communications", 3: "HID", 5: "Physical", 6: "Image",
                     7: "Printer", 8: "Mass storage", 9: "Hub", 10: "CDC data", 11: "Smart card", 13: "Content security",
                     14: "Video", 15: "Personal healthcare", 16: "Audio/Video", 17: "Billboard", 18: "USB-C bridge",
                     0xDC: "Diagnostic", 0xE0: "Wireless controller", 0xEF: "Miscellaneous", 0xFE: "Application specific",
                     0xFF: "Vendor specific"]
        var name = names[cls] ?? String(format: "Class 0x%02X", cls)
        if cls == 3, sub == 1, let boot = [1: "keyboard", 2: "mouse"][proto] { name += " (boot \(boot))" }
        return cls == 0 ? name : name + String(format: " · %02X/%02X/%02X", cls, sub, proto)
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
