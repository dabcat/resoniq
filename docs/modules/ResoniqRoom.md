---
type: "module"
spec_module: "C, D"
phase: 4
status: "active"
tags:
  - "module"
---
# ResoniqRoom

The room as plain values, and every decision about it: the model (walls, doors and windows, furniture, speakers, seats), a room entered by hand, the first guess at speakers and seat after a scan, distances and the listening triangle, edits that keep things inside the walls, what the room's size predicts (axial modes, boundary dips), where a speaker should go, and, for AR, how far a move has left and how model coordinates map to the world. No RoomPlan, ARKit or SwiftUI: it depends on nothing and is tested on the Mac. Plans: [phase-4-room.md](../plans/phase-4-room.md) (task 1), [phase-5-ar.md](../plans/phase-5-ar.md) (task 1). Conventions come from [the RoomScan reference](../reference/iosar-roomplan-arkit.md).

Paths below are relative to `ResoniqKit/Sources/ResoniqRoom/`.

## Conventions

- **Units and axes.** Metres and radians. The plan is the x–z plane of ARKit and RoomPlan, seen from above with y up; the floor is y = 0. `PlanPoint` (`Model/PlanPoint.swift:7`) holds x and z; height is never part of a plan point.
- **Plan angles.** `atan2(z, x)`, so 0 is +x and π/2 is +z (`PlanAngle`, `Model/PlanPoint.swift:67`). ARKit's yaw of the same direction is `−angle`. Nothing user-facing depends on the sense of rotation: turns are "toward your seat".
- **Left and right.** For someone facing along `d`, the right hand is `(−d.z, d.x)` (`PlanPoint.rightHand`, `:37`): ARKit's camera looks along −z with +x on its right.
- **Footprints.** `OrientedRect` (`Model/PlanPoint.swift:99`): centre, `width` across the front, `depth` along it, `heading` the plan angle of the front. A speaker's footprint heading is its facing.
- **Walls and openings.** A wall is a segment with a height; an opening is a door or window at an `offset` from the wall's start, with a width. The floor outline is optional; without it, walls that close a loop stand in for it (`RoomGeometry.outline`).
- **Speakers are guesses until confirmed.** RoomPlan does not recognise loudspeakers. `LayoutGuess` places them with `isConfirmed == false`, and the copy says they were guessed (`RoomText.layoutGuessHint`).
- **The listener's frame.** `MoveDirection` is relative to the listener at the seat, who faces the main speakers' midpoint: forward is toward the seat, back away from it (toward the wall behind a front speaker), left and right are the listener's. One definition: `PlacementAdvisor.frame` (`Advice/PlacementAdvisor.swift:98`). AR guidance uses the viewer instead (`ViewerDirection`: toward you, away from you, left, right).
- **Every suggestion is `guide`.** Suggested, not yet tested: the words are "should", never "will". `SuggestionBasis.measured` names the measured problems it answers; `.roomShape` says it rests on the triangle alone. It becomes a fact only from a second measurement (phase 5, `ResoniqDiagnostics`).
- **Strings.** Every user-facing string is in `RoomText` (`RoomText.swift:8`), formatted without the locale: lengths "0.90 m" (two decimals), moves "35 cm" under a metre, frequencies "61 Hz".
- **Persistence.** `RoomModel` is `Codable` with `schemaVersion` (`RoomModel.currentSchemaVersion`, 1). Values are stored in the room's own frame; `WorldAlignment` and `RoomModel.applying(_:)` carry them to AR world coordinates, as RoomScan recommends.

## Public interface

### Model

