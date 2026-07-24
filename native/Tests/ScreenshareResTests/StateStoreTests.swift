import XCTest
@testable import ScreenshareRes

final class StateStoreTests: XCTestCase {
    var dir: URL!
    var now: Date!
    var store: StateStore!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssr-test-\(UUID().uuidString)")
        now = ISO8601DateFormatter().date(from: "2026-07-24T10:00:00+09:00")!
        store = StateStore(directory: dir, now: { self.now })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    // state ファイルは zsh 版と同一フォーマット (値はダブルクォート・3 行)
    func testStateFileFormatMatchesLegacy() {
        store.writeState(.low, remoteIP: "100.99.1.2")
        XCTAssertEqual(read("state"), """
        STATE="low"
        REMOTE_IP="100.99.1.2"
        CHANGED_AT="2026-07-24 10:00:00"

        """)
    }

    func testStateLowManualUsesLegacyRawValue() {
        store.writeState(.lowManual, remoteIP: nil)
        XCTAssertTrue(read("state")!.hasPrefix("STATE=\"low_manual\"\nREMOTE_IP=\"\"\n"))
    }

    // 変化が無ければ書き換えない (CHANGED_AT が動かないことで検証)
    func testStateWriteIsChangeOnly() {
        store.writeState(.home, remoteIP: nil)
        now = now.addingTimeInterval(60)
        store.writeState(.home, remoteIP: nil)
        XCTAssertTrue(read("state")!.contains("CHANGED_AT=\"2026-07-24 10:00:00\""))
        store.writeState(.low, remoteIP: "100.99.1.2")
        XCTAssertTrue(read("state")!.contains("CHANGED_AT=\"2026-07-24 10:01:00\""))
    }

    // モード切替は排他 (プラグインの mode サブコマンドと同じ意味論)
    func testSetModeIsExclusive() {
        store.setMode(.high)
        XCTAssertTrue(store.overrideHigh)
        XCTAssertFalse(store.forceLow)
        store.setMode(.low)
        XCTAssertFalse(store.overrideHigh)
        XCTAssertTrue(store.forceLow)
        store.setMode(.auto)
        XCTAssertFalse(store.overrideHigh)
        XCTAssertFalse(store.forceLow)
    }

    // 解像度選択の保存と解除 (WxH のみ・末尾改行は読み飛ばす)
    func testResSelection() {
        XCTAssertNil(store.resLow)
        XCTAssertNil(store.resHigh)
        store.setResLow("1920x810")
        store.setResHigh("2560x1080")
        XCTAssertEqual(store.resLow, "1920x810")
        XCTAssertEqual(store.resHigh, "2560x1080")
        XCTAssertEqual(read("res_low"), "1920x810\n")
        store.setResLow(nil)
        store.setResHigh(nil)
        XCTAssertNil(store.resLow)
        XCTAssertNil(store.resHigh)
        XCTAssertNil(read("res_low"))
    }

    // legacy (プラグイン/手動 touch) が書いたフラグも読める
    func testReadsExternallyTouchedFlags() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("override").path, contents: nil)
        XCTAssertTrue(store.overrideHigh)
        try "960x540\n".write(to: dir.appendingPathComponent("res_low"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.resLow, "960x540")
    }

    // watch.log へ zsh 版と同じフォーマットで追記
    func testLogFormat() {
        store.log("-> LOW (manual)")
        store.log("-> HIGH (restored)")
        XCTAssertEqual(read("watch.log"), """
        2026-07-24 10:00:00 -> LOW (manual)
        2026-07-24 10:00:00 -> HIGH (restored)

        """)
    }
}
