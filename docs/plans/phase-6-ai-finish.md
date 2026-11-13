---
type: "plan"
phase: 6
status: "active"
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
| 3 | Intro screens (three, skippable) leading into the first test | App | Sonnet | screens built; not shown at launch |
| 4 | Settings (what the app stores, delete data, keep or drop recordings, about, licences) and the rooms and systems sheet behind the switcher | App, Store | Sonnet | screens built; not reachable from the app |
| 5 | Remaining states from the design spec: level too low or clipping, phone moved during a run, all speakers healthy, no improvement, subwoofer suggestion | App | Sonnet | partly: see notes |
| 6 | Accessibility pass (VoiceOver summaries, Dynamic Type to accessibility2, Reduce Motion, contrast) and a privacy manifest | App | Sonnet, checked by Fable | partly: attributes in code, no pass recorded, no privacy manifest |
| 7 | Final review of the whole app; device checklist for the owner | — | Fable | device checklist written; final review not determined |

Done when: `make test` and `make build` pass, every screen in the design spec exists, and the device checklist
lists what the owner must verify on an iPhone.

## Notes

**What shipped as a slot.** The defect classifier and the anomaly model are slots: the protocol, the Core ML loader that finds no model and says so, the log-mel features and the rules that join a model's output to a report exist and are tested with a stand-in. No trained model ships, so a report says nothing on a model's behalf. The first dataset's plan is in [research](../research/2026-11-13-defect-dataset-plan.md). The sound classifier does run: when a run pauses or is judged too noisy the app names what it heard, tagged `inferred`, with its confidence, from the audio already captured.

**Gaps found in this pass (read from the code).**

- The intro (task 3) is built as three pages with their illustrations and `IntroGate` keeps the flag, but `RootView` never reads the gate, so a new user never sees it.
- Settings and the rooms and systems sheet (task 4) are built (what is stored, delete results, delete everything, the intro again, About with licences; rename, add, delete with counts), but the Settings button on Diagnose home does nothing (`onSettings: {}`) and the room and system switcher has an empty action. Both are reachable through the debug names only.
- Remaining states (task 5): level too low or clipping, all speakers healthy, and the Optimize states (worse and unchanged; the subwoofer chip on Confirm layout and the advisor's subwoofer suggestions) exist. "Phone moved during a run" is only the live "Steady" or "Moving" reading; `RunRecording.phoneMoved` is recorded and nothing reads it.
- Accessibility (task 6): labels, values, Dynamic Type handling and Reduce Motion are in the components and screens; no pass over a full test is recorded and nothing was checked with VoiceOver on a device. No privacy manifest is in the target.

**Open until the owner decides.** Whether the final review (task 7) is still to be done is not determined from the code; the device checklist is [device-checklist](../device-checklist.md). Trained models need real recordings of known-good and defective speakers (see Open risks in [PLAN](../PLAN.md)).
