---
type: "module"
spec_module: "E"
phase: 6
status: "active"
tags:
  - "module"
---
# ResoniqDesign

Design tokens, bundled fonts, the product's icons and the shared SwiftUI components. Source of the values: [tokens.json](../../design/tokens.json); rules: [DESIGN_SYSTEM.md](../../design/DESIGN_SYSTEM.md). The only module that imports SwiftUI (checked with `grep -rn "import SwiftUI" ResoniqKit/Sources`: 36 files, all under `ResoniqDesign/`; the other modules import only Foundation, Accelerate, AVFoundation, CoreML, CoreMotion, SoundAnalysis, SwiftData, `RoomPlan` behind `#if canImport(RoomPlan)` and each other). It depends on no other module. The app maps Kit values onto these components in its `…Display.swift` files ([App](App.md)); a component takes plain inputs and decides nothing.

Paths below are relative to `ResoniqKit/Sources/ResoniqDesign/`.

## Public interface

### Tokens

| Symbol | Where | Holds |
|---|---|---|
| `ResoniqColor` | `Tokens/Tokens.swift:18` | The thirteen colours (`ink`, `panel`, `panelRaised`, `line`, `ivory`, `muted`, `lime`, `teal`, `indigo`, `signal`, `signalText`, `guide`, `disabled`) and the semantic aliases `action`, `onAction`, `deviation`, `suggestion`, `improved` |
| `ResoniqGradient` | `Tokens/Tokens.swift:41` | The frequency scale, vertical (portraits) and horizontal (curves) |
| `ResoniqSpace`, `ResoniqRadius`, `ResoniqSize` | `Tokens/Tokens.swift:55`, `:66`, `:73` | Spacing steps (`s1`…`s6`, `screenInset`, `panelPadding`), corner radii, control sizes (`touchMin` 44, `buttonHeight` 58) and stroke widths |
| `ResoniqMotion` | `Tokens/Tokens.swift:84` | Springs and curves (`press`, `settle`, `sheet`, `pop`, `enter`, `traceDraw`, `waiting`, `pulseRing`, `scan`, `buzz`) and `pressedScale` |
| `ResoniqFont` | `Tokens/Typography.swift:8` | One `Font` per type role (`display`, `title1`…`title3`, `headline`, `button`, `body`, `caption`, `capsLabel`, `readoutLarge`, `readoutMedium`, `axis`, …), `Tracking` in em, and `font(_:size:relativeTo:)` (:29) for a one-off size |
| `ResoniqFont` screen roles | `Tokens/ScreenType.swift:6` | `bodyMedium`, `bodySemibold`, `bodySmall`, `rowTitle`, `speakerName`, `captionSemibold`, `figure` |
| `ResoniqFont.Face` | `Tokens/Typography.swift:9` | The six bundled faces; the raw value is the PostScript name and the file name |
| `ResoniqFont.registerBundledFonts()` | `Tokens/Typography.swift:65` | Registers the faces for the process. Called once in `ResoniqApp.init`; returns the faces that failed |
| `ResoniqFont.licences()`, `ResoniqFontLicence` | `Tokens/FontLicences.swift:17`, `:4` | The two OFL licence texts bundled beside the fonts, for Settings → About |
| `ResoniqTitleSize`, `View.resoniqTitle(_:)` | `Tokens/ScreenType.swift:24`, `:55` | The screen title in `compact`, `small`, `medium`, `large` |
| `ResoniqInlineLinkStyle` | `Tokens/ScreenType.swift:64` | An inline link in a sentence, `primary` or `quiet` tone |
| `View.resoniqCapsLabel()` | `Tokens/Typography.swift:97` | Caps label |
| `View.resoniqTitleRise()`, `View.resoniqWaitingPulse(low:)` | `Components/Entrance.swift:36`, `:40` | The headline's entrance and the waiting dot's pulse; both stand still under Reduce Motion |

### Icons

