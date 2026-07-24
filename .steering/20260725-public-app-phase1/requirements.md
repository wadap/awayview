# Requirements — 公開アプリ化 Phase 1（汎用化）

## 背景と目的

Swift ネイティブ版（メニューバーアプリ）は完成・本番稼働中。これを
**AwayView** という名前の公開アプリにする。Phase 1 は「自分専用の
ハードコードを外し、他人が使える形にする」まで。配布（署名・notarize・
GitHub Releases・Homebrew cask・repo public 化）は Phase 2。

## 名称

- アプリ名 / モジュール名: **AwayView**（旧 ScreenshareRes から改名。
  「Res」が用途を伝えないため。away = リモート接続がトリガーであることを
  名前に込めた。衝突なしは 2026-07-25 の web 検索で確認済み）
- bundle id: `com.wadap.AwayView`
- GitHub repo リネーム（screenshare-res → awayview）は Phase 2 の
  public 化時に実施。ローカル作業ディレクトリは当面そのまま

## スコープ（Phase 1 でやること）

1. **クリーンブレーク**: zsh 版 watcher（`bin/`）・SwiftBar プラグイン
   （`swiftbar/`）・`install.sh`・`config.example.zsh`・zsh テストを削除。
   `native/` の中身を repo 直下へ昇格（`Package.swift` がルート）
2. **監視ポートの設定化**: 既定 5900（macOS 画面共有）。1–65535 で変更可
3. **検知 IP 範囲の CIDR 設定化**: 既定 `100.64.0.0/10` +
   `fd7a:115c:a1e0::/48`（Tailscale）。v4/v6 混在リストを編集可
4. **設定ウィンドウ**（最小構成）: 監視ポート / CIDR リスト /
   ログイン時起動 の 3 項目のみ。解像度選択・モード固定は従来どおり
   メニューバーのメニューで行う
5. **日英 i18n**: システム言語追従。メニュー・設定ウィンドウが対象。
   watch.log の文言は英語固定（grep しやすさ優先）
6. **README 英語化**: `README.md`（英語）+ `README.ja.md`（日本語）

## スコープ外（Phase 2 以降 / やらない）

- Developer ID 署名・notarize・配布物作成（Phase 2。Apple Developer
  Program 加入が前提条件、加入状況未確認）
- App Store 配布（却下済み: sandbox で sysctl pcblist_n が読めない可能性大）
- 旧 screenshare-res パスからの自動 migration（旧ユーザーは自分の 1 台
  だけなので手動移行で十分）
- ポーリング間隔等の Advanced 設定 UI（YAGNI）

## 設定・状態の保存方式

- 設定（ポート / CIDR / res_high / res_low / モード固定）は
  **UserDefaults** に一本化
- **観測用ファイルは残す**: `~/.local/state/awayview/` に `state` と
  `watch.log` を出力専用で維持（hooks・デバッグ用）
- hooks は `~/.config/awayview/hooks/on_low.d|on_high.d/` の
  ディレクトリ方式のみ。config.zsh の on_low/on_high 関数サポートは廃止

## 受け入れ条件

- ポート・CIDR を設定ウィンドウで変更すると再起動なしで反映される
  （次 tick、3 秒以内）
- 初回起動（設定なし）で従来と同一の動作（5900 / Tailscale 範囲）
- システム言語 en/ja でメニュー・設定 UI が切り替わる
- `make test` が全緑、`make build` で AwayView.app が生成される
- 自宅マシンで実機切替（リモート接続 → 低解像度 → 切断 → 復帰）が
  従来どおり動く
