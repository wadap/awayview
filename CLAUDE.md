# CLAUDE.md — AwayView

Claude Code 用のプロジェクト文脈。設計意図と落とし穴を先に把握してから触ること。

## 目的（1行）

外出先からリモート接続 (既定: Tailscale 経由の画面共有) したときだけ解像度を
下げ、切断で元に戻す。狙いは帯域削減ではなく「小画面で文字を大きく見る」こと。

## 構成

SwiftPM 単体 (Xcode プロジェクトなし)。`make build` が dist/AwayView.app を組む。

- `Sources/AwayView/StateMachine.swift` — 純粋ロジック (接続/表示/設定を
  protocol 越しに観測)。二段階 SETTLE・誤学習ガード・失敗時前進禁止
- `Sources/AwayView/ConnectionMonitor.swift` — sysctl (CShim) で ESTABLISHED
  列挙 + CIDRMatcher 判定。SettingsBackedConnection が毎 tick 設定を読む
- `Sources/AwayView/CIDRMatcher.swift` — CIDR リスト判定 (既定 Tailscale 範囲)
- `Sources/AwayView/SettingsStore.swift` — UserDefaults (suite
  com.wadap.AwayView)。Port/CIDRs/Mode/ResLow/ResHigh
- `Sources/AwayView/ObservationWriter.swift` — ~/.local/state/awayview/ に
  state + watch.log を出力 (書き込み専用・英語固定)
- `Sources/AwayView/DisplayController.swift` — CoreGraphics 直叩きの表示制御
  とホーム学習 (UserDefaults)
- `Sources/AwayView/MenuController.swift` — NSStatusItem メニュー
- `Sources/AwayView/SettingsWindow.swift` — SwiftUI 設定ウィンドウ
- `Sources/AwayView/Hooks.swift` — ~/.config/awayview/hooks/on_{low,high}.d/
- `Sources/CShim/` — XNU 非公開 ABI (pcblist_n) の C シム

## 設計上の要点（変更時に壊しやすい所）

- **CShim は XNU 非公開 ABI の写経**。構造体は `#pragma pack(4)` 必須・
  ブロックは 8 バイト境界に切り上げて歩く。どちらを欠いても静かに空振りする
  (実機で発生済み)。触らない
- **ホーム解像度の扱い順序が肝**。下げる直前にだけ capture (未キャッシュ時)、
  ホーム状態では毎 tick 追従。順序を崩すと「下げた状態をホームと誤学習」する
- **capture はディスプレイ active を検証してから**。スリープ/切断の瞬間を
  学習すると復帰時に画面が消える (実機で発生済み)
- **UserDefaults(suiteName:) は suite 名 = 自 bundle id のとき nil** を返す
  (.app 実行時)。`?? .standard` フォールバックを外さない
- 接続の一瞬の揺れで下げないため二段階 SETTLE (連続 2 tick で確定)
- hooks は適用**成功後**のみ発火。失敗しても watcher は止めない
- i18n は Localizable.strings (en/ja)。`L()` ヘルパー経由。watch.log は英語固定
- Makefile の .app 組み立てで `AwayView_AwayView.bundle` を
  Contents/Resources へコピーする。忘れるとローカライズが静かに落ちる

## 開発フロー

- `make check` (型チェック) → `make test` (XCTest。DEVELOPER_DIR は設定済み) →
  `make install`
- `swift test` を直接叩くときは
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` が必要
- ログ: `tail -f ~/.local/state/awayview/watch.log`。遷移は `-> LOW` / `-> HIGH`
- CLI 検証: `.build/release/AwayView --list-modes | --list-connections |
  --apply <WxH|default> | --restore | --capture-home`

## 経緯

zsh 版 watcher + SwiftBar プラグイン (screenshare-res) が前身。
Phase 1 (66a2360 以降) でクリーンブレークして native 一本化・AwayView に改名。
旧実装は git 履歴参照。Phase 2 で repo を awayview に改名して public 化し、
署名 + notarize (`make release VERSION=x.y.z` → `make publish VERSION=x.y.z`)
と Homebrew cask (wadap/homebrew-tap) で配布。