`ResoniqIcon` (`Components/Icons.swift:4`) holds the mockups' own glyphs, drawn from their SVG paths: `diagnose`, `measure`, `optimize` (tab bar), `settings`, `chevronDown`, `check`, `speaker`, `back`, `arrowRight`, `directionArrow`. `ResoniqIconView` (`Components/Icons.swift:142`) draws one in the foreground style; it is decorative, the control that holds it carries the label.

### Components, by the flow that uses them

| Symbol | Where | Design system component | Used by |
|---|---|---|---|
| `View.resoniqPanel()` | `Components/Panel.swift:25` | Panel (also `resoniqPanel(insets:)` :28) | all |
| `ResoniqPrimaryButtonStyle` | `Components/Buttons.swift:12` | Primary button | all |
| `ResoniqSecondaryButtonStyle(.filled / .outlined)` | `Components/Buttons.swift:28` | Secondary button and its passive form | all |
| `ResoniqTextLinkStyle` | `Components/Buttons.swift:59` | Text link | all |
| `ResoniqIconButtonStyle(on: .panel / .overCamera)` | `Components/Buttons.swift:73` | Icon button | all |
| `ResoniqTabBar`, `ResoniqTabItem` | `Components/TabBar.swift:19`, `:3` | Tab bar, generic over the app's tab type | shell |
| `ResoniqContextSwitcher` | `Components/ContextSwitcher.swift:4` | Room and system switcher, in either order | each tab's home |
| `ResoniqEvidenceTag`, `ResoniqEvidenceKind` | `Components/EvidenceTag.swift:26`, `:4` | Evidence tag: glyph, name, basis | Diagnose, Measure |
| `ResoniqEvidenceMark` | `Components/EvidenceMark.swift:5` | The tag's dot alone, beside a sentence that explains it | Finding |
| `ResoniqStatusPill` | `Components/StatusPill.swift:7` | Status pill: done, active, upcoming, paused | Listening, Paused |
| `ResoniqSegmentedControl`, `ResoniqSegment` | `Components/SegmentedControl.swift:17`, `:3` | Left / Right / Only one | Aim |
| `ResoniqHoldToHear` | `Components/HoldToHear.swift:10` | Hold to hear (a toggle under VoiceOver) | Finding |
| `ResoniqReadout`, `ResoniqLevelBar` | `Components/Readout.swift:8`, `:97` | A labelled figure; a level against a mark | Listening, Paused |
| `SpeakerPortrait` | `Components/SpeakerPortrait.swift:170` | Speaker portrait: not heard, drawing, paused, deviation | Diagnose |
| `FrequencyRuler` | `Components/FrequencyRuler.swift:6` | Log-frequency axis beside a portrait; `fraction(forFrequency:)` (:34) | Diagnose |
| `RunOverlay` | `Components/RunOverlay.swift:89` | Three runs' traces overlaid, rough parts marked | Finding |
| `ResponseCurve` | `Components/ResponseCurve.swift:9` | Response curve: even band, labelled extremes, before trace | Measure, Before and after |
| `ChannelComparisonChart` | `Components/ChannelComparisonChart.swift:8` | Left and right on a decibel grid | Measure |
| `AverageBuildingCurve` | `Components/AverageBuildingCurve.swift:8` | The running average redrawing while a measurement continues | Measure |
| `SpotsDiagram` | `Components/SpotsDiagram.swift:68` | The three spots, in four states | Measure |
| `ResoniqValuesTable` | `Components/ResoniqValuesTable.swift:8` | The numbers table, one sentence per row for VoiceOver | The numbers |
| `ResoniqNumberedStep` | `Components/ResoniqNumberedStep.swift:6` | A numbered instruction row | Sit and aim |
| `SpectrumBars` | `Components/SpectrumBars.swift:35` | Live spectrum bars | Watch the sound live |
| `ResoniqLegendEntry` | `Components/ChartParts.swift:304` | One legend entry of a chart | Measure |
| `RoomPlanView`, `RoomPlanLegend`, `RoomPlanContent` | `Components/RoomPlanView.swift:157`, `:105`; `Components/RoomPlanContent.swift:11` | Room plan: walls, doors, windows, furniture, speakers, seat, measured spots, problem areas, a dashed suggestion | Optimize |
| `RoomPlanEditor`, `RoomPlanWallDistance` | `Components/RoomPlanEditor.swift:16`; `Components/RoomPlanDrawing.swift:4` | The plan with dragging, plus buttons for move and turn (the VoiceOver route) | Confirm layout |
| `ResoniqProgressTracker` | `Components/ResoniqProgressTracker.swift:42` | Scanned, Measured, Move, Verify | Optimize home, Before and after |
| `ResoniqChip` | `Components/ResoniqChip.swift:9` | Chips in three styles: `action` (takes a touch), `detected`, `measurement` | Confirm layout |
| `FloorPlanInset` | `Components/FloorPlanInset.swift:36` | The floor plan inset over the scan camera | Scan |
| `DirectionArrowInstruction` | `Components/ARGuidanceReadout.swift:264` | An arrow and one sentence | Scan |
| `ARToGoCard`, `ARStepPill`, `ARGuidanceReadout` | `Components/ARGuidanceReadout.swift:83`, `:108`, `:139` | The cards over the AR camera | AR guidance |
| `BeforeAfterRow` | `Components/BeforeAfterRow.swift:9` | A before and after value, or a plain unchanged row | Before and after |

