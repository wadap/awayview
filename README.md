# screenshare-res

外出先から **Tailscale 経由で自宅 Mac に画面共有**したときだけ、ホスト側の
ディスプレイ解像度を自動で下げる（＝小さい画面で文字を大きく見る）。
接続が切れたら元の高解像度へ自動復帰する launchd 常駐スクリプト。

- ポート 5900 の ESTABLISHED 接続を監視し、**接続元 IP が Tailscale の
  範囲 `100.64.0.0/10`** のときだけ低解像度化する
- 同じ LAN からのローカル画面共有では下げない
- ホーム解像度はハードコードせず、ホーム状態のあいだ自動キャッシュ →
  切断時にそれへ復帰

## 必要なもの

- Apple Silicon Mac / macOS（ホストは常時起動＆自分のユーザーでログイン中）
- [`displayplacer`](https://github.com/jakehilborn/displayplacer)
  `brew install jakehilborn/jakehilborn/displayplacer`
- Tailscale（リモート接続経路）

## セットアップ

```sh
# 1) 設定を用意（初回 install が無ければ自動でコピーする）
cp config.example.zsh ~/.config/screenshare-res/config.zsh
$EDITOR ~/.config/screenshare-res/config.zsh   # SCREEN_ID と LOW_CMD を埋める

# SCREEN_ID は次で確認
/opt/homebrew/bin/displayplacer list

# 2) 自宅で・画面共有していない状態で install（ホーム解像度をキャッシュ）
make install      # = ./install.sh install
```

## 使い方

```sh
make status       # 稼働状況＋直近ログ
make logs         # watch.log を tail -f
make reload       # 設定変更後の再読み込み
make uninstall    # 常駐解除・SwiftBar symlink 削除（config/log は残す）
make check        # zsh 構文チェック
make test         # スタブによる自動テスト
```

動作確認：別マシンから Tailscale 経由で画面共有 → 解像度が下がる → 切断で戻る。

## 仕組み

`bin/screenshare-res-watch.zsh` が `POLL_INTERVAL` 秒ごとに:

1. `netstat` で 5900 の ESTABLISHED 接続を取得、接続元 IP が Tailscale 範囲か判定
   （`lsof` はユーザー権限だと root 所有の screensharingd のソケットが見えないため不可）
2. リモート接続あり → `LOW_CMD` を `displayplacer` で適用（初回は下げる直前に
   ホーム解像度をキャッシュ）
3. リモート接続なし → キャッシュしたホーム配置へ復帰し、以後もホーム配置を追従キャッシュ

## SwiftBar プラグイン（メニューバー表示と手動固定）

[SwiftBar](https://github.com/swiftbar/SwiftBar)（`brew install --cask swiftbar`）
を入れると、watcher の状態をメニューバーで確認できる:

- 🏠 ホーム解像度 / 💻 低解像度 / 📌 高解像度に固定中 / ⚠️ watcher 停止
- モードを 3 択から選択（✓ が現在モード。固定は手動で自動判定に戻すまで有効）:
  **自動判定 / 高解像度（自宅） / 低解像度（外出）**
- 高解像度・低解像度それぞれの解像度をサブメニューの一覧から選択できる。
  高解像度は「自動学習」（ホーム状態を追従キャッシュ）が既定、
  低解像度は config の `LOW_CMD` が既定。メニュー選択時は HiDPI (scaling:on) 固定
- ログを開く / watcher を再起動もメニューから

```sh
# SwiftBar を一度起動してプラグインフォルダを選んでから
make swiftbar     # プラグインを symlink 設置
```

仕組み: watcher が `~/.local/state/screenshare-res/state` に現在状態を書き、
プラグインはそれを表示するだけ。モードは同ディレクトリの `override`（高固定）/
`force_low`（低固定）フラグファイル、解像度選択は `res_high` / `res_low`
（WxH のみ）で、いずれもプラグインが書き watcher が毎ループ参照する。
優先順位は `override` > `force_low` > 自動判定、解像度は
`res_low` > `LOW_CMD`、`res_high` > ホーム自動学習。適用中の解像度変更は即再適用。

## モード遷移フック（自宅⇄モバイルで他アプリも切替）

config.zsh に `on_low()` / `on_high()` 関数を定義すると、低解像度への切替後 /
ホーム復帰後に呼ばれる（手動トグル・自動検知どちらの経路でも発火）。
例: モバイル利用中はスクロール反転（Scroll Reverser）を止める:

```zsh
on_low()  { osascript -e 'tell application "Scroll Reverser" to quit' }
on_high() { open -ga "Scroll Reverser" }
```

フックの失敗は watcher 本体の動作に影響しない（ログに `!! hook ... failed`）。

## 制限・メモ

- Tailscale 判定は **IPv4 (`100.64.0.0/10`) と IPv6 (`fd7a:115c:a1e0::/48`)**。
  それ以外の経路で入る運用なら `is_tailscale_ip` を `tailscale whois` 判定に
  差し替える
- LaunchAgent は GUI ログインセッションで動くため、ホストは自分のユーザーで
  ログインしたまま常時起動である必要がある
- もし復帰解像度がおかしくなったら、自宅で `rm ~/.local/state/screenshare-res/home.cmd`
  してから通常状態に戻せば再学習する

## ロードマップ

- [x] SwiftBar プラグイン化（メニューバー状態表示＋手動オーバーライド）
- [ ] ネイティブ Swift メニューバーアプリ（`netstat`/`displayplacer` 依存を
      CoreGraphics `CGDisplaySetDisplayMode` 等へ置換）
