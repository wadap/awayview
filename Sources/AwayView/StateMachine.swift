import Foundation

// zsh 版 bin/screenshare-res-watch.zsh のメインループの意味論を移植した純粋ロジック。
// 環境 (接続・表示・フラグ) は protocol 越しに観測し、テストではモックを注入する。
//
// zsh 版との対応:
//   - SETTLE_DELAY 再確認 → 「二段階遷移」(接続検知 tick の次 tick で再確認)
//   - 誤学習ガード: 下げる前の capture(未キャッシュ時のみ) / 適用・復帰失敗時は
//     last・capture・state を進めず次 tick リトライ
//   - 適用中の res_low/res_high 変更は appliedDescriptor との差分で検出し即再適用
//   - フック: applyLow / restoreHome の成功のたびに発火 (zsh 版 run_hook と同じ)

protocol ConnectionObserving {
    /// 5900 番へ ESTABLISHED している Tailscale 接続元 IP (なければ nil)
    func tailscaleRemoteIP() -> String?
}

enum RestoreResult {
    case ok       // 復帰適用に成功
    case failed   // 適用失敗 (rc=1 相当): 前進禁止・リトライ
    case noCache  // 復帰先が無い (rc=2 相当): 初回起動。現在をホームとみなして前進
}

protocol DisplayControlling {
    /// 低解像度を適用。nil は既定 (ホームの半分・同アスペクト・HiDPI 優先)
    func applyLow(_ resolution: String?) -> Bool
    /// ホームへ復帰。resolution 指定時 (res_high) はそれを適用、nil なら自動学習分
    func restoreHome(explicit resolution: String?) -> RestoreResult
    /// ホーム配置の学習。onlyIfMissing=true は「下げる直前の確保」用。
    /// 実装側はディスプレイ非アクティブ時に何もしない誤学習ガードを持つこと
    func captureHome(onlyIfMissing: Bool)
}

protocol FlagReading {
    var overrideHigh: Bool { get }   // override フラグ (高解像度固定)
    var forceLow: Bool { get }       // force_low フラグ (低解像度固定)
    var resLow: String? { get }      // res_low 選択 (WxH)
    var resHigh: String? { get }     // res_high 選択 (WxH)
}

enum WatchState: String {
    case home
    case low
    case lowManual = "low_manual"
    case override
}

final class StateMachine {
    private enum Last { case unknown, high, low }

    private let connection: ConnectionObserving
    private let display: DisplayControlling
    private let flags: FlagReading
    private let onStateChange: (WatchState, String?) -> Void

    /// 遷移成功フック (zsh 版 on_low / on_high 相当)
    var onLowApplied: (() -> Void)?
    var onHighRestored: (() -> Void)?

    private var last: Last = .unknown
    private var applied = ""          // 適用済みレイアウトの記述子 (再適用判定用)
    private var settling = false      // 二段階 SETTLE の一段階目を通過したか

    init(connection: ConnectionObserving,
         display: DisplayControlling,
         flags: FlagReading,
         onStateChange: @escaping (WatchState, String?) -> Void) {
        self.connection = connection
        self.display = display
        self.flags = flags
        self.onStateChange = onStateChange
    }

    func tick() {
        let remoteIP = connection.tailscaleRemoteIP()

        if flags.overrideHigh {
            settling = false
            if ensureHigh() {
                display.captureHome(onlyIfMissing: false)
                onStateChange(.override, remoteIP)
            }
        } else if flags.forceLow {
            settling = false
            if ensureLow() {
                onStateChange(.lowManual, remoteIP)
            }
        } else if let ip = remoteIP {
            if last == .low {
                settling = false
                reapplyLowIfChanged()
                onStateChange(.low, ip)
            } else if settling {
                // 二段階目: 前 tick から接続が継続している → 適用 (SETTLE 相当)
                settling = false
                if ensureLow() {
                    onStateChange(.low, ip)
                }
            } else {
                settling = true   // 一段階目: 次 tick で再確認 (瞬間接続では下げない)
            }
        } else {
            settling = false
            if ensureHigh() {
                display.captureHome(onlyIfMissing: false)
                onStateChange(.home, nil)
            }
        }
    }

    /// last を high に持っていく。失敗 (rc=1) なら false = このtickは前進しない
    private func ensureHigh() -> Bool {
        if last != .high {
            switch display.restoreHome(explicit: flags.resHigh) {
            case .ok:
                applied = "high:\(flags.resHigh ?? "auto")"
                onHighRestored?()
            case .noCache:
                break   // 初回起動: 現在をホームとみなす (以後の capture で学習)
            case .failed:
                return false
            }
            last = .high
            return true
        }
        // res_high の選択変更を即再適用 (明示指定時のみ。zsh 版と同じ)
        if let resHigh = flags.resHigh {
            let desired = "high:\(resHigh)"
            if desired != applied, case .ok = display.restoreHome(explicit: resHigh) {
                applied = desired
                onHighRestored?()
            }
        }
        return true
    }

    /// last を low に持っていく。適用失敗なら false = このtickは前進しない
    private func ensureLow() -> Bool {
        if last != .low {
            display.captureHome(onlyIfMissing: true)   // 下げる直前=ホームを確保
            guard display.applyLow(flags.resLow) else { return false }
            applied = "low:\(flags.resLow ?? "default")"
            last = .low
            onLowApplied?()
            return true
        }
        reapplyLowIfChanged()
        return true
    }

    private func reapplyLowIfChanged() {
        let desired = "low:\(flags.resLow ?? "default")"
        guard desired != applied else { return }
        if display.applyLow(flags.resLow) {
            applied = desired
            onLowApplied?()
        }
    }
}
