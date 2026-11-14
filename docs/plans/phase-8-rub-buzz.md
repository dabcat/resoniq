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

- The floor (after review) is made of four parts. (1) The noise-floor report's octave bands over the same band,
  spread evenly within each (`RunAnalyzer` does not receive the floor recording's samples). (2) The run's own tail:
  the last 0.1 s of the recording, from 0.1 s after the sweep's end has arrived, averaged over half-overlapping
  frames; the higher of (1) and (2) counts, and with fewer than two tail frames there is no floor and nothing is
  measured. The tail was chosen over the lead-in because the app always records it (0.205 s at least) and the
  lead-in is only the route's delay. (3) The profile: the floor is raised by `median excess + 6 − 10` dB when
  positive, so a reading must stand 6 dB further over its floor than the run's median frame (noise during the sweep
  only lifts every frame alike). (4) The locking: a frame whose band is not locked to the tone's cycle (once or twice
  per cycle, in both halves of the frame, under 0.3) counts as noise, all of it. (3) alone could not hold out a
  coloured noise whose excess falls with frequency; (4) is what held out the Geithain birdsong and impulse runs.
- Findings start at 80 Hz (`DiagnosisThresholds.highOrderLowerFrequency`), not 40: a healthy Geithain RL900A reads
  −41 dB at 50–80 Hz (its woofer's own nonlinearity: −44.6 dB at half the drive, where leakage or a linear room
  would stay put; locked 0.3) and at its noise from 80 Hz up. One threshold, −50 dB, holds from 80 Hz on these data;
  no frequency-dependent threshold is needed for them.
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

**Rising noise and real rooms (after review).**

| Case | Result |
|---|---|
| Steady noise starting after the floor, healthy speaker, 20/25/30/35 dB S/N, seeds 21–24 | below noise everywhere (−22.4 / −27.3 / −32.5 / −37.2 dB at 100 Hz, bound 10 dB over); no finding (it was "measured" at −22.4 before the fix) |
| Same noise in two of three runs, seeds 31, 32 | no finding |
| Simulated rub, THD 1 % | still "Possible rub or buzz at 80–120 Hz", 3 of 3, about −22 dB; locking 0.82 dry |
| Rub in a reverberant room, D/R +6 dB / −6 dB | measured (−24.6 dB, locking 0.61) / not counted (locking 0.19) |
| Noise during the sweep only | locking median 0.10, held out |
| Real tones sn-97 / sn-76 / sn-57 through `steadyTone` | unchanged: −62.3 / −59.4 / −40.3 |

Geithain RL900A sweeps (`data/geithain-sweeps/`, third party, not committed): the played sweep is `LogSweep` 50 Hz to
22 kHz, 4 s, from sample 24000 (correlation 0.998). Medians, dB re the tone, Kit / coordinator's script:

| Speaker, band | Level | Floor | Coordinator |
|---|---|---|---|
| 0, 50–80 Hz | −41 to −44 (max −34) | −45 to −49 | −39 (max −25 to −29), noise −46 to −51 |
| 0, 80–160 Hz | −53 to −55 | the same | −52 to −54, noise −53 to −55 |
| 0, 160 Hz–1.8 kHz | −57 to −59 | the same | −55 to −63, at the noise |
| 1, 50–80 / 80–160 / 160–1800 Hz | −50 to −51 / −43 to −45 / −50 to −53 | at the noise | not measured |
| 2 (third channel), 50–80 / 80–160 Hz | −9 / −11 | — | not measured |

Through `RunAnalyzer` and `SpeakerDiagnosis` (three runs of one speaker at one microphone, microphones 0 and 3), no
`highOrderDistortion` for speakers 0 and 1, clean, impulse or birdsong (before the locking, birdsong raised "Possible
rub or buzz at 100–350 Hz" in 3 of 3 runs, and an impulse "at 180–210 Hz" in 2 of 3: the dataset places the noise at
the same point every run). Other findings, unchanged rules: speaker 0 "Peak at 730 Hz–1.2 kHz" (3 of 3), at mic 3
"Dip at 4.3–20 kHz", at mic 0 "Very top notes dip", "Couldn't check the woofer" (the sweep starts at 50 Hz, so the
response is trusted from 100 Hz); speaker 1 "Peak at 350–490 Hz", "Dip at 130–190 Hz", with birdsong also
"Possible buzz at 640–900 Hz" (THD, 3 of 3) at mic 0; at mic 3 two or three of its runs are "too noisy" (19.4–19.9 dB
against the 20 dB gate). The third channel's unit raises seven THD buzzes (350 Hz–3.7 kHz) and a dip at 120–210 Hz:
THD 6–19 % measured, h2 −19 dB at 600 Hz, its high orders mostly not locked to the tone (0.24) and staying at the same
level against the tone when the drive halves. It is not a clean reference; whether it is faulty or something in that
channel's chain is, the data does not say.

**First guesses.** `frameDuration` 50 ms, `hopFraction` 1/4, `lowestFrequency` 40 Hz, `minimumBandOctaves` 1/6
(reading ends at about 1.7 kHz), `highOrderDecibels` −50 dB, `highOrderLowerFrequency` 80 Hz, `tailGuard` 0.1 s,
`tailFloorDuration` 0.1 s, `localMarginDecibels` 6 dB, `lockingThreshold` 0.3; the simulated rub (2–8 kHz bursts past
70 % of the excursion) is a model, not a measured rub.

**Not verified until a device test.** What a phone in a living room reads above the tenth harmonic for a healthy
speaker (whether the floor leaves room to measure −50 dB at all, and how often a rub is "not checked"); whether the
phone's own microphone distortion or AGC adds energy there at the app's level; the spread of real units around the
threshold; whether a real rub stays locked at the distance the app measures from (only the simulated rub and the one
real steady tone say it is periodic); whether a small speaker played loud distorts above 80 Hz as the RL900A does
below it. The Geithain data never goes under 50 Hz and its response is trusted from 100 Hz, so `RunAnalyzer` never
read its 50–80 Hz; the 80 Hz limit rests on the DSP reading those frames directly.
