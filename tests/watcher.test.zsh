#!/bin/zsh
# watcher の状態遷移を lsof / displayplacer のスタブで検証する
set -eu

ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
WPID=""
trap '[[ -n "$WPID" ]] && kill "$WPID" 2>/dev/null; rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/state"

# netstat スタブ: $STUB_DIR/connected (IPv4) / connected6 (IPv6) で接続を返す
# ローカルLAN接続(100.x でない)と非ESTABLISHED行は常に混ぜて誤検知しないことを見る
cat > "$TMP/bin/netstat" <<'EOF'
#!/bin/zsh
print -r -- "Active Internet connections (including servers)"
print -r -- "Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)"
print -r -- "tcp4       0      0  192.168.1.10.5900      192.168.1.20.50000     ESTABLISHED"
print -r -- "tcp4       0      0  192.168.1.10.5900      100.99.1.9.50001       TIME_WAIT"
print -r -- "tcp4       0      0  192.168.1.10.22        100.99.1.2.50002       ESTABLISHED"
if [[ -e "$STUB_DIR/connected" ]]; then
  print -r -- "tcp4       0      0  192.168.1.10.5900      100.99.1.2.53211       ESTABLISHED"
fi
if [[ -e "$STUB_DIR/connected6" ]]; then
  print -r -- "tcp6       0      0  fd7a:115c:a1e0::aa.5900 fd7a:115c:a1e0:ab12:4843:cd96:6265:b2b5.53211 ESTABLISHED"
fi
exit 0
EOF

# displayplacer スタブ: list はホーム配置1行、適用は applied.log へ記録
cat > "$TMP/bin/displayplacer" <<'EOF'
#!/bin/zsh
if [[ "${1:-}" == "list" ]]; then
  print -r -- 'displayplacer "id:HOME res:3008x1692 origin:(0,0) degree:0"'
else
  [[ -e "$STUB_DIR/fail_apply" ]] && exit 1
  print -r -- "APPLY $*" >> "$STUB_DIR/applied.log"
fi
EOF
chmod +x "$TMP/bin/netstat" "$TMP/bin/displayplacer"

cat > "$TMP/config.zsh" <<EOF
SCREEN_ID="TEST"
LOW_CMD="id:TEST res:1600x900 scaling:on origin:(0,0) degree:0"
DISPLAYPLACER="$TMP/bin/displayplacer"
NETSTAT="$TMP/bin/netstat"
POLL_INTERVAL=1
SETTLE_DELAY=0
on_low()  { print -r -- "on_low"  >> "$TMP/hooks.log" }
on_high() { print -r -- "on_high" >> "$TMP/hooks.log" }
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

# 2) Tailscale 接続 → low、REMOTE_IP が入る、on_low フックが発火
touch "$TMP/connected"
wait_state low
[[ "$REMOTE_IP" == "100.99.1.2" ]] || { print -r -- "FAIL: REMOTE_IP=$REMOTE_IP"; exit 1 }
grep -q on_low "$TMP/hooks.log" 2>/dev/null || { print -r -- "FAIL: on_low フックが呼ばれていない"; exit 1 }

# 3) 接続中に override → ホーム復帰して override、on_high フックが発火
touch "$TMP/state/override"
wait_state override
tail -1 "$TMP/applied.log" | grep -q '3008x1692' || { print -r -- "FAIL: override 中にホーム解像度が適用されていない"; exit 1 }
grep -q on_high "$TMP/hooks.log" 2>/dev/null || { print -r -- "FAIL: on_high フックが呼ばれていない"; exit 1 }

# 4) 接続中に override 解除 → low へ戻る
rm "$TMP/state/override"
wait_state low

# 5) 切断 → home
rm "$TMP/connected"
wait_state home

# 6) 復帰失敗中は state が進まず、成功したら override になる(誤学習ガード)
touch "$TMP/connected"
wait_state low
touch "$TMP/fail_apply"
touch "$TMP/state/override"
sleep 2   # POLL_INTERVAL=1 で複数ループ回す
source "$TMP/state/state"
[[ "$STATE" == "low" ]] || { print -r -- "FAIL: 復帰失敗中に STATE=$STATE へ進んだ"; exit 1 }
rm "$TMP/fail_apply"
wait_state override
rm "$TMP/state/override" "$TMP/connected"
wait_state home

# 7) 手動低解像度トグル: 接続がなくても下がり、解除で戻る
touch "$TMP/state/force_low"
wait_state low_manual
tail -1 "$TMP/applied.log" | grep -q '1600x900' || { print -r -- "FAIL: force_low で低解像度が適用されていない"; exit 1 }
rm "$TMP/state/force_low"
wait_state home

# 8) override は force_low より優先される
touch "$TMP/state/force_low" "$TMP/state/override"
wait_state override
rm "$TMP/state/force_low" "$TMP/state/override"
wait_state home

# 9) IPv6 (fd7a:115c:a1e0::/48) の Tailscale 接続も検知する
touch "$TMP/connected6"
wait_state low
[[ "$REMOTE_IP" == fd7a:115c:a1e0:* ]] || { print -r -- "FAIL: IPv6 の REMOTE_IP=$REMOTE_IP"; exit 1 }
rm "$TMP/connected6"
wait_state home

# 10) res_low 選択が config の LOW_CMD より優先され、低解像度中の変更は即再適用
print -r -- "1280x540" > "$TMP/state/res_low"
touch "$TMP/state/force_low"
wait_state low_manual
tail -1 "$TMP/applied.log" | grep -q '1280x540' || { print -r -- "FAIL: res_low が適用されていない"; exit 1 }
print -r -- "960x540" > "$TMP/state/res_low"
sleep 2
tail -1 "$TMP/applied.log" | grep -q '960x540' || { print -r -- "FAIL: res_low 変更が再適用されていない"; exit 1 }
rm "$TMP/state/force_low" "$TMP/state/res_low"
wait_state home

# 11) res_high 明示指定はホーム状態でも即適用され、自動学習より優先される
print -r -- "3200x1350" > "$TMP/state/res_high"
sleep 2
tail -1 "$TMP/applied.log" | grep -q '3200x1350' || { print -r -- "FAIL: res_high が適用されていない"; exit 1 }
rm "$TMP/state/res_high"

grep -q 'APPLY' "$TMP/applied.log" || { print -r -- "FAIL: displayplacer が呼ばれていない"; exit 1 }
print -r -- "watcher tests: OK"
