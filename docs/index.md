---
type: "index"
tags:
  - "index"
---
# Resoniq notes

`docs/` is an Obsidian vault (open this folder as a vault) and plain Markdown on GitHub. Links are relative
Markdown links, so they work in both. Design files live outside the vault, in [`design/`](../design/README.md).

## Start here

| Note | Holds |
|---|---|
| [PRODUCT_SPEC.md](PRODUCT_SPEC.md) | What the product is: features, AI models, DSP engine, scope |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Modules, their boundaries, and the decisions behind them |
| [PLAN.md](PLAN.md) | Phases, their status, and the PR that delivered each |
| [notes.base](notes.base) | Every note in the vault, grouped by type |
| [modules.base](modules.base) | Table of module and phase notes by status |

## All notes

**Modules** ([ARCHITECTURE.md](ARCHITECTURE.md) has the map):
[ResoniqDesign](modules/ResoniqDesign.md) ·
[ResoniqDSP](modules/ResoniqDSP.md) ·
[ResoniqAudio](modules/ResoniqAudio.md) ·
[ResoniqDiagnostics](modules/ResoniqDiagnostics.md) ·
[ResoniqRoom](modules/ResoniqRoom.md) ·
[ResoniqStore](modules/ResoniqStore.md)

**Plans:** [Phase 0 · Setup](plans/phase-0-setup.md) · [Phase 1 · DSP core](plans/phase-1-dsp.md) · [Phase 2 · Diagnose](plans/phase-2-diagnose.md) · [Phase 3 · Measure](plans/phase-3-measure.md) · [Phase 4 · Room](plans/phase-4-room.md) · [Phase 5 · AR](plans/phase-5-ar.md) · [Phase 6 · AI and finish](plans/phase-6-ai-finish.md)

**Research:** [Audio datasets for testing the AI models](research/2026-11-13-audio-datasets.md)

**Reference:** [RoomPlan and ARKit lessons from RoomScan](reference/iosar-roomplan-arkit.md)

## Outside the vault

| File | Holds |
|---|---|
| [README](../README.md) | How to build and run, and the map of the repository |
| [CLAUDE.md](../CLAUDE.md) | The rules agents and people work by |
| [resoniq-stack skill](../.claude/skills/resoniq-stack/SKILL.md) | The toolbox: what we use and how |
| [Design system](../design/DESIGN_SYSTEM.md) | Colour, type, components, motion, voice, brand |
| [Design spec](../design/DESIGN_SPEC.md) | Every flow and screen |
| [Screen mockups](../design/screens/README.md) | The HTML templates the SwiftUI screens are built from |
| [Tokens](../design/tokens.json) | The design values, mirrored in `ResoniqDesign` |

## Folders

| Folder | Holds | Note `type` |
|---|---|---|
| [modules/](modules/) | One note per ResoniqKit module: purpose, public interface, tests, open questions | `module` |
| [plans/](plans/) | One detailed plan per phase, written when the phase starts | `plan` |
| [research/](research/) | Dated measurements and investigations (`YYYY-MM-DD-topic.md`) | `research` |
| [reference/](reference/) | Knowledge brought in from elsewhere, e.g. RoomPlan and ARKit patterns from the RoomScan repo | `reference` |

## Conventions

- Every note starts with frontmatter: `type`, `tags`, and for modules and plans `status`
  (`planned`, `active`, `done`) and `phase`.
- A note states facts about the code with `file:line` or a symbol name. When a note and the code disagree,
  the code wins; fix the note in the same PR.
- A finished plan item is marked done in its plan note in the same commit as the work.
- A new note gets a line under "All notes" above, in the same commit.
