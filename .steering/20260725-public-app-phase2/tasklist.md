# AwayView Phase 2（配布）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** AwayView を署名 + notarize 済みで public 配布し、Homebrew cask でインストール可能にする。

**Architecture:** コード品質修正 (Minor 4 件) → アイコン → `make release` パイプライン (ローカル完結) → repo リネーム & public 化 → GitHub Release v1.0.0 → 個人 tap の cask。spec は同ディレクトリの design.md / requirements.md / decisions.md。

**Tech Stack:** SwiftPM / Makefile / codesign + notarytool + stapler / gh CLI / librsvg + iconutil / Homebrew cask

## Global Constraints

- コマンドは `rtk` プレフィックスで実行（`rtk git status` 等。チェーン内も各コマンドに付ける）
- `swift test` 直叩きは `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 必須。`make test` は設定済み
- git push は SSH 不調のため `git -c credential.helper='!gh auth git-credential' push https://github.com/wadap/<repo>.git <branch>`。push 後 `git update-ref refs/remotes/origin/main $(git rev-parse HEAD)`
- このシェルは noclobber（既存ファイルへの `>` 禁止。Write ツールか `>|`）
- `pkill` / `rm -rf` は単機能コマンドに分割して実行（&&チェーンだと permission classifier がブロックしやすい）
- watch.log の文言は英語固定（i18n しない）
- Makefile の .app 組み立てで `AwayView_AwayView.bundle` のコピーは無条件（欠落時に build が fail するのが正）
- コミットは main 直（Phase 1 の steering コミットと同じ流儀）。メッセージ末尾に `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: CIDR パースの strict 化（`//` 拒否）

**Files:**
- Modify: `Sources/AwayView/CIDRMatcher.swift:23-29`
- Test: `Tests/AwayViewTests/CIDRMatcherTests.swift`

**Interfaces:**
- Produces: `CIDRMatcher.parseCIDR(_:) -> ([UInt8], Int)?` のシグネチャ不変。`"a//b"` / 末尾 `/` / 先頭 `/` で nil を返すようになる

現状バグ: `s.split(separator: "/")` は空要素を捨てるため `"100.64.0.0//10"` が `["100.64.0.0", "10"]` になり通ってしまう。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/AwayViewTests/CIDRMatcherTests.swift` の `testParseCIDRValidation()` 末尾に追記:

```swift
        XCTAssertNil(CIDRMatcher.parseCIDR("100.64.0.0//10"))   // 二重スラッシュ
        XCTAssertNil(CIDRMatcher.parseCIDR("100.64.0.0/10/"))   // 末尾スラッシュ
        XCTAssertNil(CIDRMatcher.parseCIDR("100.64.0.0/"))      // prefix 空
        XCTAssertNil(CIDRMatcher.parseCIDR("/10"))              // アドレス空
```

- [ ] **Step 2: 失敗を確認**

Run: `make test`
Expected: FAIL（`"100.64.0.0//10"` と `"100.64.0.0/10/"` の 2 行で assert 失敗。split が空要素を捨てるため両方とも count 2 になり通ってしまう。残り 2 つは現実装でも nil）

- [ ] **Step 3: 最小実装**

`CIDRMatcher.swift` の `parseCIDR` を差し替え:

```swift
    /// "100.64.0.0/10" → (ネットワークアドレス bytes, prefix 長)。不正なら nil
    static func parseCIDR(_ s: String) -> ([UInt8], Int)? {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]),
              let bytes = parseIP(String(parts[0])),
              (0...bytes.count * 8).contains(prefix) else { return nil }
        return (bytes, prefix)
    }
```

- [ ] **Step 4: green 確認**

Run: `make test`
Expected: 全テスト PASS（`Executed` 行で failures 0）

- [ ] **Step 5: Commit**

```bash
rtk git add Sources/AwayView/CIDRMatcher.swift Tests/AwayViewTests/CIDRMatcherTests.swift
rtk git commit -m "fix: CIDR パースを strict 化、// や空要素を拒否"
```

---

### Task 2: watch.log の LOW 文言を CIDR 設定非依存に

**Files:**
- Modify: `Sources/AwayView/MenuController.swift:64`
- Modify: 文言参照があれば `README.md` / `README.ja.md` / `CLAUDE.md`

**Interfaces:**
- Produces: watch.log の自動 LOW 遷移行は `-> LOW (remote connection)` になる（英語固定）

CIDR は設定で任意範囲に変えられるのに、ログが `Tailscale remote` 固定なのを直す。ログ出力は AppController 内でテスト対象外のため TDD なし（挙動変更はログ文字列のみ）。

- [ ] **Step 1: 文言変更**

`MenuController.swift:64`:

```swift
            case .low: writer.log("-> LOW (remote connection)")
