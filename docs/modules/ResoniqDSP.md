---
type: "module"
spec_module: "A"
phase: 3
status: "active"
tags:
  - "module"
---
# ResoniqDSP

Pure signal maths on `[Float]` buffers with Accelerate: test signals, FFT, frequency response, impulse response, THD, noise floor, clipping, smoothing. No audio hardware, no actors, runs on the Mac.

The module turns a recording of a played [`LogSweep`](#foundation) into an impulse response, a frequency response and harmonic distortion, and it decides whether a recording is fit to analyse. For a listening seat it also reads the room: the response with a long window, the decay time by band, and the power average and spread of several spots ([Room](#room)). It knows nothing about the microphone, the session or the screen: callers hand it samples and a sample rate. Plans: [phase-1-dsp.md](../plans/phase-1-dsp.md), [phase-3-measure.md](../plans/phase-3-measure.md).

Paths below are relative to `ResoniqKit/Sources/ResoniqDSP/`.

## Conventions

Each is stated once, here, with the symbol that defines it.

- **Buffers.** Audio is `[Float]` in the range −1…1 plus a separate `sampleRate` in hertz. Every function that needs the rate takes it, or reads it from `LogSweep` or `ImpulseResponse`.
- **Decibels and full scale.** A level is in decibels relative to full scale (1.0 is 0 dB), and the microphone is uncalibrated, so no level is a sound pressure. A frequency response is "dB re the sweep": 0 dB means the sweep came back unchanged. Only shapes and differences mean anything. [`Decibels`](#foundation) converts; `Decibels.floor` (−160) stands in for silence instead of minus infinity, and NaN stays NaN, so a corrupt input never reads as silence.
- **One level convention: dBFS RMS.** A full-scale sine reads −3.01 dB in `Level.rmsDecibels`, in a `SpectrumAnalyzer` bin and in an `OctaveBands` band. Band levels are the band's share of the mean square, so the bands of a signal add up to its broadband RMS. `Level.peakDecibels` is the only peak figure. Defined at `Spectrum/SpectrumAnalyzer.swift:5` and `Spectrum/OctaveBands.swift:42`.
- **One band table.** `OctaveBands` (exact base-ten centres, IEC 61260-1); `NoiseFloor` and `SignalToNoise` use it.
- **A curve is `MagnitudeResponse`.** Rising frequencies in hertz and a level in decibels at each: a spectrum, a frequency response, a distortion curve or a set of band levels. Result curves cover only the band where they are accurate; outside it there is no point, and `SweepDistortion.thdPercent(at:)` is NaN.
- **FFT normalisation.** `FFT.forward` is unnormalised and `FFT.inverse` divides by N, so `inverse(forward(x)) == x`. Sizes are powers of two. Bin `k` of an N-point transform is `k · sampleRate / N` Hz (`FFT.frequency(ofBin:size:sampleRate:)`). Functions that transform repeatedly set the transform up once (`FFT.Plan`, internal).
- **Spectrum level.** `SpectrumAnalyzer` divides out the window's coherent gain, so a sine of amplitude `A` on a bin reads `20·log10(A/√2)` whatever the window. Bins run from DC to Nyquist, `size / 2 + 1` of them. White noise reads `10·log10(2σ² · ENBW / N)` per bin (`Window.equivalentNoiseBandwidth`).
- **Impulse-response layout.** `ImpulseResponse.samples` is one period of a circular buffer. Index 0 is the instant the sweep's first sample was played, counted from the recording's first sample. Positive time runs up the first half, negative time wraps to the end, and the harmonics' responses land before the linear peak, possibly wrapped past index 0. Use `index(atTime:)` and `index(atOffset:)`, not hand-written modular arithmetic. Defined at `Response/ImpulseResponse.swift:6`.
- **Bands of a response.** `band` is what the sweep played, `capturedBand` what the recording holds of it (nil: nothing), `trustedBand` what is reported. Defined at `Response/ImpulseResponse.swift:51–64`.
- **Windows.** `frequencyResponse` reads the speaker with `ImpulseResponse.defaultPostWindow` (100 ms) and the seat with `ImpulseResponse.roomPostWindow` (500 ms), so the room's reflections and modes stay in; a window shorter than the first reflection gives a reflection-free reading. Defined at `Response/ImpulseResponse.swift:24–40`.
- **A decay is an estimate.** `Decay` returns nil rather than a figure the response cannot support, and every `DecayEstimate` carries what it rests on (evaluation range, dynamic range, fit). Pass the sweep, so the noise is read only where the recording holds data.
- **The safe level.** `LogSweep.maximumAmplitude` (0.25, −12 dBFS) is the one definition of the loudest a test signal may be. `LogSweep` and `TestSignal.sine` both clamp to it, turn a non-finite amplitude into silence, and fade over at least `LogSweep.minimumFadeDuration` with first and last samples exactly zero. The playback volume is the user's.
- **Hostile input.** No public analysis traps on a buffer a microphone can produce (empty, a few samples, shorter than the sweep, silent, or holding NaN or infinity). Each returns a neutral result that says so: `capturedBand` nil, `ToneDistortionResult.fundamentalFrequency` nil, NaN levels for non-finite input, `Decibels.floor` for silence, `RecordingVerdict.corrupt`. Preconditions remain only for choices made in code: a sample rate, a transform size, a frequency outside 0…Nyquist, harmonic orders below 2.
- **Gross and net THD.** `SweepDistortion.thd` is gross (it includes the noise its windows collect) and carries `noiseFloor` beside it; `ToneDistortionResult.thdPercent` is net (the noise share is subtracted). Both say whether they are a measurement with the same margin, `SweepDistortion.measurableMarginDecibels`.

## Public interface

### Foundation

| Symbol | Where | Holds |
|---|---|---|
| `Decibels` | `Foundation/Decibels.swift:7` | `floor` (:9), `fromAmplitude` (:11), `fromPower` (:17), `toAmplitude` (:23); NaN in, NaN out |
| `ComplexSpectrum` | `Foundation/FFT.swift:4` | Split complex spectrum (`real`, `imaginary`, `init` :8, `count` :14); `magnitudes` (:17) includes the mirrored upper half |
| `FFT` | `Foundation/FFT.swift:24` | `nextPowerOfTwo` (:25), `forward(_:size:)` of a real signal, zero-padded (:33), `forward(_:)` of a complex sequence (:38), `inverse` (:43), `frequency(ofBin:size:sampleRate:)` (:47), `bin(nearest:size:sampleRate:)` (:51) |
| `LogSweep` | `Foundation/LogSweep.swift:7` | The exponential sine sweep every measurement plays. `maximumAmplitude` (:10), `minimumFadeDuration` (:13), `defaultFadeDuration` (:16); fields `startFrequency`, `endFrequency`, `duration`, `sampleRate`, `amplitude`, `fadeDuration` (:18–29) and `init` (:31) |
| `LogSweep` members | `Foundation/LogSweep.swift:50` | `sampleCount` (:50), `logRatio` (:53), `frequency(at:)` (:56), `time(of:)` (:61), `harmonicAdvance(order:)` (:67), `samples()` (:71) |
| `LogSweep` bands and the measurement sweep | `Foundation/LogSweep+Measurement.swift:3` | `trustedStartRatio` (:6), `trustedEndMargin` (:9), `trustedBand` (:18), `reportedBand` (:26), `measurementStartFrequency`, `measurementEndFrequency`, `measurementDuration` (:33–35), `measurement(sampleRate:)` (:40), `minimumAccurateDuration` (:52) |
| `MagnitudeResponse` | `Foundation/MagnitudeResponse.swift:5` | `frequencies`, `decibels` (:6, :7), `init` (:9), `count` (:15), `decibels(at:)` (:18), interpolated linearly in log frequency and held flat outside the range |

### Signals

| Symbol | Where | Holds |
|---|---|---|
| `TestSignal` | `Signals/TestSignal.swift:4` | Steady test signals |
| `TestSignal.sine(frequency:duration:sampleRate:amplitude:fadeDuration:)` | `Signals/TestSignal.swift:12` | A faded sine, made safe as `LogSweep` is |
| `TestSignal.silence(duration:sampleRate:)` | `Signals/TestSignal.swift:31` | Zeros |
| `Window` | `Signals/Window.swift:8` | Cases `rectangular` (:10), `hann` (:12), `hamming` (:14), `blackmanHarris` (:16); all periodic cosine sums, the module's only windows |
| `Window` members | `Signals/Window.swift:30` | `samples(count:)` (:30), `coherentGain` (:45), `equivalentNoiseBandwidth` (:52), `apply(to:)` (:60) |

### Spectrum

| Symbol | Where | Holds |
|---|---|---|
| `SpectrumAnalyzer` | `Spectrum/SpectrumAnalyzer.swift:14` | Magnitude spectra in dBFS RMS, one normalisation for both; an empty buffer is silence |
| `SpectrumAnalyzer.spectrum(of:sampleRate:window:size:)` | `Spectrum/SpectrumAnalyzer.swift:18` | Spectrum of the whole signal, Hann by default |
| `SpectrumAnalyzer.averagedSpectrum(of:sampleRate:segmentSize:overlap:window:)` | `Spectrum/SpectrumAnalyzer.swift:37` | Welch's averaged spectrum; 4096-sample segments, 50 % overlap by default |
| `OctaveBands` | `Spectrum/OctaveBands.swift:7` | Fractional-octave bands with exact base-ten centres (IEC 61260-1); `octaveRatio` (:9), `referenceFrequency` (:12) |
| `OctaveBands.centres(fraction:from:to:)` | `Spectrum/OctaveBands.swift:17` | Centres of every band that overlaps the range |
| `OctaveBands.edges(ofCentre:fraction:)` | `Spectrum/OctaveBands.swift:36` | Lower and upper edge of one band |
| `OctaveBands.levels(of:fraction:from:to:window:frameLength:)` | `Spectrum/OctaveBands.swift:54` | dBFS RMS per band: power sum divided by the window's noise bandwidth and the zero padding (`frameLength`) |
| `Smoothing` | `Spectrum/Smoothing.swift:4` | `edgeTolerance` (:7) |
| `Smoothing.fractionalOctave(_:fraction:)` | `Spectrum/Smoothing.swift:16` | Power average over ±1/(2·fraction) octave; frequencies unchanged |
| `MagnitudeResponse.resampledLogarithmically(from:to:pointsPerOctave:)` | `Spectrum/MagnitudeResponse+Resampling.swift:9` | Resamples onto the module's one log grid (both ends on it, at most 1/pointsPerOctave octave apart), ignoring points at or below 0 Hz |

### Response

| Symbol | Where | Holds |
|---|---|---|
| `Deconvolution` | `Response/Deconvolution.swift:26` | Regularised spectral division of a recording by its sweep; the five constants (:28–42) |
| `Deconvolution.impulseResponse(recording:sweep:)` | `Response/Deconvolution.swift:52` | The impulse response, with `capturedBand` and `trustedBand` from the peak's delay and the recording's length; never traps |
| `ImpulseResponse` | `Response/ImpulseResponse.swift:16` | Circular buffer (layout under Conventions); window constants (:19–43); `samples` (:45), `sampleRate` (:47), `peakIndex` (:49), `band` (:51), `capturedBand` (:57), `trustedBand` (:61), `recordingDuration` (:64), hand-built `init` (:71), full `init` (:80), `count` (:101), `capturesWholeSweep` (:104) |
| `ImpulseResponse.index(atTime:)`, `index(atOffset:)` | `Response/ImpulseResponse.swift:107`, `:112` | Buffer index of a time after time zero, or of an offset from the linear peak, wrapped |
| `ImpulseResponse.delay` | `Response/ImpulseResponse.swift:121` | Seconds from time zero to the linear peak, refined by a parabola; negative if the peak is in the wrapped half |
| `ImpulseResponse.frequencyResponse(preWindow:postWindow:)` | `Response/ImpulseResponse.swift:142` | Magnitude windowed around the peak, in dB re the sweep, on the transform's linear grid within `trustedBand`; empty when nothing is trusted. `postWindow: roomPostWindow` for the seat |
| `ResponseComparison` | `Response/ResponseComparison.swift:7` | Comparing two responses with unknown absolute levels; `defaultMatchBand` (:9), `pointsPerOctave` (:11) |
| `ResponseComparison.levelMatched(_:to:band:)` | `Response/ResponseComparison.swift:18` | Shifts a response so its median in the band equals the reference's |
| `ResponseComparison.difference(_:_:)` | `Response/ResponseComparison.swift:33` | `first − second` in dB on a log grid over the shared range |

### Finding a sweep another device played (phase 7)

When a test sound file plays on the user's own system the phone only listens, so nothing says when a sweep starts, and the player's clock is not the phone's. Plan: [phase-7-external-playback.md](../plans/phase-7-external-playback.md).

| Symbol | Where | Holds |
|---|---|---|
| `FoundSweep` | `Response/SweepFinder.swift:4` | `start` (samples, sub-sample, the matched filter's peak: route and room delay included; negative when it began before the recording, :8), `strength` (dB over its surroundings, :12), `isComplete` (the whole sweep, allowing `maximumClockOffset`, lies inside the recording, :15), `init` (:17) |
| `SweepFinder` | `Response/SweepFinder.swift:51` | Matched filter (the sweep whitened by its own spectrum, in `detectionBand`) by overlap-save; a 5 ms envelope against the median of each side 1.5 s around; one sweep per sweep length; each candidate checked in four bands (`verificationBands`) so a glide that matches part of the sweep is refused |
| `SweepFinder.find(in:sampleRate:sweep:expectedCount:anchored:)` | `Response/SweepFinder.swift:81` | Every occurrence, by position; the strongest `expectedCount` when given. `anchored`: the caller knows from the file's timing (the clock tone, or another sweep at the file's spacing) that a sweep is due, and a speaker playing only part of the range is accepted (the rule below) |
| `SweepFinder.clockRatio(starts:expectedSpacing:sampleRate:)` | `Response/SweepFinder.swift:167` | The player's clock over the phone's (above 1: fast) from sweeps of one play on one path and the file's spacing; a missed sweep between is allowed; nil when a spacing is no whole number of the expected one |
| `SweepFinder.clockRatio(ofTone:sampleRate:)`, `readClockTone(_:sampleRate:)` | `Response/SweepFinder.swift:209`, `:216` | The clock from a recording of the clock tone: its phase demodulated at 1 kHz in 10 ms steps, a line through it; `readClockTone` adds the tone's onset (to 10 ms), which tells the files apart |
| `SweepFinder.isCorrectable(_:)` | `Response/SweepFinder.swift:277` | Within `maximumClockOffset` |
| `SweepFinder.corrected(_:ratio:)` | `Response/SweepFinder.swift:284` | The segment resampled so the sweep has its nominal length (`Interpolation`); deconvolve the result against the nominal sweep |
| `SweepFollower` | `Response/SweepFollower.swift:18` | The cheap live companion, one block at a time: events `toneStarted`, `toneEnded`, `sweepStarted(start:)` (to `startTolerance`), `sweepEnded` (:20–28); `heardFrequency`, `sweepFraction`, `activeSweepStart`, `isHearingTone`; `init(sweep:)` (:64), `feed(_:at:)` (:74), `reset()` (:69). A sweep is a block's strongest frequency standing over the octave either side, whose implied start agrees over 8 of 10 blocks; the tone is 5 blocks within 0.5 % of 1 kHz. It triggers and shows progress; `find` decides |
| `Interpolation.resample(_:from:step:count:)` | `Foundation/Interpolation.swift:24` | A Kaiser-windowed sinc (48 taps a side, 256 phases, linear between them): flat within 0.01 dB to 21 kHz at 48 kHz, images about 80 dB down; for steps near 1 (`Interpolation` at :13) |

**The verification rule (unanchored and anchored).** A candidate's band-limited matched filter must peak within 5 ms of its start by `minimumBandStrength` in each band counted. Unanchored, every `verificationBands` band the recording holds must agree, all but one when three or more: only a chirp at the sweep's rate over most of 150 Hz–12 kHz passes, which keeps music and noise out. Anchored, `minimumAnchoredBands` (4) neighbouring `anchoredBands` must agree, about 3.2 octaves: a speaker with a dead tweeter (nothing above 2 kHz), a dead woofer (nothing under 500 Hz) or only 200 Hz–2 kHz is found, while a 1 kHz tone followed by a glissando where a sweep would be due (an exact-rate octave, an exact-rate octave and a half, a two-octave semitone run) is not. The timing anchor alone is not trusted: the anchored rule still asks for three octaves of the sweep at its exact rate. A speaker heard only under 150 Hz (a subwoofer alone) is never found, anchored or not: nothing of it lies in `detectionBand`, and the clock tone at 1 kHz does not reach the microphone either. The listening session then says it heard sound it could not recognise (`ExternalMeasurementFailure.soundNotRecognised` in ResoniqAudio), never that it heard nothing.

### Room

| Symbol | Where | Holds |
|---|---|---|
| `DecayEstimate` | `Room/Decay.swift:5` | One band's decay and what it rests on: `band` (:19), `seconds` (RT60, :21), `evaluationRange` (:22), `dynamicRangeDecibels` (:25), `nonlinearity` (ISO 3382-2 ξ in ‰, :32), `init` (:34) |
| `DecayEstimate.EvaluationRange` | `Room/Decay.swift:8` | `t20`, `t30`; `top` (−5 dB, :13), `bottom` (−25 or −35 dB, :15) |
| `Decay` | `Room/Decay.swift:86` | Decay time by band: zero-phase band filter, Lundeby noise and truncation, Schroeder integration with compensation, a line over T30 or T20; the constants (:90–120) |
| `Decay.minimumDuration(of:)`, `blockDuration(of:sampleRate:)` | `Room/Decay.swift:124`, `:130` | Response needed after the peak (`minimumCycles` periods of the band's bottom); the averaging block |
| `Decay.estimate(impulseResponse:band:sweep:)` | `Room/Decay.swift:141` | One band; nil when the response cannot support it (outside `trustedBand` or `capturedBand`, too short, too little dynamic range, too fast to tell from the filter, non-finite). `sweep` defaults to nil; pass it for a deconvolved response |
| `Decay.estimates(impulseResponse:sweep:)` | `Room/Decay.swift:152` | `[(band, estimate?)]` over the `OctaveBands` octaves 63 Hz to 4 kHz; bands over the same stretch share one transform |
| `Decay.bassBand(for:)`, `bass(impulseResponse:sweep:)` | `Room/Decay.swift:185`, `:194` | The band under 80 Hz (from 20 Hz or the bottom of `trustedBand`; nil under half an octave) and its decay: "< 80 Hz ≈ 0.6 s" |
| `ResponseAverage` | `Room/ResponseAverage.swift:9` | Several responses on the common log grid (`ResponseComparison.pointsPerOctave`) over the range they all cover; empty when none or nothing shared |
| `ResponseAverage.power(_:)` | `Room/ResponseAverage.swift:13` | Power (energy) average in dB: mean of `10^(dB/10)` |
| `ResponseAverage.spread(_:)` | `Room/ResponseAverage.swift:23` | Loudest less quietest, in dB: large where the response changes from spot to spot |

### Distortion

| Symbol | Where | Holds |
|---|---|---|
| `SweepDistortion` | `Distortion/HarmonicDistortion.swift:7` | Result of a sweep analysis: `measurableMarginDecibels` (:14), `fundamental` (:18), `harmonics` by order (:23), `thd`, gross (:29), `noiseFloor` (:35), `init` (:37) |
| `SweepDistortion` members | `Distortion/HarmonicDistortion.swift:51` | `thdPercent(at:)`, NaN outside the band (:51), `noiseFloorPercent(at:)` (:58), `isMeasurable(at:)` (:66) |
| `HarmonicDistortion` | `Distortion/HarmonicDistortion.swift:91` | Harmonic distortion against frequency, from one sweep (Farina's method); `defaultOrders` (:93), `preWindow` (:95), `topEdgeMargin` (:100), `trustedStartRatio` (:105), `minimumTrustedFrequency` (:108), `minimumAccurateDuration` (:112), `minimumTail` (:117) |
| `HarmonicDistortion.upperFrequency(order:sweep:)` | `Distortion/HarmonicDistortion.swift:123` | Highest fundamental at which an order is reported: the end less `topEdgeMargin` and the fade-out, over the order |
| `HarmonicDistortion.trustedBand(order:sweep:)` | `Distortion/HarmonicDistortion.swift:132` | The fundamentals over which an order is accurate |
| `HarmonicDistortion.analyze(impulseResponse:sweep:orders:)` | `Distortion/HarmonicDistortion.swift:143` | Windows each harmonic's response, and the same windows on a noise-only stretch for the floor |
| `ToneDistortionResult` | `Distortion/ToneDistortion.swift:8` | `thdPercent`, net (:12), `thdPlusNoisePercent` (:15), `harmonicLevels` (:18), `nonHarmonicResidue` (:22), `fundamentalFrequency` (:26), `noiseFloorPercent` (:29), `init` (:31), `isToneFound` (:48), `isMeasurable` (:53) |
| `ToneDistortion` | `Distortion/ToneDistortion.swift:86` | Distortion of a recorded steady tone from one Blackman–Harris spectrum; `maximumOrder` (:88), `lobeHalfWidth` (:91), `minimumToneToNoiseDecibels` (:94) |
| `ToneDistortion.analyze(recording:frequency:sampleRate:)` | `Distortion/ToneDistortion.swift:99` | Locates the tone, then THD, THD+N, harmonic levels, residue and the floor; no tone found gives NaN figures |

### Quality

| Symbol | Where | Holds |
|---|---|---|
| `QualityThresholds` | `Quality/QualityThresholds.swift:8` | Every number that decides whether a recording is fit to analyse, 14 fields (:16–87), `init` (:89) and `standard` (:123) |
| `Level` | `Quality/LevelMeter.swift:7` | `peak` (:9), `rms` (:11), `dcOffset` (:13), `init` (:15), `isFinite` (:23), `peakDecibels` (:26), `rmsDecibels` (:29), `crestFactorDecibels` (:33) |
| `LevelMeter.measure(_:)` | `Quality/LevelMeter.swift:43` | Peak, RMS and DC offset of a buffer; NaN for all three when a sample is not finite (`LevelMeter` at :40) |
| `ClippingReport` | `Quality/ClippingDetector.swift:4` | `clippedSampleCount` (:6), `clippedFraction` (:8), `longestRun` (:10), `init` (:12), `isClipped` (:20) |
| `ClippingDetector.detect(_:thresholds:)` | `Quality/ClippingDetector.swift:38` | Finds runs at full scale, and flat tops at the buffer's own extreme longer than a clean crest of that level and frequency allows (`ClippingDetector` at :36) |
| `NoiseFloorReport` | `Quality/NoiseFloor.swift:4` | `rmsDecibels` (:7), `bandLevels` (:14), `fluctuationDecibels` (:17), `isSteady` (:22), `init` (:24) |
| `NoiseFloor.measure(_:sampleRate:thresholds:)` | `Quality/NoiseFloor.swift:41` | Measures a quiet recording: broadband RMS, the `OctaveBands` octaves 31.6 Hz to 15.8 kHz, steadiness; never steady when corrupt (`NoiseFloor` at :33) |
| `SignalToNoise` | `Quality/SignalToNoise.swift:8` | `ratio(signal: Level, noise: Level)` (:10), `ratio(signal: [Float], noise: [Float])` (:15), `bandRatios(signal:noise:sampleRate:)` on buffers (:21), `bandRatios(signal:noise:)` on band levels (:30) |
| `NoiseGate` | `Quality/NoiseGate.swift:13` | The live pause and resume decision on one block: `isTooNoisy(block:baseline:thresholds:)` (:16), `isQuietEnough(block:baseline:thresholds:)` (:26); a non-finite block or baseline pauses and never resumes |
| `RecordingVerdict` | `Quality/RecordingQuality.swift:7` | Cases `valid` (:9), `clipped` (:11), `tooQuiet` (:13), `tooNoisy` (:16), `silent` (:18), `corrupt` (:21) |
| `RecordingQuality.assess(recording:noiseFloor:thresholds:)` | `Quality/RecordingQuality.swift:39` | The verdict: corrupt, then silent, clipped, too quiet, too noisy; the first that fails decides (`RecordingQuality` at :25) |

## Thresholds and constants

Every public static constant, and the `standard` quality thresholds. A value marked "first guess" is called that in its doc comment and has to be tuned on a device.

| Constant | Where | Value | Note |
|---|---|---|---|
| `Decibels.floor` | `Foundation/Decibels.swift:9` | −160 dB | Stands in for silence |
| `LogSweep.maximumAmplitude` | `Foundation/LogSweep.swift:10` | 0.25 (−12 dBFS) | The safe level |
| `LogSweep.minimumFadeDuration` | `Foundation/LogSweep.swift:13` | 0.005 s | Shortest fade of any test signal |
| `LogSweep.defaultFadeDuration` | `Foundation/LogSweep.swift:16` | 0.02 s | Longer fades narrow the trusted band |
| `LogSweep.trustedStartRatio` | `Foundation/LogSweep+Measurement.swift:6` | 2 | The response is trusted from twice the start |
| `LogSweep.trustedEndMargin` | `Foundation/LogSweep+Measurement.swift:9` | 1/12 octave | Under the end |
| `LogSweep.reportedBand` | `Foundation/LogSweep+Measurement.swift:26` | 20 Hz…20 kHz | What the app reports a response over |
| `LogSweep.measurementStartFrequency` | `Foundation/LogSweep+Measurement.swift:33` | 10 Hz | |
| `LogSweep.measurementEndFrequency` | `Foundation/LogSweep+Measurement.swift:34` | 22 kHz | Under Nyquist at 44.1 kHz |
| `LogSweep.measurementDuration` | `Foundation/LogSweep+Measurement.swift:35` | 4 s | |
| `OctaveBands.octaveRatio` | `Spectrum/OctaveBands.swift:9` | 10^0.3 ≈ 1.9953 | |
| `OctaveBands.referenceFrequency` | `Spectrum/OctaveBands.swift:12` | 1000 Hz | |
| `Smoothing.edgeTolerance` | `Spectrum/Smoothing.swift:7` | 1e-5 | Fraction of the edge frequency |
| `Deconvolution.inBandRegularisation` | `Response/Deconvolution.swift:28` | 1e-6 (−60 dB) | Times the sweep's mean in-band power |
| `Deconvolution.outOfBandRegularisation` | `Response/Deconvolution.swift:30` | 1e4 (+40 dB) | Same reference |
| `Deconvolution.lowCutRatio` | `Response/Deconvolution.swift:34` | 0.35 | High-pass corner, as a fraction of the sweep's start |
| `Deconvolution.lowStopRatio` | `Response/Deconvolution.swift:38` | 0.7 | ε has risen to the out-of-band value at this fraction of the start; it ramps in from the start |
| `Deconvolution.cutMargin` | `Response/Deconvolution.swift:42` | 1 octave | Trusted band inside a cut in the recording |
| `ImpulseResponse.defaultPreWindow` | `Response/ImpulseResponse.swift:19` | 0.002 s | |
| `ImpulseResponse.defaultPostWindow` | `Response/ImpulseResponse.swift:24` | 0.1 s | Resolves down to about 10 Hz |
| `ImpulseResponse.roomPostWindow` | `Response/ImpulseResponse.swift:33` | 0.5 s | Resolves about 2 Hz (1.5 Hz grid at 48 kHz); about 8 dB more noise than the default |
| `ImpulseResponse.postTaperFraction` | `Response/ImpulseResponse.swift:36` | 0.5 | |
| `ImpulseResponse.maximumPostTaper` | `Response/ImpulseResponse.swift:40` | 0.05 s | Caps the fade; equal to the default window's, so only longer windows change |
| `ImpulseResponse.minimumTransformSize` | `Response/ImpulseResponse.swift:43` | 16384 | 2.9 Hz a point at 48 kHz |
| `Decay.minimumDynamicRangeT20` | `Room/Decay.swift:90` | 35 dB | Bottom of T20 10 dB above the noise (ISO 3382-1) |
| `Decay.minimumDynamicRangeT30` | `Room/Decay.swift:92` | 45 dB | T30 from here |
| `Decay.minimumCycles` | `Room/Decay.swift:96` | 20 periods | Of the band's bottom: 0.45 s in the 63 Hz octave, 1 s from 20 Hz. First guess |
| `Decay.filterSkirtOctaves` | `Room/Decay.swift:99` | 0.5 octave | Raised-cosine skirt at each edge, −6 dB at the edge. First guess |
| `Decay.noiseTailFraction` | `Room/Decay.swift:101` | 0.1 | Least share the noise is read from (Lundeby) |
| `Decay.minimumBlockDuration` | `Room/Decay.swift:104` | 0.01 s | Or 1 / bandwidth when longer |
| `Decay.lundebyIterations` | `Room/Decay.swift:106` | 5 | |
| `Decay.minimumBandwidthTimeProduct` | `Room/Decay.swift:112` | 7 | Bandwidth × T60; the filter's own reads 5.8. First guess |
| `Decay.octaveRange` | `Room/Decay.swift:114` | 63 Hz…4 kHz | Seven octaves |
| `Decay.bassUpperFrequency` | `Room/Decay.swift:116` | 80 Hz | |
| `Decay.bassLowerFrequency` | `Room/Decay.swift:118` | 20 Hz | `LogSweep.reportedBand`'s bottom |
| `Decay.minimumBassOctaves` | `Room/Decay.swift:120` | 0.5 octave | First guess |
| `ResponseComparison.defaultMatchBand` | `Response/ResponseComparison.swift:9` | 300…3000 Hz | |
| `ResponseComparison.pointsPerOctave` | `Response/ResponseComparison.swift:11` | 48 | |
| `SweepDistortion.measurableMarginDecibels` | `Distortion/HarmonicDistortion.swift:14` | 10 dB | Above the floor; shared with `ToneDistortion` |
| `HarmonicDistortion.defaultOrders` | `Distortion/HarmonicDistortion.swift:93` | `[2, 3, 4, 5]` | |
| `HarmonicDistortion.preWindow` | `Distortion/HarmonicDistortion.swift:95` | 0.005 s | Capped at half the gap to the next higher order |
| `HarmonicDistortion.topEdgeMargin` | `Distortion/HarmonicDistortion.swift:100` | 1/6 octave | Below the sweep's end, plus the fade-out; no harmonic is read above it |
| `HarmonicDistortion.trustedStartRatio` | `Distortion/HarmonicDistortion.swift:105` | 6 | Harmonics trusted from six times the start |
| `HarmonicDistortion.minimumTrustedFrequency` | `Distortion/HarmonicDistortion.swift:108` | 80 Hz | And never below this |
| `HarmonicDistortion.minimumAccurateDuration` | `Distortion/HarmonicDistortion.swift:112` | 3 s | Shortest sweep for the stated THD accuracy |
| `HarmonicDistortion.minimumTail` | `Distortion/HarmonicDistortion.swift:117` | 0.205 s | Recording past the sweep's end needed for a noise floor |
| `ToneDistortion.maximumOrder` | `Distortion/ToneDistortion.swift:88` | 10 | |
| `ToneDistortion.lobeHalfWidth` | `Distortion/ToneDistortion.swift:91` | 5 resolution bins | Blackman–Harris main lobe is ±4, plus one |
| `ToneDistortion.minimumToneToNoiseDecibels` | `Distortion/ToneDistortion.swift:94` | 20 dB | Below it no tone is found |
| `SweepFinder.detectionBand` | `Response/SweepFinder.swift:54` | 150 Hz…12 kHz | First guess |
| `SweepFinder.envelopeDuration` | `Response/SweepFinder.swift:57` | 5 ms | Holds a peak dispersed by 1000 ppm (4 ms) |
| `SweepFinder.minimumStrength` | `Response/SweepFinder.swift:62` | 13 dB | First guess; a sweep in room noise makes about 60 dB |
| `SweepFinder.surroundings`, `surroundingsGuard` | `Response/SweepFinder.swift:65–66` | 1.5 s, 0.15 s | Each side's median, the louder kept |
| `SweepFinder.maximumClockOffset` | `Response/SweepFinder.swift:71` | 0.001 (1000 ppm) | The limit beyond which a run is invalid (`playerClockOff`); players keep within ±100 ppm, cheap ones ±500 |
| `SweepFinder.clockToneFrequency`, `clockToneDuration`, `clockToneAmplitude` | `Response/SweepFinder.swift:195–197` | 1 kHz, 2 s, 0.125 (−18 dBFS) | The tone at the start of every test sound file |
| `SweepFinder.minimumToneDuration` | `Response/SweepFinder.swift:199` | 0.8 s | Of steady tone, after 0.2 s is trimmed from each end |
| `SweepFinder.verificationBands` | `Response/SweepFinder.swift:331` | 150–500, 500–1500, 1500–4500, 4500–12000 Hz | Unanchored: all but one must agree (both of two) |
| `SweepFinder.anchoredBands` | `Response/SweepFinder.swift:340` | `detectionBand` in eight of about 0.8 octave | Anchored candidates are checked in these |
| `SweepFinder.minimumAnchoredBands` | `Response/SweepFinder.swift:348` | 4 neighbouring | About 3.2 octaves at the sweep's exact rate and timing. First guess |
| `SweepFinder.minimumBandStrength` | `Response/SweepFinder.swift:335` | 6 dB | A band's peak over the largest output 20–250 ms around it. First guess |
| `SweepFollower.minimumProminence` | `Response/SweepFollower.swift:32` | 15 dB | Over the octave either side. First guess |
| `SweepFollower.toneProminence` | `Response/SweepFollower.swift:34` | 25 dB | First guess |
| `SweepFollower.confirmingBlocks` | `Response/SweepFollower.swift:36` | 8 (of 10) | Longer than a gliding note; a sweep is recognised about 2.3 s after it starts |
| `SweepFollower.startTolerance` | `Response/SweepFollower.swift:39` | 0.06 s | |
| `SweepFollower.toneTolerance`, `toneBlocks` | `Response/SweepFollower.swift:42`, `:44` | 0.5 %, 5 blocks | |
| `SweepFollower.topFrequency` | `Response/SweepFollower.swift:46` | 16 kHz | |
| `Interpolation.halfWidth`, `phases`, `kaiserBeta` | `Foundation/Interpolation.swift:15–19` | 48, 256, 8.6 | |
| `QualityThresholds.standard.fullScaleLevel` | `Quality/QualityThresholds.swift:124` | 32767/32768 | Largest 16-bit sample |
| `.fullScaleRun` | `Quality/QualityThresholds.swift:125` | 2 samples | |
| `.flatTopRun` | `Quality/QualityThresholds.swift:126` | 8 samples | First guess; a longer run must also beat a clean crest |
| `.flatTopTolerance` | `Quality/QualityThresholds.swift:127` | 1e-5 | First guess |
| `.flatTopMinimumLevel` | `Quality/QualityThresholds.swift:128` | 0.1 (−20 dBFS) | First guess |
| `.silencePeakDecibels` | `Quality/QualityThresholds.swift:129` | −90 dBFS | One 16-bit step |
| `.minimumPeakDecibels` | `Quality/QualityThresholds.swift:130` | −40 dBFS | First guess |
| `.minimumSignalToNoiseDecibels` | `Quality/QualityThresholds.swift:131` | 20 dB | First guess; a gate for the response, kept at 20 (see below) |
| `.steadinessBlockDuration` | `Quality/QualityThresholds.swift:132` | 0.1 s | The block the live gate watches |
| `.maximumNoiseFluctuationDecibels` | `Quality/QualityThresholds.swift:133` | 6 dB | First guess |
| `.pauseMarginDecibels` | `Quality/QualityThresholds.swift:134` | 10 dB | First guess |
| `.resumeMarginDecibels` | `Quality/QualityThresholds.swift:135` | 6 dB | First guess |
| `.pauseCeilingDecibels` | `Quality/QualityThresholds.swift:136` | −30 dBFS | First guess, uncalibrated |
| `.resumeCeilingDecibels` | `Quality/QualityThresholds.swift:137` | −34 dBFS | First guess |

## Accuracy

What the tests hold the module to, all on simulated recordings at 48 kHz (and 44.1 kHz where named).

| Result | Stated accuracy | Where it holds | Test |
|---|---|---|---|
| Frequency response | Within 0.3 dB; within 0.1 dB from three times the start | `LogSweep.trustedBand`, default window, start ≥ 10 Hz, sweeps of 1 s and longer | `TrustedBandTests` |
| Frequency response with white noise 20 dB under the recording | 0.06 dB after 1/6-octave smoothing (0.5 dB in a single bin) | 100 Hz–16 kHz | measured by probe, not asserted |
| Harmonic levels and THD, noiseless | Within 3 % of the value (0.25 dB) | `HarmonicDistortion.trustedBand(order:sweep:)`, sweeps of `minimumAccurateDuration` (3 s) or longer | `HarmonicDistortionTests` |
| THD under noise | Third-octave average within 3 % of √(THD² + floor²); a single point scatters by up to floor/THD | Where `isMeasurable(at:)` | `DistortionNoiseFloorTests` |
| End to end (filter, 2 % THD, −60 dBFS noise, delay) | Response 0.25 dB from 50 Hz to 16 kHz; THD within a quarter | 3 s sweep from 20 Hz | `EndToEndTests` |
| Tone THD | 2.236 % read within 0.01 percentage points, fifth harmonic within 0.1 dB, with up to a 100 ppm clock offset | 1–10 s tones | `ToneDistortionTests` |
| Decay, one synthetic decay | Within 10 % (0.3, 0.6, 1.2 s read 1.2, 3.5, 4.7 % long); 1.0 and 0.3 s in two octaves of one response within 3 % | 500 Hz octave; 125 Hz and 1 kHz octaves | `DecayTests` |
| Decay, bass | Mean of 16 decays within 10 % (read 0.0, 4.5, 1.6 % long for 0.3, 0.6, 1.2 s); one reading scatters 12–17 % | 40–80 Hz | `DecayTests` |
| Decay through the whole chain | A 0.52 s resonance read within 0.2 % from its own impulse response and from a deconvolved 4 s sweep, the two within 0.01 %; a 0.14 s treble resonance with a short tail within 0.1 % | 35–70 Hz; 2 kHz octave | `DecayTests` |
| Room window | A 20 ms reflection's comb within 0.08 dB; a 45 Hz mode within 0.05 dB of its level on the grid (the default window reads it 2.7 dB low); an unchanged sweep flat within 0.18 dB over the trusted band | `roomPostWindow` | `RoomWindowTests` |

| Sweep found in a recording | Every sweep of 1, 2 or 3 found within 24 samples through a speaker in noise (its group delay); within 0.2 sample without one; none in 60 s of pink noise or of a synthetic tune with gliding notes | Measurement sweep | `SweepFinderTests` |
| Clock from the spacing of three sweeps | Within 10 ppm (0.02–0.05 ppm at most offsets, 5 ppm at −300 ppm where the dispersed peak moves) | ±500 ppm, through a speaker | `SweepFinderTests` |
| Clock from the clock tone | Within 0.06 ppm (asserted 1 ppm), through a speaker with an all-pass crossover, noise 33 dB under | −500 to +1000 ppm | `SweepFinderTests` |
| A clock offset, corrected | Response within 0.011 dB of none over 20 Hz–20 kHz after third-octave smoothing (asserted 0.1 dB); THD within 0.17 % of its value, 100 Hz–5 kHz (asserted 5 %) | ±100, ±300, ±500 ppm | `ClockOffsetAccuracyTests` |
| A clock offset, not corrected | Response off by 4.0, 13.7, 18.3 dB at −100, −300, −500 ppm and 1.2, 1.4, 0.9 dB at +100, +300, +500 ppm (the worst point, at 20 Hz; −4 dB at 500 Hz at −500 ppm); THD off by up to 54 % | Same | printed, not asserted |
| Speed | 60 s searched in 0.17 s (release, Apple silicon Mac; 0.6–2.5 s in a debug build); the follower 0.17 ms a 100 ms block (2–4 ms debug) | | `SweepFinderSpeedTests`, `SweepFollowerTests` |

So a run from another device is never analysed uncorrected: a slow player's bass arrives before the response's peak by more than the 2 ms pre-window keeps. Corrected, its accuracy is the normal path's; the limit is `maximumClockOffset` (1000 ppm), past which something resamples the file wrongly and its sound is pitch-shifted.

For `LogSweep.measurement` the response is trusted from 20 Hz to 20.8 kHz and the second harmonic from 80 Hz to 9.4 kHz.

The signal-to-noise gate stays at 20 dB. With noise 20 dB under the recording the response is still good to a few hundredths of a dB once smoothed, while sweep THD reads 2 to 5 % from noise alone. Distortion confidence is decided per frequency by the floor measured on the recording (`SweepDistortion.isMeasurable(at:)`), so a higher broadband gate would only reject recordings whose response is fine.

## Tests

`ResoniqKit/Tests/ResoniqDSPTests/`, run on the Mac by `make test`.

- `FoundationTests`: dB conversions (NaN stays NaN), a seeded FFT round trip at three sizes and padding, sweep length, safe-level clamp, silent ends and instantaneous frequency, log-frequency interpolation including a point at 0 Hz.
- `SignalsTests`: `TestSignal` length, safe level, fades and frequency against an independently computed level; every generator fed hostile amplitudes, fades and durations (no sample above the safe level, none non-finite, first and last exactly zero); the 5 ms minimum fade; each `Window`'s mean, noise bandwidth (1, 1.5, 1.3628, 2.0044) and shape.
- `SpectrumTests`: spectrum bins and RMS level for every window, zero padding, Welch averaging against the analytic noise level, empty and one-sample buffers; third-octave and octave centres, band levels (a tone fills one band at its RMS; a padded spectrum reads right once the frame length is named; noise rises 3 dB an octave; the noise floor's bands are these bands); smoothing; log resampling.
- `ResponseTests`: unit impulse; flat, delayed, quieter and filtered responses inside the band; content above and below the sweep is not amplified (10–14 Hz at least 10 dB under an equal 40 Hz tone); 12 Hz rumble does not bend the bass; `CapturedBandTests` (whole, cut early, started late, empty, short, all-zero and corrupt recordings); `TrustedBandTests` (the measurement sweep covers the reported band; every point of the trusted band within the stated accuracy for four sweeps at two rates); level matching and the log-grid difference.
- `DistortionTests`: square and cubic laws inside the trusted bands within 0.25 dB; THD within 3 % across the trusted band for three sweeps; the top band of a 1 s sweep stops below its fade; the fundamental against the biquad's own magnitude; a clean system is not measurable; `DistortionNoiseFloorTests` (noise 20 dB under reads THD but is not measurable, the floor matches what the windows collect, real distortion above the floor is measured, a short tail has no floor); `ToneDistortion` THD, THD+N, harmonics below Nyquist, the residue for lines and clicks, a clock offset, silence, noise alone, short and corrupt recordings, and measurability.
- `QualityTests`: level, clipping (full scale, limiter flat tops, mild limiting, one sample is not clipping, the app's sweep quantised to 16 bits and slow clean sines are not clipping), noise floor bands (that add up to the broadband level) and steadiness, signal-to-noise against independently computed RMS and per band, the verdict order including corrupt, a real measurement-sweep recording, the gate's hysteresis, and non-finite input everywhere.
- `RoomTests`: `DecayTests` (synthetic decays of band-limited noise with known decay times in an octave and in the bass, two bands in one response and the octave table, T30 or T20 or nothing by dynamic range with the range checked against the fixture's own levels, bands outside the trusted band, the bass band's clipping, too short, a unit impulse (the filter's own decay), corrupt and silent responses, a resonance read directly and through sweep and deconvolution against the decay its poles fix, a short tail with the sweep named); `RoomWindowTests` (a reflection's comb against `|1 + g·e^(−j2πfτ)|`, a gate removes it, a 45 Hz mode at its height, the trusted band and flatness with the room window); `ResponseAverageTests` (energy mean, not dB mean; log grid; zero spread for identical responses; different grids; empty and disjoint input).
- `PublicAPITests`: imports the module without `@testable` and builds every result type, so their initialisers stay public.
- `EndToEndTests`: the phase's "Done when". A 3 s sweep from 20 Hz to 20 kHz through a simulated speaker (80 Hz high-pass, +6 dB bell at 2 kHz, about 2 % THD, white noise at −60 dBFS, 0.15 s late). It asserts that the delay is within 0.5 ms, the magnitude response within 0.25 dB from 50 Hz to 16 kHz after level matching (the plan's bar was 1 dB), and THD within a quarter of its value at 300, 500, 1000, 2000 and 3000 Hz.
- `SweepFinderTests`, `SweepFollowerTests`, `ClockOffsetAccuracyTests`, `SweepFinderSpeedTests`: sweeps played on a clock `ratio` times the phone's, computed exactly at the stretched times (`ExternalRecording`, not resampled); 1, 2, 3 sweeps found at their positions, a cut sweep at either end flagged, nothing in pink noise or a tune, a sweep found under music; the clock from three sweeps' spacing and from the tone; the interpolator against an exact sine; the accuracy with and without correction; the follower through a file of tone and three sweeps, the frequency it reports, no event in noise or music, its cost and the finder's.
- `FaultySpeakerFinderTests`: three sweeps through eighth-order edges: a dead tweeter, a dead woofer and a 200 Hz–2 kHz speaker are each found anchored (and, in this simulation's quiet noise, unanchored too: an attenuated band still peaks over its own surroundings; in a real room the drowned bands will not, which is what anchoring is for); a subwoofer alone is not found; music with a 1 kHz tone and three glissandos where sweeps are due gives nothing, anchored or not; pink noise and the tune give nothing anchored.
- `SimulatedSpeaker`: not a test; the biquads, seeded noise and polynomial nonlinearity the tests share.

All of this is simulated. Nothing here has run on a microphone, and every first-guess threshold is untested against a real iPhone.

## Limits

What the doc comments say the module cannot tell you.

- **Deconvolution:** anything outside the sweep's range or outside `capturedBand`, the absolute sound pressure, or whether a feature belongs to the speaker, the room or the microphone. `capturedBand` rests on the linear peak's delay, which includes the speaker's group delay.
- **`ImpulseResponse.delay`:** the arrival of the largest sample, not the first sound; the speaker's group delay is included.
- **`frequencyResponse`:** nothing below about `1 / postWindow` hertz is resolved, and reflections inside the window are part of the result. The stated accuracy is for the default window. A reflection-free response needs a shorter window and gives up the bass.
- **`roomPostWindow`:** about 8 dB more noise in every point than the default window, so smooth before reading; the late part of the window holds no treble unless the recording runs at least 0.5 s past the sweep. It cannot say which part of the curve is the room and which the speaker; `ResponseAverage.spread` over several spots is the clue.
- **`Decay`:** one seat's decay, not the room's; not a decay faster than the band filter's own (`minimumBandwidthTimeProduct`); nothing outside `trustedBand`; not whether a long decay is the room, the speaker or the furniture. One reading of a narrow bass band scatters by 12–17 % because the decay of random sound is itself random. Without the sweep, a deconvolved response's upper bands are read into the stretch past the recording, where it is empty, so their noise reads low. A real decay just above `minimumBandwidthTimeProduct` can read under it and give nothing. `nonlinearity` is reported but not judged: ISO 3382-2's 10 ‰ suits broad bands, while an exact exponential reads 10–70 ‰ in the bass.
- **`ResponseAverage`:** the levels must already mean the same thing (level-match first if they do not); the range is the one every response covers, so one narrow response narrows the result.
- **`ResponseComparison.levelMatched`:** cannot tell a level difference from a broadband shape difference inside the match band. It and `difference` still trap when the two responses share no range; check that they do.
- **`HarmonicDistortion`:** not the distortion of music (intermodulation); not which part of the chain distorted; not rattles. THD is gross: a clean system reads as its floor, so read it with `isMeasurable(at:)`. The floor needs `minimumTail` of recording after the sweep and counts a room's late reverberation as noise, so in a live room it errs towards "not measurable". Below the trusted band the harmonic chirp's abrupt start reads the harmonic low.
- **`ToneDistortion`:** the residue cannot tell a rattle in the speaker from one in the furniture, a buzz from mains hum, or a defect from a door or a voice. Steady hiss is subtracted, so a defect that only adds hiss is invisible. The recording must be longer than `2 · lobeHalfWidth / frequency` seconds and hold only the settled tone; the tone must lie within `lobeHalfWidth` resolution bins of the nominal frequency.
- **Levels:** dBFS RMS only; the same room reads differently on two phone models. Below about 100 Hz an iPhone microphone rolls off, so a low band reading may be the microphone.
- **`ClippingDetector`:** cannot tell a limiter from a genuinely flat waveform; a few spikes above a limited stretch hide it; a limiter that adds ripple, a soft limiter that rounds the crest, and mild limiting of a tone above a few hundred hertz are not caught. A clean sine below about 150 Hz within 0.0003 dB of full scale counts as clipped.
- **`NoiseFloor`:** steady is not quiet, since a loud fan is steady. Under 200 ms the floor cannot be shown steady.
- **`SignalToNoise`:** the figure is (signal + noise) over noise, so it is never below about 0 dB and is close to the true ratio only well above it. The broadband ratio can pass while one band is drowned; use `bandRatios`.
- **`RecordingQuality`:** judges the recording, not the speaker. `tooNoisy` never means the speaker is faulty; `corrupt` means the data, not the room.
- **`NoiseGate`:** cannot tell sweep from noise, and the ceilings only suit room-only blocks. Hysteresis and timing belong to the audio session.
- **`SweepFinder`:** cannot tell which speaker played a sweep, nor whether the sound went through a lossy format or a sample-rate converter on the way (both bend the top of the range and the distortion figures). One sweep alone does not give the clock: stretching an exponential sweep is a shift plus a delay that grows with frequency, and a speaker's own phase makes delays of that size (a sharpest-peak search missed by up to 360 ppm with one all-pass crossover), hence the clock tone. A phone moving towards the speaker shifts the tone by 30 ppm per cm/s. A real chirp in music with the sweep's exact rate over most of its range would pass the band check.
- **`SweepFollower`:** says nothing in the first 1.4 s of a sweep (under 150 Hz) and needs 0.8 s more to be sure, so the screen's portrait fills from about 2.3 s; the follower is never the authority on where a sweep is.

## Open questions

- The measurement sweep starts at 10 Hz so that the response can be reported from 20 Hz. It plays at the safe level like every other frequency, but a vented speaker at high volume moves a lot at 10 Hz. The owner should confirm the start, or raise it and report the response from twice the new start.
- Sweep length: 4 s is chosen for accuracy (THD needs 3 s) and signal-to-noise. The phone's microphone and a real room may argue for longer.
- Every value marked first guess above needs tuning on a device, in particular the live gate's margins and ceilings, which are uncalibrated and may mean different things on two phones.
- The broadband signal-to-noise minimum is dominated by low-frequency rumble. Should the verdict use a band-limited ratio?
- `flatTopRun` misses mild limiting of a high tone and `fullScaleLevel` misreads a clean low sine at full scale; a real recording may show which matters.
- Hysteresis, block counts and where to resume the sweep are left to the audio session ([ResoniqAudio](ResoniqAudio.md)).
- The seat measurement needs a longer recording tail than Diagnose: at least `roomPostWindow` (0.5 s) for the response, and for the decay the decay itself plus a stretch of noise (`Decay.noiseTailFraction` of what is read). For a 1 s bass decay a tail of 2 s or more is safe. The audio session should set it.
- Playing from another device, only a device can tell: real players' clock offsets (assumed within ±500 ppm) and whether they resample a 48 kHz file to 44.1 kHz (which leaves only the offset, the sweep reaching 22 kHz under the 22.05 kHz Nyquist); a lossy format or AirPlay to a receiver adding its own processing (room correction, loudness, a limiter) between the file and the speakers; and whether `minimumStrength`, `minimumBandStrength` and the follower's prominences hold in real rooms with real music.
- Whether a phone in a real room reaches `Decay.minimumDynamicRangeT20` (35 dB) in the bass, where the microphone rolls off and rumble is loudest, is unknown. If it rarely does, T15 (−5 to −20 dB, 30 dB) is the next step down.
