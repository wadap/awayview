#!/bin/zsh
#
# screenshare-res-watch.zsh
#
# ポート5900へのESTABLISHED接続を監視し、接続元IPがTailscaleの範囲
# (100.64.0.0/10)なら「外出中のリモート」とみなして画面解像度を下げる。
# 接続が消えたら元(ホーム)の解像度へ自動復帰する。
#
#   - ローカルLANからの画面共有では下げない(接続元が100.64.0.0/10でない)
#   - ホーム解像度はホーム状態のとき自動キャッシュ→切断時に復帰
#
# 設定は $HOME/.config/screenshare-res/config.zsh から読む
# (SCREENSHARE_RES_CONFIG で上書き可)。config.example.zsh を参照。
#
set -u

CONFIG="${SCREENSHARE_RES_CONFIG:-$HOME/.config/screenshare-res/config.zsh}"
[[ -r "$CONFIG" ]] && source "$CONFIG"

# --- 設定(config.zsh で上書きされる) --------------------------------
: "${SCREEN_ID:?SCREEN_ID が未設定です。config.example.zsh を参照}"
: "${LOW_CMD:?LOW_CMD が未設定です。config.example.zsh を参照}"
: "${DISPLAYPLACER:=/opt/homebrew/bin/displayplacer}"
: "${LSOF:=/usr/sbin/lsof}"
: "${POLL_INTERVAL:=3}"
: "${SETTLE_DELAY:=2}"

STATE_DIR="$HOME/.local/state/screenshare-res"
HOME_CACHE="$STATE_DIR/home.cmd"
LOG="$STATE_DIR/watch.log"
mkdir -p "$STATE_DIR"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" }

# --- IPv4ドット表記の 100.64.0.0/10 判定 ------------------------------
is_tailscale_ip() {
  local ip="$1" o1 rest o2
  [[ "$ip" == <->.<->.<->.<-> ]] || return 1
  o1="${ip%%.*}"; rest="${ip#*.}"; o2="${rest%%.*}"
  [[ "$o1" == "100" ]] && (( o2 >= 64 && o2 <= 127 ))
}

# --- 5900へのESTABLISHED接続にTailscale元があるか ---------------------
remote_vnc_connected() {
  local name foreign fip
  local -a names
  names=("${(@f)$($LSOF -nP -iTCP:5900 -sTCP:ESTABLISHED -Fn 2>/dev/null | sed -n 's/^n//p')}")
  for name in $names; do
    [[ -z "$name" || "$name" != *'->'* ]] && continue
    foreign="${name##*->}"
    fip="${foreign%%:*}"
    is_tailscale_ip "$fip" && return 0
  done
  return 1
}

# --- 現在(=ホーム)の配置をdisplayplacerコマンド文字列として保存 -------
capture_home() {
  local cmd
  cmd="$($DISPLAYPLACER list 2>/dev/null \
        | awk '/^displayplacer /{sub(/^displayplacer /,""); print; exit}')"
  [[ -n "$cmd" ]] && print -r -- "$cmd" > "$HOME_CACHE"
}

apply_low() {
  eval "$DISPLAYPLACER \"$LOW_CMD\"" >> "$LOG" 2>&1 && log "-> LOW (Tailscale remote)"
}

restore_home() {
  [[ -s "$HOME_CACHE" ]] || { log "!! no home cache, skip restore"; return 1 }
  eval "$DISPLAYPLACER $(cat "$HOME_CACHE")" >> "$LOG" 2>&1 && log "-> HIGH (restored)"
}

log "watcher started (screen=$SCREEN_ID)"
local last="unknown"

while true; do
  if remote_vnc_connected; then
    if [[ "$last" != "low" ]]; then
      [[ -s "$HOME_CACHE" ]] || capture_home   # 下げる前=ホーム解像度を確保
      sleep $SETTLE_DELAY
      remote_vnc_connected && { apply_low; last="low" }
    fi
  else
    if [[ "$last" != "high" ]]; then
      restore_home
      last="high"
    fi
    capture_home
  fi
  sleep $POLL_INTERVAL
done