| Symbol | Where | Holds |
|---|---|---|
| `PlanPoint` | `Model/PlanPoint.swift:7` | x, z; `init(angle:)` (:19), `length`, `angle`, `normalized`, `rightHand` (:37), `dot`, `cross`, `distance(to:)`, `rotated(by:)` (:48), arithmetic |
| `PlanAngle` | `Model/PlanPoint.swift:67` | `normalized` (:69), `difference(from:to:)` (:77), `degrees`, `radians` |
| `PlanPose` | `Model/PlanPoint.swift:84` | position and facing |
| `OrientedRect` | `Model/PlanPoint.swift:99` | centre, width, depth, heading; `area`, `corners` (:115), `moved(to:)` |
| `RoomModel` | `Model/RoomModel.swift:9` | `schemaVersion`, `source`, `walls`, `floorOutline`, `furniture`, `speakers`, `seats`; `speaker(_:)`, `seat(_:)`, `speaker(role:)` (:44–48), `primarySeat` (:51) |
| `RoomSource` | `Model/RoomModel.swift:55` | `scanned`, `manual` |
| `Wall` | `Model/RoomModel.swift:63` | id, start, end, height, openings; `length`, `direction` |
| `Opening` | `Model/RoomModel.swift:85` | `Kind` door or window, `offset` along the wall, `width` |
| `Furniture` | `Model/RoomModel.swift:107` | `Category` sofa, chair, table, storage, television, bed, other; `footprint`, optional `height` |
| `SpeakerRole` | `Model/RoomModel.swift:133` | left, right, single, subwoofer |
| `PlacedSpeaker` | `Model/RoomModel.swift:143` | id, role, position, facing, `size` (default by role), `driverHeight`, `isConfirmed`; `footprint` (:185), `pose` |
| `FootprintSize` | `Model/RoomModel.swift:193` | width, depth |
| `Seat` | `Model/RoomModel.swift:204` | id, position, `isConfirmed` |
| `ManualRoom` | `Model/ManualRoom.swift:8` | `init(width:length:height:)` (:29), `issues` (:36), `isValid`, `model() -> RoomModel?` (:52): a rectangle centred on the origin, width along x |
| `LayoutGuess.place(in:)` | `Model/LayoutGuess.swift:37` | Seat on the largest sofa (or the centre), facing a television, the sofa's open side or the long axis; a symmetric pair for a 60° triangle `defaultWallDistance` from the wall ahead; fixed ids `seatID`, `leftID`, `rightID` (:33–35); keeps items already there |
| `RoomPlanMapping` | `Model/RoomPlanMapping.swift:9` | For the converter (phase 4 task 2), on 16 column-major numbers: `centre(of:)`, `localX`, `localZ`, `wall(id:transform:width:height:openings:)` (:30), `opening(id:kind:transform:width:on:)` (:40), `furniture(id:categoryName:transform:width:height:depth:)` (:52), `category(named:)` (:62), `floorOutline(corners:transform:)` (:68) |
| `RoomModel.applying(_:)` | `Model/RoomPlanMapping.swift:82` | The whole model through a `WorldAlignment` |

### Geometry and edits

| Symbol | Where | Holds |
|---|---|---|
| `PlanRect`, `RoomDimensions` | `Geometry/RoomGeometry.swift:4`, `:27` | The bounding rectangle; width (x), length (z), height, `sortedSides` |
| `WallDistance`, `WallCoverage` | `Geometry/RoomGeometry.swift:45`, `:57` | Nearest wall answer; captured and expected walls |
| `RoomGeometry` | `Geometry/RoomGeometry.swift:66` | `outline(of:)` (:74), `bounds(of:)` (:80), `height(of:)` (median wall height, :94), `dimensions(of:)` (:101), `wallLengths(of:)`, `floorArea(of:)`, `contains(_:in:)` (:118), `nearestWall(to:in:)` (:125), `distanceToNearestWall(footprint:in:)` (:141), `wallAhead(of:direction:in:)` (:148), `wallBehind(_:in:)` (:175), `isClosed(_:)` (:204), `coverage(of:)` (:207) |
| `ListeningGeometry` | `Geometry/ListeningGeometry.swift:8` | `init(seat:left:right:)` (:34), `init?(room:)` (:41); `leftDistance`, `rightDistance`, `distanceDifference`, `spacing`, `subtendedAngle` (:55), `toeInError(of:toward:)` (:61), `issues` (:69: `tooWide`, `tooNarrow`, `closerTo`, `notToedIn`), `isEven`, `unevenness` (:86) |
| `PlacementRules` | `Geometry/RoomEdits.swift:4` | `allows(speakerFootprint:ignoring:in:)` (:22), `allows(seatAt:in:)` (:42) and the clearances |
| `RoomEdit` | `Geometry/RoomEdits.swift:51` | The new `room` and `wasClamped` |
| `RoomModel` edits | `Geometry/RoomEdits.swift:61–136` | `moving(_:to:)` (:61), `rotating(_:to:)` (:87), `adding(_: PlacedSpeaker)` (:107), `adding(_: Seat)` (:122), `removing(_:)` (:136) |

