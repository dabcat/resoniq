# Resoniq Design System

Version 0.2 · precision-instrument direction. Values live in [`tokens.json`](./tokens.json) and, for SwiftUI,
in [`swift/ResoniqTheme.swift`](./swift/ResoniqTheme.swift). Screens and flows are in
[`DESIGN_SPEC.md`](./DESIGN_SPEC.md). Brand assets are in [`brand/`](./brand).

## What it should feel like

A precision instrument made for people who have never used one. Calm, confident, a little warm.
The complexity stays inside the software.

1. **Show the thing itself.** Home screens are the user's speakers and the user's room, not menus about them.
2. **Colour means something.** Pitch has a colour scale; orange means "this deviates"; blue means
   "suggested, not yet tested"; lime means "act" or "confirmed". Nothing is coloured for decoration.
3. **Say how we know.** Every conclusion is tagged Measured, Inferred, Inconclusive or Estimate.
4. **Plain words first, numbers on request.** Headlines are sentences. Decibels live one tap deeper.
5. **Motion reports state.** Something moves only because the app is playing, listening, waiting or guiding.

## Colour

Dark theme only.

| Token | Hex | Use |
|---|---|---|
| `ink` | `#151412` | Background; text on accent fills |
| `panel` | `#1F1D1A` | Instrument panels, tab bar, secondary buttons |
| `panelRaised` | `#2E2B26` | Even band in charts, camera placeholder |
| `line` | `#3B3731` | Borders, grid, hairlines |
| `ivory` | `#F0EBE1` | Primary text; walls and objects in plans |
| `muted` | `#A9A398` | Secondary text, ruler ticks, "before" traces |
| `lime` | `#D8F27A` | Primary action, active tab, confirmed improvement |
| `signal` | `#FF5B2E` | Deviation: suspected defect, out-of-band response, noise |
| `signalText` | `#FF8157` | Signal colour for text on dark |
| `guide` | `#9CC9E8` | Suggestions, estimates, AR targets |
| `teal` | `#37C8C0` | Mid pitch; sound leaving a speaker |
| `indigo` | `#5B6CFF` | Bass pitch (graphics only) |

### The frequency scale

Pitch is coloured indigo (bass) → teal (mid) → lime (treble). It runs bottom-to-top on a speaker portrait
and left-to-right on a response curve, always against a real frequency axis. It is the only gradient in
the product.

### Rules

- Text on `lime` or `signal` fills is `ink`.
- `signal` is reserved for deviations. Never use it for buttons, tabs or decoration.
- `guide` marks anything not yet verified by a measurement.
- States never rely on colour alone: each also has an icon, a line style or words.
- Left and right channels are told apart by position and label first, then line style
  (left solid `guide`, right dashed `lime`) in overlay charts.

## Evidence tags

| Tag | Glyph | When |
|---|---|---|
| Measured | solid dot | Read directly from this session's recordings |
| Inferred | half-filled dot | Concluded from measurements; state the basis ("3 of 3 runs") |
| Inconclusive | hollow dot | Could not be decided; state why ("could be the phone's angle") |
| Estimate | `guide`-coloured label | Rough figure where measurement quality is limited (decay time) |

Never present an inferred defect as confirmed. No health scores.

## Typography

| Role | Family | Size / weight | Notes |
|---|---|---|---|
| Display | Instrument Sans | 36 / 600 | First-run headline |
| Title 1 | Instrument Sans | 34 / 600 | Screen headline, tracking −3% |
| Title 2 | Instrument Sans | 30 / 600 | Result headline |
| Title 3 | Instrument Sans | 26 / 600 | Sheet headline |
| Headline | Instrument Sans | 21 / 600 | Switcher, row titles |
| Button | Instrument Sans | 18 / 600 | |
| Body | Instrument Sans | 15–16 / 400–500 | Line height 1.4 |
| Caption | Instrument Sans | 13 / 400 | |
| Caps label | IBM Plex Mono | 11 / 400 | Uppercase, +8% tracking; panel and field labels |
| Readout | IBM Plex Mono | 34–46 / 500 | Live values, tracking −5% |
| Axis / units | IBM Plex Mono | 11–13 | Hz, dB, m, % |

Headlines are full sentences in sentence case, with a full stop. Every measured value is set in the
mono face. Support Dynamic Type up to `accessibility2`; headlines wrap rather than truncate.

## Space, shape, size

- Screen inset 24; content starts 60 below the top edge; rhythm in steps of 4.
- Radii: segment 10, control 14, panel 18, sheet 28, buttons and chips fully round.
- Touch targets at least 44. Primary button 58 tall.
- Strokes: hairline 1, measured trace 3, walls 3.

## Components

**Panel.** `panel` fill, 1 pt `line` border, radius 18, padding 14. Holds one visualisation or one group
of readings, usually headed by a caps label on the left and a unit or legend on the right.

**Primary button.** `lime` pill, `ink` label, 58 tall. One per screen, at the bottom. Scales to 0.97 on press.

**Secondary button.** `panel` pill with `ivory` label, or outlined pill for passive states
("Waiting for quiet, then I continue").

**Text link.** 15 pt, `muted`, underlined, 44 pt hit area. For the quieter alternative under a primary button.

