import XCTest
@testable import FastGlance

final class MenuTests: XCTestCase {
    private func dev(_ id: String, _ name: String, _ kind: DeviceKind = .usb) -> Device {
        Device(id: id, name: name, kind: kind, isConnected: true)
    }

    func testSummarizeGroupsAndDropsFlaps() {
        let a = dev("a", "A"), b = dev("b", "B"), c = dev("c", "C"), f = dev("f", "Flappy")
        let n = Notifier.summarize([(a, true), (f, true), (b, true), (f, false), (c, true)])
        XCTAssertEqual(n.map(\.title), ["3 devices connected"])
        XCTAssertEqual(n.first?.body, "A, B, C")

        let two = Notifier.summarize([(a, true), (b, false)])
        XCTAssertEqual(two.map(\.title), ["A connected", "B disconnected"])
    }

    @MainActor func testActionSearch() {
        var buds = dev("bt:1", "AirPods Pro", .headphones)
        buds.info = [InfoRow("Address", "AA:BB")]
        let ssd = dev("disk:1", "Samsung SSD")
        func act(_ d: Device, _ key: String, _ title: String) -> DeviceAction { DeviceAction(d, key, title, "x") {} }
        let items = [(buds, [act(buds, "connection", "Disconnect"), act(buds, "out", "Use for Output")]),
                     (ssd, [act(ssd, "eject", "Eject"), act(ssd, "open", "Open in Finder")])]

        XCTAssertEqual(Search.actions(Search.words("eject ssd"), in: items).map(\.action.id), ["disk:1|eject"])
        // Every word must hit the title or the device, and at least one the title.
        XCTAssertEqual(Search.actions(Search.words("headphones"), in: items).count, 0)
        XCTAssertEqual(Search.actions(Search.words("connect headphones"), in: items).map(\.action.id), ["bt:1|connection"])
        XCTAssertTrue(Search.matches(buds, Search.words("aa:bb")))
        XCTAssertFalse(Search.matches(ssd, Search.words("airpods")))
    }
}
