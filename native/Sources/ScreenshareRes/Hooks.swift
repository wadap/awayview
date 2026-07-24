import Foundation

// legacy 互換のモード遷移フック。config.zsh に on_low / on_high が定義されて
// いれば zsh 経由で呼ぶ。失敗しても watcher 動作には影響させない。
enum Hooks {
    static var configPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/screenshare-res/config.zsh").path

    static func run(_ name: String) {
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
