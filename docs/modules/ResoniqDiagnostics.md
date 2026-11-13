---
type: "module"
spec_module: "B"
phase: 2
status: "planned"
tags:
  - "module"
---
# ResoniqDiagnostics

Turns DSP results into findings. Each finding has a frequency range, an evidence tag (Measured, Inferred, Inconclusive, Estimate), its basis and a confidence statement. DSP rules first; SoundAnalysis and Core ML classifiers plug in behind a protocol.

## Public interface

Not written yet. Filled in when phase 2 starts: the types and functions other modules call, with `file:line`.

## Tests

Not written yet.

## Open questions

- Thresholds for a deviation that repeats across runs.
- Where the training recordings for the custom classifier come from.
