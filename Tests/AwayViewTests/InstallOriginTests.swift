import XCTest
@testable import AwayView

final class InstallOriginTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("awayview-origin-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeCaskroom(prefix: String) {
        let dir = root.appendingPathComponent(prefix).appendingPathComponent("Caskroom/awayview/1.0.1")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func prefixes(_ names: [String]) -> [String] {
        names.map { root.appendingPathComponent($0).path }
    }

    func testDirectWhenNoCaskroomEntry() {
        XCTAssertEqual(InstallOrigin.detect(prefixes: prefixes(["opt/homebrew", "usr/local"])), .direct)
    }

    func testHomebrewWhenAppleSiliconPrefixHasEntry() {
        makeCaskroom(prefix: "opt/homebrew")
        XCTAssertEqual(InstallOrigin.detect(prefixes: prefixes(["opt/homebrew", "usr/local"])), .homebrew)
    }

    // Intel 環境では /usr/local 側に入る
    func testHomebrewWhenIntelPrefixHasEntry() {
        makeCaskroom(prefix: "usr/local")
        XCTAssertEqual(InstallOrigin.detect(prefixes: prefixes(["opt/homebrew", "usr/local"])), .homebrew)
    }

    // 同名のファイル (ディレクトリでない) は誤判定しない
    func testIgnoresNonDirectoryEntry() {
        let dir = root.appendingPathComponent("opt/homebrew/Caskroom")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("awayview").path, contents: Data())
        XCTAssertEqual(InstallOrigin.detect(prefixes: prefixes(["opt/homebrew", "usr/local"])), .direct)
    }
}
