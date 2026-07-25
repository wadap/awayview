import Foundation

// 観測用出力 (~/.local/state/awayview/)。書き込み専用:
//   state     … STATE/REMOTE_IP/CHANGED_AT (値はダブルクォート・tmp+rename・変化時のみ)
//   watch.log … 稼働ログ (YYYY-MM-DD HH:MM:SS msg、文言は英語固定)
// 設定・フラグ読み書きは SettingsStore (UserDefaults) に移行済み。
final class ObservationWriter {
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
            .appendingPathComponent(".local/state/awayview"),
         now: @escaping () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

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

// Task 5 で削除する暫定エイリアス (MenuController が旧 API 名を参照している間だけ)
typealias StateStore = ObservationWriter
extension ObservationWriter: FlagReading {
    var overrideHigh: Bool { false }
    var forceLow: Bool { false }
    var resLow: String? { nil }
    var resHigh: String? { nil }
    var currentMode: WatchMode { .auto }
    func setMode(_ mode: WatchMode) {}
    func setResLow(_ res: String?) {}
    func setResHigh(_ res: String?) {}
}
