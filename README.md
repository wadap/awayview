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
make uninstall    # 常駐解除（config/log は残す）
make check        # zsh 構文チェック
```

動作確認：別マシンから Tailscale 経由で画面共有 → 解像度が下がる → 切断で戻る。

## 仕組み

`bin/screenshare-res-watch.zsh` が `POLL_INTERVAL` 秒ごとに:

1. `lsof` で 5900 の ESTABLISHED 接続を取得、接続元 IP が `100.64.0.0/10` か判定
2. リモート接続あり → `LOW_CMD` を `displayplacer` で適用（初回は下げる直前に
   ホーム解像度をキャッシュ）
3. リモート接続なし → キャッシュしたホーム配置へ復帰し、以後もホーム配置を追従キャッシュ

## 制限・メモ

- Tailscale 判定は **IPv4 (`100.64.0.0/10`) のみ**。IPv6 (`fd7a:…`) で入る
  運用なら `is_tailscale_ip` を `tailscale whois` 判定に差し替える
- LaunchAgent は GUI ログインセッションで動くため、ホストは自分のユーザーで
  ログインしたまま常時起動である必要がある
- もし復帰解像度がおかしくなったら、自宅で `rm ~/.local/state/screenshare-res/home.cmd`
  してから通常状態に戻せば再学習する

## ロードマップ

- [ ] SwiftBar プラグイン化（メニューバー状態表示＋手動オーバーライド）
- [ ] ネイティブ Swift メニューバーアプリ（`lsof`/`displayplacer` 依存を
      CoreGraphics `CGDisplaySetDisplayMode` 等へ置換）
