# 版表示とアプリ内アップデート Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** メニューに現行版を出し、更新の有無を自動/手動で確認して、インストール元に応じた方法で更新できるようにする。

**Architecture:** 4 つの新規型 (`AppVersion` / `InstallOrigin` / `UpdateChecker` / `UpdateInstaller`) を追加し、`MenuController` から呼ぶ。ネットワークは `ReleaseFetching` protocol の裏に置いてテストで差し替える。Homebrew cask 経由で入っているときはアプリが自分を置き換えず、`brew upgrade` のコマンドを提示するに留める。

**Tech Stack:** Swift 5.9 (tools version) / macOS 13+ / XCTest / URLSession / Security.framework / AppKit

**Spec:** `.steering/20260828-version-and-updater/design.md` (要求は `requirements.md`、判断の理由は `decisions.md`)

## Global Constraints

- **版の正は `Info.plist` の `CFBundleShortVersionString`**。現在 `1.0.1`。コードに版を直書きしない
- **Team ID は `45F858C28S`**。この Developer ID 以外が署名したバンドルは受け付けない
- **GitHub repo は `wadap/awayview`**。API は `https://api.github.com/repos/wadap/awayview/releases/latest`
- **Homebrew cask 名は `awayview`**、tap は `wadap/tap`
- **戻り値を `Optional` にしない**。「不在」と「失敗」を区別する必要がある観測系は enum で三値以上を返す
- **文言は必ず `L()` 経由**で `Sources/AwayView/Resources/en.lproj/Localizable.strings` と `ja.lproj/Localizable.strings` の**両方**に追加する。片方だけの追加は不可
- **`watch.log` に出すログは英語固定**。`ObservationWriter.log()` を使う
- **テストは TZ・ロケール・ネットワーク・実ファイルシステム (tmpdir を除く) に依存させない**。CI は macos-15 / Swift 6.1
- **シェルアウトは 2 箇所のみ許可**: `/usr/bin/ditto` (zip 展開) と `/usr/bin/open` (再起動)。いずれも `Process` に引数配列で渡し、シェル経由の文字列展開はしない
- **テスト実行**: `make test`。`swift test` を直接叩くときは `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` が必要
- **このマシンの zsh は noclobber**。既存ファイルへの `>` は失敗する。Write ツールか `>|` を使う

---

## File Structure

| ファイル | 責務 |
|---|---|
| `Sources/AwayView/AppVersion.swift` (新規) | SemVer の表現・比較・Bundle からの読み出し |
| `Sources/AwayView/InstallOrigin.swift` (新規) | Homebrew cask 管理下かどうかの判定 |
| `Sources/AwayView/UpdateChecker.swift` (新規) | `Release` / `UpdateCheckResult` / `ReleaseFetching` / GitHub API 実装 / 判定 |
| `Sources/AwayView/UpdateInstaller.swift` (新規) | 取得 → 署名検証 → 置換 → 再起動 |
| `Sources/AwayView/SettingsStore.swift` (変更) | `autoCheckEnabled` / `lastCheckedAt` |
| `Sources/AwayView/MenuController.swift` (変更) | 版表示・更新項目・スケジューリング・LOW ガード |
| `Sources/AwayView/SettingsWindow.swift` (変更) | 自動チェックのトグル |
| `Sources/AwayView/main.swift` (変更) | `--check-update` / `--install-update` |
| `Sources/AwayView/Resources/{en,ja}.lproj/Localizable.strings` (変更) | 文言 |
| `Tests/AwayViewTests/AppVersionTests.swift` (新規) | SemVer 比較・パース |
| `Tests/AwayViewTests/InstallOriginTests.swift` (新規) | 偽 Caskroom での判定 |
| `Tests/AwayViewTests/UpdateCheckerTests.swift` (新規) | JSON パース・判定 (fake fetcher) |
| `Tests/AwayViewTests/SettingsStoreTests.swift` (変更) | 新規キーの既定値と往復 |
| `README.md` / `README.ja.md` (変更) | brew trust とアプリ内更新の記述 |

---

### Task 1: AppVersion

**Files:**
- Create: `Sources/AwayView/AppVersion.swift`
- Test: `Tests/AwayViewTests/AppVersionTests.swift`

**Interfaces:**
- Consumes: なし (最初のタスク)
- Produces:
  - `struct AppVersion: Equatable, Comparable, CustomStringConvertible`
  - `init?(_ string: String)` — `"1.0.2"` / `"v1.0.2"` を受け、3 要素でないものや負数は `nil`
  - `var description: String` — `"1.0.2"`
  - `static func current(bundle: Bundle = .main) -> AppVersion?`

