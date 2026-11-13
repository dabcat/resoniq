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
| 1 | `SoundClassifying` protocol; SoundAnalysis implementation over a buffer; mapping of labels to plain interference kinds and sentences; use in the too-noisy and paused paths | Diagnostics | Opus | todo |
| 2 | Log-mel features; `DefectClassifying` protocol; Core ML loader that finds no model and says so; joining a classifier's output to a `SpeakerReport` under the rules above; a note on how the first dataset will be collected with the app's own recordings | Diagnostics, docs | Opus | todo |
| 3 | Intro screens (three, skippable) leading into the first test | App | Sonnet | todo |
| 4 | Settings (what the app stores, delete data, keep or drop recordings, about, licences) and the rooms and systems sheet behind the switcher | App, Store | Sonnet | todo |
| 5 | Remaining states from the design spec: level too low or clipping, phone moved during a run, all speakers healthy, no improvement, subwoofer suggestion | App | Sonnet | todo |
| 6 | Accessibility pass (VoiceOver summaries, Dynamic Type to accessibility2, Reduce Motion, contrast) and a privacy manifest | App | Sonnet, checked by Fable | todo |
| 7 | Final review of the whole app; device checklist for the owner | — | Fable | todo |

Done when: `make test` and `make build` pass, every screen in the design spec exists, and the device checklist
lists what the owner must verify on an iPhone.
