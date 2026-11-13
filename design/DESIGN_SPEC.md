# Resoniq Design Spec

Version 0.2. Visual rules: [`DESIGN_SYSTEM.md`](./DESIGN_SYSTEM.md). Values: [`tokens.json`](./tokens.json).
Working mockups: the Resoniq design canvas, page "Proposal: precision instrument".

## Who and where

| Context | What they need |
|---|---|
| Standing in someone else's home, judging second-hand speakers | A fast verdict they can trust and repeat, nothing saved to their own rooms |
| On the sofa with their own system | To know how it really sounds at the seat, in plain words |
| Walking around the room with the phone | Clear spatial guidance, big targets, little reading |

## Information architecture

```
First launch: 3 intro screens (skippable) → first speaker test
Tab bar
├── Diagnose   Your speakers as portraits · check a speaker · findings · quick check
├── Measure    How it sounds at your seat · measure · the numbers
└── Optimize   Your room plan · scan · confirm layout · AR move · before / after
Settings       Icon button, top right of Diagnose
```

Every tab starts with the **room and system switcher**. A user can have several rooms; each room can hold
several sound systems (stereo pair, stereo + subwoofer, soundbar, single speaker, surround). Nothing about
make or model is asked. If the user never names anything, results are kept under "My room · My speakers".

## First launch

Three intro screens explain what the app does and how, using the real visualisations. Each has "Skip intro".

| # | Screen | Shows | Says |
|---|---|---|---|
| 1 | Diagnose | A portrait drawing itself from bass to treble, one band trembling | Play a tone, listen, read the shape |
| 2 | Measure | A curve drawing across the even band, bass swinging outside | Measured at three spots around your head |
| 3 | Optimize | A plan where the right speaker slides into a blue outline and the problem area fades | Scan, measure, follow outlines in AR, measure again |

The third screen's button is "Try it on a speaker" and leads straight into the first test.

## Diagnose

**Aim (first test and every later test).** Illustration of the phone held sideways about 30 cm from the
speaker, bottom edge toward it. Left / Right / Only one. "Start listening" triggers the microphone
permission; the caption says so beforehand and that sound never leaves the phone.

**Listening.** Portrait panel on the left fills upward; on the right a "Playing now" readout and three
status readings (Room, Level, Phone). Bottom line: "Hold still."

**Paused · too noisy.** Automatic. Portrait dims, `Paused` pill, live room-noise readout with the
"quiet enough" mark. The app resumes by itself from the same frequency. Secondary: stop and start over.

**Result.** Headline verdict in a sentence. Portrait with findings written beside it at their frequency,
each with an evidence tag. "Kept in: room · system" with Rename and Don't keep. Primary: test the other speaker.

**Finding.** Three runs laid over each other show the deviation repeats. Hold-to-hear plays the frequency
so the user can hear it. Confidence statement. Next steps: swap test (does the fault follow the speaker?),
measure from a second spot. Link to the distortion numbers.

**Diagnose home.** Left and right portraits either side of a shared frequency ruler. Unheard speakers are
dashed outlines. Primary action is always the most useful next test. Link: "Checking speakers somewhere
else? Quick check" (runs the same test without saving to a room).

Other states to design: microphone denied, level too low / clipping, phone moved during a run,
single-speaker and soundbar systems, all speakers healthy.

## Measure

**Measure home.** Sentence verdict, response curve with the even band, up to three findings with evidence
tags; an inferred "it's the room" finding links to Optimize. Primary: measure again from the seat.
Links: the numbers, watch live.

**Sit and aim.** Top view: both speakers play toward the sofa; three spots at head height, the middle
first. Three short instructions (phone at ear height, usual volume, stay quiet).

**Three spots.** Status pills Seat / Left / Right. Instruction in a sentence ("Now move the phone 30 cm to
your left"), small top-view panel with the phone sliding to the next spot, and the average building in the
curve panel. Capture starts automatically once the phone is still; a rigid haptic marks each captured spot.

**The numbers (advanced).** Response / Distortion / Decay. Left and right on a decibel grid with
1/3-octave smoothing, then a mono table of values with evidence tags. Footnote: uncalibrated iPhone
microphone, trust shapes and differences over absolute decibels.

Other states to design: first-time empty state, noisy interruption (reuse Diagnose pattern), watch live,
comparing two dated measurements.

## Optimize

**Optimize home.** Progress tracker (Scanned → Measured → Move → Verify). One recommendation in a
sentence. Room plan with measured spots, measured problem area and the suggested position. Legend:
measured versus suggested. Primary: guide me in AR. Links: I'll move it myself, rescan, edit layout.

**Scan.** Camera with detected walls and objects outlined and labelled, wall length readouts, a mini
floor plan that fills in as walls are captured, and one instruction with a direction arrow. Camera
permission is requested here, the first time. Fallback: enter the room by hand (no LiDAR).

**Confirm layout.** Plan / 3D toggle. Speakers and seat are draggable; the selected item shows a live
distance to the nearest wall. Add subwoofer, add a seat, fix a wall. Primary: measure the room.

**AR guidance.** Target footprint on the floor, current footprint sliding toward it, large "to go"
readout, progress bar, rotation arc. Haptic taps speed up with proximity. Buttons: It's in place,
Can't move it (offers the next-best suggestion).

**Before and after.** Completed tracker, sentence verdict, before (dashed) and after traces at the same
three spots, value changes, and an honest note on what remains. Buttons: Keep this setup, Next suggestion,
Put the speaker back where it was.

Other states to design: no improvement / got worse, subwoofer placement, manual room entry, rooms and
systems sheet, Settings.

## Interaction rules

- One dominant action per screen, at the bottom, reachable with one thumb.
- The app starts, pauses and resumes measurements by itself whenever it can detect the condition.
- Nothing is asked up front that can be inferred or named later.
- Any conclusion can be traced to its evidence in at most one tap.
- Everything works offline; recordings and scans never leave the device.

## Open questions

- Tab bar: Diagnose · Measure · Optimize is proposed; the earlier brief asked for Diagnose · Optimize · Settings.
- Typeface licensing is fine (both OFL), but confirm bundling custom fonts over SF Pro.
- Light theme: not planned for MVP.
