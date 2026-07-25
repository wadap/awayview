import Foundation

// CIDR 表記 (v4/v6 混在可) のリストに対する IP マッチャ。isTailscaleIP の後継。
// パースは初期化時に 1 回。不正エントリは無視して有効エントリだけで動く
// (設定 UI が保存前に検証するので、実行時に不正が来るのは defaults 手書きのときだけ)。
struct CIDRMatcher {
    static let defaultCIDRs = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]   // Tailscale

    private struct Rule {
        let bytes: [UInt8]   // ネットワークアドレス (v4=4, v6=16 bytes)
        let prefix: Int
    }
    private let rules: [Rule]

    init(_ cidrs: [String]) {
        rules = cidrs.compactMap { cidr in
            guard let (bytes, prefix) = Self.parseCIDR(cidr) else { return nil }
            return Rule(bytes: bytes, prefix: prefix)
        }
    }

    /// "100.64.0.0/10" → (ネットワークアドレス bytes, prefix 長)。不正なら nil
    static func parseCIDR(_ s: String) -> ([UInt8], Int)? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]),
              let bytes = parseIP(String(parts[0])),
              (0...bytes.count * 8).contains(prefix) else { return nil }
        return (bytes, prefix)
    }

    static func parseIP(_ s: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            return withUnsafeBytes(of: v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) }
        }
        return nil
    }

    func matches(_ ip: String) -> Bool {
        guard let bytes = Self.parseIP(ip) else { return false }
        return rules.contains { rule in
            rule.bytes.count == bytes.count && Self.prefixMatch(bytes, rule.bytes, bits: rule.prefix)
        }
    }

    private static func prefixMatch(_ a: [UInt8], _ b: [UInt8], bits: Int) -> Bool {
        let fullBytes = bits / 8
        guard a.prefix(fullBytes).elementsEqual(b.prefix(fullBytes)) else { return false }
        let rem = bits % 8
        guard rem > 0 else { return true }
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - rem))
        return (a[fullBytes] & mask) == (b[fullBytes] & mask)
    }
}
