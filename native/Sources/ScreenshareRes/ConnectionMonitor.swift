import CShim
import Foundation

// 5900 番ポートへの ESTABLISHED 接続を sysctl (CShim 経由) から列挙する。
// netstat と同じ情報源なので root 不要で全プロセスのソケットが見える
// (ユーザー権限の lsof では root 所有 screensharingd のソケットが見えない教訓)。

/// Tailscale の割当範囲か: IPv4 100.64.0.0/10 / IPv6 fd7a:115c:a1e0::/48
func isTailscaleIP(_ ip: String) -> Bool {
    if ip.contains(":") {
        return ip.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }
    let octets = ip.split(separator: ".").compactMap { UInt8($0) }
    guard octets.count == 4, ip.split(separator: ".").count == 4 else { return false }
    return octets[0] == 100 && (64...127).contains(octets[1])
}

struct ConnectionMonitor: ConnectionObserving {
    let localPort: UInt16

    init(localPort: UInt16 = 5900) {
        self.localPort = localPort
    }

    func tailscaleRemoteIP() -> String? {
        establishedForeignIPs().first(where: isTailscaleIP)
    }

    /// local port が一致する ESTABLISHED 接続の foreign IP 一覧
    func establishedForeignIPs() -> [String] {
        var out = [CChar](repeating: 0, count: 16 * 1024)
        let n = css_list_established_foreign(localPort, &out, out.count)
        guard n > 0 else { return [] }
        return String(cString: out).split(separator: "\n").map(String.init)
    }
}