### Acoustic models

| Symbol | Where | Holds |
|---|---|---|
| `Acoustics.speedOfSound` | `Acoustics/RoomModes.swift:7` | 343 m/s |
| `RoomDimension`, `RoomMode` | `Acoustics/RoomModes.swift:11`, `:20` | width, length, height; order, span, frequency, `pressure(atCoordinate:)` = cos(nπx/L) (:37) |
| `RoomModes` | `Acoustics/RoomModes.swift:48` | `axial(for:upTo:)` (:54), `axial(dimensions:upTo:)` (:61), `coordinate(of:height:along:in:)` (:83) |
| `BoundarySurface`, `BoundaryDip` | `Acoustics/RoomModes.swift:94`, `:101` | wall behind, side wall, floor; distance and c/4d |
| `BoundaryInterference` | `Acoustics/RoomModes.swift:122` | `dipFrequency(distance:)` (:123), `dipFrequencies(for:in:)` (:127) |

### Placement advice

| Symbol | Where | Holds |
|---|---|---|
| `AcousticProblem` | `Advice/Suggestion.swift:4` | frequency, `deviation` (magnitude, dB), kind peak or dip |
| `MoveDirection`, `Slide`, `Turn`, `SuggestionStep` | `Advice/Suggestion.swift:29`, `:37`, `:49`, `:61` | forward, back, left, right; a slide; a signed turn toward the seat; slides then the turn |
| `SuggestionGoal`, `SuggestionReason`, `SuggestionBasis` | `Advice/Suggestion.swift:67`, `:79`, `:89` | A measured problem or a triangle goal; boundary dip from → to, mode coupling before → after, or a geometry issue; measured problems or room shape |
| `SuggestionText` | `Advice/Suggestion.swift:98` | `headline`, `reason`, `totalDistance` ("35 cm in total"), `thenTurn` ("then turn 12° toward your seat"), `steps`, `stepLabels` ("step 1 of 2") |
| `PlacementSuggestion` | `Advice/Suggestion.swift:114` | speaker, role, `from`, `to`, slides, turn, steps, goal, reason, `score`, basis, text; `distance`, `problem`, `target` (:141) for AR |
| `ModelTerm`, `SpeakerCoupling`, `ProblemExplanation` | `Advice/Suggestion.swift:145`, `:159`, `:166` | The terms that explain a problem, closest first; `isExplained` |
| `PlacementAdvice` | `Advice/Suggestion.swift:175` | `suggestions`, `explanations`, `unexplained` (:181), `unexplainedText` |
| `PlacementLimits` | `Advice/Suggestion.swift:188` | `maximumMove` 0.5 m, `maximumSubwooferMove` 3 m, how many to return; `standard` |
| `PlacementAdvisor` | `Advice/PlacementAdvisor.swift:23` | `suggestions(room:problems:limits:)` (:60), `advice(room:problems:limits:)` (:67), `frame(in:seat:)` (:98) |

### Guidance (phase 5)

