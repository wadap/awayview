.PHONY: build install uninstall check test icon

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
	cp -R .build/release/AwayView_AwayView.bundle $(APP)/Contents/Resources/
	cp assets/AppIcon.icns $(APP)/Contents/Resources/
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
	DEVELOPER_DIR=$(DEVELOPER_DIR) bash -o pipefail -c 'swift test 2>&1 | grep -E "Executed|error:"'

icon: ## assets/icon.svg から AppIcon.icns を生成 (要 librsvg)
	rm -rf dist/AppIcon.iconset
	mkdir -p dist/AppIcon.iconset
	for s in 16 32 128 256 512; do \
	  rsvg-convert -w $$s -h $$s assets/icon.svg -o dist/AppIcon.iconset/icon_$${s}x$${s}.png; \
	  rsvg-convert -w $$((s*2)) -h $$((s*2)) assets/icon.svg -o dist/AppIcon.iconset/icon_$${s}x$${s}@2x.png; \
	done
	iconutil -c icns dist/AppIcon.iconset -o assets/AppIcon.icns
	@echo "generated: assets/AppIcon.icns"
