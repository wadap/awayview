# CLAUDE.md — AwayView

Claude Code 用のプロジェクト文脈。設計意図と落とし穴を先に把握してから触ること。

## 目的（1行）

外出先からリモート接続 (既定: Tailscale 経由の画面共有) したときだけ解像度を
下げ、切断で元に戻す。狙いは帯域削減ではなく「小画面で文字を大きく見る」こと。

## 構成

SwiftPM 単体 (Xcode プロジェクトなし)。`make build` が dist/AwayView.app を組む。

- `Sources/AwayView/StateMachine.swift` — 純粋ロジック (接続/表示/設定を
  protocol 越しに観測)。二段階 SETTLE・誤学習ガード・失敗時前進禁止・
  失敗時バックオフ (`RetryBackoff.swift`)
- `Sources/AwayView/SleepGate.swift` — スリープ中と復帰直後の猶予のあいだ
  tick を止める門 (純粋な値型。通知の購読は MenuController)
- `Sources/AwayView/ConnectionMonitor.swift` — sysctl (CShim) で ESTABLISHED
  列挙 + CIDRMatcher 判定。SettingsBackedConnection が毎 tick 設定を読む
- `Sources/AwayView/CIDRMatcher.swift` — CIDR リスト判定 (既定 Tailscale 範囲)
- `Sources/AwayView/SettingsStore.swift` — UserDefaults (suite
  com.wadap.AwayView)。Port/CIDRs/Mode/ResLow/ResHigh
- `Sources/AwayView/ObservationWriter.swift` — ~/.local/state/awayview/ に
  state + watch.log を出力 (書き込み専用・英語固定)
- `Sources/AwayView/DisplayController.swift` — CoreGraphics 直叩きの表示制御
  とホーム学習 (UserDefaults)。列挙と状態問い合わせは `DisplayEnvironment` で
  注入できる。失敗ログは `LogThrottle.swift` で間引く
- `Sources/AwayView/MenuController.swift` — NSStatusItem メニュー
- `Sources/AwayView/HotKey.swift` — Carbon のグローバルホットキー (当て直し ⌃⌥⌘R)
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
- **消灯中のディスプレイに構成変更を投げない**。`CGCompleteDisplayConfiguration`
  は約 10 秒ブロックして失敗し、毎 tick 繰り返すとメインスレッドが塞がる
  (実機で 9.5 時間・3,478 回発生済み)。止める層は 3 つ: SleepGate (tick ごと) →
  `readyTarget()` (適用を `.deferred` で返す) → RetryBackoff (本当の失敗の間引き)。
  `.deferred` は失敗ではないのでバックオフに積まない
- **保存済みターゲットが不在でも別のディスプレイへ切り替えない**。ホームは
  アプリで 1 つしか持たないので、切り替えると別のディスプレイに他人のホームを
  当てに行く。自動選出は UUID 未保存の初回だけ
- **テストのフェイク display ID は実在しえない値にする** (`0xDEAD_0001` など)。
  1 や 2 は実機の ID と衝突し、テストが本物の解像度を変える (発生済み)
- **当て直し (relink) は「同じポイント解像度でスケール違いのモードへ行って戻る」**。
  KVM 切り替え後の起床で、macOS は設定済みのつもりなのにパネルが黒いままになる
  ことがあり、蓋の開閉 (= 出力モードの再設定) で直る。構成変更を 1 回完了させる
  たびに WindowServer は `set digital mode` を出し直すので (実機で確認済み)、往復で
  同じ効果になる。このディスプレイは同一解像度のレート違いを公開しないので、
  リフレッシュレートの往復は使えない。往復は同期で終える (tick を挟むと迂回中を
  ホームと誤学習する)
- 接続の一瞬の揺れで下げないため二段階 SETTLE (連続 2 tick で確定)
- hooks は適用**成功後**のみ発火。失敗しても watcher は止めない
- i18n は Localizable.strings (en/ja)。`L()` ヘルパー経由。watch.log は英語固定
- Makefile の .app 組み立てで `AwayView_AwayView.bundle` を
  Contents/Resources へコピーする。忘れるとローカライズが静かに落ちる

## 開発フロー

- `make check` (型チェック) → `make test` (XCTest。DEVELOPER_DIR は設定済み) →
  `make install`
- リリース: `make release VERSION=x.y.z` (署名 + notarize + staple + zip) →
  push 後に `make publish VERSION=x.y.z` (GitHub Release)。アイコン再生成は
  `make icon` (要 librsvg)。cask は wadap/homebrew-tap の Casks/awayview.rb
  (version + sha256 を更新)
- `swift test` を直接叩くときは
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` が必要
- ログ: `tail -f ~/.local/state/awayview/watch.log`。遷移は `-> LOW` / `-> HIGH`、
  失敗は `!!`、停止・保留の出入りは `--` (`paused` / `resumed` /
  `display not ready` / `display ready`)
- CLI 検証: `.build/release/AwayView --list-modes | --list-connections |
  --apply <WxH|default> | --restore | --relink | --capture-home`

## 経緯

zsh 版 watcher + SwiftBar プラグイン (screenshare-res) が前身。
Phase 1 (66a2360 以降) でクリーンブレークして native 一本化・AwayView に改名。
旧実装は git 履歴参照。Phase 2 で repo を awayview に改名して public 化し、
署名 + notarize (`make release VERSION=x.y.z` → `make publish VERSION=x.y.z`)
と Homebrew cask (wadap/homebrew-tap) で配布。
