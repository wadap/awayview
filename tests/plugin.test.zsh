#!/bin/zsh
# SwiftBar プラグインの出力を状態別に検証する(SwiftBar 不要)
set -eu

ROOT="${0:A:h:h}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PLUGIN="$ROOT/swiftbar/screenshare-res.5s.zsh"

mkdir -p "$TMP/state" "$TMP/bin"

# launchctl スタブ: STUB_LOADED=1 のときだけ「ロード済み」
cat > "$TMP/bin/launchctl" <<'EOF'
#!/bin/zsh
[[ "${STUB_LOADED:-0}" == "1" ]]
EOF
chmod +x "$TMP/bin/launchctl"

export SCREENSHARE_RES_STATE_DIR="$TMP/state"
export SCREENSHARE_RES_LAUNCHCTL="$TMP/bin/launchctl"

assert_contains() {
  print -r -- "$1" | grep -qF -- "$2" || { print -r -- "FAIL: '$2' が出力に無い"; print -r -- "$1"; exit 1 }
}

# 1) watcher 未ロード → 警告表示
out="$(STUB_LOADED=0 zsh "$PLUGIN")"
assert_contains "$out" "⚠️"
assert_contains "$out" "watcher が動いていません"

# 2) home 状態 → 🏠 + 固定メニュー
print -r -- 'STATE="home"'$'\n''REMOTE_IP=""'$'\n''CHANGED_AT="2026-07-19 10:00:00"' > "$TMP/state/state"
out="$(STUB_LOADED=1 zsh "$PLUGIN")"
assert_contains "$out" "🏠"
assert_contains "$out" "状態: ホーム解像度"
assert_contains "$out" "接続: なし"
assert_contains "$out" "高解像度に固定"

# 3) low 状態 + 接続元 IP → 📱
print -r -- 'STATE="low"'$'\n''REMOTE_IP="100.99.1.2"'$'\n''CHANGED_AT="2026-07-19 10:01:00"' > "$TMP/state/state"
out="$(STUB_LOADED=1 zsh "$PLUGIN")"
assert_contains "$out" "📱"
assert_contains "$out" "接続: 100.99.1.2"

# 4) override 状態 → 📌 + 解除メニュー
touch "$TMP/state/override"
print -r -- 'STATE="override"'$'\n''REMOTE_IP=""'$'\n''CHANGED_AT="2026-07-19 10:02:00"' > "$TMP/state/state"
out="$(STUB_LOADED=1 zsh "$PLUGIN")"
assert_contains "$out" "📌"
assert_contains "$out" "自動に戻す"

print -r -- "plugin tests: OK"
