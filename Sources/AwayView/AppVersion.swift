import Foundation

// アプリの版と SemVer 比較。版の正は Info.plist の CFBundleShortVersionString で、
// コード側には持たない (Makefile の release/publish も同じ値を正としている)。
struct AppVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "1.0.2" と "v1.0.2" の両方を受ける。3 要素でない / 数値でない / 負数は nil
    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let ma = Int(parts[0]), let mi = Int(parts[1]), let pa = Int(parts[2]),
              ma >= 0, mi >= 0, pa >= 0 else { return nil }
        self.init(major: ma, minor: mi, patch: pa)
    }

    // 辞書順ではなく数値順。"1.0.10" > "1.0.9"
    static func < (l: AppVersion, r: AppVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    /// 実行中バンドルの版。Info.plist を持たない実行形態 (swift test 等) では nil
    static func current(bundle: Bundle = .main) -> AppVersion? {
        guard let s = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return AppVersion(s)
    }
}
