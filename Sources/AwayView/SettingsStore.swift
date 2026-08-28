import Foundation

enum WatchMode {
    case auto, high, low
}

// UserDefaults ベースの設定と手動モード。旧ファイルフラグ
// (override / force_low / res_high / res_low) の後継。StateMachine へは
// FlagReading として渡す。キー: Port / CIDRs / Mode / ModeChangedAt / ResLow /
// ResHigh / AutoCheckUpdates / LastCheckedAt
final class SettingsStore: FlagReading {
    static let suiteName = "com.wadap.AwayView"
    static let defaultPort: UInt16 = 5900

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    /// アプリ本体用。suite 名が自 bundle id と同一のとき nil になるため .standard へフォールバック
    convenience init() {
        self.init(defaults: UserDefaults(suiteName: SettingsStore.suiteName) ?? .standard)
    }

    // --- 監視設定 -----------------------------------------------------

    var port: UInt16 {
        get {
            let v = defaults.integer(forKey: "Port")
            return (1...65535).contains(v) ? UInt16(v) : Self.defaultPort
        }
        set { defaults.set(Int(newValue), forKey: "Port") }
    }

    var cidrs: [String] {
        get { defaults.stringArray(forKey: "CIDRs") ?? CIDRMatcher.defaultCIDRs }
        set { defaults.set(newValue, forKey: "CIDRs") }
    }

    // --- 手動モード -----------------------------------------------------

    var currentMode: WatchMode {
        switch defaults.string(forKey: "Mode") {
        case "high": return .high
        case "low": return .low
        default: return .auto
        }
    }

    func setMode(_ mode: WatchMode) {
        switch mode {
        case .auto: defaults.removeObject(forKey: "Mode")
        case .high: defaults.set("high", forKey: "Mode")
        case .low: defaults.set("low", forKey: "Mode")
        }
        defaults.set(now(), forKey: "ModeChangedAt")
    }

    var modeChangedAt: Date? { defaults.object(forKey: "ModeChangedAt") as? Date }

    // --- FlagReading ----------------------------------------------------

    var overrideHigh: Bool { currentMode == .high }
    var forceLow: Bool { currentMode == .low }
    var resLow: String? { defaults.string(forKey: "ResLow") }
    var resHigh: String? { defaults.string(forKey: "ResHigh") }

    func setResLow(_ res: String?) { setOrRemove("ResLow", res) }
    func setResHigh(_ res: String?) { setOrRemove("ResHigh", res) }

    // --- 更新 -----------------------------------------------------------

    /// 既定は有効。UserDefaults に未登録のとき integer/bool の既定 false と区別するため
    /// object 経由で読む
    var autoCheckEnabled: Bool {
        get { defaults.object(forKey: "AutoCheckUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "AutoCheckUpdates") }
    }

    /// 最終チェック時刻。再起動を繰り返しても過剰にチェックしないための記録
    var lastCheckedAt: Date? {
        get { defaults.object(forKey: "LastCheckedAt") as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: "LastCheckedAt") }
            else { defaults.removeObject(forKey: "LastCheckedAt") }
        }
    }

    private func setOrRemove(_ key: String, _ value: String?) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}
