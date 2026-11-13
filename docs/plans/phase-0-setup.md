---
type: "plan"
phase: 0
status: "done"
tags:
  - "plan/phase-0"
---
# Phase 0 · Setup

Goal: a project every later phase can build on. Nothing here computes or measures anything.

| # | Task | Status |
|---|---|---|
| 1 | `project.yml` (XcodeGen): app target `Resoniq`, iOS 26, Swift 6, portrait, dark only; `make project` generates the project | done |
| 2 | `ResoniqKit` package with the six targets from [ARCHITECTURE.md](../ARCHITECTURE.md), each with a test target, building for iOS 26 and macOS 15 | done |
| 3 | Move `design/swift/ResoniqTheme.swift` into `ResoniqDesign`, make it compile, add secondary button, text link, icon button and caps-label styles from the design system | done |
| 4 | Bundle Instrument Sans and IBM Plex Mono (OFL, with licence files) in `ResoniqDesign` and register them at launch | done |
| 5 | App icon from `design/brand/AppIcon-1024.png`; accent colour and launch background `ink` | done |
| 6 | Tab shell: Diagnose · Measure · Optimize as in [V3Diagnose](../../design/screens/V3Diagnose.dc.html), each tab an empty screen with the room and system switcher | done |
| 7 | Privacy strings for microphone and camera in the words of the design system's Voice section | done |
| 8 | `Makefile`: `project`, `build`, `test` (Mac `swift test`), `run` (simulator) | done |
| 9 | CI: GitHub Actions running `swift test` and a simulator build on pull requests | done |

Done when: `make test` passes, `make build` succeeds for an iOS simulator, and a simulator screenshot of the
launched app shows the tab bar matching the mockup.

## Notes

- Task 3: the theme is split into `Tokens/` and `Components/` in `ResoniqDesign`; the tab bar, the switcher and
  the icons were added there too, because the shell needs them. See [ResoniqDesign](../modules/ResoniqDesign.md).
- Task 4: static faces, not the variable fonts, registered in code from the package bundle.
- Task 6: verified in the simulator on all three tabs (`make run TAB=measure`). The switcher and the Settings
  button have no target screen yet; "Rescan" on Optimize comes with phase 4.
- Task 8: `make` uses the one booted simulator and never creates another.
- Task 9: the workflow uses the `macos-26` runner; both jobs passed on pull request #2.
