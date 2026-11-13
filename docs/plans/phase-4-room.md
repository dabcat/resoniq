---
type: "plan"
phase: 4
status: "planned"
tags:
  - "plan/phase-4"
---
# Phase 4 · Optimize: room scan and layout

Goal: the app knows the room. The user scans it with RoomPlan, or enters it by hand without LiDAR, confirms
where the speakers and the seat are, and Optimize home shows the room plan with what was measured and one
suggestion. Screens: Optimize home, Scan, Confirm layout, manual room entry, from the mockups in
[design/screens](../../design/screens/README.md). RoomPlan and ARKit code starts from
[the RoomScan reference](../reference/iosar-roomplan-arkit.md).

## The room model

`ResoniqRoom` depends on nothing, so it can be tested on the Mac and stored as plain `Codable` values.

- Units are metres and radians. The plan is the x–z plane with y up, as RoomPlan and ARKit give it.
- `RoomModel`: walls (segments with a height, each with its doors and windows), the floor outline, furniture
  (category, footprint), speakers (`PlacedSpeaker`: role left, right, single, subwoofer; position; the direction
  it faces; whether a person confirmed it or the app guessed it), seats, and where the model came from
  (scanned, entered by hand).
- RoomPlan does not recognise loudspeakers. After a scan the app guesses a stereo pair against the wall the
  sofa faces and a seat on the sofa, marks them as guessed, and the Confirm layout screen exists to correct
  them. The copy must not claim more than that.

## Who decides what

| Decision | Module | Symbol (contract) |
|---|---|---|
| The room and what is in it | `ResoniqRoom` | `RoomModel`, `Wall`, `Opening`, `Furniture`, `PlacedSpeaker`, `Seat`, `RoomSource` |
| A room from a scan | `ResoniqRoom` | `RoomPlanConverter.room(from: CapturedRoom) -> RoomModel` (only where RoomPlan exists), built on helpers that take plain values and are tested on the Mac |
| A room entered by hand | `ResoniqRoom` | `ManualRoom(width:length:height:)` and `.model()` |
| The first guess at speakers and seat | `ResoniqRoom` | `LayoutGuess.place(in:) -> RoomModel` |
| Distances and listening geometry | `ResoniqRoom` | `RoomGeometry` (nearest wall and distance for a point, inside or outside, room dimensions and the bounding rectangle), `ListeningGeometry` (distances from each speaker to the seat, the angle between them, how symmetric, toe-in) |
| Moving things | `ResoniqRoom` | `RoomModel.moving(_:to:)`, `.rotating(_:to:)`, `.adding(_:)`, `.removing(_:)`, each keeping items inside the walls and clear of them by a stated margin |
| What the room's size predicts | `ResoniqRoom` | `RoomModes.axial(for:)` (the lowest resonances of the bounding rectangle), `BoundaryInterference.dipFrequencies(for:in:)` (the notes a speaker's distance to the walls cancels) |
| Where a speaker should go | `ResoniqRoom` | `PlacementAdvisor.suggestions(room:problems:) -> [PlacementSuggestion]` |

`AcousticProblem` (frequency, how far outside the even band, peak or dip) is a plain value in `ResoniqRoom`; the
app maps the seat report's findings onto it.

Rules a suggestion must follow:

- It answers a **measured** problem. Without a seat measurement the advisor gives only geometry suggestions
  (make the triangle even, turn the speakers toward the seat), and says they are from the room's shape.
- It is marked `suggested, not yet tested`. The words are "should", never "will". It becomes a fact only when
  a measurement after the move shows it (phase 5).
- It is small and possible: a distance and a direction a person can follow ("35 cm forward"), inside the room,
  not through furniture, limited to a stated maximum move, and it does not break the symmetry of a pair unless
  that is the point.
- It names what it is for ("the missing bass note at 61 Hz") and why the model expects it to help.
- There is always a second-best suggestion for "Can't move it".
- A subwoofer gets its own suggestions (positions along the walls that excite the measured problem modes least).

## Tasks

| # | Task | Module | Model | Status |
|---|---|---|---|---|
| 1 | Room model, geometry, edits, manual room, layout guess, modes, boundary interference, placement advisor | Room | Opus | todo |
| 2 | RoomPlan conversion and the scan session wrapper (permission, capability check, capture, result), ported from the reference | Room, App | Opus | todo |
| 3 | Store: a room's layout and its scan file; `SeatMeasurement` linked to the layout it was taken in | Store | Sonnet | todo |
| 4 | Components: room plan (walls, windows, doors, furniture, speakers, seat, measured spots, problem hatching, suggested outline, legend, dragging), progress tracker | Design | Sonnet | todo |
| 5 | Screens: Optimize home, Scan (camera with overlay, floor-plan inset, instruction), Confirm layout (plan, 3D, add subwoofer, add a seat, fix a wall), manual room entry | App | Sonnet / Opus for scan | todo |
| 6 | Check in the simulator (everything but the scan); module note | — | Fable | todo |

Done when: `make test` and `make build` pass; in the simulator a room entered by hand goes from Optimize home
through Confirm layout to a suggestion on the plan. Scanning needs a LiDAR device and is verified by the owner.
