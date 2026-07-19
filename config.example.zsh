# screenshare-res 設定サンプル
#
# これを $HOME/.config/screenshare-res/config.zsh にコピーして編集する。
# (install.sh install が未作成なら自動でコピーする)
#
# 対象ディスプレイの Persistent screen id は次で確認:
#   /opt/homebrew/bin/displayplacer list

# 必須 -----------------------------------------------------------------
SCREEN_ID="REPLACE_WITH_SCREEN_ID"

# 低解像度時の displayplacer 引数(1画面ぶん)。
#   scaling:on  … HiDPI(文字くっきり)。文字を大きく見たい用途向け。
#   scaling:off … 等倍。送るピクセルが素直に減るので帯域を一番軽くしたいとき。
LOW_CMD="id:${SCREEN_ID} res:1600x900 scaling:on origin:(0,0) degree:0"

# 任意(既定値を上書きしたいときだけ) ---------------------------------
# DISPLAYPLACER="/opt/homebrew/bin/displayplacer"
# LSOF="/usr/sbin/lsof"
# POLL_INTERVAL=3     # 監視間隔(秒)
# SETTLE_DELAY=2      # 接続検知後、適用までの落ち着き待ち(秒)
