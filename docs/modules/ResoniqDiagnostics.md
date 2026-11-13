---
type: "module"
spec_module: "B"
phase: 2
status: "active"
tags:
  - "module"
---
# ResoniqDiagnostics

Turns a speaker test's recordings into findings. One run's recording becomes its numbers (`RunAnalyzer`); a test's runs become a `SpeakerReport` (`SpeakerDiagnosis`): a verdict sentence, findings that each carry an evidence tag and the runs they rest on, and the portrait's shape. Every word the screens show about a diagnosis is made here (`DiagnosisText`); a view composes nothing. Pure code on top of [ResoniqDSP](ResoniqDSP.md), runs on the Mac. Plan: [phase-2-diagnose.md](../plans/phase-2-diagnose.md).

Paths below are relative to `ResoniqKit/Sources/ResoniqDiagnostics/`.

## Conventions

- **One grid.** Every curve (response, THD, the portrait) is on `ResponseGrid`: 241 log-spaced points from 20 Hz to 20 kHz, about 24 an octave (`Vocabulary.swift:96`).
- **Levels are relative.** A response is dB re the sweep, uncalibrated; it is read against its own trend or level-matched against another run. `RunMeasurement.referenceLevel` is the median from 300 Hz to 3 kHz (`ResponseComparison.defaultMatchBand`). No level is a sound pressure.
- **What the DSP measured, and nothing else.** A run is analysed only when `RecordingQuality.assess` says `.valid` and the recording holds the whole sweep (`ImpulseResponse.capturesWholeSweep`). Inside a run:
  - the response is read only inside `responseBand`, the impulse response's `trustedBand` within the grid; outside it the curve holds the edge value and nothing is raised from it;
  - THD is read only inside `HarmonicDistortion.trustedBand(order: 2, sweep:)` (80 Hz to about 9.3 kHz for `LogSweep.measurement`), and each point is a `DistortionReading`: `measured` where `SweepDistortion.isMeasurable(at:)` holds on the smoothed THD, otherwise `belowNoise` with the bound the floor gives (the floor raised by `SweepDistortion.measurableMarginDecibels`), or `notRead`.
- **Rules of evidence** (`SpeakerDiagnosis.swift:24–38`): a deviation in every valid run is `inferred`, "3 of 3 runs", medium confidence; in fewer but at least two, `inferred` with low confidence; in one, dropped. A dip above 14 kHz is `inconclusive`. A buzz is claimed only on `measured` THD; THD above the threshold but `belowNoise` is `inconclusive` (`distortionUnclear`), never a buzz. The even statement is `measured`, and its words name exactly the stretch where every run ruled a buzz out. An invalid run is reported and nothing is drawn from it; under two valid runs nothing is concluded. No score, and words hedge ("may be buzzing").
- **Not measured: rattle.** The plan lists the non-harmonic residue (rub, rattle) among a run's numbers. The DSP measures it only on a steady tone (`ToneDistortionResult.nonHarmonicResidue`); a sweep's deconvolution has no such figure. So it is not computed, and no sentence mentions rattle (`RunAnalysis.swift:207`).
- **Portrait outside the measured band.** The axis is 20 Hz to 20 kHz; outside the stretch every run measured, the portrait holds the width at the edge (`PortraitProfile.swift:13`, `SpeakerDiagnosis.consensusResponse` at `SpeakerDiagnosis.swift:157`). With `LogSweep.measurement` the trusted band covers the whole grid, so nothing is held.

## Public interface

### Runs

