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
| `Features/Optimize/` | Optimize home, Confirm layout (`LayoutScreen`, `Room3DView`), manual room entry, Before and after (`VerifyScreen`), `OptimizeCoordinator`, `RoomDisplay.swift`; `Scan/` (RoomPlan) and `AR/` (ARKit and RealityKit). The tab's decisions are `OptimizeRules` and the optimisation calls in ResoniqStore |
| `Features/Intro/` | The three intro screens and their illustrations |
| `Features/Settings/` | Settings: what is stored, delete data, the intro again, About, licences |
| `Features/Rooms/` | The rooms and systems sheet behind the switcher |
| `Resources/` | `Info.plist` (camera and microphone strings), the asset catalog |

## How a flow is built

1. **One coordinator per tab** (`DiagnoseCoordinator`, `MeasureCoordinator`, `OptimizeCoordinator`; `@Observable`, `@MainActor`). It owns what is on screen (a full-screen cover, a pushed route), what was kept in the store and what comes next. It calls decisions and navigates; a decision that depends only on store and Kit values lives in the Kit with tests (`OptimizeRules` and `baseline`, `confirmLayout`, `optimization(for:in:)`, `verifies`, `canPutBack`, `declinedSuggestions`, `optimizeStatus` in ResoniqStore; see [ResoniqStore](ResoniqStore.md)). `DiagnoseRules` (in `Features/Diagnose/DiagnoseCoordinator.swift`) is still in the app.
   - **Covers and timing.** Nothing waits on a timer before presenting. Measure hands a kept measurement on from its cover's `onDismiss` (`MeasureCoordinator.coverDismissed`, wired in `MeasureTab`), so Optimize presents Before and after only once Measure's cover has gone, and only while the Optimize tab is on screen (`tabAppeared`). `OptimizeCoordinator.isCoverShowing` is what the system actually presented (set by the cover's `onAppear`, cleared by `onDismiss`); a cover asked for but never presented is dropped when the tab appears, so the home cannot stay blocked. An alert set while a cover leaves shows on the tab once the dismissal ends.
   - **Deleted data.** `AppComposition` sets `ResoniqStore.onDataReset` once; after "Delete all results" or "Delete everything" it calls `resetAfterDataDeletion()` on each coordinator: Diagnose drops the comparison memory and the quick check's chain and closes its cover (with any pushed finding); Measure closes its cover and drops an unsaved result, a comparison, The numbers and its path; Optimize closes its cover and drops a waiting Before and after.
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
| `appLifecycle` | `App/AppLifecycle.swift:27` | `AppLifecycle`: handlers registered once in `AppComposition`; `RootView` calls `sceneLeftForeground()` when the scene is not active, which cancels a running test or measurement, stops a hold-to-hear tone (`DiagnoseCoordinator.stopTone`, through a weak reference to the latest `TonePlayerAdapter`; VoiceOver can start one with no finger to lift), and closes the scan and AR covers |
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
| `-resetIntro YES` | `App/RootView.swift` | Marks the intro unfinished at launch, Debug only: read under `#if DEBUG` and passed to `IntroGate.standard(resetRequested:)`; a Release build never reads it |

Screen names, by file (each file's `names` list is the authority):

| File | Names |
|---|---|
| `App/DebugScreens+Flow.swift` | `aim`, `listening`, `paused`, `denied`, `repeating`, `failed`, `failed-noisy`, `failed-not-connected`, `flow` (live flow on simulated audio) |
| `App/DebugScreens+Results.swift` | `result`, `result-healthy`, `result-inconclusive`, `result-quiet-woofer`, `result-not-assessed`, `finding`, `home`, `home-empty`, `home-single` |
| `App/DebugScreens+Measure.swift` | `measure`, `measure-even`, `measure-empty`, `measure-inconclusive`, `numbers`, `numbers-distortion`, `numbers-decay`, `sit-and-aim`, `three-spots`, `three-spots-paused`, `live`, `measure-flow` |
| `App/DebugScreens+Optimize.swift` | `optimize`, `optimize-empty`, `optimize-room`, `optimize-nothing`, `optimize-moved`, `layout`, `layout-guess`, `layout-3d`, `manual-room`, `verify`, `verify-worse`, `verify-unchanged`, `optimize-flow`, `optimize-flow-empty` |
| `App/DebugScreens+Scan.swift` | `scan`, `scan-denied`, `scan-unsupported`, `scan-failed` |
| `App/DebugScreens+AR.swift` | `ar`, `ar-floor`, `ar-mark`, `ar-mark-second`, `ar-disagree`, `ar-turn`, `ar-arrived`, `ar-limited` |
| `App/DebugScreens+Finish.swift` | `intro`, `intro-2`, `intro-3`, `settings`, `rooms`, `rooms-empty` |

`App/DebugScreens.swift` asks each provider in turn, one line each. Fixtures (`DiagnoseFixtures.swift`, `MeasureFixtures.swift`, `OptimizeFixtures.swift`) are Kit reports built from the mockups' numbers.

## First launch, Settings, rooms

- **First launch.** `AppShell` shows `IntroView` while `IntroGate` says the intro has not been finished.
  "Try it on a speaker" finishes the gate and calls `DiagnoseCoordinator.startFirstTest()`; "Skip intro" lands
  on Diagnose. A `-screen` launch never shows the intro and never writes the flag.
- **Settings** opens as a sheet from the icon button on Diagnose home (`DiagnoseTab`).
- **Rooms and systems.** The switcher on every tab calls the `openRooms` environment action, set once in
  `RootView`, which presents `RoomsSheet`. When either sheet closes, `systemsChanged` tells each coordinator
  that the selection may have changed; deleting data calls each coordinator's `resetAfterDataDeletion()`.
- **Privacy manifest**: `Resources/PrivacyInfo.xcprivacy`.

## Optimize: what is stored and when

- **Scan files.** RoomPlan's export stays in the temporary directory until "Looks right"; only then is it imported into `Scans/` and recorded on the room. Closing the scan, scanning again, entering by hand or a scan that finishes after its cover closed deletes the temporary file; closing while RoomPlan processes cancels the processing and deletes the export (`RoomCaptureHost`). At launch `AppComposition` sweeps scan files no room refers to and temporary exports left behind. A hand-entered layout drops the room's old scan file.
- **"I'll move it myself"** stores the suggestion's pose with the speaker not confirmed; the moved home says the plan shows where the speaker was meant to go, and Before and after says the comparison is of two measurements and that nobody saw where the speaker went. The AR guide stores where the person last pointed at the speaker, confirmed; when that is farther than 3 cm from the suggestion the home and Before and after say it was marked a little way off.
- **Confirm layout** goes through `ResoniqStore.confirmLayout`, which supersedes an open optimisation the new layout makes stale. "Put the speaker back" is refused (an alert) when the room's layout is no longer the move's.
- **A failed save of a seat measurement** keeps the result on Measure home (as the unsaved one) and, once the cover has gone, `RootView` shows the store-failure alert ("I couldn't save that", `StoreText.measurementNotSaved`). Measure home itself carries no "not saved" mark: that view is not part of this change.

## What has no automated test

- Everything in this target. Its decisions are meant to be Kit code (tested on the Mac): the Optimize decisions now are (`OptimizeRules` and the store calls above); `DiagnoseRules` is a plain function that a test target could cover, and none exists. The cover timing above (presentation after dismissal, a dropped cover let go on the tab's appearance) is reasoned, not run: it needs the simulator or a device.
- The real engine (`EngineAudioIO`), RoomPlan (`LiveRoomScanSource`) and ARKit (`LiveARGuidanceSource`) paths: they compile for the device and have not run on one. The list of what to check is the [device checklist](../device-checklist.md).
- How any screen looks: checked by eye in the simulator against `design/screens/` (`make run SCREEN=<name>`, `make screenshot`).
