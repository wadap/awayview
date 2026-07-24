# Swift ネイティブ化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development または superpowers:executing-plans。ただし本計画は CG API のスパイク（Task 1）の結果が後続の設計詳細に影響するため、タスクは「厳密なインターフェース + テスト仕様」で規定し、コードは要点のみ示す（greenfield の Swift アプリを計画に全文埋め込むより実装時の判断が正しくなるため）。

**Goal:** zsh watcher + SwiftBar + displayplacer を単一の Swift メニューバーアプリに置換（design.md 参照）。

**Architecture:** 純粋な StateMachine を protocol 境界（ConnectionObserving / DisplayControlling / FlagReading）で囲み、XCTest でシナリオ検証。UI は NSStatusItem。接続監視 sysctl、表示制御 CoreGraphics。

**Tech Stack:** Swift 5.9+ / SwiftPM / AppKit / CoreGraphics / XCTest（macOS 13+）

## Global Constraints

- ファイル契約（state/override/force_low/res_high/res_low）は zsh 版と完全互換。
  `state` は値をダブルクォートし tmp+rename で原子的に、変化時のみ書く
- メニュー構成・文言・アイコン（🏠/💻/📌/⚠️）は SwiftBar 版と同一
- ログは既存 `watch.log` に同フォーマット追記（`-> LOW (manual)` 等）
- 誤学習ガード 3 種（スリープ capture 禁止 / 適用失敗時の非前進 / 下げる直前 capture）を必ず移植
- 各タスク完了時に `make test`（zsh テスト + swift test）が通ること
- コミットは日本語 + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`

---

### Task 1: SwiftPM スケルトン + CG モード列挙スパイク

**Files:** Create `native/Package.swift`, `native/Sources/ScreenshareRes/main.swift`, `native/Sources/ScreenshareRes/DisplayController.swift`（列挙部のみ）

- [x] Package.swift: executable `ScreenshareRes`, platform .macOS(.v13)
- [x] `--list-modes` CLI フラグ: 全ディスプレイの UUID / 現在モードと、
  `CGDisplayCopyAllDisplayModes` + `kCGDisplayShowDuplicateLowResolutionModes: true`
  のポイント解像度一覧（width x height, isHiDPI, refreshRate）を stdout に出力
- [x] 実機で `swift run ScreenshareRes --list-modes` を実行し、legacy の
  `~/.local/state/screenshare-res/res_options`（41 モード）と突き合わせる。
  **ゲート: 1920x810 / 2560x1080 / 1600x1200 等の scaled モードが列挙に含まれること**。
  結果（一致/差分）を blockers.md に記録
- [x] コミット

### Task 2: StateMachine + シナリオテスト移植

**Files:** Create `native/Sources/ScreenshareRes/StateMachine.swift`, `native/Tests/ScreenshareResTests/StateMachineTests.swift`

**Interfaces（後続タスクが依存する契約）:**
```swift
protocol ConnectionObserving { func tailscaleRemoteIP() -> String? }
protocol DisplayControlling {
    func applyLow(_ resolution: String?) -> Bool     // nil なら既定 = ホームの半分(同アスペクト・HiDPI優先)
    func restoreHome(explicit resolution: String?) -> RestoreResult  // .ok/.failed/.noCache
    func captureHome() // ガード込み: 非アクティブ時は何もしない
    var isDisplayActive: Bool { get }
}
protocol FlagReading {
    var overrideHigh: Bool { get }
    var forceLow: Bool { get }
    var resLow: String? { get }
    var resHigh: String? { get }
}
enum WatchState: String { case home, low, lowManual = "low_manual", override }
final class StateMachine {
    init(connection: ConnectionObserving, display: DisplayControlling, flags: FlagReading,
         onStateChange: @escaping (WatchState, String?) -> Void)  // (state, remoteIP)
    func tick()
}
```
- [x] zsh 版 tests/watcher.test.zsh の 12 シナリオを XCTest に移植（モック注入で
  tick を進める。SETTLE は「二段階遷移」= 接続検知の次 tick で再確認）
- [x] 追加シナリオ: 二段階 SETTLE で「1 tick だけの瞬間接続では下げない」
- [x] RED → 実装 → GREEN → コミット

### Task 3: Tailscale 判定 + ConnectionMonitor (sysctl)

**Files:** Create `ConnectionMonitor.swift`, `Tests/.../TailscaleRangeTests.swift`

- [x] `isTailscaleIP(_:) -> Bool`（IPv4 100.64/10, IPv6 fd7a:115c:a1e0::/48）を
  pure function として実装 + 境界値テスト（100.63.x / 100.128.x / fd7a:115c:a1e1: 等）
- [x] sysctl `net.inet.tcp.pcblist_n` を歩いて ESTABLISHED × local:5900 の foreign IP を
  列挙（xinpgen ヘッダ→ xtcpcb_n。INP_IPV4/INP_IPV6 両対応）
- [x] smoke テスト: 実バッファでクラッシュせず配列を返す。実機で SSH 接続が
  5900 に現れない（port filter）ことを確認
- [x] コミット

### Task 4: StateStore（ファイル契約）

**Files:** Create `StateStore.swift`, `Tests/.../StateStoreTests.swift`

- [x] state 書き込み: `STATE="..."` 形式 3 行・原子的・変化時のみ（tmp dir でテスト:
  フォーマット完全一致を zsh 版出力と文字列比較）
- [x] フラグ/解像度ファイルの read/write（FlagReading 実装 + メニューからの排他切替
  `setMode(auto|high|low)` と `setRes(low:/high:)`）
- [x] watch.log への追記ロガー（既存フォーマット `YYYY-MM-DD HH:MM:SS msg`）
- [x] コミット

### Task 5: DisplayController 本実装 + 実機検証

**Files:** Modify `DisplayController.swift`

- [ ] 対象選出（外部優先→UUID を UserDefaults へ）・モード検索（WxH 文字列→
  CGDisplayMode、HiDPI 優先）・適用（CGBeginDisplayConfiguration→Complete）
- [ ] capture: CGDisplayCopyDisplayMode + `IsActive/IsOnline/!IsAsleep` ガード。
  home モードは UserDefaults に (UUID, WxH, isHiDPI) で永続化
- [ ] 実機検証スクリプト: `swift run ScreenshareRes --apply 1920x810` →
  `--restore` で往復し解像度が実際に変わることを確認（displayplacer list で裏取り）
- [ ] コミット

### Task 6: MenuController + App 組み立て

**Files:** Create `MenuController.swift`, `Hooks.swift`, main.swift を App 化

- [ ] NSStatusItem。SwiftBar 版と同一のメニュー構成（状態/接続表示、3 モードラジオ
  ✓、解像度サブメニュー〔高: 自動学習+一覧 / 低: 一覧〕、ログを開く、
  ログイン時に起動トグル〔SMAppService〕、終了）
- [ ] DispatchSourceTimer 3 秒 tick で StateMachine 駆動 + メニュー更新
- [ ] Hooks: config.zsh に on_low/on_high があれば
  `zsh -c 'source <config> && on_low'` を遷移成功後に非同期実行
- [ ] `swift run` で起動しメニュー操作の手動確認（モード切替がフラグファイルに
  反映され legacy SwiftBar 表示とも整合することを確認）
- [ ] コミット

### Task 7: .app バンドル + Makefile + ドキュメント

**Files:** Modify `Makefile`, `README.md`, `CLAUDE.md`; Create `native/Info.plist`

- [ ] `make native-build`: swift build -c release → `native/dist/ScreenshareRes.app`
  （Contents/MacOS/ + Info.plist: LSUIElement=true）→ `codesign --force --sign -`
- [ ] `make native-install`: legacy bootout + SwiftBar symlink 撤去 → ~/Applications
  へ cp → open。`make native-uninstall` も追加
- [ ] `make test` に `cd native && swift test` を追加
- [ ] README: ネイティブ版セクション（セットアップ・切替・切戻し手順）、
  CLAUDE.md: 構成・設計要点の更新
- [ ] コミット

### Task 8: 実機切替 + 手動テストマトリクス（要ユーザー協力）

- [ ] `make native-install` で切替（ユーザー確認後）
- [ ] マトリクス: 🏠 表示 / モード 3 切替 / 解像度ピッカー / リモート接続で自動 💻 /
  切断で 🏠 / スリープ後の復帰正常
- [ ] 結果を blockers.md / tasklist.md に記録し、progress ledger 更新、マージ判断
