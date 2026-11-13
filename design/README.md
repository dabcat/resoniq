# Resoniq design

| File | What it is |
|---|---|
| [`DESIGN_SPEC.md`](./DESIGN_SPEC.md) | Contexts, information architecture, every flow and screen, open questions |
| [`DESIGN_SYSTEM.md`](./DESIGN_SYSTEM.md) | Principles, colour, evidence tags, type, components, motion, voice, brand rules |
| [`tokens.json`](./tokens.json) | Design tokens: colour, frequency gradient, type, space, radius, size, motion, haptics |
| [`../ResoniqKit/Sources/ResoniqDesign`](../ResoniqKit/Sources/ResoniqDesign) | The same tokens for SwiftUI, the bundled fonts and the shared components ([module note](../docs/modules/ResoniqDesign.md)) |
| [`screens/`](./screens/README.md) | HTML mockups of every screen, used as templates for the SwiftUI screens |
| [`brand/`](./brand) | Mark, logo lockups and app icon (SVG, plus `AppIcon-1024.png`) |

The Swift tokens are written by hand from `tokens.json`; change both together.
The logo SVGs use live text in Instrument Sans; outline it before sending them to print.
