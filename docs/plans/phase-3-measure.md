---
type: "plan"
phase: 3
status: "planned"
tags:
  - "plan/phase-3"
---
# Phase 3 · Measure

Goal: the user sits where they listen, the app measures at three spots around the head, and says in a sentence
how the system sounds at the seat, with the curve and up to three findings. The screens are Measure home, Sit
and aim, Three spots, The numbers and the live spectrum, from the mockups in
[design/screens](../../design/screens/README.md).

## How a seat measurement works

1. **Three spots**: the seat, then 30 cm to the left, then 30 cm to the right, so one odd spot cannot decide
   the result. A spot is captured by itself once the phone has been still for a moment; a rigid haptic marks it.
2. **At each spot** the left speaker plays the sweep, then the right (one channel only for a single speaker).
   The run machinery is the one from phase 2: noise floor first, pause on noise, splice, check the recording.
3. **Per recording** the room response is read with a long window (the room is the subject here, so
   reflections stay in), distortion as in Diagnose, and the decay of the bass from the impulse response.
4. **The seat's curve** is the power average over the three spots of left and right together. Left and right
   are also kept apart, averaged over the spots, for the comparison.
5. **Findings**, at most three, strongest first: bass peaks and dips with their frequency and size
   (`measured`), whether the rest is even and how closely left matches right (`measured`, with the figure), and
   whether the unevenness looks like the room (`inferred`, with its basis).

## Who decides what

| Decision | Module | Symbol (contract) |
|---|---|---|
| Decay time by band from an impulse response | `ResoniqDSP` | `Decay.estimate(impulseResponse:band:) -> DecayEstimate?` (Schroeder integration; `nil` when the dynamic range is too small to say) |
| In-room response from an impulse response | `ResoniqDSP` | `ImpulseResponse.frequencyResponse(preWindow:postWindow:)` with `ImpulseResponse.roomPostWindow` |
| Power average of several responses | `ResoniqDSP` | `ResponseAverage.power(_:) -> MagnitudeResponse` |
| One spot's numbers | `ResoniqDiagnostics` | `SpotAnalyzer.analyze(left:right:sweep:noiseFloor:) -> SpotAnalysis` |
| The seat's result | `ResoniqDiagnostics` | `SeatDiagnosis.diagnose(spots: [SpotAnalysis], room: RoomHint?) -> SeatReport` (verdict, curve on `ResponseGrid`, the even band, labelled extremes, findings, left and right curves, the numbers table rows, whether it is conclusive) |
| What "even" means | `ResoniqDiagnostics` | `SeatThresholds.evenBandDecibels` (±3 dB, the design system's band), one definition |
| The three-spot procedure | `ResoniqAudio` | `SeatMeasurementSession` (states: waiting for stillness at spot n, playing left or right at spot n, paused, checking, finished, failed) built on the phase 2 run machinery |
| The live spectrum | `ResoniqAudio` | `LiveSpectrum` (an async sequence of `MagnitudeResponse` in third-octave bands from the microphone) |
| Kept seat measurements | `ResoniqStore` | `SeatMeasurement` model in schema version 2, `keep(_: SeatReport, in:)`, `latestSeatMeasurement(in:)`, `seatHistory(in:)` |

Rules the seat diagnosis must follow:

- A peak or dip is reported with its frequency and its size against the curve's own middle level, and only when
  it leaves the even band in the average of the three spots.
- "It's the room, not the speakers" is `inferred`, never `measured`. Its basis is stated: the room's size when a
  scan exists ("Inferred from room size"), otherwise that the unevenness is in the bass, narrow, and changes
  from spot to spot ("Inferred from how it changes between spots"). Without either it is not said.
- Decay is always an `estimate`, shown with "≈", and is not given when the recording cannot support it.
- Left against right is a `measured` difference with its figure ("within 1.2 dB").
- Levels are approximate and the screens say so (the footnote on The numbers).
- A spot whose recording is not valid is repeated; a seat result needs three valid spots.

## Tasks

| # | Task | Module | Model | Status |
|---|---|---|---|---|
| 1 | `Decay`, `ResponseAverage`, room window | DSP | Opus | todo |
| 2 | `SpotAnalyzer`, `SeatDiagnosis`, `SeatReport`, `SeatThresholds`, numbers table rows, texts | Diagnostics | Opus | todo |
| 3 | `SeatMeasurementSession`, `LiveSpectrum`, simulated room for tests | Audio | Opus | todo |
| 4 | `SeatMeasurement` in schema version 2 with a migration | Store | Sonnet | todo |
| 5 | Components: response curve (even band, extremes, before trace, left and right on a decibel grid), three-spot diagram, values table, live spectrum bars | Design | Sonnet | todo |
| 6 | Screens: Measure home (and its empty state), Sit and aim, Three spots, The numbers, Watch the sound live; wiring | App | Sonnet | todo |
| 7 | Check against the mockups in the simulator; module notes | — | Fable | todo |

Done when: `make test` and `make build` pass; in the simulator, with simulated audio, a seat measurement runs
from Sit and aim to Measure home and the screens match their mockups. Real rooms are verified on a device.
