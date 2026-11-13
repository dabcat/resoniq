---
type: "module"
spec_module: "A"
phase: 1
status: "active"
tags:
  - "module"
---
# ResoniqDSP

Pure signal maths on `[Float]` buffers with Accelerate: test signals, FFT, frequency response, impulse response, THD, noise floor, clipping, smoothing. No audio hardware, no actors, runs on the Mac.

The module turns a recording of a played [`LogSweep`](#foundation) into an impulse response, a frequency response and harmonic distortion, and it decides whether a recording is fit to analyse. It knows nothing about the microphone, the session or the screen: callers hand it samples and a sample rate. Plan: [phase-1-dsp.md](../plans/phase-1-dsp.md).

Paths below are relative to `ResoniqKit/Sources/ResoniqDSP/`.

## Conventions

Each is stated once, here, with the symbol that defines it.

- **Buffers.** Audio is `[Float]` in the range −1…1 plus a separate `sampleRate` in hertz. Every function that needs the rate takes it, or reads it from `LogSweep` or `ImpulseResponse`.
- **Decibels and full scale.** A level is in decibels relative to full scale (1.0 is 0 dB), and the microphone is uncalibrated, so no level is a sound pressure. A frequency response is "dB re the sweep": 0 dB means the sweep came back unchanged. Only shapes and differences mean anything. [`Decibels`](#foundation) converts, and `Decibels.floor` (−160) stands in for silence instead of minus infinity.
- **A curve is `MagnitudeResponse`.** Rising frequencies in hertz and a level in decibels at each: a spectrum, a frequency response, a distortion curve or a set of band levels.
- **FFT normalisation.** `FFT.forward` is unnormalised and `FFT.inverse` divides by N, so `inverse(forward(x)) == x`. Sizes are powers of two. Bin `k` of an N-point transform is `k · sampleRate / N` Hz (`FFT.frequency(ofBin:size:sampleRate:)`).
- **Spectrum level.** `SpectrumAnalyzer` divides out the window's coherent gain, so a sine of amplitude `A` on a bin reads `20·log10(A)` whatever the window. Bins run from DC to Nyquist, `size / 2 + 1` of them. White noise reads `10·log10(4σ² · ENBW / N)` per bin (`Window.equivalentNoiseBandwidth`).
- **Impulse-response layout.** `ImpulseResponse.samples` is one period of a circular buffer. Index 0 is the instant the sweep's first sample was played, counted from the recording's first sample. Positive time runs up the first half, negative time wraps to the end, and the harmonics' responses land before the linear peak, possibly wrapped past index 0. Use `index(atTime:)` and `index(atOffset:)`, not hand-written modular arithmetic. Defined at `Response/ImpulseResponse.swift:6`.
- **The safe level.** `LogSweep.maximumAmplitude` (0.25, −12 dBFS) is the one definition of the loudest a test signal may be. `LogSweep` and `TestSignal.sine` both clamp to it. The playback volume is the user's.

## Public interface

### Foundation

| Symbol | Where | Holds |
|---|---|---|
| `Decibels` | `Foundation/Decibels.swift:4` | `floor` (:6), `fromAmplitude` (:8), `fromPower` (:13), `toAmplitude` (:18) |
| `ComplexSpectrum` | `Foundation/FFT.swift:4` | Split complex spectrum (`real`, `imaginary`, `init` :8, `count` :14); `magnitudes` (:17) includes the mirrored upper half |
| `FFT` | `Foundation/FFT.swift:24` | `nextPowerOfTwo` (:25), `forward(_:size:)` of a real signal, zero-padded (:33), `forward(_:)` of a complex sequence (:42), `inverse` (:47), `frequency(ofBin:size:sampleRate:)` (:51), `bin(nearest:size:sampleRate:)` (:55) |
| `LogSweep` | `Foundation/LogSweep.swift:7` | The exponential sine sweep every measurement plays. Fields `startFrequency`, `endFrequency`, `duration`, `sampleRate`, `amplitude`, `fadeDuration` (:12–20) and `init` (:22); `maximumAmplitude` (:10) |
| `LogSweep` members | `Foundation/LogSweep.swift:41` | `sampleCount` (:41), `logRatio` (:44), `frequency(at:)` (:47), `time(of:)` (:52), `harmonicAdvance(order:)` (:58), `samples()` (:62) |
| `MagnitudeResponse` | `Foundation/MagnitudeResponse.swift:5` | `frequencies`, `decibels` (:6, :7), `init` (:9), `count` (:15), `decibels(at:)` (:18), interpolated linearly in log frequency and held flat outside the range |

### Signals

| Symbol | Where | Holds |
|---|---|---|
| `TestSignal` | `Signals/TestSignal.swift:4` | Steady test signals |
| `TestSignal.sine(frequency:duration:sampleRate:amplitude:fadeDuration:)` | `Signals/TestSignal.swift:11` | A faded sine, clamped to `LogSweep.maximumAmplitude` |
| `TestSignal.silence(duration:sampleRate:)` | `Signals/TestSignal.swift:30` | Zeros |
| `Window` | `Signals/Window.swift:8` | Cases `rectangular` (:10), `hann` (:12), `hamming` (:14), `blackmanHarris` (:16); all periodic cosine sums |
| `Window` members | `Signals/Window.swift:29` | `samples(count:)` (:29), `coherentGain` (:45), `equivalentNoiseBandwidth` (:52), `apply(to:)` (:60) |

### Spectrum

| Symbol | Where | Holds |
|---|---|---|
| `SpectrumAnalyzer` | `Spectrum/SpectrumAnalyzer.swift:12` | Magnitude spectra, one normalisation for both |
| `SpectrumAnalyzer.spectrum(of:sampleRate:window:size:)` | `Spectrum/SpectrumAnalyzer.swift:16` | Spectrum of the whole signal, Hann by default |
| `SpectrumAnalyzer.averagedSpectrum(of:sampleRate:segmentSize:overlap:window:)` | `Spectrum/SpectrumAnalyzer.swift:35` | Welch's averaged spectrum; 4096-sample segments, 50 % overlap by default |
| `OctaveBands` | `Spectrum/OctaveBands.swift:7` | Fractional-octave bands with exact base-ten centres (IEC 61260-1); `octaveRatio` (:9), `referenceFrequency` (:12) |
| `OctaveBands.centres(fraction:from:to:)` | `Spectrum/OctaveBands.swift:17` | Centres of every band that overlaps the range |
| `OctaveBands.edges(ofCentre:fraction:)` | `Spectrum/OctaveBands.swift:36` | Lower and upper edge of one band |
| `OctaveBands.levels(of:fraction:from:to:window:)` | `Spectrum/OctaveBands.swift:49` | Power sum of a spectrum per band, with the window's noise bandwidth divided out |
| `Smoothing` | `Spectrum/Smoothing.swift:4` | `edgeTolerance` (:7) |
| `Smoothing.fractionalOctave(_:fraction:)` | `Spectrum/Smoothing.swift:16` | Power average over ±1/(2·fraction) octave; frequencies unchanged |
| `MagnitudeResponse.resampledLogarithmically(from:to:pointsPerOctave:)` | `Spectrum/MagnitudeResponse+Resampling.swift:10` | Resamples onto a log grid, ignoring points at or below 0 Hz |

### Response

| Symbol | Where | Holds |
|---|---|---|
| `Deconvolution` | `Response/Deconvolution.swift:23` | Regularised spectral division of a recording by its sweep; the four regularisation constants (:25–31) |
| `Deconvolution.impulseResponse(recording:sweep:)` | `Response/Deconvolution.swift:39` | The impulse response of the system between the sweep and the recording, band set to the sweep's range |
| `ImpulseResponse` | `Response/ImpulseResponse.swift:16` | Circular buffer (layout under Conventions); `samples` (:31), `sampleRate` (:33), `peakIndex` (:35), `band` (:38), `init` (:43), `count` (:53) |
| `ImpulseResponse.index(atTime:)`, `index(atOffset:)` | `Response/ImpulseResponse.swift:56`, `:61` | Buffer index of a time after time zero, or of an offset from the linear peak, wrapped |
| `ImpulseResponse.delay` | `Response/ImpulseResponse.swift:70` | Seconds from time zero to the linear peak, refined by a parabola; negative if the peak is in the wrapped half |
| `ImpulseResponse.frequencyResponse(preWindow:postWindow:)` | `Response/ImpulseResponse.swift:88` | Magnitude windowed around the peak, in dB re the sweep, on the transform's linear grid within `band` |
| `ResponseComparison` | `Response/ResponseComparison.swift:7` | Comparing two responses with unknown absolute levels; `defaultMatchBand` (:9), `pointsPerOctave` (:11) |
| `ResponseComparison.levelMatched(_:to:band:)` | `Response/ResponseComparison.swift:18` | Shifts a response so its median in the band equals the reference's |
| `ResponseComparison.difference(_:_:)` | `Response/ResponseComparison.swift:33` | `first − second` in dB on a log grid over the shared range |

### Distortion

| Symbol | Where | Holds |
|---|---|---|
| `SweepDistortion` | `Distortion/HarmonicDistortion.swift:7` | Result of a sweep analysis: `fundamental` (:10), `harmonics` by order (:16), `thd` (:22) |
| `SweepDistortion.thdPercent(at:)` | `Distortion/HarmonicDistortion.swift:26` | THD at a frequency as a percentage of the fundamental |
| `HarmonicDistortion` | `Distortion/HarmonicDistortion.swift:42` | Harmonic distortion against frequency, from one sweep (Farina's method); `defaultOrders` (:44), `preWindow` (:46), `topEdgeMargin` (:51) |
| `HarmonicDistortion.upperFrequency(order:sweep:)` | `Distortion/HarmonicDistortion.swift:56` | Highest fundamental at which an order is reported |
| `HarmonicDistortion.analyze(impulseResponse:sweep:orders:)` | `Distortion/HarmonicDistortion.swift:64` | Windows each harmonic's response out of the impulse response |
| `ToneDistortionResult` | `Distortion/ToneDistortion.swift:4` | `thdPercent` (:7), `thdPlusNoisePercent` (:10), `harmonicLevels` (:13), `nonHarmonicResidue` (:17) |
| `ToneDistortion` | `Distortion/ToneDistortion.swift:38` | Distortion of a recorded steady tone from one Blackman–Harris spectrum; `maximumOrder` (:40), `lobeHalfWidth` (:43) |
| `ToneDistortion.analyze(recording:frequency:sampleRate:)` | `Distortion/ToneDistortion.swift:45` | THD, THD+N, harmonic levels and the non-harmonic residue |

### Quality

| Symbol | Where | Holds |
|---|---|---|
| `QualityThresholds` | `Quality/QualityThresholds.swift:8` | Every number that decides whether a recording is fit to analyse, 14 fields (:16–80), `init` (:82) and `standard` (:116) |
| `Level` | `Quality/LevelMeter.swift:7` | `peak` (:9), `rms` (:11), `dcOffset` (:13), `init` (:15), `peakDecibels` (:22), `rmsDecibels` (:25), `crestFactorDecibels` (:29) |
| `LevelMeter.measure(_:)` | `Quality/LevelMeter.swift:38` | Peak, RMS and DC offset of a buffer (`LevelMeter` at :36) |
| `ClippingReport` | `Quality/ClippingDetector.swift:4` | `clippedSampleCount` (:6), `clippedFraction` (:8), `longestRun` (:10), `init` (:12), `isClipped` (:20) |
| `ClippingDetector.detect(_:thresholds:)` | `Quality/ClippingDetector.swift:34` | Finds runs at full scale and flat tops at the buffer's own extreme (`ClippingDetector` at :32) |
| `NoiseFloorReport` | `Quality/NoiseFloor.swift:4` | `rmsDecibels` (:7), `bandLevels` (:12), `fluctuationDecibels` (:15), `isSteady` (:20), `init` (:22) |
| `NoiseFloor.measure(_:sampleRate:thresholds:)` | `Quality/NoiseFloor.swift:37` | Measures a quiet recording: broadband RMS, octave bands 31.5 Hz to 16 kHz, steadiness (`NoiseFloor` at :31) |
| `SignalToNoise` | `Quality/SignalToNoise.swift:8` | `ratio(signal: Level, noise: Level)` (:10), `ratio(signal: [Float], noise: [Float])` (:15), `bandRatios(signal:noise:sampleRate:)` on buffers (:21), `bandRatios(signal:noise:)` on band levels (:30) |
| `NoiseGate` | `Quality/NoiseGate.swift:10` | The live pause and resume decision on one block: `isTooNoisy(block:baseline:thresholds:)` (:13), `isQuietEnough(block:baseline:thresholds:)` (:20) |
| `RecordingVerdict` | `Quality/RecordingQuality.swift:7` | Cases `valid` (:9), `clipped` (:11), `tooQuiet` (:13), `tooNoisy` (:16), `silent` (:18) |
| `RecordingQuality.assess(recording:noiseFloor:thresholds:)` | `Quality/RecordingQuality.swift:34` | The verdict: silent, then clipped, then too quiet, then too noisy; the first that fails decides (`RecordingQuality` at :22) |

## Thresholds and constants

Every public static constant, and the `standard` quality thresholds. A value marked "first guess" is called that in its doc comment and has to be tuned on a device.

| Constant | Where | Value | Note |
|---|---|---|---|
| `Decibels.floor` | `Foundation/Decibels.swift:6` | −160 dB | Stands in for silence |
| `LogSweep.maximumAmplitude` | `Foundation/LogSweep.swift:10` | 0.25 (−12 dBFS) | The safe level |
| `OctaveBands.octaveRatio` | `Spectrum/OctaveBands.swift:9` | 10^0.3 ≈ 1.9953 | |
| `OctaveBands.referenceFrequency` | `Spectrum/OctaveBands.swift:12` | 1000 Hz | |
| `Smoothing.edgeTolerance` | `Spectrum/Smoothing.swift:7` | 1e-5 | Fraction of the edge frequency |
| `Deconvolution.inBandRegularisation` | `Response/Deconvolution.swift:25` | 1e-6 (−60 dB) | Times the sweep's mean in-band power |
| `Deconvolution.outOfBandRegularisation` | `Response/Deconvolution.swift:27` | 1e4 (+40 dB) | Same reference |
| `Deconvolution.lowCutRatio` | `Response/Deconvolution.swift:29` | 0.5 | High-pass corner, as a fraction of the sweep's start |
| `Deconvolution.lowStopRatio` | `Response/Deconvolution.swift:31` | 0.25 | Below this fraction of the start the out-of-band ε applies |
| `ImpulseResponse.defaultPreWindow` | `Response/ImpulseResponse.swift:19` | 0.002 s | |
| `ImpulseResponse.defaultPostWindow` | `Response/ImpulseResponse.swift:24` | 0.1 s | Resolves down to about 10 Hz |
| `ImpulseResponse.postTaperFraction` | `Response/ImpulseResponse.swift:26` | 0.5 | |
| `ImpulseResponse.minimumTransformSize` | `Response/ImpulseResponse.swift:29` | 16384 | 2.9 Hz a point at 48 kHz |
| `ResponseComparison.defaultMatchBand` | `Response/ResponseComparison.swift:9` | 300…3000 Hz | |
| `ResponseComparison.pointsPerOctave` | `Response/ResponseComparison.swift:11` | 48 | |
| `HarmonicDistortion.defaultOrders` | `Distortion/HarmonicDistortion.swift:44` | `[2, 3, 4, 5]` | |
| `HarmonicDistortion.preWindow` | `Distortion/HarmonicDistortion.swift:46` | 0.005 s | Capped at half the gap to the next higher order |
| `HarmonicDistortion.topEdgeMargin` | `Distortion/HarmonicDistortion.swift:51` | 1/6 octave | Below the sweep's end; no harmonic is read above it |
| `ToneDistortion.maximumOrder` | `Distortion/ToneDistortion.swift:40` | 10 | |
| `ToneDistortion.lobeHalfWidth` | `Distortion/ToneDistortion.swift:43` | 5 resolution bins | Blackman–Harris main lobe is ±4, plus one |
| `QualityThresholds.standard.fullScaleLevel` | `Quality/QualityThresholds.swift:117` | 32767/32768 | Largest 16-bit sample |
| `.fullScaleRun` | `Quality/QualityThresholds.swift:118` | 2 samples | |
| `.flatTopRun` | `Quality/QualityThresholds.swift:119` | 8 samples | First guess |
| `.flatTopTolerance` | `Quality/QualityThresholds.swift:120` | 1e-5 | First guess |
| `.flatTopMinimumLevel` | `Quality/QualityThresholds.swift:121` | 0.1 (−20 dBFS) | First guess |
| `.silencePeakDecibels` | `Quality/QualityThresholds.swift:122` | −90 dBFS | One 16-bit step |
| `.minimumPeakDecibels` | `Quality/QualityThresholds.swift:123` | −40 dBFS | First guess |
| `.minimumSignalToNoiseDecibels` | `Quality/QualityThresholds.swift:124` | 20 dB | First guess |
| `.steadinessBlockDuration` | `Quality/QualityThresholds.swift:125` | 0.1 s | The block the live gate watches |
| `.maximumNoiseFluctuationDecibels` | `Quality/QualityThresholds.swift:126` | 6 dB | First guess |
| `.pauseMarginDecibels` | `Quality/QualityThresholds.swift:127` | 10 dB | First guess |
| `.resumeMarginDecibels` | `Quality/QualityThresholds.swift:128` | 6 dB | First guess |
| `.pauseCeilingDecibels` | `Quality/QualityThresholds.swift:129` | −30 dBFS | First guess, uncalibrated |
| `.resumeCeilingDecibels` | `Quality/QualityThresholds.swift:130` | −34 dBFS | First guess |

The sweep's own range, length and fade are not constants: the caller passes them to `LogSweep.init`, and the tests use 20 Hz to 20 kHz over 1 to 3 seconds with a 20 ms fade.

## Tests

`ResoniqKit/Tests/ResoniqDSPTests/`, run on the Mac by `make test`.

- `FoundationTests`: dB conversions, FFT round trip and padding, sweep length, safe-level clamp, silent ends and instantaneous frequency, log-frequency interpolation including a point at 0 Hz.
- `SignalsTests`: `TestSignal` length, safe level, fades and frequency; each `Window`'s mean, noise bandwidth (1, 1.5, 1.3628, 2.0044) and shape.
- `SpectrumTests`: spectrum bins and level for every window, zero padding, Welch averaging against the analytic noise level, third-octave and octave centres, band levels (a tone fills one band; noise rises 3 dB an octave), smoothing, log resampling.
- `ResponseTests`: deconvolving a recording identical to the sweep gives a unit impulse and a response flat to 0.05 dB from 40 Hz to 18 kHz; a delayed copy is found within 0.1 sample; a peaking filter is recovered within 0.1 dB; content above the sweep's range is not amplified; level matching and the log-grid difference.
- `DistortionTests`: a square law shows only the second harmonic at `a·A/2` (within 0.1 dB from 100 Hz) and THD within 0.1 % of 2.5 %; a cubic law shows the third at `b·A²/4` within 0.1 dB; harmonics stop where they leave the sweep; a clean system reads below 0.3 % THD (0.6 % at 5 kHz); `ToneDistortion` THD, THD+N, harmonics below Nyquist and the non-harmonic residue for lines and clicks.
- `QualityTests`: level, clipping (full scale, limiter flat tops, one sample is not clipping), noise floor bands and steadiness, signal-to-noise per band, the verdict order, and the gate's hysteresis.
- `EndToEndTests`: the phase's "Done when". A 3 s sweep from 20 Hz to 20 kHz through a simulated speaker (80 Hz high-pass, +6 dB bell at 2 kHz, about 2 % THD, white noise at −60 dBFS, 0.15 s late). It asserts that the delay is within 0.5 ms, the magnitude response within 0.25 dB from 50 Hz to 16 kHz after level matching (the plan's bar was 1 dB), and THD within a quarter of its value at 300, 500, 1000, 2000 and 3000 Hz. It prints the worst response error and the measured against expected THD at each frequency; the figures are not stored in the note, run `make test` to see them.
- `SimulatedSpeaker`: not a test; the biquads, seeded noise and polynomial nonlinearity the end-to-end and distortion tests share.

All of this is simulated. Nothing here has run on a microphone, and every first-guess threshold is untested against a real iPhone.

## Limits

What the doc comments say the module cannot tell you.

- **Deconvolution:** anything outside the sweep's range, the absolute sound pressure, or whether a feature belongs to the speaker, the room or the microphone. The recording must start no later than the sweep's playback.
- **`ImpulseResponse.delay`:** the arrival of the largest sample, not the first sound; the speaker's group delay is included.
- **`frequencyResponse`:** nothing below about `1 / postWindow` hertz is resolved, and reflections inside the window are part of the result. A reflection-free response needs a shorter window and gives up the bass.
- **`ResponseComparison.levelMatched`:** cannot tell a level difference from a broadband shape difference inside the match band.
- **`HarmonicDistortion`:** not the distortion of music (intermodulation); not which part of the chain distorted; not rattles. The floor of a clean system reads as a few tenths of a percent, never zero, and rises with frequency. Short sweeps resolve the higher orders coarsely. Within about an octave of the sweep's start the harmonic reads slightly high (0.6 dB at 50 Hz on a 2 s sweep from 20 Hz).
- **`ToneDistortion`:** the residue cannot tell a rattle in the speaker from one in the furniture, a buzz from mains hum, or a defect from a door or a voice. Steady hiss is subtracted, so a defect that only adds hiss is invisible. The recording must be longer than `2 · lobeHalfWidth / frequency` seconds and hold only the settled tone.
- **Levels:** dBFS only; the same room reads differently on two phone models. Below about 100 Hz an iPhone microphone rolls off, so a low band reading may be the microphone.
- **`ClippingDetector`:** cannot tell a limiter from a genuinely flat waveform; a few spikes above a limited stretch hide it; a soft limiter that rounds the crest is not caught. A clean sine below about 150 Hz within 0.0003 dB of full scale counts as clipped.
- **`NoiseFloor`:** steady is not quiet, since a loud fan is steady. Under 200 ms the floor cannot be shown steady.
- **`SignalToNoise`:** the figure is (signal + noise) over noise, so it is never below about 0 dB and is close to the true ratio only well above it. The broadband ratio can pass while one band is drowned; use `bandRatios`.
- **`RecordingQuality`:** judges the recording, not the speaker. `tooNoisy` never means the speaker is faulty.
- **`NoiseGate`:** cannot tell sweep from noise, and the ceilings only suit room-only blocks. Hysteresis and timing belong to the audio session.

## Open questions

- Sweep length and level that are safe for tweeters and still give enough signal-to-noise on an iPhone microphone. The level is capped at 0.25 here; the length is the caller's, and the tests use 1 to 3 seconds.
- Every value marked first guess above needs tuning on a device, in particular the live gate's margins and ceilings, which are uncalibrated and may mean different things on two phones.
- The broadband signal-to-noise minimum is dominated by low-frequency rumble. Should the verdict use a band-limited ratio?
- `flatTopRun` misses mild limiting of a high tone and `fullScaleLevel` misreads a clean low sine at full scale; a real recording may show which matters.
- Hysteresis, block counts and where to resume the sweep are left to the audio session ([ResoniqAudio](ResoniqAudio.md)).
