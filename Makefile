SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

APP_NAME := GroqTalk
BUNDLE_ID := com.neonwatty.GroqTalk
SCHEME := $(APP_NAME)
CONFIG := Debug
LOCAL_SIGN_IDENTITY := GroqTalk Local Code Signing
LOCAL_SIGN_KEYCHAIN := $(HOME)/Library/Keychains/groqtalk-codesign.keychain-db
LOCAL_SIGN_KEYCHAIN_PASSWORD ?= groqtalk-local-codesign
DEFAULT_SIGN_IDENTITY := $(shell security find-identity -p codesigning "$(LOCAL_SIGN_KEYCHAIN)" 2>/dev/null | grep -q '"$(LOCAL_SIGN_IDENTITY)"' && echo "$(LOCAL_SIGN_IDENTITY)" || echo "-")
SIGN_IDENTITY ?= $(DEFAULT_SIGN_IDENTITY)
DEVELOPMENT_TEAM ?=

ifeq ($(SIGN_IDENTITY),-)
SIGNING_FLAGS := CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO
else ifeq ($(SIGN_IDENTITY),$(LOCAL_SIGN_IDENTITY))
SIGNING_FLAGS := CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) CODE_SIGN_STYLE=Manual ENABLE_HARDENED_RUNTIME=NO
else
SIGNING_FLAGS := CODE_SIGN_IDENTITY="$(SIGN_IDENTITY)" DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) CODE_SIGN_STYLE=Manual
endif

BUILD_DIR := $(shell xcodebuild -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' -showBuildSettings 2>/dev/null | grep -m1 BUILT_PRODUCTS_DIR | awk '{print $$NF}')
APP_PATH := $(BUILD_DIR)/$(APP_NAME).app

.PHONY: setup-local-signing setup-release-secrets enable-xctest-developer-mode build build-warnings-as-errors unlock-local-signing-keychain run start stop restart install uninstall clean test test-ui test-provider-qa test-provider-qa-live test-local-transcription-e2e test-microphone-live test-cross-app test-app-smoke test-paste-real qa-paste test-cleanup-quality qa qa-ci qa-local

setup-local-signing:
	LOCAL_SIGN_KEYCHAIN_PASSWORD="$(LOCAL_SIGN_KEYCHAIN_PASSWORD)" scripts/setup-local-signing.sh

setup-release-secrets:
	scripts/set-release-secrets.sh

enable-xctest-developer-mode:
	sudo DevToolsSecurity -enable
	@if ! id -Gn "$$USER" | tr ' ' '\n' | grep -qx '_developer'; then \
		sudo dseditgroup -o edit -a "$$USER" -t user _developer; \
	fi

unlock-local-signing-keychain:
	@if [ "$(SIGN_IDENTITY)" = "$(LOCAL_SIGN_IDENTITY)" ] && [ -f "$(LOCAL_SIGN_KEYCHAIN)" ]; then \
		security unlock-keychain -p "$(LOCAL_SIGN_KEYCHAIN_PASSWORD)" "$(LOCAL_SIGN_KEYCHAIN)"; \
	fi

build: unlock-local-signing-keychain
	@if [ -d "$(APP_PATH)" ]; then find "$(APP_PATH)" -name '*.cstemp*' -delete; fi
	@tmp=$$(mktemp); \
	xcodebuild -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' $(SIGNING_FLAGS) build >"$$tmp" 2>&1; \
	status=$$?; tail -3 "$$tmp"; \
	if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$$tmp"; then status=1; fi; \
	rm -f "$$tmp"; exit $$status

build-warnings-as-errors:
	@tmp=$$(mktemp); \
	xcodebuild build -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' OTHER_SWIFT_FLAGS='-warnings-as-errors' >"$$tmp" 2>&1; \
	status=$$?; tail -3 "$$tmp"; \
	if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$$tmp"; then status=1; fi; \
	rm -f "$$tmp"; exit $$status

run:
	@identity=$$(security find-identity -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: Mean Weasel LLC (B3A6AN2HA4)\)".*/\1/p' | head -1); \
	if [ -z "$$identity" ]; then \
		$(MAKE) setup-local-signing; \
		identity="$(LOCAL_SIGN_IDENTITY)"; \
	fi; \
	$(MAKE) install SIGN_IDENTITY="$$identity" DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)"
	open /Applications/$(APP_NAME).app

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
	@tmp=$$(mktemp); \
	xcodebuild test -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' -only-testing:GroqTalkTests >"$$tmp" 2>&1; \
	status=$$?; tail -5 "$$tmp"; \
	if ! grep -q '\*\* TEST SUCCEEDED \*\*' "$$tmp"; then status=1; fi; \
	rm -f "$$tmp"; exit $$status

test-ui:
	@tmp=$$(mktemp); \
	xcodebuild test -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' -only-testing:GroqTalkUITests >"$$tmp" 2>&1; \
	status=$$?; tail -5 "$$tmp"; \
	if ! grep -q '\*\* TEST SUCCEEDED \*\*' "$$tmp"; then status=1; fi; \
	rm -f "$$tmp"; exit $$status

test-provider-qa:
	@tmp=$$(mktemp); \
	xcodebuild test -scheme $(SCHEME) -configuration $(CONFIG) -destination 'platform=macOS' \
		-only-testing:GroqTalkUITests/GroqTalkUITests/testProviderQADefaultsToGroqPreset \
		-only-testing:GroqTalkUITests/GroqTalkUITests/testProviderQALocalWhisperPresetShowsExpectedSettings \
		-only-testing:GroqTalkUITests/GroqTalkUITests/testProviderQAInvalidCustomBaseURLShowsValidationStatus \
		-only-testing:GroqTalkUITests/GroqTalkUITests/testProviderQACustomProviderPersistsAcrossRelaunch >"$$tmp" 2>&1; \
	status=$$?; tail -8 "$$tmp"; \
	if ! grep -q '\*\* TEST SUCCEEDED \*\*' "$$tmp"; then status=1; fi; \
	rm -f "$$tmp"; exit $$status

test-provider-qa-live:
	SCHEME="$(SCHEME)" CONFIG="$(CONFIG)" scripts/run-live-groq-provider-qa-xcuitest.sh

test-local-transcription-e2e:
	SCHEME="$(SCHEME)" CONFIG="$(CONFIG)" scripts/run-local-transcription-e2e-xcuitest.sh

test-microphone-live:
	RUN_LIVE_MICROPHONE_TESTS=1 SCHEME="$(SCHEME)" CONFIG="$(CONFIG)" scripts/run-live-microphone-qa.sh

test-cross-app:
	swift tests/test_async_paste.swift
	swift tests/test_skylight_paste.swift
	swift tests/test_cross_app_async_paste.swift

test-app-smoke:
	swift tests/test_app_mock_async_paste.swift

test-paste-real: install
	swift tests/test_app_mock_async_paste.swift

qa-paste: test-paste-real

test-cleanup-quality:
	swift tests/test_cleanup_quality.swift

qa-ci:
	@echo "=== Warnings-as-errors build ==="
	$(MAKE) build-warnings-as-errors
	@echo ""
	@echo "=== Unit tests ==="
	$(MAKE) test
	@echo ""
	@echo "=== UI feedback tests ==="
	$(MAKE) test-ui

qa-local: install
	@echo "=== Installed app smoke test ==="
	$(MAKE) test-paste-real
	@echo ""
	@echo "=== Desktop paste integration tests ==="
	$(MAKE) test-cross-app
	@echo ""
	@echo "Run 'make test-cleanup-quality' separately when a local Groq API key is configured."

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
