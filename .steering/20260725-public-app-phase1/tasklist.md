# AwayView Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ScreenshareRes（Swift native 版）を公開アプリ **AwayView** に汎用化する — クリーンブレーク・ポート/CIDR 設定化・設定ウィンドウ・日英 i18n・README 英語化。

**Architecture:** 既存 StateMachine（純粋ロジック）は無変更。周辺を差し替える: 判定は `CIDRMatcher`（設定 CIDR リスト）、設定/フラグは `SettingsStore`（UserDefaults）、ファイル出力は `ObservationWriter`（state + watch.log のみ）に縮小。設定ウィンドウは SwiftUI を NSWindow にホスト。

**Tech Stack:** Swift 5.9 / SwiftPM / AppKit + SwiftUI / XCTest / Makefile ビルド（Xcode プロジェクトなし）

## Global Constraints

- 作業ブランチ: `phase1-awayview`（main から分岐。Task 1 冒頭で作成）
- `swift test` は `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 必須（`make test` は設定済み。裸で叩くときだけ注意）
- このシェルは **noclobber**: 既存ファイルへの `>` リダイレクト禁止（Write ツールか `>|`）
- `Sources/CShim/`（pcblist_n）は XNU 非公開 ABI の写経 — **一切触らない**
- 本番稼働中の `~/Applications/ScreenshareRes.app` は Task 10（実機移行）まで触らない
- push は SSH でなく `git -c credential.helper='!gh auth git-credential' push https://github.com/wadap/screenshare-res.git <branch>`
- bundle id / UserDefaults suite = `com.wadap.AwayView`。suite 名が自 bundle id と同一のとき `UserDefaults(suiteName:)` は nil → `.standard` フォールバック必須（916ecd8 の教訓）
- watch.log の文言は英語固定（i18n 対象外）

---

### Task 1: クリーンブレーク & AwayView リネーム（repo 再構成）

**Files:**
- Delete: `bin/` `swiftbar/` `tests/` `install.sh` `config.example.zsh`
- Move: `native/{Package.swift,Info.plist,Sources,Tests}` → repo 直下、`native/` 削除
- Rename: `Sources/ScreenshareRes` → `Sources/AwayView`、`Tests/ScreenshareResTests` → `Tests/AwayViewTests`
- Modify: `Package.swift` `Info.plist` `Makefile` `.gitignore` `Sources/AwayView/main.swift` `Sources/AwayView/DisplayController.swift`、テスト 5 ファイルの import

**Interfaces:**
- Produces: モジュール名 `AwayView`（以後の全タスクは `@testable import AwayView`）。`make build|install|uninstall|check|test`。実行体名 `AwayView`

- [ ] **Step 1: ブランチ作成と legacy 削除・移動**

```bash
git checkout -b phase1-awayview
git rm -r bin swiftbar tests install.sh config.example.zsh
git mv native/Package.swift native/Info.plist native/Sources native/Tests .
rm -rf native   # 残るのは untracked の .build/ dist/ のみ
git mv Sources/ScreenshareRes Sources/AwayView
git mv Tests/ScreenshareResTests Tests/AwayViewTests
```

- [ ] **Step 2: Package.swift を全置換**

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AwayView",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "CShim",
            path: "Sources/CShim"
        ),
        .executableTarget(
            name: "AwayView",
            dependencies: ["CShim"],
            path: "Sources/AwayView",
            linkerSettings: [
                .linkedFramework("ColorSync"),  // CGDisplayCreateUUIDFromDisplayID の実体
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "AwayViewTests",
            dependencies: ["AwayView"],
            path: "Tests/AwayViewTests"
        ),
    ]
)
```

- [ ] **Step 3: Info.plist を全置換**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>AwayView</string>
	<key>CFBundleDisplayName</key>
	<string>AwayView</string>
	<key>CFBundleIdentifier</key>
	<string>com.wadap.AwayView</string>
	<key>CFBundleVersion</key>
	<string>1.0</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleExecutable</key>
	<string>AwayView</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>AwayView</string>
</dict>
</plist>
```

- [ ] **Step 4: Makefile を全置換**

```make
.PHONY: build install uninstall check test

# swift test に XCTest が要るため Xcode toolchain を明示 (CLT には無い)
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
APP     = dist/AwayView.app
APP_DST = $(HOME)/Applications/AwayView.app

build: ## .app バンドルを組み立てて ad-hoc 署名
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/AwayView $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	@if [ -d .build/release/AwayView_AwayView.bundle ]; then \
	  cp -R .build/release/AwayView_AwayView.bundle $(APP)/Contents/Resources/; fi
	codesign --force --sign - $(APP)
	@echo "built: $(APP)"

install: build ## ~/Applications へ入れ替えて起動
	-pkill -x AwayView 2>/dev/null
	rm -rf $(APP_DST)
	cp -R $(APP) $(APP_DST)
	open $(APP_DST)
	@echo "installed & launched: $(APP_DST)"

uninstall: ## 終了して削除 (ログイン項目は設定ウィンドウで解除)
	-pkill -x AwayView 2>/dev/null
	rm -rf $(APP_DST)
	@echo "uninstalled: $(APP_DST)"

check: ## 型チェック (debug build)
	swift build

test:
	DEVELOPER_DIR=$(DEVELOPER_DIR) swift test 2>&1 | tail -1
```

（`AwayView_AwayView.bundle` のコピーは Task 7 で i18n リソースが増えたとき有効になるガード）

- [ ] **Step 5: .gitignore の Swift 節を更新**

`native/.build/` → `.build/`、`native/dist/` → `dist/` に変更（他の行はそのまま）。

- [ ] **Step 6: ソース内の名前参照を更新**

- テスト 5 ファイル（`Tests/AwayViewTests/*.swift`）: `@testable import ScreenshareRes` → `@testable import AwayView`
- `Sources/AwayView/main.swift:72`: usage 文字列 `ScreenshareRes [--list-modes ...]` → `AwayView [--list-modes ...]`
- `Sources/AwayView/DisplayController.swift:80`: `static let suiteName = "com.wadap.screenshare-res.native"` → `static let suiteName = "com.wadap.AwayView"`
  （ホーム学習・TargetDisplayUUID は新 suite で再学習になる。設計どおり）

- [ ] **Step 7: ビルドとテストで移行を検証**

