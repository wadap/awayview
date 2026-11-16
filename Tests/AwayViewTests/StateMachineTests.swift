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
    var applyLowResult: ApplyResult = .ok
    var restoreResult: RestoreResult = .ok
    private(set) var events: [String] = []

    func applyLow(_ resolution: String?) -> ApplyResult {
        switch applyLowResult {
        case .ok: events.append("applyLow:\(resolution ?? "default")")
        case .failed: events.append("applyLow:FAILED")
        case .deferred: events.append("applyLow:DEFERRED")
        }
        return applyLowResult
    }

    func restoreHome(explicit resolution: String?) -> RestoreResult {
        switch restoreResult {
        case .ok: events.append("restore:\(resolution ?? "auto")")
        case .failed: events.append("restore:FAILED")
        case .noCache: events.append("restore:NOCACHE")
        case .deferred: events.append("restore:DEFERRED")
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
    /// テスト用の時計。tick() が 1 回読むたびに step 秒進む (= 3 秒 tick の再現)
    var time: TimeInterval = 0
    var step: TimeInterval = 3

    override func setUp() {
        super.setUp()
        conn = MockConnection()
        display = MockDisplay()
        flags = MockFlags()
        states = []
        lowHooks = 0
        highHooks = 0
        unavailableCount = 0
        time = 1000
        step = 3
        sm = StateMachine(connection: conn, display: display, flags: flags,
                          clock: { [unowned self] in
                              self.time += self.step
                              return self.time
                          }) { [weak self] state, ip in
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
        time += 60                      // バックオフ明け
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
        display.applyLowResult = .failed
        sm.tick()
        XCTAssertEqual(lastState, .home, "適用失敗中は state を進めない")
        display.applyLowResult = .ok
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

    // 17) 復帰が保留 (ディスプレイ未準備) の間は前進せず、hooks も capture も走らない
    func testDeferredRestoreDoesNotAdvance() {
        goLow()
        let hooksBefore = highHooks
        let capturesBefore = display.count("capture")
        conn.ip = nil
        display.restoreResult = .deferred
        sm.tick()
        sm.tick()
        sm.tick()
        XCTAssertEqual(lastState, .low, "保留中は state を進めない")
        XCTAssertEqual(highHooks, hooksBefore, "保留中は on_high を発火しない")
        XCTAssertEqual(display.count("capture"), capturesBefore, "保留中は capture しない (誤学習ガード)")
    }

    // 18) 保留が明けて ok が返ったら HIGH へ遷移し、on_high が 1 回だけ発火する
    func testDeferredRestoreAdvancesOnceReady() {
        goLow()
        let hooksBefore = highHooks
        conn.ip = nil
        display.restoreResult = .deferred
        sm.tick()
        sm.tick()
        display.restoreResult = .ok
        sm.tick()
        XCTAssertEqual(lastState, .home)
        XCTAssertEqual(highHooks, hooksBefore + 1)
        XCTAssertEqual(display.count("capture:follow"), 2, "起動時と復帰時の 2 回だけ追従する")
    }

    // 19) 低解像度の適用が保留の間も前進せず on_low を発火しない。明けたら適用する
    func testDeferredApplyLowDoesNotAdvance() {
        sm.tick()
        conn.ip = "100.99.1.2"
        display.applyLowResult = .deferred
        sm.tick()                       // 一段階目
        sm.tick()                       // 二段階目: 保留
        sm.tick()
        XCTAssertEqual(lastState, .home, "保留中は state を進めない")
        XCTAssertEqual(lowHooks, 0, "保留中は on_low を発火しない")
        display.applyLowResult = .ok
        sm.tick()
        sm.tick()
        XCTAssertEqual(lastState, .low)
        XCTAssertEqual(lowHooks, 1)
    }

    // 20) 復帰の連続失敗はバックオフで間引かれる (3s → 10s → 30s → 60s)。
    //     3 秒 tick を 40 回 (約 2 分) 回しても試行は 0/3/15/45/105 秒の 5 回だけ
    func testRepeatedRestoreFailuresBackOff() {
        goLow()
        conn.ip = nil
        display.restoreResult = .failed
        for _ in 0..<40 { sm.tick() }
        XCTAssertEqual(display.count("restore:FAILED"), 5)
        XCTAssertEqual(lastState, .low, "失敗中は state を進めない")
    }

    // 21) 低解像度の適用失敗も同じバックオフに乗る
    func testRepeatedApplyLowFailuresBackOff() {
        sm.tick()
        flags.forceLow = true
        display.applyLowResult = .failed
        for _ in 0..<40 { sm.tick() }
        XCTAssertEqual(display.count("applyLow:FAILED"), 5)
    }

    // 22) バックオフは上限 60 秒で頭打ちになり、それ以上は伸びない
    func testBackoffIsCappedAtSixtySeconds() {
        goLow()
        conn.ip = nil
        display.restoreResult = .failed
        for _ in 0..<40 { sm.tick() }            // 0/3/15/45/105 秒
        let before = display.count("restore:FAILED")
        for _ in 0..<100 { sm.tick() }           // さらに 300 秒 → 60 秒ごとに 5 回
        XCTAssertEqual(display.count("restore:FAILED"), before + 5)
    }

    // 23) 接続状態が変わったらバックオフをリセットし、次の機会にすぐ試す
    func testConnectionChangeResetsBackoff() {
        goLow()
        conn.ip = nil
        display.restoreResult = .failed
        for _ in 0..<10 { sm.tick() }            // 0/3/15 秒で 3 回。次は 45 秒
        XCTAssertEqual(display.count("restore:FAILED"), 3)
        conn.ip = "100.99.1.2"
        sm.tick()                                // 再接続: low のまま (表示操作なし)
        conn.ip = nil
        sm.tick()                                // 切断: 6 秒しか経っていないが即試行
        XCTAssertEqual(display.count("restore:FAILED"), 4)
    }

    // 24) モードや解像度の選び直しでもリセットする (メニュー操作を待たせない)
    func testFlagChangeResetsBackoff() {
        goLow()
        conn.ip = nil
        display.restoreResult = .failed
        for _ in 0..<10 { sm.tick() }
        XCTAssertEqual(display.count("restore:FAILED"), 3)
        flags.resHigh = "3200x1350"
        sm.tick()
        XCTAssertEqual(display.count("restore:FAILED"), 4)
    }

    // 25) 保留を挟んだら連続失敗を数え直す (ディスプレイの状態が変わった合図)
    func testDeferredResetsBackoff() {
        goLow()
        conn.ip = nil
        display.restoreResult = .failed
        sm.tick()                                // 0 秒: 失敗
        sm.tick()                                // 3 秒: 失敗 → 次は 13 秒以降
        display.restoreResult = .deferred
        for _ in 0..<4 { sm.tick() }             // 15 秒で保留を観測 → リセット
        display.restoreResult = .failed
        sm.tick()                                // 直後の tick で試行される
        XCTAssertEqual(display.count("restore:FAILED"), 3)
    }

    // 26) 不明 (列挙失敗) は接続状態の変化として数えない
    func testUnavailableProbeDoesNotResetBackoff() {
        goLow()
        conn.ip = nil
        display.restoreResult = .failed
        for _ in 0..<10 { sm.tick() }
        XCTAssertEqual(display.count("restore:FAILED"), 3)
        conn.forced = .unavailable
        sm.tick()
        conn.forced = nil
        sm.tick()
        XCTAssertEqual(display.count("restore:FAILED"), 3, "不明を挟んでもバックオフは続く")
    }

    // 27) resetBackoff() (スリープ復帰時に呼ぶ) で次の tick からすぐ試す
    func testResetBackoffAllowsImmediateRetry() {
        goLow()
        conn.ip = nil
        display.restoreResult = .failed
        for _ in 0..<10 { sm.tick() }
        XCTAssertEqual(display.count("restore:FAILED"), 3)
        sm.resetBackoff()
        display.restoreResult = .ok
        sm.tick()
        XCTAssertEqual(lastState, .home)
    }

    private func goLow() {
        sm.tick()
        conn.ip = "100.99.1.2"
        sm.tick()
        sm.tick()
        precondition(states.last?.0 == .low)
    }
}
