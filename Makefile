.PHONY: lint test

lint:
	bash -n bin/av-scan-scheduler bin/av-scan-scheduler-configure-webhook bin/av-scan-scheduler-runner install.sh uninstall.sh tests/test.sh
	shellcheck bin/av-scan-scheduler bin/av-scan-scheduler-configure-webhook bin/av-scan-scheduler-runner install.sh uninstall.sh tests/test.sh
	plutil -lint launchd/io.github.tetsuroando.av-scan-scheduler.plist

test:
	./tests/test.sh
