import XCTest
@testable import AwayView

// zsh 版 tests/watcher.test.zsh のシナリオ移植。
// SETTLE は「二段階遷移」(接続検知 tick の次 tick で再確認して適用)。

final class MockConnection: ConnectionObserving {
    var ip: String?
    /// nil でない間は ip を無視して この値を返す (列挙失敗の再現用)
    var forced: ConnectionProbe?
    func probe() -> ConnectionProbe {
        if let forced { return forced }
        if let ip { return .remote(ip) }
        return ConnectionProbe.none
    }
}

final class MockDisplay: DisplayControlling {
    var applyLowSucceeds = true
    var restoreResult: RestoreResult = .ok
    private(set) var events: [String] = []

    func applyLow(_ resolution: String?) -> Bool {
        guard applyLowSucceeds else { events.append("applyLow:FAILED"); return false }
        events.append("applyLow:\(resolution ?? "default")")
        return true
    }

    func restoreHome(explicit resolution: String?) -> RestoreResult {
        switch restoreResult {
        case .ok: events.append("restore:\(resolution ?? "auto")")
        case .failed: events.append("restore:FAILED")
        case .noCache: events.append("restore:NOCACHE")
        }
        return restoreResult
    }

    func captureHome(onlyIfMissing: Bool) {
        events.append(onlyIfMissing ? "capture:ifMissing" : "capture:follow")
    }

    func count(_ prefix: String) -> Int { events.filter { $0.hasPrefix(prefix) }.count }
}

final class MockFlags: FlagReading {
    var overrideHigh = false
    var forceLow = false
    var resLow: String?
    var resHigh: String?
}

final class StateMachineTests: XCTestCase {
    var conn: MockConnection!
    var display: MockDisplay!
    var flags: MockFlags!
    var states: [(WatchState, String?)] = []
    var lowHooks = 0
    var highHooks = 0
    var unavailableCount = 0
    var sm: StateMachine!

    override func setUp() {
        super.setUp()
        conn = MockConnection()
        display = MockDisplay()
        flags = MockFlags()
        states = []
        lowHooks = 0
        highHooks = 0
        unavailableCount = 0
        sm = StateMachine(connection: conn, display: display, flags: flags) { [weak self] state, ip in
            self?.states.append((state, ip))
        }
        sm.onLowApplied = { [weak self] in self?.lowHooks += 1 }
        sm.onHighRestored = { [weak self] in self?.highHooks += 1 }
        sm.onProbeUnavailable = { [weak self] in self?.unavailableCount += 1 }
    }

    private var lastState: WatchState? { states.last?.0 }
    private var lastIP: String? { states.last?.1 }

    // 1) 起動直後・接続なし → home (キャッシュ無しでも前進し、追従 capture する)
    func testStartupNoConnectionIsHome() {
        display.restoreResult = .noCache
        sm.tick()
        XCTAssertEqual(lastState, .home)
        XCTAssertEqual(display.count("capture:follow"), 1)
    }

    // 2) 接続 → 二段階 SETTLE を経て low。REMOTE_IP が入り、
    //    下げる直前に capture(ifMissing) → applyLow の順で呼ばれ、on_low が発火
    func testRemoteConnectionLowersAfterSettle() {
        sm.tick()                       // home
        conn.ip = "100.99.1.2"
        sm.tick()                       // 一段階目: まだ下げない
        XCTAssertEqual(display.count("applyLow"), 0)
        sm.tick()                       // 二段階目: 適用
        XCTAssertEqual(lastState, .low)
        XCTAssertEqual(lastIP, "100.99.1.2")
        XCTAssertEqual(display.count("applyLow"), 1)
        let captureIdx = display.events.firstIndex(of: "capture:ifMissing")
        let applyIdx = display.events.firstIndex(of: "applyLow:default")
        XCTAssertNotNil(captureIdx)
        XCTAssertNotNil(applyIdx)
        XCTAssertLessThan(captureIdx!, applyIdx!, "capture は applyLow より先 (誤学習ガード)")
        XCTAssertEqual(lowHooks, 1)
    }

    // 3) 1 tick だけの瞬間接続では下げない
    func testMomentaryConnectionDoesNotLower() {
        sm.tick()
        conn.ip = "100.99.1.2"
        sm.tick()
        conn.ip = nil
        sm.tick()
        XCTAssertEqual(lastState, .home)
        XCTAssertEqual(display.count("applyLow"), 0)
    }

    // 4) 接続中に override → ホーム復帰して override。on_high 発火
    //    (起動時 tick でも restore + on_high が 1 回走るため差分で検証)
    func testOverrideDuringConnectionRestoresHigh() {
        goLow()
        let restoresBefore = display.count("restore")
        let hooksBefore = highHooks
        flags.overrideHigh = true
        sm.tick()
        XCTAssertEqual(lastState, .override)
        XCTAssertEqual(display.count("restore"), restoresBefore + 1)
        XCTAssertEqual(highHooks, hooksBefore + 1)
        XCTAssertEqual(lastIP, "100.99.1.2", "固定中も接続元 IP は表示用に保持")
    }

    // 5) 接続中に override 解除 → SETTLE を経て low へ戻る
    func testOverrideReleaseDuringConnectionLowersAgain() {
        goLow()
        flags.overrideHigh = true
        sm.tick()
        flags.overrideHigh = false
        sm.tick()   // 一段階目
        sm.tick()   // 二段階目
        XCTAssertEqual(lastState, .low)
    }

