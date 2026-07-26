# Blockers / 要確認 — 公開アプリ化 Phase 2

## 解消済み (2026-07-26)

- ~~Developer ID Application 証明書~~: Xcode から発行済み
  (`Developer ID Application: NANICA, K.K. (45F858C28S)`)
- ~~notarytool 認証情報~~: app-specific password は 401 が解消せず、
  **App Store Connect API キー方式**で解決 (プロファイル `awayview-notary`、
  キーは `~/.private_keys/AuthKey_427TJ9K2H4.p8`)
- ~~hardened runtime での CG / sysctl 動作~~: 署名済みバイナリで
  `--list-modes` / `--list-connections` とも動作確認済み。entitlements 不要

## 未検証 (Phase 1 からの持ち越し)

- **実リモートでの自動切替**: Tailscale 経由の実接続で
  `-> LOW (remote connection)` が watch.log に出ることを次の外出時に確認
  (文言は Phase 2 で `Tailscale remote` から変更済みなので grep はこの新文言で)