- [ ] **Step 1: Write the failing test**

`Tests/AwayViewTests/AppVersionTests.swift` を新規作成:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'AppVersion' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/AwayView/AppVersion.swift` を新規作成:

```swift
import Foundation

// アプリの版と SemVer 比較。版の正は Info.plist の CFBundleShortVersionString で、
// コード側には持たない (Makefile の release/publish も同じ値を正としている)。
struct AppVersion: Equatable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "1.0.2" と "v1.0.2" の両方を受ける。3 要素でない / 数値でない / 負数は nil
    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let ma = Int(parts[0]), let mi = Int(parts[1]), let pa = Int(parts[2]),
              ma >= 0, mi >= 0, pa >= 0 else { return nil }
        self.init(major: ma, minor: mi, patch: pa)
    }

    // 辞書順ではなく数値順。"1.0.10" > "1.0.9"
    static func < (l: AppVersion, r: AppVersion) -> Bool {
        (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    /// 実行中バンドルの版。Info.plist を持たない実行形態 (swift test 等) では nil
    static func current(bundle: Bundle = .main) -> AppVersion? {
        guard let s = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return AppVersion(s)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AwayView/AppVersion.swift Tests/AwayViewTests/AppVersionTests.swift
git commit -m "feat: 版の表現と SemVer 比較を追加"
```

---

### Task 2: InstallOrigin

**Files:**
- Create: `Sources/AwayView/InstallOrigin.swift`
- Test: `Tests/AwayViewTests/InstallOriginTests.swift`

**Interfaces:**
- Consumes: なし
- Produces:
  - `enum InstallOrigin: Equatable { case homebrew, direct }`
  - `static let defaultPrefixes: [String]` — `["/opt/homebrew", "/usr/local"]`
  - `static func detect(prefixes: [String] = defaultPrefixes, fileManager: FileManager = .default) -> InstallOrigin`

**背景 (実機で確認済み)**: Homebrew の cask は app を **実体として** `/Applications/AwayView.app` へ移動する (symlink ではない)。管理記録は `<brew prefix>/Caskroom/awayview/<version>/` に残る。したがってバンドルの位置では判定できず、Caskroom のエントリの有無だけが信号になる。

- [ ] **Step 1: Write the failing test**

`Tests/AwayViewTests/InstallOriginTests.swift` を新規作成:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'InstallOrigin' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/AwayView/InstallOrigin.swift` を新規作成:

```swift
import Foundation

// インストール元。Homebrew cask は app を /Applications へ実体で置き
// (symlink ではない)、<brew prefix>/Caskroom/awayview/<version>/ に管理記録を残す。
// バンドルの位置では判定できないので、Caskroom のエントリの有無で判定する。
// brew CLI は起こさない (sysctl 直叩きでシェルアウトを避けている既存方針に合わせる)。
enum InstallOrigin: Equatable {
    case homebrew
    case direct

    static let defaultPrefixes = ["/opt/homebrew", "/usr/local"]   // Apple silicon / Intel
    static let caskName = "awayview"

    static func detect(prefixes: [String] = defaultPrefixes,
                       fileManager: FileManager = .default) -> InstallOrigin {
        for prefix in prefixes {
            let path = (prefix as NSString)
                .appendingPathComponent("Caskroom")
                .appending("/" + caskName)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return .homebrew
            }
        }
        return .direct
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AwayView/InstallOrigin.swift Tests/AwayViewTests/InstallOriginTests.swift
git commit -m "feat: Homebrew cask 管理下かどうかを判定する"
```

---

### Task 3: UpdateChecker

**Files:**
- Create: `Sources/AwayView/UpdateChecker.swift`
- Test: `Tests/AwayViewTests/UpdateCheckerTests.swift`

**Interfaces:**
- Consumes: `AppVersion` (Task 1)
- Produces:
  - `struct Release: Equatable { let version: AppVersion; let downloadURL: URL; let htmlURL: URL }`
  - `enum UpdateCheckResult: Equatable { case upToDate, available(Release), failed(String) }`
  - `protocol ReleaseFetching { func fetchLatestJSON() throws -> Data }`
  - `struct GitHubReleaseFetcher: ReleaseFetching`
  - `struct UpdateChecker { let fetcher: ReleaseFetching; let currentVersion: AppVersion; func check() -> UpdateCheckResult; static func parse(_ data: Data) -> Release? }`

**注意**: `check()` は同期。ネットワーク I/O を含むので、呼び出し側 (Task 6) が背景キューで回す。既存の `ConnectionMonitor` が同期で sysctl を叩き、tick 側がスケジュールを持っているのと同じ分担。

- [ ] **Step 1: Write the failing test**

`Tests/AwayViewTests/UpdateCheckerTests.swift` を新規作成:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `cannot find 'ReleaseFetching' in scope`

- [ ] **Step 3: Write minimal implementation**

`Sources/AwayView/UpdateChecker.swift` を新規作成:

```swift
import Foundation

struct Release: Equatable {
    let version: AppVersion
    let downloadURL: URL   // 配布 zip (AwayView-x.y.z.zip)
    let htmlURL: URL       // Releases ページ (更新を適用できないときの逃げ道)
}

// 「新版なし」と「確認できなかった」を nil に潰さない。
// v1.0.1 で ConnectionObserving を三値 enum にしたのと同じ理由。
enum UpdateCheckResult: Equatable {
    case upToDate
    case available(Release)
    case failed(String)
}

enum UpdateError: Error, LocalizedError {
    case http(Int)
    case emptyResponse
    case timedOut
    case process(String, Int32)

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .emptyResponse: return "empty response"
        case .timedOut: return "timed out"
        case .process(let path, let status): return "\(path) exited with \(status)"
        }
    }
}

// ネットワークを差し替えるための seam。テストでは stub を刺す
protocol ReleaseFetching {
    func fetchLatestJSON() throws -> Data
}

struct GitHubReleaseFetcher: ReleaseFetching {
    static let latestURL = URL(string: "https://api.github.com/repos/wadap/awayview/releases/latest")!

    func fetchLatestJSON() throws -> Data {
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AwayView", forHTTPHeaderField: "User-Agent")
        return try URLSession.shared.awayviewSynchronousData(for: request)
    }
}

extension URLSession {
    /// URLSession に同期版が無いのでセマフォで待つ。**背景キュー専用** (main で呼ばない)
    func awayviewSynchronousData(for request: URLRequest) throws -> Data {
        var outcome: Result<Data, Error> = .failure(UpdateError.emptyResponse)
        let semaphore = DispatchSemaphore(value: 0)
        let task = dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(error)
            } else if let http = response as? HTTPURLResponse,
                      !(200...299).contains(http.statusCode) {
                outcome = .failure(UpdateError.http(http.statusCode))
            } else if let data {
                outcome = .success(data)
            } else {
                outcome = .failure(UpdateError.emptyResponse)
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + request.timeoutInterval + 5) == .timedOut {
            task.cancel()
            throw UpdateError.timedOut
        }
        return try outcome.get()
    }
}

struct UpdateChecker {
    let fetcher: ReleaseFetching
    let currentVersion: AppVersion

    /// 同期。ネットワーク I/O を含むので呼び出し側が背景キューで回すこと
    func check() -> UpdateCheckResult {
        let data: Data
        do {
            data = try fetcher.fetchLatestJSON()
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let release = Self.parse(data) else {
            return .failed("could not parse release metadata")
        }
        return release.version > currentVersion ? .available(release) : .upToDate
    }

    // /releases/latest は draft と prerelease を返さないので、その判定は持たない
    static func parse(_ data: Data) -> Release? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let downloadURL: URL
                enum CodingKeys: String, CodingKey {
                    case name
                    case downloadURL = "browser_download_url"
                }
            }
            let tag: String
            let htmlURL: URL
            let assets: [Asset]
            enum CodingKeys: String, CodingKey {
                case tag = "tag_name"
                case htmlURL = "html_url"
                case assets
            }
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = AppVersion(payload.tag),
              let asset = payload.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            return nil
        }
        return Release(version: version, downloadURL: asset.downloadURL, htmlURL: payload.htmlURL)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AwayView/UpdateChecker.swift Tests/AwayViewTests/UpdateCheckerTests.swift
git commit -m "feat: GitHub Releases から最新版を確認する"
```

---

### Task 4: SettingsStore に更新設定を足す

**Files:**
- Modify: `Sources/AwayView/SettingsStore.swift` (末尾の `private func setOrRemove` の直前に追加)
- Test: `Tests/AwayViewTests/SettingsStoreTests.swift` (末尾にテストを追加)

**Interfaces:**
- Consumes: なし
- Produces:
  - `var autoCheckEnabled: Bool { get set }` — 既定 `true`。キー `AutoCheckUpdates`
  - `var lastCheckedAt: Date? { get set }` — キー `LastCheckedAt`

- [ ] **Step 1: Write the failing test**

`Tests/AwayViewTests/SettingsStoreTests.swift` の最後のテストの後 (クラスの閉じ括弧の直前) に追加:

```swift
    // 未設定なら自動チェックは有効。明示的に false を書いたときだけ無効
    func testAutoCheckDefaultsToEnabled() {
        XCTAssertTrue(store.autoCheckEnabled)
        store.autoCheckEnabled = false
        XCTAssertFalse(store.autoCheckEnabled)
        store.autoCheckEnabled = true
        XCTAssertTrue(store.autoCheckEnabled)
    }

    func testLastCheckedAtRoundTrip() {
        XCTAssertNil(store.lastCheckedAt)
        store.lastCheckedAt = now
        XCTAssertEqual(store.lastCheckedAt, now)
        store.lastCheckedAt = nil
        XCTAssertNil(store.lastCheckedAt)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL — `value of type 'SettingsStore' has no member 'autoCheckEnabled'`

- [ ] **Step 3: Write minimal implementation**

`Sources/AwayView/SettingsStore.swift` の `private func setOrRemove` の直前に追加:

```swift
    // --- 更新 -----------------------------------------------------------

    /// 既定は有効。UserDefaults に未登録のとき integer/bool の既定 false と区別するため
    /// object 経由で読む
    var autoCheckEnabled: Bool {
        get { defaults.object(forKey: "AutoCheckUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "AutoCheckUpdates") }
    }

    /// 最終チェック時刻。再起動を繰り返しても過剰にチェックしないための記録
    var lastCheckedAt: Date? {
        get { defaults.object(forKey: "LastCheckedAt") as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: "LastCheckedAt") }
            else { defaults.removeObject(forKey: "LastCheckedAt") }
        }
    }
```

あわせて、クラス冒頭のコメントのキー一覧を更新する:

```swift
// UserDefaults ベースの設定と手動モード。旧ファイルフラグ
// (override / force_low / res_high / res_low) の後継。StateMachine へは
// FlagReading として渡す。キー: Port / CIDRs / Mode / ModeChangedAt / ResLow /
// ResHigh / AutoCheckUpdates / LastCheckedAt
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AwayView/SettingsStore.swift Tests/AwayViewTests/SettingsStoreTests.swift
git commit -m "feat: 自動チェックの可否と最終チェック時刻を設定に持つ"
```

---

### Task 5: UpdateInstaller と CLI フラグ

**Files:**
- Create: `Sources/AwayView/UpdateInstaller.swift`
- Modify: `Sources/AwayView/main.swift` (`--help` の分岐の直前に追加、`--help` の usage 文字列も更新)

**Interfaces:**
- Consumes: `Release` / `UpdateCheckResult` / `UpdateChecker` / `GitHubReleaseFetcher` (Task 3), `AppVersion` (Task 1)
- Produces:
  - `enum InstallOutcome: Equatable { case ok, failed(String) }`
  - `enum UpdateInstaller { static var log: (String) -> Void; static let teamID: String; static func install(_ release: Release, bundleURL: URL) -> InstallOutcome; static func relaunch(bundleURL: URL) }`

**このタスクにユニットテストは書かない。** 自分自身のバンドルを消して置き換える操作を意味のあるテストにするには、本物のバンドルと署名済み zip が要る。CShim の ENOMEM リトライで同じ判断をしたのと同様、割に合わない。代わりに `--check-update` / `--install-update` で実機確認する (既存の `--apply` / `--restore` と同じ検証用フラグの並び)。**この穴は Task 9 で BACKLOG に明記する。**

- [ ] **Step 1: 実装を書く (テストなし。理由は上記)**

`Sources/AwayView/UpdateInstaller.swift` を新規作成:

```swift
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

    static var log: (String) -> Void = { _ in }

    static func install(_ release: Release,
                        bundleURL: URL = Bundle.main.bundleURL) -> InstallOutcome {
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

    // Developer ID 署名で、かつ leaf 証明書の OU が自分の Team ID であること。
    // notarize 済みバンドルは staple されているので、この検証を通れば配布物として正当
    private static func verifySignature(at url: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else { return false }

        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let req = requirement else { return false }

        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
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
```

- [ ] **Step 2: CLI フラグを足す**

`Sources/AwayView/main.swift` の `if args.contains("--help")` の**直前**に追加:

```swift
// 実機検証用: 更新チェックと適用を CLI から叩ける (ユニットテストの届かない範囲)
if args.contains("--check-update") {
    let current = AppVersion.current() ?? AppVersion(major: 0, minor: 0, patch: 0)
    print("current: \(current)")
    let checker = UpdateChecker(fetcher: GitHubReleaseFetcher(), currentVersion: current)
    switch checker.check() {
    case .upToDate: print("up to date"); exit(0)
    case .available(let r): print("available: \(r.version) \(r.downloadURL)"); exit(0)
    case .failed(let why): print("check FAILED: \(why)"); exit(1)
    }
}

if args.contains("--install-update") {
    // .build/release/AwayView のような素の実行ファイルでは bundleURL が
    // 親ディレクトリを指す。そのまま置換すると無関係なディレクトリを壊すので拒否する
    guard Bundle.main.bundleURL.pathExtension == "app" else {
        print("refusing: --install-update only works from inside AwayView.app")
        exit(1)
    }
    let current = AppVersion.current() ?? AppVersion(major: 0, minor: 0, patch: 0)
    let checker = UpdateChecker(fetcher: GitHubReleaseFetcher(), currentVersion: current)
    UpdateInstaller.log = { print($0) }
    switch checker.check() {
    case .upToDate: print("up to date"); exit(0)
    case .failed(let why): print("check FAILED: \(why)"); exit(1)
    case .available(let release):
        switch UpdateInstaller.install(release) {
        case .ok: print("installed \(release.version)"); exit(0)
        case .failed(let why): print("install FAILED: \(why)"); exit(1)
        }
    }
}
```

同じファイルの `--help` の usage 行を差し替える:

```swift
    print("usage: AwayView [--list-modes | --list-connections | --capture-home | --apply <WxH|default> | --restore | --check-update | --install-update]")
```

- [ ] **Step 3: ビルドが通ることを確認**

Run: `make check && make test`
Expected: エラーなし、既存テストは緑のまま

- [ ] **Step 4: 実機で確認**

```bash
swift build -c release
.build/release/AwayView --check-update
```

Expected: `current: 0.0.0` (CLI 実行では Info.plist が無いので 0.0.0) に続いて `available: 1.0.1 https://github.com/...` が出る。**ネットワークとパースと署名検証以外の全経路がここで通る。**

`--install-update` は実際にバンドルを置き換えるので、この時点では**実行しない** (Task 8 の最後にまとめて確認する)。

- [ ] **Step 5: Commit**

```bash
git add Sources/AwayView/UpdateInstaller.swift Sources/AwayView/main.swift
git commit -m "feat: 署名を検証して自分自身を置き換える更新処理を追加"
```

---

### Task 6: 文言を追加する

**Files:**
- Modify: `Sources/AwayView/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/AwayView/Resources/ja.lproj/Localizable.strings`

**Interfaces:**
- Consumes: なし
- Produces: 下記のキー。Task 7 と Task 8 が `L()` 経由で使う

Task 7/8 を先に書くとビルドは通るが文言が英語キーのまま画面に出るので、先にこちらを入れる。

- [ ] **Step 1: en を追加**

`en.lproj/Localizable.strings` の `"menu.quit"` の行の**直前**に追加:

```
"menu.version" = "AwayView %@";
"menu.check_updates" = "Check for Updates…";
"menu.checking" = "Checking for updates…";
"menu.update_available" = "Update to v%@";
"menu.update_available_brew" = "v%@ available — copy brew command";
```

同ファイルの末尾に追加:

```

/* updates */
"settings.auto_check" = "Check for updates automatically";
"update.up_to_date" = "AwayView %@ is the latest version.";
"update.failed" = "Could not check for updates: %@";
"update.copied" = "Copied: %@\nRun it in Terminal to update.";
"update.blocked_low" = "AwayView is at the low resolution right now. Switch back to the home resolution first, then update — restarting while lowered can make the app mis-learn your home resolution.";
"update.install_failed" = "Update failed: %@\nOpen the Releases page to update manually.";
"update.open_releases" = "Open Releases Page";
"update.ok" = "OK";
```

- [ ] **Step 2: ja を追加**

`ja.lproj/Localizable.strings` の `"menu.quit"` の行の**直前**に追加:

```
"menu.version" = "AwayView %@";
"menu.check_updates" = "更新を確認…";
"menu.checking" = "更新を確認中…";
"menu.update_available" = "v%@ に更新";
"menu.update_available_brew" = "v%@ が利用可能 — brew のコマンドをコピー";
```

同ファイルの末尾に追加:

```

/* updates */
"settings.auto_check" = "自動で更新を確認する";
"update.up_to_date" = "AwayView %@ は最新版です。";
"update.failed" = "更新を確認できませんでした: %@";
"update.copied" = "コピーしました: %@\nターミナルで実行すると更新できます。";
"update.blocked_low" = "いま低解像度で動作中です。ホーム解像度に戻してから更新してください。低解像度のまま再起動すると、その解像度をホームとして誤って学習することがあります。";
"update.install_failed" = "更新に失敗しました: %@\nReleases ページから手動で更新してください。";
"update.open_releases" = "Releases を開く";
"update.ok" = "OK";
```

- [ ] **Step 3: 両ファイルのキーが一致することを確認**

```bash
diff <(grep -oE '^"[a-z_.]+"' Sources/AwayView/Resources/en.lproj/Localizable.strings | sort) \
     <(grep -oE '^"[a-z_.]+"' Sources/AwayView/Resources/ja.lproj/Localizable.strings | sort)
```

Expected: 差分なし (出力が空)

- [ ] **Step 4: Commit**

```bash
git add Sources/AwayView/Resources
git commit -m "feat: 版表示と更新まわりの文言を en/ja に追加"
```

---

### Task 7: 設定ウィンドウに自動チェックのトグルを足す

**Files:**
- Modify: `Sources/AwayView/SettingsWindow.swift`

**Interfaces:**
- Consumes: `SettingsStore.autoCheckEnabled` (Task 4), `settings.auto_check` (Task 6)
- Produces: なし (UI のみ)

- [ ] **Step 1: `@State` を足す**

`SettingsView` の `@State private var launchAtLogin: Bool` の直後に追加:

```swift
    @State private var autoCheckUpdates: Bool
```

`init` の `_launchAtLogin = ...` の直後に追加:

```swift
        _autoCheckUpdates = State(initialValue: settings.autoCheckEnabled)
```

- [ ] **Step 2: トグルを足す**

`Toggle(L("settings.launch_at_login"), isOn: $launchAtLogin)` の `.onChange` ブロックの**閉じ括弧の直後**に追加:

```swift
            Toggle(L("settings.auto_check"), isOn: $autoCheckUpdates)
                .onChange(of: autoCheckUpdates) { enabled in
                    settings.autoCheckEnabled = enabled
                }
```

- [ ] **Step 3: ビルドとテスト**

Run: `make check && make test`
Expected: エラーなし、テストは緑

- [ ] **Step 4: Commit**

```bash
git add Sources/AwayView/SettingsWindow.swift
git commit -m "feat: 設定で自動チェックの有無を切り替えられるようにする"
```

---

### Task 8: メニューに版と更新を出す

**Files:**
- Modify: `Sources/AwayView/MenuController.swift`

**Interfaces:**
- Consumes: `AppVersion` (Task 1), `InstallOrigin` (Task 2), `UpdateChecker` / `GitHubReleaseFetcher` / `Release` / `UpdateCheckResult` (Task 3), `SettingsStore.autoCheckEnabled` / `.lastCheckedAt` (Task 4), `UpdateInstaller` (Task 5), 文言 (Task 6)
- Produces: なし (最終結線)

- [ ] **Step 1: 状態とスケジューラを足す**

`AppController` のプロパティ (`private var lastLogged: WatchState?` の直後) に追加:

```swift
    private let origin = InstallOrigin.detect()
    private let version = AppVersion.current()
    private var pendingRelease: Release?
    private var isChecking = false
    private var updateTimer: DispatchSourceTimer?
```

`applicationDidFinishLaunching` の `timer = t` の直後に追加:

```swift
        // 更新チェック: 起動 5 分後から 1 時間ごとに「24 時間経ったか」を見る。
        // 判定を時刻ベースにしているのは、再起動を繰り返しても過剰に叩かないため
        let u = DispatchSource.makeTimerSource(queue: .main)
        u.schedule(deadline: .now() + 300, repeating: 3600)
        u.setEventHandler { [weak self] in self?.autoCheckIfDue() }
        u.resume()
        updateTimer = u

        UpdateInstaller.log = { [writer] message in writer.log(message) }
```

- [ ] **Step 2: チェック処理を足す**

`updateIcon()` の実装の直後 (`// --- メニュー構築` コメントの直前) に追加:

```swift
    // --- 更新 ------------------------------------------------------------

    private func autoCheckIfDue() {
        guard settings.autoCheckEnabled else { return }
        if let last = settings.lastCheckedAt, Date().timeIntervalSince(last) < 24 * 3600 {
            return
        }
        checkForUpdates(manual: false)
    }

    private func checkForUpdates(manual: Bool) {
        guard !isChecking, let version else { return }
        isChecking = true
        let checker = UpdateChecker(fetcher: GitHubReleaseFetcher(), currentVersion: version)
        // ネットワーク I/O は同期なので背景キューで回す
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = checker.check()
            DispatchQueue.main.async { self?.checkFinished(result, manual: manual) }
        }
    }

    private func checkFinished(_ result: UpdateCheckResult, manual: Bool) {
        isChecking = false
        settings.lastCheckedAt = Date()
        switch result {
        case .upToDate:
            pendingRelease = nil
            writer.log("update check: up to date")
            if manual, let version {
                alert(L("update.up_to_date", version.description))
            }
        case .available(let release):
            pendingRelease = release
            writer.log("update check: \(release.version) available")
        case .failed(let reason):
            // 確認できなかっただけ。watcher は止めない (hooks の失敗と同じ規律)
            writer.log("!! update check failed: \(reason)")
            if manual { alert(L("update.failed", reason)) }
        }
    }

    @objc private func checkForUpdatesManually() {
        checkForUpdates(manual: true)
    }

    @objc private func copyBrewCommand() {
        let command = "brew upgrade --cask awayview"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        alert(L("update.copied", command))
    }

    @objc private func installUpdate() {
        guard let release = pendingRelease else { return }
        // 低解像度のまま再起動すると、その解像度をホームとして誤学習しうる。
        // 適用がユーザー操作起点でも、リモート接続中に押される可能性は残るので状態で塞ぐ
        guard currentState == .home else {
            alert(L("update.blocked_low"))
            return
        }
        writer.log("update: installing \(release.version)")
        switch UpdateInstaller.install(release) {
        case .ok:
            UpdateInstaller.relaunch()
            NSApp.terminate(nil)
        case .failed(let reason):
            writer.log("!! update failed: \(reason)")
            alertWithReleasesLink(L("update.install_failed", reason), url: release.htmlURL)
        }
    }

    private func alert(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)   // accessory アプリなので明示活性化
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: L("update.ok"))
        a.runModal()
    }

    private func alertWithReleasesLink(_ message: String, url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = message
        a.addButton(withTitle: L("update.open_releases"))
        a.addButton(withTitle: L("update.ok"))
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateMenuItem() -> NSMenuItem {
        if isChecking {
            return disabled(L("menu.checking"))
        }
        guard let release = pendingRelease else {
            let item = NSMenuItem(title: L("menu.check_updates"),
                                  action: #selector(checkForUpdatesManually),
                                  keyEquivalent: "")
            item.target = self
            return item
        }
        switch origin {
        case .homebrew:
            // brew 管理下でアプリが自分を置き換えると brew 側の版情報がずれる。
            // ここではコマンドを渡すだけにする
            let item = NSMenuItem(title: L("menu.update_available_brew", release.version.description),
                                  action: #selector(copyBrewCommand),
                                  keyEquivalent: "")
            item.target = self
            return item
        case .direct:
            let item = NSMenuItem(title: L("menu.update_available", release.version.description),
                                  action: #selector(installUpdate),
                                  keyEquivalent: "")
            item.target = self
            return item
        }
    }
```

- [ ] **Step 3: メニューに項目を足す**

`menuNeedsUpdate` の `menu.addItem(.separator())` (設定項目の後、終了の前) の**直後**、`let quit = ...` の**直前**に追加:

```swift
        menu.addItem(disabled(L("menu.version", version?.description ?? "dev")))
        menu.addItem(updateMenuItem())
        menu.addItem(.separator())
```

- [ ] **Step 4: ビルドとテスト**

Run: `make check && make test`
Expected: エラーなし、テストは緑

- [ ] **Step 5: 実機で確認**

```bash
make install
```

確認すること:
- メニューに `AwayView 1.0.1` が出る
- 「更新を確認…」を押すと、数秒後に「AwayView 1.0.1 は最新版です。」が出る (現行が最新のため)
- `tail -3 ~/.local/state/awayview/watch.log` に `update check: up to date` が出ている
- 設定ウィンドウに「自動で更新を確認する」が出ていて、切り替えられる

**このマシンは Homebrew 管理下なので、新版があった場合の表示は「brew のコマンドをコピー」になる**。`direct` 経路の表示と自己置換は、Homebrew の Caskroom エントリを一時的に退避すれば確認できる:

```bash
sudo mv /opt/homebrew/Caskroom/awayview /opt/homebrew/Caskroom/awayview.bak
# 確認が終わったら必ず戻す
sudo mv /opt/homebrew/Caskroom/awayview.bak /opt/homebrew/Caskroom/awayview
```

- [ ] **Step 6: Commit**

```bash
git add Sources/AwayView/MenuController.swift
git commit -m "feat: メニューに版を表示し、更新の確認と適用を出す"
```

---

### Task 9: README と BACKLOG

**Files:**
- Modify: `README.md`
- Modify: `README.ja.md`
- Modify: `.steering/BACKLOG.md`

**Interfaces:**
- Consumes: なし
- Produces: なし

**確認済み**: Homebrew 6.0.20 の `brew trust` の書式は `brew trust --tap <tap>`。非公式 tap の cask を読み込むにはこれが要る。

- [ ] **Step 1: README.md を直す**

`### Homebrew` の下のコマンドブロックを差し替える:

```
### Homebrew
    brew tap wadap/tap
    brew trust --tap wadap/tap    # Homebrew 6+ requires this for third-party taps
    brew install --cask awayview
```

`## Menu bar` セクションの最後 (`Resolution pickers for both high and low sides.` の直後) に追加:

```

The menu also shows the running version and checks GitHub for newer releases
(daily, and on demand). If AwayView was installed with Homebrew it hands you
the `brew upgrade` command rather than replacing itself; installed any other
way, it downloads the notarized build, verifies its signature, and restarts.
Updates are never applied while the display is lowered — switch back to the
home resolution first. Automatic checking can be turned off in Settings.
```

- [ ] **Step 2: README.ja.md を直す**

`### Homebrew` の下のコマンドブロックを差し替える:

```
### Homebrew
    brew tap wadap/tap
    brew trust --tap wadap/tap    # Homebrew 6 以降、サードパーティ tap に必要
    brew install --cask awayview
```

`## メニュー` セクションの最後 (`高解像度・低解像度それぞれに解像度選択メニューあり。` の直後) に追加:

```

メニューには動作中の版も出る。GitHub の Releases を 1 日 1 回と手動で確認し、
Homebrew で入れている場合は `brew upgrade` のコマンドを渡すだけ、それ以外の
経路で入れている場合は notarize 済みビルドを取得して署名を検証し、置き換えて
再起動する。低解像度で動作中は更新を適用しない (先にホーム解像度へ戻すこと)。
自動確認は設定でオフにできる。
```

- [ ] **Step 3: BACKLOG に穴を明記する**

`.steering/BACKLOG.md` の `## 既知の未解決 (別ドキュメントに詳細あり)` の箇条書きの末尾に追加:

```
- **`UpdateInstaller` に自動テストが無い** — `.steering/20260828-version-and-updater/`。
  自分自身のバンドルを消して置き換える操作は、本物のバンドルと署名済み zip を
  用意しないと意味のあるテストにならないため見送った。取得・展開・署名検証・置換の
  経路は `--check-update` / `--install-update` の実機確認だけが担保になっている。
  リリース手順に「新版を 1 つ前の版から更新して確認する」を入れるのが現実的な穴埋め
```

- [ ] **Step 4: Commit**

```bash
git add README.md README.ja.md .steering/BACKLOG.md
git commit -m "docs: brew trust とアプリ内更新を README に書き、テストの穴を BACKLOG に残す"
```

---

## 全タスク後の確認

- [ ] `make check && make test` が緑
- [ ] `diff` で en/ja の文言キーが一致している (Task 6 Step 3 のコマンド)
- [ ] `.build/release/AwayView --check-update` が最新版を報告する
- [ ] メニューに版が出て、手動チェックが動く
- [ ] CI (GitHub Actions) が緑 — **ローカルは Swift 6.3 / CI は Swift 6.1 なので、
      ローカルで通っても CI で型エラーになることがある** (`??` のオーバーロード解決差で
      一度踏んでいる)。push 後に必ず確認する
- [ ] `~/git/homebrew-tap` を pull して cask が 1.0.1 になっているか確認する
      (本作業とは独立だが、次のリリースでずれていると混乱する)
