import Foundation

// インストール元。Homebrew cask は app を /Applications へ実体で置き
// (symlink ではない)、<brew prefix>/Caskroom/awayview/<version>/ に管理記録を残す。
// バンドルの位置では判定できないので、Caskroom のエントリの有無で判定する。
// brew CLI は起こさない (sysctl 直叩きでシェルアウトを避けている既存方針に合わせる)。
enum InstallOrigin: Equatable {
    case homebrew
    case direct

    static let defaultPrefixes: [String] = ["/opt/homebrew", "/usr/local"]   // Apple silicon / Intel
    static let caskName = "awayview"

    static func detect(prefixes: [String] = defaultPrefixes,
                       fileManager: FileManager = .default) -> InstallOrigin {
        for prefix in prefixes {
            let path = (prefix as NSString)
                .appendingPathComponent("Caskroom")
                .appending("/" + caskName)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return .homebrew
            }
        }
        return .direct
    }
}
