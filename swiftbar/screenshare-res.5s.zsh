#!/bin/zsh
# <xbar.title>screenshare-res</xbar.title>
# <xbar.desc>Tailscale 画面共有の解像度自動切替: 状態表示と手動固定</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisabled>true</swiftbar.hideDisabled>
#
# watcher が書く state を表示し、override フラグを touch/rm する薄い UI。
# SwiftBar なしでも直接実行して出力を確認できる。
set -u

LABEL="com.wadap.screenshare-res"
STATE_DIR="${SCREENSHARE_RES_STATE_DIR:-$HOME/.local/state/screenshare-res}"
STATE_FILE="$STATE_DIR/state"
OVERRIDE_FLAG="$STATE_DIR/override"
LOG="$STATE_DIR/watch.log"
LAUNCHCTL="${SCREENSHARE_RES_LAUNCHCTL:-/bin/launchctl}"
GUI="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

STATE="" REMOTE_IP="" CHANGED_AT=""
[[ -r "$STATE_FILE" ]] && source "$STATE_FILE"

menu_log() {
  [[ -f "$LOG" ]] && print -r -- "ログを開く | bash=/usr/bin/open param1=$LOG terminal=false"
}

# watcher 生存確認。死んでいれば固定表示より警告を優先する
if ! "$LAUNCHCTL" print "$GUI/$LABEL" >/dev/null 2>&1; then
  print -r -- "⚠️"
  print -r -- "---"
  print -r -- "watcher が動いていません"
  print -r -- "watcher を起動 | bash=$LAUNCHCTL param1=bootstrap param2=$GUI param3=$PLIST terminal=false refresh=true"
  menu_log
  exit 0
fi

case "$STATE" in
  low)      icon="📱"; label="低解像度" ;;
  override) icon="📌"; label="高解像度に固定中" ;;
  home)     icon="🏠"; label="ホーム解像度" ;;
  *)        icon="⚠️"; label="状態不明 (state 未生成)" ;;
esac
if [[ "$STATE" == "override" && -e "$OVERRIDE_FLAG" ]]; then
  label="高解像度に固定中 ($(stat -f %Sm -t %H:%M "$OVERRIDE_FLAG")〜)"
fi

print -r -- "$icon"
print -r -- "---"
print -r -- "状態: $label"
print -r -- "接続: ${REMOTE_IP:-なし}"
print -r -- "---"
if [[ -e "$OVERRIDE_FLAG" ]]; then
  print -r -- "✅ 自動に戻す | bash=/bin/rm param1=-f param2=$OVERRIDE_FLAG terminal=false refresh=true"
else
  print -r -- "📌 高解像度に固定 | bash=/usr/bin/touch param1=$OVERRIDE_FLAG terminal=false refresh=true"
fi
print -r -- "---"
menu_log
print -r -- "watcher を再起動 | bash=$LAUNCHCTL param1=kickstart param2=-k param3=$GUI/$LABEL terminal=false refresh=true"