`PreviewCurves` (`Components/ResponseCurve.swift:145`) is the mockups' curve for previews and the gallery. `ChartGeometry`, `RoomPlanGeometry` and `MarchingOutline` are internal.

## Fonts

Static faces are bundled, not the variable fonts: Instrument Sans Regular, Medium, SemiBold, Bold and IBM Plex Mono Regular, Medium, in `Resources/Fonts/` with both OFL licence files. A role names its face by PostScript name, so a weight never depends on how the system matches a family name. The fonts live in the package's resource bundle, which is why they are registered in code and not listed under `UIAppFonts`.

To add a face: put the `.ttf` in `Resources/Fonts/` named by its PostScript name and add a case to `ResoniqFont.Face`. The tests then cover it.

## Tests

`ResoniqKit/Tests/ResoniqDesignTests/`, run on the Mac by `make test`. They cover what can be computed without drawing:

- `FontTests`: every face registers, resolves to its own font (Core Text substitutes silently, so the resolved name is compared) and belongs to the family the design system names; both licences are in the bundle.
- `IconTests`: every icon's paths lie inside its view box.
- `FrequencyRulerTests`, `SpeakerPortraitTests`, `RunOverlayTests`: the portrait's and the ruler's mapping from frequency to position, the overlay's rough segments.
- `ChartGeometryTests` (curves, even-band segments, labels, spectrum bars, spots, the values table's sentences), `RoomPlanGeometryTests` (fitting a room to the view, metres and points), `OptimizeComponentTests` (tracker states, the scan inset's camera wedge, the before and after sentence, the direction arrow).

How a component looks has no automated test. It is checked against its mockup in the simulator (`make run SCREEN=<name>`, `make screenshot`) and in the app's component gallery (`make run` with `-gallery YES`, [App](App.md)).

## Known differences from the design files

- The active tab's icon is `ivory`, as in the mockups; [DESIGN_SYSTEM.md](../../design/DESIGN_SYSTEM.md) says `lime`.
- The switcher's headline in the mockups has −1% tracking, which is not a token; it is set without tracking.
- The accent and launch colours in the app's asset catalog repeat `lime` and `ink`, because an asset catalog cannot read Swift.
- Texts that the mockups write as confirmed ("Buzz at 70–110 Hz") are hedged where they come from the Kit ("Possible buzz at 80–110 Hz"); see [ResoniqDiagnostics](ResoniqDiagnostics.md). The components show whatever string they are given.
- Components for states with no mockup (denied, failed, repeating, the unfinished Optimize states) reuse the existing ones in the design system's voice; the screens say so in their file headers.

## Open questions

- Generate the Swift tokens from `tokens.json` or keep them hand-written?
- Whether the components pass VoiceOver, Dynamic Type up to accessibility sizes and Reduce Motion on a device: the attributes are in the code, nothing was checked on a phone ([device checklist](../device-checklist.md)).
