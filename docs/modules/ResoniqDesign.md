---
type: "module"
spec_module: "E"
phase: 0
status: "active"
tags:
  - "module"
---
# ResoniqDesign

Design tokens, bundled fonts and the shared SwiftUI components. Source of the values: [tokens.json](../../design/tokens.json); rules: [DESIGN_SYSTEM.md](../../design/DESIGN_SYSTEM.md). The only module that imports SwiftUI.

Paths below are relative to `ResoniqKit/Sources/ResoniqDesign/`.

## Public interface

### Tokens

| Symbol | Where | Holds |
|---|---|---|
| `ResoniqColor` | `Tokens/Tokens.swift:18` | The colour table and the semantic aliases (`action`, `deviation`, `suggestion`, `improved`) |
| `ResoniqGradient` | `Tokens/Tokens.swift:41` | The frequency scale, vertical (portraits) and horizontal (curves) |
| `ResoniqSpace`, `ResoniqRadius`, `ResoniqSize` | `Tokens/Tokens.swift:55`, `:66`, `:73` | Spacing steps, corner radii, control sizes and stroke widths |
| `ResoniqMotion` | `Tokens/Tokens.swift:84` | Springs, curves and `pressedScale` |
| `ResoniqFont` | `Tokens/Typography.swift:8` | One `Font` per type role (`title1`, `headline`, `capsLabel`, `readoutLarge`, …), `Tracking` in em, and `font(_:size:relativeTo:)` for a one-off size |
| `ResoniqFont.Face` | `Tokens/Typography.swift:9` | The six bundled faces; the raw value is the PostScript name and the file name |
| `ResoniqFont.registerBundledFonts()` | `Tokens/Typography.swift:65` | Registers the faces for the process. Called once in `ResoniqApp.init`; returns the faces that failed |

### Components

| Symbol | Where | Design system component |
|---|---|---|
| `View.resoniqPanel()` | `Components/Panel.swift:18` | Panel |
| `View.resoniqCapsLabel()` | `Tokens/Typography.swift:96` | Caps label |
| `ResoniqPrimaryButtonStyle` | `Components/Buttons.swift:12` | Primary button |
| `ResoniqSecondaryButtonStyle(.filled / .outlined)` | `Components/Buttons.swift:28` | Secondary button and its passive, outlined form |
| `ResoniqTextLinkStyle` | `Components/Buttons.swift:59` | Text link |
| `ResoniqIconButtonStyle(on: .panel / .overCamera)` | `Components/Buttons.swift:73` | Icon button |
| `ResoniqIcon`, `ResoniqIconView` | `Components/Icons.swift:4`, `:85` | The mockups' own glyphs (tab icons, settings, chevron), drawn from their SVG paths in the foreground style |
| `ResoniqTabBar`, `ResoniqTabItem` | `Components/TabBar.swift:19`, `:3` | Tab bar, generic over the app's tab type |
| `ResoniqContextSwitcher` | `Components/ContextSwitcher.swift:4` | Room and system switcher, in either order |

Still to come, each with the flow that first needs it: segmented control, speaker portrait, readout, status pill,
hold-to-hear (phase 2); response curve (phase 3); room plan, progress tracker (phase 4); AR overlay (phase 5).

## Fonts

Static faces are bundled, not the variable fonts: Instrument Sans Regular, Medium, SemiBold, Bold and IBM Plex
Mono Regular, Medium, in `Resources/Fonts/` with both OFL licence files. A role names its face by PostScript
name, so a weight never depends on how the system matches a family name. The fonts live in the package's
resource bundle, which is why they are registered in code and not listed under `UIAppFonts`.

To add a face: put the `.ttf` in `Resources/Fonts/` named by its PostScript name and add a case to
`ResoniqFont.Face`. The tests then cover it.

## Tests

`ResoniqKit/Tests/ResoniqDesignTests/`, run on the Mac by `make test`.

- `FontTests`: every face registers, resolves to its own font (Core Text substitutes silently, so the
  resolved name is compared) and belongs to the family the design system names; both licences are in the bundle.
- `IconTests`: every icon's paths lie inside its view box, which catches a mistyped coordinate.

Components have no automated tests. They are checked against the mockups in the simulator (`make run`,
`make screenshot`).

## Known differences from the design files

- The active tab's icon is `ivory`, as in the mockups; [DESIGN_SYSTEM.md](../../design/DESIGN_SYSTEM.md) says `lime`.
- The switcher's headline in the mockups has −1% tracking, which is not a token; it is set without tracking.
- The accent and launch colours in the app's asset catalog repeat `lime` and `ink`, because an asset catalog
  cannot read Swift.

## Open questions

- Generate the Swift tokens from `tokens.json` or keep them hand-written?
