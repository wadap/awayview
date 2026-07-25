import XCTest
@testable import AwayView

final class HooksTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssr-hooks-\(UUID().uuidString)")
        Hooks.hooksDir = dir
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func addScript(_ subdir: String, _ name: String, marker: URL, executable: Bool = true) throws {
        let d = dir.appendingPathComponent(subdir)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let script = d.appendingPathComponent(name)
        try "#!/bin/zsh\nprint -r -- \(name) >> '\(marker.path)'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 3,
                             until condition: (String) -> Bool = { _ in true }) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        while Date() < deadline {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                last = s
                if condition(s) { return s }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return last
    }

    // on_low.d の実行可能スクリプトが全部呼ばれる
    func testRunsAllExecutableScriptsInDirectory() throws {
        let marker = dir.appendingPathComponent("marker")
        try addScript("on_low.d", "10-first", marker: marker)
        try addScript("on_low.d", "20-second", marker: marker)
        Hooks.run("on_low")
        let content = waitForFile(marker) { $0.contains("10-first") && $0.contains("20-second") }
        XCTAssertNotNil(content)
        XCTAssertTrue(content!.contains("10-first"))
        XCTAssertTrue(content!.contains("20-second"))
    }

    // 実行可能でないファイルはスキップされる
    func testSkipsNonExecutableFiles() throws {
        let marker = dir.appendingPathComponent("marker")
        try addScript("on_low.d", "runnable", marker: marker)
        try addScript("on_low.d", "not-runnable", marker: marker, executable: false)
        Hooks.run("on_low")
        let content = waitForFile(marker) { $0.contains("runnable") }
        XCTAssertNotNil(content)
        Thread.sleep(forTimeInterval: 0.3)   // not-runnable が誤実行されるなら追記される猶予
        let final = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(final.contains("runnable"))
        XCTAssertFalse(final.contains("not-runnable"))
    }

    // on_high は on_high.d だけを見る
    func testUsesMatchingSubdirectory() throws {
        let lowMarker = dir.appendingPathComponent("low-marker")
        let highMarker = dir.appendingPathComponent("high-marker")
        try addScript("on_low.d", "low-hook", marker: lowMarker)
        try addScript("on_high.d", "high-hook", marker: highMarker)
        Hooks.run("on_high")
        XCTAssertNotNil(waitForFile(highMarker))
        XCTAssertNil(try? String(contentsOf: lowMarker, encoding: .utf8))
    }

    // ディレクトリが無くても何も起きない (クラッシュしない)
    func testMissingDirectoryIsFine() {
        Hooks.run("on_low")
    }
}
