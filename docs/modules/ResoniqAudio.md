---
type: "module"
spec_module: "A"
phase: 2
status: "active"
tags:
  - "module"
---
# ResoniqAudio

Plays the test signals and records them: the `AVAudioSession` and `AVAudioEngine` behind an `AudioIO` protocol, and the `MeasurementSession` state machine that measures the room's floor, plays the sweep three times, pauses for noise and splices, checks each recording and hands back the recordings. Also the "hold to hear" tone, microphone permission and whether the phone is steady. Decisions about the signal (levels, verdicts, the sweep itself) come from [ResoniqDSP](ResoniqDSP.md); this module times and records. Plan: [phase-2-diagnose.md](../plans/phase-2-diagnose.md).

Paths below are relative to `ResoniqKit/Sources/ResoniqAudio/`.

## Conventions

- **One sweep.** Every run plays `LogSweep.measurement(sampleRate:)` (10 Hz to 22 kHz over 4 s, at the DSP's safe level), through `MeasurementConfiguration.sweep(sampleRate:)` (`MeasurementConfiguration.swift:119`). Nothing here sets its range or length. A stream under 44.1 kHz fails the test before any sound (`MeasurementConfiguration.minimumSampleRate`, `MeasurementSession.swift:155`).
- **One clock.** Every wait (the floor, the quiet before resuming, the decay) is counted in captured samples on the IO's capture timeline, so a test on `SimulatedAudioIO` runs as fast as the arithmetic and gives the same answer as one in real time. `AudioIO.schedule` returns the capture position of a buffer's first sample; the route's own delay is measured from the recording.
- **Levels are dBFS RMS**, the DSP's one convention (`LevelMeter`): a full-scale sine reads −3.01 dBFS, and 107 "dB" on screen with `SoundLevel.approximateOffsetDecibels`. The on-screen figure is an estimate and decides nothing.
- **The run check** (`MeasurementSession.check`, `MeasurementSession.swift:458`): `RecordingQuality.assess`, where anything but `.valid` (`.corrupt` included) is `RunProblem.unusable`; then the recording is deconvolved and one that does not hold the whole sweep (`ImpulseResponse.capturesWholeSweep`) is `RunProblem.didNotArrive`. The deconvolved response is the authority on arrival: the live `ArrivalTracker` estimate only decides when the recorder stops listening. A bad run is repeated once; a second ends the test.
- **Isolation.** `MeasurementSession`, `TonePlayer` and the stillness monitors are `@MainActor`; the work per 100 ms block is well under a millisecond. Capture runs on the IO's threads; the run check runs off the main actor (`@concurrent`). Nothing runs on the render thread (`EngineAudioIO.swift:30`).

## Public interface

### The seam to the hardware

| Symbol | Where | Holds |
|---|---|---|
| `SpeakerChannel` | `AudioIO.swift:4` | `left`, `right`, `both` |
| `PlaybackMode` | `AudioIO.swift:12` | `once`, `loop`, `afterLoop` |
| `CapturedBlock` | `AudioIO.swift:22` | `position` on the capture timeline, `samples`, `init` (:30), `end` (:36) |
| `CaptureStream` | `AudioIO.swift:40` | `sampleRate`, `blocks` (ends with an `AudioIOError` on interruption or route change) |
| `AudioIOError` | `AudioIO.swift:54` | `interrupted`, `routeChanged`, `unavailable(String)`, `notRunning` |
| `AudioIO` | `AudioIO.swift:74` | `start()`, `schedule(_:on:mode:)`, `stopPlayback()`, `stop()` |
| `EngineAudioIO` | `EngineAudioIO.swift:35` | The real IO: `.playAndRecord`, mode `.measurement`, A2DP and AirPlay allowed, HFP not; `preferredSampleRate` (:37), `tapBufferSize` (:39), `schedulingLead` (:42) |
| `SimulatedAudioIO` | `SimulatedAudioIO.swift:114` | The IO for tests: a simulated speaker per channel, route delay, noise and bursts, real-time or immediate pacing; `Configuration` (:120), `fail(with:)` (:181) |
| `SimulatedSpeaker`, `SimulatedFilter`, `NoiseBurst` | `SimulatedAudioIO.swift:42`, `:5`, `:84` | What the simulated IO plays through and adds; `SimulatedSpeaker.bookshelf` (:68) |

### The test

| Symbol | Where | Holds |
|---|---|---|
| `MeasurementSession` | `MeasurementSession.swift:17` | `init(io:channel:permission:stillness:configuration:thresholds:)` (:70), `start()` (:87), `run()` (:95), `cancel()` (:106), `progressUpdates()` (:115), `state`, `progress`, `runCount`, `isRunning` |
| `MeasurementSession.State` | `MeasurementSession.swift:19` | `idle`, `measuringNoiseFloor`, `playing(run:note:)`, `paused(run:resumeFrequency:)`, `checking(run:)`, `finished(MeasurementResult)`, `failed(MeasurementFailure)`; `isFinal` (:33) |
| `MeasurementConfiguration` | `MeasurementConfiguration.swift:5` | Every timing of a test, 16 fields (:11–66), `init` (:68), `standard` (:110), `minimumSampleRate` (:115), `sweep(sampleRate:)` (:119) |
| `MeasurementResult` | `MeasurementTypes.swift:65` | `channel`, `sweep`, `noiseFloor`, `runs` |
| `RunRecording` | `MeasurementTypes.swift:42` | One run's samples (from `leadIn` before the sweep), `sampleRate`, `leadIn`, `arrivalDelay` (live estimate), `verdict`, `spliceCount`, `phoneMoved`, `attempt` |
| `MeasurementProgress` | `MeasurementTypes.swift:73` | What Listening and Paused show: run, frequency arriving, sweep fraction, room level, the "quiet enough" mark, input level and peak, clipping, phone steady, route delay |
| `RunProblem` | `MeasurementTypes.swift:4` | `unusable(RecordingVerdict)` (:7), `didNotArrive` (:11), `interruptedRepeatedly` (:14) |
| `RunNote` | `MeasurementTypes.swift:18` | `repeating(RunProblem)`, `restarted(RestartReason)` |
| `RestartReason` | `RunRecorder.swift:216` | `noiseTooEarly`, `timelineUnreliable` |
| `MeasurementFailure` | `MeasurementTypes.swift:26` | `permissionDenied`, `interrupted`, `routeChanged`, `recordingUnusable(RunProblem)`, `cancelled`, `audioUnavailable(String)` |
| `SweepNoiseDetector` | `SweepNoiseDetector.swift:22` | Room noise while the sweep plays: the strongest tone and its harmonics taken out, the rest against the floor's same bins; `init(noiseFloor:sweep:blockLength:thresholds:)` (:72), `assess(_:)` (:109), `Assessment` (:38) |
| `SweepSplicer.splice(_:_:crossfadeAt:crossfadeLength:)` | `SweepSplicer.swift:43` | Joins two takes of the sweep with a raised-cosine crossfade |
| `SoundLevel` | `SoundLevel.swift:4` | `dBFS` (RMS), `approximateOffsetDecibels` (:16), `approximateDecibels` (:26), `init(of:)` (:29) |

### Around the test

| Symbol | Where | Holds |
|---|---|---|
| `MicrophoneAccess`, `MicrophonePermission` | `MicrophonePermission.swift:6`, `:14` | Granted, denied, undetermined; `status`, `request()` |
| `SystemMicrophonePermission`, `SimulatedMicrophonePermission` | `MicrophonePermission.swift:36`, `:21` | `AVAudioApplication`, and a fixed answer for tests |
| `StillnessMonitor` | `StillnessMonitor.swift:12` | `isSteady`, `start()`, `stop()` |
| `MotionStillnessMonitor`, `ConstantStillnessMonitor` | `StillnessMonitor.swift:36`, `:20` | Core Motion, and a settable value for tests |
| `TonePlayer` | `TonePlayer.swift:14` | "Hold to hear": `start(frequency:on:)` (:38), `stop()` (:70), `stopAndWait()` (:81), `fadeDuration` (:16), `loopDurations` (:19) |

## Thresholds and constants

`MeasurementConfiguration.standard`. Times in seconds. The sweep's own values (10 Hz, 22 kHz, 4 s) are the DSP's (`LogSweep.measurement`).

| Field | Value | Note |
|---|---|---|
| `runCount` | 3 | From the plan |
| `blockDuration` | 0.1 | The block `NoiseGate` and steadiness are defined on |
| `settleDuration` | 0.2 | First guess |
| `noiseFloorDuration` | 1 | From the plan |
| `leadIn` | 0.05 | |
| `maximumRouteDelay` | 2.5 | First guess; AirPlay is documented at about 2 s |
| `decayHold` | 0.3 | First guess |
| `minimumTail` | `HarmonicDistortion.minimumTail` (0.205) | So the distortion floor can be measured; was 0.2 |
| `maximumDecay` | 1 | First guess |
| `resumeHold` | 0.5 | First guess |
| `resumeOverlap` | 0.4 | First guess; must hold guard + crossfade + fade in + delay margin |
| `noiseGuard` | 0.1 | One block |
| `crossfade` | 0.02 | First guess |
| `fadeIn` | 0.02 | The sweep's own fade |
| `delayMargin` | 0.1 | First guess |
| `maximumRestarts` | 3 | First guess |
| `MeasurementConfiguration.minimumSampleRate` | 44 100 Hz | What `LogSweep.measurement` requires |
| `SoundLevel.approximateOffsetDecibels` | 110 dB | Estimate, first guess; a quiet room seen at −75 dBFS RMS. A datasheet sensitivity would give 123 |
| `SweepNoiseDetector.analysisLowFrequency`, `analysisHighFrequency` | 100 Hz, 12 kHz | First guesses |
| `SweepNoiseDetector.excludedHarmonics` | 5 | First guess |
| `SweepNoiseDetector.reverberationAllowance` | 0.3 | First guess |
| `SweepNoiseDetector.mainLobeBins` | 6 | Blackman–Harris lobe plus two |
| `SweepNoiseDetector.presenceMarginDecibels` | 10 dB | First guess |
| `ArrivalTracker` (internal) | 100 Hz, 20 dB, 2 estimates, 64 kept | `CaptureTimeline.swift:45–51`; presence first guess |
| `EngineAudioIO.preferredSampleRate`, `tapBufferSize`, `schedulingLead` | 48 kHz, 4800, 0.1 | |
| `MotionStillnessMonitor` limits | 0.2 rad/s, 0.05 g, 0.5 s, 50 Hz | `StillnessMonitor.swift:39–46`; first guesses |
| `TonePlayer.fadeDuration`, `loopDurations` | 0.02, 0.1…0.25 | |

`SweepNoiseDetector` and the live gate are unaffected by the DSP's move to dBFS RMS: the detector compares a block's bins with the floor's same bins (a ratio), and adds that rise to the floor's broadband `LevelMeter` RMS, which was RMS before and after.

## Tests

`ResoniqKit/Tests/ResoniqAudioTests/`, run on the Mac by `make test`, all on `SimulatedAudioIO` with the app's own configuration (4 s sweeps).

- `MeasurementSessionTests`: a clean test deconvolves to the speaker within 0.5 dB; a 1.5 s route delay is waited for and measured; a noise burst pauses, resumes earlier in the sweep and splices cleanly; noise early restarts the run; endless noise stays paused until cancelled; a clipped run is repeated once, then fails; denied permission plays nothing; an interruption ends the test; a moving phone is noted; cancelling in every state releases everything; progress rises run by run; any block size; a stream under 44.1 kHz fails before any sound.
- `RecordingCheckTests`: a whole recording passes, a non-finite sample is `.unusable(.corrupt)`, a recording cut 0.3 s before the sweep's end is `.didNotArrive`.
- `SweepNoiseDetectorTests`: a quiet room is never too noisy while the sweep plays (three speakers, one with a buzz), the tone found follows the sweep, a burst is too noisy in exactly its blocks, without a sweep it is the plain gate.
- `SweepSplicerTests`, `SimulatedAudioIOTests`, `TonePlayerTests`.

The suite takes about 8 to 10 s.

## Limits

- `SweepNoiseDetector` cannot tell a steady tone near the sweep from the sweep, ignores rumble under 100 Hz, and counts a rattle that is not a harmonic as noise, so a badly rattling speaker can pause a test.
- The route delay must stay under `maximumRouteDelay`; a longer one is `didNotArrive`.
- The live arrival estimate is good to a fraction of a block; when it is early the recording can stop too soon. The run check catches a recording that misses the sweep's end, but a tail shorter than `minimumTail` is not a failure: the run is kept and its distortion is then not measurable.
- A route that runs under 44.1 kHz (Bluetooth hands-free) cannot be measured.
- `SoundLevel` is approximate: the microphone is not calibrated.

## Open questions

- Is 4 s right on a phone held at arm's length in a living room, or should the DSP's sweep be longer for signal-to-noise?
- Should a run whose tail is shorter than `HarmonicDistortion.minimumTail` be repeated rather than kept with unmeasurable distortion?
- Only on a real iPhone: the `.measurement` mode's actual processing on current models, the input's real latency and whether the host-clock mapping of the timeline holds, AirPlay and Bluetooth delays and their drift over a 4 s sweep, real clock offsets between output and input, interruptions and route changes as they really arrive, the sample rate a Bluetooth or AirPlay route settles on, the 110 dB on-screen offset, the stillness limits against a hand-held phone, and whether `SweepNoiseDetector`'s margins hold in a real room with a real speaker's harmonics.
