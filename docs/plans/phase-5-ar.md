---
type: "plan"
phase: 5
status: "done"
tags:
  - "plan/phase-5"
---
# Phase 5 · Optimize: AR guidance and before/after

Goal: the user moves a speaker to the suggested place by following an outline on the floor, measures again at
the same three spots, and sees what changed. Screens: AR guidance and Before and after, from the mockups in
[design/screens](../../design/screens/README.md). AR code starts from
[the RoomScan reference](../reference/iosar-roomplan-arkit.md).

## How it works

1. Optimize home shows one `PlacementSuggestion` (phase 4). "Guide me in AR" opens the camera; "I'll move it
   myself, then re-measure" skips to step 4.
2. The AR session finds the floor and is aligned with the room model: the user points at the speaker to be
   moved and confirms it, which fixes the model's coordinates to the world (after a scan in the same session
   the world map is reused when it can be).
3. The target footprint is a dashed blue outline on the floor; the speaker's current footprint follows the
   speaker as the user slides it (the user re-marks it, or it is tracked from the phone held against it — the
   simplest thing that works on a device decides). "To go" counts down, taps in the hand speed up near the
   target, then the turn toward the seat is shown as an arc. "It's in place" confirms; "Can't move it" offers
   the next-best suggestion.
4. The seat is measured again at the same three spots (phase 3).
5. Before and after are compared: the verdict in a sentence, both curves, each targeted problem's value before
   and after, what is unchanged, and an honest note on what remains.

## Who decides what

| Decision | Module | Symbol (contract) |
|---|---|---|
| How far and which way is left to go | `ResoniqRoom` | `MoveGuidance.progress(current:target:) -> MoveProgress` (distance, direction relative to the viewer, turn remaining, arrived or not, with a stated tolerance) |
| How fast the taps come | `ResoniqRoom` | `MoveGuidance.hapticInterval(distance:)` |
| Model coordinates to world coordinates | `ResoniqRoom` | `WorldAlignment` (a rigid transform in the floor plane from one or two matched points) |
| What changed between two seat measurements | `ResoniqDiagnostics` | `SeatComparison.compare(before:after:targeting:) -> ComparisonReport` (verdict, rows, what remains, improved, unchanged or worse) |
| The state of an optimisation | `ResoniqStore` | `Optimization` (the layout before, the suggestion, the layout after, the two seat measurements, the outcome: kept, put back) |

Rules:

- "Improved" is said only from the second measurement, tagged `measured`. A change inside the repeatability of
  the measurement is "unchanged".
- If it got worse or did not change, the screen says so plainly and offers to put the speaker back.
- The tracker's steps are Scanned, Measured, Move, Verify; a step is done only when its data exists.

## Tasks

| # | Task | Module | Model | Status |
|---|---|---|---|---|
| 1 | `MoveGuidance`, `WorldAlignment` | Room | Opus | done |
| 2 | `SeatComparison`, `ComparisonReport`, texts | Diagnostics | Opus | done |
| 3 | `Optimization` in the store | Store | Sonnet | done |
| 4 | AR session wrapper: floor detection, alignment, footprints and arc in RealityKit, haptics | App | Opus | done; never run on a device |
| 5 | Components and screens: AR overlay readouts, Before and after, no improvement, subwoofer suggestion | Design, App | Sonnet | done |
| 6 | Check in the simulator (everything but the camera); module notes | — | Fable | module notes done; the comparison with the mockups is not recorded |

Done when: `make test` and `make build` pass; in the simulator the "move it myself" path goes from a suggestion
through a second measurement to Before and after. The AR path needs a device and is verified by the owner.

## Notes

**What differs from the plan.**

- The speaker's position in AR is **marked by the user, not tracked**: ARKit does not track an arbitrary loudspeaker. The person puts a reticle on the speaker's front and marks it; while "Follow" is held the speaker's outline follows the reticle as the speaker slides. The speaker's turn is not seen either: "I can't see the speaker turn, so line it up by eye."
- The camera and the floor overlays are RealityKit on the source's own `ARSession`; the screen talks only to `ARGuidanceModel`. In the simulator `ScriptedARGuidanceSource` acts out a whole move on a 2D stand-in for the camera.
- Tracking trouble is a state of its own (limited tracking, too dark) with its own sentence; the guide never pretends.
- "Improved" is said only from the second measurement, tagged `measured`; a change inside the repeatability (1.5 dB) is unchanged. Worse and unchanged have a screen of their own (no mockup) with "Put the speaker back where it was" as the quiet link.
- `Optimization` tracks outcomes `suggested`, `moved`, `verified`, `kept`, `putBack`, `declined`; the tracker's steps are true only when their data exists.
- Hand-over between tabs: Optimize asks Measure for a seat measurement, and when Measure keeps a conclusive report Optimize compares it with the one before the move and shows Before and after.

**Not verified until a device test.** All of AR guidance: floor detection, the raycast under the screen's centre, how well a person can mark a speaker's front, the follow control used one-handed, tracking and relocalisation after an interruption, the haptics' feel, VoiceOver's announcements while moving, the camera permission and denied state. The list is in [ResoniqRoom](../modules/ResoniqRoom.md) and the [device checklist](../device-checklist.md).
