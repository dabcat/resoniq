# Resoniq task runner. `make help` lists the targets.

PROJECT := Resoniq.xcodeproj
SCHEME  := Resoniq
PKG     := ResoniqKit
BUNDLE  := com.matovic.resoniq
DD      := .build/dd
APP     := $(DD)/Build/Products/Debug-iphonesimulator/Resoniq.app

# One simulator is used for everything: the booted one, or the one named here (make run SIM=<name or UDID>).
# Nothing in this file creates a simulator.
SIM ?= booted

# Debug builds can open on another tab: make run TAB=measure
TAB ?= diagnose
# …or on one screen in a fixed state: make run SCREEN=listening (names in Resoniq/App/DebugScreens*.swift)
SCREEN ?=

# A phone build is signed. The team is not in the repository: TEAM=… on the command line, or DEVELOPMENT_TEAM in
# the gitignored Config/Signing.local.xcconfig, or the first Apple Development certificate in the keychain.
SIGNING_LOCAL := Config/Signing.local.xcconfig
TEAM ?= $(shell sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]\{10\}\).*/\1/p' $(SIGNING_LOCAL) 2>/dev/null | head -1)
ifeq ($(strip $(TEAM)),)
TEAM := $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject -nameopt multiline 2>/dev/null | sed -n 's/^[[:space:]]*organizationalUnitName[[:space:]]*=[[:space:]]*//p' | head -1)
endif
# Phone builds are Release unless asked otherwise: what is checked on a device should be what a user runs.
CONFIG ?= Release
DEVICE_APP = $(DD)-device/Build/Products/$(CONFIG)-iphoneos/Resoniq.app

.PHONY: help project test build build-release run screenshot clean device-list build-device install phone

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | expand -t 14

project: ## Generate Resoniq.xcodeproj from project.yml
	xcodegen generate --quiet

# One target at a time: in one run the DSP suites' heavy synchronous work starved the audio sessions' tests of
# threads on a three-core CI runner, and they ran past their time limits.
TEST_TARGETS := ResoniqDesignTests ResoniqDSPTests ResoniqAudioTests ResoniqDiagnosticsTests ResoniqRoomTests ResoniqStoreTests

test: ## Run the ResoniqKit tests on the Mac
	swift build --package-path $(PKG) --build-tests
	@for target in $(TEST_TARGETS); do \
		echo "== $$target"; \
		swift test --package-path $(PKG) --skip-build --filter "^$$target\." || exit 1; \
	done

build: project ## Build the app for the iOS simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath $(DD) \
		CODE_SIGNING_ALLOWED=NO build

build-release: project ## Build the Release configuration for the simulator (debug-only code must compile out)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath $(DD)-release \
		CODE_SIGNING_ALLOWED=NO build

run: build ## Install and launch the app in the simulator
	xcrun simctl install $(SIM) $(APP)
	xcrun simctl terminate $(SIM) $(BUNDLE) 2>/dev/null || true
	xcrun simctl launch $(SIM) $(BUNDLE) -initialTab $(TAB) $(if $(SCREEN),-screen $(SCREEN))

screenshot: ## Save a screenshot of the simulator to .build/screenshot.png
	xcrun simctl io $(SIM) screenshot .build/screenshot.png

device-list: ## Show connected phones and their identifiers
	xcrun devicectl list devices

build-device: project ## Signed build for a phone (CONFIG=Release by default)
	@test -n "$(TEAM)" || (echo "No signing team found. Put DEVELOPMENT_TEAM = <id> in $(SIGNING_LOCAL)."; exit 1)
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination 'generic/platform=iOS' -allowProvisioningUpdates \
		-derivedDataPath $(DD)-device DEVELOPMENT_TEAM=$(TEAM)

install: build-device ## Build and install on a phone: make install DEVICE=<identifier>
	@test -n "$(DEVICE)" || (echo "usage: make install DEVICE=<identifier>   (see: make device-list)"; exit 1)
	xcrun devicectl device install app --device $(DEVICE) $(DEVICE_APP)

phone: install ## Build, install and launch on a phone: make phone DEVICE=<identifier>
	xcrun devicectl device process launch --device $(DEVICE) $(BUNDLE)

clean: ## Remove build output and the generated project
	rm -rf .build $(PKG)/.build $(PROJECT)
