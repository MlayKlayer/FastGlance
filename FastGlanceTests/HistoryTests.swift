import XCTest
@testable import FastGlance

final class HistoryTests: XCTestCase {
    func testRecordMergesAndKeepsLastConnected() throws {
        var h = DeviceHistory()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let t1 = t0.addingTimeInterval(100)

        XCTAssertTrue(h.record([Device(id: "bt:a", name: "A", kind: .headphones, isConnected: true)], now: t0))

        // Same id updates in place; disconnected keeps the old timestamp; new id inserts.
        XCTAssertTrue(h.record([
            Device(id: "bt:a", name: "A2", kind: .headphones, isConnected: false),
            Device(id: "usb:b", name: "B", kind: .usb, isConnected: true),
        ], now: t1))
        XCTAssertEqual(h.entries.count, 2)
        XCTAssertEqual(h.entries["bt:a"]?.name, "A2")
        XCTAssertEqual(h.entries["bt:a"]?.lastConnected, t0)
        XCTAssertEqual(h.entries["usb:b"]?.lastConnected, t1)

        // Disconnecting stamps the moment it went away.
        let t2 = t1.addingTimeInterval(50)
        h.markDisconnected(["usb:b"], now: t2)
        XCTAssertEqual(h.entries["usb:b"]?.lastConnected, t2)

        // A never-connected device takes the source's hint.
        var hinted = Device(id: "bt:c", name: "C", kind: .mouse, isConnected: false)
        hinted.lastConnected = t0
        h.record([hinted], now: t2)
        XCTAssertEqual(h.entries["bt:c"]?.lastConnected, t0)

        // Low case battery doesn't count as low.
        var buds = Device(id: "bt:d", name: "D", kind: .headphones, isConnected: true)
        buds.batteries = [Battery(label: "L", percent: 90), Battery(label: "R", percent: 80), Battery(label: "Case", percent: 10)]
        XCTAssertEqual(buds.lowestBattery, 80)

        // Nothing structural changed: only the timestamp moves.
        XCTAssertFalse(h.record([Device(id: "usb:b", name: "B", kind: .usb, isConnected: true)], now: t2))

        // Round-trips through disk; a corrupt file is moved aside, not lost.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        h.save(to: url)
        XCTAssertEqual(DeviceHistory.load(from: url), h)
        try Data("garbage".utf8).write(to: url)
        XCTAssertEqual(DeviceHistory.load(from: url).entries.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("corrupt.json").path))
    }
}
