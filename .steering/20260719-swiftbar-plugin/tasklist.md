# SwiftBar プラグイン化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** watcher の状態をメニューバーに常時表示し、「高解像度に固定」の手動オーバーライドを追加する（設計: 同ディレクトリの design.md）。

**Architecture:** watcher が `state` ファイル（key=value, source 可能）を書き、SwiftBar プラグイン（zsh 1枚）がそれを読んで表示・`override` フラグファイルを touch/rm する。判定・適用ロジックは watcher に一元化したまま、プラグインは薄い UI 層。

**Tech Stack:** zsh / SwiftBar / launchd / displayplacer（既存）

## Global Constraints

- シェルは **zsh 固定**（macOS の bash 3.2 は不可。`${(@f)...}`, `<->` グロブ等の zsh 依存を使用してよい）
- launchd ラベルは `com.wadap.screenshare-res`、GUI ドメインは `gui/$(id -u)`
- `displayplacer` に `hz` / `color_depth` は指定しない
- 状態ディレクトリは `~/.local/state/screenshare-res`。**テスト用に環境変数 `SCREENSHARE_RES_STATE_DIR` で上書き可能にする**（本番挙動は不変）
- `state` ファイルの値は**必ずダブルクォートで書く**（`CHANGED_AT` に空白が入るため。素の値だと `source` が壊れる）
- コミットメッセージは日本語、末尾に `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- 各タスク完了時に `make check`（Task 1 以降は `make test`）が通ること

---

### Task 1: watcher 拡張（override フラグ + state ファイル）

**Files:**
- Modify: `bin/screenshare-res-watch.zsh`
- Test: `tests/watcher.test.zsh`（新規）

**Interfaces:**
- Consumes: なし（既存 watcher のみ）
- Produces（後続タスクが依存する契約）:
  - `$STATE_DIR/override` … 存在＝高解像度固定。watcher は存在チェックのみ（作成/削除はプラグイン）
  - `$STATE_DIR/state` … watcher だけが書く。内容は 3 行、値はダブルクォート:
    `STATE="home|low|override"` / `REMOTE_IP="100.x.y.z か空"` / `CHANGED_AT="YYYY-MM-DD HH:MM:SS"`
  - 環境変数 `SCREENSHARE_RES_STATE_DIR`（未設定時は従来の `~/.local/state/screenshare-res`）

- [x] **Step 1: 失敗するテストを書く**

`tests/watcher.test.zsh` を新規作成（実行権限付与）:

```zsh
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
```

- [x] **Step 2: テストが失敗することを確認**

Run: `chmod +x tests/watcher.test.zsh && zsh tests/watcher.test.zsh`
Expected: `FAIL: STATE が home にならない (現在: <none>)` で exit 1（現行 watcher は state ファイルを書かないため）

- [x] **Step 3: watcher を実装**

`bin/screenshare-res-watch.zsh` を以下の完全な内容に置き換える（既存からの差分: ヘッダコメント追記、`STATE_DIR` の env 上書き、`STATE_FILE`/`OVERRIDE_FLAG` 追加、`remote_vnc_connected` が `REMOTE_IP` を保存、`restore_home` が理由ラベルを取る、`write_state` 追加、メインループに override 分岐と `write_state` 呼び出し追加。判定・適用・誤学習ガードの順序は不変）:

```zsh
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
    fip="${foreign%%:*}"
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
  eval "$DISPLAYPLACER \"$LOW_CMD\"" >> "$LOG" 2>&1 && log "-> LOW (Tailscale remote)"
}

