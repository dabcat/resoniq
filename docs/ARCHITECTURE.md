---
type: "architecture"
tags:
  - "architecture"
---
# Architecture

Resoniq is one iOS app target on top of one local Swift package, `ResoniqKit`. Everything that can be decided
without a screen (signals, DSP, findings, room geometry, placement) lives in the package and is tested on the
Mac. The app target holds SwiftUI screens, the audio and AR sessions' wiring, and nothing that computes a result.

## Layout

```
project.yml              XcodeGen spec; Resoniq.xcodeproj is generated (`make project`) and not committed
Resoniq/                 app target: App/, Features/{Intro,Diagnose,Measure,Optimize,Settings}/, Resources/
ResoniqKit/              Swift package, one target per module below
design/                  design spec, system, tokens, brand, screens/ (HTML mockups used as templates)
docs/                    this vault
```

## Modules

| Target | Spec module | Depends on | Holds |
|---|---|---|---|
| [ResoniqDesign](modules/ResoniqDesign.md) | E | — | Tokens, fonts, shared SwiftUI components (panel, buttons, portrait, curve, room plan) |
| [ResoniqDSP](modules/ResoniqDSP.md) | A | — | Pure maths on sample buffers: test signals, FFT, frequency response, THD, noise floor, clipping |
| [ResoniqAudio](modules/ResoniqAudio.md) | A | DSP | AVAudioSession and AVAudioEngine: play a signal, record it, hand buffers to DSP; measurement sessions |
| [ResoniqDiagnostics](modules/ResoniqDiagnostics.md) | B | DSP | Findings, evidence tags, rules over DSP results, SoundAnalysis noise gate, Core ML classifiers |
| [ResoniqRoom](modules/ResoniqRoom.md) | C, D | — | Codable room model, RoomPlan conversion, manual layout, placement recommendations |
| [ResoniqStore](modules/ResoniqStore.md) | E | Diagnostics, Room | SwiftData models (rooms, systems, sessions) and files for audio and scans |

The app depends on all of them. No module imports the app, SwiftUI appears only in `ResoniqDesign`.

## Decisions

| Decision | Why |
|---|---|
| iOS 26 minimum, Swift 6 language mode, strict concurrency | Current SwiftData, RoomPlan and Swift Testing without back-deployment work. Revisit at phase 4 if a RoomPlan API needs iOS 27. |
| Package also builds for macOS 15 | `swift test` on the Mac runs in seconds; the simulator cannot play or record a measurement anyway. |
| DSP is separate from audio I/O | DSP takes and returns plain `[Float]` buffers, so every algorithm is tested with synthetic signals whose answer is known. |
| XcodeGen, project not committed | The project file is reviewable as `project.yml` and never conflicts between agent branches. |
| Dark theme only, bundled Instrument Sans and IBM Plex Mono | [Design system](../design/DESIGN_SYSTEM.md). Both fonts are OFL. |
| Tabs: Diagnose · Measure · Optimize | The current mockups ([design/screens](../design/screens/README.md)); Settings is an icon button on Diagnose. |
| DSP first, AI later | No dataset of defective speakers exists yet. Until phase 6, findings come from DSP rules, and SoundAnalysis only gates noisy measurements. Classifiers sit behind a protocol so they can be added without touching callers. |
| No health scores, every finding carries an evidence tag | [Design system, Evidence tags](../design/DESIGN_SYSTEM.md); spec §8 forbids claiming a confirmed defect. |

## Rules that follow

- A threshold, band limit or conversion has one definition, in the Kit. Screens read results; they never recompute.
- A screen is built from its mockup in `design/screens/` and uses `ResoniqDesign` tokens; a literal colour, font
  size or radius in a feature view is a defect.
- RoomPlan and ARKit work starts from [the RoomScan reference](reference/iosar-roomplan-arkit.md).