Run: `make check && make test`
Expected: ビルド成功、既存テスト全 PASS（StateMachine/StateStore/Hooks/ConnectionMonitor/DisplayModeSelection）

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "refactor: クリーンブレーク — native を repo 直下へ昇格し AwayView に改名"
```

---

### Task 2: CIDRMatcher（TDD）

**Files:**
- Create: `Sources/AwayView/CIDRMatcher.swift`
- Test: `Tests/AwayViewTests/CIDRMatcherTests.swift`

**Interfaces:**
- Produces: `struct CIDRMatcher { init(_ cidrs: [String]); func matches(_ ip: String) -> Bool; static func parseCIDR(_ s: String) -> ([UInt8], Int)?; static let defaultCIDRs: [String] }`

- [ ] **Step 1: 失敗するテストを書く**

`Tests/AwayViewTests/CIDRMatcherTests.swift`:

```swift
import XCTest
@testable import AwayView

final class CIDRMatcherTests: XCTestCase {
    let tailscale = CIDRMatcher(CIDRMatcher.defaultCIDRs)

    func testIPv4InRange() {
        XCTAssertTrue(tailscale.matches("100.64.0.1"))
        XCTAssertTrue(tailscale.matches("100.99.1.2"))
        XCTAssertTrue(tailscale.matches("100.127.255.255"))
    }

    func testIPv4OutOfRange() {
        XCTAssertFalse(tailscale.matches("100.63.255.255"))
        XCTAssertFalse(tailscale.matches("100.128.0.1"))
        XCTAssertFalse(tailscale.matches("192.168.1.10"))
        XCTAssertFalse(tailscale.matches("100.64.0"))       // 不完全な v4
        XCTAssertFalse(tailscale.matches(""))
        XCTAssertFalse(tailscale.matches("100.64.0.999"))
    }

    func testIPv6Range() {
        XCTAssertTrue(tailscale.matches("fd7a:115c:a1e0::1"))
        XCTAssertTrue(tailscale.matches("FD7A:115C:A1E0:AB12:4843:CD96:6265:B2B5"))
        XCTAssertFalse(tailscale.matches("fd7a:115c:a1e1::1"))
        XCTAssertFalse(tailscale.matches("fe80::1"))
        XCTAssertFalse(tailscale.matches("::1"))
    }

    func testCustomRuleAndExactHost() {
        let m = CIDRMatcher(["192.168.1.0/24", "10.0.0.1/32"])
        XCTAssertTrue(m.matches("192.168.1.42"))
        XCTAssertFalse(m.matches("192.168.2.1"))
        XCTAssertTrue(m.matches("10.0.0.1"))
        XCTAssertFalse(m.matches("10.0.0.2"))
    }

    func testInvalidEntriesAreIgnored() {
        let m = CIDRMatcher(["not-a-cidr", "100.64.0.0/10", "1.2.3.4/33", "1.2.3.4"])
        XCTAssertTrue(m.matches("100.99.1.2"))    // 有効エントリは生きる
        XCTAssertFalse(m.matches("1.2.3.4"))      // prefix なし・不正はマッチ源にならない
    }

    func testEmptyListMatchesNothing() {
        let m = CIDRMatcher([])
        XCTAssertFalse(m.matches("100.99.1.2"))
        XCTAssertFalse(m.matches("fd7a:115c:a1e0::1"))
    }

    func testParseCIDRValidation() {
        XCTAssertNotNil(CIDRMatcher.parseCIDR("100.64.0.0/10"))
        XCTAssertNotNil(CIDRMatcher.parseCIDR("fd7a:115c:a1e0::/48"))
        XCTAssertNotNil(CIDRMatcher.parseCIDR("0.0.0.0/0"))
        XCTAssertNil(CIDRMatcher.parseCIDR("100.64.0.0"))       // prefix なし
        XCTAssertNil(CIDRMatcher.parseCIDR("100.64.0.0/33"))    // v4 上限超え
        XCTAssertNil(CIDRMatcher.parseCIDR("fd7a::/129"))       // v6 上限超え
        XCTAssertNil(CIDRMatcher.parseCIDR("hello/8"))
    }
}
```

- [ ] **Step 2: 失敗を確認**

Run: `make test`
Expected: FAIL（`cannot find 'CIDRMatcher' in scope` のコンパイルエラー）

- [ ] **Step 3: 実装**

`Sources/AwayView/CIDRMatcher.swift`:

```swift
import Foundation

// CIDR 表記 (v4/v6 混在可) のリストに対する IP マッチャ。isTailscaleIP の後継。
// パースは初期化時に 1 回。不正エントリは無視して有効エントリだけで動く
// (設定 UI が保存前に検証するので、実行時に不正が来るのは defaults 手書きのときだけ)。
struct CIDRMatcher {
    static let defaultCIDRs = ["100.64.0.0/10", "fd7a:115c:a1e0::/48"]   // Tailscale

    private struct Rule {
        let bytes: [UInt8]   // ネットワークアドレス (v4=4, v6=16 bytes)
        let prefix: Int
    }
    private let rules: [Rule]

    init(_ cidrs: [String]) {
        rules = cidrs.compactMap { cidr in
            guard let (bytes, prefix) = Self.parseCIDR(cidr) else { return nil }
            return Rule(bytes: bytes, prefix: prefix)
        }
    }

    /// "100.64.0.0/10" → (ネットワークアドレス bytes, prefix 長)。不正なら nil
    static func parseCIDR(_ s: String) -> ([UInt8], Int)? {
        let parts = s.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]),
              let bytes = parseIP(String(parts[0])),
              (0...bytes.count * 8).contains(prefix) else { return nil }
        return (bytes, prefix)
    }

    static func parseIP(_ s: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, s, &v4) == 1 {
            return withUnsafeBytes(of: v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, s, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) }
        }
        return nil
    }

    func matches(_ ip: String) -> Bool {
        guard let bytes = Self.parseIP(ip) else { return false }
        return rules.contains { rule in
            rule.bytes.count == bytes.count && Self.prefixMatch(bytes, rule.bytes, bits: rule.prefix)
        }
    }

    private static func prefixMatch(_ a: [UInt8], _ b: [UInt8], bits: Int) -> Bool {
        let fullBytes = bits / 8
        guard a.prefix(fullBytes).elementsEqual(b.prefix(fullBytes)) else { return false }
        let rem = bits % 8
        guard rem > 0 else { return true }
        let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - rem))
        return (a[fullBytes] & mask) == (b[fullBytes] & mask)
    }
}
```

- [ ] **Step 4: テストが通ることを確認**

Run: `make test`
Expected: 全 PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/AwayView/CIDRMatcher.swift Tests/AwayViewTests/CIDRMatcherTests.swift
git commit -m "feat: CIDRMatcher — 検知 IP 範囲を CIDR リストで設定可能に"
```

---

### Task 3: SettingsStore（UserDefaults、TDD）

