---
type: "plan"
phase: 6
status: "done"
tags:
  - "plan/phase-6"
---
# Phase 6 · AI diagnostics and finish

Goal: the parts that make the app complete for a first user: the model-based helpers behind their protocols,
the intro, Settings, rooms and systems, the remaining states, and an accessibility pass.

## AI: what is real and what is a slot

The rule stays "DSP first, AI second": a model's output adds to a finding and never replaces a measurement.

| Piece | State after this phase |
|---|---|
| **Naming the interference** (SoundAnalysis) | Built. When a run is paused for noise, or a recording is judged too noisy, Apple's built-in sound classifier names what it heard ("It sounds like someone talking."), tagged `inferred`, with its confidence. It runs on the recording already captured; nothing is uploaded. |
| **Features for a custom model** | Built. Log-mel spectrogram and the DSP features a classifier would take, computed in the Kit and tested. |
| **Speaker-defect classifier** (Core ML) | A slot. The protocol, the loader and the way its output joins a report exist and are tested with a stand-in model. No trained model ships: there is no dataset of defective loudspeakers ([research note](../research/2026-11-13-audio-datasets.md)). Until one exists the report says nothing on the model's behalf. |
| **Anomaly model** | A slot behind the same protocol, with the same honesty. |

Rules:

- A classifier result never changes a `measured` finding. It may add an `inferred` line or support an existing
  `inferred` finding, and it always states its basis ("sound classifier, 82 %").
- Below a stated confidence nothing is said.
- With no model loaded the app behaves exactly as it does today.

## Tasks

| # | Task | Module | Model | Status |
|---|---|---|---|---|
| 1 | `SoundClassifying` protocol; SoundAnalysis implementation over a buffer; mapping of labels to plain interference kinds and sentences; use in the too-noisy and paused paths | Diagnostics | Opus | done |
| 2 | Log-mel features; `DefectClassifying` protocol; Core ML loader that finds no model and says so; joining a classifier's output to a `SpeakerReport` under the rules above; a note on how the first dataset will be collected with the app's own recordings | Diagnostics, docs | Opus | done |
| 3 | Intro screens (three, skippable) leading into the first test | App | Sonnet | done |
| 4 | Settings (what the app stores, delete data, keep or drop recordings, about, licences) and the rooms and systems sheet behind the switcher | App, Store | Sonnet | done |
| 5 | Remaining states from the design spec: level too low or clipping, phone moved during a run, all speakers healthy, no improvement, subwoofer suggestion | App | Sonnet | done |
| 6 | Accessibility pass (VoiceOver summaries, Dynamic Type to accessibility2, Reduce Motion, contrast) and a privacy manifest | App | Sonnet, checked by Fable | done in code; VoiceOver on a device is for the owner |
| 7 | Final review of the whole app; device checklist for the owner | — | Fable | done |

Done when: `make test` and `make build` pass, every screen in the design spec exists, and the device checklist
lists what the owner must verify on an iPhone.

## Notes

**What shipped as a slot.** The defect classifier and the anomaly model are slots: the protocol, the Core ML loader that finds no model and says so, the log-mel features and the rules that join a model's output to a report exist and are tested with a stand-in. No trained model ships, so a report says nothing on a model's behalf. The first dataset's plan is in [research](../research/2026-11-13-defect-dataset-plan.md). The sound classifier does run: when a run pauses or is judged too noisy the app names what it heard, tagged `inferred`, with its confidence, from the audio already captured.

**Finishing work.**

- The intro is shown on first launch (`IntroGate`), "Try it on a speaker" opens the first test, Settings opens
  from the icon button on Diagnose, and the switcher on every tab opens the rooms and systems sheet.
- Remaining states: the Level reading says what to do when a run is too quiet or clips; a run taken while the
  phone moved is noted on the result and stored with it; a noisy pause names what the sound classifier heard,
  with its confidence; two dated seat measurements can be compared; a single speaker or a soundbar gets its own
  Aim screen. The Optimize states (worse, unchanged, subwoofer) existed already.
- Accessibility pass, in code: one spoken summary per chart, announcements for pause, resume, failure and
  finish, Dynamic Type handling to `accessibility2`, Reduce Motion in every loop, 44 pt targets. A unit test
  computes the contrast of every text and background pair in use; all pass WCAG AA. What needs a device with
  VoiceOver is in the [device checklist](../device-checklist.md).
- Privacy manifest: no tracking, no collected data, two required-reason declarations (UserDefaults, system
  uptime). The repository contains no networking code.
- The Release configuration did not compile (previews used debug-only fixtures). It is fixed, and CI now builds
  Release as well as Debug.

**Final review.** An independent review of phases 2 to 6 found eleven defects, the worst being unsupported
"improved" claims on Before and after. All were fixed with a test that failed first where a test is possible:

- A change inside the measurement's repeatability is "unchanged"; the verdict is built from the row that
  changed and never says "back" outside the even band; a grid of 704 before and after cases checks that the
  verdict, the rows and the note agree.
- After "Put the speaker back" the baseline is the measurement that matches the room's current layout, and the
  same move is not offered again. A rescan or an edit while a move is open closes it.
- AR alignment uses two marked points and refuses when they disagree with the plan by more than 10 cm; one
  point plus the camera's heading swung the target by up to 18 cm. What is stored is where the speaker was
  marked, not the suggested spot.
- The app's own sweep is no longer named as music after a pause on slow routes; listening for the room's floor
  and waiting for a still phone both have an upper limit; three spots that may be one position say so; the room
  is blamed only when the feature is narrow or the spots disagree, and the headline is hedged.
- The decisions that lived in the app's Optimize coordinator moved into `ResoniqStore` with tests, because the
  app target has no tests of its own.

**Open until the owner decides.** Everything in the [device checklist](../device-checklist.md): nothing has run
on an iPhone. Trained models need real recordings of known-good and defective speakers (see Open risks in
[PLAN](../PLAN.md)). The measurement sweep starts at 10 Hz at −12 dBFS so that 20 Hz is accurate; whether that
is comfortable for vented speakers at high volume is the owner's call.
