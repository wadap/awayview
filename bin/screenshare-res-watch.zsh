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
#   - $STATE_DIR/override が存在する間は接続中でもホーム解像度を維持
#     (SwiftBar プラグイン等の手動オーバーライド用)
#   - 現在状態は $STATE_DIR/state に書き出す(プラグインが source して読む)
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

STATE_DIR="${SCREENSHARE_RES_STATE_DIR:-$HOME/.local/state/screenshare-res}"
HOME_CACHE="$STATE_DIR/home.cmd"
LOG="$STATE_DIR/watch.log"
STATE_FILE="$STATE_DIR/state"
OVERRIDE_FLAG="$STATE_DIR/override"
FORCE_LOW_FLAG="$STATE_DIR/force_low"
mkdir -p "$STATE_DIR"

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" }

# --- Tailscale 範囲判定: IPv4 100.64.0.0/10 / IPv6 fd7a:115c:a1e0::/48 ---
is_tailscale_ip() {
  local ip="$1" o1 rest o2
  if [[ "$ip" == <->.<->.<->.<-> ]]; then
    o1="${ip%%.*}"; rest="${ip#*.}"; o2="${rest%%.*}"
    [[ "$o1" == "100" ]] && (( o2 >= 64 && o2 <= 127 ))
    return
  fi
  [[ "${(L)ip}" == fd7a:115c:a1e0:* ]]
}

# --- 5900へのESTABLISHED接続にTailscale元があるか ---------------------
# 見つけた接続元は REMOTE_IP に保存する(state ファイル表示用)
REMOTE_IP=""
remote_vnc_connected() {
  local name foreign fip
  local -a names
  REMOTE_IP=""
  names=("${(@f)$($LSOF -nP -iTCP:5900 -sTCP:ESTABLISHED -Fn 2>/dev/null | sed -n 's/^n//p')}")
  for name in $names; do
    [[ -z "$name" || "$name" != *'->'* ]] && continue
    foreign="${name##*->}"
    if [[ "$foreign" == \[* ]]; then
      fip="${${foreign#\[}%%\]*}"   # IPv6: [addr]:port 形式
    else
      fip="${foreign%%:*}"
    fi
    is_tailscale_ip "$fip" && { REMOTE_IP="$fip"; return 0 }
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
  local why="${1:-Tailscale remote}"
  eval "$DISPLAYPLACER \"$LOW_CMD\"" >> "$LOG" 2>&1 && log "-> LOW ($why)"
}

restore_home() {
  local why="${1:-restored}"
  [[ -s "$HOME_CACHE" ]] || { log "!! no home cache, skip restore"; return 2 }
  if eval "$DISPLAYPLACER $(cat "$HOME_CACHE")" >> "$LOG" 2>&1; then
    log "-> HIGH ($why)"
  else
    log "!! restore failed ($why), will retry"
    return 1
  fi
}

# --- state ファイル(プラグインが source して読む)。値は必ずクォート ---
LAST_STATE_BODY=""
write_state() {
  local st="$1" body
  body="STATE=\"$st\""$'\n'"REMOTE_IP=\"$REMOTE_IP\""
  [[ "$body" == "$LAST_STATE_BODY" ]] && return 0
  {
    print -r -- "$body"
    print -r -- "CHANGED_AT=\"$(date '+%Y-%m-%d %H:%M:%S')\""
  } > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
  LAST_STATE_BODY="$body"
}

log "watcher started (screen=$SCREEN_ID)"
local last="unknown"

while true; do
  if [[ -e "$OVERRIDE_FLAG" ]]; then
    # 手動オーバーライド: 接続の有無に関わらずホーム解像度を維持
    remote_vnc_connected || true   # REMOTE_IP を表示用に更新するだけ
    if [[ "$last" != "high" ]]; then
      restore_home override
      rc=$?
      # 適用失敗時は capture すると低解像度を誤学習するため、次ループで再試行
      if (( rc == 1 )); then sleep $POLL_INTERVAL; continue; fi
      last="high"
    fi
    capture_home
    write_state override
  elif [[ -e "$FORCE_LOW_FLAG" ]]; then
    # 手動の低解像度固定: 接続の有無に関わらず下げる
    remote_vnc_connected || true   # REMOTE_IP を表示用に更新するだけ
    if [[ "$last" != "low" ]]; then
      [[ -s "$HOME_CACHE" ]] || capture_home   # 下げる前=ホーム解像度を確保
      apply_low manual && last="low"
    fi
    [[ "$last" == "low" ]] && write_state low_manual
  elif remote_vnc_connected; then
    if [[ "$last" != "low" ]]; then
      [[ -s "$HOME_CACHE" ]] || capture_home   # 下げる前=ホーム解像度を確保
      sleep $SETTLE_DELAY
      remote_vnc_connected && { apply_low; last="low" }
    fi
    [[ "$last" == "low" ]] && write_state low
  else
    if [[ "$last" != "high" ]]; then
      restore_home
      rc=$?
      if (( rc == 1 )); then sleep $POLL_INTERVAL; continue; fi
      last="high"
    fi
    capture_home
    write_state home
  fi
  sleep $POLL_INTERVAL
done
