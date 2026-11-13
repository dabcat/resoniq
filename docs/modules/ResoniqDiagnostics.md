---
type: "module"
spec_module: "B"
phase: 3
status: "active"
tags:
  - "module"
---
# ResoniqDiagnostics

Turns a speaker test's recordings into findings. One run's recording becomes its numbers (`RunAnalyzer`); a test's runs become a `SpeakerReport` (`SpeakerDiagnosis`): a verdict sentence, findings that each carry an evidence tag and the runs they rest on, and the portrait's shape. Every word the screens show about a diagnosis is made here (`DiagnosisText`); a view composes nothing. Recordings at the listening seat become a `SeatReport` (`SpotAnalyzer`, `SeatDiagnosis`), and two seat reports a `ComparisonReport` (`SeatComparison`). Pure code on top of [ResoniqDSP](ResoniqDSP.md), runs on the Mac. Plan: [phase-2-diagnose.md](../plans/phase-2-diagnose.md).

Paths below are relative to `ResoniqKit/Sources/ResoniqDiagnostics/`.

## Conventions

- **One grid.** Every curve (response, THD, the portrait) is on `ResponseGrid`: 241 log-spaced points from 20 Hz to 20 kHz, about 24 an octave (`Vocabulary.swift:96`).
- **Levels are relative.** A response is dB re the sweep, uncalibrated; it is read against its own trend or level-matched against another run. `RunMeasurement.referenceLevel` is the median from 300 Hz to 3 kHz (`ResponseComparison.defaultMatchBand`). No level is a sound pressure.
- **What the DSP measured, and nothing else.** A run is analysed only when `RecordingQuality.assess` says `.valid` and the recording holds the whole sweep (`ImpulseResponse.capturesWholeSweep`). Inside a run:
  - the response is read only inside `responseBand`, the impulse response's `trustedBand` within the grid; outside it the curve holds the edge value and nothing is raised from it;
  - THD is read only inside `HarmonicDistortion.trustedBand(order: 2, sweep:)` (80 Hz to about 9.3 kHz for `LogSweep.measurement`), and each point is a `DistortionReading`: `measured` where `SweepDistortion.isMeasurable(at:)` holds on the smoothed THD, otherwise `belowNoise` with the bound the floor gives (the floor raised by `SweepDistortion.measurableMarginDecibels`), or `notRead`.
- **Rules of evidence** (`SpeakerDiagnosis.swift:24–38`): a deviation in every valid run is `inferred`, "3 of 3 runs", medium confidence; in fewer but at least two, `inferred` with low confidence; in one, dropped. A dip above 14 kHz is `inconclusive`. A buzz is claimed only on `measured` THD; THD above the threshold but `belowNoise` is `inconclusive` (`distortionUnclear`), never a buzz. The even statement is `measured`; a driver is in it only when its response stays within `EvenBand.decibels` (±3 dB, the one definition the seat uses too) of its trend over its judged range (woofer 50–300 Hz, mid 300 Hz–3 kHz, tweeter 3–14 kHz, cut short where a top-end dip begins) and no deviation or inconclusive finding overlaps it; between 3 and 6 dB a driver is simply left out, neither even nor suspect. Its words name the response stretch, the stretch where every run ruled a buzz out, and, when the woofer is in it, that distortion was not checked below 80 Hz. A driver whose level is 15 dB or more under the loudest other is "barely heard" (`quietBand`, `measured`, cause left open); one too close to the room's noise is `notAssessed` (`inconclusive`), and the verdict calls healthy only the drivers checked; with nothing assessed the report is not conclusive. An invalid run is reported and nothing is drawn from it; under two valid runs nothing is concluded. No score, and words hedge ("may be buzzing", "Possible buzz").
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
| `Finding.Kind` | `Finding.swift:8` | `responseDip`, `responsePeak`, `distortion`, `topEndDip`, `even`, `invalidRecording`, `leftRightDifference`, `distortionUnclear`, `quietBand` (:29, a deviation), `notAssessed` (:32); `isDeviation` (:35) |
| `EvenBand.decibels` | `Vocabulary.swift:20` | ±3 dB, the one definition of "even" for speakers and seats |
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

