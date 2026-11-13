---
type: "plan-index"
tags:
  - "plan"
---
# Development plan

Seven phases. Each phase is one or more PRs, gets its own detailed note in [plans/](plans/) when it starts, and
is marked here when its PR merges. Diagnose is the first complete flow because the spec asks that a user can
launch the app and test a speaker immediately.

## Progress

| # | Phase | Status | Plan | PR |
|---|---|---|---|---|
| — | Repo foundation: spec, design, vault, agent rules, screen templates | in review | — | #1 |
| 0 | Setup: project, package, theme, fonts, icon, tab shell | active | [phase-0-setup](plans/phase-0-setup.md) | |
| 1 | DSP core: signals, FFT, response, THD, noise floor, clipping | planned | | |
| 2 | Diagnose flow | planned | | |
| 3 | Measure flow | planned | | |
| 4 | Optimize: room scan and layout | planned | | |
| 5 | Optimize: AR guidance and before/after | planned | | |
| 6 | AI diagnostics and finish | planned | | |

## Phases

**0 · Setup.** The app builds and launches in the simulator with three empty tabs in the design system's look;
`swift test` passes on the Mac; `make` wraps the common commands.

**1 · DSP core.** `ResoniqDSP`, no UI: logarithmic sweep and tone generation, windowed FFT, frequency response
by deconvolution, harmonic distortion, noise floor, clipping and invalid-recording detection, 1/3-octave
smoothing. Every function is tested against a synthetic signal with a known answer.

**2 · Diagnose.** `ResoniqAudio` measurement session (play, record, pause on noise, resume), the speaker portrait
component, then the screens: Aim → Listening → Paused → Result → Finding → Diagnose home. Rooms and systems in
`ResoniqStore`. First DSP rules in `ResoniqDiagnostics` with evidence tags. Needs a physical iPhone to verify.

**3 · Measure.** Three-spot capture with stillness detection, response curve component, Measure home, Sit and
aim, Three spots, The numbers, live spectrum.

**4 · Optimize: room.** RoomPlan scan, conversion to the room model, Confirm layout (plan and 3D), manual room
entry without LiDAR, room plan component. Starts from [the RoomScan reference](reference/iosar-roomplan-arkit.md).

**5 · Optimize: AR.** Placement recommendations from measurements and geometry, AR guidance overlay, before and
after comparison, subwoofer placement.

**6 · AI and finish.** SoundAnalysis noise gate (may move earlier if phase 2 needs it), custom classifier and
anomaly model behind the classifier protocol, intro screens, Settings, the unfinished states listed in the
design spec, accessibility pass.

## Open risks

- **No training data** for the speaker-defect classifier. Phase 6 needs recordings of known-good and defective
  speakers; collecting them can start during phase 2 using the app's own recordings.
- **Device-only verification.** Phases 2–5 cannot be verified in the simulator; phases 4–5 need LiDAR.
- **Undesigned states** (microphone denied, clipping, phone moved, Settings, manual room entry, no improvement):
  built from the design system's rules, then reviewed against the canvas when designed.
