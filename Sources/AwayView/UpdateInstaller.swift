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

    /// 置き換え先として認める bundle identifier。同じ team の別アプリを弾く
    static let bundleIdentifier = "com.wadap.AwayView"

    static var log: (String) -> Void = { _ in }

    static func install(_ release: Release,
                        bundleURL: URL = Bundle.main.bundleURL) -> InstallOutcome {
        // .build/release/AwayView のような素の実行ファイルでは bundleURL が
        // 親ディレクトリを指す。ダウンロード前に弾く (呼び出し元の CLI 側の
        // チェックだけに頼らない。Task 8 はここをデフォルト引数で呼ぶ)
        guard bundleURL.pathExtension == "app" else {
            return .failed("bundleURL is not a .app bundle: \(bundleURL.path)")
        }

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

    // Developer ID Application 証明書で署名され、Team ID と bundle identifier が
    // 自分のものであることを見る。notarization チケットの有無や証明書失効は見て
    // いない (別チェック) ので、ここを通っても「notarize 済み」の証明にはならない
    private static func verifySignature(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }

        // OU だけでは足りない。Apple Development 証明書の OU も同じ Team ID なので
        // (このマシンの keychain のもので実測)、開発機の鍵で署名したバンドルが
        // 通ってしまう。Developer ID の marker OID で証明書の種類まで縛る
        //   1.2.840.113635.100.6.2.6  = Developer ID Certification Authority
        //   1.2.840.113635.100.6.1.13 = Developer ID Application (leaf)
        // zip は URLSession で取って ditto で展開するため quarantine 属性が付かず、
        // Gatekeeper が独立に評価する機会は無い。この要件が唯一の防壁になる
        let text = """
        anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "\(teamID)" \
        and identifier "\(bundleIdentifier)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else { return false }

        // strictValidate: ネットワーク経由で取得した zip なので、シールされていない
        // 余分なファイルや symlink 差し替えを見逃さないようにする
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures
            | kSecCSCheckNestedCode
            | kSecCSStrictValidate)
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
