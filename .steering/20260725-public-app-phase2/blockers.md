# Blockers / 要確認 — 公開アプリ化 Phase 2

## ユーザー操作が必要（該当タスク直前に案内）

- **Developer ID Application 証明書の発行**: Keychain に codesigning
  identity 0 件（2026-07-25 確認）。Xcode → Settings → Accounts →
  Manage Certificates から発行が最短
- **notarytool 認証情報**: `xcrun notarytool store-credentials` で
  App Store Connect API キー（推奨）か app-specific password を登録

## 未検証

- hardened runtime 有効時の CoreGraphics 表示制御 / sysctl(pcblist_n) 動作
- 実リモート自動切替（Phase 1 からの持ち越し。次の外出時に watch.log 確認）
