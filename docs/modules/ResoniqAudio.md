---
type: "module"
spec_module: "A"
phase: 2
status: "planned"
tags:
  - "module"
---
# ResoniqAudio

Audio I/O around `ResoniqDSP`: session configuration with voice processing and gain control off, playing a test signal, recording it in sync, and the measurement session state machine (listening, paused for noise, resumed, done).

## Public interface

Not written yet. Filled in when phase 2 starts: the types and functions other modules call, with `file:line`.

## Tests

Not written yet.

## Open questions

- Which `AVAudioSession` mode gives the least processed microphone signal on current iPhones (`.measurement` is the starting point).
- How to align playback and recording without a loopback.
