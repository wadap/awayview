import CoreGraphics
import XCTest
@testable import AwayView

/// CG を叩かずにディスプレイ構成を再現する。id → (UUID, 内蔵か, 準備完了か)
final class FakeDisplayEnvironment: DisplayEnvironment {
    struct Display {
        let uuid: String
        var builtin = false
        var ready = true
    }

    var displays: [CGDirectDisplayID: Display] = [:]
    /// 列挙順 (CGGetOnlineDisplayList の順序に相当)
    var order: [CGDirectDisplayID] = []

    func add(_ id: CGDirectDisplayID, uuid: String, builtin: Bool = false, ready: Bool = true) {
        displays[id] = Display(uuid: uuid, builtin: builtin, ready: ready)
        order.append(id)
    }

    func remove(_ id: CGDirectDisplayID) {
        displays[id] = nil
        order.removeAll { $0 == id }
    }

    func onlineDisplays() -> [CGDirectDisplayID] { order }
    func uuidString(for id: CGDirectDisplayID) -> String? { displays[id]?.uuid }
    func isBuiltin(_ id: CGDirectDisplayID) -> Bool { displays[id]?.builtin ?? false }
    func isReady(_ id: CGDirectDisplayID) -> Bool { displays[id]?.ready ?? false }
}

final class RealDisplayControllerTests: XCTestCase {
    let suite = "awayview-unit-tests-display"
    // 実在しえない ID にする。小さい値 (1, 2...) は実機のディスプレイ ID と衝突し、
    // ガードをすり抜けた呼び出しが本物の CG に届いて実機の解像度を変えてしまう
    let builtin: CGDirectDisplayID = 0xDEAD_0001
    let external: CGDirectDisplayID = 0xDEAD_0002
    var defaults: UserDefaults!
    var env: FakeDisplayEnvironment!
    var logs: [String] = []
    var dc: RealDisplayController!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        env = FakeDisplayEnvironment()
        logs = []
        dc = RealDisplayController(defaults: defaults, environment: env)
        dc.log = { [unowned self] in self.logs.append($0) }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private var savedUUID: String? { defaults.string(forKey: "TargetDisplayUUID") }

    // --- resolveTarget ----------------------------------------------------

    // 初回 (UUID 未保存): 外部ディスプレイを優先して選び、UUID を保存する
    func testFirstRunPicksExternalAndSaves() {
        env.add(builtin, uuid: "BUILTIN", builtin: true)
        env.add(external, uuid: "EXTERNAL")
        XCTAssertEqual(dc.resolveTarget(), external)
        XCTAssertEqual(savedUUID, "EXTERNAL")
    }

    // 初回で外部が無ければ内蔵を選ぶ (従来どおり)
    func testFirstRunFallsBackToBuiltin() {
        env.add(builtin, uuid: "BUILTIN", builtin: true)
        XCTAssertEqual(dc.resolveTarget(), builtin)
        XCTAssertEqual(savedUUID, "BUILTIN")
    }

    // 保存済み UUID がオンラインならそれを返す (列挙順や内蔵/外部に左右されない)
    func testSavedTargetIsUsedWhenOnline() {
        defaults.set("BUILTIN", forKey: "TargetDisplayUUID")
        env.add(external, uuid: "EXTERNAL")
        env.add(builtin, uuid: "BUILTIN", builtin: true)
        XCTAssertEqual(dc.resolveTarget(), builtin)
        XCTAssertEqual(savedUUID, "BUILTIN")
    }

    // 保存済み UUID が一覧に無いとき、別のディスプレイを選ばず UUID も上書きしない。
    // クラムシェル復帰中に外部が一瞬消え、内蔵だけが見えている瞬間の再現
    func testMissingSavedTargetIsNotReplaced() {
        defaults.set("EXTERNAL", forKey: "TargetDisplayUUID")
        env.add(builtin, uuid: "BUILTIN", builtin: true)
        XCTAssertNil(dc.resolveTarget())
        XCTAssertEqual(savedUUID, "EXTERNAL", "不在の間に UUID を書き換えない")
    }

    // 不在だったディスプレイが戻ったら、そのまま元のターゲットに復帰する
    func testSavedTargetResumesWhenItComesBack() {
        defaults.set("EXTERNAL", forKey: "TargetDisplayUUID")
        env.add(builtin, uuid: "BUILTIN", builtin: true)
        XCTAssertNil(dc.resolveTarget())
        env.add(external, uuid: "EXTERNAL")
        XCTAssertEqual(dc.resolveTarget(), external)
        XCTAssertEqual(savedUUID, "EXTERNAL")
    }

    // ディスプレイが 1 台も無ければ nil。初回でも何も保存しない
    func testNoDisplaysResolvesToNil() {
        XCTAssertNil(dc.resolveTarget())
        XCTAssertNil(savedUUID)
    }

    // --- 適用直前のガード ---------------------------------------------------

    // ディスプレイが未準備 (スリープ中など) なら CG を呼ばずに保留を返す
    func testApplyLowIsDeferredWhileDisplayNotReady() {
        env.add(external, uuid: "EXTERNAL", ready: false)
        XCTAssertEqual(dc.applyLow(nil), .deferred)
        XCTAssertEqual(dc.applyLow("1920x1080"), .deferred)
    }

    func testRestoreHomeIsDeferredWhileDisplayNotReady() {
        env.add(external, uuid: "EXTERNAL", ready: false)
        XCTAssertEqual(dc.restoreHome(explicit: nil), .deferred)
        XCTAssertEqual(dc.restoreHome(explicit: "3840x1620"), .deferred)
    }

    // ターゲット不在も失敗ではなく保留 (待てば戻る。バックオフを積ませない)
    func testMissingTargetIsDeferred() {
        defaults.set("EXTERNAL", forKey: "TargetDisplayUUID")
        env.add(builtin, uuid: "BUILTIN", builtin: true)
        XCTAssertEqual(dc.applyLow(nil), .deferred)
        XCTAssertEqual(dc.restoreHome(explicit: nil), .deferred)
        XCTAssertEqual(dc.restoreHome(explicit: "3840x1620"), .deferred)
    }

    // 保留のログは入ったときに 1 回だけ。毎 tick 呼ばれても連打しない
    func testDeferralIsLoggedOnce() {
        env.add(external, uuid: "EXTERNAL", ready: false)
        for _ in 0..<5 { _ = dc.restoreHome(explicit: nil) }
        _ = dc.applyLow(nil)
        XCTAssertEqual(logs, ["-- display not ready; deferring display changes"])
    }

    // 準備できたら保留を抜け、抜けたことも 1 回だけ記録する
    // (ホーム未学習なので .noCache で返り、CG の適用までは進まない)
    func testLeavingDeferralIsLoggedOnce() {
        env.add(external, uuid: "EXTERNAL", ready: false)
        _ = dc.restoreHome(explicit: nil)
        env.displays[external]?.ready = true
        XCTAssertEqual(dc.restoreHome(explicit: nil), .noCache)
        XCTAssertEqual(dc.restoreHome(explicit: nil), .noCache)
        XCTAssertEqual(logs, ["-- display not ready; deferring display changes",
                              "-- display ready"])
    }

    // ホーム学習の誤学習ガードは注入後も効く: 未準備なら capture しない
    func testCaptureHomeSkipsWhileDisplayNotReady() {
        env.add(external, uuid: "EXTERNAL", ready: false)
        dc.captureHome(onlyIfMissing: false)
        XCTAssertNil(dc.storedHome())
    }
}