| Symbol | Where | Holds |
|---|---|---|
| `RecordingCheck` | `RunAnalysis.swift:6` | A run's check in storable form: `valid`, `clipped`, `tooQuiet`, `tooNoisy`, `silent`, `corrupt(nonFiniteSampleCount:)` (:18), `incomplete(capturedBand:)` (:27); `init(_ verdict:)` (:34), `isValid` (:45), `problem` (:48) |
| `RecordingCheck.Problem` | `RunAnalysis.swift:30` | `clipped`, `tooQuiet`, `tooNoisy`, `silent`, `corrupt`, `incomplete` |
| `DistortionReading` | `RunAnalysis.swift:62` | `notRead`, `measured(percent:)`, `belowNoise(readPercent:upperBoundPercent:)` |
| `RunMeasurement` | `RunAnalysis.swift:76` | `response`, `referenceLevel`, `responseBand`, `thdDecibels` (gross), `thdMeasurable`, `thdNoiseFloorDecibels`, `delay`, `bandCentres`, `bandSignalToNoise`; `init` (:108), `normalizedResponse` (:135), `isResponseMeasured(atIndex:)` (:138), `thdPercent(atIndex:)` (:143), `distortion(atIndex:)` (:148), `signalToNoise(at:)` (:159). The three newer fields are optional so reports stored before them still decode; nil counts as measured nowhere |
| `RunRecord` | `RunAnalysis.swift:167` | `check` and, for a valid run only, `measurement`; `init` (:171) |
| `RunAnalysis` | `RunAnalysis.swift:183` | `verdict` (the DSP's, with full numbers) and `record`; `init(verdict:measurement:)` (:191), `init(verdict:check:measurement:)` (:196), `isValid`, `measurement` |
| `RunAnalyzer.analyze(recording:sweep:noiseFloor:thresholds:quality:)` | `RunAnalysis.swift:218` | One run's numbers; an invalid or incomplete recording is not analysed |

### Reports and findings

| Symbol | Where | Holds |
|---|---|---|
| `SpeakerReport` | `SpeakerDiagnosis.swift:5` | `verdict`, `findings` (invalid runs first, then top of the portrait down), `profile`, `runs`, `consensusResponse`, `isConclusive`, `suspectedDefects` (:21) |
| `SpeakerDiagnosis.diagnose(runs:counterpart:thresholds:)` | `SpeakerDiagnosis.swift:43` | The report from a speaker's runs, and the other speaker's for a left/right comparison |
| `Finding` | `Finding.swift:7` | `id`, `kind`, `frequencyRange`, `bands`, `tag`, `basis`, `confidence`, `headline`, `detail`, `sentence`, `tagLine`, `confidenceStatement`, `repeatability`, `listenFrequency`, `context`, `numbers`, `recordingProblem`; `band` (:111) |
| `Finding.Kind` | `Finding.swift:8` | `responseDip`, `responsePeak`, `distortion`, `topEndDip`, `even`, `invalidRecording`, `leftRightDifference`, `distortionUnclear` (:25); `isDeviation` (:28) |
| `Finding.Confidence`, `Finding.Basis`, `Finding.Numbers` | `Finding.swift:37`, `:42`, `:56` | Low/medium/high (never high from one position); "3 of 3 runs"; the numbers behind a finding, per run |
| `EvidenceTag` | `Vocabulary.swift:4` | `measured`, `inferred`, `inconclusive`, `estimate`; `displayName` (:15) |
| `FrequencyRange` | `Vocabulary.swift:19` | `init(lower:upper:)` (:23), `centre`, `octaves`, `contains`, `overlaps(_:toleranceOctaves:)` (:38), `widened(octaves:)` (:44) |
| `DriverBand` | `Vocabulary.swift:59` | `woofer`, `middle`, `tweeter`; `wooferUpperFrequency` 300 Hz (:65), `tweeterLowerFrequency` 3 kHz (:67), `init(frequency:)` (:69), `range` (:80), `displayName` (:89) |
| `ResponseGrid` | `Vocabulary.swift:96` | `lowerFrequency`, `upperFrequency`, `count`, `frequencies` (:102), `pointsPerOctave` (:107), `nearestIndex(to:)` (:110) |
| `DiagnosisText` | `DiagnosisText.swift:8` | Every user-facing string; public: `rounded(_:)` (:50), `frequency(_:)` (:56), `range(_:)` (:62) |
| `DiagnosisThresholds` | `DiagnosisThresholds.swift:8` | Every number that turns measurements into findings, 17 fields (:14–90), `init` (:92), `standard` (:131) |

### Portrait

| Symbol | Where | Holds |
|---|---|---|
| `PortraitProfile` | `PortraitProfile.swift:18` | `referenceWidth` 0.8 (:20), `dynamicRange` 30 dB (:22), `frequencies`, `widths`, `deviations`, `heardUpTo` (:25–33), `init(response:deviations:)` (:37), `notHeard` (:58), `live(envelope:sweep:delay:)` (:74) |
| `LevelEnvelope` | `PortraitProfile.swift:100` | The recording's level in 5 ms blocks for the live portrait; `blockDuration` (:102), `init(sampleRate:)` (:110), `init(samples:sampleRate:)` (:115), `append` (:127), `level(from:to:)` (:141) |

## Thresholds and constants

`DiagnosisThresholds.standard` (`DiagnosisThresholds.swift:131`). "First guess" means checked only against simulated speakers.

| Field | Value | Note |
|---|---|---|
| `smoothingFraction` | 3 (1/3 octave) | From the plan |
| `trendWindowOctaves` | 5 octaves | First guess; with outlier rejection |
| `responseLowerFrequency` | 50 Hz | First guess |
| `topEndFrequency` | 14 kHz | From the plan: a dip above is inconclusive |
| `deviationDecibels` | 6 dB | First guess |
| `edgeDecibels` | 3 dB | The design system's "even" band |
| `minimumDeviationOctaves` | 1/3 | The smoothing's width |
| `distortionSmoothingFraction` | 12 | |
| `distortionLowerFrequency` | 40 Hz | First guess; the DSP's 80 Hz trusted band sets the bottom with the measurement sweep |
| `distortionPercent` | 10 % | First guess; counts only where THD is measurable |
| `minimumDistortionOctaves` | 1/6 | First guess; also the narrowest stretch the even statement names |
| `samePlaceOctaves` | 1/3 | First guess; also how close an unclear stretch may be to a buzz before it is taken as the buzz's skirt |
| `minimumAgreeingRuns` | 2 | From the plan |
| `minimumValidRuns` | 2 | |
| `mediumConfidenceRuns` | 3 | From the plan |
| `leftRightDecibels` | 6 dB | First guess |
| `minimumBandSignalToNoise` | 10 dB | First guess; an octave band under it is not assessed |

The measurability margin is the DSP's (`SweepDistortion.measurableMarginDecibels`, 10 dB) and is not restated. Other constants: `PortraitProfile.referenceWidth` 0.8 and `dynamicRange` 30 dB, `LevelEnvelope.blockDuration` 5 ms, `DriverBand` limits 300 Hz and 3 kHz, `Trend.rejectionPasses` 3 (internal, `Deviations.swift:6`).

## Tests

`ResoniqKit/Tests/ResoniqDiagnosticsTests/`, run on the Mac by `make test`. Simulated runs use the measurement sweep's range (10 Hz to 22 kHz) over `LogSweep.minimumAccurateDuration` (3 s); tests about the response alone use 2 s (`Bench.responseSweep`). One noise floor per room, as the app measures it.

- `HealthySpeakerTests`: no deviation, no inferred and no unclear finding for a healthy speaker over four quiet seeds and at 20 dB (two seeds), 25 and 30 dB signal-to-noise; an uneven but healthy speaker; the margin to every threshold; the even statement (`measured`, "Distortion stayed under 10 % from 80 Hz to 9.2 kHz."); the review's case, a clean speaker at 20 dB whose THD reads 3.7 % at 5 kHz from noise alone: no buzz, and the even statement stops below 2 kHz.
- `DistortionTests`: a buzz in 3, 2 and 1 of 3 runs; its words and numbers; a buzz at the 20 dB gate is still measured.
- `ResponseTests`: a dip, a peak, a top-end dip (inconclusive), the mockup's result.
- `InvalidRecordingTests`: clipped, too noisy, too few valid runs, corrupt ("One run came back damaged"), cut short ("One run was cut short", nothing drawn from the part it holds).
- `EvidenceTests`, on hand-built readings: THD over the threshold below the noise is inconclusive and not a buzz, the same clear of the noise is a buzz, unclear in one run is dropped, a floor too high to rule a buzz out is not called clean, nothing measurable at all, nothing raised from held values and the portrait holds its edges.
- `LeftRightTests`, `WordingTests` (mockup frequencies, no confirmed defect, no score, a report survives JSON), `RunAnalyzerTests`, `PortraitProfileTests`, `DriverBandTests`, `ResponseGridTests`.
- `SimulatedSpeaker`: not a test; the simulated speaker, the seeded noise and `Bench`.

The suite takes about 12 to 15 s on the Mac, most of it the deconvolution of 3 s sweeps in a debug build.

## Limits

- A finding rests on one microphone position: a dip or a buzz may be the room, or something near the speaker. Confidence is never high.
- THD is read from 80 Hz to about 9.3 kHz only (the second harmonic's trusted band); a buzz outside that range is never seen, and one that starts under 80 Hz is reported from 80 Hz (the simulated 72–110 Hz buzz reads "80–110 Hz", where the mockup says 70–110 Hz).
- Rattles and rub that are not harmonics are not measured from a sweep.
- In a noisy room the even statement covers less, and a buzz near the threshold becomes "too noisy to tell". At the 20 dB gate a healthy speaker's distortion is ruled out only up to about 1.3 kHz.
- A run that does not hold the whole sweep is discarded, not analysed over what it holds.
- Band signal-to-noise restates the frame length `NoiseFloor` uses for its bands, because that helper is internal to the DSP.

## Open questions

- Every first guess above, on real speakers in real rooms: the 10 % buzz threshold, 6 dB deviations, the 5-octave trend, 10 dB band signal-to-noise.
- Whether a healthy woofer at a loud level reads above 10 % in the deep bass, which would need a level-dependent threshold.
- Whether "too noisy to tell" should be shown at all when the verdict is healthy, or folded into the even statement's range.
- A steady-tone check (`ToneDistortion`) for the residue, run only where the sweep found something, would make "rattle" measurable.
- Only on a real iPhone: the microphone's own roll-off under 100 Hz and its distortion at loud levels (both read as the speaker's), how far off axis the phone's top end falls (the 14 kHz rule), how much a real room's reverberation in the noise-floor stretch pushes distortion towards "not measurable", and how a real recording's signal-to-noise per band compares with the simulation's white noise.
