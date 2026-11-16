import Foundation

/// 表示適用が本当に失敗した (CG が拒否した) ときの再試行間隔。
/// 失敗のたびに次の試行までの待ちを 3s → 10s → 30s → 60s (上限) と伸ばす。
/// CGCompleteDisplayConfiguration は失敗時に約 10 秒ブロックするので、
/// tick ごとに叩き続けるとメインスレッドがほぼ塞がる (実機で発生済み)
struct RetryBackoff {
    static let delays: [TimeInterval] = [3, 10, 30, 60]

    private(set) var failures = 0
    private var notBefore: TimeInterval = 0

    /// いま試行してよいか
    func allows(_ now: TimeInterval) -> Bool { now >= notBefore }

    mutating func recordFailure(now: TimeInterval) {
        let delay = Self.delays[min(failures, Self.delays.count - 1)]
        failures += 1
        notBefore = now + delay
    }

    mutating func reset() {
        failures = 0
        notBefore = 0
    }
}