    // 6) 切断 → home。on_high 発火 (起動時分があるため差分で検証)
    func testDisconnectRestoresHome() {
        goLow()
        let hooksBefore = highHooks
        conn.ip = nil
        sm.tick()
        XCTAssertEqual(lastState, .home)
        XCTAssertEqual(highHooks, hooksBefore + 1)
    }

    // 7) 復帰失敗中は state が前進せず capture もしない。成功したら override
    func testFailedRestoreDoesNotAdvance() {
        goLow()
        let capturesBefore = display.count("capture")
        flags.overrideHigh = true
        display.restoreResult = .failed
        sm.tick()
        sm.tick()
        XCTAssertEqual(lastState, .low, "復帰失敗中は state を進めない")
        XCTAssertEqual(display.count("capture"), capturesBefore, "失敗中は capture しない (誤学習ガード)")
        display.restoreResult = .ok
        sm.tick()
        XCTAssertEqual(lastState, .override)
    }

    // 8) force_low → SETTLE なしで即 low_manual。解除で home
    func testForceLowIsImmediate() {
        sm.tick()
        flags.forceLow = true
        sm.tick()
        XCTAssertEqual(lastState, .lowManual)
        XCTAssertEqual(display.count("applyLow"), 1)
        flags.forceLow = false
        sm.tick()
        XCTAssertEqual(lastState, .home)
    }

    // 9) override は force_low より優先される
    func testOverrideBeatsForceLow() {
        sm.tick()
        flags.forceLow = true
        flags.overrideHigh = true
        sm.tick()
        XCTAssertEqual(lastState, .override)
        XCTAssertEqual(display.count("applyLow"), 0)
    }

    // 10) res_low 選択が渡り、適用中の変更は即再適用。同値なら再適用しない
    func testResLowChangeReappliesImmediately() {
        sm.tick()
        flags.forceLow = true
        flags.resLow = "1280x540"
        sm.tick()
        XCTAssertEqual(display.events.last, "applyLow:1280x540")
        flags.resLow = "960x540"
        sm.tick()
        XCTAssertEqual(display.events.last, "applyLow:960x540")
        XCTAssertEqual(lastState, .lowManual)
        sm.tick()
        XCTAssertEqual(display.count("applyLow"), 2, "同値では再適用しない")
    }

    // 11) res_high 明示指定は home でも即適用され、同値では再適用しない
    func testResHighChangeReappliesInHome() {
        sm.tick()
        flags.resHigh = "3200x1350"
        sm.tick()
        XCTAssertEqual(display.events.last { $0.hasPrefix("restore") }, "restore:3200x1350")
        let restores = display.count("restore")
        sm.tick()
        XCTAssertEqual(display.count("restore"), restores, "同値では再適用しない")
    }

    // 12) applyLow 失敗時は state を進めず次 tick でリトライ
    func testFailedApplyLowRetries() {
        sm.tick()
        flags.forceLow = true
        display.applyLowSucceeds = false
        sm.tick()
        XCTAssertEqual(lastState, .home, "適用失敗中は state を進めない")
        display.applyLowSucceeds = true
        sm.tick()
        XCTAssertEqual(lastState, .lowManual)
    }

    // --- helper -----------------------------------------------------------
    // 13) 列挙失敗 (不明) を「接続なし」に倒さない。
    //     low 中に不明になっても復帰を試みない (試みても画面共有中は CG に
    //     拒否され、10 秒ごとに無音でリトライし続ける原因になる)
    func testUnavailableProbeDoesNotRestoreWhileLow() {
        goLow()
        let restoresBefore = display.count("restore")
        conn.forced = .unavailable
        sm.tick()
        sm.tick()
        XCTAssertEqual(display.count("restore"), restoresBefore,
                       "不明の間は復帰を試みない")
        XCTAssertEqual(lastState, .low, "状態は low のまま据え置く")
    }

    // 14) home 中に不明になっても home を再確認しない。
    //     特に capture(follow) を走らせない (不明な瞬間の配置を学習させない)
    func testUnavailableProbeDoesNotCaptureWhileHome() {
        sm.tick()
        precondition(lastState == .home)
        let capturesBefore = display.count("capture:follow")
        conn.forced = .unavailable
        sm.tick()
        XCTAssertEqual(display.count("capture:follow"), capturesBefore,
                       "不明の間はホーム追従 capture をしない")
    }

    // 15) 不明は SETTLE の二段階確認を巻き戻さない。
    //     remote → unavailable → remote は「連続 2 回の肯定的観測」として扱う
    func testUnavailableProbeDoesNotResetSettling() {
        sm.tick()                        // home
        conn.ip = "100.99.1.2"
        sm.tick()                        // 一段階目
        conn.forced = .unavailable
        sm.tick()                        // 不明: 何もしない
        conn.forced = nil
        sm.tick()                        // 二段階目として成立する
        XCTAssertEqual(lastState, .low)
        XCTAssertEqual(display.count("applyLow"), 1)
    }

    // 16) 不明は観測可能にする (無音で増幅させない)
    func testUnavailableProbeIsReported() {
        sm.tick()
        conn.forced = .unavailable
        sm.tick()
        sm.tick()
        XCTAssertEqual(unavailableCount, 2)
    }

    private func goLow() {
        sm.tick()
        conn.ip = "100.99.1.2"
        sm.tick()
        sm.tick()
        precondition(states.last?.0 == .low)
    }
}
