#!/bin/zsh
#
# install.sh <command>
#   install    ~/bin へ設置し config を用意し LaunchAgent を bootstrap
#   uninstall  bootout して plist と設置スクリプトを削除(config/logは残す)
#   reload     bootout → bootstrap
#   status     稼働状況と直近ログ
#   logs       watch.log を tail -f
#
# 初回 install は「自宅で・画面共有していない状態」で実行すること
# (ホーム解像度をその場でキャッシュするため)。
#
set -eu

LABEL="com.wadap.screenshare-res"
SRC_DIR="${0:A:h}"
SCRIPT_SRC="$SRC_DIR/bin/screenshare-res-watch.zsh"
CONFIG_SRC="$SRC_DIR/config.example.zsh"

BIN_DIR="$HOME/bin"
SCRIPT_DST="$BIN_DIR/screenshare-res-watch.zsh"
AGENT_DIR="$HOME/Library/LaunchAgents"
PLIST="$AGENT_DIR/$LABEL.plist"
CONFIG_DIR="$HOME/.config/screenshare-res"
CONFIG="$CONFIG_DIR/config.zsh"
STATE_DIR="$HOME/.local/state/screenshare-res"
DP="/opt/homebrew/bin/displayplacer"
GUI="gui/$(id -u)"

die() { print -r -- "error: $*" >&2; exit 1 }

cmd_install() {
  [[ -f "$SCRIPT_SRC" ]] || die "bin/screenshare-res-watch.zsh が見つかりません"
  [[ -x "$DP" ]] || die "displayplacer が無い → brew install jakehilborn/jakehilborn/displayplacer"

  mkdir -p "$BIN_DIR" "$AGENT_DIR" "$CONFIG_DIR" "$STATE_DIR"

  # config を用意(無ければサンプルから)
  if [[ ! -f "$CONFIG" ]]; then
    cp "$CONFIG_SRC" "$CONFIG"
    print -r -- "seeded config: $CONFIG"
  fi
  if grep -q 'REPLACE_WITH_SCREEN_ID' "$CONFIG"; then
    die "先に $CONFIG の SCREEN_ID を埋めてください（$DP list で確認）"
  fi

  cp "$SCRIPT_SRC" "$SCRIPT_DST"
  chmod +x "$SCRIPT_DST"

  cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$SCRIPT_DST</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$STATE_DIR/launchd.out.log</string>
  <key>StandardErrorPath</key><string>$STATE_DIR/launchd.err.log</string>
</dict>
</plist>
PLIST_EOF

  launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$GUI" "$PLIST"
  launchctl enable "$GUI/$LABEL"
  print -r -- "installed & loaded: $LABEL"
  print -r -- "  config: $CONFIG"
  print -r -- "  logs  : $STATE_DIR/"
}

cmd_uninstall() {
  launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$SCRIPT_DST"
  print -r -- "uninstalled (config と logs は $CONFIG_DIR / $STATE_DIR に残置)"
}

cmd_reload() {
  [[ -f "$PLIST" ]] || die "plist が無い。先に install してください"
  launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$GUI" "$PLIST"
  print -r -- "reloaded: $LABEL"
}

cmd_status() {
  if launchctl print "$GUI/$LABEL" >/dev/null 2>&1; then
    print -r -- "agent: loaded"
  else
    print -r -- "agent: NOT loaded"
  fi
  [[ -f "$STATE_DIR/watch.log" ]] && { print -r -- "--- watch.log (tail) ---"; tail -n 5 "$STATE_DIR/watch.log" }
}

cmd_logs() { exec tail -f "$STATE_DIR/watch.log" }

case "${1:-}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  reload)    cmd_reload ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  *) print -r -- "usage: install.sh {install|uninstall|reload|status|logs}"; exit 2 ;;
esac
