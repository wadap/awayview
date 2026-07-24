import Foundation

// モード遷移フック。2 系統を両方サポートする:
//  1. hooks ディレクトリ (推奨): ~/.config/screenshare-res/hooks/<name>.d/ の
//     実行可能ファイルを名前順に全実行 (run-parts 方式)。デーモン連動の追加は
//     スクリプトを 1 ファイル置くだけ、削除はファイルを消すだけ
//  2. legacy 互換: config.zsh に on_low / on_high 関数があれば zsh 経由で実行
// いずれも失敗は watcher 動作に影響させない (非同期・ログのみ)。
enum Hooks {
    static var configPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/screenshare-res/config.zsh").path

    static var hooksDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/screenshare-res/hooks")

    static var log: (String) -> Void = { _ in }

    /// name は "on_low" / "on_high"
    static func run(_ name: String) {
        runScripts(in: hooksDir.appendingPathComponent("\(name).d"))
        runZshFunction(name)
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

    private static func runZshFunction(_ name: String) {
        guard FileManager.default.fileExists(atPath: configPath) else { return }
        let script = "source '\(configPath)' >/dev/null 2>&1; whence -f \(name) >/dev/null && \(name)"
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }
}
