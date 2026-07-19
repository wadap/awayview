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

assert_not_contains() {
  if print -r -- "$1" | grep -qF -- "$2"; then
    print -r -- "FAIL: '$2' が出力に含まれる"; print -r -- "$1"; exit 1
  fi
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

# 5) override 中でも watcher 未ロードなら警告が優先される(design.md §5)
out="$(STUB_LOADED=0 zsh "$PLUGIN")"
assert_contains "$out" "⚠️"
assert_not_contains "$out" "📌"

# 6) フラグなしの home → 高固定・低固定の両トグルが並ぶ
rm "$TMP/state/override"
print -r -- 'STATE="home"'$'\n''REMOTE_IP=""'$'\n''CHANGED_AT="2026-07-19 10:03:00"' > "$TMP/state/state"
out="$(STUB_LOADED=1 zsh "$PLUGIN")"
assert_contains "$out" "高解像度に固定"
assert_contains "$out" "今すぐ低解像度にする"

# 7) 手動低解像度固定中 → 📱 + 解除メニューのみ
touch "$TMP/state/force_low"
print -r -- 'STATE="low_manual"'$'\n''REMOTE_IP=""'$'\n''CHANGED_AT="2026-07-19 10:04:00"' > "$TMP/state/state"
out="$(STUB_LOADED=1 zsh "$PLUGIN")"
assert_contains "$out" "📱"
assert_contains "$out" "低解像度に固定中"
assert_contains "$out" "自動に戻す"
assert_not_contains "$out" "高解像度に固定"
rm "$TMP/state/force_low"

print -r -- "plugin tests: OK"
