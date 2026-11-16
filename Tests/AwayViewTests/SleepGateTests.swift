import XCTest
@testable import AwayView

final class SleepGateTests: XCTestCase {
    // 起動直後は開いている
    func testStartsOpen() {
        XCTAssertTrue(SleepGate().isOpen(now: 0))
    }

    // システムスリープ中は閉じ、復帰しても猶予が明けるまで開かない
    func testSystemSleepClosesUntilGraceAfterWake() {
        var gate = SleepGate()
        gate.systemWillSleep()
        XCTAssertFalse(gate.isOpen(now: 10))
        gate.systemDidWake(now: 100)
        XCTAssertFalse(gate.isOpen(now: 100))
        XCTAssertFalse(gate.isOpen(now: 100 + SleepGate.wakeGrace - 0.1))
        XCTAssertTrue(gate.isOpen(now: 100 + SleepGate.wakeGrace))
    }

    // ディスプレイスリープだけでも閉じる (システムは起きていて tick は回り続ける。
    // 11/12 の嵐はこの状態で起きた)
    func testScreenSleepClosesUntilGraceAfterWake() {
        var gate = SleepGate()
        gate.screensDidSleep()
        XCTAssertFalse(gate.isOpen(now: 10_000), "消灯中は何時間経っても開かない")
        gate.screensDidWake(now: 20_000)
        XCTAssertFalse(gate.isOpen(now: 20_000 + 1))
        XCTAssertTrue(gate.isOpen(now: 20_000 + SleepGate.wakeGrace))
    }

    // システムが復帰しても、ディスプレイが消えたままなら開かない
    func testStaysClosedWhileScreensStillAsleep() {
        var gate = SleepGate()
        gate.systemWillSleep()
        gate.screensDidSleep()
        gate.systemDidWake(now: 100)
        XCTAssertFalse(gate.isOpen(now: 200))
        gate.screensDidWake(now: 300)
        XCTAssertTrue(gate.isOpen(now: 300 + SleepGate.wakeGrace))
    }

    // 復帰通知が続けて届いたら、猶予は最後の通知から数える
    func testGraceRestartsFromLatestWake() {
        var gate = SleepGate()
        gate.systemDidWake(now: 100)
        gate.screensDidWake(now: 103)
        XCTAssertFalse(gate.isOpen(now: 100 + SleepGate.wakeGrace))
        XCTAssertTrue(gate.isOpen(now: 103 + SleepGate.wakeGrace))
    }

    // スリープを経ない復帰通知 (起動時点で消灯していた等) でも猶予は置く
    func testWakeWithoutSleepStillWaitsForGrace() {
        var gate = SleepGate()
        gate.screensDidWake(now: 50)
        XCTAssertFalse(gate.isOpen(now: 51))
        XCTAssertTrue(gate.isOpen(now: 50 + SleepGate.wakeGrace))
    }

    // 猶予中に再びスリープしたら、次の復帰まで閉じたまま
    func testSleepDuringGraceKeepsClosed() {
        var gate = SleepGate()
        gate.screensDidWake(now: 100)
        gate.screensDidSleep()
        XCTAssertFalse(gate.isOpen(now: 100 + SleepGate.wakeGrace))
    }
}
