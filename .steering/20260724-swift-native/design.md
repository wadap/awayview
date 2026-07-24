# design — Swift ネイティブ化

## モジュール構成（native/Sources/ScreenshareRes/）

```
StateMachine.swift       純粋ロジック。プロトコル越しに環境を観測し Effect を返す
ConnectionMonitor.swift  sysctl net.inet.tcp.pcblist_n で 5900 ESTABLISHED を列挙
DisplayController.swift  CoreGraphics 直叩き（モード列挙 / 適用 / capture / UUID 識別）
StateStore.swift         既存ファイル契約 (state/override/force_low/res_high/res_low)
MenuController.swift     NSStatusItem + NSMenu（3 モードラジオ + 解像度サブメニュー）
Hooks.swift              config.zsh の on_low/on_high を zsh 経由で互換実行
App/main.swift           NSApplication 起動・タイマー・SMAppService
```

## StateMachine（テスト可能性の核）

- zsh 版メインループの意味論をそのまま移植。protocol
  `ConnectionObserving` / `DisplayControlling` / `FlagReading` をモック注入して
  XCTest でシナリオ検証（zsh 版 tests/watcher.test.zsh の 12 シナリオを移植）
- 保持する内部状態: `last (unknown|high|low)`, `appliedCommand`
- 遷移優先順位: override > force_low > リモート接続 > home（zsh 版と同一）
- ガード（zsh 版から移植）:
  - 下げる前の capture（未キャッシュ時のみ）→ SETTLE 後に接続再確認 → 適用
  - 適用/復帰失敗時: last・capture・state を進めず次 tick リトライ
  - ディスプレイ非アクティブ（スリープ/無効）中は capture しない
  - 適用中の res_low/res_high 変更は appliedCommand との差分で検出し即再適用

## ConnectionMonitor

- `sysctlbyname("net.inet.tcp.pcblist_n")` のバッファを xinpgen/xtcpcb_n 構造体で
  歩き、state==ESTABLISHED かつ local port 5900 の foreign address を返す
- Tailscale 判定（IPv4 100.64/10, IPv6 fd7a:115c:a1e0::/48）は pure function として
  切り出し単体テスト
- 注: プロセス所有者に関係なく全ソケットが見える（netstat と同じ情報源）。
  root 不要

## DisplayController

- 対象ディスプレイ: 初回は「外部 > 内蔵」優先で自動選出し、
  `CGDisplayCreateUUIDFromDisplayID` の UUID を UserDefaults に記憶
- モード列挙: `CGDisplayCopyAllDisplayModes` +
  `kCGDisplayShowDuplicateLowResolutionModes: true` で HiDPI(scaled) モードを含めて
  取得。ピッカーには「ポイント解像度 (width x height)」で重複排除して表示
- 適用: `CGBeginDisplayConfiguration` → `CGConfigureDisplayWithDisplayMode` →
  `CGCompleteDisplayConfiguration(.permanently)`
- 低解像度が未選択（res_low なし）のときの既定値: **ホーム解像度の半分
  （同アスペクト比・HiDPI 優先、一覧に無ければ最も近い下位モード）**。
  config.zsh の LOW_CMD が無いネイティブ版でも初回から自動判定が機能する
- capture（自動学習）: 現在の `CGDisplayCopyDisplayMode` を保持 +
  `CGDisplayIsActive/IsOnline/IsAsleep` を検証してから（誤学習ガード）
- **リスク**: HiDPI モード列挙が displayplacer と一致するかは Task 1 のスパイクで
  最初に実証する（--list-modes CLI フラグで res_options と突き合わせ）

## StateStore（ファイル契約維持）

- 既存フォーマットのまま読み書き:
  - `state`: STATE/REMOTE_IP/CHANGED_AT（値はダブルクォート、tmp+rename で原子的、
    変化時のみ）
  - `override` / `force_low`: フラグ（メニューから排他で touch/rm）
  - `res_high` / `res_low`: WxH のみ
- legacy（zsh 版 + SwiftBar）と相互運用可能。デバッグも従来どおり cat で可能
- home 自動学習のキャッシュはネイティブでは CGDisplayMode 参照を UserDefaults に
  保持（home.cmd は legacy 専用として触らない）

## MenuController

- NSStatusItem。メニュー構成・文言・アイコン（🏠/💻/📌/⚠️）は SwiftBar 版と同一
- モード 3 項目は state ではなくフラグから導出（override 優先）、NSMenuItem.state で ✓
- 解像度サブメニュー: DisplayController のモード列挙から生成（キャッシュ不要 —
  メニューを開いた時だけ構築）
- 追加: 「ログイン時に起動」トグル（SMAppService.mainApp）と「終了」

## タイマーと更新

- DispatchSourceTimer で 3 秒ごとに StateMachine.tick（zsh 版 POLL_INTERVAL 相当）
- SETTLE_DELAY(2s) は tick 内の再確認 sleep ではなく「次 tick で再確認する
  二段階遷移」として実装（UI スレッドをブロックしない）
- メニュー表示はファイル/内部状態から毎 tick 更新

## インストール / 切替（Makefile）

- `make native-build`: swift build -c release → `native/dist/ScreenshareRes.app` 組立
  （Info.plist: LSUIElement=true, CFBundleIdentifier=com.wadap.screenshare-res.native）
  → `codesign --force --sign -`
- `make native-install`: legacy を bootout・SwiftBar symlink 撤去 → .app を
  `~/Applications` へ → open で起動
- `make native-uninstall`: アプリ終了・ログイン項目解除・.app 削除
- `make install`（zsh 版）は従来どおり = 切戻し手段。README に相互切替手順を明記
- `make test` = 既存 zsh テスト + `swift test`

## エラー処理

- 表示 API の失敗・対象ディスプレイ消失（モニタ切断）→ ⚠️ アイコン + メニューに
  理由表示。tick は継続（復帰したら自動回復）
- フック失敗はログのみ（watcher 挙動に影響させない）
- ログ: 既存 `watch.log` に同フォーマットで追記（`-> LOW (...)` / `-> HIGH (...)`）

## テスト戦略

- `swift test`: StateMachine 全シナリオ（モック注入）+ Tailscale 判定 +
  StateStore の読み書き/原子性 + sysctl パーサ（実バッファで smoke）
- 実機: スパイク（Task 1）でモード列挙検証 → 最終タスクで手動マトリクス
  （リモート接続含む）
