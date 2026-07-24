#!/bin/zsh
# SwiftBar プラグインの出力とサブコマンドを検証する(SwiftBar 不要)
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

# displayplacer スタブ: 解像度サブメニューの一覧用
cat > "$TMP/bin/displayplacer" <<'EOF'
#!/bin/zsh
print -r -- "Resolutions for rotation 0:"
print -r -- "  mode 1: res:3840x1620 hz:120"
print -r -- "  mode 2: res:2560x1080"
print -r -- "  mode 3: res:1920x810"
EOF
chmod +x "$TMP/bin/launchctl" "$TMP/bin/displayplacer"

export SCREENSHARE_RES_STATE_DIR="$TMP/state"
export SCREENSHARE_RES_LAUNCHCTL="$TMP/bin/launchctl"
export SCREENSHARE_RES_DISPLAYPLACER="$TMP/bin/displayplacer"

assert_contains() {
  print -r -- "$1" | grep -qF -- "$2" || { print -r -- "FAIL: '$2' が出力に無い"; print -r -- "$1"; exit 1 }
}

assert_not_contains() {
  if print -r -- "$1" | grep -qF -- "$2"; then
    print -r -- "FAIL: '$2' が出力に含まれる"; print -r -- "$1"; exit 1
  fi
}

assert_checked() {  # $1=出力 $2=ラベル: そのラベル行に checked=true があること
  print -r -- "$1" | grep -F -- "$2" | grep -q "checked=true" \
    || { print -r -- "FAIL: '$2' の行に checked=true が無い"; print -r -- "$1"; exit 1 }
}

# 1) watcher 未ロード → 警告表示
out="$(STUB_LOADED=0 zsh "$PLUGIN")"
assert_contains "$out" "⚠️"
assert_contains "$out" "watcher が動いていません"

# 2) home + 自動判定 → 🏠、自動判定に ✓、3 モードと解像度サブメニューが並ぶ
print -r -- 'STATE="home"'$'\n''REMOTE_IP=""'$'\n''CHANGED_AT="2026-07-20 10:00:00"' > "$TMP/state/state"
out="$(STUB_LOADED=1 zsh "$PLUGIN")"
assert_contains "$out" "🏠"
assert_contains "$out" "状態: ホーム解像度"
assert_contains "$out" "接続: なし"
assert_checked "$out" "自動判定"
assert_contains "$out" "高解像度（自宅）"
assert_contains "$out" "低解像度（外出）"
assert_contains "$out" "高解像度: 自動学習"
assert_contains "$out" "低解像度: config 設定"
assert_contains "$out" "-- 2560x1080"

# 3) low 状態 + 接続元 IP → 💻
print -r -- 'STATE="low"'$'\n''REMOTE_IP="100.99.1.2"'$'\n''CHANGED_AT="2026-07-20 10:01:00"' > "$TMP/state/state"
out="$(STUB_LOADED=1 zsh "$PLUGIN")"
assert_contains "$out" "💻"
assert_contains "$out" "接続: 100.99.1.2"

# 4) mode サブコマンドは排他でフラグを切り替える
zsh "$PLUGIN" mode high
[[ -e "$TMP/state/override" && ! -e "$TMP/state/force_low" ]] || { print -r -- "FAIL: mode high のフラグ"; exit 1 }
zsh "$PLUGIN" mode low
[[ ! -e "$TMP/state/override" && -e "$TMP/state/force_low" ]] || { print -r -- "FAIL: mode low のフラグ"; exit 1 }
zsh "$PLUGIN" mode auto
[[ ! -e "$TMP/state/override" && ! -e "$TMP/state/force_low" ]] || { print -r -- "FAIL: mode auto のフラグ"; exit 1 }

# 5) override 状態 → 📌、高解像度（自宅）に ✓
zsh "$PLUGIN" mode high
print -r -- 'STATE="override"'$'\n''REMOTE_IP=""'$'\n''CHANGED_AT="2026-07-20 10:02:00"' > "$TMP/state/state"
out="$(STUB_LOADED=1 zsh "$PLUGIN")"
assert_contains "$out" "📌"
assert_checked "$out" "高解像度（自宅）"

# 6) override 中でも watcher 未ロードなら警告が優先される(design.md §5)
out="$(STUB_LOADED=0 zsh "$PLUGIN")"
assert_contains "$out" "⚠️"
assert_not_contains "$out" "📌"

# 7) 手動低解像度 → 💻、低解像度（外出）に ✓
zsh "$PLUGIN" mode low
print -r -- 'STATE="low_manual"'$'\n''REMOTE_IP=""'$'\n''CHANGED_AT="2026-07-20 10:03:00"' > "$TMP/state/state"
out="$(STUB_LOADED=1 zsh "$PLUGIN")"
assert_contains "$out" "💻"
assert_contains "$out" "低解像度に固定中"
assert_checked "$out" "低解像度（外出）"
zsh "$PLUGIN" mode auto

# 8) res サブコマンド: 保存・表示・解除
zsh "$PLUGIN" res low 1920x810
[[ "$(cat "$TMP/state/res_low")" == "1920x810" ]] || { print -r -- "FAIL: res_low 保存"; exit 1 }
zsh "$PLUGIN" res high 2560x1080
[[ "$(cat "$TMP/state/res_high")" == "2560x1080" ]] || { print -r -- "FAIL: res_high 保存"; exit 1 }
print -r -- 'STATE="home"'$'\n''REMOTE_IP=""'$'\n''CHANGED_AT="2026-07-20 10:04:00"' > "$TMP/state/state"
out="$(STUB_LOADED=1 zsh "$PLUGIN")"
assert_contains "$out" "高解像度: 2560x1080"
assert_contains "$out" "低解像度: 1920x810"
zsh "$PLUGIN" res high auto
[[ ! -e "$TMP/state/res_high" ]] || { print -r -- "FAIL: res high auto で解除されない"; exit 1 }
zsh "$PLUGIN" res low config
[[ ! -e "$TMP/state/res_low" ]] || { print -r -- "FAIL: res low config で解除されない"; exit 1 }

print -r -- "plugin tests: OK"
