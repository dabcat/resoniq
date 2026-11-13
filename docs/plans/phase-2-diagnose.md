---
type: "plan"
phase: 2
status: "active"
tags:
  - "plan/phase-2"
---
# Phase 2 · Diagnose

Goal: a user launches the app, aims the phone at a speaker, and gets a portrait of it with findings that say
how they are known. The flow is Aim → Listening → Paused → Result → Finding → Diagnose home, from the mockups
in [design/screens](../../design/screens/README.md).

## How a test works

One test of one speaker is **three runs** of the same sweep (`LogSweep`, 20 Hz to 20 kHz). Three, because a
finding is only "Inferred" when it repeats ("3 of 3 runs").

1. **Before the first run** the app listens to the room for about a second and measures the noise floor.
2. **A run** plays the sweep on the chosen channel (left, right, or both for "Only one") and records the
   microphone. The recording continues after the sweep ends until the sound has arrived and died away, because
   the route to the speakers (cable, Bluetooth, AirPlay) adds a delay nobody tells us.
3. **If the room gets noisy** the run pauses. The engine keeps recording. When the room is quiet again the
   sweep restarts a little before the frequency where it stopped. The two takes are then spliced into one
   recording at a point before the noise began: the sweep is deterministic and the speaker is the same, so the
   splice is the recording an uninterrupted run would have given. This is what "I'll pick up at 1 kHz" means.
4. **After each run** the recording is checked (clipped, too quiet, too noisy, silent). A bad run is repeated
   once with the reason shown; a second failure ends the test with an inconclusive result.
5. **After three runs** each is analysed on its own (response, distortion), then the three are compared.

While a run plays, the portrait fills upward: the level of the recording at each moment is the level at the
frequency being played at that moment. The finished portrait is drawn from the smoothed frequency response.

## Who decides what

| Decision | Module | Symbol (contract) |
|---|---|---|
| One run's numbers from its recording | `ResoniqDiagnostics` | `RunAnalyzer.analyze(recording:sweep:noiseFloor:) -> RunAnalysis` (verdict on the recording, 1/3-octave response on a log grid, THD against frequency, non-harmonic residue) |
| The portrait's shape | `ResoniqDiagnostics` | `PortraitProfile` (widths 0…1 at log-spaced frequencies from 20 Hz to 20 kHz); `PortraitProfile(response:)` and `PortraitProfile.live(envelope:sweep:delay:)` |
| Which driver a frequency belongs to | `ResoniqDiagnostics` | `DriverBand` (`woofer`, `middle`, `tweeter`) and `DriverBand(frequency:)`; band limits defined once |
| Findings from the runs | `ResoniqDiagnostics` | `SpeakerDiagnosis.diagnose(runs: [RunAnalysis], counterpart: [RunAnalysis]?) -> SpeakerReport` |
| What a finding is | `ResoniqDiagnostics` | `Finding` (kind, frequency range, `EvidenceTag`, basis such as "3 of 3 runs", headline, detail), `EvidenceTag` (`measured`, `inferred`, `inconclusive`, `estimate`), `SpeakerReport` (verdict sentence, findings, profile, runs) |
| Playing, recording, pausing, splicing | `ResoniqAudio` | `MeasurementSession` (state machine) over an `AudioIO` protocol; `SpeakerChannel` (`left`, `right`, `both`); `MeasurementSession.State`; live `MeasurementProgress` (run number, frequency playing, room level, input level, clipping, phone steady) |
| Microphone permission | `ResoniqAudio` | `MicrophonePermission` |
| Whether the phone is steady | `ResoniqAudio` | `StillnessMonitor` protocol, Core Motion implementation on iOS |
| Rooms, systems, kept results | `ResoniqStore` | SwiftData `Room`, `SoundSystem`, `SpeakerTest`; `ResoniqStore.defaultContext` gives "My room · My speakers" |

`MeasurementSession` is tested on the Mac against a simulated `AudioIO` that plays the signal through a
simulated speaker, adds a delay, and can inject noise at a chosen moment. `RunAnalyzer` and `SpeakerDiagnosis`
are tested with synthetic recordings: a healthy speaker, one with a distortion band, one with a response dip.

Rules the diagnosis must follow:

- A deviation that appears in all three runs at the same place is `inferred`, with the basis "3 of 3 runs". In
  two of three, `inferred` with "2 of 3 runs" and lower confidence. In one, it is dropped.
- A dip above 14 kHz is `inconclusive` ("could be the phone's angle"): a phone microphone off axis loses the top.
- A statement that something is even or clean is `measured`.
- Words hedge: "may be buzzing", never "is broken". No score.
- If a run's recording is not valid the report says so and concludes nothing from it.
- Levels are shown as approximate: the microphone is not calibrated. The one offset from dBFS to the "dB"
  shown on screen is a named constant in the Kit, marked as an estimate.

## Tasks

| # | Task | Module | Model | Status |
|---|---|---|---|---|
| 1 | `RunAnalyzer`, `PortraitProfile`, `DriverBand`, `Finding`, `EvidenceTag`, `SpeakerDiagnosis`, `SpeakerReport` | Diagnostics | Opus | todo |
| 2 | `AudioIO` protocol, `AVAudioEngine` implementation, session configuration, `MeasurementSession`, splicing, `MicrophonePermission`, `StillnessMonitor`, simulated IO for tests | Audio | Opus | todo |
| 3 | SwiftData models, default room and system, saving and loading a `SpeakerReport`, quick check that saves nothing | Store | Sonnet | todo |
| 4 | Components: speaker portrait (not heard, drawing, paused, deviation), readout, status pill, segmented control, hold-to-hear, evidence tag | Design | Sonnet | todo |
| 5 | Diagnose flow model in the app (wires Audio → Diagnostics → Store) and the screens Aim, Listening, Paused | App | Sonnet | todo |
| 6 | Screens Result, Finding, Diagnose home; hold-to-hear tone playback | App | Sonnet | todo |
| 7 | States with no mockup: microphone denied, recording clipped or too quiet, all speakers healthy | App | Sonnet | todo |
| 8 | Check against the mockups in the simulator with a simulated `AudioIO`; module notes | — | Fable | todo |

Tasks 1 to 4 run in parallel (three at a time); 5 to 7 follow.

Done when: `make test` and `make build` pass; in the simulator, with the simulated audio, a test runs from Aim
to Result and the screens match their mockups. Playing and recording through real speakers is verified on a
device by the owner and listed as not verified until then.
