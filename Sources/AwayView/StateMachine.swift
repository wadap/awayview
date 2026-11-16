import Foundation

// (削除済みの) zsh 版 watcher のメインループの意味論を移植した純粋ロジック。
// 環境 (接続・表示・フラグ) は protocol 越しに観測し、テストではモックを注入する。
//
// zsh 版との対応:
//   - SETTLE_DELAY 再確認 → 「二段階遷移」(接続検知 tick の次 tick で再確認)
//   - 誤学習ガード: 下げる前の capture(未キャッシュ時のみ) / 適用・復帰失敗時は
//     last・capture・state を進めず次 tick リトライ
//   - 適用中の res_low/res_high 変更は appliedDescriptor との差分で検出し即再適用
//   - フック: applyLow / restoreHome の成功のたびに発火 (zsh 版 run_hook と同じ)
//
// zsh 版に無い追加:
//   - 保留 (.deferred): ディスプレイが未準備で CG を呼ばなかった。前進しない
//   - バックオフ: 本当に失敗したら再試行の間隔を空ける (RetryBackoff)。
//     成功・保留・意図 (接続の有無 / フラグ) の変化でリセット

/// 接続の観測結果。列挙に失敗した「不明」を「接続なし」と区別する。
/// Optional<String> だと両者が nil に潰れ、一過性の列挙失敗が「切断」に化ける
enum ConnectionProbe: Equatable {
    case remote(String)   // 監視ポートへ ESTABLISHED している設定 CIDR 内の接続元
    case none             // 接続なし (列挙自体は成功した)
    case unavailable      // 列挙に失敗した = 判定不能
}

protocol ConnectionObserving {
    func probe() -> ConnectionProbe
}

enum RestoreResult {
    case ok       // 復帰適用に成功
    case failed   // 適用失敗 (rc=1 相当): 前進禁止・リトライ
    case noCache  // 復帰先が無い (rc=2 相当): 初回起動。現在をホームとみなして前進
    case deferred // 保留: ディスプレイが未準備で CG を呼んでいない。前進禁止
}

enum ApplyResult {
    case ok       // 低解像度の適用に成功
    case failed   // CG が拒否した / 候補モードが無い: 前進禁止・リトライ
    case deferred // 保留: ディスプレイが未準備で CG を呼んでいない。前進禁止
}

protocol DisplayControlling {
    /// 低解像度を適用。nil は既定 (ホームの半分・同アスペクト・HiDPI 優先)
    func applyLow(_ resolution: String?) -> ApplyResult
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
    /// 接続の列挙に失敗した tick (無音にせず観測できるようにする)
    var onProbeUnavailable: (() -> Void)?

    private var last: Last = .unknown
    private var applied = ""          // 適用済みレイアウトの記述子 (再適用判定用)
    private var settling = false      // 二段階 SETTLE の一段階目を通過したか

    private let clock: () -> TimeInterval
    private var now: TimeInterval = 0     // この tick の時刻 (tick 冒頭で 1 回だけ読む)
    private var backoff = RetryBackoff()
    private var intent: String?           // 直近の「意図」(バックオフのリセット判定用)

    init(connection: ConnectionObserving,
         display: DisplayControlling,
         flags: FlagReading,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onStateChange: @escaping (WatchState, String?) -> Void) {
        self.connection = connection
        self.display = display
        self.flags = flags
        self.clock = clock
        self.onStateChange = onStateChange
    }

    /// スリープ復帰など、外側で「状況が変わった」と分かったときに呼ぶ。
    /// 次の tick からすぐ試行する
    func resetBackoff() {
        backoff.reset()
    }

    func tick() {
        now = clock()
        let probe = connection.probe()
        let remoteIP: String? = if case .remote(let ip) = probe { ip } else { nil }

        // 接続の有無かフラグが変わったら、連続失敗を数え直してすぐ試す。
        // 不明 (.unavailable) は変化の証拠ではないので意図を更新しない
        if probe != .unavailable {
            let current = [
                remoteIP == nil ? "away" : "remote",
                flags.overrideHigh ? "override" : "",
                flags.forceLow ? "force_low" : "",
                flags.resLow ?? "",
                flags.resHigh ?? "",
            ].joined(separator: "|")
            if current != intent {
                intent = current
                backoff.reset()
            }
        }

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
        } else if case .unavailable = probe {
            // 判定不能: 前 tick の判定を維持する。ここを「接続なし」に倒すと
            // 画面共有が生きたまま復帰を試み、CG に拒否され、tick ごとに
            // 無音でリトライし続ける (settling も巻き戻さない)
            onProbeUnavailable?()
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
            switch restore(flags.resHigh) {
            case .ok:
                applied = "high:\(flags.resHigh ?? "auto")"
                onHighRestored?()
            case .noCache:
                break   // 初回起動: 現在をホームとみなす (以後の capture で学習)
            case .failed, .deferred:
                return false
            }
            last = .high
            return true
        }
        // res_high の選択変更を即再適用 (明示指定時のみ。zsh 版と同じ)
        if let resHigh = flags.resHigh {
            let desired = "high:\(resHigh)"
            if desired != applied, restore(resHigh) == .ok {
                applied = desired
                onHighRestored?()
            }
        }
        return true
    }

    /// last を low に持っていく。適用失敗なら false = このtickは前進しない
    private func ensureLow() -> Bool {
        if last != .low {
            guard backoff.allows(now) else { return false }   // capture より先に弾く
            display.captureHome(onlyIfMissing: true)   // 下げる直前=ホームを確保
            guard lower(flags.resLow) == .ok else { return false }
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
        if lower(flags.resLow) == .ok {
            applied = desired
            onLowApplied?()
        }
    }

    // --- 表示操作 (すべてここを通す: バックオフの判定と記録) -------------------

    /// バックオフ中は表示を触らず .deferred を返す (呼び出し側は前進しない)
    private func restore(_ resolution: String?) -> RestoreResult {
        guard backoff.allows(now) else { return .deferred }
        let result = display.restoreHome(explicit: resolution)
        record(failed: result == .failed)
        return result
    }

    private func lower(_ resolution: String?) -> ApplyResult {
        guard backoff.allows(now) else { return .deferred }
        let result = display.applyLow(resolution)
        record(failed: result == .failed)
        return result
    }

    /// 失敗だけを積む。成功はもちろん、保留も「状況が変わった」合図なので数え直す
    private func record(failed: Bool) {
        if failed {
            backoff.recordFailure(now: now)
        } else {
            backoff.reset()
        }
    }
}
