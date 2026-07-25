# Design — 公開アプリ化 Phase 2（配布）

2026-07-25 ユーザー承認済み（§1〜§3 セクション毎に承認）。

## 作業順序

public 化を後半に置き、コード品質を先に固める:

1. Minor 見直し 4 件
2. アイコン
3. 署名 + notarize パイプライン（この直前に証明書発行のユーザー操作）
4. repo リネーム & public 化（notarize 検証が通った後）
5. GitHub Release v1.0.0
6. Homebrew tap + cask

## 1. Minor 見直し（Phase 1 blockers.md の 4 件）

| # | 対象 | 方針 |
|---|---|---|
| 1 | watch.log `-> LOW (Tailscale remote)` が CIDR 設定と無関係に固定 | CIDR 設定に依存しない `-> LOW (remote connection)` 系の文言へ。watch.log は英語固定の規約を維持 |
| 2 | CIDR パースが `//` を許容 | strict parse に修正 + ユニットテスト追加 |
| 3 | メニュー「(HH:mm〜)」の `〜` が両ロケール共通 | Localizable.strings へ移動（en は `-` 等） |
| 4 | 設定画面 UX | port 入力 trim / エラー message 共有 / ウィンドウ位置の記憶 |

## 2. アイコン

- マスター: `assets/icon.svg`（repo にコミット）
- 生成: `rsvg-convert`（librsvg、未導入なら brew install）→ 16〜1024px PNG
  → `iconutil` で `AppIcon.icns`。`make icon` ターゲット化
- **生成物 .icns もコミット**（ビルドに librsvg を要求しない）
- Info.plist に CFBundleIconFile、Makefile の .app 組み立てで
  Contents/Resources へコピー
- デザイン: 「外出先から自宅画面を覗く」モチーフで 2〜3 案の SVG を実物提示
  → ユーザー選択。macOS squircle ガイドライン準拠
- メニューバーは絵文字 (🏠/💻) 維持。.icns は Dock/Finder/About 用のみ

## 3. 署名 + notarize（`make release`）

```
make release VERSION=1.0.0
  → swift build -c release
  → .app 組み立て（CFBundleShortVersionString を VERSION で差し替え）
  → codesign --sign "Developer ID Application: ..." --options runtime --timestamp
  → ditto -c -k で zip → xcrun notarytool submit --wait
  → xcrun stapler staple → staple 後に配布用 zip を再作成
  → gh release create v$(VERSION) AwayView-$(VERSION).zip
```

- hardened runtime 必須（notarize 条件）。sandbox なし・特殊 entitlements
  なしの想定。**notarize 後に実機で解像度切替が動くことを検証**
  （hardened runtime による CG API / sysctl への影響がないことの確認）
- 既存 `make install`（ad-hoc 署名）は開発用に残し、`release` は別ターゲット
- 署名 identity は Makefile 変数（`SIGN_ID ?= Developer ID Application`
  で `security find-identity` から自動解決）

## 4. repo リネーム & public 化

- `gh repo rename awayview`（旧 URL リダイレクトは GitHub が維持）。
  local remote が HTTPS URL であることを確認（SSH agent 不調のため）
- public 化前チェック: git 全履歴の秘密情報 grep、README リンク/バッジ更新、
  既定値のユーザー固有値（bundle id `com.wadap.AwayView` 等）の妥当性確認
- リネーム/public 化は **notarize 検証成功後**（問題時に private のまま調査）

## 5. GitHub Release + Homebrew cask

- v1.0.0 始まり
- `wadap/homebrew-tap` 新規作成、`Casks/awayview.rb`:
  version / sha256 / url（Release zip）/ `app "AwayView.app"` /
  `zap trash:`（defaults suite com.wadap.AwayView、~/.local/state/awayview、
  ~/.config/awayview）
- 手動設置の `~/Applications/AwayView.app` は cask 検証時に brew 管理
  （/Applications）へ移行し二重起動を防ぐ

## 6. 検証

- `make check` / `make test` green 維持 + CIDR strict parse テスト追加
- 署名: `codesign --verify --deep --strict` + `spctl -a -vv` accepted
- E2E: brew install した .app で解像度切替の実機スモーク
  （StateMachine はテスト済み、表示制御のみ確認）

## リスク

- **hardened runtime での CG/sysctl 動作は未検証**。問題があれば entitlements
  追加を検討（notarize 検証をリネームより先に置くのはこのため）
- notarytool の審査時間は通常数分だが遅延することがある。`--wait` の
  タイムアウトを長めに設定
- 実リモート検証（Tailscale 経由の自動切替）は Phase 1 から未達のまま。
  Phase 2 と独立に、次の外出時に watch.log で確認する
