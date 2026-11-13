---
type: "module"
spec_module: "B"
phase: 6
status: "active"
tags:
  - "module"
---
# ResoniqDiagnostics

Turns a speaker test's recordings into findings. One run's recording becomes its numbers (`RunAnalyzer`); a test's runs become a `SpeakerReport` (`SpeakerDiagnosis`): a verdict sentence, findings that each carry an evidence tag and the runs they rest on, and the portrait's shape. Every word the screens show about a diagnosis is made here (`DiagnosisText`); a view composes nothing. Recordings at the listening seat become a `SeatReport` (`SpotAnalyzer`, `SeatDiagnosis`), and two seat reports a `ComparisonReport` (`SeatComparison`). Pure code on top of [ResoniqDSP](ResoniqDSP.md), runs on the Mac. Plan: [phase-2-diagnose.md](../plans/phase-2-diagnose.md). The model-based helpers (naming interference with SoundAnalysis, features and slots for a Core ML defect classifier and an anomaly model) are in `Models/`; plan: [phase-6-ai-finish.md](../plans/phase-6-ai-finish.md).

Paths below are relative to `ResoniqKit/Sources/ResoniqDiagnostics/`.

## Conventions

- **One grid.** Every curve (response, THD, the portrait) is on `ResponseGrid`: 241 log-spaced points from 20 Hz to 20 kHz, about 24 an octave (`Vocabulary.swift:102`).
- **Levels are relative.** A response is dB re the sweep, uncalibrated; it is read against its own trend or level-matched against another run. `RunMeasurement.referenceLevel` is the median from 300 Hz to 3 kHz (`ResponseComparison.defaultMatchBand`). No level is a sound pressure.
- **What the DSP measured, and nothing else.** A run is analysed only when `RecordingQuality.assess` says `.valid` and the recording holds the whole sweep (`ImpulseResponse.capturesWholeSweep`). Inside a run:
  - the response is read only inside `responseBand`, the impulse response's `trustedBand` within the grid; outside it the curve holds the edge value and nothing is raised from it;
  - THD is read only inside `HarmonicDistortion.trustedBand(order: 2, sweep:)` (80 Hz to about 9.3 kHz for `LogSweep.measurement`), and each point is a `DistortionReading`: `measured` where `SweepDistortion.isMeasurable(at:)` holds on the smoothed THD, otherwise `belowNoise` with the bound the floor gives (the floor raised by `SweepDistortion.measurableMarginDecibels`), or `notRead`.
- **Rules of evidence** (`SpeakerDiagnosis.swift:24–38`): a deviation in every valid run is `inferred`, "3 of 3 runs", medium confidence; in fewer but at least two, `inferred` with low confidence; in one, dropped. A dip above 14 kHz is `inconclusive`. A buzz is claimed only on `measured` THD; THD above the threshold but `belowNoise` is `inconclusive` (`distortionUnclear`), never a buzz. The even statement is `measured`; a driver is in it only when its response stays within `EvenBand.decibels` (±3 dB, the one definition the seat uses too) of its trend over its judged range (woofer 50–300 Hz, mid 300 Hz–3 kHz, tweeter 3–14 kHz, cut short where a top-end dip begins) and no deviation or inconclusive finding overlaps it; a natural bass roll-off is normal: when the response, from 50 Hz up, starts more than 3 dB under its trend and rises steadily (never falling by more than `rollOffToleranceDecibels` from one point to the next) back within 3 dB by `rollOffUpperFrequency` (100 Hz, the same frequency the quiet-band rule reads the woofer's level from), that point is the knee (`SpeakerDiagnosis.rollOffKnee`), the woofer is judged from it up, and the even statement says it plainly after its first sentence ("It stays within 3 dB from 70 Hz to 14 kHz. Bass rolls off below 70 Hz.", `measured`, not a deviation, no finding of its own because `Finding.Kind` has no informational kind the app does not already switch on). A dip that comes back lower down, or bass still falling above 100 Hz, is not a roll-off; above 100 Hz the bass is judged as it is (the hedge below, or "I could barely hear the woofer" at 15 dB down), never both. Between 3 and 6 dB above the knee, or where at least two runs measured distortion over 10 % that was too narrow to be a buzz, a driver is left out, neither even nor suspect, but never silently: the statement adds why ("The woofer isn't in this: around 130–210 Hz it's up to 4 dB off the notes around it. I couldn't check it for distortion below 80 Hz." or "The woofer isn't in this: its distortion reached 11 % around 130 Hz, short of what I'd call a buzz.", each sentence only when it holds), and the verdict does not call that driver healthy ("The tweeter and mid sound healthy; the woofer isn't clearly even, but I found no fault in it."; with every driver left out, "I found no fault, but the tweeter, mid and woofer aren't clearly even."). Its words name the response stretch, the stretch where every run ruled a buzz out, and, when the woofer is in it, that distortion was not checked below 80 Hz. A driver whose level is 15 dB or more under the loudest other is "barely heard" (`quietBand`, `measured`, cause left open); one too close to the room's noise is `notAssessed` (`inconclusive`), and the verdict calls healthy only the drivers checked; with nothing assessed the report is not conclusive. An invalid run is reported and nothing is drawn from it; under two valid runs nothing is concluded. No score, and words hedge ("may be buzzing", "Possible buzz").
- **Rattle: inferred from the session, never measured.** The DSP measures the non-harmonic residue only on a steady tone (`ToneDistortionResult.nonHarmonicResidue`); a sweep's deconvolution has no such figure. What a run carries instead is the session's observation that sound tied to the sweep came back where the run paused (`SweepTiedSound`, `RunAnalysis.swift:174`; the app maps `RunRecording.sweepTiedSound` onto it and passes it to `RunAnalyzer`). At the same place (overlapping within `samePlaceOctaves`) in at least `minimumAgreeingRuns` valid runs it is a `rattle` finding: `inferred`, basis "2 of 3 runs", low confidence unless in every run of three, its confidence statement naming the room or something near the speaker vibrating, no numbers; in one run it is dropped; an invalid run's observation does not count. Over a measured buzz it is not a second finding: the buzz carries it (`Finding.sweepTied`) and its detail adds "I also heard sound tied to the test tone there in 2 of 3 runs." Either way the drivers it overlaps leave the even statement, which never mentions rattle (the observation's absence proves nothing).
- **Portrait outside the measured band.** The axis is 20 Hz to 20 kHz; outside the stretch every run measured, the portrait holds the width at the edge (`PortraitProfile.swift:13`, `SpeakerDiagnosis.consensusResponse` at `SpeakerDiagnosis.swift:205`). With `LogSweep.measurement` the trusted band covers the whole grid, so nothing is held.