restore_home() {
  local why="${1:-restored}"
  [[ -s "$HOME_CACHE" ]] || { log "!! no home cache, skip restore"; return 1 }
  eval "$DISPLAYPLACER $(cat "$HOME_CACHE")" >> "$LOG" 2>&1 && log "-> HIGH ($why)"
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
      last="high"
    fi
    capture_home
    write_state override
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
      last="high"
    fi
    capture_home
    write_state home
  fi
  sleep $POLL_INTERVAL
done
```

- [x] **Step 4: テストが通ることを確認**

Run: `zsh tests/watcher.test.zsh && make check`
Expected: `watcher tests: OK` と `syntax ok`

- [x] **Step 5: コミット**

```bash
rtk git add bin/screenshare-res-watch.zsh tests/watcher.test.zsh
rtk git commit -m "watcher に override フラグと state ファイル書き出しを追加

SwiftBar プラグインとのファイル IF (design.md 参照)。
- override 存在中は接続中でもホーム解像度を維持
- 状態変化時に state を tmp+mv でアトミック書き込み
- テスト: lsof/displayplacer スタブによる状態遷移検証

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: SwiftBar プラグイン本体

**Files:**
- Create: `swiftbar/screenshare-res.5s.zsh`（実行権限付与）
- Test: `tests/plugin.test.zsh`（新規）

**Interfaces:**
- Consumes（Task 1 の契約）: `$STATE_DIR/state`（`STATE`/`REMOTE_IP`/`CHANGED_AT`、値はクォート済み）、`$STATE_DIR/override`、env `SCREENSHARE_RES_STATE_DIR`
- Produces: `swiftbar/screenshare-res.5s.zsh`（Task 3 が symlink 設置する）。テスト用 env `SCREENSHARE_RES_LAUNCHCTL`（launchctl のパス差し替え、既定 `/bin/launchctl`）

- [x] **Step 1: 失敗するテストを書く**

`tests/plugin.test.zsh` を新規作成（実行権限付与）:

```zsh
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
```

- [x] **Step 2: テストが失敗することを確認**

Run: `chmod +x tests/plugin.test.zsh && zsh tests/plugin.test.zsh`
Expected: プラグインファイルが存在しないため zsh がエラー（no such file）で exit 非0

- [x] **Step 3: プラグインを実装**

`swiftbar/screenshare-res.5s.zsh` を新規作成:

```zsh
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
```

作成後: `chmod +x swiftbar/screenshare-res.5s.zsh`

- [x] **Step 4: テストが通ることを確認**

Run: `zsh tests/plugin.test.zsh && zsh -n swiftbar/screenshare-res.5s.zsh`
Expected: `plugin tests: OK`

- [x] **Step 5: コミット**

```bash
rtk git add swiftbar/screenshare-res.5s.zsh tests/plugin.test.zsh
rtk git commit -m "SwiftBar プラグインを追加

state を読んで 🏠/📱/📌/⚠️ を表示し、override フラグを
touch/rm する薄い UI 層。SwiftBar なしでも直接実行で検証可能。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: install.sh / Makefile 統合

**Files:**
- Modify: `install.sh`（`swiftbar` サブコマンド追加、`cmd_uninstall` に symlink 削除追加、usage 更新）
- Modify: `Makefile`（`swiftbar` / `test` ターゲット追加、`check` にプラグインとテストを追加）

**Interfaces:**
- Consumes: `swiftbar/screenshare-res.5s.zsh`（Task 2）
- Produces: `make swiftbar` / `./install.sh swiftbar` / `make test`

- [x] **Step 1: install.sh に swiftbar サブコマンドを追加**

変数定義部（`CONFIG_SRC=` の直後）に追加:

```zsh
PLUGIN_SRC="$SRC_DIR/swiftbar/screenshare-res.5s.zsh"
PLUGIN_NAME="screenshare-res.5s.zsh"
```

`cmd_logs()` の後に追加:

```zsh
# SwiftBar のプラグインフォルダ(ユーザーが初回起動時に選択)を取得。未設定なら空
swiftbar_plugdir() {
  defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true
}

cmd_swiftbar() {
  [[ -d "/Applications/SwiftBar.app" || -d "$HOME/Applications/SwiftBar.app" ]] \
    || die "SwiftBar が無い → brew install --cask swiftbar"
  local plugdir
  plugdir="$(swiftbar_plugdir)"
  [[ -n "$plugdir" && -d "$plugdir" ]] \
    || die "SwiftBar のプラグインフォルダ未設定。SwiftBar を一度起動して選択してください"
  ln -sfn "$PLUGIN_SRC" "$plugdir/$PLUGIN_NAME"
  print -r -- "linked: $plugdir/$PLUGIN_NAME -> $PLUGIN_SRC"
}
```

`cmd_uninstall()` を以下に置き換え（symlink 削除を追加。`set -eu` なので `&&` 連鎖ではなく `if` を使うこと）:

```zsh
cmd_uninstall() {
  launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$SCRIPT_DST"
  local plugdir
  plugdir="$(swiftbar_plugdir)"
  if [[ -n "$plugdir" ]]; then
    rm -f "$plugdir/$PLUGIN_NAME"
  fi
  print -r -- "uninstalled (config と logs は $CONFIG_DIR / $STATE_DIR に残置)"
}
```

末尾の `case` を以下に置き換え:

```zsh
case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  reload)    cmd_reload ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  swiftbar)  cmd_swiftbar ;;
  *) print -r -- "usage: install.sh {install|uninstall|reload|status|logs|swiftbar}"; exit 2 ;;
