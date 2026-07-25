# Requirements — 公開アプリ化 Phase 2（配布）

## ゴール

AwayView を署名・notarize 済みの配布可能なアプリとして public 化し、
Homebrew cask でインストールできる状態にする。

## スコープ（6 項目すべて / 2026-07-25 ユーザー確定）

1. accept 済み Minor の見直し（Phase 1 blockers.md の 4 件）
2. アプリアイコン（SVG マスター → .icns。Claude がデザイン案を提示し選択）
3. Developer ID 署名 + notarize（`make release` 一気通貫、ローカル完結）
4. repo リネーム screenshare-res → awayview + public 化
5. GitHub Release v1.0.0
6. Homebrew tap（wadap/homebrew-tap）+ cask

## 前提条件

- Apple Developer Program: **加入済み**（2026-07-25 ユーザー確認）
- Developer ID Application 証明書: **未発行**（Keychain に codesigning
  identity 0 件を確認済み）。作業 3 の直前にユーザー操作で発行
- notarytool 認証情報: 未設定。`xcrun notarytool store-credentials` で
  Keychain プロファイル化（ユーザー操作）

## 受け入れ条件

- `make release VERSION=1.0.0` が署名〜notarize〜GitHub Release 作成まで完走
- `spctl -a -vv` が accepted（Gatekeeper 通過）
- `brew tap wadap/tap && brew install --cask awayview` でインストールでき、
  解像度切替の実機スモークが通る
- repo が awayview に改名され public、README リンク類が整合
- Minor 4 件が修正され `make check` / `make test` green

## スコープ外

- GitHub Actions によるリリース自動化（B 案は不採用 / decisions.md 参照）
- 本家 homebrew/cask への登録（notability 要件未達のため個人 tap）
- メニューバーの絵文字アイコン変更（現行 🏠/💻 を維持）
- 自動アップデート機構（Sparkle 等）