| Symbol | Where | Holds |
|---|---|---|
| `ViewerDirection`, `Viewer` | `Guidance/MoveGuidance.swift:4`, `:12` | toward you, away from you, left, right; the phone's plan position and heading |
| `MoveProgress` | `Guidance/MoveGuidance.swift:24` | `distanceToGo`, `direction`, `bearing`, `turnRemaining`, `totalDistance`, `fractionDone`, `isInPosition`, `hasArrived` |
| `MoveGuidance` | `Guidance/MoveGuidance.swift:44` | `Target` (:46, start and end pose), `progress(current:target:viewer:)` (:70), `hapticInterval(distance:)` (:91) |
| `WorldAlignment` | `Guidance/WorldAlignment.swift:10` | rotation (plan angle), translation, `residual`; `init(modelPoint:worldPoint:modelHeading:worldHeading:)` (:32), `fit(model:world:)` least squares (:39), `isConsistent`, `apply` (:61–65), `inverse` (:70) |

### Text

| Symbol | Where | Holds |
|---|---|---|
| `RoomText` | `RoomText.swift:8` | `metres` (:12), `move` (:15), `moveParts` (:21), `dimensions` (:28), `roomTitle` (:34), `wallsCaptured` (:39), `degrees`, `frequency`, `problemLabel` (:55), `legendMeasured`, `legendSuggested`, `seatName` (:62–64), `layoutGuessHint` (:68), `shortName`, `title`, `manualIssue` (:101), `geometryIssue` (:114), `geometrySummary`, `roomShapeBasis` (:132), `totalDistance` (:219), `thenTurn`, `stepLabel`, `stepTitle` (:228), `stepInstruction`, `unexplained` (:241), `slideInstruction` (:248), `toGoLabel`, `hapticHint`, `arrived` |

## How the advisor decides

For each measured problem (`Advice/PlacementAdvisor.swift:23`, the doc comment is the full statement):

1. **Explain.** A speaker's boundary dip within `boundaryTolerance` (1/6 octave) of a measured dip; an axial mode within `modeTolerance` (1/12 octave) where, for a peak, the seat and a speaker both sit near an antinode (`|cos| ≥ 0.5`), or, for a dip, the seat or a speaker sits near a null (`|cos| ≤ 0.35`). Above 300 Hz nothing is explained. No term: `unexplained`, and no move is invented.
2. **Search.** Each main speaker slides along the four directions in 5 cm steps up to `maximumMove`, keeping `PlacementRules`, and ends turned toward the seat. For each explained problem the best term for that speaker earns credit: a dip moved away from the problem frequency (full credit at a third of an octave), or the speaker's coupling to the mode changed the right way. Credit is weighted by the deviation (10 dB = 1). Penalties: 0.5 a metre moved, 0.05 per unit of added triangle unevenness, 0.3 for landing two of the speaker's own dips on one note.
3. **Rank.** The best spot per speaker and direction, best first, up to three, so "Can't move it" has an alternative.

A subwoofer is searched along the walls (every 0.25 m, facing in), scored only on mode coupling (for a peak, less; for a dip, more), 0.1 a metre moved, up to `maximumSubwooferMove`; two spots at least a metre apart. With no measured problems, the same search scores only the triangle (60° ± 10°, distances within 5 cm, toe-in within 10°), with a turn on its own when only the toe-in is off, and every result says it is from the room's shape.

