---
name: resoniq-stack
description: What Resoniq is built with and how to drive it - make targets, XcodeGen, ResoniqKit tests, the one simulator, agents and which model does what, screenshots, fonts, tokens, CI, where each kind of note goes. Use before building, running or testing the app, and before adding a file, target, dependency, token, font or note in this repo.
---

# Resoniq stack

The rules of the project are in [CLAUDE.md](../../../CLAUDE.md). This is the toolbox: what each tool is for
and the one way it is used here.

## What we use

| Tool | For | How |
|---|---|---|
| Swift 6, strict concurrency | All code | The app target is main-actor by default (`project.yml`); the Kit is not, so its APIs stay callable from anywhere |
| `ResoniqKit` (Swift package) | Everything that decides something | Six modules, each with a test target; map in [ARCHITECTURE.md](../../../docs/ARCHITECTURE.md), interfaces in [docs/modules/](../../../docs/modules/) |
| Swift Testing | Kit tests, on the Mac | `make test`, about five minutes (one test target at a time) |
| XcodeGen | The Xcode project | Edit `project.yml`, then `make project`. `Resoniq.xcodeproj` is generated and ignored by git |
| SwiftUI, iOS 26 minimum | Screens, in `Resoniq/Features/<Tab>/` | Built from the mockup in `design/screens/`, with `ResoniqDesign` tokens and components only |
| `make` | Every routine command | `make help` lists the targets |
| One iOS simulator | Running the app | The booted one. See below |
| GitHub Actions | Kit tests and a simulator build on each pull request | `.github/workflows/ci.yml` |
| Obsidian vault in `docs/` | Project knowledge | Start at [docs/index.md](../../../docs/index.md) |

No third-party Swift dependencies, no networking, no analytics.

## The loop

1. `make test` while writing Kit code. The test comes first.
2. `make build` before a pull request: generates the project and builds for the simulator, unsigned.
3. `make run` installs and launches in the simulator; `make run TAB=measure` (or `optimize`) opens a Debug
   build on that tab, and `make run SCREEN=<name>` opens one screen in a fixed state. The names are the
   `names` lists in `Resoniq/App/DebugScreens*.swift`.
4. `make screenshot` writes `.build/screenshot.png`. Read the image and compare it with the mockup before
   calling a screen done.
5. To run a whole flow unattended, launch with `xcrun simctl launch booted com.matovic.resoniq …` (`make`
   passes only `-initialTab` and `-screen`): `-screen measure-flow` (or `optimize-flow`, `app-flow`) with
   `-autostart YES` presses the start button and runs it to its result on simulated audio;
   `-simulatedNoise YES` adds the noise that pauses a run. Other arguments: `Resoniq/App/RootView.swift`,
   `AppComposition.swift`, `AudioEnvironment.swift`.

A build log worth keeping goes to `.build/`, which git ignores.

## Agents and models

At most 3 agents run in parallel. The strongest model plans and checks; cheaper models build.

| Work | Model |
|---|---|
| Architecture, a design that spans modules, a phase plan | Strongest available (Fable) |
| Checks: code review, verifying a finished task against its plan and mockup, a pull request before it is opened | Strongest available (Fable) |
| Hard implementation: DSP algorithms, concurrency, audio sessions, RoomPlan, AR, Core ML | Opus |
| Ordinary implementation: screens from mockups, components, small tests, mechanical edits, notes | Sonnet |
| Lookups: find a file, read a doc, list usages | Haiku |

The split is by task, so one feature is usually designed by the strongest model, built by a cheaper one from
that design, and checked by the strongest again. Pass `model` explicitly when spawning an agent. Parallel
agents that write code work in worktrees under `.claude/worktrees/`, removed once merged; an agent that only
reads or writes one new note can share the main tree.

## One simulator

Use the simulator that is already booted for everything, and leave the set of simulators as it is: `make`
targets default to `SIM=booted` and create nothing. If none is booted, boot an existing one
(`xcrun simctl list devices`, `xcrun simctl boot <name>`) or ask the owner which to use. The microphone,
LiDAR and AR are verified on a device, never in the simulator.

