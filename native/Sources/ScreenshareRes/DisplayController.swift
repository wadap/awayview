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
// DisplayControlling の実装 (CG 直叩き)。ホーム自動学習は UserDefaults に永続化
// (UUID/WxH/isHiDPI)。home.cmd は legacy 専用なので触らない。
// ---------------------------------------------------------------------------

final class RealDisplayController: DisplayControlling {
    static let suiteName = "com.wadap.screenshare-res.native"

    private let defaults: UserDefaults
    var log: (String) -> Void = { _ in }

    // suiteName が自 bundle id と同一のとき UserDefaults(suiteName:) は nil を
    // 返す (.app 実行時)。その場合 .standard が同じドメインを指すのでフォールバック
    init(defaults: UserDefaults = UserDefaults(suiteName: RealDisplayController.suiteName) ?? .standard) {
        self.defaults = defaults
    }

    // --- 対象ディスプレイ (外部優先で選出し UUID を記憶) -------------------

    func resolveTarget() -> CGDirectDisplayID? {
        let displays = DisplayController.onlineDisplays()
        guard !displays.isEmpty else { return nil }
        if let saved = defaults.string(forKey: "TargetDisplayUUID"),
           let id = displays.first(where: { DisplayController.uuidString(for: $0) == saved }) {
            return id
        }
        let target = displays.first { CGDisplayIsBuiltin($0) == 0 } ?? displays[0]
        if let uuid = DisplayController.uuidString(for: target) {
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

    func applyLow(_ resolution: String?) -> Bool {
        guard let id = resolveTarget() else { return false }
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
            log("!! no low mode candidate")
            return false
        }
        return apply(target, on: id)
    }

    func restoreHome(explicit resolution: String?) -> RestoreResult {
        guard let id = resolveTarget() else { return .failed }
        let modes = DisplayController.allModes(for: id)
        if let resolution {
            guard let m = DisplayController.findMode(resolution, in: modes) else {
                log("!! res_high mode not found: \(resolution)")
                return .failed
            }
            return apply(m, on: id) ? .ok : .failed
        }
        guard let home = storedHome() else { return .noCache }
        let candidates = modes.filter {
            $0.width == home.width && $0.height == home.height && $0.isHiDPI == home.isHiDPI
        }
        guard let m = candidates.max(by: { $0.refreshRate < $1.refreshRate }) else {
            log("!! home mode not found: \(home.width)x\(home.height)")
            return .failed
        }
        return apply(m, on: id) ? .ok : .failed
    }

    func captureHome(onlyIfMissing: Bool) {
        guard let id = resolveTarget() else { return }
        if onlyIfMissing, storedHome() != nil { return }
        // 誤学習ガード: スリープ/非アクティブの瞬間の配置をホームとして学習しない
        guard CGDisplayIsActive(id) != 0, CGDisplayIsOnline(id) != 0, CGDisplayIsAsleep(id) == 0 else { return }
        guard let cur = CGDisplayCopyDisplayMode(id) else { return }
        defaults.set(cur.width, forKey: "HomeWidth")
        defaults.set(cur.height, forKey: "HomeHeight")
        defaults.set(cur.pixelWidth > cur.width, forKey: "HomeIsHiDPI")
    }

    // --- 適用 -------------------------------------------------------------

    private func apply(_ target: DisplayModeInfo, on id: CGDirectDisplayID) -> Bool {
        guard let cgMode = target.mode else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, cgMode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            log("!! configure failed: \(target.resString)")
            return false
        }
        guard CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            log("!! complete configuration failed: \(target.resString)")
            return false
        }
        return true
    }
}