**Icon button.** 44 pt circle in `panel` (or `ink` over camera).

**Segmented control.** `panel` track, radius 14; selected segment `ivory` with `ink` label.

**Room and system switcher.** Top-left of every tab: caps label (room) over headline (system) with a
chevron. On Optimize the order flips (system over room), because the room is the subject there.

**Tab bar.** Diagnose · Measure · Optimize. `panel` background, hairline on top. Active tab: `ivory`
label, 700, a 3 pt `lime` bar on its top edge and a `lime` icon. Settings sits behind the icon button at
the top right of Diagnose.

**Speaker portrait.** The signature graphic. Vertical log-frequency axis from 20 Hz (bottom) to 20 kHz
(top) with a ruler on the left; a symmetric shape whose width is the measured level; filled with the
frequency scale. States:
- *Not heard yet*: dashed `ivory` outline, slow opacity pulse.
- *Drawing*: filled up to the current frequency, `signal` sweep line at that height.
- *Paused*: fill switches to `disabled`.
- *Deviation*: the affected band is cut out and redrawn in `signal` with a ragged edge that trembles.
Findings are written beside the portrait at the height of the frequency they concern.

**Response curve.** Horizontal log-frequency axis; `panelRaised` band marks "even, ±3 dB"; the trace uses
the frequency scale; segments outside the band are overdrawn in `signal` with a dot and a mono label at
each extreme. "Before" traces are dashed `muted`.

**Room plan.** Top-down. Walls 3 pt `ivory`, windows a double line, door a dashed arc, furniture `muted`
outlines. Speakers are filled `ivory` squares, the seat a ringed dot. Measured spots are solid `ivory`
dots; a measured problem area is `signal` hatching; a suggested position is a dashed `guide` outline.
A legend states "Measured here" versus "Suggested, not yet tested".

**Progress tracker.** Scanned → Measured → Move → Verify, caps labels joined by 2 pt rules. Done `lime`,
current `guide` (pulsing), upcoming `line`.

**Readout.** Caps label, large mono value, unit in sans. Coloured `signalText` only while the value is
out of range.

**Status pill.** 30 pt tall. `lime` fill = done, `lime` outline with pulsing dot = active,
`line` outline = upcoming, `signal` fill = paused.

**Hold-to-hear.** 92 pt `signal` circle with a speaker glyph and an expanding ring. Plays the offending
frequency through the speaker only while held.

**AR overlay.** Target footprint: dashed, marching `guide` outline with a faint fill. Current footprint:
`ivory` outline. Remaining distance: `lime` mono readout and a `lime` progress bar. Rotation: `guide` arc
with a mono angle label.

## Motion

| Pattern | Meaning | Spec |
|---|---|---|
| Title rise | New screen | 12 pt up, 0.5 s |
| Trace draw | A result arrived | Curve draws once, 1.6 s |
| Sweep line | Tone is playing at this pitch | ±4 pt hover, 1.2 s loop |
| Tremble | This band deviates | ±1.4 pt, 0.09 s loop |
| Pulse ring | Active spot / marker | Scale to 2.6 and fade, 1.8 s |
| Sound arcs | Speaker is playing | Staggered opacity, 1.8 s |
| Waiting dot | App waits for the user or the room | Opacity 0.4–1, 1.2 s |
| Settle | Where something should move | Spring with slight overshoot |
| Marching outline | AR target | 1 s loop |
| Press | Touch feedback | Scale 0.97, 0.14 s |

- A loop runs only while what it describes is true.
- With Reduce Motion: loops stop, traces appear without drawing, nothing is hidden.
- Haptics are listed under `haptic` in the tokens; in AR, taps speed up as the speaker nears its target.

## Voice

- First person, calm, specific: "It got noisy, so I stopped."
- Say what will happen before asking for a permission.
- Hedge honestly: "may be buzzing", "should return", "could be the phone's angle".
- No jargon in headlines; units are fine in details.

## Accessibility

- Text contrast at least 4.5:1 (3:1 from 24 pt). `indigo` is never used for text.
- Every chart and illustration has one VoiceOver summary that states the finding.
- Icon-only controls are labelled. All flows work without colour, motion or haptics.

## Brand

- **Mark.** Seven stacked bands forming a speaker portrait, coloured with the frequency scale. One bass
  band sits out of line: the thing Resoniq finds. Files: `brand/resoniq-mark.svg`, `resoniq-mark-mono.svg`.
- **Wordmark.** "Resoniq" in Instrument Sans SemiBold, tracking −4.5%.
- **Lockup.** Mark left, wordmark right, cap height of the wordmark about 70% of the mark's height.
  Files: `brand/resoniq-logo-dark.svg`, `resoniq-logo-light.svg` (live text; outline before print).
- **App icon.** Mark on `ink`, full bleed. Files: `brand/resoniq-app-icon.svg`, `AppIcon-1024.png`.
- **Colour use.** Full-colour mark on `ink` or `panel`. On light or on `lime`, use the one-colour mark in `ink`.
- **Clear space.** Half the mark's width on every side. Minimum mark size 20 pt.
- Do not recolour the bands individually, straighten the offset band, add effects, or place the
  full-colour mark on a mid-tone or photographic background.