**Files:**
- Create: `Sources/AwayView/SettingsStore.swift`
- Modify: `Sources/AwayView/StateStore.swift`（`enum WatchMode` の定義を SettingsStore.swift へ移動 = StateStore.swift から削除）
- Test: `Tests/AwayViewTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `FlagReading`（StateMachine.swift、無変更）、`CIDRMatcher.defaultCIDRs`（Task 2）
- Produces: `final class SettingsStore: FlagReading { init(defaults: UserDefaults, now: @escaping () -> Date); convenience init(); var port: UInt16; var cidrs: [String]; var currentMode: WatchMode; func setMode(_:); var modeChangedAt: Date?; func setResLow(_: String?); func setResHigh(_: String?); static let defaultPort: UInt16 }`。`enum WatchMode` はこのファイルが定義元になる

- [ ] **Step 1: 失敗するテストを書く**

`Tests/AwayViewTests/SettingsStoreTests.swift`:

```swift
import XCTest
@testable import AwayView

final class SettingsStoreTests: XCTestCase {
    let suite = "awayview-unit-tests"
    var defaults: UserDefaults!
    var now: Date!
    var store: SettingsStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        now = ISO8601DateFormatter().date(from: "2026-07-25T10:00:00+09:00")!
        store = SettingsStore(defaults: defaults, now: { self.now })
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    // 未設定 = 従来と同一の既定値 (5900 / Tailscale 範囲 / 自動)
    func testDefaults() {
        XCTAssertEqual(store.port, 5900)
        XCTAssertEqual(store.cidrs, ["100.64.0.0/10", "fd7a:115c:a1e0::/48"])
        XCTAssertEqual(store.currentMode, .auto)
        XCTAssertFalse(store.overrideHigh)
        XCTAssertFalse(store.forceLow)
        XCTAssertNil(store.resLow)
        XCTAssertNil(store.resHigh)
        XCTAssertNil(store.modeChangedAt)
    }

    func testPortRoundTripAndInvalidFallback() {
        store.port = 5901
        XCTAssertEqual(store.port, 5901)
        defaults.set(0, forKey: "Port")       // defaults 手書きで壊された値は既定へ
        XCTAssertEqual(store.port, 5900)
        defaults.set(99999, forKey: "Port")
        XCTAssertEqual(store.port, 5900)
    }

    func testCIDRRoundTrip() {
        store.cidrs = ["192.168.0.0/16"]
        XCTAssertEqual(store.cidrs, ["192.168.0.0/16"])
        store.cidrs = []
        XCTAssertEqual(store.cidrs, [])       // 空リスト = 自動切替オフ (既定に戻さない)
    }

    // モードは排他 + 切替時刻を記録 (メニューの「(HH:mm〜)」表示用)
    func testModeIsExclusiveAndStampsTime() {
        store.setMode(.high)
        XCTAssertTrue(store.overrideHigh)
        XCTAssertFalse(store.forceLow)
        XCTAssertEqual(store.modeChangedAt, now)
        store.setMode(.low)
        XCTAssertFalse(store.overrideHigh)
        XCTAssertTrue(store.forceLow)
        store.setMode(.auto)
        XCTAssertEqual(store.currentMode, .auto)
        XCTAssertFalse(store.overrideHigh)
        XCTAssertFalse(store.forceLow)
    }

    func testResSelectionRoundTrip() {
        store.setResLow("1920x810")
        store.setResHigh("2560x1080")
        XCTAssertEqual(store.resLow, "1920x810")
        XCTAssertEqual(store.resHigh, "2560x1080")
        store.setResLow(nil)
        store.setResHigh(nil)
        XCTAssertNil(store.resLow)
        XCTAssertNil(store.resHigh)
    }
}
```

- [ ] **Step 2: 失敗を確認**

Run: `make test`
Expected: FAIL（`cannot find 'SettingsStore' in scope`）

- [ ] **Step 3: 実装**

`Sources/AwayView/SettingsStore.swift`:

```swift
import Foundation

enum WatchMode {
    case auto, high, low
}

