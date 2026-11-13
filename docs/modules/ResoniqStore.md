---
type: "module"
spec_module: "E"
phase: 5
status: "active"
tags:
  - "module"
---
# ResoniqStore

Local persistence with SwiftData: rooms with their layout, sound systems, speaker tests, seat measurements and optimisations, plus the scan file of a room. No accounts, no CloudKit, no network. The store keeps what the Kit decided; it decides nothing itself, except the one rule of the optimise tracker (`progress`).

Callers hand it finished values (`SpeakerReport`, `SeatReport`, `RoomModel`, `PlacementSuggestion`, `ComparisonReport`); it encodes them as JSON `Data` with a schema version beside each and reads them back with typed accessors that throw instead of crashing. Plans: [phase-2](../plans/phase-2-diagnose.md), [phase-3-measure.md](../plans/phase-3-measure.md), [phase-4-room.md](../plans/phase-4-room.md), [phase-5-ar.md](../plans/phase-5-ar.md).

Paths are relative to `ResoniqKit/Sources/ResoniqStore/`.

## Conventions

- **Reports are `Data` plus a version.** A stored value is never a model property of its own type. Each accessor (`readReport`, `readLayout`, `readSuggestion`...) compares the stored version with the current one and throws `ReportReadError.unknownSchemaVersion` or `.undecodable`; the optional-returning twin (`report`, `layout`, `comparison`) turns that into nil. One decoder, `StoredValue.decode` (`SchemaV2.swift:34`).
- **Enums are raw strings** (`kindRaw`, `speakerRaw`, `outcomeRaw`); an unknown raw value falls back to a default instead of failing.
- **Delete rules.** Room cascades to systems; a system cascades to its tests, seat measurements and optimisations. An optimisation's references to seat measurements (`seatBefore`, `seatAfter`) are nullify, with inverses on the measurement (`asBefore`, `asAfter`). `StoreState.selectedSystem` is nullify.
- **SwiftData does not update live objects on nullify.** `discard(_ measurement:)` clears the references itself before deleting, and `delete(_ room:)` / `delete(_ system:)` clear the selection first. Read through relationships after a delete only on objects fetched again.
- **History is filtered and sorted in memory** from the relationship arrays, not with relationship predicates.
- **A layout is a snapshot.** A seat measurement copies the room's layout bytes when it is kept, so a comparison knows where the speakers stood. An optimisation keeps the layout before and, once the move is recorded, the layout after.
- **Files are references.** The database keeps only a file name (`Room.scanFileName`); `ScanFileStore` owns the bytes. Scan files stay in the backup: a scan is user data that takes a walk round the room to recreate, so it is not excluded (the data skill excludes only re-creatable files). Recordings are not stored.
- **Main actor.** `ResoniqStore` is `@MainActor` and uses the container's main context. Models are not `Sendable`.

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
| `SpeakerTest` | `SchemaV2.swift:109` | the kept speaker report with its version; `readReport()` (:134) |
| `StoreState` | `SchemaV2.swift:144` | the selected system, in the database |
| `SeatMeasurement` | `SchemaV2.swift:153` | date, system, `SeatReport` data and version, layout snapshot (optional); `readReport()` (:179), `readLayout()` (:186) |
| `Optimization` | `SchemaV2.swift:194` | system, createdAt, suggestion, layout before, layout after (nil until moved), `seatBefore`, `seatAfter`, comparison (nil until verified), `outcome`; `readSuggestion()` (:225), `readLayoutBefore()` (:229), `readLayoutAfter()` (:234), `readComparison()` (:240) |
| `OptimizationOutcome` | `SchemaV2.swift:14` | `suggested`, `moved`, `verified`, `kept`, `putBack`, `declined`; `isClosed` is kept, putBack or declined |
| `ReportReadError` | `Models.swift:22` | `unknownSchemaVersion(Int)`, `undecodable`; used for every stored value |

## Facade

`ResoniqStore` (`ResoniqStore.swift:9`), `init(container:scanFiles:)` (:18), `init(inMemory:scanFiles:)` (:24), `scanFiles` nil keeps the store off the disk beyond the database.

