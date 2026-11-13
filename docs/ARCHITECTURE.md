---
type: "architecture"
tags:
  - "architecture"
---
# Architecture

Resoniq is one iOS app target on top of one local Swift package, `ResoniqKit`. Everything that can be decided
without a screen (signals, DSP, findings, room geometry, placement) lives in the package and is tested on the
Mac. The app target holds SwiftUI screens, the audio, scan and AR sessions' wiring, and nothing that computes a
result.

## Layout

```
project.yml              XcodeGen spec; Resoniq.xcodeproj is generated (`make project`) and not committed
Makefile                 make test | build | run | screenshot (see the README)
Config/                  Signing.xcconfig; Signing.local.xcconfig (yours, ignored by git)
Resoniq/                 app target, no test target
  App/                   entry, composition, tab shell, AudioEnvironment, AppLifecycle; Debug: DebugScreens*, fixtures, gallery
  Features/              Diagnose, Measure, Optimize (with Scan/ and AR/), Intro, Settings, Rooms
  Resources/             Info.plist, asset catalog
ResoniqKit/              Swift package
  Sources/               one target per module below
  Tests/                 one test target per module, run on the Mac
design/                  design spec, system, tokens, brand, screens/ (HTML mockups used as templates)
docs/                    this vault
.github/workflows/ci.yml Kit tests and a simulator build on each pull request
.claude/skills/          resoniq-stack: the toolbox
```

## Modules

Dependencies are as in `ResoniqKit/Package.swift`; the app depends on all six.

| Target | Spec module | Depends on | Holds |
|---|---|---|---|
| [ResoniqDesign](modules/ResoniqDesign.md) | E | — | Tokens, bundled fonts, icons and the shared SwiftUI components: portraits, curves, spots, room plan and editor, AR cards, trackers, chips |
| [ResoniqDSP](modules/ResoniqDSP.md) | A | — | Pure maths on sample buffers: test signals and the measurement sweep, FFT, impulse and frequency response, distortion, noise floor, clipping, recording verdicts, decay, response averaging |
| [ResoniqAudio](modules/ResoniqAudio.md) | A | DSP | `AVAudioSession` and `AVAudioEngine` behind `AudioIO`; the speaker test and the three-spot seat measurement (shared run machinery), live spectrum, hold-to-hear tone, microphone permission, stillness, simulated IO and room; the session's words |
| [ResoniqDiagnostics](modules/ResoniqDiagnostics.md) | B | DSP | Findings and evidence tags from runs and spots, the portrait's shape, the seat result and before and after comparison, SoundAnalysis naming of interference, log-mel features and Core ML slots for defect and anomaly models; the words of every finding |
| [ResoniqRoom](modules/ResoniqRoom.md) | C, D | — | The room model and manual room, RoomPlan conversion, layout guess, geometry and edits, room modes, placement advice, AR move guidance and alignment; the words of scan and AR |
| [ResoniqStore](modules/ResoniqStore.md) | E | Diagnostics, Room | SwiftData schema (rooms, systems, speaker tests, seat measurements, optimisations; migration V1 to V2), scan files, counts and delete-all, the intro flag |

`ResoniqDesign` is still the only module that imports SwiftUI: `grep -rn "import SwiftUI" ResoniqKit/Sources`
finds 36 files, all under `ResoniqDesign/`. The other modules import Foundation, Accelerate, AVFoundation,
CoreML, CoreMotion, SoundAnalysis, SwiftData, and RoomPlan inside `#if canImport(RoomPlan)`. No module imports
the app. The app's own layer is described in [App](modules/App.md) and below.

## The app layer

- **One coordinator per tab** (`DiagnoseCoordinator`, `MeasureCoordinator`, `OptimizeCoordinator`) owns what is
  on screen, what is kept and what comes next.
- **One flow object per measurement** (`DiagnoseFlow`, `SeatFlow`) follows a Kit session's state and progress,
  analyses when the last run or spot is in, and hands the report to the coordinator.
- **The Kit decides, screens show.** `…Display.swift` and `…States.swift` files map Kit values onto component
  inputs and write no sentence. Texts that depend on a result or a session state live in the Kit; the app's
  `…Text.swift` files hold copy only a screen uses.
