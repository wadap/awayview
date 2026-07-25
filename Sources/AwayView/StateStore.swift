import Foundation

// zsh 版と互換のファイル契約 (~/.local/state/screenshare-res/) の読み書き。
//   state     … STATE/REMOTE_IP/CHANGED_AT (値はダブルクォート・tmp+rename・変化時のみ)
//   override  … 高解像度固定フラグ / force_low … 低解像度固定フラグ (排他)
//   res_high / res_low … 解像度選択 (WxH のみ)
//   watch.log … 稼働ログ (YYYY-MM-DD HH:MM:SS msg)

final class StateStore: FlagReading {
    let directory: URL
    private let now: () -> Date
    private var lastStateBody: String?

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/screenshare-res"),
         now: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: url(name).path)
    }

    private func contents(_ name: String) -> String? {
        guard let raw = try? String(contentsOf: url(name), encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // --- FlagReading ------------------------------------------------------

    var overrideHigh: Bool { exists("override") }
    var forceLow: Bool { exists("force_low") }
    var resLow: String? { contents("res_low") }
    var resHigh: String? { contents("res_high") }

    // --- 書き込み (メニュー操作) ------------------------------------------

    func setMode(_ mode: WatchMode) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fm = FileManager.default
        switch mode {
        case .auto:
            try? fm.removeItem(at: url("override"))
            try? fm.removeItem(at: url("force_low"))
        case .high:
            fm.createFile(atPath: url("override").path, contents: nil)
            try? fm.removeItem(at: url("force_low"))
        case .low:
            fm.createFile(atPath: url("force_low").path, contents: nil)
            try? fm.removeItem(at: url("override"))
        }
    }

    var currentMode: WatchMode {
        if overrideHigh { return .high }   // 両立時は override 優先 (watcher と同じ)
        if forceLow { return .low }
        return .auto
    }

    func setResLow(_ res: String?) { writeOrRemove("res_low", res) }
    func setResHigh(_ res: String?) { writeOrRemove("res_high", res) }

    private func writeOrRemove(_ name: String, _ value: String?) {
        if let value {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? (value + "\n").write(to: url(name), atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: url(name))
        }
    }

    // --- state ファイル ---------------------------------------------------

    func writeState(_ state: WatchState, remoteIP: String?) {
        let body = "STATE=\"\(state.rawValue)\"\nREMOTE_IP=\"\(remoteIP ?? "")\""
        guard body != lastStateBody else { return }
        let stamp = Self.timestampFormatter.string(from: now())
        let full = body + "\nCHANGED_AT=\"\(stamp)\"\n"
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tmp = url("state.tmp")
        guard (try? full.write(to: tmp, atomically: false, encoding: .utf8)) != nil else { return }
        guard rename(tmp.path, url("state").path) == 0 else { return }   // 原子的
        lastStateBody = body
    }

    // --- ログ -------------------------------------------------------------

    func log(_ message: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = Self.timestampFormatter.string(from: now())
        let line = "\(stamp) \(message)\n"
        let logURL = url("watch.log")
        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}
