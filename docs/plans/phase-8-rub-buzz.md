---
type: "plan"
phase: 8
status: "in progress"
tags:
  - "plan/phase-8"
---
# Phase 8 · Rub and buzz from the high orders

Goal: the diagnosis notices a driver that rubs or buzzes even when its THD is low. Today a buzz is claimed only
from THD over orders 2 to 5 crossing 10 %; a real unit with strong rub and buzz reads 4.2 % and would be called
clean ([research](../research/2026-11-14-rub-buzz-recordings.md)). What gives it away is the energy above the tenth
harmonic, about 18 dB over a good unit.

## How it is measured

1. **From the sweep the app already plays**, no new signal. The sweep's frequency at every moment is known once the
   recording is aligned, so for each moment the power above `order × f(t)` is read against the power of the tone
   itself. The sweep rises, so the room's tail of what was already played lies below `f(t)`, not above it: the band
   above the tenth harmonic holds only what the speaker adds, and the room's noise.
2. **The noise floor decides what is a measurement**, as it does for THD: the same band read from the noise-floor
   recording gives the level noise alone would read, and a reading counts only when it stands clear of that by the
   DSP's margin. Below it the reading is "below noise", never a finding.
3. **Only where it can be read**: `order × f` must stay under the top of the measured band, so with order 10 the
   measure covers tones up to about 2 kHz, which is where excursion is large and rub and buzz lives.
4. **A steady tone is the reference case.** `ToneDistortion.nonHarmonicResidue` on the three real recordings is the
   check that the sweep measure and the tone measure agree on a simulated speaker.

## Who decides what

| Decision | Module | Symbol (contract) |
|---|---|---|
| Energy above the high orders along a sweep | `ResoniqDSP` | `HighOrderDistortion.analyze(recording:sweep:noise:…)`: per grid frequency, the level above `minimumOrder × f` relative to the fundamental (dB), the same read from the noise, and whether it is a measurement |
| One run's reading | `ResoniqDiagnostics` | `RunMeasurement` gains optional high-order arrays (optional so stored reports decode); `RunAnalyzer` fills them |
| The finding | `ResoniqDiagnostics` | `Finding.Kind.highOrderDistortion`: `inferred`, basis the runs that agree, hedged words ("Possible rub or buzz at 60–120 Hz"), never a confirmed defect; a deviation, so the verdict names it |
| The threshold | `ResoniqDiagnostics` | `DiagnosisThresholds.highOrderDecibels`, one definition, a first guess set from the three recordings (good −62 dB, borderline −58 dB, bad −40 dB) |
| The numbers behind it | `ResoniqDiagnostics` | `Finding.Numbers` in decibels relative to the tone, per run |

Rules the finding must follow:

- Same place in at least `minimumAgreeingRuns` valid runs, like every deviation; in one run it is dropped.
- Where a measured THD buzz or a possible rattle already covers the place, it is that finding's further evidence,
  not a second finding.
- It blocks the even statement for the drivers it reaches, and the even statement never claims the high orders
  were clean where they could not be read.
- A healthy simulated speaker in a noisy simulated room raises nothing: the worst failure is a false alarm.

## Tasks

| # | Task | Module | Model | Status |
|---|---|---|---|---|
| 1 | `HighOrderDistortion` with tests: simulated clean, rubbing and noisy speakers; agreement with `ToneDistortion` on a steady tone; the three real recordings where present | DSP | Opus | todo |
| 2 | `RunMeasurement` fields, `RunAnalyzer`, the finding, threshold, words, verdict clause, golden files | Diagnostics | Opus | todo |
| 3 | App: the new kind in the displays (Result, Finding, numbers sheet), no new screen | App | Sonnet | todo |
| 4 | Review; module notes; device checklist entry | — | Fable | todo |

Done when: `make test` and `make build` pass, a simulated rubbing speaker with low THD gets the finding and a
healthy one in noise does not. What a phone in a real room reads for a healthy speaker is not known and is verified
on a device.
