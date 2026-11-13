---
type: "plan"
phase: 5
status: "planned"
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
| 1 | `MoveGuidance`, `WorldAlignment` | Room | Opus | todo |
| 2 | `SeatComparison`, `ComparisonReport`, texts | Diagnostics | Opus | todo |
| 3 | `Optimization` in the store | Store | Sonnet | todo |
| 4 | AR session wrapper: floor detection, alignment, footprints and arc in RealityKit, haptics | App | Opus | todo |
| 5 | Components and screens: AR overlay readouts, Before and after, no improvement, subwoofer suggestion | Design, App | Sonnet | todo |
| 6 | Check in the simulator (everything but the camera); module notes | — | Fable | todo |

Done when: `make test` and `make build` pass; in the simulator the "move it myself" path goes from a suggestion
through a second measurement to Before and after. The AR path needs a device and is verified by the owner.
