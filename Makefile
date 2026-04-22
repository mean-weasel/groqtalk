APP_NAME := GroqTalk
BUNDLE_ID := com.neonwatty.GroqTalk
SCHEME := $(APP_NAME)
CONFIG := Debug
BUILD_DIR := $(shell xcodebuild -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' -showBuildSettings 2>/dev/null | grep -m1 BUILT_PRODUCTS_DIR | awk '{print $$NF}')
APP_PATH := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: build run start stop restart install uninstall clean test

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
	@tccutil reset Accessibility $(BUNDLE_ID) 2>/dev/null || true
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(APP_PATH) /Applications/$(APP_NAME).app
	@echo "Installed to /Applications/$(APP_NAME).app"
	@echo "First launch will prompt for Accessibility — grant it once."

uninstall:
	-@pkill -x $(APP_NAME) 2>/dev/null
	rm -rf /Applications/$(APP_NAME).app
	@echo "Removed /Applications/$(APP_NAME).app"

test:
	xcodebuild test -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' 2>&1 | tail -5

clean:
	xcodebuild -scheme $(SCHEME) clean 2>&1 | tail -3
