.PHONY: install uninstall reload status logs swiftbar check test \
        native-build native-install native-uninstall

# --- legacy (zsh watcher + SwiftBar) ----------------------------------
install:   ; ./install.sh install
uninstall: ; ./install.sh uninstall
reload:    ; ./install.sh reload
status:    ; ./install.sh status
logs:      ; ./install.sh logs
swiftbar:  ; ./install.sh swiftbar

# --- native (Swift メニューバーアプリ) --------------------------------
# swift test に XCTest が要るため Xcode toolchain を明示 (CLT には無い)
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
APP      = native/dist/ScreenshareRes.app
APP_DST  = $(HOME)/Applications/ScreenshareRes.app

native-build: ## .app バンドルを組み立てて ad-hoc 署名
	cd native && swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp native/.build/release/ScreenshareRes $(APP)/Contents/MacOS/
	cp native/Info.plist $(APP)/Contents/
	codesign --force --sign - $(APP)
	@echo "built: $(APP)"

native-install: native-build ## legacy を止めて native に切替
	-launchctl bootout gui/$$(id -u)/com.wadap.screenshare-res 2>/dev/null
	-rm -f "$$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null)/screenshare-res.5s.zsh"
	-pkill -x ScreenshareRes 2>/dev/null
	rm -rf $(APP_DST)
	cp -R $(APP) $(APP_DST)
	open $(APP_DST)
	@echo "installed & launched: $(APP_DST)"
	@echo "  (zsh 版へ戻すには: make native-uninstall && make install && make swiftbar)"

native-uninstall: ## native を終了して削除 (ログイン項目はアプリ側メニューで解除)
	-pkill -x ScreenshareRes 2>/dev/null
	rm -rf $(APP_DST)
	@echo "uninstalled: $(APP_DST)"

# --- 共通 -------------------------------------------------------------
check: ## zsh構文チェック
	zsh -n bin/screenshare-res-watch.zsh
	zsh -n install.sh
	zsh -n swiftbar/screenshare-res.5s.zsh
	zsh -n tests/watcher.test.zsh
	zsh -n tests/plugin.test.zsh
	@echo "syntax ok"

test: check ## zsh テスト + Swift テスト
	zsh tests/watcher.test.zsh
	zsh tests/plugin.test.zsh
	cd native && DEVELOPER_DIR=$(DEVELOPER_DIR) swift test 2>&1 | tail -1