### Seat (phase 3) and before-and-after (phase 5)

In `Seat/`. Plans: [phase-3-measure.md](../plans/phase-3-measure.md), [phase-5-ar.md](../plans/phase-5-ar.md).

| Symbol | Where | Holds |
|---|---|---|
| `SpotAnalyzer.analyze(left:right:sweep:noiseFloor:thresholds:quality:) -> SpotAnalysis` | `Seat/SpotAnalysis.swift:92` | One spot: each recording checked like a run, deconvolved, read with `ImpulseResponse.roomPostWindow`, smoothed into a room curve; THD at 1 kHz where measurable; `Decay.bass` (given the sweep) |
| `SpotAnalyzer.roomCurve(_:thresholds:)` | `Seat/SpotAnalysis.swift:154` | The one definition of a seat curve's smoothing: 1/12 octave under 200 Hz, 1/3 above, blended over an octave |
| `SpotAnalysis` | `Seat/SpotAnalysis.swift:63` | `left`, `right` (nil for one speaker), `isValid` (every recording it needs), `problems` |
| `SpotRecording`, `SpotMeasurement` | `Seat/SpotAnalysis.swift:49`, `:5` | A recording's `check` and, when valid, its `response` (dB re sweep, on `ResponseGrid`), `responseBand`, band signal-to-noise, `distortionPercent`, `bassDecay`; public inits for fixtures |
| `SeatDiagnosis.diagnose(spots:room:thresholds:) -> SeatReport` | `Seat/SeatDiagnosis.swift:55` | The seat's result; rules of evidence in the doc comment (`:35–50`) |
| `RoomHint` | `Seat/SeatReport.swift:5` | Width, length, height in metres, each optional; axial modes c/2L·n computed here (c = 343 m/s, `SeatDiagnosis.swift:53`), no dependency on `ResoniqRoom` |
| `SeatReport` | `Seat/SeatReport.swift:159` | `schemaVersion` (`currentSchemaVersion` 1), `verdict`, `isConclusive`, `validSpotCount`, `requiredSpotCount`, `spots` (`SpotCheck`), `curve`, `leftCurve`, `rightCurve`, `spotCurves`, `spread`, `assessed`, `evenBandDecibels`, `extremes`, `leftRightDifference`, `findings`, `numbers`, `distortionPercent`, `bassDecay`; `displayedFindings` (first three, :246), `placementTargets` (bass extremes, :249), `progress` ("1 of 3 in"), `footnote`, `level(at:)` |
| `SeatExtreme` | `Seat/SeatReport.swift:18` | `kind` (`peak`, `dip`), `frequency` (interpolated), `deviation` (signed dB re middle), `range`, `spread`; `label` "41 Hz +9 dB", `frequencyLabel`, `valueLabel` "+9.2 dB". Maps onto `AcousticProblem(frequency:deviation:kind:)` in the app |
| `SeatFinding` | `Seat/SeatReport.swift:62` | `kind` (`bass`, `rest`, `leftRight`, `roomCause`, `invalidSpot`), `tag`, `basis` (`SeatBasis`: `roomSize`, `spotToSpot`), `isDeviation`, `headline`, `tagLine`, `detail`, `strength` |
| `SeatNumberRow` | `Seat/SeatReport.swift:107` | `kind`, `label`, `value`, `word`, `tag`: "41 Hz · +9.2 dB · peak · Measured", "< 80 Hz · ≈ 0.6 s · decay · Estimate" |
| `SeatDecay`, `SpotCheck` | `Seat/SeatReport.swift:128`, `:143` | Bass band and RT60; a spot's two recording checks |
| `SeatThresholds` | `Seat/SeatThresholds.swift:8` | 25 fields, `standard` (:185) |
| `SeatComparison.compare(before:after:targeting:thresholds:) -> ComparisonReport` | `Seat/SeatComparison.swift:98` | Verdict, rows, note, outcome; rules in the doc comment |
| `SeatComparison.repeatability(at:before:after:thresholds:)` | `Seat/SeatComparison.swift:194` | The one definition of the least change that counts |
| `ComparisonReport` | `Seat/SeatComparison.swift:52` | `schemaVersion` (1), `verdict`, `rows`, `note`, `outcome` (`ComparisonOutcome`: `improved`, `unchanged`, `worse`, `mixed`), `nextTarget`, `isConclusive`, `tag` (`measured`) |
| `ComparisonRow` | `Seat/SeatComparison.swift:21` | `label`, `before`, `after`, `status`, `change` (`ComparisonChange`), `beforeDecibels`, `afterDecibels`, `frequency`, `tag` |
| `SeatText` | `Seat/SeatText.swift:6` | Every seat and comparison string; public: `frequency(_:)` (whole hertz under 1 kHz), `signedDecibels(_:)`, `signedDecibelsTenths(_:)` (U+2212 minus) |