## Public interface

### Runs

| Symbol | Where | Holds |
|---|---|---|
| `RecordingCheck` | `RunAnalysis.swift:6` | A run's check in storable form: `valid`, `clipped`, `tooQuiet`, `tooNoisy`, `silent`, `corrupt(nonFiniteSampleCount:)` (:18), `incomplete(capturedBand:)` (:27); `init(_ verdict:)` (:34), `isValid` (:45), `problem` (:48) |
| `RecordingCheck.Problem` | `RunAnalysis.swift:30` | `clipped`, `tooQuiet`, `tooNoisy`, `silent`, `corrupt`, `incomplete` |
| `DistortionReading` | `RunAnalysis.swift:62` | `notRead`, `measured(percent:)`, `belowNoise(readPercent:upperBoundPercent:)` |
| `RunMeasurement` | `RunAnalysis.swift:76` | `response`, `referenceLevel`, `responseBand`, `thdDecibels` (gross), `thdMeasurable`, `thdNoiseFloorDecibels`, `delay`, `bandCentres`, `bandSignalToNoise`; `init` (:108), `normalizedResponse` (:135), `isResponseMeasured(atIndex:)` (:138), `thdPercent(atIndex:)` (:143), `distortion(atIndex:)` (:148), `signalToNoise(at:)` (:159). The three newer fields are optional so reports stored before them still decode; nil counts as measured nowhere |
| `RunRecord` | `RunAnalysis.swift:190` | `check` and, for a valid run only, `measurement`; `interference` (optional, phase 6: what a sound classifier heard during a noisy run); `init(check:measurement:interference:)` |
| `RunAnalysis` | `RunAnalysis.swift:224` | `verdict` (the DSP's, with full numbers) and `record`; `init(verdict:measurement:)` (:191), `init(verdict:check:measurement:)` (:196), `isValid`, `measurement` |
| `RunAnalyzer.analyze(recording:sweep:noiseFloor:thresholds:quality:sweepTiedSound:)` | `RunAnalysis.swift` | One run's numbers; an invalid or incomplete recording is not analysed; the session's observation is kept on the record either way |
| `SweepTiedSound`, `RunRecord.sweepTiedSound` | `RunAnalysis.swift:174`, `:198` | Where in the sweep sound tied to it was heard (`range`); `init?(lower:upper:)` from the session's hertz; optional on the record, encoded only when set; `RunRecord`/`RunAnalysis.adding(sweepTiedSound:)` |
| `InputLevel` | `Readings.swift:10` | The level reading: `good`, `tooQuiet` (only above the woofer, under the check's minimum peak), `tooLoud` (clipping); `label` "Good, no clipping", `shortLabel` "Good" |

### Reports and findings

| Symbol | Where | Holds |
|---|---|---|
| `SpeakerReport` | `SpeakerDiagnosis.swift:5` | `verdict`, `findings` (invalid runs first, then top of the portrait down), `profile`, `runs`, `consensusResponse`, `isConclusive`, `modelFindings` (optional, phase 6), `phoneMovedRuns` (optional: the 1-based runs the phone moved in, rising) and `phoneMovedNote` (its sentence, from `DiagnosisText.phoneMovedNote(runs:)`, the same words as `ReadingText.phoneMovedNote`), `suspectedDefects` |
| `SpeakerDiagnosis.diagnose(runs:counterpart:phoneMovedRuns:source:thresholds:)` | `SpeakerDiagnosis.swift:69` | The report from a speaker's runs, and the other speaker's for a left/right comparison; `phoneMovedRuns` (default none, from the session's `RunRecording.phoneMoved`) and `source` (default nil: the phone played it) are kept on the report and change nothing else |
| `SoundSource`; `SpeakerReport.source`, `sourceNote`; `SeatReport.source`, `sourceNote` | `SoundSource.swift:10`; `SpeakerDiagnosis.swift:29`, `:32`; `Seat/SeatReport.swift:213`, `:216` | How the sound was played (phase 7): `anotherDevice`, or nil for the phone. Optional, so every stored report decodes and the golden files are unchanged (nil is not written). `sourceNote` is "Measured from a test sound played on another device." |
| `DiagnosisText.sourceNote(_:)`, `measuredFromAnotherDevice`, `holdToHearUnavailable(frequency:)`; `SeatText.sourceNote(_:)` | `SoundSource.swift:17`, `:25`, `:33`, `:42` | The source line for the result screens, and what the Finding screen says instead of hold-to-hear when another device played the sound |
| `Finding` | `Finding.swift:7` | `id`, `kind`, `frequencyRange`, `bands`, `tag`, `basis`, `confidence`, `headline`, `detail`, `sentence`, `tagLine`, `confidenceStatement`, `repeatability`, `listenFrequency`, `context`, `numbers`, `recordingProblem`, `interference` and `modelSupport` (both optional, phase 6); `band` |
| `Finding.Kind` | `Finding.swift:8` | `responseDip`, `responsePeak`, `distortion`, `topEndDip`, `even`, `invalidRecording`, `leftRightDifference`, `distortionUnclear`, `quietBand` (:29, a deviation), `notAssessed` (:32), `rattle` (:36, a deviation, `inferred`); `isDeviation` |
| `Finding.SweepTiedEvidence`, `Finding.sweepTied` | `Finding.swift:49`, `:141` | On a buzz, the sound tied to the sweep heard at the same place: `range`, `runsHeard`, `runsCompared`, `statement` |
| `SpeakerReport.drawableResponse` | `Readings.swift:51` | `consensusResponse` with nil where not every valid run measured |
| `EvenBand.decibels` | `Vocabulary.swift:21` | ±3 dB, the one definition of "even" for speakers and seats |
| `Finding.Confidence`, `Finding.Basis`, `Finding.Numbers` | `Finding.swift:60`, `:65`, `:79` | Low/medium/high (never high from one position); "3 of 3 runs"; the numbers behind a finding, per run |
| `EvidenceTag` | `Vocabulary.swift:4` | `measured`, `inferred`, `inconclusive`, `estimate`; `displayName` (:15) |
| `FrequencyRange` | `Vocabulary.swift:25` | `init(lower:upper:)` (:23), `centre`, `octaves`, `contains`, `overlaps(_:toleranceOctaves:)` (:44), `widened(octaves:)` (:50) |
| `DriverBand` | `Vocabulary.swift:65` | `woofer`, `middle`, `tweeter`; `wooferUpperFrequency` 300 Hz (:71), `tweeterLowerFrequency` 3 kHz (:73), `init(frequency:)` (:75), `range` (:86), `displayName` (:95) |
| `ResponseGrid` | `Vocabulary.swift:102` | `lowerFrequency`, `upperFrequency`, `count`, `frequencies` (:108), `pointsPerOctave` (:113), `nearestIndex(to:)` (:116) |
| `DiagnosisText` | `DiagnosisText.swift:8` | Every user-facing string; public: `rounded(_:)` (:50), `frequency(_:)` (:56), `range(_:)` (:62) |
| `DiagnosisThresholds` | `DiagnosisThresholds.swift:8` | Every number that turns measurements into findings, 17 fields (:14–90), `init` (:105), `standard` (:148) |

### Portrait

| Symbol | Where | Holds |
|---|---|---|
| `PortraitProfile` | `PortraitProfile.swift:18` | `referenceWidth` 0.8 (:20), `dynamicRange` 30 dB (:22), `frequencies`, `widths`, `deviations`, `heardUpTo` (:25–33), `init(response:deviations:)` (:37), `notHeard` (:58), `live(envelope:sweep:delay:)` (:74) |
| `LevelEnvelope` | `PortraitProfile.swift:100` | The recording's level in 5 ms blocks for the live portrait; `blockDuration` (:102), `init(sampleRate:)` (:110), `init(samples:sampleRate:)` (:115), `append` (:127), `level(from:to:)` (:141) |

### Seat (phase 3) and before-and-after (phase 5)

In `Seat/`. Plans: [phase-3-measure.md](../plans/phase-3-measure.md), [phase-5-ar.md](../plans/phase-5-ar.md).

| Symbol | Where | Holds |
|---|---|---|
| `SpotAnalyzer.analyze(left:right:sweep:noiseFloor:movementDetected:thresholds:quality:) -> SpotAnalysis` | `Seat/SpotAnalysis.swift:100` | One spot: each recording checked like a run, deconvolved, read with `ImpulseResponse.roomPostWindow`, smoothed into a room curve; THD at 1 kHz where measurable; `Decay.bass` (given the sweep). `movementDetected` (default true) is the session's `SeatSpotRecording.movementDetected` |
| `SpotAnalyzer.roomCurve(_:thresholds:)` | `Seat/SpotAnalysis.swift:166` | The one definition of a seat curve's smoothing: 1/12 octave under 200 Hz, 1/3 above, blended over an octave |
| `SpotAnalysis` | `Seat/SpotAnalysis.swift:63` | `left`, `right` (nil for one speaker), `moveNotDetected` (optional: true when the phone was not seen to move to this spot), `isValid` (every recording it needs), `problems` |
| `SpotRecording`, `SpotMeasurement` | `Seat/SpotAnalysis.swift:49`, `:5` | A recording's `check` and, when valid, its `response` (dB re sweep, on `ResponseGrid`), `responseBand`, band signal-to-noise, `distortionPercent`, `bassDecay`; public inits for fixtures |
| `SeatDiagnosis.diagnose(spots:room:source:thresholds:) -> SeatReport` | `Seat/SeatDiagnosis.swift:62` | `source` kept on the report, nothing else changed. | The seat's result; rules of evidence in the doc comment (`:33–50`) |
| `RoomHint` | `Seat/SeatReport.swift:5` | Width, length, height in metres, each optional; axial modes c/2L·n computed here (c = 343 m/s, `SeatDiagnosis.swift:53`), no dependency on `ResoniqRoom` |
| `SeatReport` | `Seat/SeatReport.swift:165` | `schemaVersion` (`currentSchemaVersion` 1), `verdict`, `isConclusive`, `validSpotCount`, `requiredSpotCount`, `spots` (`SpotCheck`), `curve`, `leftCurve`, `rightCurve`, `spotCurves`, `spread`, `assessed`, `evenBandDecibels`, `extremes`, `leftRightDifference`, `findings`, `numbers`, `distortionPercent`, `bassDecay`, `restsOnOnePosition` (optional: true when the result may rest on one position); `displayedFindings` (first three, :252), `placementTargets` (bass extremes, :259), `progress` ("1 of 3 in"), `footnote`, `level(at:)` |
| `SeatReport.drawableRange`, `drawable(_:)`, `drawableCurve`, `drawableLeftCurve`, `drawableRightCurve`, `drawableSpotCurves`, `heldAtEdges(_:)` | `Seat/SeatReport.swift:273`, `:299` | What a curve may be drawn over: from the first to the last assessed point inside the judged band (30 Hz–10 kHz); nil outside it. `heldAtEdges` fills the gaps with the nearest drawn value for a component that draws every grid point. Stored JSON unchanged |
| `SeatReport.location(of:)`, `MeasuredPlace` | `Seat/SeatReport.swift:264`, `:54` | A measured problem's place is the seat (`.seat`), not an extent; `placementTargets` says so |
| `SeatDiagnosis.building(spots:thresholds:) -> SeatBuilding` | `Seat/SeatBuilding.swift:24` | The running average from the spots analysed so far: `spotCurves` and `average` (drawable, as the report of those spots holds them), `progress` "1 of 3 in", `validSpotCount`, `requiredSpotCount` |
| `SeatExtreme` | `Seat/SeatReport.swift:18` | `kind` (`peak`, `dip`), `frequency` (interpolated), `deviation` (signed dB re middle), `range`, `spread`; `label` "41 Hz +9 dB", `frequencyLabel`, `valueLabel` "+9.2 dB". Maps onto `AcousticProblem(frequency:deviation:kind:)` in the app |
| `SeatFinding` | `Seat/SeatReport.swift:68` | `kind` (`bass`, `rest`, `leftRight`, `roomCause`, `invalidSpot`, `singlePosition`), `tag`, `basis` (`SeatBasis`: `roomSize`, `spotToSpot`), `isDeviation`, `headline`, `tagLine`, `detail`, `strength` |
| `SeatNumberRow` | `Seat/SeatReport.swift:113` | `kind`, `label`, `value`, `word`, `tag`: "41 Hz · +9.2 dB · peak · Measured", "< 80 Hz · ≈ 0.6 s · decay · Estimate" |
| `SeatDecay`, `SpotCheck` | `Seat/SeatReport.swift:134`, `:149` | Bass band and RT60; a spot's two recording checks |
| `SeatThresholds` | `Seat/SeatThresholds.swift:8` | 26 fields, `standard` (:197) |
| `SeatDiagnosis.modeCoincidenceShare(_:thresholds:)` | `Seat/SeatDiagnosis.swift` | Internal: the share of 30–200 Hz within `roomModeOctaves` of an axial mode, the chance a bass feature matches a mode by coincidence |
| `SeatComparison.compare(before:after:targeting:thresholds:) -> ComparisonReport` | `Seat/SeatComparison.swift:98` | Verdict, rows, note, outcome; rules in the doc comment |
| `SeatComparison.repeatability(at:before:after:thresholds:)` | `Seat/SeatComparison.swift:194` | The one definition of the least change that counts |
| `ComparisonReport` | `Seat/SeatComparison.swift:52` | `schemaVersion` (1), `verdict`, `rows`, `note`, `outcome` (`ComparisonOutcome`: `improved`, `unchanged`, `worse`, `mixed`), `nextTarget`, `isConclusive`, `tag` (`measured`) |
| `ComparisonRow` | `Seat/SeatComparison.swift:21` | `label`, `before`, `after`, `status`, `change` (`ComparisonChange`), `beforeDecibels`, `afterDecibels`, `frequency`, `tag` |
| `SeatText` | `Seat/SeatText.swift:6` | Every seat and comparison string; public: `frequency(_:)` (whole hertz under 1 kHz), `signedDecibels(_:)`, `signedDecibelsTenths(_:)` (U+2212 minus), `progress(valid:required:)`, `buildingLabel(captured:drawn:of:)` (:74), the analysing lines, `displayResolutionDecibels` (:40); the strings of the screen shown while the spots are put together: `analysingHeadline`, `analysingBody`, `analysingKicker`, `analysingWaiting` |

How the seat result is made:

- **Curves.** The seat curve is the power average (`ResponseAverage.power`) of every valid recording (three spots × left and right), 0 dB at its middle: the median from 200 Hz to 4 kHz over assessed points. Left, right and spot curves are on the same reference, so a balance error shows. The spread is `ResponseAverage.spread` of the spot curves.
- **Assessed.** A grid point counts only inside every recording's measured band, with at least 10 dB in its octave band over the room's noise.
- **Extremes.** Where the seat curve leaves ±3 dB between 30 Hz and 10 kHz, at least 1/24 octave wide; a dip that runs into 30 Hz is roll-off and dropped. The frequency and size are the vertex of a parabola through the three grid points around the summit.
- **Findings**, deviations strongest first, then statements, then the cause: bass (`measured`, "One bass note booms, one nearly vanishes"; "nearly vanishes" from 8 dB); voices and treble even or uneven (`measured`), merged with "left matches right" and its figure when both hold; left and right differing by more than 3 dB is its own `measured` deviation and nothing says they match; the cause (`inferred`, "It's probably the room, not the speakers") only with a basis: every bass extreme within 1/48 octave of an axial mode of the hinted room *and* shaped like a mode, no wider than half an octave or the spots at least 3 dB apart there ("Inferred from room size."), otherwise every bass extreme no wider than half an octave and the spots at least 3 dB apart there ("Inferred from how it changes between spots."). A hint whose modes miss is no basis; the spots are then asked. A mode match alone is not enough: 17 % of 30–200 Hz lies on an axial mode of a 4.2 × 5.6 × 2.5 m room at 1/48 octave (21 % for 5 × 7 × 2.7 m; a third and more at the earlier 1/24 octave), so a broad bump the same at every spot would be blamed on the room by chance.
- **One position.** When the phone was not seen to move to a spot (`SpotAnalysis.moveNotDetected`) and the spots' largest spread from 30 Hz to 10 kHz is under 1 dB, the spots may all be one position: the verdict ends "The phone may not have moved between spots, so this rests on one position.", an `inconclusive` finding "The phone may not have moved between spots" comes after the deviations, `restsOnOnePosition` is true, and nothing is inferred from the spots (no spot-to-spot cause; a room-size cause needs a narrow extreme). When the spots differ, the missing detection is ignored.
- **Below the display's resolution.** A left/right difference (or any "within" or "±" figure) that would round under 0.1 dB is written "0.1 dB", never "0.0 dB": two measured curves are only known to be closer than the figure shows ("Measured · within 0.1 dB").
- **Drawing.** Outside `drawableRange` the curves hold values nothing was judged on; extremes and findings already ignore that region (a healthy simulated room has none at the band edges, and its held curve stays inside ±3 dB).
- **Figures.** Distortion at 1 kHz and the bass decay are the median of the recordings that have one, given only when at least half of them do. Decay is an `estimate`, written "≈ 0.6 s".
- **Spots.** Three valid spots are needed. With fewer the report is inconclusive, says which spot needs measuring again and why, and still carries the running average and the spots measured so far. Failed spots are not reported once the result is conclusive.
- **Comparison.** A targeted extreme, and each untargeted bass extreme of the first measurement, is read in the second as the larger excursion of either sign within 1/6 octave; it improved or got worse when its magnitude moved by more than the repeatability (1.5 dB, or a quarter of the two measurements' mean spread there). One that changed sign and now lies outside the even band (a dip turned into a peak) is `worse`, a new problem, never a fix. New bass extremes in the second away from every followed one, and voices and treble, each get a row. Voices and treble compare the largest excursion of each curve above 200 Hz at points both assessed, so a move inside the repeatability that crosses the ±3 dB line is unchanged ("About the same, just inside the even band" / "…just outside the even band"). The verdict comes from the row that decided the outcome (targets first, then other bass rows, then voices and treble), named for what it is: "The missing bass note is back." / "The booming bass note is calmer now." only when that row's value is now inside the even band, otherwise "It's a little better: the missing bass note is less quiet, now −7 dB." / "…the booming bass note is less strong, now +5 dB."; voices and treble alone: "Voices and treble are even now." / "It's a little better: voices and treble are more even."; "Nothing changed that I can measure."; "It sounds worse from your seat than before." (note: "Putting the speaker back where it was is the safe choice."), or, when a note changed sign, "The missing bass note now booms instead." / "The booming bass note is now missing instead." (the note names what is left, without "still"); "It's better in one place and worse in another."; an incomplete measurement compares nothing. With nothing targeted (a room-shape suggestion) the verdict is built the same way from what measurably changed.

### Models (phase 6)

In `Models/`. The rule is "DSP first, AI second": a model's output adds an `inferred` line or supports an `inferred` finding, never changes a measurement, and always states its basis. The new fields on stored types are optional and encoded only when set, so the pinned golden JSON is unchanged and old reports decode (`InterferenceInReportsTests`).

| Symbol | Where | Holds |
|---|---|---|
| `SoundClassifying` | `Models/SoundClassifying.swift:28` | `classify(_ samples: [Float], sampleRate: Double) async throws -> [SoundClassification]`, `Sendable`; empty for audio too short |
| `SoundClassification` | `Models/SoundClassifying.swift:4` | `identifier`, `confidence` (0…1), `start`, `duration`, `end` |
| `SystemSoundClassifier` | `Models/SystemSoundClassifier.swift:22` | Apple's built-in classifier (`.version1`, 303 labels) with `SNAudioStreamAnalyzer` on a background queue; `windowDuration` 1.5 s, `overlapFactor` 0.5, `labelsPerWindow` 10, `init(timeout:)` (`standardTimeout` 5 s), `isWorking()`, `isAvailable`, `knownLabels()`; resumes exactly once (complete, fail, time out, or cancel → `CancellationError`); under 1.5 s returns `[]`, and so does a sample rate that is not a positive whole number of hertz within `CMTimeScale` (it used to trap). `#if canImport(SoundAnalysis)`: macOS and iOS; throws `SoundClassifierError.unsupportedFormat(sampleRate)` for a rate it cannot take and `.timedOut` when the system classifier has not answered within `timeout` |
| `SystemSoundClassifier.isWorking() async -> Bool` | `Models/SystemSoundClassifier.swift` | **The availability rule**, decided once per process: a trial classification of 2 s of quiet noise with `probeTimeout` (15 s); false where the classifier cannot be created, fails or does not answer in time. `isAvailable` only tries to create the request, synchronously and unbounded, on the calling thread |
| `SoundAnalysisBackend` (internal) | `Models/SystemSoundClassifier.swift` | The analysis `classify` bounds: `analyze(_:sampleRate:) async throws`; must return promptly when its task is cancelled. `SystemSoundAnalysis` is the system one; tests inject one that never answers |
| `InterferenceKind` | `Models/InterferenceKind.swift:4` | `speech`, `music`, `televisionOrRadio` (no system label maps to it), `traffic`, `appliance`, `animal`, `doorOrFootsteps`, `windOrRain`, `babyOrChildren`, `phoneOrAlarm`, `unknown`; `isMimickedBySweep` (music, animal, phoneOrAlarm, unknown) |
| `InterferenceMapping` | `Models/InterferenceKind.swift:50` | `labels`: 190 of the 303 identifiers (184 to kinds, 6 `testSignal`: synthesizer, theremin, tuning_fork, beep, whistling, bell); `ignored` (silence); `label(for:)` |
| `InterferenceContext` | `Models/InterferenceAdvisor.swift:17` | `sweepSilent` (paused stretch, noise-floor listen), `sweepPlaying` (a recording judged too noisy) |
| `InterferenceReport` | `Models/InterferenceAdvisor.swift:28` | `kind`, `confidence` (mean over the stretches heard), `duration`, `fraction`, `sentence` ("It sounds like someone talking."), `basis` ("sound classifier, 82 %"), `tagLine`, `tag` (always `inferred`) |
| `InterferenceAdvisor.describe(classifications:context:thresholds:)` | `Models/InterferenceAdvisor.swift:82` | Pure: the kind heard longest at or above `minimumConfidence`, or nil; rules in the doc comment |
| `InterferenceAdvisor.note(heard:sampleRate:sweepPlaying:classifier:) -> InterferenceNote?` | `Models/InterferenceAdvisor.swift:153`, `:59` | The paused screen's line from audio the session kept (`pausedAudio()`, `noisyRecording`): `sentence` and `tagLine`, or nil |
| `InterferenceAdvisor.noiseNote(heard:sampleRate:context:classifier:)` | `Models/InterferenceAdvisor.swift` | **The app's call when a run pauses or fails for noise**: the report to show under "It got noisy, so I stopped." (`sentence`, `tagLine`), or nil (nothing clear, `unknown`, or the classifier failed or timed out; never throws, never waits longer than the classifier's `timeout`). `noiseSentence` gives the sentence alone |
| `RunRecord.adding(interference:)`, `RunAnalysis.adding(interference:)` | `Models/InterferenceAdvisor.swift:202`, `:209` | Attach a report to a noisy run; `SpeakerDiagnosis` copies it onto that run's `invalidRecording` finding (`Finding.interference`) |
| `LogMelSpectrogram` | `Models/LogMelSpectrogram.swift:16` | `compute(_:sampleRate:configuration:)`, `configuration`, `sampleRate`, `frameCount`, `bandCount`, `values` (frames × bands, dB), `bandCentres`, `level(frame:band:)`, `frame(_:)` |
| `LogMelSpectrogram.Configuration` | `Models/LogMelSpectrogram.swift:17` | `windowLength` 2048, `hopLength` 480 (10 ms at 48 kHz), `window` Hann, `bandCount` 64, 20 Hz–20 kHz, `referencePower` 1 (dBFS RMS), `floorDecibels` −120; `frameCount(sampleCount:)`: 0 under one window, else `1 + (n − 2048) / 480` |
| `DefectFeatures` | `Models/DefectFeatures.swift:11` | Per octave band (`bandCentres`, 31.6 Hz–15.8 kHz, 10): `thdPercent` (measured only), `responseDeviation` (from the run's own `Trend`), `signalToNoise`, `runToRunSpread` (standard deviation across runs); `broadbandSignalToNoise`, `validRunCount`, `runCount`; `init(runs:)`, `init(records:)`; `vector` (`vectorLength` 84: value and presence per figure) |
| `DefectClass`, `DefectPrediction` | `Models/DefectClassifying.swift:4`, `:26` | The spec's §3.4 classes: `normal`, `mechanicalRattling`, `voiceCoilRubbing`, `buzzing`, `crackling`, `potentialDriverMalfunction`, `environmentalInterference`, `unknownAnomaly`; a class and its confidence |
| `DefectClassifying` | `Models/DefectClassifying.swift:42` | `classify(features:spectrogram:) async throws -> [DefectPrediction]` |
| `AnomalyScoring`, `AnomalyScore` | `Models/DefectClassifying.swift:66`, `:48` | `score(_:reference:)`; `reconstructionError`, `typicalHealthyError`, `ratio`. No implementation ships |
| `DefectModelDescription` | `Models/CoreMLDefectClassifier.swift:15` | The model contract; `validate()` throws `DefectModelError`: input `features` `[84]` or `[1, 84]` required; optional `spectrogram` `[frames, 64]` or `[1, frames, 64]`; no other input; a classifier whose labels are all `DefectClass` raw values |
| `CoreMLDefectClassifier` | `Models/CoreMLDefectClassifier.swift:96` | Actor. `modelName` "ResoniqDefectClassifier"; `load(from: Bundle)` returns nil when there is no `ResoniqDefectClassifier.mlmodelc` (the shipped state) and throws for a model that breaks the contract; `load(compiledModelAt:)`; `contract`; `classify` pads or cuts the spectrogram to the model's frames |
| `ModelAdvice.join(_:to:thresholds:)` | `Models/ModelAdvice.swift:75` | Predictions into a report; rules in the doc comment and below |
| `ModelAdvice.join(anomaly:to:thresholds:)` | `Models/ModelAdvice.swift:114` | An anomaly result into a report |
| `ModelFinding`, `ModelEvidence` | `Models/ModelAdvice.swift:23`, `:4` | A model's line (`kind` defect or anomaly, `headline`, `detail`, `sentence`, `tagLine`, `tag` inferred, `confidence` low); its source, class, value, `basis`, `statement` |
| `ModelText` | `Models/ModelText.swift` | Every model string; public `percent(_:)` ("82 %", never 0 or 100) |

How model output joins a report (`ModelAdvice`):

- An inconclusive report gets nothing. The verdict, every finding's tag, basis, confidence and words, and `suspectedDefects` never change.
- Only the most confident class speaks, and only at or above `minimumDefectConfidence`; when it is `normal`, nothing at all.
- A `buzzing` prediction supports an existing `inferred` `distortion` finding (`Finding.modelSupport`: "A defect classifier also heard a buzz (74 %)."). Every other class, or a buzz with no inferred buzz finding, adds one `ModelFinding` ("Possible rattle", "I may have heard a rattle.", "Inferred · defect classifier, 81 %"); a second join replaces it.
- The anomaly check adds "Something sounded unusual" ("Inferred · anomaly check, 3.1 × usual") at or above `minimumAnomalyRatio`, beside a defect line, never as the verdict.
- Model lines live in `SpeakerReport.modelFindings`, not in `findings`, because the app switches exhaustively over `Finding.Kind` (`Resoniq/Features/Diagnose/FindingScreen.swift:382`, `:409` and `DiagnosticsDisplay.swift:70`); a new kind would need an app change. The app shows nothing from a model until a screen is built for it.

Naming interference: labels are grouped by window, and a kind's confidence in a window is its most confident label. Test-signal labels are never counted. With the sweep playing (`sweepPlaying`), music, animals, alarms and `unknown` are not named either: the app's measurement sweep reads as "music" up to 0.95, "theremin" 0.96, "tuning_fork" and "bell", and a plain sweep's top octaves as "bird_chirp_tweet" 0.52. Speech over the sweep is still named (0.67–0.99 per window).

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
| `rollOffUpperFrequency` | 100 Hz | `quietBandLowerFrequency`, not a second number: the highest knee taken as a natural bass roll-off, so the two rules meet there |
| `rollOffToleranceDecibels` | 0.5 dB | First guess; how far the response may rise going down inside a roll-off |

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
| `roomModeOctaves` | 1/48 | First guess; 17 % chance coincidence in a 4.2 × 5.6 m room (a third at 1/24) |
| `roomModeUpperFrequency` | 200 Hz | |
| `distortionFrequency` | 1 kHz | The mockup's row |
| `distortionSmoothingFraction` | 3 | |
| `minimumFigureShare` | 1/2 | |
| `requiredSpots` | 3 | From the plan |
| `minimumBandSignalToNoise` | 10 dB | First guess, as for speakers |
| `singlePositionSpreadDecibels` | 1 dB | First guess; with a move not detected, spots closer than this everywhere may be one position |
| `repeatabilityDecibels` | 1.5 dB | First guess |
| `repeatabilitySpreadShare` | 1/4 | First guess |
| `samePlaceOctaves` | 1/6 | |

Models (phase 6):

| Field | Value | Note |
|---|---|---|
| `InterferenceThresholds.standard.minimumConfidence` | 0.5 | First guess; on the Mac a synthetic voice read "speech" 0.99, white noise nothing above 0.24 |
| `ModelAdviceThresholds.standard.minimumDefectConfidence` | 0.7 | First guess; above 0.5, so only one class of a softmax can speak |
| `ModelAdviceThresholds.standard.minimumAnomalyRatio` | 3 | First guess; three times a healthy recording's typical error |
| `SystemSoundClassifier.windowDuration` / `overlapFactor` | 1.5 s / 0.5 | First guess. A bark or a door is shorter than the classifier's 3 s default; under 1 s it has too little to go on |
| `SystemSoundClassifier.labelsPerWindow` | 10 | |
| `SystemSoundClassifier.standardTimeout` | 5 s | First guess. A few seconds of audio took 0.07–0.15 s on a Mac (debug), about 0.8 s on first use; past this the paused screen's line comes too late to help. A timeout is "nothing heard" |
| `SystemSoundClassifier.probeTimeout` | 15 s | First guess, for a slow first model load on a busy or virtual machine |
| `LogMelSpectrogram.Configuration.standard` | 2048 / 480 / Hann / 64 bands / 20 Hz–20 kHz / −120 dB | For 48 kHz recordings: 23.4 Hz bins put three or more in the lowest band; 10 ms hop |

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
- `SeatCauseTests`: a 90 Hz peak the same at every spot is not blamed on the room, with no hint or a mismatched one; a broad +6 dB peak with no spread slid across 35–150 Hz in a 4.2 × 5.6 m room is never blamed on it (before the fix: at 14 of 47 positions); a narrow peak on a mode is, hedged; the chance coincidence is under 20 % (16.7 %; 21.3 % for 5 × 7 m); left and right 5 dB apart in the treble; one speaker.
- `SeatSinglePositionTests`: no move seen and identical spots gives the caveat, the inconclusive finding and no spot-to-spot cause; spots that differ ignore the missing detection; moves seen say nothing; the analyzer carries the flag and JSON writes nothing when the move was seen.
- `SeatInvalidTests`, `SeatDecayTests`: two valid spots are inconclusive; a clipped recording invalidates its spot with the reason; no decay in a 40 Hz rumble 14 dB under the recording (the gate relaxed to 12 dB, because under the standard 20 dB gate the simulation always leaves the decay enough range).
- `SeatComparisonTests`: the mockup's move (−11 → −4 dB, +9 → +5 dB) gives the mockup's rows and note and "…less quiet, now −4 dB."; both sides of the repeatability; the spread widening it; worse; an untargeted region and a new bass note that got worse; an incomplete second measurement. The review's cases: a 2 kHz bump of 3.4 → 3.0 dB (3.38 dB read) with the target unchanged is unchanged both ways (it was "It's a little better…" one way and "It sounds worse…" plus "Putting the speaker back…" the other); an untargeted +9 → +5 dB peak names the booming note; −11 → −7.3 dB is "less quiet, now −7 dB", −11 → −2 dB "back"; a dip turned into a +9 dB peak is "now booms instead", one row, `worse`. A grid of 2 × 4 befores, 11 × 4 afters, with and without targets (704 comparisons) checks that verdict, rows and note never contradict. Hand-built spots (`handSpots`) need no recording.
- `PhoneMovedTests`: the runs and the sentence are kept and survive JSON; none moved writes nothing.

- `InterferenceMappingTests`: every mapped identifier is in the committed list of 303 (`SoundClassifierLabels.swift`, obtained from `knownClassifications` on macOS 27); the kinds that matter are mapped.
- `InterferenceAdvisorTests`, on hand-built labels: the kind heard longest, the threshold, ties, test-signal labels and the sweep context, `unknown`, the app's call with a stub and a failing classifier, every sentence's wording.
- `InterferenceInReportsTests`: a noisy run's report reaches its finding and changes nothing else; old JSON and the golden reports decode with no new field.
- `SoundClassifierInputTests` (always run): a sample rate the analyzer cannot use (44 100.5, 0, negative, infinite, NaN, 10¹²) gives no classification.
- `SoundClassifierTimeoutTests` (always run, no system classifier: an injected backend): one that never answers throws `timedOut` within its limit, was resumed once by the cancellation and had ended before `classify` returned; the advisor's `note` is nil within the limit; an answer after the limit is dropped; one within it is returned; cancelling the caller throws at once; the probe says no within its limit.
- `SoundClassifierTests` (each with a 2-minute `.timeLimit`; skipped, with the reason, where `isWorking()` says the system classifier does not answer; the voice tests also where `say` cannot make a voice within 20 s, the process then stopped; never a failure for either; the classifier runs with a 60 s timeout. `RESONIQ_TEST_SOUND_CLASSIFIER=unavailable` or `=silent` simulates a machine without it): the live label list equals the committed one; a `say` voice is speech (0.99 in every window; skipped if `say` fails); a synthesised tune is music (0.92–0.95) but not with the sweep playing; white noise names nothing (top "waterfall" 0.23); a clean measurement-sweep recording gives no report with `sweepPlaying` (and would be "music" without it); speech over the sweep is still speech; short audio gives nothing; window spacing; cancellation. Timing on an Apple-silicon Mac: 0.07–0.15 s per 4–5 s of audio in the debug test build after the first call (about 0.8 s with the model load), about 0.03 s in a release build.
- `LogMelSpectrogramTests`: the frame-count formula, silence is the floor, the filter bank's weights sum to 1 between the first and last centres (per bin and continuously), a sine at a band's centre reads `20·log10(A/√2)` within 0.3 dB with bands two away 30 dB down, white noise's bands sum to its level within 0.3 dB, JSON.
- `DefectFeaturesTests`, `DefectModelContractTests` (every refusal), `CoreMLDefectClassifierTests` (no model → nil), `StandInModelTests` (a logistic-regression stand-in trained in the test with Create ML on the 84-number vector: loads, classifies, probabilities add up to 1, found by name in a bundle; a wrong vector length, input name or class label is refused. Training runs on a thread of its own (`OffPool`), never the concurrency pool, with a 120 s limit: Create ML blocks its thread on a semaphore while it waits for work it queued on that pool, and on CI's three-core runner that starved the pool and hung the whole test process for 26 minutes (run 43504323796). Skipped with the reason where Create ML cannot train in time, or with `RESONIQ_TEST_CREATE_ML=unavailable`; a 5-minute `.timeLimit`), `ModelAdviceTests` (every rule above, the wording, JSON).

- `RollOffTests`: a healthy speaker rolling off below 70 Hz (as the app's simulated bookshelf) is "Sounds healthy.", "Tweeter, mid and woofer are even", "It stays within 3 dB from 70 Hz to 14 kHz. Bass rolls off below 70 Hz."; the boundary with the quiet-band rule at 100 Hz: a 90 Hz roll-off is healthy with "Bass rolls off below 90 Hz.", a 120 Hz one is the hedge (no roll-off line, not barely heard), no output below 500 Hz is "I could barely hear the woofer" with no roll-off line; a 70 Hz dip over a 30 Hz roll-off is a dip, not a roll-off; the knee on hand-made curves (a notch merging into the fall, a fall ending at 160 Hz: none). `UnclearedDriverTests`: a 5 dB rise at 100–250 Hz over a 70 Hz roll-off is "The tweeter and mid sound healthy; the woofer isn't clearly even, but I found no fault in it.", its statement adding "The woofer isn't in this: around 130–210 Hz it's up to 4 dB off the notes around it."; a 12 % buzz too narrow to report (123–134 Hz) is "The woofer isn't in this: its distortion reached 12 % around 120 Hz, short of what I'd call a buzz.", no buzz finding; the verdict's wording. Found when the app's demo reported "Sounds healthy." with no word on the woofer. `MeasurementSweepBuzzTests`: a 20 % buzz at 100–160 Hz is "Possible buzz at 100–160 Hz", 3 of 3 runs, with the app's 4 s sweep as with the suite's 3 s one.
- `SweepTiedFindingTests`: sound tied to the sweep at 92–433 Hz in 2 of 3 runs is "Possible rattle at 90–430 Hz", "Something may be rattling around 200 Hz.", `inferred`, "2 of 3 runs", low confidence, the room named, the verdict "Sounds healthy, except something may be rattling around 200 Hz.", the woofer and mid out of the even statement; in 3 of 3 medium; in one run, at different places or in an invalid run, dropped; over a measured buzz one finding with both pieces of evidence; the analyzer keeps it; JSON.
- `SeatDrawingTests`: a healthy room has no extreme and nothing drawn outside 30 Hz–10 kHz, its held curve inside ±3 dB; unassessed points are not drawn; the running average grows spot by spot with "1 of 3 in" and ends as the report's curves; a failed spot adds nothing; identical left and right read "within 0.1 dB"; the problem's place is the seat.
- `ReadingTests`: the input level and its words, the paused screen's line, a speaker report's drawable response.

The suite takes about 18 s on a loaded Mac (it took 22–38 s), most of it the deconvolution of 3 s sweeps in a debug build. Fixtures are made once per key even when tests running side by side ask for the same one (`OnceCache`), and the simulated speaker's filter is a plain loop.

- `SoundSourceTests`: a speaker report keeps its source, says it, stores `"source":"anotherDevice"` and decodes it back; one without stores no `source` key; the golden reports decode with no source; the hold-to-hear sentence; a seat played elsewhere on a clock 300 ppm slow (cut and corrected as the listening session does it) gives the same verdict as the phone-played seat, a curve within 0.03 dB of it, and a bass decay.

**No caveat about the player's clock.** Corrected, a clock offset of up to ±500 ppm measures within 0.01 dB and 0.2 % of THD of none (`ClockOffsetAccuracyTests` in ResoniqDSP), as accurately as the normal path, so the reports say how the sound was played and do not lower confidence for the clock; a clock beyond 1000 ppm never reaches a report (the session fails it). What the reports cannot know: whether the sound passed through a lossy format, a sample-rate converter, AirPlay or a receiver's own processing on the way to the speakers, any of which bends the top of the range and the distortion figures. The files' instructions say to play the WAV itself.

## Limits

- A finding rests on one microphone position: a dip or a buzz may be the room, or something near the speaker. Confidence is never high.
- THD is read from 80 Hz to about 9.3 kHz only (the second harmonic's trusted band); a buzz outside that range is never seen, and one that starts under 80 Hz is reported from 80 Hz (the simulated 72–110 Hz buzz reads "80–110 Hz", where the mockup says 70–110 Hz).
- Rattles and rub that are not harmonics are not measured from a sweep; a rattle is inferred only where the session noticed sound tied to the sweep, which it does only where that sound paused a run (a quiet rattle never does), and strong reverberation reads the same.
- In a noisy room the even statement covers less, and a buzz near the threshold becomes "too noisy to tell". At the 20 dB gate a healthy speaker's distortion is ruled out only up to about 1.3 kHz.
- A run that does not hold the whole sweep is discarded, not analysed over what it holds.
- Seat: a deep, narrow dip reads shallower than it is (the mockup room's 61 Hz dip by 1.5 dB): the 0.5 s window resolves about 2 Hz and power smoothing fills a notch.
- Seat: levels are relative to the seat's own middle; a real room's natural treble tilt may leave the even band above a few kHz, and real left and right speakers in different places may differ by more than 3 dB somewhere above 200 Hz. Both are untested on real rooms.
- Seat: the cause is inferred, never measured; with a hint, extremes are matched to axial modes only (no tangential or oblique modes, no boundary dips).
- Models: the sound classifier's labels were checked only on synthetic audio on the Mac (a `say` voice, a synthesised tune, white noise, a simulated sweep), never on an iPhone recording of a real room. No label names a TV, radio or washing machine. Insects are left unmapped because a synthetic voice's sibilants read as "mosquito_buzz" up to 0.76. While the sweep plays, real music, a dog or an alarm cannot be named.
- Models: no defect or anomaly model exists. The features, the contract and the join rules are tested; whether the features help a model is not (see [the dataset plan](../research/2026-11-13-defect-dataset-plan.md)). The stand-in model takes only the feature vector; a model with a `spectrogram` input was validated by description, not run.
- Band signal-to-noise restates the frame length `NoiseFloor` uses for its bands, because that helper is internal to the DSP.

## Known differences from the design files

- The buzz finding hedges in its headline and sentence ("Possible buzz at 80–110 Hz", "A possible buzz around 100 Hz."), where the Diagnose mockups write "Buzz at 70–110 Hz" and "A buzz around 90 Hz.": the rule "never state a suspected defect as confirmed" wins. The range starts at 80 Hz, where THD is trusted.
- The even statement's detail names its response stretch and, with the woofer in it, says distortion was not checked below 80 Hz ("It stays within 3 dB from 50 Hz to 14 kHz. Distortion stayed under 10 % from 80 Hz to 9.2 kHz. I couldn't check for distortion below 80 Hz."), instead of the mockup's "No distortion or rattle found."
- The seat's cause headline is "It's probably the room, not the speakers" where the Measure mockup writes "It's the room, not the speakers": the cause is inferred, and an inferred cause is not stated as fact.
- The mockup's before-and-after verdict "The missing bass note is back." stands over a row that reads −11 → −4 dB, outside the even band; the Kit says "back" only for a value inside ±3 dB, so that move reads "It's a little better: the missing bass note is less quiet, now −4 dB."
- New states with no mockup: "The phone may not have moved between spots" (inconclusive) and the verdict's "The phone may not have moved between spots, so this rests on one position."; the comparison's "The missing bass note now booms instead.", "Voices and treble are even now.", "It's a little better: voices and treble are more even.", "About the same, just inside the even band", "About the same, just outside the even band". "Possible rattle at 90–430 Hz" / "Something may be rattling around 200 Hz." (deviation, `inferred`), "I could barely hear the woofer" (deviation), "Couldn't check the woofer" (inconclusive), the verdict "The tweeter and mid sound healthy; I couldn't check the woofer.", the verdict "The tweeter and mid sound healthy; the woofer isn't clearly even, but I found no fault in it." with the even statement's "The woofer isn't in this: …", the even statement's "Bass rolls off below 70 Hz.", and "The room was too loud against the speaker for me to judge it." (not conclusive). For the seat: "I couldn't check the bass over the room's noise", "From your seat, what I could hear sounds even. The room was too noisy to check the bass.", "The room was too loud against the speakers for me to judge your seat."

## Open questions

- The 10 % THD threshold at 80–110 Hz may be normal for a small woofer played loud (the review's concern): it stays a first guess until real small speakers are measured at the app's level.
- Whether a woofer's fundamental response varying from run to run in 40–80 Hz could flag instability where THD is not read; for now distortion there is only said to be unchecked.

- Every first guess above, on real speakers in real rooms: the 10 % buzz threshold, 6 dB deviations, the 5-octave trend, 10 dB band signal-to-noise.
- Whether a healthy woofer at a loud level reads above 10 % in the deep bass, which would need a level-dependent threshold.
- Whether "too noisy to tell" should be shown at all when the verdict is healthy, or folded into the even statement's range.
- A steady-tone check (`ToneDistortion`) for the residue, run only where the sweep found something, would make "rattle" measurable.
- Seat, in real rooms: how far the spots really disagree at a mode over 60 cm (the 3 dB disagreement rule), the 1.5 dB repeatability, the 1/48-octave mode match against a RoomPlan scan, the 1 dB "one position" spread, and whether 1/12-octave bass smoothing is too ragged on a real phone recording.
- Playing from another device: whether real players' lossy or resampled paths need a caveat on the top octave or the THD after all, which only a device with real players can show.
- Only on a real iPhone: the microphone's own roll-off under 100 Hz and its distortion at loud levels (both read as the speaker's), how far off axis the phone's top end falls (the 14 kHz rule), how much a real room's reverberation in the noise-floor stretch pushes distortion towards "not measurable", and how a real recording's signal-to-noise per band compares with the simulation's white noise.
