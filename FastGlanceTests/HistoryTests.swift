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

        // Nothing structural changed: only the timestamp moves.
        XCTAssertFalse(h.record([Device(id: "usb:b", name: "B", kind: .usb, isConnected: true)], now: t1))

        // Round-trips through disk; a corrupt file is moved aside, not lost.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        h.save(to: url)
        XCTAssertEqual(DeviceHistory.load(from: url), h)
        try Data("garbage".utf8).write(to: url)
        XCTAssertEqual(DeviceHistory.load(from: url).entries.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("corrupt.json").path))
    }
}
