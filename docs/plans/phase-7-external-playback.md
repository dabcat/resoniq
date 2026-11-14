---
type: "plan"
phase: 7
status: "done"
tags:
  - "plan/phase-7"
---
# Phase 7 · Playing the test sound from another device

Goal: a person whose sound system cannot take sound from the iPhone (a turntable amplifier, a CD player, a
streamer without Bluetooth or AirPlay) can still test a speaker and measure the seat. The test sound is a file
they play on their own system; the iPhone only listens. It is an option beside the normal way, never a
replacement: when the phone can play through the speakers, that way is better, because the app controls when the
sound starts and can pause for noise.

Why arbitrary music cannot be used: a measurement compares what was played with what was heard, so the app has to
know exactly what was played. With unknown music a missing bass note could be the song or the speaker.

## How it works

1. **Get the test sound.** The app writes the standard sweep to WAV files (48 kHz, the safe level, with the fades)
   and hands them over through the share sheet: AirDrop, Files, a USB stick. One file per use:
   - *Speaker test, left* / *right* / *both channels*: three runs of the sweep with silence between them.
   - *Seat*: the sweep on the left, then on the right (or both channels for a single speaker). It is played once
     at each of the three spots.
   Each file starts with 3 s of silence, so pressing play is not heard as part of the measurement, then a 3 s
   tone at 1 kHz that tells the app which file it is and how fast the player runs.
2. **Listen.** The person taps "I'm ready", the app measures the room's noise for a moment, then says "Press play
   now" and listens. It finds the sweeps in what it hears by itself: nothing has to be synchronised, and the delay
   of the route does not matter.
3. **Check.** Each run it finds is checked like any run (clipped, too quiet, too noisy, cut short). The app cannot
   pause someone else's player, so a run spoiled by noise is not spliced: the app keeps the good runs and asks for
   the file to be played again until it has three (one file per spot for the seat).
4. **Analyse.** The recordings go through the same analysis as a normal test. The result says it was measured
   from a file played on another device.

## What is different, and what the result must say

- **The player's clock is not the phone's.** A player running a little fast or slow stretches the sweep. The app
  estimates the stretch from the known spacing of the sweeps in the file and corrects for it; a stretch too large
  to correct makes the run invalid, with a reason.
- **Lossy formats change the sound.** The file is WAV. If it reaches the speakers through a lossy format or a
  sample-rate conversion, the top of the range and the distortion figures are less trustworthy; the app cannot
  see that, so the instructions say to play the WAV itself.
- **No pause for noise, no hold-to-hear.** The Finding screen's hold-to-hear needs the phone to play; in this
  mode it says so instead of failing.
- **Level.** The file is at the safe level; the volume is the person's, as always.

## Who decides what

| Decision | Module | Symbol (contract) |
|---|---|---|
| The files and where each sweep sits in them | `ResoniqAudio` | `TestSoundFile` (kinds, `write(to:)`, `TestSoundLayout` with the offset of every sweep and the channel it is on) |
| Finding the sweeps in a recording, and the player's clock | `ResoniqDSP` | `SweepFinder.find(in:sweep:expected:) -> [FoundSweep]` (position, strength, clock ratio), tolerant of delay, noise and a clock offset |
| The listening session for a speaker test | `ResoniqAudio` | `ExternalMeasurementSession` → the same `MeasurementResult` a normal test gives |
| The listening session for the seat | `ResoniqAudio` | `ExternalSeatMeasurementSession` → the same `SeatMeasurementResult` |
| What the report says about how it was measured | `ResoniqDiagnostics` | an optional source on the reports ("played from another device") and its sentence |

## Tasks

| # | Task | Module | Model | Status |
|---|---|---|---|---|
| 1 | `SweepFinder` with clock-ratio estimate and correction | DSP | Opus | done |
| 2 | `TestSoundFile`, `ExternalMeasurementSession`, `ExternalSeatMeasurementSession`, simulated external player for tests and the simulator | Audio | Opus | done |
| 3 | Source on the reports and its texts | Diagnostics | Opus | done |
| 4 | Screens: getting the files, listening (Diagnose and Measure), play it again, the option on Aim, on Sit and aim and on the "sound is coming from the iPhone" screen, Settings entry; wiring | App | Sonnet | done |
| 5 | Review, module notes, device checklist additions | — | Fable | done |

Done when: `make test` and `make build` pass; in the simulator, with a simulated external player (delay, clock
offset, noise), a speaker test and a seat measurement run from "I'm ready" to a kept result. Real players are
verified on a device by the owner.

## Notes

**What differs from the plan.**

- Each file carries a 1 kHz tone before the sweeps. The gap from the tone's end to the first sweep names the file, and the tone gives the player's clock; the spacing of the sweeps cross-checks both and overrules the tone when they disagree (a phone moving during the tone, a player that mutes its first half second).
- The files are 24-bit by default, with a 16-bit variant for players that need it. There is no 44.1 kHz file: the sweep runs to 22 kHz.
- A subwoofer alone is not supported in this mode.

**Review (Fable), nine findings, all fixed.** The finder failed at an ordinary listening seat, where reflections are stronger than the direct sound (now found down to a direct-to-reverberant ratio of −24 dB in synthetic rooms); a rattling speaker was refused as room noise (noise that returns at the same place of the sweep is now kept as the speaker's); a sweep stopped or paused part-way was kept (`SweepCompleteness`, and the three runs must agree within 6 dB); a muted start misnamed the file; the Room reading showed the test sound's own level; the clock had one source. In the app: the screen is kept awake in every measurement, a measurement stopped by the background says so, the microphone permission alert no longer cancels a flow, and comparisons say when the two measurements were taken differently.

**Not verified until a device test.** Everything with a real player: how much of the start it mutes, loudness normalisation in a music library, lossy copies, Bluetooth between player and amplifier, real seats against the synthetic rooms, and the first-guess constants (6 dB run agreement, the stop detector, 20 and 50 ppm clock limits). Steps in the [device checklist](../device-checklist.md), section 9.
