# Resoniq Design System

Status: draft 0.1. Values live in [`tokens.json`](./tokens.json); this file explains how to use them.
Screens and flows are described in [`DESIGN_SPEC.md`](./DESIGN_SPEC.md).

## Character

Playful and fun, but trustworthy. Resoniq measures things, so numbers and verdicts must look precise;
everything around them can be warm, bouncy and a little silly.

- **Reso does the talking.** A round speaker character with two eyes guides the user. Copy is in first
  person ("I play a rising tone, then listen").
- **Plain words first.** "The woofer may be buzzing", not "THD exceeds threshold". Technical data is one tap away.
- **Something always moves.** If the app is playing or listening, the screen shows it: a woofer thumps,
  rings ripple, bars dance.
- **Honest verdicts.** Colour and motion never overstate a result. A suspected defect is "suspected".

## Colour

Dark theme only. One ground, one primary accent, a small supporting cast.

| Token | Hex | Use |
|---|---|---|
| `ink` | `#15132B` | App background |
| `inkDeep` | `#0D0C1C` | Backdrop behind sheets |
| `surface` | `#211E3F` | Cards, tab bar, secondary buttons |
| `surfaceRaised` | `#2E2A55` | Fills inside a surface, tertiary buttons |
| `line` | `#3A3566` | Hairlines, inactive dots, dashed outlines |
| `text` | `#F6F4FF` | Primary text |
| `textMuted` | `#BDB8DB` | Secondary text |
| `sun` | `#FFC83D` | Primary action, active tab, right channel |
| `sky` | `#7CC8FF` | Links, left channel |
| `lilac` | `#B69CFF` | Reso's outline, rooms, completed steps |
| `mint` | `#7CE8B8` | Healthy / confirmed |
| `coral` | `#FF8A7A` | Suspected defect |

Rules:

- Text on any accent fill is `onAccent` (`#15132B`). Never white on an accent.
- Left channel is always `sky`, right channel always `sun`. They differ in hue and lightness, and are always
  labelled L / R as well.
- Result states are never colour-only: each pairs a colour with an icon and words.
  Healthy = mint + check. Suspected = coral + waveform. Environmental = sun + label. Inconclusive = outlined, muted.
- No gradients. Depth comes from flat layers and the button's solid bottom edge.

## Typography

| Role | Family | Size / weight |
|---|---|---|
| Hero | SF Pro Rounded | 40 / 800 |
| Title 1 | SF Pro Rounded | 34 / 800 |
| Title 2 | SF Pro Rounded | 28 / 800 |
| Title 3 (card titles) | SF Pro Rounded | 21 / 800 |
| Button | SF Pro Rounded | 19 / 800 |
| Chip, link | SF Pro Rounded | 16 / 700 |
| Eyebrow | SF Pro Rounded | 14 / 800, uppercase, +8% tracking |
| Body large | SF Pro Text | 17 / 400, line height 1.45 |
| Body | SF Pro Text | 16 / 400–600 |
| Caption | SF Pro Text | 13 / 400 |
| Readout | SF Mono | 13–64 / 500 |

- Headings use sentence case and may end with a full stop.
- Every measured value (Hz, dB, m, %) is set in the mono face so digits do not jump while updating.
- Support Dynamic Type; headings scale up to the `accessibility2` size, then wrap.

## Shape, spacing, size

- Screen inset 24. Vertical rhythm in steps of 4 (see `space`).
- Radii are generous: chip 16, button 20, row 22, card 28–32, hero illustration 36.
- Minimum touch target 44. Primary button 58 tall, chips 48, list rows 64.

## Components

**Primary button.** `sun` fill, `onAccent` label, radius 20, height 58, with a solid 5 pt bottom edge in
`sunShadow`. On press it moves down 4 pt and the edge shrinks to 1 pt (`motion.duration.press`), with a
medium impact haptic. One per screen.

**Secondary button.** `surface` fill, `text` label, same size, no bottom edge. Back buttons in flows are the
58 × 58 square version with a chevron.

**Text button.** Rounded 16 / 700 in `textMuted` ("Skip", "Not now"). 44 pt tall hit area.

**Chip.** Height 48, radius 16, 2 pt border. Unselected: `surface` fill, `line` border. Selected: `sun` fill
and border, `onAccent` label. Selecting pops with `spring.pop` and a selection haptic.

**Card.** `surface`, radius 28. The single most important action on a screen may use a `sun` card with
radius 32. Cards scale to 0.97 while pressed (`spring.press`).

**Result badge.** Pill, height 40, accent fill, icon + two or three words ("Buzz at 90 Hz"). Appears with
`spring.pop`.

**Progress dots.** 8 pt dots, 6 pt gap. Done = `lilac`, upcoming = `line`, current = 28 × 8 `sun` pill that
pops in.

**Room and system switcher.** A pill at the top left of every tab: room icon in a `lilac` circle, room name
over system name, chevron. Opens the Rooms and systems sheet.

**Tab bar.** Three tabs: Diagnose, Optimize, Settings. `surface` background with a `line` hairline on top.
The active tab's icon sits in a 60 × 30 `sun` pill that pops in on change; its label is `text` / 800.
Inactive tabs are `textMuted` / 700.

**Sheet.** `ink` panel with 36 pt top corners and a grabber over an `inkDeep` backdrop. Enters with
`spring.sheet`.

**Reso.** Outer ring: `surfaceRaised` fill, `lilac` stroke. Inner cone: `sun`. Eyes and smile: `onAccent`.
Sizes: 200 (hero), 72 (inline), 48 (header). Reso never covers content and never appears on result screens
that report a suspected defect.

## Motion

Motion explains what the app is doing; it is never the only carrier of meaning.

| Pattern | When | Spec |
|---|---|---|
| Pop | Badges, checks, active tab pill, selected chip | `spring.pop`, from scale 0.5 |
| Press | Cards, rows, chips | scale 0.97 with `spring.press` |
| Button press | Primary button | 4 pt down, 0.12 s |
| Rise | Screen text entering | 16 pt up, 0.6 s, siblings staggered 0.08 s |
| Bob / blink | Reso idle | 3 s float, blink every 4 s |
| Thump | A speaker is playing | scale 1.0–1.1, 0.7 s loop |
| Ripple | Sound leaving a source, mic listening | rings scale 0.7–1.7 and fade, 2.4 s |
| Equalizer | Live level | bars scale 0.3–1.0, staggered |
| Settle | Speakers moving to a recommended position | `spring.settle` with slight overshoot |

Rules:

- Loops run only while the thing they describe is true (thump only while a tone plays).
- At most one looping animation in the user's focus per screen, plus Reso.
- With Reduce Motion on: loops stop, springs become 0.2 s cross-fades, nothing is hidden.
- Haptics accompany the moments listed under `haptic` in the tokens, and nothing else.

## Voice

- First person, short, friendly: "Can I listen in?", "All set, let's listen".
- Say what happens next before asking for permission.
- Never claim a confirmed defect. Use "may", "suspected", "likely the room".
- No jargon in headlines. Units and numbers are fine in details.

## Accessibility

- Text contrast at least 4.5:1 (3:1 from 24 pt). All listed text/background pairs pass.
- VoiceOver labels on every icon-only control; illustrations get one summary label.
- All flows are usable without colour, motion or sound cues alone.
