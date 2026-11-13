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

.PHONY: help project test build run screenshot clean

help: ## List the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | expand -t 14

project: ## Generate Resoniq.xcodeproj from project.yml
	xcodegen generate --quiet

test: ## Run the ResoniqKit tests on the Mac
	swift test --package-path $(PKG)

build: project ## Build the app for the iOS simulator
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'generic/platform=iOS Simulator' -derivedDataPath $(DD) \
		CODE_SIGNING_ALLOWED=NO build

run: build ## Install and launch the app in the simulator
	xcrun simctl install $(SIM) $(APP)
	xcrun simctl terminate $(SIM) $(BUNDLE) 2>/dev/null || true
	xcrun simctl launch $(SIM) $(BUNDLE) -initialTab $(TAB)

screenshot: ## Save a screenshot of the simulator to .build/screenshot.png
	xcrun simctl io $(SIM) screenshot .build/screenshot.png

clean: ## Remove build output and the generated project
	rm -rf .build $(PKG)/.build $(PROJECT)
