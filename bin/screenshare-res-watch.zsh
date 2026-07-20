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
: "${NETSTAT:=/usr/sbin/netstat}"
: "${POLL_INTERVAL:=3}"
: "${SETTLE_DELAY:=2}"

STATE_DIR="${SCREENSHARE_RES_STATE_DIR:-$HOME/.local/state/screenshare-res}"
HOME_CACHE="$STATE_DIR/home.cmd"
LOG="$STATE_DIR/watch.log"
STATE_FILE="$STATE_DIR/state"
OVERRIDE_FLAG="$STATE_DIR/override"
FORCE_LOW_FLAG="$STATE_DIR/force_low"
RES_LOW_FILE="$STATE_DIR/res_low"     # プラグインで選んだ低解像度 (WxH)。無ければ LOW_CMD
RES_HIGH_FILE="$STATE_DIR/res_high"   # プラグインで選んだ高解像度 (WxH)。無ければ自動学習
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
# netstat を使う: screensharingd は root 所有で、ユーザー権限の lsof では
# そのソケットが見えない(検知不能)。netstat は root 不要で全プロセス可視。
# 見つけた接続元は REMOTE_IP に保存する(state ファイル表示用)
REMOTE_IP=""
remote_vnc_connected() {
  local foreign fip
  local -a foreigns
  REMOTE_IP=""
  foreigns=("${(@f)$($NETSTAT -anv -p tcp 2>/dev/null \
    | awk '$6=="ESTABLISHED" && $4 ~ /\.5900$/ {print $5}')}")
  for foreign in $foreigns; do
    [[ -z "$foreign" ]] && continue
    fip="${foreign%.*}"   # 末尾の .port を除去 (IPv4/IPv6 共通)
    is_tailscale_ip "$fip" && { REMOTE_IP="$fip"; return 0 }
  done
  return 1
}

# --- 現在(=ホーム)の配置をdisplayplacerコマンド文字列として保存 -------
capture_home() {
  local cmd
  cmd="$($DISPLAYPLACER list 2>/dev/null \
        | awk '/^displayplacer /{sub(/^displayplacer /,""); print; exit}')"
  # ディスプレイのスリープ/無効の瞬間 (enabled:false や res 無し) を
  # ホームとして誤学習しない。復帰時に enabled:false を適用すると画面が消える
  [[ -n "$cmd" && "$cmd" == *" res:"* && "$cmd" != *"enabled:false"* ]] || return 0
  print -r -- "$cmd" > "$HOME_CACHE"
}

# --- モード遷移フック: config.zsh に on_low() / on_high() があれば呼ぶ ---
# フックの失敗は watcher 本体の動作に影響させない
run_hook() {
  local hook="$1"
  whence -f "$hook" >/dev/null || return 0
  "$hook" >> "$LOG" 2>&1 || log "!! hook $hook failed"
}

# --- 解像度選択 (プラグインが書く WxH ファイル) から引数を組み立てる ---
# hz/color_depth は指定しない方針。scaling は HiDPI 固定
res_cmd() { print -r -- "id:${SCREEN_ID} res:${1} scaling:on origin:(0,0) degree:0" }

current_low_cmd() {   # res_low 選択 > config の LOW_CMD
  local res=""
  [[ -s "$RES_LOW_FILE" ]] && res="$(<"$RES_LOW_FILE")"
  if [[ -n "$res" ]]; then res_cmd "$res"; else print -r -- "$LOW_CMD"; fi
}

current_high_cmd() {  # res_high 明示指定のときだけ非空。未指定なら自動学習に任せる
  local res=""
  [[ -s "$RES_HIGH_FILE" ]] && res="$(<"$RES_HIGH_FILE")"
  [[ -n "$res" ]] && res_cmd "$res"
  return 0
}

# 最後に適用したコマンド。適用中の解像度選択変更を検出して再適用するために使う
APPLIED_CMD=""

apply_low() {
  local why="${1:-Tailscale remote}" cmd
  cmd="$(current_low_cmd)"
  eval "$DISPLAYPLACER \"$cmd\"" >> "$LOG" 2>&1 || return 1
  APPLIED_CMD="$cmd"
  log "-> LOW ($why)"
  run_hook on_low
}

restore_home() {
  local why="${1:-restored}" cmd
  cmd="$(current_high_cmd)"
  if [[ -n "$cmd" ]]; then
    # 明示指定された高解像度を適用
    if eval "$DISPLAYPLACER \"$cmd\"" >> "$LOG" 2>&1; then
      APPLIED_CMD="$cmd"
      log "-> HIGH ($why)"
      run_hook on_high
      return 0
    fi
    log "!! restore failed ($why), will retry"
    return 1
  fi
  # 従来どおり自動学習したホーム配置へ復帰
  [[ -s "$HOME_CACHE" ]] || { log "!! no home cache, skip restore"; return 2 }
  if eval "$DISPLAYPLACER $(cat "$HOME_CACHE")" >> "$LOG" 2>&1; then
    APPLIED_CMD="$(<"$HOME_CACHE")"
    log "-> HIGH ($why)"
    run_hook on_high
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
    hcmd="$(current_high_cmd)"
    if [[ -n "$hcmd" && "$hcmd" != "$APPLIED_CMD" ]]; then
      restore_home "override, res change" || true   # 高解像度の選択変更を即反映
    fi
    capture_home
    write_state override
  elif [[ -e "$FORCE_LOW_FLAG" ]]; then
    # 手動の低解像度固定: 接続の有無に関わらず下げる
    remote_vnc_connected || true   # REMOTE_IP を表示用に更新するだけ
    if [[ "$last" != "low" ]]; then
      [[ -s "$HOME_CACHE" ]] || capture_home   # 下げる前=ホーム解像度を確保
      apply_low manual && last="low"
    elif [[ "$(current_low_cmd)" != "$APPLIED_CMD" ]]; then
      apply_low "manual, res change" || true   # 低解像度の選択変更を即反映
    fi
    [[ "$last" == "low" ]] && write_state low_manual
  elif remote_vnc_connected; then
    if [[ "$last" != "low" ]]; then
      [[ -s "$HOME_CACHE" ]] || capture_home   # 下げる前=ホーム解像度を確保
      sleep $SETTLE_DELAY
      remote_vnc_connected && { apply_low; last="low" }
    elif [[ "$(current_low_cmd)" != "$APPLIED_CMD" ]]; then
      apply_low "res change" || true           # 低解像度の選択変更を即反映
    fi
    [[ "$last" == "low" ]] && write_state low
  else
    if [[ "$last" != "high" ]]; then
      restore_home
      rc=$?
      if (( rc == 1 )); then sleep $POLL_INTERVAL; continue; fi
      last="high"
    fi
    hcmd="$(current_high_cmd)"
    if [[ -n "$hcmd" && "$hcmd" != "$APPLIED_CMD" ]]; then
      restore_home "res change" || true        # 高解像度の選択変更を即反映
    fi
    capture_home
    write_state home
  fi
  sleep $POLL_INTERVAL
done
