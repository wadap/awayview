import XCTest
@testable import AwayView

final class ObservationWriterTests: XCTestCase {
    var dir: URL!
    var now: Date!
    var writer: ObservationWriter!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("awayview-test-\(UUID().uuidString)")
        now = ISO8601DateFormatter().date(from: "2026-07-24T10:00:00+09:00")!
        // 期待値を JST 表記で書いているので TZ を固定する。
        // 固定しないとランナー (UTC) とローカル (JST) で結果が変わる
        writer = ObservationWriter(directory: dir, now: { self.now },
                                   timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    // state ファイルは従来フォーマット (値はダブルクォート・3 行)
    func testStateFileFormat() {
        writer.writeState(.low, remoteIP: "100.99.1.2")
        XCTAssertEqual(read("state"), """
        STATE="low"
        REMOTE_IP="100.99.1.2"
        CHANGED_AT="2026-07-24 10:00:00"

        """)
    }

    func testStateLowManualRawValue() {
        writer.writeState(.lowManual, remoteIP: nil)
        XCTAssertTrue(read("state")!.hasPrefix("STATE=\"low_manual\"\nREMOTE_IP=\"\"\n"))
    }

    // 変化が無ければ書き換えない (CHANGED_AT が動かないことで検証)
    func testStateWriteIsChangeOnly() {
        writer.writeState(.home, remoteIP: nil)
        now = now.addingTimeInterval(60)
        writer.writeState(.home, remoteIP: nil)
        XCTAssertTrue(read("state")!.contains("CHANGED_AT=\"2026-07-24 10:00:00\""))
        writer.writeState(.low, remoteIP: "100.99.1.2")
        XCTAssertTrue(read("state")!.contains("CHANGED_AT=\"2026-07-24 10:01:00\""))
    }

    func testLogFormat() {
        writer.log("-> LOW (manual)")
        writer.log("-> HIGH (restored)")
        XCTAssertEqual(read("watch.log"), """
        2026-07-24 10:00:00 -> LOW (manual)
        2026-07-24 10:00:00 -> HIGH (restored)

        """)
    }
}
