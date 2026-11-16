import CoreGraphics
import Foundation

// Swift に公開されていない CG シンボル。displayplacer の persistent id と同じ UUID を返す
@_silgen_name("CGDisplayCreateUUIDFromDisplayID")
func CGDisplayCreateUUIDFromDisplayID(_ display: UInt32) -> Unmanaged<CFUUID>?

/// CoreGraphics 直叩きの表示制御。まずはモード列挙（Task 1 スパイク範囲）。
struct DisplayModeInfo {
    let width: Int        // ポイント解像度
    let height: Int
    let pixelWidth: Int   // 物理ピクセル
    let pixelHeight: Int
    let refreshRate: Double
    let mode: CGDisplayMode?   // テスト用フィクスチャでは nil

    var isHiDPI: Bool { pixelWidth > width }
    var resString: String { "\(width)x\(height)" }
}

enum DisplayController {
    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// HiDPI(scaled) モードを含む全モード。displayplacer 相当の一覧が取れるかの検証対象
    static func allModes(for id: CGDirectDisplayID) -> [DisplayModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue!] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return [] }
        return raw.map {
            DisplayModeInfo(width: $0.width, height: $0.height,
                            pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight,
                            refreshRate: $0.refreshRate, mode: $0)
        }
    }

    /// "WxH" に一致するモード (HiDPI 優先、次にリフレッシュレート)
    static func findMode(_ res: String, in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        let parts = res.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return modes
            .filter { $0.width == w && $0.height == h }
            .max { ($0.isHiDPI ? 1 : 0, $0.refreshRate) < ($1.isHiDPI ? 1 : 0, $1.refreshRate) }
    }

    /// 低解像度の既定 = ホームの半分 (同アスペクト・HiDPI 優先)。
    /// ちょうど半分が無ければ同アスペクトで半分以下の最大を選ぶ
    static func defaultLowMode(homeWidth: Int, homeHeight: Int,
                               in modes: [DisplayModeInfo]) -> DisplayModeInfo? {
        guard homeWidth > 0, homeHeight > 0 else { return nil }
        let halfW = homeWidth / 2
        let halfH = homeHeight / 2
        if let exact = findMode("\(halfW)x\(halfH)", in: modes) { return exact }
        let aspect = Double(homeWidth) / Double(homeHeight)
        return modes
            .filter {
                $0.width <= halfW &&
                abs(Double($0.width) / Double($0.height) - aspect) < 0.02
            }
            .max { ($0.width, $0.isHiDPI ? 1 : 0, $0.refreshRate) < ($1.width, $1.isHiDPI ? 1 : 0, $1.refreshRate) }
    }
}

// ---------------------------------------------------------------------------
// ディスプレイの列挙と状態問い合わせ。RealDisplayController に注入することで、
// 「保存済みディスプレイが一瞬消える」「スリープ中」をテストで再現できる。
// ---------------------------------------------------------------------------

protocol DisplayEnvironment {
    func onlineDisplays() -> [CGDirectDisplayID]
    func uuidString(for id: CGDirectDisplayID) -> String?
    func isBuiltin(_ id: CGDirectDisplayID) -> Bool
    /// 構成変更を受け付けられる状態か (アクティブ・オンライン・スリープしていない)
    func isReady(_ id: CGDirectDisplayID) -> Bool
}

struct SystemDisplayEnvironment: DisplayEnvironment {
    func onlineDisplays() -> [CGDirectDisplayID] { DisplayController.onlineDisplays() }
    func uuidString(for id: CGDirectDisplayID) -> String? { DisplayController.uuidString(for: id) }
    func isBuiltin(_ id: CGDirectDisplayID) -> Bool { CGDisplayIsBuiltin(id) != 0 }
    func isReady(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsActive(id) != 0 && CGDisplayIsOnline(id) != 0 && CGDisplayIsAsleep(id) == 0
    }
}

// ---------------------------------------------------------------------------
// DisplayControlling の実装 (CG 直叩き)。ホーム自動学習は UserDefaults に永続化
// (UUID/WxH/isHiDPI)。home.cmd は legacy 専用なので触らない。
// ---------------------------------------------------------------------------

final class RealDisplayController: DisplayControlling {
    static let suiteName = "com.wadap.AwayView"

    private let defaults: UserDefaults
    private let environment: DisplayEnvironment
    var log: (String) -> Void = { _ in }
    private let clock: () -> TimeInterval
    private var deferring = false   // 保留中か (出入りのログを 1 回ずつにするため)
    private var failureLog = LogThrottle()

    // suiteName が自 bundle id と同一のとき UserDefaults(suiteName:) は nil を
    // 返す (.app 実行時)。その場合 .standard が同じドメインを指すのでフォールバック
    init(defaults: UserDefaults = UserDefaults(suiteName: RealDisplayController.suiteName) ?? .standard,
         environment: DisplayEnvironment = SystemDisplayEnvironment(),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.environment = environment
        self.clock = clock
    }

    // --- 対象ディスプレイ (外部優先で選出し UUID を記憶) -------------------