esac
```

ファイル先頭のコメント（サブコマンド一覧）にも `swiftbar  SwiftBar プラグインを symlink 設置` の行を追加。

- [x] **Step 2: Makefile を更新**

全体を以下に置き換え:

```makefile
.PHONY: install uninstall reload status logs swiftbar check test

install:   ; ./install.sh install
uninstall: ; ./install.sh uninstall
reload:    ; ./install.sh reload
status:    ; ./install.sh status
logs:      ; ./install.sh logs
swiftbar:  ; ./install.sh swiftbar

check: ## zsh構文チェック
	zsh -n bin/screenshare-res-watch.zsh
	zsh -n install.sh
	zsh -n swiftbar/screenshare-res.5s.zsh
	zsh -n tests/watcher.test.zsh
	zsh -n tests/plugin.test.zsh
	@echo "syntax ok"

test: check ## スタブによる自動テスト
	zsh tests/watcher.test.zsh
	zsh tests/plugin.test.zsh
```

- [x] **Step 3: 動作確認**

Run: `make test`
Expected: `syntax ok` → `watcher tests: OK` → `plugin tests: OK`

Run: `./install.sh swiftbar`
Expected: このマシンは SwiftBar 未インストールなので `error: SwiftBar が無い → brew install --cask swiftbar` で exit 1（案内が正しく出ることの確認）

- [x] **Step 4: コミット**

```bash
rtk git add install.sh Makefile
rtk git commit -m "install.sh に swiftbar サブコマンド、make test を追加

プラグインは SwiftBar のプラグインフォルダへ symlink 設置
(開発中の変更を即反映するため。watcher の cp 方式とは意図的に非対称)。

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: ドキュメント更新

**Files:**
- Modify: `README.md`（SwiftBar セクション追加、ロードマップ更新）
- Modify: `CLAUDE.md`（ファイル構成・設計要点に state/override とプラグインを追記）
- Modify: `.steering/20260719-swiftbar-plugin/decisions.md`（テスト用 env の決定を追記）

**Interfaces:**
- Consumes: Task 1〜3 の成果物
- Produces: なし（ドキュメントのみ）

- [x] **Step 1: README.md を更新**

「使い方」セクションの `make check` の行の後に `make test        # スタブによる自動テスト` を追加。

「仕組み」セクションの後に以下を追加:

```markdown
## SwiftBar プラグイン（メニューバー表示と手動固定）

[SwiftBar](https://github.com/swiftbar/SwiftBar)（`brew install --cask swiftbar`）
を入れると、watcher の状態をメニューバーで確認できる:

- 🏠 ホーム解像度 / 📱 低解像度 / 📌 高解像度に固定中 / ⚠️ watcher 停止
- メニューから「📌 高解像度に固定」⇄「✅ 自動に戻す」を切替（固定は手動解除まで有効）
- ログを開く / watcher を再起動もメニューから

```sh
# SwiftBar を一度起動してプラグインフォルダを選んでから
make swiftbar     # プラグインを symlink 設置
```

仕組み: watcher が `~/.local/state/screenshare-res/state` に現在状態を書き、
プラグインはそれを表示するだけ。「固定」は同ディレクトリの `override` フラグ
ファイルを touch/rm し、watcher が毎ループ参照する。
```

