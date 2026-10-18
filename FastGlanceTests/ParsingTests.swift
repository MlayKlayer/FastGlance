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
