# Design — AwayView Phase 1（汎用化）

## repo 構成（クリーンブレーク後）

```
Package.swift                 # native/ から昇格
Sources/AwayView/             # 旧 Sources/ScreenshareRes/
Sources/AwayView/Resources/   # en.lproj/ ja.lproj (Localizable.strings)
                              # ※ Bundle.module に入れるため target 配下に置く
Sources/CShim/                # pcblist_n C シム（無変更）
Tests/AwayViewTests/
Info.plist
Makefile                      # native 系 target 中心に再編
README.md / README.ja.md
CLAUDE.md                     # 新構成に合わせ書き換え
.steering/
```

削除: `bin/` `swiftbar/` `tests/`(zsh) `install.sh` `config.example.zsh`
（git 履歴には残る）

## コンポーネント

### CIDRMatcher（新規）

- `isTailscaleIP` を置換。`[String]`（CIDR 表記, v4/v6 混在可）を受け、
  `inet_pton` でバイナリ化 + プレフィックス長ビット比較でマッチ
- 既定値: `["100.64.0.0/10", "fd7a:115c:a1e0::/48"]`
- パースは初期化時に 1 回。不正エントリは初期化時に弾く（設定 UI 側で
  保存前バリデーションするため、実行時に不正が来るのは手動で defaults を
  書き換えた場合のみ → 無視して有効エントリだけで動く）
- 空リスト = 何にもマッチしない = 自動切替オフ（許容。UI に注記）

### SettingsStore（新規, UserDefaults）

- キー: `port`(Int, 既定 5900) / `cidrs`([String], 既定 Tailscale) /
  `resHigh`(String?) / `resLow`(String?) / モード（auto/high/low）
- 既存 `FlagReading` protocol を実装（overrideHigh/forceLow/resLow/resHigh）
  → **StateMachine は無変更で流用**
- モード切替時刻も保存（現状メニューの「(HH:mm〜)」表示はフラグファイルの
  mtime 依存 → UserDefaults に切替時刻を持たせて維持）
- テスト用に suite 名を差し替え可能に（注意: suite 名が自 bundle id と
  同一だと nil になる既知問題あり — 916ecd8 の教訓）

### StateStore → ObservationWriter に縮小

- 書き込み専用: `state`（STATE/REMOTE_IP/CHANGED_AT、値ダブルクォート・
  tmp+rename・変化時のみ）と `watch.log`
- 場所: `~/.local/state/awayview/`。テスト用 env `AWAYVIEW_STATE_DIR`
- フラグ読み書き（override/force_low/res_*ファイル）は削除
  （SettingsStore へ移動）

### 設定ウィンドウ（新規）

- メニュー「設定…」→ `NSWindow` + `NSHostingController` で SwiftUI Form
- 項目: 監視ポート（整数, 1–65535）/ CIDR リスト（複数行編集）/
  ログイン時起動（SMAppService、メニューから移設 or 併存はメニュー簡素化
  のため設定ウィンドウへ移設）
- バリデーションは保存時。不正行はインラインエラーで保存拒否
- accessory アプリなのでウィンドウ表示時に `activate` を忘れない

### Hooks

- hooks ディレクトリ方式のみ: `~/.config/awayview/hooks/on_low.d|on_high.d/`
- `runZshFunction`（config.zsh の on_low/on_high）は削除
- 発火条件は現行のまま（applyLow / restoreHome の成功後のみ・非同期・
  失敗はログのみ）

### i18n

- `Package.swift` に `defaultLocalization: "en"`、
  `Resources/en.lproj|ja.lproj/Localizable.strings`
- `NSLocalizedString`（`Bundle.module`）でメニュー・設定 UI を置換
- Makefile の .app バンドル化で `Bundle.module` のリソースバンドルを
  `Contents/Resources/` へコピーする処理を追加（現状はバイナリのみコピー
  しているため、ここを忘れるとローカライズが静かに落ちる）
- watch.log は英語固定

## データフロー

毎 tick（3 秒, 現行どおり）:
`ConnectionMonitor(port: settings.port)` が sysctl 列挙 →
`CIDRMatcher(settings.cidrs)` でリモート判定 → StateMachine tick
（二段階 SETTLE・誤学習ガード・失敗時前進禁止、すべて無変更）

- メニュー / 設定ウィンドウの変更 → UserDefaults 書き込み → 即 `tick()`
- ポート・CIDR は毎 tick 読み直すので再起動不要（次 tick から反映）

## エラー処理

- CIDR / ポートは保存時バリデーション（§設定ウィンドウ）
- UserDefaults 未設定・型不一致は既定値フォールバック（初回起動 =
  従来同等動作）
- 表示系の既存ガード（enabled:false 検証・適用失敗時リトライ）は不変

## テスト

- 既存 XCTest はモジュール名変更のみで移植
- 新規: CIDRMatcherTests（v4/v6・境界 100.63.x / 100.128.x・プレフィックス
  境界・不正入力・空リスト）、SettingsStoreTests（既定値・round-trip・
  FlagReading 実装）
- StateStore のフラグ系テストは SettingsStore テストへ移動、
  ObservationWriter は state/log 出力のみテスト
- 実機切替検証は手動（このマシンが実稼働ホスト）

## リスク・注意

- `swift test` は `DEVELOPER_DIR=/Applications/Xcode.app/...` 必須
  （Makefile 設定済み）
- pcblist_n C シムは XNU 非公開 ABI（pack(4) + 8B 境界）— 触らない
- legacy zsh 版と native を同時に動かさない。**クリーンブレーク後の
  実機切替時は先に zsh 版 LaunchAgent を uninstall する**（手順は
  tasklist に含める）
- リネーム後の初回起動は旧 UserDefaults / 旧 state dir を読まないため
  「初回起動」扱いになる（ホーム再学習。想定どおりの挙動）