「ロードマップ」の SwiftBar 行を `- [x]` に更新。

- [x] **Step 2: CLAUDE.md を更新**

「ファイル構成」に以下を追加:

```markdown
- `swiftbar/screenshare-res.5s.zsh` — SwiftBar プラグイン（状態表示 + 手動固定 UI）
- `tests/*.test.zsh` — スタブ(lsof/displayplacer/launchctl)による自動テスト。`make test`
```

状態の行を次のように更新:

```markdown
- 状態: `~/.local/state/screenshare-res/`（`home.cmd` キャッシュ、`watch.log`、
  `state` 現在状態、`override` 手動固定フラグ）
```

「設計上の要点」に以下を追加:

```markdown
- **watcher ⇄ プラグインの契約はファイル 2 つ**。`state` は watcher だけが書く
  （値は必ずダブルクォート。source で読むため）。`override` はプラグインだけが
  touch/rm する。この契約は Swift ネイティブ化(ロードマップ②)でも維持する。
- テスト用に `SCREENSHARE_RES_STATE_DIR` / `SCREENSHARE_RES_LAUNCHCTL` で
  状態 dir と launchctl を差し替え可能（本番では未設定のまま）。
```

- [x] **Step 3: decisions.md に追記**

```markdown
- **2026-07-19 テスト容易性のため env 上書きを導入**
  - `SCREENSHARE_RES_STATE_DIR`（watcher/プラグイン共通）と
    `SCREENSHARE_RES_LAUNCHCTL`（プラグイン）を追加
  - lsof / displayplacer は既存の config 変数で差し替え可能なため、
    スタブによる自動テスト(`make test`)が SwiftBar・実接続なしで回せる
```

- [x] **Step 4: コミット**

```bash
rtk git add README.md CLAUDE.md .steering/
rtk git commit -m "SwiftBar プラグインのドキュメントを追加

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: 実機確認（要ユーザー協力）

**Files:** なし（検証のみ）

**Interfaces:**
- Consumes: Task 1〜3 の成果物一式
- Produces: 検証済みの動作（blockers.md の解消）

前提: SwiftBar のインストール（`brew install --cask swiftbar`）と初回起動（プラグインフォルダ選択）が必要。マシンへの変更なのでユーザーに確認してから実行すること。

- [x] **Step 1: watcher を新版に入れ替え**

Run: `make reload` ではなく `make install`（`~/bin` へのコピーを更新するため）
Expected: `installed & loaded: com.wadap.screenshare-res`。`make status` で agent: loaded、`tail -2 ~/.local/state/screenshare-res/state` に `STATE="home"` が出る

- [x] **Step 2: SwiftBar 設置**

Run: `brew install --cask swiftbar`（ユーザー確認後）→ SwiftBar を起動しプラグインフォルダを選択 → `make swiftbar`
Expected: メニューバーに 🏠 が出る

- [x] **Step 3: 手動テストマトリクス**

1. メニューから「📌 高解像度に固定」→ アイコンが 📌 になる
2. 「✅ 自動に戻す」→ 🏠 に戻る
3. `launchctl bootout gui/$(id -u)/com.wadap.screenshare-res` → ⚠️ になり、メニュー「watcher を起動」で復帰
4. （外出時 or 別マシンから）Tailscale 経由で画面共有 → 📱・解像度低下、📌 固定すると復帰、切断で 🏠
Expected: すべて期待どおり。4 は実接続が必要なので可能なタイミングでよい

- [x] **Step 4: 結果を記録してコミット**

`.steering/20260719-swiftbar-plugin/blockers.md` から解消済み項目を消し、`tasklist.md` のチェックボックスを更新して:

```bash
rtk git add .steering/ && rtk git commit -m "実機確認の結果を記録

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>" && rtk git push
```