- **`AudioEnvironment` chooses real or simulated audio** (the real engine on a device, `SimulatedAudioIO` in the
  simulator or with `-simulatedAudio YES`). The scan and AR have the same seam (`OptimizeSources`), with scripted
  sources for the simulator.
- **`AppLifecycle`** is the one place that stops sound and sensors when the scene leaves the foreground.
- **Debug screens** (`make run SCREEN=<name>`) show any screen in a fixed state from Kit fixtures; the names are
  listed in `Resoniq/App/DebugScreens*.swift` and in [App](modules/App.md).

## Decisions

| Decision | Why |
|---|---|
| iOS 26 minimum, Swift 6 language mode, strict concurrency | Current SwiftData, RoomPlan and Swift Testing without back-deployment work. |
| Package also builds for macOS 15 | `swift test` on the Mac runs in seconds; the simulator cannot play or record a measurement anyway. |
| DSP is separate from audio I/O | DSP takes and returns plain `[Float]` buffers, so every algorithm is tested with synthetic signals whose answer is known. |
| XcodeGen, project not committed | The project file is reviewable as `project.yml` and never conflicts between agent branches. |
| Dark theme only, bundled Instrument Sans and IBM Plex Mono | [Design system](../design/DESIGN_SYSTEM.md). Both fonts are OFL; their licences are shown in Settings. |
| Tabs: Diagnose · Measure · Optimize | The current mockups ([design/screens](../design/screens/README.md)); Settings is an icon button on Diagnose. |
| DSP first, AI second | No dataset of defective speakers exists. Findings come from DSP rules; SoundAnalysis only names what interfered; the Core ML defect and anomaly models are empty slots behind a protocol, and model lines are kept apart from findings (`SpeakerReport.modelFindings`). |
| No health scores, every finding carries an evidence tag | [Design system, Evidence tags](../design/DESIGN_SYSTEM.md); spec §8 forbids claiming a confirmed defect. |
| Findings hedge in their headlines ("Possible buzz"), though the mockups do not | A suspected defect is never stated as confirmed; the even statement also says what was not checked. |
| One sweep for every measurement (10 Hz to 22 kHz, 4 s, safe level) | Reports the response from 20 Hz; 4 s gives distortion its accuracy. The 10 Hz start is unconfirmed for vented speakers. |
| One level convention, dBFS RMS; the on-screen "dB" is an estimate with one named offset | The microphone is not calibrated; screens say levels are approximate. |
| Every wait is counted in captured samples | A test on simulated IO runs as fast as the arithmetic and gives the same answer as in real time. |
| The speaker test and the seat measurement share one run machinery (`RunPerformer`) | Pause on noise, splice, check and repeat were proven once; the second session only chooses what to play when. |
| The output route is checked before any sound | With nothing connected the phone plays through its receiver, and the app would diagnose the phone. |
| Reports are stored as JSON `Data` with a schema version; the schema is versioned with a migration | A stored report from another version fails with an error instead of crashing; a model change is a new schema version with a stage and a test. |
| A layout is a snapshot copied into each seat measurement | A comparison must know where the speakers stood when it was measured. |
| RoomPlan cannot see loudspeakers, so a scan's layout is a guess the user confirms | `LayoutGuess` marks positions as guessed; Confirm layout exists to correct them. |
| The speaker's position in AR is marked by the user, not tracked | ARKit does not track an arbitrary loudspeaker; the person points a reticle at it and judges the turn by eye. |
| Scan, AR and audio sit behind protocols with scripted or simulated sources | The simulator cannot run RoomPlan, ARKit or a loop from speaker to microphone; every flow still runs unattended. |
| The app target has no tests; decisions live in the Kit | What the Mac can test, it tests; app code only maps and navigates. Anything that needs a microphone, LiDAR or AR is verified on a device ([checklist](device-checklist.md)). |
| Texts that depend on a result live in the Kit | One definition, tested for the wording rules (hedging, no scores, units). |
| Nothing leaves the device; scan files stay in Application Support and in the backup | A scan takes a walk round the room to recreate. Recordings are not stored. |

## Rules that follow

- A threshold, band limit or conversion has one definition, in the Kit. Screens read results; they never recompute.
- A screen is built from its mockup in `design/screens/` and uses `ResoniqDesign` tokens; a literal colour, font
  size or radius in a feature view is a defect.
- RoomPlan and ARKit work starts from [the RoomScan reference](reference/iosar-roomplan-arkit.md).
