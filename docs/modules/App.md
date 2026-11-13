---
type: "module"
spec_module: "app"
phase: 6
status: "active"
tags:
  - "module"
  - "app"
---
# App target

The `Resoniq` target: SwiftUI screens, the wiring that follows a Kit session, and the debug entries. It decides nothing about sound, rooms or findings; the Kit does ([ARCHITECTURE.md](../ARCHITECTURE.md)). Main-actor by default (`SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` in `project.yml`), so a type used as a generic argument (a tab enum, a route) is marked `nonisolated`. Depends on all six Kit modules. There is **no test target**: anything worth testing is a plain function in the Kit.

Paths are relative to `Resoniq/`.

## Folders

| Folder | Holds |
|---|---|
| `App/` | `ResoniqApp.swift` (entry; registers fonts, makes the composition), `AppComposition.swift`, `RootView.swift` (tab shell), `TabHome.swift` (the frame every home screen shares), `AudioEnvironment.swift`, `AppLifecycle.swift`, and, Debug only, `DebugScreens*.swift`, `*Fixtures.swift`, `ComponentGallery.swift` |
| `Features/Diagnose/` | Aim, Listening, Paused, Result, Finding, Diagnose home, the states with no mockup (`DiagnoseStates.swift`), `DiagnoseCoordinator`, `DiagnoseFlow`, `DiagnosticsDisplay.swift` |
| `Features/Measure/` | Measure home, Sit and aim, Three spots, The numbers, Watch the sound live, `MeasureCoordinator`, `SeatFlow`, `SeatDisplay.swift`, `SeatStates.swift` |
| `Features/Optimize/` | Optimize home, Confirm layout (`LayoutScreen`, `Room3DView`), manual room entry, Before and after (`VerifyScreen`), `OptimizeCoordinator`, `OptimizeRules`, `RoomDisplay.swift`; `Scan/` (RoomPlan) and `AR/` (ARKit and RealityKit) |
| `Features/Intro/` | The three intro screens and their illustrations |
| `Features/Settings/` | Settings: what is stored, delete data, the intro again, About, licences |
| `Features/Rooms/` | The rooms and systems sheet behind the switcher |
| `Resources/` | `Info.plist` (camera and microphone strings), the asset catalog |

## How a flow is built

1. **One coordinator per tab** (`DiagnoseCoordinator`, `MeasureCoordinator`, `OptimizeCoordinator`; `@Observable`, `@MainActor`). It owns what is on screen (a full-screen cover, a pushed route), what was kept in the store and what comes next. Navigation and "keep or not" are its decisions, written as plain functions where they can be (`DiagnoseRules` in `Features/Diagnose/DiagnoseCoordinator.swift`, `OptimizeRules` in `Features/Optimize/OptimizeRules.swift`).
2. **One flow object per measurement** (`DiagnoseFlow`, `SeatFlow`). It owns a Kit session (`MeasurementSession`, `SeatMeasurementSession`), follows its `state` and `progress`, and when the last run or spot is in, analyses off the main actor and calls the Kit's diagnosis. It keeps nothing; the coordinator takes the finished report and saves it. `ComparisonMemory` (in `DiagnoseCoordinator.swift`) holds a kept test's runs for the session so the second speaker can be compared with the first.
3. **`…Display.swift` and `…States.swift` map Kit values onto component inputs** (`DiagnosticsDisplay.swift`, `SeatDisplay.swift`, `RoomDisplay.swift`). They write no sentence and compute no result; the only numbers are named display scales (`DisplayScale` in `DiagnosticsDisplay.swift`). Exhaustive switches over Kit enums live here: a new Kit case breaks them on purpose and is added in the same change.
4. **Screens take plain inputs.** A screen view takes display values and closures; a container reads the coordinator or the store and passes them in. That is what lets `DebugScreens` show any screen in a fixed state.
5. **Texts live in the Kit** where they depend on a result or a session state (`SessionText`, `DiagnosisText`, `SeatText`, `RoomText`, `ScanText`, `ARGuidanceText`, `StoreText`). The app's `DiagnoseText`, `MeasureText`, `OptimizeText`, `IntroText`, `SettingsText`, `RoomsText` hold copy only a screen uses.
6. **Sensors behind small protocols**, so the simulator runs everything: `AudioEnvironment` for audio, `OptimizeSources` (in `OptimizeCoordinator.swift`) for the scan (`RoomScanSource`) and AR (`ARGuidanceSource`, `ARGuidanceHaptics`). On a device the real ones (`LiveRoomScanSource` in `Optimize/Scan/RoomCaptureHost.swift`, `LiveARGuidanceSource`) are used; in the simulator `ScriptedRoomScanSource` and `ScriptedARGuidanceSource` act out a whole scan and a whole move. The port of RoomPlan and ARKit follows [the RoomScan reference](../reference/iosar-roomplan-arkit.md).

## Environment values

| Value | Defined in | Holds |
|---|---|---|
| `resoniqStore` | `App/AppComposition.swift:64` | The `ResoniqStore` (also `.modelContainer` for `@Query`) |
| `audioEnvironment` | `App/AudioEnvironment.swift:128` | `AudioEnvironment.current`: real engine, system permission and Core Motion on a device; `SimulatedAudioIO` in the simulator (`isSimulated`). One simulated speaker buzzes at about 70–110 Hz, the other is clean; the seat runs in a `SimulatedRoom` with a peak near 41 Hz and a dip near 61 Hz; the live spectrum hears a steady hiss |
| `appLifecycle` | `App/AppLifecycle.swift:27` | `AppLifecycle`: handlers registered once by each coordinator; `RootView` calls `sceneLeftForeground()` when the scene is not active, which cancels a running test or measurement and closes the scan and AR covers |
| `switchTab` | `App/RootView.swift:31` | A tab asks the shell to show another tab ("It's the room" leads to Optimize) |

