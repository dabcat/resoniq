---
type: "module"
spec_module: "E"
phase: 6
status: "active"
tags:
  - "module"
---
# ResoniqStore

Local persistence with SwiftData: rooms with their layout, sound systems, speaker tests, seat measurements and optimisations, plus the scan file of a room. No accounts, no CloudKit, no network (sending kept recordings is [ResoniqShare](ResoniqShare.md); this module only decides what of a manifest may leave, `RecordingManifest.shared()`). The store keeps what the Kit decided. It also holds the Optimize tab's decisions, which depend only on store and Kit values (`OptimizeRules`: routes, the baseline, what a layout change closes, what counts as declined, how a move was placed, the tracker), so they are tested on the Mac rather than living untested in the app.

Callers hand it finished values (`SpeakerReport`, `SeatReport`, `RoomModel`, `PlacementSuggestion`, `ComparisonReport`); it encodes them as JSON `Data` with a schema version beside each and reads them back with typed accessors that throw instead of crashing. Also the counts and delete-all calls Settings and the rooms sheet use, the default names, and the "intro finished" flag. Plans: [phase-2](../plans/phase-2-diagnose.md), [phase-3-measure.md](../plans/phase-3-measure.md), [phase-4-room.md](../plans/phase-4-room.md), [phase-5-ar.md](../plans/phase-5-ar.md), [phase-6](../plans/phase-6-ai-finish.md).

Paths are relative to `ResoniqKit/Sources/ResoniqStore/`.

## Conventions

- **Reports are `Data` plus a version.** A stored value is never a model property of its own type. Each accessor (`readReport`, `readLayout`, `readSuggestion`...) compares the stored version with the current one and throws `ReportReadError.unknownSchemaVersion` or `.undecodable`; the optional-returning twin (`report`, `layout`, `comparison`) turns that into nil. One decoder, `StoredValue.decode` (`SchemaV2.swift:34`).
- **Enums are raw strings** (`kindRaw`, `speakerRaw`, `outcomeRaw`); an unknown raw value falls back to a default instead of failing.
- **Delete rules.** Room cascades to systems; a system cascades to its tests, seat measurements and optimisations. An optimisation's references to seat measurements (`seatBefore`, `seatAfter`) are nullify, with inverses on the measurement (`asBefore`, `asAfter`). `StoreState.selectedSystem` is nullify.
- **SwiftData does not update live objects on nullify.** `discard(_ measurement:)` clears the references itself before deleting, and `delete(_ room:)` / `delete(_ system:)` clear the selection first. Read through relationships after a delete only on objects fetched again.
- **History is filtered and sorted in memory** from the relationship arrays, not with relationship predicates.
- **A layout is a snapshot.** A seat measurement copies the room's layout bytes when it is kept, so a comparison knows where the speakers stood. An optimisation keeps the layout before and, once the move is recorded, the layout after.
- **"The same layout" has one definition:** `LayoutMatch.matches` in ResoniqRoom (same speakers and seats by id, each pose within 2 cm and 2°). The baseline, `verifies`, `staysOpen`, `canPutBack` and `staysDeclined` all use it; nothing compares layout bytes alone any more (equal bytes are a shortcut to "matches").
- **Files are references.** The database keeps only a file name (`Room.scanFileName`, `SpeakerTest.recordingFileName`); `ScanFileStore` and `RecordingStore` own the bytes. Scan files stay in the backup: a scan is user data that takes a walk round the room to recreate, so it is not excluded (the data skill excludes only re-creatable files). Kept recordings (phase 9, only when "Keep recordings" is on) are excluded from the backup: they are the room's raw sound, for the owner to take off the phone themselves.
- **Main actor.** `ResoniqStore` is `@MainActor` and uses the container's main context, unless `init(container:scanFiles:context:)` is given another (tests use a second `ModelContext` to prove a value was saved, not only held in memory). Models are not `Sendable`.

## Schema versions

