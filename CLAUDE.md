# Resoniq — rules for agents

Resoniq is a native iOS app that diagnoses speakers, measures how a system sounds at the seat, and guides
speaker placement with RoomPlan and AR. Everything runs on the device: no accounts, no backend, no network.

Read first: `docs/index.md` (map of the notes), the `resoniq-stack` skill (the tools and how we use them), `docs/ARCHITECTURE.md` (modules and decisions), `docs/PLAN.md`
(phases and status). The product is defined in `docs/PRODUCT_SPEC.md`, the look in `design/DESIGN_SYSTEM.md`,
the screens in `design/DESIGN_SPEC.md`.

## What must stay true

- **The Kit decides, screens show.** Signals, DSP, findings, room geometry and placement live in `ResoniqKit`
  and are tested on the Mac. A threshold or conversion has one definition there. A view never computes a result.
- **DSP first, AI second.** A finding rests on a measurement. Model output can add to it, never replace it.
- **Say how we know.** Every finding carries an evidence tag (Measured, Inferred, Inconclusive, Estimate) and
  its basis. No health scores, and never state a suspected defect as confirmed.
- **Screens come from the mockups.** Build each screen from its file in `design/screens/` (layout, copy, SVG
  paths) with `ResoniqDesign` tokens and components. A literal colour, font size or radius in a feature view is a
  defect. For a state with no mockup, follow `design/DESIGN_SYSTEM.md` and say so in the PR.
- **Safe signals.** Test signals stay at a level that cannot damage a driver; recordings are checked for
  clipping and noise before they are analysed.
- **Offline and private.** No networking code, no analytics, no third-party SDKs without the owner's say.

## RoomPlan and ARKit

The sibling repo `~/Projects/iosar` (RoomScan) already solved scanning, the room model and AR sessions. Before
writing any RoomPlan, ARKit or RealityKit code, read `docs/reference/iosar-roomplan-arkit.md` and the iosar
files it names, and port the pattern instead of inventing one. Never edit iosar from here.

## Workflow

- Work starts on a branch from `main` (or from the PR it depends on), goes through a pull request, and is
  merged by the owner. Never push to `main`.
- A phase gets a plan note in `docs/plans/` before code. A finished task is marked done in that note in the
  same commit, and `docs/PLAN.md` gets the PR number.
- `docs/` is an Obsidian vault. New knowledge goes there as a note with frontmatter (`docs/index.md` lists the
  types): a module's interface in `docs/modules/`, a measurement in `docs/research/`. Update the note in the
  same PR as the code it describes.
- At most 3 agents at a time. The strongest model does architecture and checks, cheaper models build: the
  table is in the `resoniq-stack` skill ("Agents and models"). Parallel agents work in worktrees under
  `.claude/worktrees/`, removed once merged.
- Write the test first for Kit code. Run `make test` (Mac, seconds) while working and `make build` before a PR.
  Anything that needs a microphone, LiDAR or AR is verified on a device; say in the PR what was and was not.
- The Xcode project is generated: edit `project.yml`, run `make project`, never commit `*.xcodeproj`.

## Skills to load

| When | Skills |
|---|---|
| Any Swift change | `write-swift`, `axiom:axiom-swift` |
| SwiftUI screens and components | `axiom:axiom-swiftui`, `axiom:axiom-design`, `ios-design` |
| Audio capture, playback, sessions | `axiom:axiom-media` |
| Concurrency, actors, Sendable, audio threads | `axiom:axiom-concurrency` |
| SwiftData and files | `axiom:axiom-data` |
| RoomPlan, ARKit, RealityKit | `axiom:axiom-graphics`, then `docs/reference/iosar-roomplan-arkit.md` |
| Core ML, SoundAnalysis | `axiom:axiom-ai` |
| Tests | `axiom:axiom-testing` |
| Build, signing, project generation | `axiom:axiom-build` |
| Performance, memory, energy | `axiom:axiom-performance` |
| Accessibility | `axiom:axiom-accessibility` |
| Notes in `docs/` | `obsidian:obsidian-markdown`, `obsidian:obsidian-bases` |
| Before saying work is done | `superpowers:verification-before-completion` |
