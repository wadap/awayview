# requirements — Swift ネイティブ化（ロードマップ②）

## 目的

zsh watcher + SwiftBar + displayplacer の構成を、**単一のネイティブ Swift
メニューバーアプリ**に置き換える。shell-out（netstat / displayplacer）を排し、
接続監視は sysctl、表示制御は CoreGraphics 直叩きにして外部依存をゼロにする。

## 決定済み要件

- **全部入り 1 アプリ**: メニューバー UI + watcher 機能（接続監視・解像度制御）を内蔵
- **ビルド**: SwiftPM + Makefile（`make native-build` / `make native-install`）。
  Xcode プロジェクトは作らない。ad-hoc 署名のローカル専用
- **zsh 版は legacy としてリポジトリに残す**。native-install が legacy watcher の
  bootout と SwiftBar symlink 撤去を行い、`make install` でいつでも戻れる
- **機能パリティ**（現行 zsh 版と同一挙動）:
  - Tailscale (IPv4 100.64.0.0/10 / IPv6 fd7a:115c:a1e0::/48) からの 5900 接続で自動低解像度化
  - 3 モード（自動判定 / 高解像度（自宅） / 低解像度（外出））のラジオメニュー
  - 解像度ピッカー（高: 自動学習が既定 / 低: 選択制）+ 適用中の変更は即再適用
  - アイコン: 🏠 / 💻 / 📌 / ⚠️（⚠️ は内部異常時）
  - SETTLE_DELAY 再確認・誤学習ガード（スリープ配置の capture 禁止 / 適用失敗時の
    capture・state 更新禁止とリトライ）
  - on_low / on_high フック（config.zsh に定義があれば zsh 経由で呼ぶ互換維持）
- **ファイル契約は維持**: `~/.local/state/screenshare-res/` の
  state / override / force_low / res_high / res_low を従来フォーマットで読み書き
- **config.zsh はネイティブ版では不要**: 対象ディスプレイは自動検出（UUID 記憶）、
  低解像度はメニュー選択、ホームは自動学習
- **常駐**: SMAppService によるログイン項目 + メニューに「ログイン時に起動」トグル

## スコープ外

- App Store / notarize 配布
- 複数ディスプレイの同時制御（対象は 1 枚。選択 UI は将来課題）
- zsh 版の削除（安定確認後に別途）

## 成功基準

1. `swift test` で StateMachine のシナリオテスト（zsh 版 12 シナリオ移植）が全通過
2. 実機で: リモート接続 → 自動 💻、切断 → 🏠 復帰、3 モード切替、解像度ピッカー、
   スリープ誤学習なし、が zsh 版と同等に動く
3. displayplacer / netstat / SwiftBar のどれが未インストールでも動作する
4. `make install`（zsh 版）⇄ `make native-install` の相互切替が安全にできる