// UserDefaults ベースの設定と手動モード。旧ファイルフラグ
// (override / force_low / res_high / res_low) の後継。StateMachine へは
// FlagReading として渡す。キー: Port / CIDRs / Mode / ModeChangedAt / ResLow / ResHigh
final class SettingsStore: FlagReading {
    static let suiteName = "com.wadap.AwayView"
    static let defaultPort: UInt16 = 5900

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults, now: @escaping () -> Date = { Date() }) {
        self.defaults = defaults
        self.now = now
    }

    /// アプリ本体用。suite 名が自 bundle id と同一のとき nil になるため .standard へフォールバック
    convenience init() {
        self.init(defaults: UserDefaults(suiteName: SettingsStore.suiteName) ?? .standard)
    }

    // --- 監視設定 -----------------------------------------------------

    var port: UInt16 {
        get {
            let v = defaults.integer(forKey: "Port")
            return (1...65535).contains(v) ? UInt16(v) : Self.defaultPort
        }
        set { defaults.set(Int(newValue), forKey: "Port") }
    }

    var cidrs: [String] {
        get { defaults.stringArray(forKey: "CIDRs") ?? CIDRMatcher.defaultCIDRs }
        set { defaults.set(newValue, forKey: "CIDRs") }
    }

    // --- 手動モード -----------------------------------------------------

    var currentMode: WatchMode {
        switch defaults.string(forKey: "Mode") {
        case "high": return .high
        case "low": return .low
        default: return .auto
        }
    }

    func setMode(_ mode: WatchMode) {
        switch mode {
        case .auto: defaults.removeObject(forKey: "Mode")
        case .high: defaults.set("high", forKey: "Mode")
        case .low: defaults.set("low", forKey: "Mode")
        }
        defaults.set(now(), forKey: "ModeChangedAt")
    }

    var modeChangedAt: Date? { defaults.object(forKey: "ModeChangedAt") as? Date }

    // --- FlagReading ----------------------------------------------------

    var overrideHigh: Bool { currentMode == .high }
    var forceLow: Bool { currentMode == .low }
    var resLow: String? { defaults.string(forKey: "ResLow") }
    var resHigh: String? { defaults.string(forKey: "ResHigh") }

    func setResLow(_ res: String?) { setOrRemove("ResLow", res) }
    func setResHigh(_ res: String?) { setOrRemove("ResHigh", res) }

    private func setOrRemove(_ key: String, _ value: String?) {
        if let value { defaults.set(value, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}
```

同時に `Sources/AwayView/StateStore.swift` から `enum WatchMode { case auto, high, low }` の 3 行を削除（定義が二重になるため。StateStore 自体はまだ触らない）。

- [ ] **Step 4: テストが通ることを確認**

Run: `make test`
Expected: 全 PASS（既存 StateStoreTests も含む — WatchMode は同一モジュール内で解決される）

- [ ] **Step 5: Commit**

```bash
git add Sources/AwayView/SettingsStore.swift Sources/AwayView/StateStore.swift Tests/AwayViewTests/SettingsStoreTests.swift
git commit -m "feat: SettingsStore — 設定・手動モードを UserDefaults に一本化"
```

---

### Task 4: StateStore → ObservationWriter（出力専用に縮小）

**Files:**
- Rename+Modify: `Sources/AwayView/StateStore.swift` → `Sources/AwayView/ObservationWriter.swift`
- Rename+Modify: `Tests/AwayViewTests/StateStoreTests.swift` → `Tests/AwayViewTests/ObservationWriterTests.swift`
- Modify: `Sources/AwayView/main.swift:78`（env 変数名）
- Modify: `Sources/AwayView/MenuController.swift`（コンパイルを通すための最小改名。本格統合は Task 5）

**Interfaces:**
- Produces: `final class ObservationWriter { let directory: URL; init(directory: URL = ~/.local/state/awayview, now: @escaping () -> Date = { Date() }); func writeState(_ state: WatchState, remoteIP: String?); func log(_ message: String) }`。テスト用 env は `AWAYVIEW_STATE_DIR`
- 消えるもの: `StateStore` の `setMode/currentMode/overrideHigh/forceLow/resLow/resHigh/setResLow/setResHigh`（SettingsStore に移行済み）

- [ ] **Step 1: テストを先に書き換える**

```bash
git mv Tests/AwayViewTests/StateStoreTests.swift Tests/AwayViewTests/ObservationWriterTests.swift
```

`Tests/AwayViewTests/ObservationWriterTests.swift` を全置換:

```swift
import XCTest
@testable import AwayView

final class ObservationWriterTests: XCTestCase {
    var dir: URL!
    var now: Date!
    var writer: ObservationWriter!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("awayview-test-\(UUID().uuidString)")
        now = ISO8601DateFormatter().date(from: "2026-07-24T10:00:00+09:00")!
        writer = ObservationWriter(directory: dir, now: { self.now })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func read(_ name: String) -> String? {
        try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
    }

    // state ファイルは従来フォーマット (値はダブルクォート・3 行)
    func testStateFileFormat() {
        writer.writeState(.low, remoteIP: "100.99.1.2")
        XCTAssertEqual(read("state"), """
        STATE="low"
        REMOTE_IP="100.99.1.2"
        CHANGED_AT="2026-07-24 10:00:00"

        """)
    }

    func testStateLowManualRawValue() {
        writer.writeState(.lowManual, remoteIP: nil)
        XCTAssertTrue(read("state")!.hasPrefix("STATE=\"low_manual\"\nREMOTE_IP=\"\"\n"))
    }

    // 変化が無ければ書き換えない (CHANGED_AT が動かないことで検証)
    func testStateWriteIsChangeOnly() {
        writer.writeState(.home, remoteIP: nil)
        now = now.addingTimeInterval(60)
        writer.writeState(.home, remoteIP: nil)
        XCTAssertTrue(read("state")!.contains("CHANGED_AT=\"2026-07-24 10:00:00\""))
        writer.writeState(.low, remoteIP: "100.99.1.2")
        XCTAssertTrue(read("state")!.contains("CHANGED_AT=\"2026-07-24 10:01:00\""))
    }

    func testLogFormat() {
        writer.log("-> LOW (manual)")
        writer.log("-> HIGH (restored)")
        XCTAssertEqual(read("watch.log"), """
        2026-07-24 10:00:00 -> LOW (manual)
        2026-07-24 10:00:00 -> HIGH (restored)

        """)
    }
}
```

- [ ] **Step 2: 失敗を確認**

Run: `make test`
Expected: FAIL（`cannot find 'ObservationWriter' in scope`）

- [ ] **Step 3: 実装（リネーム + 縮小）**

```bash
git mv Sources/AwayView/StateStore.swift Sources/AwayView/ObservationWriter.swift
```

`Sources/AwayView/ObservationWriter.swift` を全置換:

```swift
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
```

- [ ] **Step 4: 呼び出し側の暫定修正（コンパイルを通す）**

MenuController の本格統合は Task 5 で行う。このタスクでは MenuController を**一切変更せず**、ビルドを通すための暫定 shim を `ObservationWriter.swift` 末尾に置く（Task 5 Step 5 で削除する）:

```swift
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
```

- `Sources/AwayView/main.swift:78`: `SCREENSHARE_RES_STATE_DIR` → `AWAYVIEW_STATE_DIR`

- [ ] **Step 5: テストが通ることを確認**

Run: `make test`
Expected: 全 PASS（この時点でメニューのモード/解像度操作は shim で一時的に無効だが、テスト対象外。Task 5 で復活する）

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: StateStore を ObservationWriter (出力専用) に縮小、state dir を awayview へ"
```

---

### Task 5: 接続判定の汎用化と AppController 統合

**Files:**
- Modify: `Sources/AwayView/StateMachine.swift`（protocol `ConnectionObserving` の rename のみ）
- Modify: `Sources/AwayView/ConnectionMonitor.swift`
- Modify: `Sources/AwayView/MenuController.swift`（SettingsStore/ObservationWriter への本統合）
- Modify: `Sources/AwayView/ObservationWriter.swift`（Task 4 の暫定 shim を削除）
- Modify: `Sources/AwayView/main.swift`（--list-connections）
- Modify: `Sources/AwayView/Hooks.swift` + `Tests/AwayViewTests/HooksTests.swift`（パス変更・zsh 互換削除）
- Modify: `Tests/AwayViewTests/ConnectionMonitorTests.swift` `Tests/AwayViewTests/StateMachineTests.swift`

**Interfaces:**
- Consumes: `CIDRMatcher`（Task 2）、`SettingsStore`（Task 3）、`ObservationWriter`（Task 4）
- Produces: `protocol ConnectionObserving { func remoteIP() -> String? }`（旧 `tailscaleRemoteIP()`）。`ConnectionMonitor(localPort: UInt16, matcher: CIDRMatcher)`。`struct SettingsBackedConnection: ConnectionObserving`。`Hooks.hooksDir` 既定 = `~/.config/awayview/hooks`、`Hooks.configPath` と zsh 関数互換は削除

- [ ] **Step 1: StateMachine の protocol を rename**

`StateMachine.swift`:
- `protocol ConnectionObserving` のメソッドを `func tailscaleRemoteIP() -> String?` → `func remoteIP() -> String?` に（doc コメントも「監視ポートへ ESTABLISHED している設定 CIDR 内の接続元 IP (なければ nil)」に更新）
- `tick()` 内 `connection.tailscaleRemoteIP()` → `connection.remoteIP()`
- ファイル冒頭コメントの「zsh 版 bin/screenshare-res-watch.zsh」への言及は「(削除済みの) zsh 版 watcher」に変更

- [ ] **Step 2: ConnectionMonitor を CIDRMatcher ベースに全置換**

`Sources/AwayView/ConnectionMonitor.swift`:

```swift
import CShim
import Foundation

// 監視ポートへの ESTABLISHED 接続を sysctl (CShim 経由) から列挙する。
// netstat と同じ情報源なので root 不要で全プロセスのソケットが見える。

struct ConnectionMonitor: ConnectionObserving {
    let localPort: UInt16
    let matcher: CIDRMatcher

    init(localPort: UInt16 = SettingsStore.defaultPort,
         matcher: CIDRMatcher = CIDRMatcher(CIDRMatcher.defaultCIDRs)) {
        self.localPort = localPort
        self.matcher = matcher
    }

    func remoteIP() -> String? {
        establishedForeignIPs().first(where: matcher.matches)
    }

    /// local port が一致する ESTABLISHED 接続の foreign IP 一覧
    func establishedForeignIPs() -> [String] {
        var out = [CChar](repeating: 0, count: 16 * 1024)
        let n = css_list_established_foreign(localPort, &out, out.count)
        guard n > 0 else { return [] }
        return String(cString: out).split(separator: "\n").map(String.init)
    }
}

/// 毎 tick 現在の設定でモニタを組む (ポート・CIDR 変更を再起動なしで反映)
struct SettingsBackedConnection: ConnectionObserving {
    let settings: SettingsStore

    func remoteIP() -> String? {
        ConnectionMonitor(localPort: settings.port,
                          matcher: CIDRMatcher(settings.cidrs)).remoteIP()
    }
}
```

（`isTailscaleIP` 関数は削除 — CIDRMatcher が後継）

- [ ] **Step 3: テストを追従**

- `ConnectionMonitorTests.swift`: `TailscaleRangeTests` クラスを丸ごと削除（CIDRMatcherTests が後継）。`ConnectionMonitorSmokeTests` は無変更で残す
- `StateMachineTests.swift`: mock の `func tailscaleRemoteIP()` を `func remoteIP()` に改名（実装内容は変更なし。grep で 1 箇所）

- [ ] **Step 4: Hooks のパス変更と zsh 互換削除**

`Sources/AwayView/Hooks.swift` を全置換:

```swift
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
```

`Tests/AwayViewTests/HooksTests.swift` の setUp から `Hooks.configPath = ...` の行を削除（他は無変更で通る）。

- [ ] **Step 5: MenuController を SettingsStore + ObservationWriter に統合**

`Sources/AwayView/MenuController.swift` の変更点（クラス全体の構造は維持）:

```swift
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let writer: ObservationWriter
    private let settings: SettingsStore
    private let display: RealDisplayController
    private var machine: StateMachine!
    // statusItem / timer / currentState / currentIP / lastLogged は従来どおり

    init(stateDirectory: URL? = nil) {
        self.writer = stateDirectory.map { ObservationWriter(directory: $0) } ?? ObservationWriter()
        self.settings = SettingsStore()
        self.display = RealDisplayController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        display.log = { [writer] message in writer.log(message) }
        Hooks.log = { [writer] message in writer.log(message) }

        machine = StateMachine(
            connection: SettingsBackedConnection(settings: settings),
            display: display,
            flags: settings
        ) { [weak self] state, ip in
            self?.stateChanged(state, ip)
        }
        // 以降 (onLowApplied / statusItem / timer / writer.log("watcher started (native)")) は
        // 従来コードのまま。store → writer の置換のみ
    }
    ...
}
```

機械的な置換（全メソッド共通）:
- `store.log(...)` → `writer.log(...)`、`store.writeState(...)` → `writer.writeState(...)`
- `store.currentMode` → `settings.currentMode`、`store.setMode(...)` → `settings.setMode(...)`
- `store.resHigh / store.resLow / store.setResHigh / store.setResLow` → `settings.*`
- `openLog()` の `store.directory` → `writer.directory`
- `flagTimeSuffix(_ flag: String)`（ファイル mtime 依存）を削除し、以下に置換:

```swift
    private func modeTimeSuffix() -> String {
        guard let date = settings.modeChangedAt else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return " (\(f.string(from: date))〜)"
    }
```

`stateLabel()` 内の `\(flagTimeSuffix("force_low"))` / `\(flagTimeSuffix("override"))` はどちらも `\(modeTimeSuffix())` に。

最後に `ObservationWriter.swift` 末尾の暫定 shim（`typealias StateStore` と `extension ObservationWriter: FlagReading`）を削除。

- [ ] **Step 6: main.swift の --list-connections を設定対応に**

`main.swift` の該当ブロックを置換:

```swift
if args.contains("--list-connections") {
    let settings = SettingsStore()
    let monitor = ConnectionMonitor(localPort: settings.port,
                                    matcher: CIDRMatcher(settings.cidrs))
    let ips = monitor.establishedForeignIPs()
    print("port \(settings.port) ESTABLISHED foreign IPs: \(ips.isEmpty ? "(none)" : ips.joined(separator: ", "))")
    print("matched remote: \(monitor.remoteIP() ?? "(none)")")
    exit(0)
}
```

- [ ] **Step 7: ビルド・全テスト**

Run: `make check && make test`
Expected: 全 PASS（StateMachineTests は remoteIP 改名後のロジック回帰を担保）

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: 接続判定を設定 (ポート/CIDR) ベースに汎用化、hooks を ~/.config/awayview へ"
```

---

### Task 6: i18n 基盤 + メニューのローカライズ

**Files:**
- Modify: `Package.swift`（defaultLocalization + resources）
- Create: `Sources/AwayView/Localization.swift`
- Create: `Sources/AwayView/Resources/en.lproj/Localizable.strings`
- Create: `Sources/AwayView/Resources/ja.lproj/Localizable.strings`
- Modify: `Sources/AwayView/MenuController.swift`（表示文字列を L() に置換）
- Modify: `Info.plist`（CFBundleDevelopmentRegion / CFBundleLocalizations）

**Interfaces:**
- Produces: `func L(_ key: String) -> String` / `func L(_ key: String, _ args: CVarArg...) -> String`（`Bundle.module` 経由）。以後の UI 文字列はすべて L() を通す

- [ ] **Step 1: Package.swift に localization とリソースを追加**

`.executableTarget(name: "AwayView", ...)` を以下に変更し、`Package(name: "AwayView",` の直後に `defaultLocalization: "en",` を追加:

```swift
let package = Package(
    name: "AwayView",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    ...
        .executableTarget(
            name: "AwayView",
            dependencies: ["CShim"],
            path: "Sources/AwayView",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("ColorSync"),
                .linkedFramework("AppKit"),
            ]
        ),
    ...
```

- [ ] **Step 2: L() ヘルパー**

`Sources/AwayView/Localization.swift`:

```swift
import Foundation

func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .module, comment: "")
}

func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
```

- [ ] **Step 3: strings ファイル（en）**

`Sources/AwayView/Resources/en.lproj/Localizable.strings`:

```c
/* menu */
"menu.no_display" = "⚠️ No target display found";
"menu.state" = "Status: %@";
"menu.connection" = "Connection: %@";
"menu.connection.none" = "none";
"mode.auto" = "Automatic";
"mode.high" = "High resolution (home)";
"mode.low" = "Low resolution (away)";
"state.home" = "Home resolution";
"state.low" = "Low resolution";
"state.low_manual" = "Pinned to low resolution%@";
"state.override" = "Pinned to high resolution%@";
"res.high.title" = "High res: %@";
"res.low.title" = "Low res: %@";
"res.high.default" = "Auto-learned%@";
"res.low.default" = "Default (half of home)";
"menu.open_log" = "Open Log";
"menu.settings" = "Settings…";
"menu.quit" = "Quit AwayView";
```

- [ ] **Step 4: strings ファイル（ja）**

`Sources/AwayView/Resources/ja.lproj/Localizable.strings`:

```c
/* menu */
"menu.no_display" = "⚠️ 対象ディスプレイが見つかりません";
"menu.state" = "状態: %@";
"menu.connection" = "接続: %@";
"menu.connection.none" = "なし";
"mode.auto" = "自動判定";
"mode.high" = "高解像度（自宅）";
"mode.low" = "低解像度（外出）";
"state.home" = "ホーム解像度";
"state.low" = "低解像度";
"state.low_manual" = "低解像度に固定中%@";
"state.override" = "高解像度に固定中%@";
"res.high.title" = "高解像度: %@";
"res.low.title" = "低解像度: %@";
"res.high.default" = "自動学習%@";
"res.low.default" = "既定（ホームの半分）";
"menu.open_log" = "ログを開く";
"menu.settings" = "設定…";
"menu.quit" = "終了";
```

（`menu.settings` / `menu.quit` は Task 7 のメニュー変更でも使う。`menu.quit` の ja は従来表記「終了」を維持）

- [ ] **Step 5: MenuController の文字列を置換**

`menuNeedsUpdate` / `stateLabel` / `resParent` 内のリテラルを対応キーで置換:

- `"⚠️ 対象ディスプレイが見つかりません"` → `L("menu.no_display")`
- `"状態: \(stateLabel())"` → `L("menu.state", stateLabel())`
- `"接続: \(currentIP ?? "なし")"` → `L("menu.connection", currentIP ?? L("menu.connection.none"))`
- `"自動判定"` → `L("mode.auto")`、`"高解像度（自宅）"` → `L("mode.high")`、`"低解像度（外出）"` → `L("mode.low")`
- stateLabel: `"ホーム解像度"` → `L("state.home")`、`"低解像度"` → `L("state.low")`、`"低解像度に固定中\(modeTimeSuffix())"` → `L("state.low_manual", modeTimeSuffix())`、`"高解像度に固定中\(modeTimeSuffix())"` → `L("state.override", modeTimeSuffix())`
- resParent: `"自動学習\(home)"` → `L("res.high.default", home)`、`"既定（ホームの半分）"` → `L("res.low.default")`、`"高解像度: \(...)"` → `L("res.high.title", selected ?? defaultLabel)`、`"低解像度: \(...)"` → `L("res.low.title", selected ?? defaultLabel)`
- `"ログを開く"` → `L("menu.open_log")`、`"終了"` → `L("menu.quit")`
- `"ログイン時に起動"` はこのタスクでは据え置き（Task 7 で設定ウィンドウへ移動して消える）

- [ ] **Step 6: Info.plist にロケール宣言を追加**

`</dict>` の直前に追加:

```xml
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>ja</string>
	</array>
```

- [ ] **Step 7: ビルド・テスト・手動確認**

Run: `make check && make test`
Expected: 全 PASS

Run: `make build && ls dist/AwayView.app/Contents/Resources/`
Expected: `AwayView_AwayView.bundle` が入っている（Task 1 の Makefile ガードが有効化）

手動: `open dist/AwayView.app` → メニューが日本語（システム言語 ja のため）。`pkill -x AwayView` で終了
（本番の ScreenshareRes.app と同時に動くのは数十秒だが、どちらも home 状態なら解像度は動かない。気になるなら先に ScreenshareRes.app を一時 pkill してもよい）

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: i18n 基盤 (Localizable.strings en/ja) とメニューのローカライズ"
```

---

### Task 7: 設定ウィンドウ（SwiftUI）

**Files:**
- Create: `Sources/AwayView/SettingsWindow.swift`
- Modify: `Sources/AwayView/MenuController.swift`（「設定…」追加・ログイン項目トグルをメニューから削除）
- Modify: `Sources/AwayView/Resources/{en,ja}.lproj/Localizable.strings`（settings.* キー追加）

**Interfaces:**
- Consumes: `SettingsStore`（Task 3）、`CIDRMatcher.parseCIDR`（Task 2）、`L()`（Task 6）
- Produces: `final class SettingsWindowController { init(settings: SettingsStore, onChange: @escaping () -> Void); func show() }`

- [ ] **Step 1: strings に settings.* を追加**

en に追加:

```c
/* settings */
"settings.title" = "AwayView Settings";
"settings.port" = "Port to watch:";
"settings.cidrs" = "Remote IP ranges (CIDR, one per line):";
"settings.cidrs.note" = "Empty list disables automatic switching. Default is the Tailscale range.";
"settings.launch_at_login" = "Launch at login";
"settings.save" = "Save";
"settings.saved" = "Saved. Applies within a few seconds.";
"settings.error.port" = "Port must be an integer between 1 and 65535.";
"settings.error.cidr" = "Invalid CIDR: %@";
```

ja に追加:

```c
/* settings */
"settings.title" = "AwayView 設定";
"settings.port" = "監視ポート:";
"settings.cidrs" = "検知する接続元 IP 範囲（CIDR・1 行 1 件）:";
"settings.cidrs.note" = "空にすると自動切替は無効。既定は Tailscale の範囲。";
"settings.launch_at_login" = "ログイン時に起動";
"settings.save" = "保存";
"settings.saved" = "保存しました。数秒以内に反映されます。";
"settings.error.port" = "ポートは 1〜65535 の整数で入力してください。";
"settings.error.cidr" = "不正な CIDR: %@";
```

- [ ] **Step 2: SettingsWindow.swift を作成**

```swift
import AppKit
import ServiceManagement
import SwiftUI

// 設定ウィンドウ: SwiftUI Form を NSWindow にホスト。バリデーションは保存時。
// ポート/CIDR は SettingsStore へ書くだけで、次 tick から効く (再起動不要)。
final class SettingsWindowController {
    private let window: NSWindow

    init(settings: SettingsStore, onChange: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, onChange: onChange))
        window = NSWindow(contentViewController: hosting)
        window.title = L("settings.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)   // accessory アプリなので明示活性化
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let settings: SettingsStore
    let onChange: () -> Void

    @State private var portText: String
    @State private var cidrText: String
    @State private var launchAtLogin: Bool
    @State private var message: String?
    @State private var isError = false

    init(settings: SettingsStore, onChange: @escaping () -> Void) {
        self.settings = settings
        self.onChange = onChange
        _portText = State(initialValue: String(settings.port))
        _cidrText = State(initialValue: settings.cidrs.joined(separator: "\n"))
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("settings.port"))
                TextField("5900", text: $portText)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(L("settings.cidrs"))
                TextEditor(text: $cidrText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 72)
                    .border(Color.secondary.opacity(0.3))
                Text(L("settings.cidrs.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle(L("settings.launch_at_login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        message = error.localizedDescription
                        isError = true
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }

            HStack {
                if let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(isError ? Color.red : Color.secondary)
                }
                Spacer()
                Button(L("settings.save")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        guard let p = Int(portText), (1...65535).contains(p) else {
            message = L("settings.error.port")
            isError = true
            return
        }
        let lines = cidrText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines where CIDRMatcher.parseCIDR(line) == nil {
            message = L("settings.error.cidr", line)
            isError = true
            return
        }
        settings.port = UInt16(p)
        settings.cidrs = lines
        message = L("settings.saved")
        isError = false
        onChange()
    }
}
```

- [ ] **Step 3: メニューに「設定…」を追加し、ログイン項目トグルを撤去**

`MenuController.swift`:
- プロパティ追加: `private var settingsWindow: SettingsWindowController?`
- `menuNeedsUpdate` の「ログを開く」の後の `login` アイテム（`toggleLoginItem` ごと）を削除し、代わりに:

```swift
        let settingsItem = NSMenuItem(title: L("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
```

- アクション追加（`toggleLoginItem` メソッドは削除）:

```swift
    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings) { [weak self] in self?.tick() }
        }
        settingsWindow?.show()
    }
```

- `import ServiceManagement` は MenuController から削除可（SettingsWindow.swift 側に移った）

- [ ] **Step 4: ビルド・テスト・手動確認**

Run: `make check && make test`
Expected: 全 PASS

手動（`make build && open dist/AwayView.app`）:
1. メニュー →「設定…」でウィンドウが前面に出る
2. ポートに `abc` → 保存 → 赤エラー（ポート範囲メッセージ）
3. CIDR に `foo/8` 行を足す → 保存 → 赤エラー `不正な CIDR: foo/8`
4. CIDR を既定 2 行に戻しポート `5900` → 保存 →「保存しました」
5. `defaults read com.wadap.AwayView` に `Port` / `CIDRs` が入っている
6. 確認後 `pkill -x AwayView`、`defaults delete com.wadap.AwayView Port CIDRs`（自分の環境を既定に戻す）

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: 設定ウィンドウ (ポート / CIDR / ログイン時起動)"
```

---

### Task 8: README 英語化・README.ja・CLAUDE.md 更新

**Files:**
- Rewrite: `README.md`（英語）
- Create: `README.ja.md`
- Rewrite: `CLAUDE.md`

**Interfaces:**
- Consumes: ここまでの全確定仕様（名前・パス・設定キー・hooks 契約）

- [ ] **Step 1: README.md（英語）を全置換**

構成（この見出しと内容を含めること。文章は執筆者が整えてよいが事実は変えない）:

```markdown
# AwayView

Automatically lowers your Mac's display resolution while you're screen-sharing
into it from far away — and restores it the moment you disconnect.

The point is not bandwidth: on a small remote screen (an iPad on the road,
a laptop at a café), your desktop's native resolution renders text too small
to read. AwayView switches the Mac to a lower resolution so everything is
bigger, then switches back when you leave.

## How it works
- A menu bar app polls established TCP connections to a watched port
  (default 5900 = macOS Screen Sharing) via sysctl — no root, no shell-outs.
- If the peer address falls inside configured CIDR ranges
  (default: the Tailscale range 100.64.0.0/10 + fd7a:115c:a1e0::/48),
  the display switches to a low resolution after a short settle delay.
- On disconnect it restores the previous ("home") resolution, which is
  auto-learned and guarded against mis-learning during display sleep.

## Requirements
- macOS 13+ / Apple silicon or Intel
- Xcode toolchain to build from source (`swift build`)

## Install (from source)
    git clone https://github.com/wadap/awayview && cd awayview
    make install       # builds dist/AwayView.app, copies to ~/Applications, launches

## Menu bar
🏠 home / 💻 low / 📌 pinned high / ⚠️ no target display.
Modes: Automatic / High resolution (home) / Low resolution (away).
Resolution pickers for both high and low sides.

## Settings
Menu → Settings…: watched port, remote CIDR ranges (one per line; empty list
disables automatic switching), launch at login. Changes apply within seconds.

## Hooks
Executable files in `~/.config/awayview/hooks/on_low.d/` and `on_high.d/`
run (in name order) after each successful switch. Failures are logged and
never block the watcher.

## Observability
`~/.local/state/awayview/state` (current STATE/REMOTE_IP/CHANGED_AT) and
`~/.local/state/awayview/watch.log`.

## Uninstall
    make uninstall     # or quit from the menu and delete ~/Applications/AwayView.app
Disable "Launch at login" in Settings first if you enabled it.

## License
MIT
```

- [ ] **Step 2: README.ja.md を作成**

README.md と同じ構成の日本語版（見出し: 何をするか / 仕組み / 動作環境 / インストール / メニュー / 設定 / フック / 観測ファイル / アンインストール / ライセンス）。内容は README.md の対訳で、事実（パス・既定値・コマンド）は完全一致させる。README.md 冒頭に `[日本語](README.ja.md)`、README.ja.md 冒頭に `[English](README.md)` の相互リンクを置く。

- [ ] **Step 3: CLAUDE.md を全置換**

```markdown
# CLAUDE.md — AwayView

Claude Code 用のプロジェクト文脈。設計意図と落とし穴を先に把握してから触ること。

## 目的（1行）

外出先からリモート接続 (既定: Tailscale 経由の画面共有) したときだけ解像度を
下げ、切断で元に戻す。狙いは帯域削減ではなく「小画面で文字を大きく見る」こと。

## 構成

SwiftPM 単体 (Xcode プロジェクトなし)。`make build` が dist/AwayView.app を組む。

- `Sources/AwayView/StateMachine.swift` — 純粋ロジック (接続/表示/設定を
  protocol 越しに観測)。二段階 SETTLE・誤学習ガード・失敗時前進禁止
- `Sources/AwayView/ConnectionMonitor.swift` — sysctl (CShim) で ESTABLISHED
  列挙 + CIDRMatcher 判定。SettingsBackedConnection が毎 tick 設定を読む
- `Sources/AwayView/CIDRMatcher.swift` — CIDR リスト判定 (既定 Tailscale 範囲)
- `Sources/AwayView/SettingsStore.swift` — UserDefaults (suite
  com.wadap.AwayView)。Port/CIDRs/Mode/ResLow/ResHigh
- `Sources/AwayView/ObservationWriter.swift` — ~/.local/state/awayview/ に
  state + watch.log を出力 (書き込み専用・英語固定)
- `Sources/AwayView/DisplayController.swift` — CoreGraphics 直叩きの表示制御
  とホーム学習 (UserDefaults)
- `Sources/AwayView/MenuController.swift` — NSStatusItem メニュー
- `Sources/AwayView/SettingsWindow.swift` — SwiftUI 設定ウィンドウ
- `Sources/AwayView/Hooks.swift` — ~/.config/awayview/hooks/on_{low,high}.d/
- `Sources/CShim/` — XNU 非公開 ABI (pcblist_n) の C シム

## 設計上の要点（変更時に壊しやすい所）

- **CShim は XNU 非公開 ABI の写経**。構造体は `#pragma pack(4)` 必須・
  ブロックは 8 バイト境界に切り上げて歩く。どちらを欠いても静かに空振りする
  (実機で発生済み)。触らない
- **ホーム解像度の扱い順序が肝**。下げる直前にだけ capture (未キャッシュ時)、
  ホーム状態では毎 tick 追従。順序を崩すと「下げた状態をホームと誤学習」する
- **capture はディスプレイ active を検証してから**。スリープ/切断の瞬間を
  学習すると復帰時に画面が消える (実機で発生済み)
- **UserDefaults(suiteName:) は suite 名 = 自 bundle id のとき nil** を返す
  (.app 実行時)。`?? .standard` フォールバックを外さない
- 接続の一瞬の揺れで下げないため二段階 SETTLE (連続 2 tick で確定)
- hooks は適用**成功後**のみ発火。失敗しても watcher は止めない
- i18n は Localizable.strings (en/ja)。`L()` ヘルパー経由。watch.log は英語固定
- Makefile の .app 組み立てで `AwayView_AwayView.bundle` を
  Contents/Resources へコピーする。忘れるとローカライズが静かに落ちる

## 開発フロー

- `make check` (型チェック) → `make test` (XCTest。DEVELOPER_DIR は設定済み) →
  `make install`
- `swift test` を直接叩くときは
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` が必要
- ログ: `tail -f ~/.local/state/awayview/watch.log`。遷移は `-> LOW` / `-> HIGH`
- CLI 検証: `.build/release/AwayView --list-modes | --list-connections |
  --apply <WxH|default> | --restore | --capture-home`

## 経緯

zsh 版 watcher + SwiftBar プラグイン (screenshare-res) が前身。
Phase 1 (66a2360 以降) でクリーンブレークして native 一本化・AwayView に改名。
旧実装は git 履歴参照。配布 (署名/notarize/Homebrew) は Phase 2 で予定。
```

- [ ] **Step 4: リンク・事実の突き合わせ**

README.md / README.ja.md / CLAUDE.md の間で以下が完全一致することを確認:
パス（`~/.config/awayview/hooks/on_low.d` 等）、既定値（5900 / Tailscale 2 レンジ）、コマンド（`make install` 等）、メニューアイコン 4 種。

- [ ] **Step 5: Commit**

```bash
git add README.md README.ja.md CLAUDE.md
git commit -m "docs: README を英語化 (README.ja.md 併設)、CLAUDE.md を AwayView 構成に更新"
```

---

### Task 9: main ブランチへの統合

**Files:** なし（git 操作のみ）

- [ ] **Step 1: 全テスト最終確認**

Run: `make check && make test`
Expected: 全 PASS

- [ ] **Step 2: main へ merge**

```bash
git checkout main
git merge --no-ff phase1-awayview -m "merge: 公開アプリ化 Phase 1 — AwayView 汎用化"
```

- [ ] **Step 3: push（SSH agent 不調のため gh HTTPS 経由）**

```bash
git -c credential.helper='!gh auth git-credential' push https://github.com/wadap/screenshare-res.git main
git update-ref refs/remotes/origin/main $(git rev-parse HEAD)
```

Expected: push 成功

---

### Task 10: 実機移行（手動・このマシン）

**Files:** なし（運用作業。ユーザー立ち会いで実施）

- [ ] **Step 1: legacy 残骸の掃除（冪等）**

```bash
launchctl bootout gui/$(id -u)/com.wadap.screenshare-res 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.wadap.screenshare-res.plist
rm -f "$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null)/screenshare-res.5s.zsh" 2>/dev/null || true
```

- [ ] **Step 2: 旧 native 版を停止・削除して AwayView を導入**

```bash
pkill -x ScreenshareRes 2>/dev/null || true
rm -rf ~/Applications/ScreenshareRes.app
make install
```

Expected: メニューバーに 🏠 が出る（旧アイコンは消える）

- [ ] **Step 3: 旧 state・hooks の移行**

```bash
[ -d ~/.config/screenshare-res/hooks ] && mkdir -p ~/.config/awayview && \
  mv ~/.config/screenshare-res/hooks ~/.config/awayview/hooks
rm -rf ~/.local/state/screenshare-res
```

（config.zsh の on_low/on_high 関数を使っていた場合は hooks ディレクトリ形式
のスクリプトに手で移す — 現環境は 66a2360 で hooks ディレクトリ方式に移行済み）

- [ ] **Step 4: 動作確認**

```bash
tail -5 ~/.local/state/awayview/watch.log     # "watcher started (native)" が出る
cat ~/.local/state/awayview/state             # STATE="home"
.build/release/AwayView --list-connections    # port 5900 表示
```

- メニューから「設定…」を開き、既定値（5900 / Tailscale 2 レンジ）を確認
- 「ログイン時に起動」を ON（旧アプリの登録は削除済みなので入れ直し）
- モード「低解像度（外出）」→ 解像度が下がる → 「自動判定」→ 復帰する
- 実リモート検証（iPhone/iPad から Tailscale 経由で画面共有 → 💻 に変わり
  低解像度化 → 切断 → 🏠 復帰）は次に外出時 or 手元の別デバイスで実施

- [ ] **Step 5: steering の記録更新**

`.steering/20260725-public-app-phase1/tasklist.md` のチェックボックスを全て更新し、
実機移行で気づいたことがあれば `blockers.md` / `decisions.md` に記録して commit。
```
