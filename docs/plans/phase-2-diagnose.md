---
type: "plan"
phase: 2
status: "done"
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
| 1 | `RunAnalyzer`, `PortraitProfile`, `DriverBand`, `Finding`, `EvidenceTag`, `SpeakerDiagnosis`, `SpeakerReport` | Diagnostics | Opus | done |
| 2 | `AudioIO` protocol, `AVAudioEngine` implementation, session configuration, `MeasurementSession`, splicing, `MicrophonePermission`, `StillnessMonitor`, simulated IO for tests | Audio | Opus | done |
| 3 | SwiftData models, default room and system, saving and loading a `SpeakerReport`, quick check that saves nothing | Store | Sonnet | done |
| 4 | Components: speaker portrait (not heard, drawing, paused, deviation), readout, status pill, segmented control, hold-to-hear, evidence tag | Design | Sonnet | done |
| 5 | Diagnose flow model in the app (wires Audio → Diagnostics → Store) and the screens Aim, Listening, Paused | App | Sonnet | done |
| 6 | Screens Result, Finding, Diagnose home; hold-to-hear tone playback | App | Sonnet | done |
| 7 | States with no mockup: microphone denied, recording clipped or too quiet, all speakers healthy | App | Sonnet | done |
| 8 | Check against the mockups in the simulator with a simulated `AudioIO`; module notes | — | Fable | module notes done; the comparison with the mockups is not recorded |

Tasks 1 to 4 run in parallel (three at a time); 5 to 7 follow.

Done when: `make test` and `make build` pass; in the simulator, with the simulated audio, a test runs from Aim
to Result and the screens match their mockups. Playing and recording through real speakers is verified on a
device by the owner and listed as not verified until then.

## Notes

**Delivered with phase 3.** Phases 2 and 3 go into one pull request: the review fixes for phase 2 were made on the phase 3 branch (`feat/phase-3-measure`), after the DSP was hardened in phase 1 and the audio and diagnostics modules had to be adapted to it. The tables above give the contract as planned; the built interface is in the module notes ([ResoniqAudio](../modules/ResoniqAudio.md), [ResoniqDiagnostics](../modules/ResoniqDiagnostics.md), [ResoniqStore](../modules/ResoniqStore.md), [ResoniqDesign](../modules/ResoniqDesign.md), [App](../modules/App.md)).

**What differs from the plan.**

- Every run plays `LogSweep.measurement` (10 Hz to 22 kHz, 4 s), not a 20 Hz to 20 kHz sweep; the response is reported from 20 Hz to 20 kHz.
- Findings hedge in their headlines ("Possible buzz at 80–110 Hz") where the mockups state the defect ("Buzz at 70–110 Hz"), because a suspected defect is never stated as confirmed. The even statement says what was checked and what was not (distortion below 80 Hz).
- The route to the speakers is checked before any sound: with nothing connected the phone plays through its receiver, and the app would have diagnosed that as the left speaker. Both sessions fail with `speakersNotConnected`; the tone player refuses too. Not in the plan.
- A rattle or a reverberant room no longer pauses a run for ever: noise that returns where it first paused the run is tied to the sweep, a run pauses at most six times, and a pause past 30 s ends the test as too noisy.
- Two takes are spliced only if the route's delay did not move between them (30 µs).
- New finding kinds beyond the plan's list: a quiet band ("I could barely hear the woofer"), a band not assessed, a rattle, unclear distortion. The app's exhaustive switches over `Finding.Kind` had to learn each in the same change.
- States with no mockup were built from the design system and listed as such in each file's header: microphone denied, repeating a run, failed (clipped or too quiet), failed too noisy, speakers not connected, all speakers healthy, quiet woofer, not assessed.
- Hold to hear shows the tone player's error under the control and resets when the Kit ends a tone after its limit (20 s).

**What the review found, and what was fixed.** An independent review of the audio, diagnostics and app layers found, among others:

- `EngineAudioIO` depended on the player's timeline, which is unknown after every stop; scheduling now comes from the tap's host-time anchor; stops fade over 6 ms; one session owner. Device-only, checked by an iOS build.
- Findings said more than was assessed: the Kit now says only what was assessed about a speaker and about a seat ("sounds even" only for the assessed band), and a test runs the wording rules over every fixture report.
- Unmeasured distortion and response were drawn as zero in the run traces; they are gaps now.
- The left/right comparison could use a run the user had chosen not to keep; it holds only kept tests now.
- Hold to hear swallowed its failures; each finding kind now decides its own row and next steps.
- The sweep noise detector's peak interpolation could run off the spectrum.

**Not verified until a device test.** Nothing in Diagnose has run on an iPhone: the real engine, microphone permission, route detection and delays (cable, Bluetooth, AirPlay), the sweep at the safe level (and the 10 Hz start on a vented speaker), pausing and resuming on real noise, hold to hear, and every first-guess threshold. The steps are in the [device checklist](../device-checklist.md).
