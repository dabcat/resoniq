---
type: "plan"
phase: 9
status: "active"
tags:
  - "plan/phase-9"
---
# Phase 9 · Keep the raw recordings of a speaker test

Goal: when the owner asks for it, a kept speaker test also keeps its sound: each run's raw recording, the room's
noise floor and a manifest of everything the app knew about the test, on the iPhone, where the Files app and
`xcrun devicectl` can reach it. Today only the report is kept. The recordings are needed to see what a healthy
speaker reads through a phone in a real room ([phase 8](phase-8-rub-buzz.md), "Not verified") and later as the
first examples of the dataset ([dataset plan](../research/2026-11-13-defect-dataset-plan.md), "What one saved
example must hold", which is the spec of what one example holds).

Nothing leaves the device by itself: no networking, no share sheet, no upload, and the folder is left out of the
iCloud backup. Getting the files off the phone is the owner's own act (Files, Finder, `devicectl`).

## How it works

1. **Off by default.** A setting, "Keep recordings", in Settings. While it is off nothing changes from today.
2. **Only what is kept.** When the setting is on and a speaker test is kept (the normal flow and the
   external-playback flow; never a quick check, never an inconclusive test, which are not kept), its example is
   written. "Don't keep" deletes it; so do deleting the test's system or room, "Delete all results", "Delete
   everything" and the new "Delete recordings".
3. **Never in the way.** The report is kept first, exactly as today. The audio is encoded and written off the main
   actor after the result is on screen. A write that fails leaves the report kept and the test without a
   recording; the user sees nothing (the space used in Settings simply does not grow).
4. **Seat measurements are out of scope** for this phase: only speaker tests are kept as examples.

## Who decides what

| Decision | Module | Symbol (contract) |
|---|---|---|
| The noise-floor recording and the route travel with the result | `ResoniqAudio` | `MeasurementResult.noiseFloorSamples` (the exact samples `NoiseFloor.measure` accepted), `outputRoute`, `inputRoute` (what the IO reported when the test opened); `AudioIO.inputRoute` |
| Lossless mono audio files | `ResoniqAudio` | `WAVFile`: the RIFF writer `TestSoundFile` already had, generalised (channels, PCM 16/24, 32-bit float) and a reader for the files it writes |
| What one example holds | `ResoniqStore` | `RecordingManifest` (Codable, `schemaVersion` 1) and `RecordingExample` (manifest plus samples), built from `MeasurementResult`, `SpeakerReport` and the test's context |
| Where examples live, size, delete, sweep | `ResoniqStore` | `RecordingStore`: `<Documents>/Recordings/<folder>/`; `write`, `read`, `delete`, `deleteAll`, `sweep(keeping:)`, `totalSize()` |
| Which test owns which folder, and deletes | `ResoniqStore` | `SpeakerTest.recordingFileName` (the reserved field: the folder's name, no migration); `ResoniqStore.keepRecording(_:for:)`, `discard`, `delete(room/system)`, `deleteAllResults`, `deleteEverything`, `deleteRecordings`, `sweepRecordings` |
| Whether to keep recordings | `ResoniqStore` | `RecordingPreference` (UserDefaults key `keepRecordings`, false by default), as `IntroGate` keeps its flag |
| When an example is written | App | `DiagnoseCoordinator.testFinished`: after `store.keep`, only when the preference is on |

**Why `ResoniqStore` owns it.** The store already decides what is kept on the phone and what a delete takes with
it; an example lives and dies with a `SpeakerTest`, and `ScanFileStore` is the same pattern for a room's scan. The
manifest needs `SpeakerReport` (Diagnostics) and `MeasurementResult` (Audio); Audio must not learn about reports, so
the store gains a dependency on `ResoniqAudio` (Audio depends only on DSP, so there is no cycle). The WAV encoder is
audio and stays in `ResoniqAudio`, next to the test sound file that already used it.

**Why no migration.** `SpeakerTest.recordingFileName` was reserved in V1 for exactly this and has always been nil;
it now holds the example's folder name. No model changes, so the schema stays at V2.

**Why 32-bit float.** The phone hands the app 32-bit float samples, and the analysis runs on those. Written as IEEE
float WAV (format 3) they come back bit for bit, so a feature recomputed on the Mac from a file is the same number
the phone computed, and nothing is held to ±1 (a float sample over full scale stays what it was). 24-bit PCM would
also lose nothing audible (its step is 138 dB under full scale, far under a phone microphone's own noise) but it
rounds every sample and clips at full scale, so a recomputed feature would differ in its last digits for no saving
worth having (a quarter of the size). Mono, at the sample rate the stream ran at.

## Layout on the phone

```
Documents/Recordings/                       (excluded from backup)
  2026-11-14_153012_left_1A2B3C4D/
    manifest.json
    noise-floor.wav                         mono, 32-bit float, the stream's rate
    run-1.wav  run-2.wav  run-3.wav
```

`Info.plist` gains `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`, both true: the first makes the
Documents folder visible in Finder when the phone is plugged in, both together show it in the Files app under
"On My iPhone > Resoniq". `devicectl` reads the app's data container without either key.

## Tasks

| # | Task | Module | Model | Status |
|---|---|---|---|---|
| 1 | `WAVFile` (write and read, mono and stereo, PCM 16/24, float 32), `TestSoundFile` on it with its bytes unchanged | Audio | Opus | |
| 2 | `MeasurementResult` gains the floor's samples and the routes; both speaker-test sessions fill them | Audio | Opus | |
| 3 | `RecordingManifest`, `RecordingExample`, `RecordingStore`, `RecordingPreference`, the store's calls; tests first | Store | Opus | |
| 4 | App: the preference, writing after keep, deleting on discard, sweep at launch, Settings section, Info.plist keys | App | Opus | |
| 5 | Module notes, device checklist, review | — | Fable | |

Done when: `make test` and `make build` pass; on the Mac a written example reads back bit for bit with every
manifest field; deleting a test, its system or room, all results or everything removes its folder; in the
simulator, with the setting on, a kept test leaves a folder in the app's Documents and a discarded one does not.
What the phone's own routes report, and that the Files app shows the folder, is verified on a device.