```

- [ ] **Step 2: ドキュメント内の旧文言を洗い出して更新**

Run: `rtk grep -rn "Tailscale remote" --include="*.md" .`
`.steering/20260725-public-app-phase1/` 配下は歴史記録なので**変更しない**。README.md / README.ja.md / CLAUDE.md にヒットしたらその行だけ `-> LOW (remote connection)` に更新。

- [ ] **Step 3: 型チェック**

Run: `make check`
Expected: Build complete

- [ ] **Step 4: Commit**

```bash
rtk git add -A
rtk git commit -m "fix: watch.log の LOW 文言を CIDR 設定に依存しない表現へ"
```

---

### Task 3: メニューの「(HH:mm〜)」をローカライズ

**Files:**
- Modify: `Sources/AwayView/MenuController.swift:135-140`
- Modify: `Sources/AwayView/Resources/en.lproj/Localizable.strings`
- Modify: `Sources/AwayView/Resources/ja.lproj/Localizable.strings`

**Interfaces:**
- Produces: strings キー `state.time_suffix`（`%@` = HH:mm）。`state.low_manual` / `state.override` の `%@` に渡る文字列を生成

- [ ] **Step 1: strings に追加**

`en.lproj/Localizable.strings` の `"state.override"` 行の下に:

```
"state.time_suffix" = " (since %@)";
```

`ja.lproj/Localizable.strings` の同位置に:

```
"state.time_suffix" = " (%@〜)";
```

- [ ] **Step 2: ハードコードを置換**

`MenuController.swift` の `modeTimeSuffix()`:

```swift
    private func modeTimeSuffix() -> String {
        guard let date = settings.modeChangedAt else { return "" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return L("state.time_suffix", f.string(from: date))
    }
```

- [ ] **Step 3: 型チェック + 実機確認**

Run: `make check` → Expected: Build complete
Run: `make install` → メニューで「低解像度に固定」を選び、状態行が「低解像度に固定中 (HH:mm〜)」（ja）になること。System Settings で言語を一時変更しての en 確認は省略可（strings の書式検証は目視）

- [ ] **Step 4: Commit**

```bash
rtk git add Sources/AwayView/MenuController.swift Sources/AwayView/Resources
rtk git commit -m "fix: モード固定時刻のサフィックスをローカライズ"
```

---

### Task 4: 設定ウィンドウ UX（port trim / ウィンドウ位置記憶）

**Files:**
- Modify: `Sources/AwayView/SettingsWindow.swift`

**Interfaces:**
- Produces: 挙動変更のみ、公開シグネチャ不変

スコープ確定: (a) port 入力の前後空白を trim して受理し正規化表示、(b) `show()` が毎回 `center()` するのをやめ前回位置を記憶。「message 共有」は現実装（保存/ログイン項目エラーが同一 `message` 欄）が既に共有設計のため変更なし。

- [ ] **Step 1: port trim**

`save()` の先頭を変更:

```swift
    private func save() {
        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        guard let p = Int(trimmedPort), (1...65535).contains(p) else {
            message = L("settings.error.port")
            isError = true
            return
        }
```

保存成功パス（`settings.port = UInt16(p)` の直後）に正規化表示を追加:

```swift
        settings.port = UInt16(p)
        portText = String(p)
```

- [ ] **Step 2: ウィンドウ位置の記憶**

`SettingsWindowController` を変更:

```swift
    init(settings: SettingsStore, onChange: @escaping () -> Void) {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, onChange: onChange))
        window = NSWindow(contentViewController: hosting)
        window.title = L("settings.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("AwayViewSettings")
        if !window.setFrameUsingName("AwayViewSettings") {
            window.center()   // 初回のみ
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)   // accessory アプリなので明示活性化
        window.makeKeyAndOrderFront(nil)
    }
```

- [ ] **Step 3: 型チェック + 実機確認**

Run: `make check` → Expected: Build complete
Run: `make install` → 設定を開く→動かす→閉じる→再度開く: 位置が保持される。ポートに ` 5900 ` を入力して保存: 受理され表示が `5900` になる

- [ ] **Step 4: Commit**

```bash
rtk git add Sources/AwayView/SettingsWindow.swift
rtk git commit -m "fix: 設定ウィンドウの位置記憶とポート入力の trim"
```

---

### Task 5: アプリアイコン（SVG → .icns → 組み込み）

**Files:**
- Create: `assets/icon.svg`（マスター）
- Create: `assets/AppIcon.icns`（生成物もコミット）
- Modify: `Makefile`（`icon` ターゲット + build でのコピー）
- Modify: `Info.plist`（CFBundleIconFile）

**Interfaces:**
- Produces: `make icon` が assets/AppIcon.icns を再生成。`make build` が Contents/Resources/AppIcon.icns を含む .app を組む

- [ ] **Step 1: librsvg 確認**

Run: `command -v rsvg-convert || brew install librsvg`

- [ ] **Step 2: デザイン案の提示と選択（ユーザー対話）**

「外出先から自宅画面を覗く」モチーフで SVG 案を 2〜3 作成し（1024x1024 viewBox、macOS squircle 角丸 = 辺の約 22.5%）、各案を PNG プレビューしてユーザーに選んでもらう。選択案を `assets/icon.svg` として保存。
プレビュー生成（scratchpad ディレクトリで、案ごとに）: `rsvg-convert -w 256 -h 256 <scratchpad>/icon-a.svg -o <scratchpad>/icon-a.png` → Read ツールで表示して選択を仰ぐ

- [ ] **Step 3: Makefile に icon ターゲット追加**

```make
icon: ## assets/icon.svg から AppIcon.icns を生成 (要 librsvg)
	rm -rf dist/AppIcon.iconset
	mkdir -p dist/AppIcon.iconset
	for s in 16 32 128 256 512; do \
	  rsvg-convert -w $$s -h $$s assets/icon.svg -o dist/AppIcon.iconset/icon_$${s}x$${s}.png; \
	  rsvg-convert -w $$((s*2)) -h $$((s*2)) assets/icon.svg -o dist/AppIcon.iconset/icon_$${s}x$${s}@2x.png; \
	done
	iconutil -c icns dist/AppIcon.iconset -o assets/AppIcon.icns
	@echo "generated: assets/AppIcon.icns"
```

`.PHONY` 行に `icon` を追加。`build` ターゲットの `cp -R .build/release/AwayView_AwayView.bundle ...` の次の行に追加:

```make
	cp assets/AppIcon.icns $(APP)/Contents/Resources/
```

- [ ] **Step 4: Info.plist にアイコン宣言**

`CFBundlePackageType` の下に追加:

```xml
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
```

- [ ] **Step 5: 生成 + 実機確認**

Run: `make icon && make install`
Expected: Finder で ~/Applications/AwayView.app にアイコンが出る（Dock は LSUIElement のため出ない。Finder / Get Info で確認）

- [ ] **Step 6: Commit**

```bash
rtk git add assets Makefile Info.plist
rtk git commit -m "feat: アプリアイコンを追加 (SVG マスター + make icon で icns 生成)"
```

---

### Task 6: 署名の前提セットアップ（ユーザー操作ガイド）

**Files:** なし（Keychain / Apple Developer 側の操作）

**Interfaces:**
- Produces: `security find-identity -v -p codesigning` に `Developer ID Application: ... (TEAMID)` が出る。notarytool の keychain プロファイル `awayview-notary`

現状 identity 0 件（2026-07-25 確認）。**両方ユーザー操作**なので、コマンドを提示して完了を待つ。

- [ ] **Step 1: Developer ID Application 証明書の発行**

ユーザーに案内: Xcode → Settings → Accounts → (Apple ID 選択) → Manage Certificates… → 「+」→ **Developer ID Application**。
確認: `security find-identity -v -p codesigning` に `Developer ID Application: <名前> (<TEAMID>)` が 1 件出る。TEAMID を控える

- [ ] **Step 2: notarytool 認証プロファイル作成**

推奨は Apple ID + app-specific password（App Store Connect API キーより手順が短い）:
1. https://account.apple.com → Sign-In and Security → App-Specific Passwords で発行
2. `xcrun notarytool store-credentials awayview-notary --apple-id shuichi.wada@gmail.com --team-id <TEAMID>`（パスワードは対話入力。シェル履歴に残さない）

確認: `xcrun notarytool history --keychain-profile awayview-notary` がエラーなく返る（履歴 0 件で OK）

---

### Task 7: `make release` / `make publish` パイプライン

**Files:**
- Modify: `Makefile`

**Interfaces:**
- Consumes: Task 6 の identity / `awayview-notary` プロファイル
- Produces: `make release VERSION=x.y.z` → 署名 + notarize + staple 済み `dist/AwayView-x.y.z.zip`。`make publish VERSION=x.y.z` → GitHub Release 作成

- [ ] **Step 1: Makefile に変数とターゲット追加**

変数部（`APP_DST` の下）:

```make
SIGN_ID ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $$2; exit}')
NOTARY_PROFILE ?= awayview-notary
ZIP = dist/AwayView-$(VERSION).zip
```

ターゲット（`.PHONY` に `release publish` 追加）:

```make
release: ## 署名 + notarize + staple + 配布 zip (VERSION=x.y.z 必須)
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=1.0.0"; exit 1; }
	@test -n "$(SIGN_ID)" || { echo "error: Developer ID Application identity not found"; exit 1; }
	$(MAKE) test
	$(MAKE) build
	plutil -replace CFBundleShortVersionString -string "$(VERSION)" $(APP)/Contents/Info.plist
	plutil -replace CFBundleVersion -string "$(VERSION)" $(APP)/Contents/Info.plist
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	xcrun notarytool submit $(ZIP) --keychain-profile $(NOTARY_PROFILE) --wait --timeout 30m
	xcrun stapler staple $(APP)
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	spctl -a -vv --type execute $(APP)
	@echo "release artifact: $(ZIP)"

