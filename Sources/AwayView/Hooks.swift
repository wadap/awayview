import Foundation

// モード遷移フック: ~/.config/awayview/hooks/<name>.d/ の実行可能ファイルを
// 名前順に全実行 (run-parts 方式)。デーモン連動の追加はスクリプトを 1 ファイル
// 置くだけ、削除はファイルを消すだけ。失敗は watcher 動作に影響させない
// (非同期・ログのみ)。
enum Hooks {
    static var hooksDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/awayview/hooks")

    static var log: (String) -> Void = { _ in }

    /// name は "on_low" / "on_high"
    static func run(_ name: String) {
        runScripts(in: hooksDir.appendingPathComponent("\(name).d"))
    }

    private static func runScripts(in dir: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let scripts = entries
            .filter { fm.isExecutableFile(atPath: $0.path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for script in scripts {
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = script
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    log("!! hook \(script.lastPathComponent) failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