| Call | Where | Does |
|---|---|---|
| `rooms()`, `defaultContext()`, `addRoom`, `addSystem`, `rename` | `ResoniqStore.swift:52–95` | as in phase 2 |
| `delete(_ room:)`, `delete(_ system:)` | `ResoniqStore.swift:102`, `:111` | cascade; the room's scan file is deleted too |
| `selectedSystem`, `select(_:)` | `ResoniqStore.swift:120`, `:124` | selection in the database |
| `keep(_ report: SpeakerReport, speaker:in:date:)`, `discard(_ test:)`, `latestTest`, `history` | `ResoniqStore.swift:149–174` | speaker tests |
| `layout(of:)` | `ResoniqStore+Optimize.swift:46` | the room's `RoomModel`, nil when none, throws when unreadable |
| `setLayout(_:for:scanFile:date:)` | `ResoniqStore+Optimize.swift:52` | stores the layout and its date; a new `scanFile` replaces the reference and deletes the old file, nil keeps it |
| `keep(_ report: SeatReport, in:date:)` | `ResoniqStore+Optimize.swift:67` | stores the report with a snapshot of the room's layout |
| `latestSeatMeasurement(in:)`, `seatHistory(in:)` | `ResoniqStore+Optimize.swift:79`, `:84` | newest first |
| `discard(_ measurement:)` | `ResoniqStore+Optimize.swift:90` | deletes; optimisations lose the reference |
| `beginOptimization(suggestion:in:before:date:)` | `ResoniqStore+Optimize.swift:102` | outcome `suggested`, layout before = the room's layout; throws `StoreError.noRoom` or `.noLayout` |
| `recordMove(_:newLayout:date:)` | `ResoniqStore+Optimize.swift:121` | layout after stored, room's layout replaced, `moved` |
| `recordVerification(_:after:comparison:)` | `ResoniqStore+Optimize.swift:130` | `seatAfter` and comparison stored, `verified` |
| `keep(_ optimization:)`, `decline(_:)` | `ResoniqStore+Optimize.swift:139`, `:155` | `kept`, `declined` |
| `putBack(_:date:)` | `ResoniqStore+Optimize.swift:145` | the room's layout returns to the layout before; `putBack` |
| `currentOptimization(in:)`, `optimizations(in:)` | `ResoniqStore+Optimize.swift:161`, `:166` | latest not closed; all, newest first |
| `progress(in:)` | `ResoniqStore+Optimize.swift:173` | `OptimizeProgress` (below) |

### Tracker progress

`OptimizeProgress` (`ResoniqStore+Optimize.swift:25`) has four flags, each true only when its data exists. The current optimisation is the latest one that is not kept, put back or declined.

- **scanned**: the room has a layout (scanned or entered).
- **measured**: a seat measurement of the current layout exists (its snapshot equals the room's layout bytes, or it is newer than the layout's last change); or the current optimisation started from one (`seatBefore`), so moving a speaker does not undo the measurement the move came from. Without a layout, any measurement counts.
- **moved**: the current optimisation has a layout after.
- **verified**: the current optimisation has a seat measurement after and a comparison.

The task asked for the first part of `measured` only; the `seatBefore` clause is an addition, because after `recordMove` the baseline is older than the new layout and would otherwise uncheck "Measured" in the middle of a cycle. Once an optimisation is kept, put back or declined, `moved` and `verified` clear for the next one.

### Scan files

`ScanFileStore` (`ScanFileStore.swift:9`): files in `<root>/Scans/<uuid>.usdz`. `applicationSupport()` (:19) for the app, `init(root:)` for tests. `importScan(from:replacing:)` (:28) copies and returns the name (the old file goes after a successful copy), `url(for:)` (:39) resolves (nil for a missing file or a name with a path separator), `delete(_:)` (:46) is quiet when the file is missing.

## Tests

`ResoniqKit/Tests/ResoniqStoreTests/`: `ResoniqStoreTests.swift` (phase 2, unchanged) and `StoreV2Tests.swift`: layout round trip and unknown version; seat measurement keep, latest, history, discard, snapshot; optimisation life cycle through every outcome; `progress` for each combination; cascade and nullify rules, including reading after the referenced object is gone; scan files in a temporary directory; and the migration test, which writes a V1 store to disk (room, system, speaker test, selection), closes it, opens it with V2 and the plan, checks everything and the empty new fields, then writes V2 data into it.

## Limits

- Migration is tested on the Mac with a store written by the V1 schema in this repo, not with a store written by the shipped app on a device.
- A seat measurement is compared with the layout by bytes; saving a layout that encodes differently but means the same counts as an edit.
- Only one optimisation is expected to be open at a time; starting a second leaves the first open, and `currentOptimization` returns the newer.
- `putBack` restores the room's layout but does not delete the layout after; the optimisation keeps both for the record.
- No SwiftData-level index or predicate on the new models; fine for tens of rows per system.

## Open questions

- Whether raw recordings are kept by default or only on request (spec §9 lists them as optional).
- Whether `StoreError` and `ReportReadError` should merge once the screens show their messages.