    /// 自動選出するのは初回 (UUID 未保存) だけ。保存済みのディスプレイが一覧に
    /// 無いときは nil を返し、別のディスプレイへ切り替えない。クラムシェル復帰中は
    /// 外部ディスプレイが一瞬消えるので、そこで切り替えて UUID を上書きすると
    /// 別のディスプレイにホーム解像度を当てに行ってしまう (実機で発生済み)
    func resolveTarget() -> CGDirectDisplayID? {
        let displays = environment.onlineDisplays()
        guard !displays.isEmpty else { return nil }
        if let saved = defaults.string(forKey: "TargetDisplayUUID") {
            return displays.first { environment.uuidString(for: $0) == saved }
        }
        // 型注釈は必須: 省くと Swift 6.1 が ?? を Optional 側のオーバーロードに
        // 解決してしまう (6.3 では非 Optional に倒れるのでローカルでは気づけない)
        let target: CGDirectDisplayID = displays.first { !environment.isBuiltin($0) } ?? displays[0]
        if let uuid = environment.uuidString(for: target) {
            defaults.set(uuid, forKey: "TargetDisplayUUID")
        }
        return target
    }

    // --- ホーム学習 (UserDefaults) ----------------------------------------

    struct HomeMode {
        let width: Int
        let height: Int
        let isHiDPI: Bool
    }

    func storedHome() -> HomeMode? {
        let w = defaults.integer(forKey: "HomeWidth")
        let h = defaults.integer(forKey: "HomeHeight")
        guard w > 0, h > 0 else { return nil }
        return HomeMode(width: w, height: h, isHiDPI: defaults.bool(forKey: "HomeIsHiDPI"))
    }

    func clearHome() {
        defaults.removeObject(forKey: "HomeWidth")
        defaults.removeObject(forKey: "HomeHeight")
        defaults.removeObject(forKey: "HomeIsHiDPI")
    }

    // --- DisplayControlling -----------------------------------------------

    func applyLow(_ resolution: String?) -> ApplyResult {
        guard let id = readyTarget() else { return .deferred }
        let modes = DisplayController.allModes(for: id)
        let target: DisplayModeInfo?
        if let resolution {
            target = DisplayController.findMode(resolution, in: modes)
        } else if let home = storedHome() {
            target = DisplayController.defaultLowMode(homeWidth: home.width, homeHeight: home.height, in: modes)
        } else if let cur = CGDisplayCopyDisplayMode(id) {
            target = DisplayController.defaultLowMode(homeWidth: cur.width, homeHeight: cur.height, in: modes)
        } else {
            target = nil
        }
        guard let target else {
            logFailure("!! no low mode candidate")
            return .failed
        }
        return apply(target, on: id) ? .ok : .failed
    }

    func restoreHome(explicit resolution: String?) -> RestoreResult {
        guard let id = readyTarget() else { return .deferred }
        let modes = DisplayController.allModes(for: id)
        if let resolution {
            guard let m = DisplayController.findMode(resolution, in: modes) else {
                logFailure("!! res_high mode not found: \(resolution)")
                return .failed
            }
            return apply(m, on: id) ? .ok : .failed
        }
        guard let home = storedHome() else { return .noCache }
        let candidates = modes.filter {
            $0.width == home.width && $0.height == home.height && $0.isHiDPI == home.isHiDPI
        }
        guard let m = candidates.max(by: { $0.refreshRate < $1.refreshRate }) else {
            logFailure("!! home mode not found: \(home.width)x\(home.height)")
            return .failed
        }
        return apply(m, on: id) ? .ok : .failed
    }

    func captureHome(onlyIfMissing: Bool) {
        guard let id = resolveTarget() else { return }
        if onlyIfMissing, storedHome() != nil { return }
        // 誤学習ガード: スリープ/非アクティブの瞬間の配置をホームとして学習しない
        guard environment.isReady(id) else { return }
        guard let cur = CGDisplayCopyDisplayMode(id) else { return }
        defaults.set(cur.width, forKey: "HomeWidth")
        defaults.set(cur.height, forKey: "HomeHeight")
        defaults.set(cur.pixelWidth > cur.width, forKey: "HomeIsHiDPI")
    }

    // --- 適用直前のガード ---------------------------------------------------

    /// 構成変更を受け付けられるターゲット。不在・非アクティブ・スリープ中は nil。
    /// この状態で CGCompleteDisplayConfiguration を呼ぶと約 10 秒ブロックして
    /// 失敗する (実機で発生済み) ので、呼ばずに「保留」として返すための入口。
    /// ログは保留に入ったとき・抜けたときの 1 回ずつだけ
    private func readyTarget() -> CGDirectDisplayID? {
        guard let id = resolveTarget(), environment.isReady(id) else {
            if !deferring {
                deferring = true
                failureLog.reset()
                log("-- display not ready; deferring display changes")
            }
            return nil
        }
        if deferring {
            deferring = false
            log("-- display ready")
        }
        return id
    }

    // --- 適用 -------------------------------------------------------------

    private func apply(_ target: DisplayModeInfo, on id: CGDirectDisplayID) -> Bool {
        guard let cgMode = target.mode else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, cgMode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            logFailure("!! configure failed: \(target.resString)")
            return false
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            logFailure("!! complete configuration failed: \(target.resString)")
            return false
        }
        failureLog.reset()
        return true
    }

    /// 失敗ログは間引いて出す (同じ文言の連続は 10 分に 1 行の要約にまとめる)
    private func logFailure(_ message: String) {
        if let line = failureLog.filter(message, now: clock()) {
            log(line)
        }
    }
}
