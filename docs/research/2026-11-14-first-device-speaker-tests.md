---
type: "research"
tags:
  - "research"
  - "device"
  - "diagnose"
---
# First speaker tests on an iPhone

**Asked:** what the first two real speaker tests say about the app, read from the store copied off the phone
(`xcrun devicectl device copy from … --domain-type appDataContainer`, the `ZSPEAKERTEST.ZREPORTDATA` JSON).

**Setup.** iPhone 17 Pro Max, the app's build of 2026-11-14 (phases 0–7), the normal mode (the phone played the
sweep), a stereo pair, left then right 40 s apart. The route, the distance and the room were not recorded.

## What was measured

| | Left | Right |
|---|---|---|
| Valid runs | 3 of 3 | 3 of 3 |
| Signal-to-noise | 26 dB | 34 dB |
| Route delay | 2.064 s, within 0.5 ms across runs | 2.059–2.062 s |
| Run-to-run agreement of each deviation | within 0.3 dB | within 0.5 dB |
| Distortion where measurable | under 4 % | under 3 % |
| Phone moved | run 2 | none |

Both speakers show the same shape: a peak of about 9 dB between 50 and 150 Hz, a peak of 7–8 dB near 400 Hz, a
dip of 6–8 dB at 2.3–3.9 kHz and a roll-off of about 9 dB above 12 kHz. Left and right agree within about 2 dB
from 200 Hz up, and differ by up to 10 dB at 100–160 Hz.

## What it tells us

- **The real engine path works**: playback, capture, deconvolution, three valid runs, a kept result, on a route
  with a 2 s delay. `maximumRouteDelay` is 2.5 s, so this route is 0.4 s from being refused.
- **A deviation that both speakers share is probably not a defect.** Two speakers with the same peaks and dips
  point at the room, the position or the phone's microphone. The verdicts were "I found 4 things worth a closer
  look." and "I found 3 things…", each finding `inferred`, medium confidence. That is honest per finding and too
  alarming as a whole. Open: say so when the other speaker shows the same deviation, and whether 6 dB is the
  right threshold away from 1 m.
- **Defect found: the top-end dip flipped.** The same roll-off was "Dip at 12–20 kHz" (inferred) for the left
  and "Very top notes dip" (inconclusive, could be the phone's angle) for the right, because the rule looked at
  where the dip crosses the threshold (just under and just over 14 kHz). The rule now looks at where the dip is
  deepest (`SpeakerDiagnosis`, with a test).
- **Distortion could be read at only 25–40 of 164 points per run.** Whether the result says clearly enough how
  little was checked is open.
- **The bass under 40 Hz** differs by 8 dB between the two: the left's signal-to-noise there was 16 dB, so that
  is noise, and the report makes no claim about it.
