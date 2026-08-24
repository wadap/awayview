.PHONY: build install uninstall check test icon release publish

# swift test に XCTest が要るため Xcode toolchain を明示 (CLT には無い)
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
APP     = dist/AwayView.app
APP_DST = $(HOME)/Applications/AwayView.app
SIGN_ID ?= $(shell security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $$2; exit}')
NOTARY_PROFILE ?= awayview-notary
# バージョンの正は Info.plist。VERSION= を明示した場合は release で一致を検証する
PLIST_VERSION = $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
VERSION ?= $(PLIST_VERSION)
ZIP = dist/AwayView-$(VERSION).zip

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

release: ## 署名 + notarize + staple + 配布 zip (版は Info.plist から)
	@test "$(VERSION)" = "$(PLIST_VERSION)" || { \
	  echo "error: VERSION=$(VERSION) but Info.plist says $(PLIST_VERSION)"; \
	  echo "       バージョンの正は Info.plist。先にそちらを更新すること"; exit 1; }
	@test -n "$(SIGN_ID)" || { echo "error: Developer ID Application identity not found"; exit 1; }
	$(MAKE) test
	$(MAKE) build
	codesign --force --options runtime --timestamp --sign "$(SIGN_ID)" $(APP)
	codesign --verify --strict --verbose=2 $(APP)
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	xcrun notarytool submit $(ZIP) --keychain-profile $(NOTARY_PROFILE) --wait --timeout 30m
	xcrun stapler staple $(APP)
	rm -f $(ZIP)
	ditto -c -k --keepParent $(APP) $(ZIP)
	spctl -a -vv --type execute $(APP)
	@echo "release artifact: $(ZIP)"

publish: ## GitHub Release 作成 (版は Info.plist から、release 実行後に)
	@test "$(VERSION)" = "$(PLIST_VERSION)" || { echo "error: VERSION=$(VERSION) but Info.plist says $(PLIST_VERSION)"; exit 1; }
	@test -f $(ZIP) || { echo "error: $(ZIP) not found. run make release first"; exit 1; }
	gh release create v$(VERSION) $(ZIP) --title "AwayView v$(VERSION)" --generate-notes --target $$(git rev-parse HEAD)
