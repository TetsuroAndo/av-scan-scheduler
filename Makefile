.PHONY: lint test

lint:
	bash -n bin/clamav-hook bin/clamav-hook-configure-webhook bin/clamav-hook-runner install.sh uninstall.sh tests/test.sh
	shellcheck bin/clamav-hook bin/clamav-hook-configure-webhook bin/clamav-hook-runner install.sh uninstall.sh tests/test.sh
	plutil -lint launchd/io.github.tetsuroando.clamav-hook.plist

test:
	./tests/test.sh
