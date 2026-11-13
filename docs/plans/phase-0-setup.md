---
type: "plan"
phase: 0
status: "active"
tags:
  - "plan/phase-0"
---
# Phase 0 · Setup

Goal: a project every later phase can build on. Nothing here computes or measures anything.

| # | Task | Status |
|---|---|---|
| 1 | `project.yml` (XcodeGen): app target `Resoniq`, iOS 26, Swift 6, portrait, dark only; `make project` generates the project | todo |
| 2 | `ResoniqKit` package with the six targets from [ARCHITECTURE.md](../ARCHITECTURE.md), each with a test target, building for iOS 26 and macOS 15 | todo |
| 3 | Move `design/swift/ResoniqTheme.swift` into `ResoniqDesign`, make it compile, add secondary button, text link, icon button and caps-label styles from the design system | todo |
| 4 | Bundle Instrument Sans and IBM Plex Mono (OFL, with licence files) in `ResoniqDesign` and register them at launch | todo |
| 5 | App icon from `design/brand/AppIcon-1024.png`; accent colour and launch background `ink` | todo |
| 6 | Tab shell: Diagnose · Measure · Optimize as in [V3Diagnose](../../design/screens/V3Diagnose.dc.html), each tab an empty screen with the room and system switcher | todo |
| 7 | Privacy strings for microphone and camera in the words of the design system's Voice section | todo |
| 8 | `Makefile`: `project`, `build`, `test` (Mac `swift test`), `run` (simulator) | todo |
| 9 | CI: GitHub Actions running `swift test` and a simulator build on pull requests | todo |

Done when: `make test` passes, `make build` succeeds for an iOS simulator, and a simulator screenshot of the
launched app shows the tab bar matching the mockup.
