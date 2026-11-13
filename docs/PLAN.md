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
| — | Repo foundation: spec, design, vault, agent rules, screen templates | done | — | #1 |
| 0 | Setup: project, package, theme, fonts, icon, tab shell | done | [phase-0-setup](plans/phase-0-setup.md) | #2 |
| 1 | DSP core: signals, FFT, response, THD, noise floor, clipping | done | [phase-1-dsp](plans/phase-1-dsp.md) | #3 |
| 2 | Diagnose flow | done | [phase-2-diagnose](plans/phase-2-diagnose.md) | |
| 3 | Measure flow | done | [phase-3-measure](plans/phase-3-measure.md) | |
| 4 | Optimize: room scan and layout | done | [phase-4-room](plans/phase-4-room.md) | |
| 5 | Optimize: AR guidance and before/after | done | [phase-5-ar](plans/phase-5-ar.md) | |
| 6 | AI diagnostics and finish | active | [phase-6-ai-finish](plans/phase-6-ai-finish.md) | |

Phases 2 and 3 are one pull request (the review fixes for phase 2 were made on the phase 3 branch), and phases
4 to 6 followed on the same branch, so the PR cells for 2 to 6 stay empty until it is opened. "Done" means the
code and its tests exist and the screens run in the simulator; nothing has run on an iPhone, which the
[device checklist](device-checklist.md) is for. Phase 6 is still active: the intro, Settings and the rooms sheet
are built but not reachable from the app, and there is no privacy manifest ([phase 6 notes](plans/phase-6-ai-finish.md)).

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

- **Nothing has run on a device.** The real audio engine, microphone, RoomPlan, ARKit, haptics and every
  first-guess threshold are unverified; the simulator runs the same flows on simulated audio, a scripted scan
  and a scripted AR move. The steps, and which block calling a feature working, are in the
  [device checklist](device-checklist.md).
- **Built but not reachable.** The intro, Settings and the rooms and systems sheet exist and are shown only by
  debug screen names; Diagnose's Settings button and the room switcher do nothing yet
  ([App](modules/App.md)). There is no privacy manifest.
- **No training data** for the speaker-defect classifier. The Core ML slots ship empty and the report says
  nothing on a model's behalf; collecting recordings is planned in
  [the dataset plan](research/2026-11-13-defect-dataset-plan.md).
- **Sweep safety on vented speakers.** The measurement sweep starts at 10 Hz at the safe level; the owner has
  not confirmed that start for a vented speaker at high volume ([ResoniqDSP](modules/ResoniqDSP.md)).
- **Wording the owner has not confirmed.** Findings hedge in their headlines where the mockups do not; the
  layout guess says speakers were guessed where the mockup says they were spotted; the advisor's move is 40 cm
  where the mockup says 35 cm.
- **Undesigned states** (microphone denied, repeating, failed, not connected, quiet woofer, not assessed, worse
  and unchanged results, Fix a wall, manual room entry) are built from the design system's rules and listed as
  "no mockup" in the screens' headers; they are still to be reviewed against the canvas when designed.
