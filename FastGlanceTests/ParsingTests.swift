import XCTest
@testable import FastGlance

final class ParsingTests: XCTestCase {
    func testARP() {
        let text = """
        ? (172.20.10.1) at 52:b1:27:87:64:64 on en0 ifscope [ethernet]
        ? (172.20.10.2) at 92:b3:ef:c4:44:60 on en0 ifscope permanent [ethernet]
        ? (172.20.10.15) at ff:ff:ff:ff:ff:ff on en0 ifscope [ethernet]
        ? (224.0.0.251) at 1:0:5e:0:0:fb on en0 ifscope permanent [ethernet]
        ? (192.168.1.7) at 0:11:2:a:b:c on en0 ifscope [ethernet]
        ? (192.168.1.9) at (incomplete) on en0 ifscope [ethernet]
        """
        XCTAssertEqual(NetworkSource.parseARP(text), ["172.20.10.1": "52:b1:27:87:64:64", "192.168.1.7": "00:11:02:0a:0b:0c"])
    }

    func testMagicPacketAndMAC() {
        let p = NetworkSource.magicPacket("00:11:22:33:44:55")!
        XCTAssertEqual(p.count, 102)
        XCTAssertEqual(Array(p.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        XCTAssertEqual(Array(p[96...]), [0x00, 0x11, 0x22, 0x33, 0x44, 0x55])
        XCTAssertNil(NetworkSource.magicPacket("nope"))
        XCTAssertTrue(NetworkSource.isPrivateMAC("92:b3:ef:c4:44:60"))
        XCTAssertFalse(NetworkSource.isPrivateMAC("00:11:22:33:44:55"))
    }

    func testSubnetAndGateway() {
        // 172.20.10.2/28 -> .1 ... .14 minus self
        let hosts = NetworkSource.subnetHosts(ip: 0xAC140A02, mask: 0xFFFF_FFF0)
        XCTAssertEqual(hosts.first, "172.20.10.1")
        XCTAssertEqual(hosts.count, 13)
        XCTAssertEqual(NetworkSource.subnetHosts(ip: 0x0A000001, mask: 0xFF00_0000).count, 1021)  // capped at /22
        XCTAssertEqual(NetworkSource.parseGateway("   route to: default\n    gateway: 172.20.10.1\n  interface: en0"), "172.20.10.1")
    }

    func testKinds() {
        XCTAssertEqual(NetworkSource.kind(["_ipp._tcp."], name: "Brother", isGateway: false), .printer)
        XCTAssertEqual(NetworkSource.kind(["_companion-link._tcp."], name: "Dmitrii's iPhone", isGateway: true), .phone)
        XCTAssertEqual(NetworkSource.kind(["_airplay._tcp."], name: "Living Room", isGateway: false), .media)
        XCTAssertEqual(NetworkSource.kind([], name: "Router", isGateway: true), .router)
    }

    func testPrinters() {
        let ipp = """
                device-uri (uri) = usb://Xerox/Phaser%203020?serial=5315040800
                marker-levels (1setOf integer) = 80,-1
                printer-state-reasons (keyword) = offline-report
        """
        let a = PrinterSource.parseIPP(ipp)
        XCTAssertEqual(a["marker-levels"], "80,-1")
        XCTAssertEqual(PrinterSource.usbSerial(a["device-uri"]!), "5315040800")
        XCTAssertEqual(PrinterSource.dnssdName("dnssd://Brother%20HL-L2350DW._ipp._tcp.local./?uuid=x"), "Brother HL-L2350DW")
        XCTAssertNil(PrinterSource.dnssdName("ipp://10.0.0.5/ipp"))
    }
}

final class DDCTests: XCTestCase {
    func testReplyAndChecksum() {
        // Brightness 50 of 100.
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0x00]
        let v = DDC.parseReply(reply, code: 0x10)
        XCTAssertEqual(v?.current, 50)
        XCTAssertEqual(v?.max, 100)
        XCTAssertNil(DDC.parseReply(reply, code: 0x12))  // answer for another VCP code
        XCTAssertEqual(DDC.checksum([0x84, 0x03, 0x10, 0x00, 0x32]), 0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ 0x10 ^ 0x32)
    }
}

@MainActor final class PinTests: XCTestCase {
    func testPinsResolveBySlotNotByFilteredPosition() {
        let buds = Device(id: "bt:a", name: "Buds", kind: .headphones, isConnected: true)
        let disk = Device(id: "disk:b", name: "Disk", kind: .storage, isConnected: true)
        var ran: [String] = []
        let actions: (Device) -> [DeviceAction] = { d in
            d.id == "disk:b" ? [DeviceAction(d, "eject", "Eject", "eject") { ran.append("eject") }] : []
        }
        let pins = ["bt:a|gone", "disk:b|eject"]
        // Slot 0 can't run right now: it must not fall through to the disk.
        XCTAssertNil(DeviceHub.resolve(pin: pins[0], devices: [buds, disk], actions: actions))
        DeviceHub.resolve(pin: pins[1], devices: [buds, disk], actions: actions)?.action.run()
        XCTAssertEqual(ran, ["eject"])
        XCTAssertNil(DeviceHub.resolve(pin: nil, devices: [buds, disk], actions: actions))
    }
}

final class USBDoctorTests: XCTestCase {
    func testAssess() {
        // USB 3 SSD on a USB 2 cable: reports bcdUSB 0x0210 at high speed.
        XCTAssertNotNil(USBDoctor.assess(speed: 2, bcdUSB: 0x0210, isStorage: true, hubs: []).warning)
        // Same, but behind a USB 2 hub: blame the hub.
        let viaHub = USBDoctor.assess(speed: 2, bcdUSB: 0x0210, isStorage: true, hubs: [.init(name: "Old Hub", speed: 2)])
        XCTAssertTrue(viaHub.warning?.contains("Old Hub") == true)
        // Plain USB 2 flash drive: no warning, just a note.
        let stick = USBDoctor.assess(speed: 2, bcdUSB: 0x0200, isStorage: true, hubs: [])
        XCTAssertNil(stick.warning)
        XCTAssertNotNil(stick.note)
        // USB 2 mouse behind a USB 2 hub: nothing to fix.
        XCTAssertNil(USBDoctor.assess(speed: 1, bcdUSB: 0x0200, isStorage: false, hubs: [.init(name: "Hub", speed: 2)]).warning)
        // Healthy 10 Gb/s SSD.
        let ssd = USBDoctor.assess(speed: 4, bcdUSB: 0x0320, isStorage: true, hubs: [])
        XCTAssertNil(ssd.warning)
        XCTAssertEqual(ssd.link, "USB 3.2 Gen 2 · 10 Gb/s")
    }
}

final class DDCPairTests: XCTestCase {
    func testTwoIdenticalMonitorsPairBySerial() {
        let a = DDC.Identity(vendor: 0x10AC, product: 0xA0C4, serial: 111)
        let b = DDC.Identity(vendor: 0x10AC, product: 0xA0C4, serial: 222)
        // Services found in the opposite order to the displays.
        XCTAssertEqual(DDC.pair(displays: [a, b], services: [b, a]), [0: 1, 1: 0])
        // Unknown identities fall back to order.
        XCTAssertEqual(DDC.pair(displays: [a, b], services: [DDC.Identity(), DDC.Identity()]), [0: 0, 1: 1])
        // More displays than services: the extra one gets nothing.
        XCTAssertEqual(DDC.pair(displays: [a, b], services: [b]), [1: 0])
    }
}