## Adding things

- **An app source file**: create it under `Resoniq/`, then `make project`. Folders are picked up whole.
- **A Kit module or dependency between modules**: `ResoniqKit/Package.swift`, then the product under
  `dependencies` in `project.yml`, then the module's note in `docs/modules/`.
- **A screen**: a view with plain inputs (display values and closures), a `…Display.swift` mapping from the
  Kit value, a container that reads the coordinator or the store, and a debug name: one `case` and one `names`
  entry in `DebugScreens+<Area>.swift`, with a fixture. Look at an existing screen of the same tab first.
- **A text that depends on a result**: in the Kit module's `…Text.swift`, never in a view.
- **A store model change**: a new `ResoniqSchemaV<n>` (move the typealiases), a migration stage and its test;
  [ResoniqStore](../../../docs/modules/ResoniqStore.md) says how.
- **A token**: `design/tokens.json` and `ResoniqKit/Sources/ResoniqDesign/Tokens/` in the same commit.
- **A shared component**: `ResoniqKit/Sources/ResoniqDesign/Components/`, listed in
  [the module note](../../../docs/modules/ResoniqDesign.md) with its `file:line`.
- **An icon from a mockup**: a case in `ResoniqIcon` with the SVG path converted to absolute coordinates;
  `IconTests` checks it stays inside its view box.
- **A font face**: the `.ttf` in `ResoniqDesign/Resources/Fonts/`, named by its PostScript name, and a case
  in `ResoniqFont.Face`.
- **An Info.plist key or a permission string**: `Resoniq/Resources/Info.plist`, written by hand, in the
  voice of the design system.
- **A signing team**: `Config/Signing.local.xcconfig` (ignored by git), one line `DEVELOPMENT_TEAM = …`.

## Where knowledge goes

| Kind | Place |
|---|---|
| A module's interface and tests | `docs/modules/<Module>.md` |
| A phase's tasks and their status | `docs/plans/phase-N-….md`, and the phase row in `docs/PLAN.md` |
| A measurement or investigation | `docs/research/YYYY-MM-DD-topic.md` |
| Knowledge from another repo or source | `docs/reference/` |
| A decision and its reason | The table in `docs/ARCHITECTURE.md` |

Every new note gets a line in [docs/index.md](../../../docs/index.md); the [README](../../../README.md) links
only to the entry points.

## Things that cost time once

- **A type used as a generic argument from the app target** (a tab enum, an identifier) may need
  `nonisolated` in front of it: under main-actor-by-default its `Hashable` conformance is isolated, and the
  compiler says "main actor-isolated conformance … cannot satisfy conformance requirement".
- **Fonts are named by PostScript name** (`InstrumentSans-SemiBold`), never by family plus `.weight()`. Use
  the roles in `ResoniqFont`.
- **Core Text substitutes a missing font silently.** A font test compares the name it resolved.
- **The asset catalog repeats two colours** (`AccentColor` = `lime`, `LaunchBackground` = `ink`). Change them
  with the tokens.
- **Driving taps in the simulator** needs AXe, which Homebrew cannot build until the Command Line Tools are
  updated. Until then, use `make run SCREEN=…` or `-autostart YES` and screenshot.
- **A Kit enum that gains a case breaks the app's exhaustive switches** (the `…Display.swift` files). Add the
  case there in the same change.
- **Parallel branches conflict in `DebugScreens.swift`.** Keep it to one line per provider; each branch adds
  its screens in its own `DebugScreens+<Area>.swift`.
- **The app target has no test target.** A decision worth testing belongs in the Kit.
- **A worktree agent starts on an old commit.** Its first command: `git fetch origin && git reset --hard
  origin/<the feature branch>`.
- **SourceKit reports "No such module 'ResoniqDesign'"** in app files until the project has been built once.
  Trust `make build`.
