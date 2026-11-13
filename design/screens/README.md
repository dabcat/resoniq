# Screen templates

HTML/SVG mockups at 390×844, exported on 2026-11-13 from the Resoniq design canvas (page "Proposal: precision instrument"): <https://claude.ai/artifact/CJrMUftT8UwJWe1QJiCGKb>. They are templates for the SwiftUI screens. The canvas is the source of truth, so re-export when it changes. Each file loads `<script src="./support.js">`, the canvas runtime, which is not included. Use the files to read exact layout, colours, copy and SVG paths, not to open standalone. `canvas.json` holds the board titles and positions.

## Screens (flow order)

| File | Title | Flow | DESIGN_SPEC heading | Links to |
|---|---|---|---|---|
| `V3Onb1.dc.html` | Intro 1 · Diagnose | First launch | First launch (screen 1) | Onb2, Start |
| `V3Onb2.dc.html` | Intro 2 · Measure | First launch | First launch (screen 2) | Onb3, Start |
| `V3Onb3.dc.html` | Intro 3 · Optimize | First launch | First launch (screen 3) | Start |
| `V3Start.dc.html` | First test · Aim | First launch / Diagnose | Diagnose > Aim | Listening, Diagnose |
| `V3Listening.dc.html` | Listening | Diagnose | Diagnose > Listening | Paused, Start |
| `V3Paused.dc.html` | Paused · too noisy | Diagnose | Diagnose > Paused · too noisy | Start |
| `V3Result.dc.html` | Speaker portrait · result | Diagnose | Diagnose > Result | Finding, Diagnose, Start |
| `V3Finding.dc.html` | Finding · hear it yourself | Diagnose | Diagnose > Finding | Result, Measure, Start |
| `V3Diagnose.dc.html` | Diagnose | Diagnose | Diagnose > Diagnose home | Result, Start, Measure, Optimize |
| `V3Measure.dc.html` | Measure | Measure | Measure > Measure home | MGuide, MDetail, Optimize, Diagnose |
| `V3MGuide.dc.html` | Measure · Sit and aim | Measure | Measure > Sit and aim | MRunning, Measure |
| `V3MRunning.dc.html` | Measure · Three spots | Measure | Measure > Three spots | MGuide, Measure |
| `V3MDetail.dc.html` | Measure · The numbers | Measure | Measure > The numbers (advanced) | Measure |
| `V3Optimize.dc.html` | Optimize | Optimize | Optimize > Optimize home | OAR, OVerify, OScan, OLayout, Measure, Diagnose |
| `V3OScan.dc.html` | Optimize · Scan the room | Optimize | Optimize > Scan | OLayout, Optimize |
| `V3OLayout.dc.html` | Optimize · Confirm layout | Optimize | Optimize > Confirm layout | MGuide ("measure the room"), OScan |
| `V3OAR.dc.html` | Optimize · AR guidance | Optimize | Optimize > AR guidance | OVerify, Optimize |
| `V3OVerify.dc.html` | Optimize · Before and after | Optimize | Optimize > Before and after | OAR, Optimize |

Link targets are the `href="V3….dc.html"` values (shown without the `V3` prefix and extension, `OAR` = `V3OAR.dc.html`). Links to the screen itself are omitted. Several back and stop buttons also link to earlier screens.

## Reusable pieces

Canonical markup for each shared component in `../DESIGN_SYSTEM.md`:

- **Speaker portrait**: `V3Result` (finished, with deviation), `V3Listening` (drawing), `V3Paused` (dimmed), `V3Diagnose` (left and right, unheard dashed), `V3Start` (not heard yet).
- **Response curve**: `V3Measure` (home), `V3MDetail` (dB grid, left and right overlay), `V3MRunning` (average building), `V3OVerify` (before and after).
- **Room plan**: `V3Optimize` (with measured spots, problem hatching, suggested outline and legend), `V3OLayout` (editable), `V3Onb3` (intro).
- **Progress tracker**: `V3Optimize` (in progress), `V3OVerify` (completed).
- **Status pill**: `V3MRunning` (done, active, upcoming), `V3Paused` (paused).
- **Readout**: `V3Listening` ("Playing now"), `V3Paused` (room noise), `V3OAR`.
- **Hold-to-hear**: `V3Finding`.
- **Tab bar**: `V3Diagnose`, `V3Measure`, `V3Optimize` (active state differs per file).
- **Room and system switcher**: `V3Diagnose` and `V3Measure` (room over system), `V3Optimize` (system over room).
- **AR overlay**: `V3OAR`.
- **Segmented control**: `V3Start`, `V3MDetail`, `V3OLayout`.
- Not found: none of the components above is missing. Result and Finding show no tab bar.

## Known differences from the spec and the system (found at export)

- `#6B665D` (paused portrait fill, `V3Paused`) and `#3D2218` (`V3Finding`) are not in the colour table.
- `V3OVerify` labels the tracker "Moved / Verified"; the system and `V3Optimize` say "Move / Verify".
- The tab bar appears only on the three home screens; flows are shown without it.
- `V3OLayout`'s primary button leads into the Measure flow (`V3MGuide`).
- Undefined in the system: the Left / Right / Only one picker (`V3Start`), detected-object chips and the
  floor-plan inset (`V3OScan`), the Add subwoofer / Add a seat / Fix a wall chips (`V3OLayout`).
- The switcher and "Watch the sound live" have no target screen yet.
