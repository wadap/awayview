import Foundation
import Security

enum InstallOutcome: Equatable {
    case ok
    case failed(String)
}

// 取得 → 署名検証 → 置換 → 再起動。direct 経路専用 (Homebrew 管理下では呼ばない)。
//
// **順序を崩さないこと**。ネットワーク経由で取得したバンドルを検証前に一度でも
// 実行したら、更新経路がそのまま任意コード実行の穴になる。
enum UpdateInstaller {
    /// Developer ID の Team ID。これ以外が署名したバンドルは受け付けない
    static let teamID = "45F858C28S"

    static var log: (String) -> Void = { _ in }

    static func install(_ release: Release,
                        bundleURL: URL = Bundle.main.bundleURL) -> InstallOutcome {
        let fm = FileManager.default
        let work = fm.temporaryDirectory
            .appendingPathComponent("awayview-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }

        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)

            // 1. 取得
            let zip = work.appendingPathComponent("AwayView.zip")
            var request = URLRequest(url: release.downloadURL, timeoutInterval: 120)
            request.setValue("AwayView", forHTTPHeaderField: "User-Agent")
            let data = try URLSession.shared.awayviewSynchronousData(for: request)
            try data.write(to: zip)
            log("update: downloaded \(data.count) bytes")

            // 2. 展開。ditto は署名済みバンドルの拡張属性と symlink を保つ
            //    (unzip は壊す)。公開 API に代替が無いのでここだけ Process を使う
            let unpacked = work.appendingPathComponent("unpacked")
            try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

            let contents = try fm.contentsOfDirectory(at: unpacked,
                                                      includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                return .failed("no .app found in archive")
            }

            // 3. 署名検証 — ここを通らないものは絶対に置かない
            guard verifySignature(at: newApp) else {
                return .failed("signature verification failed")
            }
            guard let newBundle = Bundle(url: newApp),
                  let newVersion = AppVersion.current(bundle: newBundle),
                  newVersion == release.version else {
                return .failed("archive version does not match the announced release")
            }
            log("update: verified \(newVersion) signed by \(teamID)")

            // 4. 置換。replaceItemAt は失敗時に元を残す
            _ = try fm.replaceItemAt(bundleURL, withItemAt: newApp)
            log("update: replaced bundle at \(bundleURL.path)")
            return .ok
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// 新しいバンドルを起動する。自プロセスの終了は呼び出し側が行う
    static func relaunch(bundleURL: URL = Bundle.main.bundleURL) {
        // -n: 自分がまだ生きているので、新しいインスタンスを明示的に立てる
        try? run("/usr/bin/open", ["-n", bundleURL.path])
    }

    // Developer ID 署名で、かつ leaf 証明書の OU が自分の Team ID であること。
    // notarize 済みバンドルは staple されているので、この検証を通れば配布物として正当
    private static func verifySignature(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }

        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else { return false }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    // 引数は配列で渡す。シェル経由の文字列展開はしない
    private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.process(path, process.terminationStatus)
        }
    }
}
