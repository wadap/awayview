import XCTest
@testable import AwayView

final class SettingsStoreTests: XCTestCase {
    let suite = "awayview-unit-tests"
    var defaults: UserDefaults!
    var now: Date!
    var store: SettingsStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        now = ISO8601DateFormatter().date(from: "2026-07-25T10:00:00+09:00")!
        store = SettingsStore(defaults: defaults, now: { self.now })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // 未設定 = 従来と同一の既定値 (5900 / Tailscale 範囲 / 自動)
    func testDefaults() {
        XCTAssertEqual(store.port, 5900)
        XCTAssertEqual(store.cidrs, ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
        XCTAssertEqual(store.currentMode, .auto)
        XCTAssertFalse(store.overrideHigh)
        XCTAssertFalse(store.forceLow)
        XCTAssertNil(store.resLow)
        XCTAssertNil(store.resHigh)
        XCTAssertNil(store.modeChangedAt)
    }

    func testPortRoundTripAndInvalidFallback() {
        store.port = 5901
        XCTAssertEqual(store.port, 5901)
        defaults.set(0, forKey: "Port")       // defaults 手書きで壊された値は既定へ
        XCTAssertEqual(store.port, 5900)
        defaults.set(99999, forKey: "Port")
        XCTAssertEqual(store.port, 5900)
    }

    func testCIDRRoundTrip() {
        store.cidrs = ["192.168.0.0/16"]
        XCTAssertEqual(store.cidrs, ["192.168.0.0/16"])
        store.cidrs = []
        XCTAssertEqual(store.cidrs, [])       // 空リスト = 自動切替オフ (既定に戻さない)
    }

    // モードは排他 + 切替時刻を記録 (メニューの「(HH:mm〜)」表示用)
    func testModeIsExclusiveAndStampsTime() {
        store.setMode(.high)
        XCTAssertTrue(store.overrideHigh)
        XCTAssertFalse(store.forceLow)
        XCTAssertEqual(store.modeChangedAt, now)
        store.setMode(.low)
        XCTAssertFalse(store.overrideHigh)
        XCTAssertTrue(store.forceLow)
        store.setMode(.auto)
        XCTAssertEqual(store.currentMode, .auto)
        XCTAssertFalse(store.overrideHigh)
        XCTAssertFalse(store.forceLow)
    }

    func testResSelectionRoundTrip() {
        store.setResLow("1920x810")
        store.setResHigh("2560x1080")
        XCTAssertEqual(store.resLow, "1920x810")
        XCTAssertEqual(store.resHigh, "2560x1080")
        store.setResLow(nil)
        store.setResHigh(nil)
        XCTAssertNil(store.resLow)
        XCTAssertNil(store.resHigh)
    }
}