publish: ## GitHub Release 作成 (VERSION=x.y.z、release 実行後に)
	@test -n "$(VERSION)" || { echo "usage: make publish VERSION=1.0.0"; exit 1; }
	@test -f $(ZIP) || { echo "error: $(ZIP) not found. run make release first"; exit 1; }
	gh release create v$(VERSION) $(ZIP) --title "AwayView v$(VERSION)" --generate-notes
```

補足: `build` の ad-hoc 署名は `codesign --force` で上書きされるため開発フローと共存できる。リソースバンドルは実行コードを含まないため個別署名不要。

- [ ] **Step 2: dry run（publish 以外）**

Run: `make release VERSION=1.0.0`
Expected: notarytool が `status: Accepted`、stapler が `The staple and validate action worked!`、spctl が `accepted` + `source=Notarized Developer ID`。
失敗時: `xcrun notarytool log <submission-id> --keychain-profile awayview-notary` で理由確認（hardened runtime 由来の欠落 entitlement など）

- [ ] **Step 3: hardened runtime 実機スモーク**

```bash
dist/AwayView.app/Contents/MacOS/AwayView --list-modes
dist/AwayView.app/Contents/MacOS/AwayView --list-connections
```
Expected: モード列挙と接続列挙が動く（sysctl pcblist_n が hardened runtime 下でも動作することの確認）。
さらに `cp -R` で ~/Applications に入れ替えて（`make install` は ad-hoc 再署名してしまうので使わない: `pkill -x AwayView` → `rm -rf ~/Applications/AwayView.app` → `cp -R dist/AwayView.app ~/Applications/` → `open ~/Applications/AwayView.app`）メニューから低解像度適用 → 自動判定に戻す、が動くこと

- [ ] **Step 4: Commit**

```bash
rtk git add Makefile
rtk git commit -m "build: make release/publish を追加 (Developer ID 署名 + notarize + staple)"
```

---

### Task 8: repo リネーム & public 化

**Files:**
- Modify: `README.md` / `README.ja.md`（URL・インストール手順）
- Modify: `CLAUDE.md`（経緯 section の repo 名）

**Interfaces:**
- Consumes: Task 7 の notarize 成功（成功前に public 化しない）
- Produces: `https://github.com/wadap/awayview`（public）。origin は HTTPS URL