How the seat result is made:

- **Curves.** The seat curve is the power average (`ResponseAverage.power`) of every valid recording (three spots × left and right), 0 dB at its middle: the median from 200 Hz to 4 kHz over assessed points. Left, right and spot curves are on the same reference, so a balance error shows. The spread is `ResponseAverage.spread` of the spot curves.
- **Assessed.** A grid point counts only inside every recording's measured band, with at least 10 dB in its octave band over the room's noise.
- **Extremes.** Where the seat curve leaves ±3 dB between 30 Hz and 10 kHz, at least 1/24 octave wide; a dip that runs into 30 Hz is roll-off and dropped. The frequency and size are the vertex of a parabola through the three grid points around the summit.
- **Findings**, deviations strongest first, then statements, then the cause: bass (`measured`, "One bass note booms, one nearly vanishes"; "nearly vanishes" from 8 dB); voices and treble even or uneven (`measured`), merged with "left matches right" and its figure when both hold; left and right differing by more than 3 dB is its own `measured` deviation and nothing says they match; the cause (`inferred`) only with a basis: every bass extreme within 1/24 octave of an axial mode of the hinted room ("Inferred from room size."), otherwise every bass extreme no wider than half an octave and the spots at least 3 dB apart there ("Inferred from how it changes between spots."). A hint whose modes miss is no basis; the spots are then asked.
- **Figures.** Distortion at 1 kHz and the bass decay are the median of the recordings that have one, given only when at least half of them do. Decay is an `estimate`, written "≈ 0.6 s".
- **Spots.** Three valid spots are needed. With fewer the report is inconclusive, says which spot needs measuring again and why, and still carries the running average and the spots measured so far. Failed spots are not reported once the result is conclusive.
- **Comparison.** A targeted extreme is read in the second measurement as the deepest (dip) or highest (peak) point within 1/6 octave; a change counts beyond the repeatability (1.5 dB, or a quarter of the two measurements' mean spread there). Untargeted bass extremes of the first measurement, new bass extremes in the second and voices-and-treble each get a row, so a move that made something else worse is reported. Verdicts: "The missing bass note is back." (the most improved target is a dip now under 8 dB), "The booming bass note is calmer now.", "It's a little better: …", "Nothing changed that I can measure.", "It sounds worse from your seat than before.", "It's better in one place and worse in another."; an incomplete measurement compares nothing.

## Thresholds and constants

`DiagnosisThresholds.standard` (`DiagnosisThresholds.swift:148`). "First guess" means checked only against simulated speakers.

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
| `quietBandDecibels` | 15 dB | First guess; a driver this far under the loudest other is "barely heard" |
| `quietBandLowerFrequency` | 100 Hz | First guess; the woofer's level is read from here to 300 Hz |

`SeatThresholds.standard` (`Seat/SeatThresholds.swift:185`):

| Field | Value | Note |
|---|---|---|
| `smoothingFraction` | 3 (1/3 octave) | Above the bass; from the plan |
| `bassSmoothingFraction` | 12 | First guess; keeps a narrow mode's summit |
| `smoothingCrossoverFrequency` | 200 Hz | Blended over an octave |
| `middleBand` | 200 Hz–4 kHz | 0 dB on every seat curve |
| `evenBandDecibels` | ±3 dB | The design system's even band |
| `lowerFrequency` / `upperFrequency` | 30 Hz / 10 kHz | First guesses |
| `bassUpperFrequency` | 200 Hz | First guess (≈ Schroeder frequency of a living room) |
| `trebleLowerFrequency` | 3 kHz | "Voices" below, "treble" above |
| `minimumExtremeOctaves` | 1/24 | |
| `vanishingDipDecibels` | 8 dB | First guess; "nearly vanishes", "a little strong" |
| `leftRightLowerFrequency` | 200 Hz | |
| `leftRightDecibels` | 3 dB | First guess |
| `narrowOctaves` | 1/2 | First guess |
| `spotDisagreementDecibels` | 3 dB | First guess |
| `roomModeOctaves` | 1/24 | First guess |
| `roomModeUpperFrequency` | 200 Hz | |
| `distortionFrequency` | 1 kHz | The mockup's row |
| `distortionSmoothingFraction` | 3 | |
| `minimumFigureShare` | 1/2 | |
| `requiredSpots` | 3 | From the plan |
| `minimumBandSignalToNoise` | 10 dB | First guess, as for speakers |
| `repeatabilityDecibels` | 1.5 dB | First guess |
| `repeatabilitySpreadShare` | 1/4 | First guess |
| `samePlaceOctaves` | 1/6 | |

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
- `SimulatedRoom` (not a test): a speaker pair with a 25 Hz roll-off and a mild nonlinearity, room modes as peaking filters whose gain changes per spot, a channel tilt (high shelf), one early reflection per spot, white or low-passed noise, a route delay; expectations from the filter coefficients alone. `SeatBench` shares each room's spots.
- `MockupSeatTests`: the mockup's room (41 Hz +12/+9.5/+7 dB Q 8, 61 Hz −16.3/−11.1/−13.4 dB Q 7, right +1.2 dB above 3 kHz, 3 s sweep) gives the mockup's verdict, extremes ("41 Hz +9 dB", "+9.2 dB"; "61 Hz −11 dB", "−11.4 dB"), three findings with tags and tag lines, table rows; measured 41.02 Hz +9.21 dB (expected 41.0 Hz +9.58), 61.18 Hz −11.40 dB (expected −12.90: a deep narrow dip reads up to 1.5 dB shallow), L/R 1.19 dB (1.19), THD 0.42 % (0.39 %), decay 0.74 s (the boom's poles ring 0.74 s); the cause without a hint rests on the spots; a mismatched hint is no basis; JSON round trip.
- `EvenSeatTests`: three noise seeds, no extreme, no deviation, no cause (worst deviation 1.9 dB).
- `SeatCauseTests`: a 90 Hz peak the same at every spot is not blamed on the room, with no hint or a mismatched one; left and right 5 dB apart in the treble; one speaker.
- `SeatInvalidTests`, `SeatDecayTests`: two valid spots are inconclusive; a clipped recording invalidates its spot with the reason; no decay in a 40 Hz rumble 14 dB under the recording (the gate relaxed to 12 dB, because under the standard 20 dB gate the simulation always leaves the decay enough range).
- `SeatComparisonTests`: the mockup's move (−11 → −4 dB, +9 → +5 dB) gives the mockup's verdict, rows and note; both sides of the repeatability; the spread widening it; worse; an untargeted region and a new bass note that got worse; an incomplete second measurement. Hand-built spots (`handSpots`) need no recording.

The suite takes about 20 s on the Mac (the seat tests add about 7 s, run in parallel), most of it the deconvolution of 3 s sweeps in a debug build.

## Limits

- A finding rests on one microphone position: a dip or a buzz may be the room, or something near the speaker. Confidence is never high.
- THD is read from 80 Hz to about 9.3 kHz only (the second harmonic's trusted band); a buzz outside that range is never seen, and one that starts under 80 Hz is reported from 80 Hz (the simulated 72–110 Hz buzz reads "80–110 Hz", where the mockup says 70–110 Hz).
- Rattles and rub that are not harmonics are not measured from a sweep.
- In a noisy room the even statement covers less, and a buzz near the threshold becomes "too noisy to tell". At the 20 dB gate a healthy speaker's distortion is ruled out only up to about 1.3 kHz.
- A run that does not hold the whole sweep is discarded, not analysed over what it holds.
- Seat: a deep, narrow dip reads shallower than it is (the mockup room's 61 Hz dip by 1.5 dB): the 0.5 s window resolves about 2 Hz and power smoothing fills a notch.
- Seat: levels are relative to the seat's own middle; a real room's natural treble tilt may leave the even band above a few kHz, and real left and right speakers in different places may differ by more than 3 dB somewhere above 200 Hz. Both are untested on real rooms.
- Seat: the cause is inferred, never measured; with a hint, extremes are matched to axial modes only (no tangential or oblique modes, no boundary dips).
- Band signal-to-noise restates the frame length `NoiseFloor` uses for its bands, because that helper is internal to the DSP.

## Known differences from the design files

- The buzz finding hedges in its headline and sentence ("Possible buzz at 80–110 Hz", "A possible buzz around 100 Hz."), where the Diagnose mockups write "Buzz at 70–110 Hz" and "A buzz around 90 Hz.": the rule "never state a suspected defect as confirmed" wins. The range starts at 80 Hz, where THD is trusted.
- The even statement's detail names its response stretch and, with the woofer in it, says distortion was not checked below 80 Hz ("It stays within 3 dB from 50 Hz to 14 kHz. Distortion stayed under 10 % from 80 Hz to 9.2 kHz. I couldn't check for distortion below 80 Hz."), instead of the mockup's "No distortion or rattle found."
- New states with no mockup: "I could barely hear the woofer" (deviation), "Couldn't check the woofer" (inconclusive), the verdict "The tweeter and mid sound healthy; I couldn't check the woofer.", and "The room was too loud against the speaker for me to judge it." (not conclusive). For the seat: "I couldn't check the bass over the room's noise", "From your seat, what I could hear sounds even. The room was too noisy to check the bass.", "The room was too loud against the speakers for me to judge your seat."

## Open questions

- The 10 % THD threshold at 80–110 Hz may be normal for a small woofer played loud (the review's concern): it stays a first guess until real small speakers are measured at the app's level.
- Whether a woofer's fundamental response varying from run to run in 40–80 Hz could flag instability where THD is not read; for now distortion there is only said to be unchecked.

- Every first guess above, on real speakers in real rooms: the 10 % buzz threshold, 6 dB deviations, the 5-octave trend, 10 dB band signal-to-noise.
- Whether a healthy woofer at a loud level reads above 10 % in the deep bass, which would need a level-dependent threshold.
- Whether "too noisy to tell" should be shown at all when the verdict is healthy, or folded into the even statement's range.
- A steady-tone check (`ToneDistortion`) for the residue, run only where the sweep found something, would make "rattle" measurable.
- Seat, in real rooms: how far the spots really disagree at a mode over 60 cm (the 3 dB disagreement rule), the 1.5 dB repeatability, the 1/24-octave mode match against a RoomPlan scan, and whether 1/12-octave bass smoothing is too ragged on a real phone recording.
- Only on a real iPhone: the microphone's own roll-off under 100 Hz and its distortion at loud levels (both read as the speaker's), how far off axis the phone's top end falls (the 14 kHz rule), how much a real room's reverberation in the noise-floor stretch pushes distortion towards "not measurable", and how a real recording's signal-to-noise per band compares with the simulation's white noise.
