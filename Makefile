APP_NAME := GroqTalk
BUNDLE_ID := com.neonwatty.GroqTalk
SCHEME := $(APP_NAME)
CONFIG := Debug
BUILD_DIR := $(shell xcodebuild -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' -showBuildSettings 2>/dev/null | grep -m1 BUILT_PRODUCTS_DIR | awk '{print $$NF}')
APP_PATH := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build run start stop restart install uninstall clean test test-ui test-cross-app test-app-smoke test-cleanup-quality qa

build:
	xcodebuild -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' build 2>&1 | tail -3

run: build
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.5
	open $(APP_PATH)

start:
	@open /Applications/$(APP_NAME).app 2>/dev/null || open $(APP_PATH) 2>/dev/null || echo "Run 'make install' or 'make build' first"

stop:
	@pkill -x $(APP_NAME) 2>/dev/null && echo "Stopped" || echo "Not running"

restart: stop
	@sleep 0.5
	@open /Applications/$(APP_NAME).app 2>/dev/null || open $(APP_PATH)

install: build
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.5
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_PATH) /Applications/$(APP_NAME).app
	@echo "Installed to /Applications/$(APP_NAME).app"

uninstall:
	-@pkill -x $(APP_NAME) 2>/dev/null
	rm -rf /Applications/$(APP_NAME).app
	@echo "Removed /Applications/$(APP_NAME).app"

test:
	xcodebuild test -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' 2>&1 | tail -5

test-ui:
	xcodebuild test -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' -only-testing:GroqTalkUITests 2>&1 | tail -5

test-cross-app:
	swift tests/test_async_paste.swift
	swift tests/test_skylight_paste.swift
	swift tests/test_cross_app_async_paste.swift

test-app-smoke:
	swift tests/test_app_mock_async_paste.swift

test-cleanup-quality:
	swift tests/test_cleanup_quality.swift

qa:
	@echo "=== Unit tests ==="
	xcodebuild test -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' 2>&1 | grep -E "Executed|TEST (SUCCEEDED|FAILED)"
	@echo ""
	@echo "=== Async paste integration test ==="
	-@pkill -x $(APP_NAME) 2>/dev/null; sleep 0.5
	swift tests/test_async_paste.swift
	@echo ""
	@echo "=== SkyLight background paste test ==="
	swift tests/test_skylight_paste.swift

clean:
	xcodebuild -scheme $(SCHEME) clean 2>&1 | tail -3
