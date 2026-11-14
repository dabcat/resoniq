---
type: "research"
tags:
  - "research"
  - "diagnose"
  - "false-alarms"
  - "thresholds"
  - "datasets"
---
# Healthy speakers in a real room: what the diagnosis says

**Asked:** how often the speaker diagnosis raises a suspected defect on loudspeakers that are healthy, measured in a
real room, and why. The product rule is that a false alarm on a healthy speaker is the worst outcome. This note
measures; it changes no rule or threshold. The proposals at the end are for the owner.

**Read this first.** These are measurement microphones, one loudspeaker model (Geithain RL900A) and one room, with
a third-party sweep that starts at 50 Hz. Nothing here says what an iPhone will read, at what distance, or in a
living room. Where a sentence says *inference*, it is reasoning from the figures, not a measurement.

## How it was checked

- **Data.** 2,160 sweep recordings of three RL900A monitors (sweep channels 0, 1, 2) in one room, seven
  microphones each, from `data/geithain-sweeps/` (third party, not committed; layout in `GeithainRuns` and
  `GeithainSweeps`). Per index the playlist gives the speaker, the sweep length (4, 8, 16, 32 or 64 s), an
  interfering noise (none, `impulse.wav`, `birds.wav`), the speaker playing it, when it starts and its level (1,
  0.5, 0.25). Even indices drive the sweep at a peak of 0.5, odd ones at 0.25 (read from the input files). The
  impulse's `noise_delay` counts from the start of the sweep: the noise detector fires within 0.3 s after it in
  3,216 of 3,360 impulse runs read that way, and in 58 read from the start of the file. Intervals 0, 1, 2 put the
  noise in the first, second and last third of the sweep; `reverbration` puts it at the sweep's end.
- **Runs and tests.** Every recording at every microphone went through the Kit's own `RunAnalyzer` (sweep
  `LogSweep` 50 Hz–22 kHz, 0.5 s lead-in, the floor the first steady second of that microphone's silence recording,
  as in `GeithainRuns.floor`): 15,120 runs. Three recordings of one speaker at one microphone under one condition
  are one three-run test for `SpeakerDiagnosis.diagnose`. Clean: consecutive triplets at one drive (8 per drive).
  With noise: one noise channel, level and drive, the noise in intervals 0, 1 and 2 (the app's three runs, each hit
  at a different point); and the three `reverbration` recordings of one channel and drive (the three levels).
  That is 48 tests per speaker, length and microphone: **3,360 tests of the two healthy speakers** (0 and 1) and
  1,680 of speaker 2. Each test was also diagnosed with the other healthy speaker's same test at the same
  microphone as its counterpart (speaker 0 ↔ 1), and under the candidate thresholds of question 5.
- **The session's parts** were run from the files where they are pure: `SweepNoiseDetector` block by block (0.1 s,
  floor the same steady second), and `SystemSoundClassifier` with `InterferenceAdvisor` on 36 recordings. Pausing,
  resuming, splicing, repeating a run, sweep-tied sound (`rattle`) and the phone's motion need the live session
  and were not run.
- **Code.** `GeithainSurveyTests` (ResoniqDiagnosticsTests) and `GeithainNoiseSurveyTests` (ResoniqAudioTests)
  write JSON lines to `ResoniqKit/.build/geithain-survey/`. They run only with `RESONIQ_GEITHAIN_SURVEY` set, so
  `make test` skips them; `RESONIQ_GEITHAIN_LENGTHS` and `RESONIQ_GEITHAIN_SPEAKERS` choose the sample (default 4 s,
  all three speakers). Optimised, the full sample took about 11 minutes on the Mac used:
  `RESONIQ_GEITHAIN_SURVEY=1 RESONIQ_GEITHAIN_LENGTHS=4,8,16,32,64 swift test --package-path ResoniqKit -c release -Xswiftc -enable-testing --filter "GeithainSurveyTests|GeithainNoiseSurveyTests"`.
  The tables were counted from those files with throwaway Python scripts (numpy), not committed.
- "Conclusive" means the report was not "I couldn't get clean enough recordings to judge this speaker." (fewer than
  two valid runs). A "flagged" test has at least one `Finding.isSuspectedDefect`.

## 1. False-alarm rate

