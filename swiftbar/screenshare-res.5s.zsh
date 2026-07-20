#!/bin/zsh
# <xbar.title>screenshare-res</xbar.title>
# <xbar.desc>Tailscale 画面共有の解像度自動切替: 状態表示とモード/解像度選択</xbar.desc>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# watcher が書く state を表示し、モード(自動/高/低)と解像度の選択を行う薄い UI。
# メニュークリックは自分自身をサブコマンド付きで呼ぶ:
#   $0 mode auto|high|low          … フラグ(override/force_low)を排他で切替
#   $0 res  high <WxH>|auto        … 高解像度の選択を保存 / 自動学習へ戻す
#   $0 res  low  <WxH>|config      … 低解像度の選択を保存 / config の LOW_CMD へ戻す
# SwiftBar なしでも直接実行して出力を確認できる。
set -u

LABEL="com.wadap.screenshare-res"
STATE_DIR="${SCREENSHARE_RES_STATE_DIR:-$HOME/.local/state/screenshare-res}"
STATE_FILE="$STATE_DIR/state"
OVERRIDE_FLAG="$STATE_DIR/override"
FORCE_LOW_FLAG="$STATE_DIR/force_low"
RES_LOW_FILE="$STATE_DIR/res_low"
RES_HIGH_FILE="$STATE_DIR/res_high"
RES_CACHE="$STATE_DIR/res_options"
HOME_CACHE="$STATE_DIR/home.cmd"
LOG="$STATE_DIR/watch.log"
LAUNCHCTL="${SCREENSHARE_RES_LAUNCHCTL:-/bin/launchctl}"
DISPLAYPLACER="${SCREENSHARE_RES_DISPLAYPLACER:-/opt/homebrew/bin/displayplacer}"
GUI="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SELF="${0:A}"

mkdir -p "$STATE_DIR"

# --- サブコマンド (メニュークリックから自分自身が呼ばれる) --------------
case "${1:-}" in
  mode)
    case "${2:-}" in
      auto) rm -f "$OVERRIDE_FLAG" "$FORCE_LOW_FLAG" ;;
      high) touch "$OVERRIDE_FLAG"; rm -f "$FORCE_LOW_FLAG" ;;
      low)  touch "$FORCE_LOW_FLAG"; rm -f "$OVERRIDE_FLAG" ;;
    esac
    exit 0 ;;
  res)
    case "${2:-}" in
      high) if [[ "${3:-}" == "auto" ]];   then rm -f "$RES_HIGH_FILE"; else print -r -- "${3:-}" >| "$RES_HIGH_FILE"; fi ;;
      low)  if [[ "${3:-}" == "config" ]]; then rm -f "$RES_LOW_FILE";  else print -r -- "${3:-}" >| "$RES_LOW_FILE";  fi ;;
    esac
    exit 0 ;;
esac

STATE="" REMOTE_IP="" CHANGED_AT=""
[[ -r "$STATE_FILE" ]] && source "$STATE_FILE"

menu_log() {
  [[ -f "$LOG" ]] && print -r -- "ログを開く | bash=/usr/bin/open param1=$LOG terminal=false"
}

# watcher 生存確認。死んでいればモード表示より警告を優先する
if ! "$LAUNCHCTL" print "$GUI/$LABEL" >/dev/null 2>&1; then
  print -r -- "⚠️"
  print -r -- "---"
  print -r -- "watcher が動いていません"
  if [[ -f "$PLIST" ]]; then
    print -r -- "watcher を起動 | bash=$LAUNCHCTL param1=bootstrap param2=$GUI param3=$PLIST terminal=false refresh=true"
  else
    print -r -- "未インストール: リポジトリで make install を実行してください"
  fi
  menu_log
  exit 0
fi

# --- 現在モード (フラグから導出。override 優先は watcher と同じ) --------
MODE="auto"
[[ -e "$FORCE_LOW_FLAG" ]] && MODE="low"
[[ -e "$OVERRIDE_FLAG" ]] && MODE="high"

