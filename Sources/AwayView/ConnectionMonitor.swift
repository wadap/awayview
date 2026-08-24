import CShim
import Foundation

// 監視ポートへの ESTABLISHED 接続を sysctl (CShim 経由) から列挙する。
// netstat と同じ情報源なので root 不要で全プロセスのソケットが見える。

/// CShim の列挙呼び出し。戻り値は件数、負値はエラー
typealias ForeignIPLister = (UInt16, UnsafeMutablePointer<CChar>, Int) -> Int32

struct ConnectionMonitor: ConnectionObserving {
    let localPort: UInt16
    let matcher: CIDRMatcher
    let lister: ForeignIPLister

    init(localPort: UInt16 = SettingsStore.defaultPort,
         matcher: CIDRMatcher = CIDRMatcher(CIDRMatcher.defaultCIDRs),
         lister: @escaping ForeignIPLister = css_list_established_foreign) {
        self.localPort = localPort
        self.matcher = matcher
        self.lister = lister
    }

    func probe() -> ConnectionProbe {
        guard let ips = enumerateForeignIPs() else { return .unavailable }
        if let ip = ips.first(where: matcher.matches) { return .remote(ip) }
        return ConnectionProbe.none
    }

    /// local port が一致する ESTABLISHED 接続の foreign IP 一覧。
    /// 列挙に失敗したときは nil (「接続 0 件」と区別するため空配列にしない)
    func enumerateForeignIPs() -> [String]? {
        var out = [CChar](repeating: 0, count: 16 * 1024)
        let n = lister(localPort, &out, out.count)
        guard n >= 0 else { return nil }   // 負値は列挙エラー: 「0 件」に潰さない
        guard n > 0 else { return [] }
        return String(cString: out).split(separator: "\n").map(String.init)
    }

    /// 列挙失敗を空扱いにする簡易版 (CLI 表示用)
    func establishedForeignIPs() -> [String] { enumerateForeignIPs() ?? [] }
}

/// 毎 tick 現在の設定でモニタを組む (ポート・CIDR 変更を再起動なしで反映)
struct SettingsBackedConnection: ConnectionObserving {
    let settings: SettingsStore

    func probe() -> ConnectionProbe {
        ConnectionMonitor(localPort: settings.port,
                          matcher: CIDRMatcher(settings.cidrs)).probe()
    }
}
