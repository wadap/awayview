import XCTest
@testable import AwayView

final class LogThrottleTests: XCTestCase {
    let failure = "!! complete configuration failed: 3840x1620"

    // 初回はそのまま出す
    func testFirstOccurrencePassesThrough() {
        var t = LogThrottle()
        XCTAssertEqual(t.filter(failure, now: 0), failure)
    }

    // 同じ文言の連続は、要約の間隔 (10 分) が空くまで黙る
    func testRepeatsAreSuppressedWithinInterval() {
        var t = LogThrottle()
        _ = t.filter(failure, now: 0)
        XCTAssertNil(t.filter(failure, now: 60))
        XCTAssertNil(t.filter(failure, now: 599))
    }

    // 間隔が空いたら、連続回数を添えて 1 行だけ出す
    func testSummaryIsEmittedAfterInterval() {
        var t = LogThrottle()
        _ = t.filter(failure, now: 0)
        _ = t.filter(failure, now: 60)
        _ = t.filter(failure, now: 120)
        XCTAssertEqual(t.filter(failure, now: 600), "\(failure) (4 consecutive failures)")
        XCTAssertNil(t.filter(failure, now: 660), "要約のあとはまた黙る")
        XCTAssertEqual(t.filter(failure, now: 1200), "\(failure) (6 consecutive failures)")
    }

    // 文言が変わったら連続扱いにせず、すぐ出す
    func testDifferentMessageIsNotSuppressed() {
        var t = LogThrottle()
        _ = t.filter(failure, now: 0)
        let other = "!! home mode not found: 3840x1620"
        XCTAssertEqual(t.filter(other, now: 1), other)
        XCTAssertEqual(t.filter(failure, now: 2), failure)
    }

    // reset (適用成功・保留への遷移) のあとは初回として出す
    func testResetStartsOver() {
        var t = LogThrottle()
        _ = t.filter(failure, now: 0)
        t.reset()
        XCTAssertEqual(t.filter(failure, now: 1), failure)
    }
}
