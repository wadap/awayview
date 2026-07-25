# Blockers / 要確認 — 公開アプリ化 Phase 1

## 未検証（Phase 1 受け入れ条件の残り）

- **実リモートでの自動切替**: iPhone/iPad/ノート PC から Tailscale 経由で画面共有
  → 💻 + `-> LOW (Tailscale remote)` → 切断で 🏠 復帰、を実機で未確認
  （2026-07-25 の実機移行ではローカル動作のみ確認。次の外出時に watch.log で判定）

## Phase 2 への持ち越し

- **アプリアイコン未作成**（ユーザー指摘 2026-07-25）: .icns なし。配布前に必須
- Developer ID 署名 + notarize（Apple Developer Program 加入が前提、加入状況未確認）
- GitHub repo リネーム screenshare-res → awayview + public 化
- Homebrew cask / GitHub Releases
- 最終レビューの accept 済み Minor（見直し候補）: watch.log の `-> LOW (Tailscale remote)`
  文言が CIDR 設定と無関係に固定 / CIDR パースが `//` を許容 / メニューの
  「(HH:mm〜)」の `〜` が両ロケール共通 / 設定画面の細かな UX（port trim・
  message 共有・毎回 center）
