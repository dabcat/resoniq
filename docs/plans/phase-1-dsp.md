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
| 2 | Signals and spectrum: sine and silence, window functions, magnitude spectrum of a buffer (single and averaged), 1/3-octave band centres, fractional-octave smoothing, resampling a response to log-spaced points | `Signals/`, `Spectrum/` | todo |
| 3 | Response: impulse response by deconvolving a recording with the sweep, start-of-response alignment, windowed frequency response from the impulse response, level-matched comparison of two responses | `Response/` | todo |
| 4 | Distortion: harmonic impulse responses from a sweep recording (Farina), THD per frequency; THD and THD+N of a recorded steady tone; non-harmonic residue (rub and buzz measure) | `Distortion/` | todo |
| 5 | Recording quality: peak and RMS level, clipping detection, noise floor from a quiet recording, signal-to-noise ratio, verdict (valid, clipped, too quiet, too noisy, silent) with thresholds defined once | `Quality/` | todo |
| 6 | Module note with the public interface and `file:line`; research note with the chosen sweep length and level | `docs/modules/ResoniqDSP.md` | todo |

Done when: `make test` passes; the end-to-end test plays a sweep through a simulated speaker (a known filter,
added noise, a known nonlinearity) and recovers the filter's response within 1 dB between 50 Hz and 16 kHz and
the nonlinearity's THD within a quarter of its value.
