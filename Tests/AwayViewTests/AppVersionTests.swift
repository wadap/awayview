import XCTest
@testable import AwayView

final class AppVersionTests: XCTestCase {
    // 辞書順で実装すると "1.0.10" < "1.0.9" になる。ここが壊れると
    // 「新版があるのに一生気づかない」形で静かに失敗する
    func testNumericOrderingNotLexicographic() {
        XCTAssertTrue(AppVersion("1.0.10")! > AppVersion("1.0.9")!)
        XCTAssertTrue(AppVersion("1.10.0")! > AppVersion("1.9.0")!)
        XCTAssertTrue(AppVersion("2.0.0")! > AppVersion("1.99.99")!)
    }

    func testEquality() {
        XCTAssertEqual(AppVersion("1.0.1"), AppVersion("1.0.1"))
        XCTAssertFalse(AppVersion("1.0.1")! > AppVersion("1.0.1")!)
    }

    // GitHub のタグは "v" 付き、Info.plist は "v" なし。両方受ける
    func testStripsLeadingV() {
        XCTAssertEqual(AppVersion("v1.0.2"), AppVersion("1.0.2"))
        XCTAssertEqual(AppVersion("V1.0.2"), AppVersion("1.0.2"))
    }

    func testRejectsMalformed() {
        XCTAssertNil(AppVersion("1.0"))
        XCTAssertNil(AppVersion("1.0.0.1"))
        XCTAssertNil(AppVersion("1.0.x"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("-1.0.0"))
        XCTAssertNil(AppVersion("1.0.-2"))
    }

    func testDescriptionRoundTrip() {
        XCTAssertEqual(AppVersion("v1.0.2")!.description, "1.0.2")
    }

    // `AppVersion.current(bundle:)` は Info.plist の 1 キーを読むだけで、
    // 文字列のパースは上のテストが押さえている。テスト用 bundle の Info.plist の
    // 中身は環境依存なので、ここでは検証しない (Task 5 の --check-update で実機確認する)
}
