# CLAUDE.md — screenshare-res

Claude Code 用のプロジェクト文脈。設計意図と落とし穴を先に把握してから触ること。

## 目的（1行）

外出先から Tailscale 経由で自宅 Mac に画面共有したときだけ解像度を下げ、
切断で元に戻す。狙いは帯域削減ではなく「小画面で文字を大きく見る」こと。

## ファイル構成

- `bin/screenshare-res-watch.zsh` — 常駐 watcher 本体（ポーリング state machine）
- `config.example.zsh` — 設定サンプル。実体は `~/.config/screenshare-res/config.zsh`
- `install.sh` — `install|uninstall|reload|status|logs` サブコマンド。plist を生成し
  `launchctl bootstrap` する
- `Makefile` — install.sh への薄いフロントドア
- `swiftbar/screenshare-res.5s.zsh` — SwiftBar プラグイン（状態表示 + 手動固定 UI）
- `tests/*.test.zsh` — スタブ(netstat/displayplacer/launchctl)による自動テスト。`make test`
- 状態: `~/.local/state/screenshare-res/`（`home.cmd` キャッシュ、`watch.log`、
  `state` 現在状態、`override` 高解像度固定フラグ、`force_low` 低解像度固定フラグ）

## 設計上の要点（変更時に壊しやすい所）

- **シェルは zsh 固定**。macOS の `/bin/bash` は 3.2 で `mapfile` 等が無いため。
  `${(@f)...}`、`[[ $ip == <->.<->.<->.<-> ]]` など zsh 依存を使っている。
- **リモート判定 = 接続元 IP が `100.64.0.0/10` または `fd7a:115c:a1e0::/48`**。
  これでローカル画面共有 (192.168.x 等) と区別している。判定を緩めると
  ローカルでも下がるので注意。Tailscale はホスト名接続だと IPv6 を使うことが
  多く、IPv4 だけの判定だと検知漏れする（実機で発生済み）。
- **ホーム解像度の扱い順序が肝**。`last != low` かつ未キャッシュのときだけ、
  *下げる直前*に `capture_home` する。ホーム状態のあいだは毎ループ追従キャッシュ。
  この順序を崩すと「下げた状態をホームとして誤学習」する事故が起きる。
- `SETTLE_DELAY` 後に **接続を再確認してから** 適用（一瞬の接続で下げない）。
- `displayplacer` の `hz`/`color_depth` は指定しない方針（不一致で
  `could not find` になりやすいため）。
- LaunchAgent は **GUI セッション**必須（`launchctl bootstrap gui/$(id -u)`）。
  LaunchDaemon にすると displayplacer がユーザーの表示セッションを掴めない。
- **watcher ⇄ プラグインの契約はファイル 3 つ**。`state` は watcher だけが書く
  （値は必ずダブルクォート。source で読むため。値は home/low/low_manual/override）。
  `override`（高固定）と `force_low`（低固定）はプラグインだけが touch/rm する。
  優先順位は override > force_low > 自動判定。UI 上は排他（両立時は override 優先）。
  この契約は Swift ネイティブ化(ロードマップ②)でも維持する。
- テスト用に `SCREENSHARE_RES_STATE_DIR` / `SCREENSHARE_RES_LAUNCHCTL` で
  状態 dir と launchctl を差し替え可能（本番では未設定のまま）。
- **モード遷移フック**: config の `on_low()` / `on_high()` を `apply_low` /
  `restore_home` の*成功後*に呼ぶ（`run_hook`）。失敗しても watcher は止めない。
  復帰失敗時(rc=1)はフックも発火しない — 実際に解像度が変わったときだけ発火。

## 開発フロー

- 変更後は `make check`（`zsh -n`）で構文確認 → `make reload`。
- ログ追跡は `make logs`。状態遷移は `-> LOW` / `-> HIGH` 行で分かる。
- 実 config（`config.zsh`）と `~/.local/` は `.gitignore` 済み。マシン固有値や
  ログはコミットしない。

## 次にやりたいこと

1. SwiftBar プラグイン化：この判定ロジックを流用しつつメニューバーに状態表示、
   「今は高解像度に固定 / 自動に戻す」の手動オーバーライドを追加。
2. ネイティブ Swift メニューバーアプリ：`netstat` ポーリングと displayplacer への
   shell-out をやめ、接続監視＋ CoreGraphics 表示 API 直叩きへ。外部依存ゼロ化。

判定・適用ロジックは 1→2 でそのまま再利用できる設計にしてある。
