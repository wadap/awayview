import CShim
import Foundation

// 監視ポートへの ESTABLISHED 接続を sysctl (CShim 経由) から列挙する。
// netstat と同じ情報源なので root 不要で全プロセスのソケットが見える。

struct ConnectionMonitor: ConnectionObserving {
    let localPort: UInt16
    let matcher: CIDRMatcher

    init(localPort: UInt16 = SettingsStore.defaultPort,
         matcher: CIDRMatcher = CIDRMatcher(CIDRMatcher.defaultCIDRs)) {
        self.localPort = localPort
        self.matcher = matcher
    }

    func remoteIP() -> String? {
        establishedForeignIPs().first(where: matcher.matches)
    }

    /// local port が一致する ESTABLISHED 接続の foreign IP 一覧
    func establishedForeignIPs() -> [String] {
        var out = [CChar](repeating: 0, count: 16 * 1024)
        let n = css_list_established_foreign(localPort, &out, out.count)
        guard n > 0 else { return [] }
        return String(cString: out).split(separator: "\n").map(String.init)
    }
}

/// 毎 tick 現在の設定でモニタを組む (ポート・CIDR 変更を再起動なしで反映)
struct SettingsBackedConnection: ConnectionObserving {
    let settings: SettingsStore

    func remoteIP() -> String? {
        ConnectionMonitor(localPort: settings.port,
                          matcher: CIDRMatcher(settings.cidrs)).remoteIP()
    }
}