- [ ] **Step 1: 秘密情報の全履歴スキャン**

```bash
rtk git log -p --all | grep -inE "api[_-]?key|secret|token|password|BEGIN.*PRIVATE KEY" | head -30
```
Expected: 実害のあるヒットなし（変数名や doc 内の一般語のみ）。疑わしいヒットは user に提示して判断を仰ぐ。**実 secret が見つかったら public 化を中断**

- [ ] **Step 2: README 更新**

README.md / README.ja.md に Homebrew インストール手順を追加（Task 9 完了前提の文面で書いてよい。同一リリースサイクル内）:

```markdown
## Install

    brew tap wadap/tap
    brew install --cask awayview

Or download the notarized app from [Releases](https://github.com/wadap/awayview/releases).
```

既存の `screenshare-res` URL 参照・`make install` 前提の手順を `awayview` に更新。CLAUDE.md の経緯 section に「Phase 2 で awayview に改名・public 化」を追記

- [ ] **Step 3: Commit（リネーム前に push まで済ませる）**

```bash
rtk git add README.md README.ja.md CLAUDE.md
rtk git commit -m "docs: awayview リネームと Homebrew インストール手順"
git -c credential.helper='!gh auth git-credential' push https://github.com/wadap/screenshare-res.git main
git update-ref refs/remotes/origin/main $(git rev-parse HEAD)
```