The coordinators (`DiagnoseCoordinator`, `MeasureCoordinator`, `OptimizeCoordinator`) and `ComparisonMemory` are in the environment as observable objects (`appEnvironment(_:)`, `App/AppComposition.swift`). If the store cannot be opened the app shows `StoreUnavailableScreen` and nothing else.

## Debug entries (Debug builds only)

`make run` passes `-initialTab <tab>` (`TAB=diagnose|measure|optimize`) and `-screen <name>` (`SCREEN=<name>`). Other launch arguments are given to `xcrun simctl launch` by hand; the bundle id is `com.matovic.resoniq`.

| Argument | Read in | Effect |
|---|---|---|
| `-initialTab measure` | `App/RootView.swift` | Opens on that tab |
| `-screen <name>` | `App/RootView.swift` | Shows one screen in a fixed state instead of the tabs; names below |
| `-gallery YES` | `App/RootView.swift` | `ComponentGallery`: every component in every state |
| `-inMemoryStore YES` | `App/AppComposition.swift` | Starts with nothing stored, nothing written to disk |
| `-screen app-flow` | `App/AppComposition.swift` | The real Diagnose tab, in-memory store, simulated audio, already inside the test for the left speaker (not in a `names` list) |
| `-simulatedAudio YES` | `App/AudioEnvironment.swift` | On a device, use the simulated audio |
| `-simulatedNoise YES` | `App/AudioEnvironment.swift` | A burst of noise a few seconds into a run so Paused can be seen |
| `-autostart YES` | `Features/Diagnose/DiagnoseTab.swift`, `Features/Measure/MeasureTab.swift`, `App/DebugScreens+Optimize.swift` | Presses the start button after a second: Aim's, Sit and aim's, and Optimize's "I'll move it myself, then re-measure" |
| `-resetIntro YES` | `IntroGate.standard` (Store) | Marks the intro unfinished; nothing in the app calls `standard` yet |

Screen names, by file (each file's `names` list is the authority):

| File | Names |
|---|---|
| `App/DebugScreens+Flow.swift` | `aim`, `listening`, `paused`, `denied`, `repeating`, `failed`, `failed-noisy`, `failed-not-connected`, `flow` (live flow on simulated audio) |
| `App/DebugScreens+Results.swift` | `result`, `result-healthy`, `result-inconclusive`, `result-quiet-woofer`, `result-not-assessed`, `finding`, `home`, `home-empty`, `home-single` |
| `App/DebugScreens+Measure.swift` | `measure`, `measure-even`, `measure-empty`, `measure-inconclusive`, `numbers`, `numbers-distortion`, `numbers-decay`, `sit-and-aim`, `three-spots`, `three-spots-paused`, `live`, `measure-flow` |
| `App/DebugScreens+Optimize.swift` | `optimize`, `optimize-empty`, `optimize-room`, `optimize-nothing`, `optimize-moved`, `layout`, `layout-guess`, `layout-3d`, `manual-room`, `verify`, `verify-worse`, `verify-unchanged`, `optimize-flow`, `optimize-flow-empty` |
| `App/DebugScreens+Scan.swift` | `scan`, `scan-denied`, `scan-unsupported`, `scan-failed` |
| `App/DebugScreens+AR.swift` | `ar`, `ar-floor`, `ar-mark`, `ar-turn`, `ar-arrived`, `ar-limited` |
| `App/DebugScreens+Finish.swift` | `intro`, `intro-2`, `intro-3`, `settings`, `rooms`, `rooms-empty` |

`App/DebugScreens.swift` asks each provider in turn, one line each. Fixtures (`DiagnoseFixtures.swift`, `MeasureFixtures.swift`, `OptimizeFixtures.swift`) are Kit reports built from the mockups' numbers.

## Not wired in this branch

Read from the code at the time of writing; each is a gap between a screen that exists and the app that reaches it.

- **The intro is never shown.** `IntroView` exists and is reachable only through the debug names; `RootView` does not read `IntroGate.isShown`.
- **Settings is unreachable.** The Settings icon on Diagnose home calls `onSettings`, and `DiagnoseTab` passes `{}` (`Features/Diagnose/DiagnoseTab.swift:18`). `SettingsScreen` is reachable through the debug name only.
- **The room and system switcher does nothing.** `TabHome` passes an empty action to `ResoniqContextSwitcher` (`App/TabHome.swift:46`), so `RoomsSheet` is reachable through the debug names only.
- **No privacy manifest** (`PrivacyInfo.xcprivacy`) is in the target.

## What has no automated test

- Everything in this target. Its decisions are meant to be Kit code (tested on the Mac); `DiagnoseRules` and `OptimizeRules` are plain functions that a test target could cover, and none exists.
- The real engine (`EngineAudioIO`), RoomPlan (`LiveRoomScanSource`) and ARKit (`LiveARGuidanceSource`) paths: they compile for the device and have not run on one. The list of what to check is the [device checklist](../device-checklist.md).
- How any screen looks: checked by eye in the simulator against `design/screens/` (`make run SCREEN=<name>`, `make screenshot`).
