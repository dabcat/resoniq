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
| [modules.base](modules.base) | Table of module and phase notes by status |

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