Of 3,360 healthy tests, **2,125 were conclusive** (63 %); **1,475 of those (69.4 %) raised at least one suspected
defect**, which is 43.9 % of all tests. For the app's own length, 4 s, it is 301 of 410 conclusive tests (73.4 %).

| Kind of suspected defect | Conclusive tests with it (of 2,125) |
|---|---|
| Peak (`responsePeak`) | 1,426 (67.1 %) |
| Dip (`responseDip`) | 906 (42.6 %) |
| Buzz (`distortion`, THD) | 33 (1.6 %), all 4 s with birdsong (question 3) |
| Rub or buzz (`highOrderDistortion`) | 0 |
| Barely heard (`quietBand`) | 0 |
| Rattle | 0 (needs the session's sweep-tied sound; never set from files) |
| Left/right (`leftRightDifference`) | 0 alone; 272 (12.8 %) with the other speaker as counterpart |

Every conclusive test also said "Couldn't check the woofer" (2,125 of 2,125, inconclusive, not a defect: the sweep
starts at 50 Hz), and 1,162 "Very top notes dip" (inconclusive).

| Condition | Conclusive / all | Flagged / conclusive |
|---|---|---|
| Speaker 0 | 1,430 / 1,680 | 780 (54.5 %) |
| Speaker 1 | 695 / 1,680 | 695 (100 %) |
| Clean | 712 / 1,120 | 496 (69.7 %) |
| Impulse | 708 / 1,120 | 495 (69.9 %) |
| Birdsong | 705 / 1,120 | 484 (68.7 %) |
| Noise level 1 / 0.5 / 0.25 (noise in the sweep) | 350 / 356 / 355 of 560 each | 69.7 / 68.8 / 69.0 % |
| 4 s / 8 s / 16 s / 32 s / 64 s | 410 / 417 / 433 / 432 / 433 of 672 | 73.4 / 71.2 / 67.4 / 67.8 / 67.4 % |
| Drive 0.5 | 1,418 / 1,680 | 1,100 (77.6 %) |
| Drive 0.25 | 707 / 1,680 (speaker 0 only; speaker 1 never conclusive) | 375 (53.0 %) |
| Microphone 0 / 1 / 2 / 3 / 4 / 5 | 360 / 360 / 360 / 322 / 360 / 360 of 480 | 52.8 / 100 / 33.9 / 100 / 33.6 / 100 % |
| Microphone 6 | 3 / 480 | 0 of 3 |

The rate is set almost entirely by **which speaker and which microphone**, not by the noise or the sweep length.
Speaker 0 at microphones 2 and 4 is flagged in 2 and 1 of its 240 tests there (a buzz each time); at microphones 1, 3 and 5 in 100 %;
at microphone 0 in 21 % (drive 0.25) and 38 % (drive 0.5). Speaker 1 is flagged in every conclusive test at every
microphone.

The most frequent verdicts of the 3,360 healthy tests:

| Tests | Verdict |
|---|---|
| 1,235 | I couldn't get clean enough recordings to judge this speaker. |
| 431 | I found no fault, but the tweeter and mid aren't clearly even. I couldn't check the woofer. |
| 341 | Sounds healthy, except the middle driver may be too loud around 410 Hz and the woofer may be weak around 160 Hz. I couldn't check the woofer. |
| 302 | Sounds healthy, except the middle driver may be too loud around 900 Hz. I couldn't check the woofer, and the tweeter isn't clearly even, but I found no fault in it. |
| 219 | The tweeter sounds healthy; I couldn't check the woofer, and the mid isn't clearly even, but I found no fault in it. |
| 171 | … too loud around 910 Hz … (as the 302) |
| 126 | … 410 Hz … 160 Hz … and the tweeter isn't clearly even, but I found no fault in it. |
| 115 | … 410 Hz … weak around 150 Hz. I couldn't check the woofer. |
| 79, 55, 29, 9, 7, 3 | Sounds healthy, except the tweeter may be weak around 9.3 kHz and the middle driver may be too loud around 890–930 Hz. … |
| 77 | It's uneven in 3 places. From one spot I can't tell the speaker from the room. … |
| 44 | Sounds healthy, except the tweeter may be weak around 9.3 kHz. … |
| 20 | I found 3 (12) or 4 (8) things worth a closer look. … (every one with a buzz) |
| 13 | … the middle driver may be buzzing … |

**No conclusive healthy test was called "Sounds healthy." without an exception.** The best a healthy speaker got
was "I found no fault, but … aren't clearly even" (431 + 219 tests).

## 2. Peaks and dips: where, how large, room or speaker

Clusters of suspected dips and peaks over all 3,360 tests (findings within 1/3 octave of each other), with the
share of each microphone's conclusive tests that raised it. Microphone 6 is left out: it was conclusive 3 times.

| Speaker | Finding | Range (median) | Extreme, dB vs trend (median, range) | Microphones (of 6) where it is raised in ≥ half the tests | Share per microphone 0–5 |
|---|---|---|---|---|---|
| 0 | Peak | 766 Hz–1.06 kHz, deepest 946 Hz | +6.5 (+6.0 to +8.6) | 3 (any: 4) | 0.29 1.00 0.00 0.80 0.00 1.00 |
| 0 | Dip | 4.3–20 kHz, deepest 13.4 kHz | −11.0 (−11.5 to −10.7) | 1 (microphone 3 only) | 0 0 0 1.00 0 0 |
| 1 | Peak | 346–493 Hz, deepest 399 Hz | +7.8 (+7.4 to +8.1) | 6 | 1.00 at every microphone |
| 1 | Dip | 127–190 Hz, deepest 159 Hz | −7.1 (−8.1 to −6.0) | 6 | 1.00 0.87 1.00 1.00 1.00 1.00 |
| 1 | Peak | 701 Hz–1.09 kHz | +6.1 (+6.0 to +6.5) | 1 (microphone 3 only) | 0 0 0 0.81 0 0 |

The deviation itself (each run's response less its trend, the median over that microphone's valid clean 4 s runs),
at the clusters' frequencies:

| | 160 Hz | 420 Hz | 900 Hz | 9 kHz |
|---|---|---|---|---|
| Speaker 0, microphones 0–5 | +2.4 to +3.3 (sd 0.4) | +1.1 to +2.3 (sd 0.5) | **+5.2 to +8.4** (sd 1.1) | −0.5 to −7.0 (sd 2.3) |
| Speaker 1, microphones 0–5 | **−6.0 to −7.8** (sd 0.6) | **+7.4 to +8.0** (sd 0.2) | +2.4 to +5.5 (sd 1.0) | −1.3 to −5.8 (sd 1.8) |
| Speaker 2, microphones 0–5 | −7.9 to −9.1 | +0.8 to +3.5 | +0.5 to +2.4 | −1.5 to −12.0 |
| Speaker 0 less speaker 1, same microphone | +9.1 to +10.4 | −5.4 to −6.9 | +2.0 to +3.0 | −2.3 to +4.7 |

What it says:

- **Each speaker's peaks and dips stay at one frequency at every microphone.** Speaker 1's 400 Hz peak reads
  +7.4 to +8.0 dB at all six (sd 0.2 dB), its 160 Hz dip −6.0 to −7.8; speaker 0's 900 Hz peak +5.2 to +8.4. By the
  test the question set (a speaker's own feature stays put, a room feature moves or vanishes), these belong to the
  speaker and where it stands, not to the listening position. *Inference:* they cannot be told from the speaker's own
  placement (its distance to the wall and floor), which also stays the same at every microphone; and how far apart
  the microphones are is not in the data, so at 160 Hz (2 m wavelength) "the same at every microphone" is weak
  evidence. Nothing says either unit is faulty: they are the healthy references.
- **Whether a test is flagged is whether a feature of 5–8 dB crosses 6 dB.** Speaker 0's 900 Hz peak is there at
  every microphone, +5.2 to +8.4 dB; it is raised where it reaches 6 (microphones 1, 3, 5, partly 0) and not where it
  stays at 5.2–5.4 (2 and 4). The finding appears and vanishes across positions not because the feature moves but
  because it sits on the threshold.
- **The top-band dip is the microphone, not the speaker.** Speaker 0's dip at 4.3–20 kHz (−11 dB, deepest at
  13.4 kHz, just under the 14 kHz top-end limit, so a suspected dip, not "Very top notes dip") is at microphone 3
  only, and microphone 3 reads the top low for all three speakers (−7.0, −5.8 and −12.0 dB at 9 kHz).
- **The two speakers at the same microphone differ** by 9–10 dB at 160 Hz and 5–7 dB at 420 Hz at every
  microphone, which is why the left/right rule raises "Unlike the other speaker at 150–190 Hz" (32 tests). They
  share about +2.4 to +5.5 dB at 900 Hz (*inference*: the model's own response or the room; the same model makes the
  two indistinguishable).

**The shared-deviation rule**, with speaker 1 as speaker 0's counterpart at the same microphone and the other way
round (the 2,125 conclusive tests): suspected dips and peaks fell from 2,409 to 1,575; **834 were marked shared**
and cleared; flagged tests fell from 1,475 (69.4 %) to 1,236 (58.2 %). It added 272 left/right findings: 239
"Unlike the other speaker at 4.5–8.9 kHz" and 32 "at 150–190 Hz". Speaker 0's drive-0.25 tests gain nothing, as
speaker 1's are never conclusive. **Most of what it cleared is not the same feature:** of the 741 shared findings
that could be matched to the counterpart's own finding, 631 were matched to one whose centre is more than 2/3 octave
away. Speaker 1's 400 Hz peak (346–493 Hz) counts as shared with speaker 0's 900 Hz peak (766 Hz–1.06 kHz) because
`isShared` widens both ranges by `samePlaceOctaves` before testing overlap (`FrequencyRange.overlaps`), so ranges
up to 2/3 octave apart overlap. Only 110 (15 %) were within 1/3 octave.

## 3. "Possible buzz" with birdsong

44 `distortion` findings in 33 tests, **all in 4 s tests with birdsong in intervals 0, 1 and 2**; none clean, none
with the impulse, none in the `reverbration` triplets, none at 8 s or longer. Ranges 475 Hz–1.7 kHz, THD extremes
about 20–340 %, every one in 2 of 3 runs.

THD at 640–900 Hz, 4 s, drive 0.5, the largest value in the band per run (median and range over the runs):

| Speaker, microphone | Clean | Impulse | Birdsong |
|---|---|---|---|
| 1, mic 0 | 3.0 % (2.4–3.6), 22 of 22 measured | 3.1 % (2.6–3.7) | 12.1 % (2.6–198); 11 of 22 runs measured ≥ 10 % |
| 1, mic 1 | 3.4 % (3.0–3.8) | 3.4 % | 15.4 % (3.3–391) |
| 0, mic 0 | 1.7 % (1.6–1.8), 24 of 24 measured | 1.7 % (1.5–4.1) | 2.5 % (1.5–49); 7 of 24 ≥ 10 % |

Speaker 1, microphone 0, every birdsong run at drive 0.5 (noise channel 0; channel 2 reads the same way):

| Birdsong in | Level 0.25 | Level 0.5 | Level 1 | `DistortionReading` |
|---|---|---|---|---|
| First third (interval 0) | 49.7 % at 689 Hz | 99.7 % | 198 % | measured; floor 0.2–0.3 % |
| Second third (interval 1) | 21.3 % at 819 Hz | 42.4 % | 85.7 % | measured; floor 0.3–0.5 % |
| Last third (interval 2) | 2.6 % | 3.5 % | 3.6 % | below noise; floor 24, 48, 99 % |
| After the sweep | 2.7 % | 3.0 % | 3.0 % | below noise; floor 12, 24, 48 % |

**The buzz is the birdsong, not the speaker.** THD doubles each time the birdsong's level doubles, it is 3 % with no
birdsong or with the birdsong outside the sweep's 640–900 Hz stretch, and it is the same unit that reads 3 % clean.
It is called *measured* because the THD floor is read from the run's tail (`HarmonicDistortion`'s noise windows and
the recording's last 0.1 s): when the birds sing only during the sweep, the tail is quiet, the floor reads 0.3 %,
and the birdsong in the harmonics' windows passes for distortion 10 dB clear of it. When the birds are still singing
in the tail (interval 2, after), the floor rises with them and the reading is correctly "below noise". Over 8 s and
longer the same birdsong never raised a buzz (the longer sweep puts more energy at each frequency). The high-order
measure was not fooled: its locking test held the birdsong out (0 `highOrderDistortion` findings for speakers 0
and 1).

## 4. The recording gate, the noise detector, the classifier

**Recording checks** (15,120 runs: every recording at every microphone). Nothing was clipped, too quiet, silent,
corrupt or incomplete; every rejection was "too noisy", at 1.2–20.0 dB broadband signal-to-noise.

| | Valid | Too noisy |
|---|---|---|
| Speaker 0 (5,040 runs) | 4,249 (84 %) | 791 |
| Speaker 1 (5,040) | 2,055 (41 %) | 2,985 |
| Speaker 2 (5,040) | 3,261 (65 %) | 1,779 |

- **Microphone 6** is too noisy almost always (its floor −46 to −47 dBFS against −55 to −61 for the others; speaker
  0 at 13.1 dB median signal-to-noise at 4 s). **Speaker 1 at drive 0.25** is too noisy at every microphone and
  every length (about 15–16 dB). Speaker 0 sits at 22.7–24.5 dB (median) at microphones 0–5 at 4 s, speaker 1 at 16.6–19.2:
  the room is close to the 20 dB gate for these levels.
- **The interfering noise hardly moves the gate.** Median signal-to-noise, speaker 0, 4 s, drive 0.5: clean 26.7 dB,
  impulse 26.5–27.2, birdsong 25.9–27.1 (by level); speaker 1: 21.1, 21.0–21.5, 20.8–21.5. The ratio is broadband
  RMS over the whole recording against the floor, so a birdsong over part of the sweep passes. Runs rejected with
  noise are rejected for the same reason as without it.

**The noise detector** (`SweepNoiseDetector`, what pauses a run), block by block over the sweep:

| | Runs with a too-noisy block after the first 0.5 s |
|---|---|
| Birdsong during the sweep, speakers 0 and 1 | 2,519 of 2,520 |
| Birdsong after the sweep | 767 of 840; noisy in the tail 728 |
| Impulse during the sweep, level 1 / 0.5 / 0.25 | 832 / 812 / 717 of 840 |
| Clean, speaker 0 | 581 of 1,680: 0 of 336 at 4 s, 80 at 8 s, 162–173 at 16–64 s |
| Clean, speaker 1 | 21 of 1,680 |
| Clean, speaker 2 | 1,662 of 1,680 (sweep at 310 Hz–13 kHz, rise median 34 dB) |

So the live session would almost certainly have **paused** for the birdsong and the impulse, which these files
cannot show (the recordings were made without pausing). It would also pause speaker 0 when clean: the blocks are at
0.5–0.6 s, the sweep at 61–69 Hz, a rise of 10–12 dB over the floor: *inference*, the woofer's own distortion at
50–80 Hz that phase 8 measured (−41 dB re the tone), which the detector takes as room noise above 100 Hz. In 47 % of
speaker 0's runs a block in the first 0.5 s (sweep at about 52 Hz) is noisy as well. Speaker 2 would pause on
nearly every run, as the detector's doc comment says a speaker that distorts off its harmonics can.

**The classifier** (`SystemSoundClassifier`, `InterferenceAdvisor`; 36 recordings at microphone 0, 4 s, drive 0.5):

| Recording | As the app calls it on a noisy run (`sweepPlaying`) | Same labels read as `sweepSilent` | The 2 s after the sweep alone |
|---|---|---|---|
| Clean (4) | nothing | "music" 0.76–0.86 (the sweep) | nothing |
| Impulse (16) | "doorOrFootsteps" 0.57–0.94 in 4 (label `knock`), nothing in 12 | "music" in all 16 | nothing |
| Birdsong in the sweep (8) | nothing | "animal" 0.63–0.72 in 4 (level 1, intervals 0 and 1), "music" in 4 | nothing |
| Birdsong at the end or after (8) | nothing | "music" | "animal" 0.58–0.88 in all 8 |

With the sweep playing the birdsong is never named: animals are among the kinds the sweep passes for, and the clean
recordings (the bare sweep) score `bird_chirp_tweet` 0.47–0.61 and `bird_vocalization` up to 0.62. The app calls
the classifier only for a run that paused or failed for noise; through the gate, runs with the impulse or birdsong
failed no more often than clean ones. **Nothing the Kit does
without the session flagged the impulse or the birdsong**: no run was rejected for it, no finding names it, and the
one finding it caused (question 3) blames the speaker.

## 5. Thresholds in context

The largest suspected peak or dip per flagged conclusive healthy test (standard rules):

| | Tests | 10th / 50th / 90th percentile / max | Width, octaves (median, 90th) |
|---|---|---|---|
| Peaks | 1,426 | 6.4 / 7.5 / 8.0 / **8.6 dB** | 0.49, 0.63 |
| Dips | 906 | 6.1 / 7.6 / 11.0 / 11.5 dB | 0.58, 2.21 |

Dips fall into two groups: 6–8.9 dB (679 tests) and 10–11.5 dB (227 tests, every one speaker 0's 4.3–20 kHz dip at
microphone 3, over 2 octaves wide). Every peak is under 9 dB. Taken per test without the width condition (the median
over the runs of each run's largest deviation, 50 Hz–14 kHz, 2,125 tests), 68 % reach a 6 dB peak, 41 % 7 dB, 9 %
8 dB, none 9 dB.

Candidates, as analysis (the same diagnosis with `DiagnosisThresholds` changed): healthy conclusive tests still
raising a suspected dip or peak (of 2,125), and of 112 simulated bells (`Bench.healthy` plus one peaking filter at
150 Hz, 400 Hz, 1 kHz or 3 kHz, Q 1, 2 or 4, ±7, 8, 9, 10 dB and −12 dB, one seed each; the twelve +12 dB bells
clipped and are left out) how many are no longer found as a dip or peak at their frequency. The four simulated
defects of the existing suites (`ResponseTests`, `LeftRightTests`, `UnheardBandTests`: dip at 1 kHz Q 1 −9 dB, peak
at 3 kHz Q 1 +9 dB, dip at 2 kHz Q 1 −9 dB, dip at 70 Hz Q 3 −9 dB) are listed apart.

| Rule | Healthy tests flagged | Bells missed (of 112) | Of the 24 ±9 dB bells | Suite's four defects |
|---|---|---|---|---|
| Standard (6 dB, 1/3 octave) | 1,471 (69.2 %) | 17 | 1 | all found |
| 7 dB | 954 (44.9 %) | 47 | 6 | all found |
| 8 dB | 327 (15.4 %) | 75 | 17 | only the 3 kHz peak |
| 9 dB | 227 (10.7 %) | 99 | 24 | none |
| 10 dB | 227 (10.7 %) | 106 | 24 | none |
| 12 dB | 0 | 112 | 24 | none |
| Width 1/2 octave | 936 (44.0 %) | 22 | 2 | all found |
| Width 2/3 octave | 227 (10.7 %) | 45 | 9 | misses the 70 Hz Q 3 dip |
| Width 1 octave | 227 (10.7 %) | 71 | 17 | misses the 70 Hz Q 3 dip |
| 8 dB and 1/2 octave | 321 (15.1 %) | 75 | 17 | only the 3 kHz peak |
| Agreement at ≥ 4 / 5 / all microphones of the same test (any suspected defect) | 950 (44.7 %) / 709 (33.4 %) / 33 (1.6 %) | not testable on one simulated position | | |

The 227 tests left at 9 dB, 10 dB, 2/3 octave and 1 octave are all the microphone-3 top-band dip.

- **No deviation threshold separates these healthy speakers from the simulated defects.** A healthy peak reaches
  8.6 dB; a simulated −9 dB bell at Q 1 reads −7.6 to −7.8 dB after the 1/3-octave smoothing and the trend, a +9 dB
  one +7.7 to +8.2, and both are lost at 8 dB. Raising the threshold to clear the healthy speakers loses most real 9 dB deviations.
- **A wider minimum width separates them better.** 2/3 octave clears every healthy peak and every dip except the
  microphone-3 top band, and still finds every ±9 and ±10 dB bell at Q 1 and Q 2 that the standard rule finds; it loses the narrow ones (Q 4, and
  the suite's 70 Hz Q 3 dip), 45 of 112 in all.
- **Agreement across positions** clears what sits on the threshold at some positions (speaker 0's 900 Hz), not what
  is there at every position (speaker 1's 400 Hz peak and 160 Hz dip). The app measures from one position.

## 6. Speaker 2 (the third channel)

Its 1,680 tests: 1,085 conclusive, **all 1,085 flagged**: a dip at 119–208 Hz (−9.9 dB, every microphone), and at
4 s "Possible buzz" in every conclusive test (144 of 144), at 8 s in 16 of 152, at 16 s and longer in none; 77
`highOrderDistortion` findings, all at 32 s. At 4 s it reads like this (drive 0.5, microphone 0): "I found 8 things
worth a closer look.", buzzes at 350–400 Hz, 580–840 Hz, 1.1–1.4 kHz, 1.7–2 kHz, 2.2–2.5 kHz, 2.7–3.1 kHz and
3.3–3.7 kHz (15–79 %), and the dip. Microphones 0–5 read alike; at drive 0.25 every test was too noisy.

Harmonics against the fundamental (smoothed 1/12 octave), 4 s, clean, median over 3 recordings × 7 microphones:

| | 400 Hz | 600 Hz | 800 Hz | 1 kHz | 2 kHz | 3 kHz |
|---|---|---|---|---|---|---|
| Speaker 2, drive 0.5: h2 / h3 / h4 / h5, dB | −22.8 / −20.6 / −23.5 / −26.2 | −21.9 / −28.6 / −30.6 / −29.9 | −18.3 / −21.3 / −24.4 / −24.6 | −31.2 / −27.5 / −29.3 / −35.5 | −21.8 / −33.3 / −34.0 / −37.4 | −25.8 / −31.0 / −33.6 / −36.4 |
| Speaker 2, drive 0.25: h2, dB | −23.1 | −21.5 | −17.4 | −29.9 | −22.2 | −24.8 |
| Speaker 2 THD, drive 0.5 / 0.25 | 26.6 / 25.9 % | 11.6 / 12.0 % | 38.0 / 34.9 % | 6.7 / 6.7 % | 10.4 / 9.7 % | 10.6 / 10.9 % |
| Speaker 0 THD, drive 0.5 / 0.25 | 0.76 / 0.50 % | 0.73 / 0.62 % | 0.94 / 0.86 % | 0.51 / 0.60 % | 0.35 / 0.52 % | 0.37 / 0.59 % |
| Speaker 1 THD, drive 0.5 | 0.47 % | 0.74 % | 0.61 % | 0.51 % | 1.04 % | 0.80 % |

Speaker 2's THD at microphone 0, drive 0.5, by sweep length: at 400 Hz 33.9 / 11.6 / 4.1 % at 4 / 8 / 16 s; at
800 Hz 32.7 / 18.3 / 7.3 %. At 400 Hz across microphones 0–6: 16–34 %. Above the tenth harmonic it reads −12 dB re
the tone at 80–160 Hz and −17 dB at 160–400 Hz, but only 6–7 % of those points count as measured (the rest fail the
locking test, as phase 8 found: median locking 0.24). The noise detector calls 99 % of its clean runs too noisy.

What can be concluded: speaker 2 as recorded is not a clean reference, and the diagnosis reads it as distorting,
which is the right direction. What cannot: whether the unit or its channel is at fault. The data has no swap (the
unit on another channel, another unit on channel 2), and the channel-2 input file is the clean sweep (correlation
0.998, phase 8). *Inference:* what it reads does not behave like a driver's distortion. It stays the same against the
fundamental when the drive halves (h2 at 800 Hz −18.3 and −17.4 dB), where a driver's distortion falls; it falls by
about 9 dB in THD per doubling of the sweep's length, where a true harmonic's level against the tone does not depend
on the length; and it is mostly not locked to the tone. That is how energy proportional to the signal but not
coherent with the sweep behaves, for example a time-varying or noisy electrical chain, more than a mechanical rub
or buzz. Its response (a 150 Hz dip like speaker 1's, otherwise within a few dB of the others) shows no damaged
driver. None of this is a measurement of the cause.

## What it tells us

- **On these healthy monitors the diagnosis raises a suspected defect in 69 % of conclusive tests** (73 % at 4 s),
  and never says "Sounds healthy." without an exception. Almost all of it is peaks and dips of 6–8.6 dB that the
  same unit shows at every microphone. The room's noise, the impulse and the birdsong change the rate by less than
  2 points.
- **The 6 dB deviation threshold sits inside the spread of a healthy speaker's own response** here. Whether a
  test is flagged depends on whether a 5–8 dB feature crosses 6 dB at that position.
- **The shared-deviation rule clears features that are not the same**: with the tolerance applied to both ranges,
  two peaks an octave apart count as one. It cut flagged tests from 69 % to 58 % here, mostly for that reason.
- **THD's floor from the tail can call noise that stopped before the tail a buzz**: birdsong during a 4 s sweep was
  "measured" THD of 20–340 % and a "Possible buzz", 44 times. The high-order measure's locking test did not fall
  for it.
- **The gate does not see interfering noise**: broadband signal-to-noise over the whole recording barely moved with
  the impulse or birdsong. The noise detector does see both, and also sees a healthy woofer's distortion below
  80 Hz as noise in about a third of speaker 0's clean runs at 8 s and longer.

## Open questions

- What a phone at the app's distance reads for a healthy speaker in a living room: whether the 900 Hz and 400 Hz
  kinds of feature (5–8 dB) are typical, and whether the shared-deviation rule then helps.
- Whether the features that stay put across microphones are the RL900A's own response or its placement; the room's
  geometry and the microphones' positions are not in the data.
- Whether the noise detector's pause on speaker 0's 50–80 Hz distortion happens in the live session (its
  `shouldPause` and noise-guard logic were not run) and with the app's sweep from 10 Hz.
- Whether the THD floor's blind spot also appears with a phone's own floor and with real interruptions (a voice, a
  door) rather than the dataset's mixed-in birdsong.

## Not verified

- Nothing here was run on a phone, or with the app's own sweep (10 Hz–22 kHz) or its own levels; the woofer was
  never judged (every test "Couldn't check the woofer").
- The live session: pausing, resuming and splicing, repeating a bad run, sweep-tied sound and rattles, the phone's
  motion. The detector was run alone on the files and its "would pause" is an approximation of the session.
- The noise floor is one steady second of each microphone's silence recording (`SILENCE_0` for indices past 931),
  not a floor measured just before each run.
- The candidate rules were run only as analysis, on one seed per simulated bell, and on simulated speakers only for
  the cost; position agreement could not be costed.
- Speaker 2's cause: no swap of unit and channel exists in the data.
- One loudspeaker model, three units, one room, seven measurement microphones of unknown layout.

## Proposals for the owner (not implemented)

1. **Tighten "shared" to the same place.** Apply `samePlaceOctaves` once (or compare centres within 1/3 octave)
   in `SpeakerDiagnosis.isShared`. *Evidence:* 631 of 741 matched shared clearings here paired features more than
   2/3 octave apart (speaker 1's 400 Hz peak with speaker 0's 900 Hz peak). *Cost:* fewer healthy findings cleared
   (here about 85 % of the 834), so a higher false-alarm rate on paper, but no deviation would be cleared by a
   different one; the [first phone test](2026-11-14-first-device-speaker-tests.md)'s same-place peaks would still be
   shared.
2. **A minimum width of 2/3 octave for dips and peaks** (`minimumDeviationOctaves`). *Evidence:* healthy flagged
   tests with a dip or peak 1,471 → 227 (69 % → 11 %); 90 % of the healthy peaks here are under 0.63 octave wide (median 0.49). *Cost:* 45 of
   112 simulated bells missed instead of 17, mostly narrow ones (Q 4, and the suite's 70 Hz Q 3 dip); a narrow real
   defect would go unreported. A milder 1/2 octave costs 22 misses but clears only to 44 %.
3. **Treat a dip that runs into the top of the span as the top-end dip**, as a dip running into the bottom is the
   bass roll-off (the region's `touchesUpper`), whatever its deepest point. *Evidence:* the remaining 227 tests at
   2/3 octave are all speaker 0's 4.3–20 kHz dip at one microphone, deepest at 13.4 kHz, which "could be the phone's
   angle" describes. *Cost:* a tweeter that fails from 4 kHz up would be "inconclusive" rather than a dip; one that
   is dead is still "barely heard" (`quietBand`).
4. **Do not count THD as measured when the run's tail is quieter than the sweep's own residual.** For example,
   compare the noise in the harmonics' windows away from the harmonics' arrival with the tail floor, or require
   locking for THD too. *Evidence:* 44 "Possible buzz" findings from birdsong that stopped before the tail, THD
   doubling with the birdsong's level. *Cost:* not measured; a real buzz, which is locked and present at every
   level, should be unaffected, but that needs a test with the suite's buzzing speaker.
5. **Keep 6 dB as the deviation threshold** until a phone's healthy spread is known. *Evidence:* no threshold
   between 7 and 12 dB clears these healthy speakers without losing most simulated 9 dB defects (8 dB: 15 % flagged,
   17 of 24 ±9 dB bells lost).
6. **Let a healthy woofer's distortion below 100 Hz not pause a run**, or note it: the detector called speaker 0's
   50–80 Hz bass noise in 35 % of its clean runs. *Cost:* noise at the very bottom of the sweep would be watched less;
   only a live session can say whether it pauses at all.
