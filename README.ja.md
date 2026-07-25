[English](README.md)

# AwayView

外出先から Mac に画面共有しているあいだだけディスプレイ解像度を自動で下げ、
切断した瞬間に元へ復帰するメニューバーアプリ。

狙いは帯域削減ではない。外出先の小さい画面（移動中の iPad、カフェのノート PC）
から見ると、デスクトップのネイティブ解像度は文字が小さすぎて読めない。
AwayView は Mac 側の解像度を下げて文字を大きくし、離れたら元に戻す。

## 仕組み
- メニューバーアプリが sysctl 経由で監視ポート（既定 5900 = macOS 画面共有）への
  ESTABLISHED な TCP 接続をポーリングする — root 不要・シェルアウト不要
- 接続元アドレスが設定済みの CIDR 範囲（既定: Tailscale の範囲
  `100.64.0.0/10` + `fd7a:115c:a1e0::/48`）に含まれる場合、短い settle delay の
  あと低解像度へ切り替える
- 切断時は以前の（＝「ホーム」）解像度へ復帰する。ホーム解像度は自動学習され、
  ディスプレイのスリープ中に誤学習しないようガードされている

## 動作環境
- macOS 13 以降 / Apple silicon・Intel いずれも可
- ソースからビルドするには Xcode toolchain（`swift build`）が必要

## インストール（ソースから）
    git clone https://github.com/wadap/awayview && cd awayview
    make install       # dist/AwayView.app をビルドし ~/Applications へコピー、起動

## メニュー
🏠 ホーム / 💻 低解像度 / 📌 高解像度に固定中 / ⚠️ 対象ディスプレイなし。
モード: 自動判定 / 高解像度（ホーム）/ 低解像度（外出）。
高解像度・低解像度それぞれに解像度選択メニューあり。

## 設定
メニュー → 設定…: 監視ポート、リモート CIDR 範囲（1 行 1 件。空リストで自動切替
を無効化）、ログイン時に起動。変更は数秒以内に反映される。

## フック
`~/.config/awayview/hooks/on_low.d/` と `on_high.d/` に置いた実行可能ファイルが、
切り替え成功のたびに名前順で実行される。失敗はログに記録されるだけで
watcher の動作は止めない。

## 観測ファイル
`~/.local/state/awayview/state`（現在の STATE/REMOTE_IP/CHANGED_AT）と
`~/.local/state/awayview/watch.log`。

## アンインストール
    make uninstall     # またはメニューから終了し ~/Applications/AwayView.app を削除
「ログイン時に起動」を有効にしていた場合は、先に設定でオフにすること。

## ライセンス
MIT
