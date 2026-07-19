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
