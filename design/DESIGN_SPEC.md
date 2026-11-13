# Resoniq Design Spec

Status: draft 0.1. Visual rules are in [`DESIGN_SYSTEM.md`](./DESIGN_SYSTEM.md), values in
[`tokens.json`](./tokens.json). The working mockups live on the Resoniq design canvas.

## Information architecture

```
Onboarding (first launch only, skippable at every step)
└── Tab bar
    ├── Diagnose      Check Speaker, Analyze Sound, history for the current room
    ├── Optimize      Scan room, room layout, acoustics, AR placement, before / after
    └── Settings      Rooms and systems, microphone, units, about, privacy
```

A **room and system switcher** sits at the top of Diagnose and Optimize. Everything the user measures is
filed under the currently selected room and sound system.

## Rooms and sound systems

- A user can have many **rooms**. A room has a name, an optional scan (dimensions, layout) and its
  acoustic measurements.
- A room can hold many **sound systems** (for example "Stereo pair" and "TV soundbar"). A system has a
  name, a type and its speaker checks.
- System types: stereo pair, stereo + subwoofer, soundbar, single speaker, surround.
- Nothing about make or model is asked. Names are free text with sensible defaults.
- Exactly one room + system is current. Switching is done from the switcher pill; the choice persists
  between launches.
- The app works with zero setup: if the user skips onboarding, a default room ("My room") and system
  ("My speakers") are created silently and can be renamed later.

### Rooms and systems sheet

- Grouped by room. Room header: icon, name, dimensions if scanned ("Not scanned yet" otherwise).
- System rows: icon by type, name, one-line status ("Checked today · 1 thing to look at").
- Current system has a `sun` border and a check that pops in.
- "Add a sound system here" under each room; "Add a room" at the bottom.
- Rename and delete live behind swipe actions and in Settings.

## Onboarding

Five screens, each with progress dots and Skip. No account, no questionnaire; only the last step asks for
anything, and it is optional.

| # | Screen | Purpose | Hero animation | Primary action |
|---|---|---|---|---|
| 1 | Welcome | Meet Reso, set the tone | Reso bobs and blinks, rings ripple, small shapes drift | Let's go |
| 2 | Diagnose | Explain the speaker check | Woofer thumps, tone wave travels, "Buzz at 90 Hz" and "Tweeter fine" badges pop | Next |
| 3 | Optimize | Explain room tuning | Top-down room: L and R speakers spring into their outlines, seat ripples, "Sweet spot" pops | Next |
| 4 | Microphone | Prime the system permission | Mic bobs between dancing level bars, privacy badge pops | Allow microphone |
| 5 | Room and system | Name the first setup | Small Reso; chips pop when selected | All set, let's listen |

Behaviour:

- Skip on any screen goes straight to the Diagnose tab with the default room and system.
- "Allow microphone" triggers the iOS prompt. "Not now" continues; the prompt is offered again when the
  first test starts.
- Camera permission is not requested in onboarding. It is requested the first time a room scan starts.
- Step 5 preselects "Living room" and "Stereo pair". One choice per group.
- Onboarding is shown once. It can be replayed from Settings.
- Swiping left / right moves between steps 1–3.

## Diagnose tab

- Header: room and system switcher, small Reso.
- Title: "What shall we check today?"
- **Check Speaker** — large `sun` card with a thumping woofer. Starts the guided test.
- **Analyze Sound** — `surface` card with live level bars. Opens the spectrum analyzer.
- **In this room** — the latest results for the current system, each with a result icon; "History" opens
  the full list.

## Optimize tab

To be designed in the new look. Flow: scan room (or enter by hand) → confirm layout → measure → placement
suggestions → AR guidance → re-measure and compare. First-pass screens for this flow exist on the canvas
in the earlier visual style and define content and order.

## Settings tab

To be designed. Contents: rooms and systems management, microphone status, units (metric / imperial),
replay onboarding, privacy statement, about.

## Open questions

- Does Reso keep that name?
- Light theme: needed for MVP or later?
- Should Optimize be locked until a room exists, or start with the scan directly?
