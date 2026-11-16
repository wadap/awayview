import Foundation

/// スリープ中と復帰直後は watcher を止めるための門。
/// システムスリープとディスプレイスリープを別々に追い、どちらも起きていて、
/// かつ最後の復帰通知から猶予が過ぎているときだけ開く。
///
/// 猶予を置くのは、復帰通知の直後は WindowServer がまだ再構成の途中で、
/// CG の状態問い合わせが「準備完了」を返しても適用が通らない窓があるため。
/// 純粋な値型で、時刻は呼び出し側が渡す (テストで再現できるように)
struct SleepGate {
    /// 復帰通知から watcher を再開するまでの猶予 (秒)
    static let wakeGrace: TimeInterval = 5

    private(set) var systemAsleep = false
    private(set) var screensAsleep = false
    private var quietUntil: TimeInterval = 0

    mutating func systemWillSleep() { systemAsleep = true }

    mutating func systemDidWake(now: TimeInterval) {
        systemAsleep = false
        quietUntil = max(quietUntil, now + Self.wakeGrace)
    }

    mutating func screensDidSleep() { screensAsleep = true }

    mutating func screensDidWake(now: TimeInterval) {
        screensAsleep = false
        quietUntil = max(quietUntil, now + Self.wakeGrace)
    }

    func isOpen(now: TimeInterval) -> Bool {
        !systemAsleep && !screensAsleep && now >= quietUntil
    }
}