| Version | Models | Migration |
|---|---|---|
| `ResoniqSchemaV1` (`Models.swift`) | Room, SoundSystem, SpeakerTest, StoreState | The first release. Kept unchanged so a V1 store can open. |
| `ResoniqSchemaV2` (`SchemaV2.swift:43`) | adds SeatMeasurement and Optimization; Room gains `layoutData`, `layoutSchemaVersion`, `layoutUpdatedAt`, `scanFileName`; SoundSystem gains `seatMeasurements` and `optimizations` | `ResoniqMigrationPlan` (`SchemaV2.swift:252`): one lightweight stage V1 to V2. Everything added is optional, defaulted or a new model, so no value is rewritten; the new fields start empty. |

To change a model again: add `ResoniqSchemaV3`, move the typealiases, add a stage.

## Models

| Symbol | Where | Holds |
|---|---|---|
| `Room` | `SchemaV2.swift:50` | name, createdAt, systems; layout (`layoutData`, `layoutSchemaVersion`, `layoutUpdatedAt`), `scanFileName`; `readLayout()` (:74), `layout` (:80) |
| `SoundSystem` | `SchemaV2.swift:84` | name, kind, room, tests, seatMeasurements, optimizations |
| `SpeakerTest` | `SchemaV2.swift:109` | the kept speaker report with its version; `readReport()` (:134); `recordingFileName`, reserved since V1, holds the kept recording's folder name (phase 9; no migration) |
| `StoreState` | `SchemaV2.swift:144` | the selected system, in the database |
| `SeatMeasurement` | `SchemaV2.swift:153` | date, system, `SeatReport` data and version, layout snapshot (optional); `readReport()` (:179), `readLayout()` (:186) |
| `Optimization` | `SchemaV2.swift` | system, createdAt, suggestion, layout before, layout after (nil until moved), `seatBefore`, `seatAfter`, comparison (nil until verified), `outcome`; `readSuggestion()`, `readLayoutBefore()`, `readLayoutAfter()`, `readComparison()`, and the optional twins `suggestion`, `comparison`, `layoutBefore`, `layoutAfter` |
| `OptimizationOutcome` | `SchemaV2.swift:14` | `suggested`, `moved`, `verified`, `kept`, `putBack`, `declined`, `superseded` (:30: the room's layout changed under it, see `confirmLayout`); `isClosed` is kept, putBack, declined or superseded. A new raw string, no schema change; an older build would read `superseded` as `suggested` (only a downgrade could meet that) |
| `ReportReadError` | `Models.swift:22` | `unknownSchemaVersion(Int)`, `undecodable`; used for every stored value |

## Facade

`ResoniqStore` (`ResoniqStore.swift:9`), `init(container:scanFiles:context:)` (:24), `init(inMemory:scanFiles:)`, `scanFiles` nil keeps the store off the disk beyond the database. `onDataReset` (:22) is called after `deleteAllResults()` and `deleteEverything()` have saved; the app sets it once (`AppComposition`) so every coordinator drops what it holds about deleted data.

| Call | Where | Does |
|---|---|---|
| `rooms()`, `defaultContext()`, `addRoom`, `addSystem`, `rename` | `ResoniqStore.swift:52–95` | as in phase 2 |
| `delete(_ room:)`, `delete(_ system:)` | `ResoniqStore.swift:102`, `:111` | cascade; the room's scan file is deleted too |
| `selectedSystem`, `select(_:)` | `ResoniqStore.swift:120`, `:124` | selection in the database |
| `keep(_ report: SpeakerReport, speaker:in:date:)`, `update(_ test:report:)`, `discard(_ test:)`, `latestTest`, `history` | `ResoniqStore.swift` ("Tests") | speaker tests; `update` replaces a kept test's report with the same test read again (`SpeakerDiagnosis.compared`), keeping its date; `discard` deletes the test's recording folder too, as `delete(_ room:)` and `delete(_ system:)` do for theirs |
| `layout(of:)` | `ResoniqStore+Optimize.swift:84` | the room's `RoomModel`, nil when none, throws when unreadable |
| `setLayout(_:for:scanFile:date:)` | `ResoniqStore+Optimize.swift:94` | the raw write: stores the layout and its date; a new `scanFile` replaces the reference and deletes the old file; nil keeps it, except for a hand-entered layout (`RoomSource.manual`), which drops the room's scan and deletes its file |
| `confirmLayout(_:for:scanFile:date:)` | `ResoniqStore+Optimize.swift:112` | "Looks right": `setLayout`, after closing as `superseded` every open optimisation of the room's systems the new layout makes stale (`OptimizeRules.staysOpen`: an edit that is exactly the recorded move keeps it open; a rescan, entry by hand or any other edit does not) |
| `keep(_ report: SeatReport, in:date:)` | `ResoniqStore+Optimize.swift:127` | stores the report with a snapshot of the room's layout |
| `latestSeatMeasurement(in:)`, `seatHistory(in:)` | `ResoniqStore+Optimize.swift:139`, `:144` | newest first |
| `baseline(in:)` | `ResoniqStore+Optimize.swift:152` | the newest measurement made in the room's current layout (`LayoutMatch`): what home's suggestion and a new optimisation work from. After "Put the speaker back" that is the measurement from before the move, not the latest (made in the moved layout). No layout: the newest; an unreadable layout: none |
| `discard(_ measurement:)` | `ResoniqStore+Optimize.swift:165` | deletes; optimisations lose the reference |
| `beginOptimization(suggestion:in:before:date:)` | `ResoniqStore+Optimize.swift:177` | outcome `suggested`, layout before = the room's layout; throws `StoreError.noRoom` or `.noLayout` |
| `optimization(for:in:date:)` | `ResoniqStore+Optimize.swift:198` | the open one when it is the same suggestion still only suggested (`OptimizeRules.canReuse`), else a new one from the baseline; throws `.notMeasured` without one |
| `recordMove(_:newLayout:date:)` | `ResoniqStore+Optimize.swift:208` | layout after stored, room's layout replaced, `moved` |
| `verifies(_:_:)` | `ResoniqStore+Optimize.swift:218` | whether a kept measurement is the move's second measurement: moved, and measured in the layout the move left |
| `recordVerification(_:after:comparison:)` | `ResoniqStore+Optimize.swift:223` | `seatAfter` and comparison stored, `verified` |
| `keep(_ optimization:)`, `decline(_:)` | `ResoniqStore+Optimize.swift:232`, `:256` | `kept`, `declined` |
| `canPutBack(_:)`, `putBack(_:date:)` | `ResoniqStore+Optimize.swift:238`, `:245` | the room's layout returns to the layout before; `putBack`. Refused with `.layoutChanged` unless the room still has the layout the move left |
| `currentOptimization(in:)`, `optimizations(in:)` | `ResoniqStore+Optimize.swift:262`, `:267` | latest not closed; all, newest first |
| `declinedSuggestions(in:)` | `ResoniqStore+Optimize.swift:273` | suggestions declined or put back that still stand (`OptimizeRules.staysDeclined`: the room has the layout they were made for and the baseline still has the problem they answered) |
| `progress(in:)` | `ResoniqStore+Optimize.swift:289` | `OptimizeProgress` (below) |
| `optimizeStatus(in:)` | `ResoniqStore+Optimize.swift:300` | `OptimizeStatus` (:48): layout (or that it is unreadable), progress, the baseline's report, the open comparison, the declined suggestions and how the open move was placed: all Optimize home reads |

### Settings, rooms and the intro

| Symbol | Where | Does |
|---|---|---|
| `SoundSystemKind`, `SpeakerPosition` | `Models.swift:6`, `:15` | The kinds of system (`stereoPair`, `stereoWithSubwoofer`, `soundbar`, `singleSpeaker`, `surround`) and a test's speaker (`left`, `right`, `single`) |
| `StoreText` | `StoreText.swift:2` | `defaultRoomName` "My room", `defaultSystemName` "My speakers", `displayName` of a kind and of a position (:11, :24); `newRoomName(existing:)`, `newSystemName(existing:)` (`ResoniqStore+Data.swift:46`, `:48`) |
| `StoreCounts` | `ResoniqStore+Data.swift:6` | Rooms, systems, speaker tests, seat measurements, room scans; `results` (tests plus seat measurements); `init(system:)` (:26) and `init(room:)` (:34) give what deleting that system or room takes with it |
| `counts()` | `ResoniqStore+Data.swift:53` | The whole store's counts, for Settings |
| `canDelete(_ room:)`, `canDelete(_ system:)` | `ResoniqStore+Data.swift:65`, `:70` | False for the last room, and for the last system of a room |
| `deleteAllResults()` | `ResoniqStore+Data.swift:76` | Every speaker test, seat measurement and optimisation; rooms, systems, layouts and scans stay; then `onDataReset` |
| `deleteEverything()` | `ResoniqStore+Data.swift:86` | Everything, scan files included, then "My room" and "My speakers" are created and selected again; then `onDataReset` |
| `sweepScanFiles()` | `ResoniqStore+Data.swift:103` | Removes scan files no room refers to (one imported and never confirmed, one left by a failed save); the app runs it at launch |
| `IntroGate`, `IntroFlagStore`, `UserDefaultsIntroFlag` | `IntroGate.swift:25`, `:4`, `:9` | Whether the three intro screens are shown (until finished or skipped once, key `introFinished`); `finish()` (:44), `reset()` (:47); `standard(defaults:resetRequested:)` (:35) resets first when asked. The Kit never reads a launch argument: the app reads `-resetIntro` under `#if DEBUG` and passes it in, so a Release build cannot be reset from the command line |
| `StoreText.saveFailedTitle`, `measurementNotSaved` | `StoreText.swift` | The title of every failed-save alert ("I couldn't save that") and the message when a seat measurement could not be written down |

### Tracker progress

`OptimizeProgress` (`ResoniqStore+Optimize.swift:29`) has four flags, each true only when its data exists. The current optimisation is the latest one that is not kept, put back, declined or superseded.

- **scanned**: the room has a layout (scanned or entered).
- **measured**: the room has a baseline (a measurement whose snapshot matches the current layout by `LayoutMatch`); or the open optimisation has been moved and keeps its `seatBefore`, so moving a speaker does not undo the measurement the move came from. Without a layout, any measurement counts.
- **moved**: the current optimisation has a layout after.
- **verified**: the current optimisation has a seat measurement after and a comparison.

Once an optimisation is closed, `moved` and `verified` clear for the next one. "Measured" and the suggestion come from the same baseline, so the tracker cannot say "measured" through one measurement while the home suggests from another.

### OptimizeRules

`OptimizeRules` (`OptimizeRules.swift:9`), plain functions moved here from the app so they are tested:

| Function | Where | Decides |
|---|---|---|
| `route(for:progress:)` | :34 | where a home action leads (`HomeAction` to `Route`); a step opens only when the one before has data |
| `afterLayoutConfirmed(isNewRoom:progress:)` | :55 | after "Looks right": a new room is measured; an edit closes when the room is still measured |
| `expectedLayout`, `staysOpen` | :63, :75 | the layout an open optimisation expects (before while suggested, after once moved) and whether it survives a new layout |
| `canPutBack` | :86 | moved or verified, and the room still has the layout after |
| `verifies` | :93 | moved, and the measurement made in the layout after |
| `canReuse`, `isSame`, `isDeclined`, `firstOpen` | :102–:118 | a suggestion is the same move (speaker, from, to); the first of the advisor's not turned down |
| `staysDeclined` | :126 | a declined or put-back suggestion stays turned down while the layout matches the one it was made for and the baseline still has its problem (for one from the room's shape: still no problem) |
| `targets(of:in:)`, `frequencyTolerance` | :137 | the extreme a comparison targets |
| `moved(_:speaker:to:isConfirmed:)` | :154 | the layout with the speaker at a pose; `isConfirmed` false for "I'll move it myself" (nobody saw it there), true for a pose marked in AR |
| `withGuess` | :164 | a scanned room gets `LayoutGuess`'s speakers and seat |
| `MovePlacement`, `placement(of:in:)` | :169, :179 | `atTarget`, `approximate` (marked farther than `MoveGuidance.positionTolerance` from the target) or `notConfirmed` |

### Kept recordings (phase 9)

[Plan](../plans/phase-9-keep-recordings.md). The store depends on `ResoniqAudio` for this (`MeasurementResult`, `WAVFile`).

| Symbol | Where | Does |
|---|---|---|
| `RecordingManifest` | `RecordingManifest.swift` | `manifest.json`, `currentSchemaVersion` 1: kind, `createdAt`, `sampleRate`, `playback`, `device` (model, system, version, app version; `Device.current(appVersion:)`), `audioRoute` (output, input), `speaker` (position, channel; make, model, unit id absent), `system` (name, kind), `room` (name), `sweep` (the `LogSweep`'s parameters and sample count), `noiseFloor` (file, sample count, rms, fluctuation, steady), `runs` (file, sample count, lead-in, arrival, measured and route delay, the report's `RecordingCheck`, splices, phone moved, attempt, sweep-tied sound, take offsets, clock ratio, source and disagreement), `report` (schema version and the `SpeakerReport`), `label` (absent); `encoder`, `decoder` (ISO 8601 dates, sorted keys, non-finite numbers as text) |
| `RecordingManifest.shared(calendar:)` | `RecordingManifest+Shared.swift` | Phase 10: the manifest as it may leave the phone. The day only (midnight UTC of the day in the person's calendar), each route's kind without its name, the system's kind without its name, no room, the speaker's position and channel without make, model or unit id, a label without `givenBy`; device model and versions, sweep, noise floor, runs and report kept. Route, system and room names are optional for this (`Route.Output`, `Route.Input`, `System.name`, `room`), with the same JSON on disk as before |
| `RecordingExample` | `RecordingManifest.swift` | manifest, each run's samples, the floor's; `init(result:report:speaker:systemName:systemKind:roomName:date:device:)` builds it from a finished test |
| `RecordingStore` | `RecordingStore.swift` | `<root>/Recordings/<name>/` with `manifest.json`, `noise-floor.wav`, `run-N.wav` (mono 32-bit float at the stream's rate); `documents()`, `folderName(date:speaker:id:timeZone:)` (`2026-11-14_153012_left_1A2B3C4D`), `write(_:named:)` (into `.<name>.partial`, then moved: a plain name is always complete), `read(_:)`, `manifest(_:)` (without the audio), `fileURL(_:file:)` and `contains(_:)` (for sharing, which streams the files), `names()`, `totalSize()`, `delete(_:)`, `deleteAll()`, `sweep(keeping:)`; the folder is excluded from backup |
| `RecordingPreference` | `RecordingStore.swift` | "Keep recordings": `UserDefaults` key `keepRecordings`, false until turned on |
| `keepRecording(_:for:)` | `ResoniqStore+Recordings.swift` | names the folder on the test and saves, writes off the main actor (`@concurrent`), then on it: a failed write clears the name (the report stays kept); a test deleted meanwhile has its folder removed |
| `recordingsSize()`, `deleteRecordings()`, `sweepRecordings()` | `ResoniqStore+Recordings.swift` | bytes on disk; every recording goes and every test stays; folders no test refers to and partial writes go (at launch) |
| `StoreCounts.recordings` | `ResoniqStore+Data.swift` | tests with a recording; `deleteAllResults()` and `deleteEverything()` delete every recording |

### Scan files

`ScanFileStore` (`ScanFileStore.swift:9`): files in `<root>/Scans/<uuid>.usdz`. `applicationSupport()` (:19) for the app, `init(root:)` for tests. `importScan(from:replacing:)` (:28) copies and returns the name (the old file goes after a successful copy), `url(for:)` (:39) resolves (nil for a missing file or a name with a path separator), `delete(_:)` (:46) is quiet when the file is missing, `sweep(keeping:)` (:54) removes every file not named. RoomPlan's export goes to the temporary directory first, named by `temporaryExportURL(in:)` (:70, prefix `Resoniq-scan-`); the app imports it only when the layout is confirmed, deletes it when the scan is closed or abandoned, and `removeTemporaryExports(in:)` (:77) clears any left at launch.

## Tests

`ResoniqKit/Tests/ResoniqStoreTests/`: `ResoniqStoreTests.swift` (phase 2) and `StoreV2Tests.swift` (which also covers `counts()`, `canDelete`, `deleteAllResults()` and `deleteEverything()`; `IntroGateTests` in the same file): layout round trip and unknown version; seat measurement keep, latest, history, discard, snapshot; optimisation life cycle through every outcome; `progress` for each combination; cascade and nullify rules, including reading after the referenced object is gone; scan files in a temporary directory; and the migration test, which writes a V1 store to disk (room, system, speaker test, selection), closes it, opens it with V2 and the plan, checks everything and the empty new fields, then writes V2 data into it. The tests that check persistence ("again") read through a second `ModelContext`, so they prove a save, not object identity.

`SharedManifestTests.swift` (phase 10): every stored field of the manifest, a device and a run listed by reflection (a new field fails until decided), names typed by the person gone, routes keep their kind only, the day in the person's calendar written as midnight UTC, speaker and label, device kept, the measurement kept whole, no name anywhere in the encoded JSON or the report, a manifest written before reads back and shares the same way.

`RecordingStoreTests.swift` (phase 9): every manifest field from a hand-made result, another device's clock, the JSON's shape; an example read back bit for bit, its size, the backup exclusion, a partial write and odd names; on the store, keeping names the folder and saves it, a failed write keeps the report and no name, Don't keep, a discard during the write, deleting a system or room, all results, everything and the recordings alone, the sweep; the preference off by default.

`OptimizeFlowTests.swift` drives the flow with the real advisor's suggestion: after put back, home works from the measurement of the restored layout, the put-back move is not offered again, and a new optimisation starts from that baseline; a put-back move returns once the problem changes; a decline stays until the layout changes; a rescan while moved supersedes the move, leaves the room not measured, the next measurement does not verify and put back is refused; an edit that is exactly the move keeps it, any other supersedes it; "I'll move it myself" is recorded not confirmed and AR placements as at the target or approximate; `verifies` only in the layout the move left; `optimization(for:in:)` needs a baseline and reuses an open suggestion; the status of an unreadable layout. `OptimizeRulesTests` covers routes, what follows a layout, targets and closed outcomes. `StoreMaintenanceTests.swift`: the scan sweep and temporary exports in a temporary directory, a hand-entered room dropping the scan, and `onDataReset` firing on both deletes only.

## Limits

- Migration is tested on the Mac with a store written by the V1 schema in this repo, not with a store written by the shipped app on a device.
- "The same layout" ignores walls and furniture (`LayoutMatch`): a scan that changed only the walls but kept every speaker's id would count as unchanged. A rescan never does that today (the guess makes new ids).
- A put-back or declined suggestion is matched to the baseline's problem by kind and frequency (±0.5 Hz, the advisor copies the frequency); a new measurement whose dip moved a hertz brings the suggestion back.
- Only one optimisation is expected to be open at a time; starting a second leaves the first open, and `currentOptimization` returns the newer. `confirmLayout` closes only the current one of each system.
- `putBack` restores the room's layout but does not delete the layout after; the optimisation keeps both for the record.
- No SwiftData-level index or predicate on the new models; fine for tens of rows per system.

## Open questions

- Decided in phase 9: raw recordings are kept only on request, off by default.
- A kept recording's manifest holds the report as first made; when the pair's comparison rewrites the kept report (`update`), the manifest is not rewritten.
- Whether `StoreError` and `ReportReadError` should merge once the screens show their messages.