**Worked case** (the tests' `stereoRoom`: the mockups' 4.20 × 5.60 m room, a pair 2 m apart and 1.40 m from the back wall, the seat at the apex of an equilateral triangle, a measured dip of 11 dB at 61 Hz). Explained by both speakers' rear-wall dips (343 / 5.6 = 61.25 Hz) and the length's second mode (61.25 Hz, speakers on its null). Best: "Pull the left speaker 40 cm forward and the missing bass note should return." (the rear-wall dip moves to 47.6 Hz, then a 7° turn toward the seat, score 0.53); second, the same for the right speaker; third, the left speaker 30 cm back (to 78 Hz, ranked lower because it lands on the side wall's 78 Hz dip). The mockup shows 35 cm; with these constants 40 cm is the smallest grid step that moves the dip a full third of an octave.

## Thresholds and constants

Every public static constant. "First guess" is said in the doc comment, and every one so marked has to be tuned against before-and-after measurements in real rooms.

| Constant | Where | Value | Note |
|---|---|---|---|
| `RoomModel.currentSchemaVersion` | `Model/RoomModel.swift:11` | 1 | |
| `RoomModel.defaultHeight` | `Model/RoomModel.swift:14` | 2.4 m | First guess |
| `PlacedSpeaker.defaultSize` | `Model/RoomModel.swift:146` | 0.25 × 0.30 m | First guess |
| `PlacedSpeaker.defaultSubwooferSize` | `Model/RoomModel.swift:148` | 0.35 × 0.35 m | First guess |
| `PlacedSpeaker.defaultDriverHeight` | `Model/RoomModel.swift:151` | 0.9 m | First guess; sets the floor dip (95 Hz) |
| `PlacedSpeaker.defaultSubwooferDriverHeight` | `Model/RoomModel.swift:153` | 0.2 m | First guess |
| `ManualRoom.minimumSide`, `maximumSide` | `Model/ManualRoom.swift:10`, `:12` | 1.5 m, 20 m | First guesses |
| `ManualRoom.minimumHeight`, `maximumHeight` | `Model/ManualRoom.swift:14`, `:16` | 1.8 m, 6 m | First guesses |
| `LayoutGuess.defaultWallDistance` | `Model/LayoutGuess.swift:23` | 0.6 m | First guess |
| `LayoutGuess.minimumSpacing`, `maximumSpacing` | `Model/LayoutGuess.swift:25`, `:27` | 1.0 m, 3.0 m | First guesses |
| `LayoutGuess.televisionGap` | `Model/LayoutGuess.swift:29` | 0.15 m | First guess |
| `RoomGeometry.cornerJoin` | `Geometry/RoomGeometry.swift:68` | 0.05 m | RoomScan's `cornerJoinM` |
| `RoomGeometry.behindCosine` | `Geometry/RoomGeometry.swift:167` | 0.5 (60°) | Which wall is behind a toed-in speaker |
| `ListeningGeometry.idealAngle` | `Geometry/ListeningGeometry.swift:11` | 60° | Classic guidance (ITU-R BS.775 ±30°), not a measurement |
| `ListeningGeometry.angleTolerance` | `Geometry/ListeningGeometry.swift:13` | ±10° | First guess |
| `ListeningGeometry.distanceTolerance` | `Geometry/ListeningGeometry.swift:16` | 0.05 m | First guess (about 0.15 ms) |
| `ListeningGeometry.toeInTolerance` | `Geometry/ListeningGeometry.swift:18` | ±10° | First guess |
| `PlacementRules.speakerWallClearance` | `Geometry/RoomEdits.swift:6` | 0.05 m | First guess |
| `PlacementRules.speakerFurnitureClearance` | `Geometry/RoomEdits.swift:8` | 0.05 m | First guess; also between speakers |
| `PlacementRules.seatWallClearance` | `Geometry/RoomEdits.swift:10` | 0.20 m | First guess |
| `PlacementRules.furnitureSpeakersMayStandOn` | `Geometry/RoomEdits.swift:13` | storage | Speakers stand on cabinets and shelves |
| `PlacementRules.clampSearchRadius`, `clampSearchStep` | `Geometry/RoomEdits.swift:15`, `:17` | 1.5 m, 0.01 m | |
| `Acoustics.speedOfSound` | `Acoustics/RoomModes.swift:7` | 343 m/s | Air at about 20 °C |
| `RoomModes.defaultMaximumFrequency` | `Acoustics/RoomModes.swift:51` | 200 Hz | First guess, about a living room's Schroeder frequency |
| `PlacementAdvisor.boundaryTolerance` | `Advice/PlacementAdvisor.swift:25` | 1/6 octave | First guess |
| `PlacementAdvisor.modeTolerance` | `Advice/PlacementAdvisor.swift:28` | 1/12 octave | First guess |
| `PlacementAdvisor.maximumFrequency` | `Advice/PlacementAdvisor.swift:30` | 300 Hz | |
| `PlacementAdvisor.antinodeCoupling`, `nullCoupling` | `Advice/PlacementAdvisor.swift:32`, `:34` | 0.5, 0.35 | First guesses |
| `PlacementAdvisor.targetShift` | `Advice/PlacementAdvisor.swift:37` | 1/3 octave | First guess |
| `PlacementAdvisor.couplingSwing` | `Advice/PlacementAdvisor.swift:39` | 0.5 | First guess |
| `PlacementAdvisor.referenceDeviation` | `Advice/PlacementAdvisor.swift:41` | 10 dB | Weight 1; capped at 2 |
| `PlacementAdvisor.gridStep` | `Advice/PlacementAdvisor.swift:43` | 0.05 m | |
| `PlacementAdvisor.movePenaltyPerMetre` | `Advice/PlacementAdvisor.swift:45` | 0.5 | First guess |
| `PlacementAdvisor.subwooferMovePenaltyPerMetre` | `Advice/PlacementAdvisor.swift:47` | 0.1 | First guess |
| `PlacementAdvisor.asymmetryPenalty` | `Advice/PlacementAdvisor.swift:49` | 0.05 per unit | First guess |
| `PlacementAdvisor.stackingPenalty` | `Advice/PlacementAdvisor.swift:51` | 0.3 | First guess |
| `PlacementAdvisor.geometryCredit` | `Advice/PlacementAdvisor.swift:53` | 0.1 per unit | First guess |
| `PlacementAdvisor.minimumTurn` | `Advice/PlacementAdvisor.swift:55` | 2° | |
| `PlacementAdvisor.subwooferStep` | `Advice/PlacementAdvisor.swift:57` | 0.25 m | |
| `PlacementLimits.standard` | `Advice/Suggestion.swift:206` | 0.5 m, 3 m, 3, 2 | First guesses |
| `MoveGuidance.positionTolerance` | `Guidance/MoveGuidance.swift:60` | 0.03 m | First guess |
| `MoveGuidance.angleTolerance` | `Guidance/MoveGuidance.swift:62` | 3° | First guess |
| `MoveGuidance.hapticRange` | `Guidance/MoveGuidance.swift:64` | 1.0 m | First guess |
| `MoveGuidance.fastestHapticInterval`, `slowestHapticInterval` | `Guidance/MoveGuidance.swift:66`, `:68` | 0.08 s, 0.8 s | First guesses; linear between |
| `WorldAlignment.maximumResidual` | `Guidance/WorldAlignment.swift:13` | 0.10 m | First guess |

## Tests

`ResoniqKit/Tests/ResoniqRoomTests/`, 51 tests, under a second.

- `GeometryTests`: plan vectors (ARKit's right hand, angle wrapping, footprint corners); the manual room's walls, dimensions, area and every validation limit including NaN; containment, nearest wall inside and outside, a footprint's gap to the wall, the wall behind a toed-in speaker, on a rectangle and an L; "3 of 4 walls" while a scan is open, walls standing in for a missing floor; every length, size, angle and frequency format the mockups show.
- `EditTests`: a move into a wall stops at the clearance, an allowed move is exact, furniture blocks a speaker, a seat may sit on a sofa but not in a wall, a turn into a wall moves the speaker out, adding outside the room and removing.
- `ListeningGeometryTests`: an equilateral triangle against hand values and an uneven one (108.4°, 82 cm closer to the right, both toe-ins off).
- `LayoutGuessTests`: deterministic and inside the room for an empty rectangle (seat at the centre, pair 0.6 m from the wall at 60°), two sofas (the largest wins and faces the open room), a television (symmetric, clear of it), an L-shape with no furniture, and a confirmed layout left alone.
- `AcousticModelTests`: axial modes of 4.20 × 5.60 × 2.40 m against n·343/2L by hand; mode pressure at the wall, the null and the centre; the three boundary dips against c/4d.
- `PlacementAdvisorTests`: the 61 Hz case (forward or back, within the limit, the mockup's sentence form, the AR lines, a distinct second); turns aim at the seat; the listener's frame; unexplained problems give nothing; no problems gives only room-shape suggestions, and a turn on its own when only the toe-in is off; every suggestion stays inside, off furniture and within the limit for two limits; a wall limits a move back; a subwoofer peak moved along a wall away from the width's second mode; no seat, no suggestion.
- `GuidanceTests`: progress halfway, toward the viewer and to the side, arrival needs both position and turn, the fraction stays in 0…1, taps strictly faster as the distance shrinks and none outside the range; `WorldAlignment` recovers a known rotation and translation from two and four points and from a point and a heading, flags an inconsistent point by its residual, refuses degenerate input, and carries a room there and back.
- `ModelTests` (without `@testable`): a full model and a full advice round-trip through JSON; the RoomPlan helpers on hand-built transforms (a wall along its local x through its centre, an opening's offset, furniture heading, unknown categories, floor corners through the transform).

All of this is constructed geometry. Nothing here has met a real scan or a real room.

## Limits

What the doc comments say the models cannot tell you.

- **`RoomModes`:** the bounding rectangle only, so an L-shaped or open-plan room is treated as its rectangle; axial modes only (no tangential or oblique); furniture, openings, wall construction (a light wall leaks bass) and absorption are ignored, so how strong or wide a mode is is not predicted. Above about 200 Hz modes overlap and a match means little. The rectangle is axis-aligned in the model's frame, so a scanned room must be in a room-anchored frame (longest wall along x, as RoomScan's `SceneNormalizer` does) for the width and length to be the room's.
- **`BoundaryInterference`:** the first dip of each surface only (the next are at 3, 5, 7 times it); perfect rigid reflectors; an omnidirectional speaker, which holds in the bass and fails higher up; the three reflections are not summed, so the depth at the seat is not predicted. Distances are from the speaker's centre, not its baffle or drivers.
- **`PlacementAdvisor`:** only the moved speaker's own terms are credited, so moving one of two speakers that both cause a dip is scored as if it fixes it. It does not check that a move creates a new problem elsewhere (except stacking its own dips). Slides are along the four listener directions only. RoomPlan gives geometry, not materials (product spec §8): every suggestion rests on a measured problem or says it is from the room's shape, and none is a fact until measured again.
- **`LayoutGuess`:** a guess from furniture; RoomPlan's front of a sofa is not trusted, so the sofa faces whichever side has more room.
- **`ListeningGeometry`:** classic guidance, not a measurement of imaging.

## Open questions

- The mockups say "35 cm"; these constants give 40 cm for the same case. Is the third-of-an-octave target right, or should the advisor prefer the smaller move that clears the tolerance?
- `V3OLayout`'s copy "I spotted the speakers from the scan" claims RoomPlan saw the speakers; it cannot. `RoomText.layoutGuessHint` says they were guessed. The owner should confirm the wording.
- Is RoomPlan's local +z an object's front? The converter task should check on a real scan and, if so, `LayoutGuess` can trust the sofa's heading.
- Should a move of one speaker of a symmetric pair suggest moving both (keeping symmetry), as the plan's rule "it does not break the symmetry of a pair unless that is the point" hints?
- Every first-guess constant above needs before-and-after measurements in real rooms; the advisor's weights in particular are untested.
