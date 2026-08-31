import XCTest
@testable import AwayView

private struct StubFetcher: ReleaseFetching {
    let result: Result<Data, Error>
    func fetchLatestJSON() throws -> Data { try result.get() }
}

private struct StubError: Error {}

final class UpdateCheckerTests: XCTestCase {
    // GitHub Releases API の latest レスポンスの抜粋 (必要なキーのみ)
    private let payload = """
    {
      "tag_name": "v1.0.2",
      "html_url": "https://github.com/wadap/awayview/releases/tag/v1.0.2",
      "assets": [
        { "name": "AwayView-1.0.2.zip",
          "browser_download_url": "https://github.com/wadap/awayview/releases/download/v1.0.2/AwayView-1.0.2.zip" }
      ]
    }
    """.data(using: .utf8)!

    func testParsesTagAssetAndPage() {
        let release = UpdateChecker.parse(payload)
        XCTAssertEqual(release?.version, AppVersion("1.0.2"))
        XCTAssertEqual(release?.downloadURL.lastPathComponent, "AwayView-1.0.2.zip")
        XCTAssertEqual(release?.htmlURL.absoluteString,
                       "https://github.com/wadap/awayview/releases/tag/v1.0.2")
    }

    func testAvailableWhenNewer() {
        let checker = UpdateChecker(fetcher: StubFetcher(result: .success(payload)),
                                    currentVersion: AppVersion("1.0.1")!)
        guard case .available(let release) = checker.check() else {
            return XCTFail("expected .available")
        }
        XCTAssertEqual(release.version, AppVersion("1.0.2"))
    }

    func testUpToDateWhenSame() {
        let checker = UpdateChecker(fetcher: StubFetcher(result: .success(payload)),
                                    currentVersion: AppVersion("1.0.2")!)
        XCTAssertEqual(checker.check(), .upToDate)
    }

    // 手元が公開版より新しい (開発中ビルド) ときに更新を促さない
    func testUpToDateWhenLocalIsNewer() {
        let checker = UpdateChecker(fetcher: StubFetcher(result: .success(payload)),
                                    currentVersion: AppVersion("1.1.0")!)
        XCTAssertEqual(checker.check(), .upToDate)
    }

    // 「新版なし」と「確認できなかった」を潰さない
    func testFailedOnNetworkError() {
        let checker = UpdateChecker(fetcher: StubFetcher(result: .failure(StubError())),
                                    currentVersion: AppVersion("1.0.1")!)
        guard case .failed = checker.check() else { return XCTFail("expected .failed") }
    }

    func testFailedOnGarbageJSON() {
        let checker = UpdateChecker(fetcher: StubFetcher(result: .success(Data("not json".utf8))),
                                    currentVersion: AppVersion("1.0.1")!)
        guard case .failed = checker.check() else { return XCTFail("expected .failed") }
    }

    // zip 資産が無い release は適用先が無いので失敗扱い
    func testFailedWhenNoZipAsset() {
        let noAsset = """
        { "tag_name": "v1.0.2",
          "html_url": "https://github.com/wadap/awayview/releases/tag/v1.0.2",
          "assets": [] }
        """.data(using: .utf8)!
        XCTAssertNil(UpdateChecker.parse(noAsset))
    }

    func testFailedWhenTagIsNotSemVer() {
        let badTag = """
        { "tag_name": "nightly",
          "html_url": "https://github.com/wadap/awayview/releases/tag/nightly",
          "assets": [{ "name": "a.zip", "browser_download_url": "https://example.com/a.zip" }] }
        """.data(using: .utf8)!
        XCTAssertNil(UpdateChecker.parse(badTag))
    }
}
