#!/bin/zsh
# watcher の状態遷移を lsof / displayplacer のスタブで検証する
set -eu

ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
WPID=""
trap '[[ -n "$WPID" ]] && kill "$WPID" 2>/dev/null; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/state"

# lsof スタブ: $STUB_DIR/connected があるときだけ Tailscale 接続を返す
cat > "$TMP/bin/lsof" <<'EOF'
#!/bin/zsh
[[ -e "$STUB_DIR/connected" ]] || exit 0
print -r -- "p123"
print -r -- "n192.168.1.10:5900->100.99.1.2:53211"
EOF

# displayplacer スタブ: list はホーム配置1行、適用は applied.log へ記録
cat > "$TMP/bin/displayplacer" <<'EOF'
#!/bin/zsh
if [[ "${1:-}" == "list" ]]; then
  print -r -- 'displayplacer "id:HOME res:3008x1692 origin:(0,0) degree:0"'
else
  print -r -- "APPLY $*" >> "$STUB_DIR/applied.log"
fi
EOF
chmod +x "$TMP/bin/lsof" "$TMP/bin/displayplacer"

cat > "$TMP/config.zsh" <<EOF
SCREEN_ID="TEST"
LOW_CMD="id:TEST res:1600x900 scaling:on origin:(0,0) degree:0"
DISPLAYPLACER="$TMP/bin/displayplacer"
LSOF="$TMP/bin/lsof"
POLL_INTERVAL=1
SETTLE_DELAY=0
EOF

export STUB_DIR="$TMP"
export SCREENSHARE_RES_CONFIG="$TMP/config.zsh"
export SCREENSHARE_RES_STATE_DIR="$TMP/state"
# env を知らない実装(旧版・誤実装)が実 ~/.local/state を汚さないためのガード
export HOME="$TMP"

zsh "$ROOT/bin/screenshare-res-watch.zsh" &
WPID=$!

STATE="" REMOTE_IP=""
wait_state() {  # state ファイルが期待値になるまで最大 5 秒待つ
  local want="$1" i
  for i in {1..50}; do
    if [[ -f "$TMP/state/state" ]]; then
      source "$TMP/state/state"
      if [[ "$STATE" == "$want" ]]; then return 0; fi
    fi
    sleep 0.1
  done
  print -r -- "FAIL: STATE が $want にならない (現在: ${STATE:-<none>})"
  exit 1
}

# 1) 起動直後・接続なし → home
wait_state home

# 2) Tailscale 接続 → low、REMOTE_IP が入る
touch "$TMP/connected"
wait_state low
[[ "$REMOTE_IP" == "100.99.1.2" ]] || { print -r -- "FAIL: REMOTE_IP=$REMOTE_IP"; exit 1 }

# 3) 接続中に override → ホーム復帰して override
touch "$TMP/state/override"
wait_state override

# 4) 接続中に override 解除 → low へ戻る
rm "$TMP/state/override"
wait_state low

# 5) 切断 → home
rm "$TMP/connected"
wait_state home

grep -q 'APPLY' "$TMP/applied.log" || { print -r -- "FAIL: displayplacer が呼ばれていない"; exit 1 }
print -r -- "watcher tests: OK"
