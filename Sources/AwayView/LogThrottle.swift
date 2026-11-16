import Foundation

/// 同じ失敗ログの連打を間引く。初回はそのまま出し、同じ文言が続く間は黙って、
/// 一定間隔ごとに「N 回連続」の要約を 1 行だけ出す。
/// watch.log が失敗行で埋まり、遷移 (-> LOW / -> HIGH) が読めなくなるのを防ぐ
struct LogThrottle {
    static let summaryInterval: TimeInterval = 600

    private var lastMessage: String?
    private var repeats = 0
    private var lastEmitted: TimeInterval = 0

    /// 出すべき行を返す。nil は「出さない」
    mutating func filter(_ message: String, now: TimeInterval) -> String? {
        guard message == lastMessage else {
            lastMessage = message
            repeats = 1
            lastEmitted = now
            return message
        }
        repeats += 1
        guard now - lastEmitted >= Self.summaryInterval else { return nil }
        lastEmitted = now
        return "\(message) (\(repeats) consecutive failures)"
    }

    mutating func reset() {
        lastMessage = nil
        repeats = 0
    }
}
