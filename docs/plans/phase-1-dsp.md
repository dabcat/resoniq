---
type: "plan"
phase: 1
status: "active"
tags:
  - "plan/phase-1"
---
# Phase 1 · DSP core

Goal: `ResoniqDSP` can make a test signal and turn a recording of it into a frequency response, a distortion
figure and a verdict on the recording's quality. No audio hardware, no UI. Every function is tested on the Mac
against a synthetic signal whose answer is known.

All functions take and return `[Float]` buffers plus a sample rate. Types are `Sendable` values. Nothing here
is isolated to an actor.

| # | Task | Files in `ResoniqKit/Sources/ResoniqDSP/` | Status |
|---|---|---|---|
| 1 | Foundation: decibel conversions, FFT and inverse FFT on power-of-two sizes, `MagnitudeResponse`, `LogSweep` (parameters, samples, safe level, fades) | `Foundation/` | done |
| 2 | Signals and spectrum: sine and silence, window functions, magnitude spectrum of a buffer (single and averaged), 1/3-octave band centres, fractional-octave smoothing, resampling a response to log-spaced points | `Signals/`, `Spectrum/` | done |
| 3 | Response: impulse response by deconvolving a recording with the sweep, start-of-response alignment, windowed frequency response from the impulse response, level-matched comparison of two responses | `Response/` | done |
| 4 | Distortion: harmonic impulse responses from a sweep recording (Farina), THD per frequency; THD and THD+N of a recorded steady tone; non-harmonic residue (rub and buzz measure) | `Distortion/` | done |
| 5 | Recording quality: peak and RMS level, clipping detection, noise floor from a quiet recording, signal-to-noise ratio, verdict (valid, clipped, too quiet, too noisy, silent) with thresholds defined once | `Quality/` | done |
| 6 | Module note with the public interface and `file:line`; research note with the chosen sweep length and level | `docs/modules/ResoniqDSP.md` | done |

Done when: `make test` passes; the end-to-end test plays a sweep through a simulated speaker (a known filter,
added noise, a known nonlinearity) and recovers the filter's response within 1 dB between 50 Hz and 16 kHz and
the nonlinearity's THD within a quarter of its value.

## Notes

**Review outcome.** A review of tasks 2 to 5 found thirteen defects, each reproduced by a test that failed
before its fix. All are fixed.

- Noise read as distortion: sweep THD now carries a noise floor measured with the same windows on a noise-only
  stretch of the response, and `isMeasurable(at:)` with a 10 dB margin.
- Recordings cut short, started late, empty, silent or corrupt: `ImpulseResponse.capturedBand` and `trustedBand`
  say what was recorded and what is reported, and nothing traps.
- Rumble under the sweep was amplified; it is now attenuated.
- A NaN sample read as silence; `RecordingVerdict.corrupt` now comes first.
- Tone analysis lost harmonics to a clock offset; it locates the tone first, and says when there is none.
- Two band tables and two level references are now one, dBFS RMS.
- Band edges were reported inaccurately; results now cover only trusted bands, and `LogSweep.measurement` sweeps
  wider than the reported band.
- The safety holes in the signal generators are closed, and the app's own 16-bit sweep no longer reads clipped.
- The result types have public initialisers.
- The duplicated helpers are merged, and the tautological tests are replaced.

The module note has the interface and an accuracy table.

**Accuracy now asserted** (simulated recordings):

- The frequency response is within 0.3 dB across `LogSweep.trustedBand`, and within 0.1 dB from three times the
  start.
- Harmonics and THD are within 3 % of their value across `HarmonicDistortion.trustedBand(order:sweep:)`, for sweeps
  of 3 s or longer.
- Tone THD holds to 0.01 percentage points with a 100 ppm clock offset.
- End to end: the response is within 0.25 dB and THD within a quarter.
- For the measurement sweep (10 Hz to 22 kHz, 4 s, −12 dBFS), the response is reported from 20 Hz to 20 kHz and
  the second harmonic from 80 Hz to 9.4 kHz.

**Sweep length and level.** These are now code (`LogSweep.measurement`) rather than a research note. The 10 Hz
start and the 4 s length are first choices to confirm on a device and with the owner; the open questions in the
module note give the reasons.

**Unverified until a device test.**

- Everything above was measured on synthetic recordings.
- Still to be learned from real recordings:
  - the iPhone microphone's own roll-off and distortion;
  - a real room's reverberation in the noise-floor stretch, where it reads as noise and errs towards "not
    measurable";
  - real clock offsets;
  - a real converter's clipping and limiting;
  - every first-guess threshold.
- Whether a 10 Hz sweep at the safe level is safe for vented speakers at high volume.
