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
| 1 | `HighOrderDistortion` with tests: simulated clean, rubbing and noisy speakers; agreement with `ToneDistortion` on a steady tone; the three real recordings where present | DSP | Opus | done |
| 2 | `RunMeasurement` fields, `RunAnalyzer`, the finding, threshold, words, verdict clause, golden files | Diagnostics | Opus | done |
| 3 | App: the new kind in the displays (Result, Finding, numbers sheet), no new screen | App | Sonnet | todo |
| 4 | Review; module notes; device checklist entry | — | Fable | todo |

Done when: `make test` and `make build` pass, a simulated rubbing speaker with low THD gets the finding and a
healthy one in noise does not. What a phone in a real room reads for a healthy speaker is not known and is verified
on a device.

## Notes (tasks 1 and 2)

**Method.** Short-time Hann spectra of the recording (50 ms frames every 12.5 ms), each centred where the aligned
sweep plays `f`; the tone's lobe gives the tone's power, everything from just above the tenth harmonic (as it moves
within the frame, plus the window's lobe) to the top of the trusted band gives the level. The floor is the
noise-floor report's octave bands over the same band, against the same tone power. `HighOrderDistortion.steadyTone`
is the same core on a steady tone.

**Measured (simulation and the three recordings).**

| Case | Level above the tenth harmonic, dB re the tone |
|---|---|
| Clean simulated speaker, −100 dBFS noise | under −80 (floor about −85) |
| Clean, no noise at all | −87 at 40 Hz, under −100 above 85 Hz (the tone's leakage) |
| Healthy speaker, the suite's quiet room (−60 dBFS white) | about −45 at 100 Hz, below its noise (bound −36) |
| Healthy speaker at the 20 dB gate | about −22 at 100 Hz, below its noise (bound −12) |
| Simulated rub at 60–150 Hz, THD 1 % | about −22 to −23, measured |
| Real tone, sn-97 (good) / sn-76 (borderline) / sn-57 (bad) | −62.3 / −59.4 / −40.3 |

The threshold, `DiagnosisThresholds.highOrderDecibels` = −50 dB, sits 9.4 dB above the borderline unit, 12.3 above
the good one and 9.7 dB below the bad one; a reading counts only where it is also 10 dB clear of its floor.

**What differs from the plan.**

- The floor is read from `NoiseFloorReport.bandLevels` (octave bands, spread evenly within each) rather than from the
  noise-floor recording's samples, which `RunAnalyzer` does not receive. A noise that rises during a run above the
  floor measured before it is not held out; the THD floor, read from the recording's own tail, does not have this
  gap.
- The analysis signature is `analyze(recording:sweep:delay:noise:measuredBand:minimumOrder:)`: the delay and the
  trusted band come from the impulse response `RunAnalyzer` already has.
- A level over the threshold that is below the noise raises nothing, not even an inconclusive finding: in the
  suite's quiet room every healthy speaker reads its noise above the threshold, and an "unclear" finding there would
  be on every report.
- The even statement gains a closing sentence about rub and buzz (ruled out over a named stretch, or not checked over
  the room's noise), so "Distortion stayed under 10 %" is never read as covering the high orders. Records stored
  without the levels say nothing, as before. Two exact-text tests changed for it.
- `Finding.Numbers.Unit` gains `toneDecibels` (dB re the tone, the threshold a level, not a magnitude); the app
  formats it signed. No golden file changed: the new fields are optional and nil is not encoded.
- The app (task 3) only gained the new cases where it switches, treated like a buzz; the numbers sheet explains the
  new unit in one line. The Finding screen's run traces draw the response for it, not the level.

**First guesses.** `frameDuration` 50 ms, `hopFraction` 1/4, `lowestFrequency` 40 Hz, `minimumBandOctaves` 1/6
(reading ends at about 1.7 kHz), `highOrderDecibels` −50 dB; the simulated rub (2–8 kHz bursts past 70 % of the
excursion) is a model, not a measured rub.

**Not verified until a device test.** What a phone in a living room reads above the tenth harmonic for a healthy
speaker (whether the floor leaves room to measure −50 dB at all, and how often a rub is "not checked"); whether the
phone's own microphone distortion or AGC adds energy there at the app's level; whether room noise during the runs
stays at the floor measured before them; the spread of real units around the threshold.
