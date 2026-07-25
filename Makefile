.PHONY: build install uninstall check test

# swift test に XCTest が要るため Xcode toolchain を明示 (CLT には無い)
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
APP     = dist/AwayView.app
APP_DST = $(HOME)/Applications/AwayView.app

build: ## .app バンドルを組み立てて ad-hoc 署名
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp .build/release/AwayView $(APP)/Contents/MacOS/
	cp Info.plist $(APP)/Contents/
	@if [ -d .build/release/AwayView_AwayView.bundle ]; then \
	  cp -R .build/release/AwayView_AwayView.bundle $(APP)/Contents/Resources/; fi
	codesign --force --sign - $(APP)
	@echo "built: $(APP)"

install: build ## ~/Applications へ入れ替えて起動
	-pkill -x AwayView 2>/dev/null
	rm -rf $(APP_DST)
	cp -R $(APP) $(APP_DST)
	open $(APP_DST)
	@echo "installed & launched: $(APP_DST)"

uninstall: ## 終了して削除 (ログイン項目は設定ウィンドウで解除)
	-pkill -x AwayView 2>/dev/null
	rm -rf $(APP_DST)
	@echo "uninstalled: $(APP_DST)"

check: ## 型チェック (debug build)
	swift build

test:
	DEVELOPER_DIR=$(DEVELOPER_DIR) swift test 2>&1 | tail -1
