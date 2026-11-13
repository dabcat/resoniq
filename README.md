# Resoniq

A native iOS app that diagnoses speakers, measures how a system sounds at the seat, and guides speaker
placement with RoomPlan and AR. Everything runs on the device: no accounts, no backend, no network.

## Run it

Needs Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make test     # ResoniqKit tests on the Mac, a few seconds
make build    # generate Resoniq.xcodeproj and build for the iOS simulator
make run      # install and launch in the booted simulator
make help     # everything else
```

The Xcode project is generated from [`project.yml`](project.yml) and not committed. To build for a device, put
your team in `Config/Signing.local.xcconfig` (see [`Config/Signing.xcconfig`](Config/Signing.xcconfig)).

## Where things are

| Path | Holds |
|---|---|
| [`Resoniq/`](Resoniq) | The app target: SwiftUI screens and wiring, nothing that computes a result |
| [`ResoniqKit/`](ResoniqKit) | The Swift package: design, DSP, audio, diagnostics, room, store |
| [`design/`](design/README.md) | Design spec, design system, tokens, brand, and the [screen mockups](design/screens/README.md) |
| [`docs/`](docs/index.md) | The project's notes, also an Obsidian vault (open the folder as a vault) |
| [`CLAUDE.md`](CLAUDE.md) | The rules agents and people work by |
| [`.claude/skills/resoniq-stack/`](.claude/skills/resoniq-stack/SKILL.md) | The toolbox: what we use and how |

## Read next

| To learn | Read |
|---|---|
| What the product is | [Product spec](docs/PRODUCT_SPEC.md) |
| How the code is divided, and why | [Architecture](docs/ARCHITECTURE.md) |
| What is done and what is next | [Plan](docs/PLAN.md) |
| How it should look, sound and read | [Design system](design/DESIGN_SYSTEM.md), [design spec](design/DESIGN_SPEC.md) |
| Everything else | [Index of the notes](docs/index.md) |
