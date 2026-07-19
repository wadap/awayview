.PHONY: install uninstall reload status logs check

install:   ; ./install.sh install
uninstall: ; ./install.sh uninstall
reload:    ; ./install.sh reload
status:    ; ./install.sh status
logs:      ; ./install.sh logs

check: ## zsh構文チェック
	zsh -n bin/screenshare-res-watch.zsh
	zsh -n install.sh
	@echo "syntax ok"