check() { [[ "$MODE" == "$1" ]] && print -rn -- "checked=true " || true }
res_checked() { [[ "${2:-}" == "$1" ]] && print -rn -- "checked=true " || true }

res_high_sel=""; [[ -s "$RES_HIGH_FILE" ]] && res_high_sel="$(<"$RES_HIGH_FILE")"
res_low_sel="";  [[ -s "$RES_LOW_FILE" ]]  && res_low_sel="$(<"$RES_LOW_FILE")"

home_res=""
[[ -s "$HOME_CACHE" ]] && home_res="$(grep -Eo 'res:[0-9]+x[0-9]+' "$HOME_CACHE" | head -1 | sed 's/^res://')"

high_label="${res_high_sel:-自動学習${home_res:+ ($home_res)}}"
low_label="${res_low_sel:-config 設定}"

# 解像度一覧: displayplacer list は重いので 1 時間キャッシュ
res_options() {
  if [[ ! -s "$RES_CACHE" || -n "$(find "$RES_CACHE" -mmin +60 2>/dev/null)" ]]; then
    "$DISPLAYPLACER" list 2>/dev/null | grep -Eo 'res:[0-9]+x[0-9]+' | sed 's/^res://' \
      | sort -t x -k1,1nr -k2,2nr | uniq >| "$RES_CACHE" || true
  fi
  if [[ -s "$RES_CACHE" ]]; then cat "$RES_CACHE"; fi
}

case "$STATE" in
  low)        icon="📱"; label="低解像度" ;;
  low_manual) icon="📱"; label="低解像度に固定中" ;;
  override)   icon="📌"; label="高解像度に固定中" ;;
  home)       icon="🏠"; label="ホーム解像度" ;;
  *)          icon="⚠️"; label="状態不明 (state 未生成)" ;;
esac
if [[ "$STATE" == "override" && -e "$OVERRIDE_FLAG" ]]; then
  label="高解像度に固定中 ($(stat -f %Sm -t %H:%M "$OVERRIDE_FLAG")〜)"
elif [[ "$STATE" == "low_manual" && -e "$FORCE_LOW_FLAG" ]]; then
  label="低解像度に固定中 ($(stat -f %Sm -t %H:%M "$FORCE_LOW_FLAG")〜)"
fi

print -r -- "$icon"
print -r -- "---"
print -r -- "状態: $label"
print -r -- "接続: ${REMOTE_IP:-なし}"
print -r -- "---"
print -r -- "自動判定 | $(check auto)bash=$SELF param1=mode param2=auto terminal=false refresh=true"
print -r -- "高解像度（自宅） | $(check high)bash=$SELF param1=mode param2=high terminal=false refresh=true"
print -r -- "低解像度（外出） | $(check low)bash=$SELF param1=mode param2=low terminal=false refresh=true"
print -r -- "---"
print -r -- "高解像度: $high_label"
print -r -- "-- 自動学習 | $(res_checked "" "$res_high_sel")bash=$SELF param1=res param2=high param3=auto terminal=false refresh=true"
for r in ${(f)"$(res_options)"}; do
  print -r -- "-- $r | $(res_checked "$r" "$res_high_sel")bash=$SELF param1=res param2=high param3=$r terminal=false refresh=true"
done
print -r -- "低解像度: $low_label"
print -r -- "-- config 設定 (LOW_CMD) | $(res_checked "" "$res_low_sel")bash=$SELF param1=res param2=low param3=config terminal=false refresh=true"
for r in ${(f)"$(res_options)"}; do
  print -r -- "-- $r | $(res_checked "$r" "$res_low_sel")bash=$SELF param1=res param2=low param3=$r terminal=false refresh=true"
done
print -r -- "---"
menu_log
print -r -- "watcher を再起動 | bash=$LAUNCHCTL param1=kickstart param2=-k param3=$GUI/$LABEL terminal=false refresh=true"