- [ ] **Step 4: リネーム + remote 更新 + public 化**

```bash
gh repo rename awayview -R wadap/screenshare-res --yes
git remote set-url origin https://github.com/wadap/awayview.git
gh repo edit wadap/awayview --visibility public --accept-visibility-change-consequences
gh repo view wadap/awayview --json visibility,name
```
Expected: `"visibility": "PUBLIC"`, `"name": "awayview"`。
ローカルの dir 名 `~/git/screenshare-res` は**このセッションでは変えない**（Claude の project memory / steering のパスキーが変わるため。変えたくなったら次セッション冒頭で）

---

### Task 9: GitHub Release v1.0.0

**Files:** なし（gh 操作のみ）

**Interfaces:**
- Consumes: Task 7 の `dist/AwayView-1.0.0.zip`（リネーム後も artifact はそのまま有効）
- Produces: `https://github.com/wadap/awayview/releases/tag/v1.0.0` と zip の sha256

- [ ] **Step 1: Release 作成**

Run: `make publish VERSION=1.0.0`
Expected: Release URL が出力される

- [ ] **Step 2: sha256 を控える**

Run: `shasum -a 256 dist/AwayView-1.0.0.zip`
出力の hash を Task 10 の cask に使う

---

### Task 10: Homebrew tap + cask

**Files:**
- Create: `~/git/homebrew-tap/Casks/awayview.rb`（別 repo）

**Interfaces:**
- Consumes: Task 9 の Release URL と sha256
- Produces: `brew tap wadap/tap && brew install --cask awayview` が通る

- [ ] **Step 1: tap repo 作成**

```bash
gh repo create homebrew-tap --public --clone ~/git/homebrew-tap
```

- [ ] **Step 2: cask 定義**

`~/git/homebrew-tap/Casks/awayview.rb`（`<SHA256>` は Task 9 の実値に置換）:

```ruby
cask "awayview" do
  version "1.0.0"
  sha256 "<SHA256>"

  url "https://github.com/wadap/awayview/releases/download/v#{version}/AwayView-#{version}.zip"
  name "AwayView"
  desc "Lower the display resolution while a remote screen-sharing session is active"
  homepage "https://github.com/wadap/awayview"

  depends_on macos: ">= :ventura"

  app "AwayView.app"

  zap trash: [
    "~/.config/awayview",
    "~/.local/state/awayview",
    "~/Library/Preferences/com.wadap.AwayView.plist",
  ]
end
```

- [ ] **Step 3: commit + push**

```bash
cd ~/git/homebrew-tap
rtk git add Casks/awayview.rb
rtk git commit -m "add awayview 1.0.0"
git -c credential.helper='!gh auth git-credential' push https://github.com/wadap/homebrew-tap.git main
```

- [ ] **Step 4: 手動設置分を撤去して brew でインストール（E2E）**

順に単独実行（複合コマンドにしない）:

```bash
pkill -x AwayView
```
```bash
rm -rf ~/Applications/AwayView.app
```
```bash
brew tap wadap/tap
brew install --cask awayview
open /Applications/AwayView.app
```
Expected: install が `🍺 awayview was successfully installed!`、メニューバーに 🏠 が出る

- [ ] **Step 5: E2E スモーク**

メニューから「低解像度に固定」→ 解像度が下がる → 「自動判定」→ 復帰。設定ウィンドウで「ログイン時に起動」を入れ直す（アプリパスが /Applications に変わったため SMAppService を再登録）。
Run: `tail -5 ~/.local/state/awayview/watch.log`
Expected: `-> LOW (manual)` と `-> HIGH (restored)` が記録されている

---

### Task 11: steering 締め

**Files:**
- Modify: `.steering/20260725-public-app-phase2/tasklist.md`（チェックボックス）
- Modify: `.steering/20260725-public-app-phase2/blockers.md`（解消済みを更新、残課題記載）
- Modify: `CLAUDE.md`（開発フローに `make release` / `make publish` / `make icon` を追記）

- [ ] **Step 1: blockers.md 更新**

証明書・notary プロファイルのセットアップ完了を反映。実リモート検証（Phase 1 持ち越し）が未達なら残す

- [ ] **Step 2: CLAUDE.md 開発フロー更新 + Commit**

```bash
rtk git add -A
rtk git commit -m "steering: Phase 2 完了を記録、CLAUDE.md にリリースフロー追記"
git -c credential.helper='!gh auth git-credential' push https://github.com/wadap/awayview.git main
git update-ref refs/remotes/origin/main $(git rev-parse HEAD)
```
