---
type: "module"
spec_module: "A"
phase: 6
status: "active"
tags:
  - "module"
---
# ResoniqAudio

Plays the test signals and records them: the `AVAudioSession` and `AVAudioEngine` behind an `AudioIO` protocol, and the `MeasurementSession` state machine that measures the room's floor, plays the sweep three times, pauses for noise and splices, checks each recording and hands back the recordings. Also the seat measurement (`SeatMeasurementSession`: the floor once, then three spots, each channel's sweep at each), the live spectrum (`LiveSpectrum`), the "hold to hear" tone, microphone permission and whether the phone is steady. Both sessions share one run machinery (`RunPerformer`, `FloorListener`). Decisions about the signal (levels, verdicts, the sweep itself, the decay) come from [ResoniqDSP](ResoniqDSP.md); this module times and records. Plans: [phase-2-diagnose.md](../plans/phase-2-diagnose.md), [phase-3-measure.md](../plans/phase-3-measure.md).

Paths below are relative to `ResoniqKit/Sources/ResoniqAudio/`.

## Conventions

- **One sweep.** Every run plays `LogSweep.measurement(sampleRate:)` (10 Hz to 22 kHz over 4 s, at the DSP's safe level), through `MeasurementConfiguration.sweep(sampleRate:)` (`MeasurementConfiguration.swift:144`). Nothing here sets its range or length. A stream under 44.1 kHz fails the test before any sound (`MeasurementConfiguration.minimumSampleRate`, `MeasurementConfiguration.swift:140`, checked in `RunPerformer.swift:331`).
- **One clock.** Every wait (the floor, the quiet before resuming, the decay) is counted in captured samples on the IO's capture timeline, so a test on `SimulatedAudioIO` runs as fast as the arithmetic and gives the same answer as one in real time. `AudioIO.schedule` returns the capture position of a buffer's first sample; the route's own delay is measured from the recording.
- **Levels are dBFS RMS**, the DSP's one convention (`LevelMeter`): a full-scale sine reads −3.01 dBFS, and 107 "dB" on screen with `SoundLevel.approximateOffsetDecibels`. The on-screen figure is an estimate and decides nothing.
- **The run check** (`RunPerformer.check`, `RunPerformer.swift:274`, and `inspect` (:285), which also gives the deconvolved delay; `MeasurementSession.check` forwards to it): `RecordingQuality.assess`, where anything but `.valid` (`.corrupt` included) is `RunProblem.unusable`; then the recording is deconvolved and one that does not hold the whole sweep (`ImpulseResponse.capturesWholeSweep`) is `RunProblem.didNotArrive`. The deconvolved response is the authority on arrival: the live `ArrivalTracker` estimate only decides when the recorder stops listening. A bad run is repeated once; a second ends the test.
- **One run machinery.** `FloorListener` (`RunPerformer.swift:11`) listens for the floor; `RunPerformer` (`RunPerformer.swift:58`) plays one sweep on one channel from its first block to a checked `RunRecording` (start, pause, resume and splice through `RunRecorder`, restarts, repeat once). `MeasurementSession` makes one per run; `SeatMeasurementSession` one per channel per spot. Both sessions own the stream, the states and the progress. The extraction was proven behaviour-preserving by the unchanged phase 2 tests and a characterisation digest of six scenarios (identical states, progress and recordings before and after).
- **The seat's tail.** `MeasurementConfiguration.seat` (`SeatMeasurementTypes.swift:136`) keeps 2 s of recording after the sweep's end arrives (`minimumTail`), for `Decay` and the room window, with `maximumDecay` 3 s so the longest route delay still leaves time for it.
- **Isolation.** `MeasurementSession`, `SeatMeasurementSession`, `TonePlayer` and the stillness monitors are `@MainActor`; the work per 100 ms block is well under a millisecond. Capture runs on the IO's threads; the run check runs off the main actor (`@concurrent`). `LiveSpectrum` analyses in a `@concurrent` task that owns the stream and hands each finished `MagnitudeResponse` to the consumer through an `AsyncStream` continuation. Nothing runs on the render thread (`EngineAudioIO.swift:38`).

## Public interface

### The seam to the hardware

| Symbol | Where | Holds |
|---|---|---|
| `SpeakerChannel` | `AudioIO.swift:4` | `left`, `right`, `both` |
| `PlaybackMode` | `AudioIO.swift:12` | `once`, `loop`, `afterLoop` |
| `CapturedBlock` | `AudioIO.swift:22` | `position` on the capture timeline, `samples`, `init` (:30), `end` (:36) |
| `CaptureStream` | `AudioIO.swift:40` | `sampleRate`, `blocks` (ends with an `AudioIOError` on interruption or route change) |
| `AudioOutputRoute` | `AudioIO.swift:54` | Where the sound goes: `kind` (`builtInReceiver`, `builtInSpeaker`, `wired`, `bluetooth`, `airPlay`, `other`), `name`, `isPhone`, `simulatedSpeakers` (:82) |
| `AudioIOError` | `AudioIO.swift:86` | `interrupted`, `routeChanged`, `unavailable(String)`, `notRunning` |
| `AudioIO` | `AudioIO.swift:106` | `start()`, `schedule(_:on:mode:)`, `stopPlayback()`, `stop()`, `outputRoute` (:121; nil by default, :126) |
| `EngineAudioIO` | `EngineAudioIO.swift:44` | The real IO: `.playAndRecord`, mode `.measurement`, A2DP and AirPlay allowed, HFP not; one session owner (an activation generation); scheduling from the host clock, appended after queued audio; `preferredSampleRate` (:46), `tapBufferSize` (:48), `schedulingLead` (:51), `stopFade` (:55), `outputRoute` (:133) |
| `SimulatedAudioIO` | `SimulatedAudioIO.swift:145` | The IO for tests: a simulated speaker per channel, route delay, noise and bursts, an optional room, an output route, real-time or immediate pacing (the sleep is injectable, internal init); refuses to schedule before the first block, as the engine does; `Configuration` (:136, `room` :153, `outputRoute` :155), `fail(with:)` (:216), `setRouteDelay(_:)` (:222), `currentSpot` (:227), `moveToSpot(_:)` (:232) |
| `SimulatedRoom` | `SimulatedRoom.swift:16` | Room modes (`Mode` :18: frequency, Q, level per spot; `decayTime(sampleRate:)` :35, `q(forDecay:frequency:sampleRate:)` :41), `rightOffsetDecibels` (:54), a comb tail with `reverberationTime` (:56) and `reverberationLevel` (:58), `combDelays` (:50), `spotCount` (:69), `livingRoom` (:74), `magnitude(at:spot:channel:sampleRate:)` (:102): the exact response a test compares with |
| `SimulatedSpeaker`, `SimulatedFilter`, `NoiseBurst` | `SimulatedAudioIO.swift:42`, `:5`, `:115` | What the simulated IO plays through and adds; `SimulatedSpeaker.Rattle` (:58, non-harmonic noise in proportion to the signal in a band), `SimulatedSpeaker.bookshelf` (:84), `SimulatedSpeaker.buzzingBookshelf` (:102, the simulator's left speaker: a cubic defect of 100 at 100–160 Hz, about 19 % THD at 130 Hz and over 10 % from about 100 to 160 Hz with the measurement sweep, so the demo ends on "Possible buzz at 100–160 Hz"; the earlier cubic 40 peaked at 10.7 % over only 0.15 octave, under the diagnosis's 1/6, and read "Sounds healthy."; pinned by `DemoSpeakerTests`) |

### The test

| Symbol | Where | Holds |
|---|---|---|
| `MeasurementSession` | `MeasurementSession.swift:17` | `init(io:channel:permission:stillness:configuration:thresholds:)` (:70), `start()` (:101), `run()` (:109), `cancel()` (:122), `progressUpdates()` (:131), `state`, `progress`, `runCount`, `isRunning`; `check` (:392) forwards to `RunPerformer.check` |
| `MeasurementSession.State` | `MeasurementSession.swift:19` | `idle`, `measuringNoiseFloor`, `playing(run:note:)`, `paused(run:resumeFrequency:)`, `checking(run:)`, `finished(MeasurementResult)`, `failed(MeasurementFailure)`; `isFinal` (:33) |
| `MeasurementConfiguration` | `MeasurementConfiguration.swift:5` | Every timing of a test, 21 fields, among them `maximumFloorWait` (:26, the longest listen for a floor), `maximumPauses`, `maximumPauseWait`, `sweepTiedTolerance` (:78), `maximumSpliceMisalignment` (:83); `init` (:85), `standard` (:135), `seat` (`SeatMeasurementTypes.swift:136`), `minimumSampleRate` (:140), `sweep(sampleRate:)` (:49) |
| `MeasurementResult` | `MeasurementTypes.swift:80` | `channel`, `sweep`, `noiseFloor`, `runs` |
| `RunRecording` | `MeasurementTypes.swift:47` | One run's samples (from `leadIn` before the sweep), `sampleRate`, `leadIn`, `arrivalDelay` (live estimate), `verdict`, `spliceCount`, `phoneMoved`, `attempt`, `sweepTiedSound` (:70, the frequencies where sound tied to the sweep was heard), `takeOffsets` (:73, each spliced take's misalignment, samples), `measuredDelay` (:76, deconvolved) |
| `MeasurementProgress` | `MeasurementTypes.swift:88` | What Listening and Paused show: run, frequency arriving, sweep fraction, room level, the "quiet enough" mark, input level and peak, clipping, phone steady, route delay |
| `RunProblem` | `MeasurementTypes.swift:4` | `unusable(RecordingVerdict)` (:7), `didNotArrive` (:11), `interruptedRepeatedly` (:14) |
| `RunNote` | `MeasurementTypes.swift:18` | `repeating(RunProblem)`, `restarted(RestartReason)` |
| `RestartReason` | `RunRecorder.swift:335` | `noiseTooEarly`, `timelineUnreliable` |
| `MeasurementFailure` | `MeasurementTypes.swift:26` | `permissionDenied`, `interrupted`, `routeChanged`, `recordingUnusable(RunProblem)`, `cancelled`, `audioUnavailable(String)`, `tooNoisy` (:41; no resume within `maximumPauseWait`, or no floor within `maximumFloorWait`), `phoneNeverStill` (:45, new: the seat measurement's phone never held still within `SeatMeasurementSession.maximumStillnessWait`), `speakersNotConnected(AudioOutputRoute)` |
| `SweepNoiseDetector` | `SweepNoiseDetector.swift:22` | Room noise while the sweep plays: the strongest tone and its harmonics taken out, the rest against the floor's same bins; `init(noiseFloor:sweep:blockLength:thresholds:)` (:72), `assess(_:)` (:114), `Assessment` (:43) |
| `SweepSplicer.splice(_:_:crossfadeAt:crossfadeLength:)` | `SweepSplicer.swift:43` | Joins two takes of the sweep with a raised-cosine crossfade |
| `SoundLevel` | `SoundLevel.swift:4` | `dBFS` (RMS), `approximateOffsetDecibels` (:16), `approximateDecibels` (:26), `init(of:)` (:29) |

### The seat measurement and the live spectrum

| Symbol | Where | Holds |
|---|---|---|
| `SeatMeasurementSession` | `SeatMeasurementSession.swift:21` | `init(io:channels:permission:stillness:configuration:thresholds:)` (:95; `channels` `[.left, .right]` or `[.both]`, configuration `.seat`), `start()` (:134), `run()` (:142), `cancel()` (:155), `skipToResult()` (:166), `progressUpdates()` (:175), `state`, `progress`, `channels`, `spotCount`, `isRunning`; `stillnessHold`, `movementTimeout`, `maximumStillnessWait`, `capturedHold` (:51–64) |
| `SeatMeasurementSession.State` | `SeatMeasurementSession.swift:23` | `idle`, `measuringNoiseFloor`, `waitingForStillness(spot:)`, `playing(spot:channel:note:)`, `paused(spot:channel:resumeFrequency:)`, `checking(spot:channel:)`, `spotCaptured(spot:)` (lasts `capturedHold`), `finished(SeatMeasurementResult)`, `failed(MeasurementFailure)`; `isFinal` (:41) |
| `SeatSpot` | `SeatMeasurementTypes.swift:5` | `seat`, `left`, `right`; `index` (:11) |
| `SeatSpotRecording` | `SeatMeasurementTypes.swift:20` | `spot`, `recordings` per channel (`RunRecording.run` is the channel's place in the order), `phoneMoved`, `movementDetected`; `recording(for:)` (:41) |
| `SeatMeasurementResult` | `SeatMeasurementTypes.swift:46` | `channels`, `sweep`, `noiseFloor`, `spots`; `isComplete` (:55) |
| `SeatMeasurementProgress` | `SeatMeasurementTypes.swift:59` | `spot`, `spotsCaptured`, `spotCount`, `channel` (nil while waiting), `frequency`, `sweepFraction`, `roomLevel`, `quietEnoughLevel`, `isRoomQuiet`, `inputLevel`, `inputPeakDecibels`, `isClipping`, `isPhoneSteady`, `stillness` (0–1 of the hold while waiting), `routeDelay` |
| `SpotAwareStillnessMonitor` | `SeatMeasurementTypes.swift:122` | A `StillnessMonitor` told `willWaitForStillness(at:)` each time a spot is waited for |
| `SimulatedStillnessMonitor` | `SimulatedStillnessMonitor.swift:14` | Acts out "moved, then still" before every spot after the first, immediate (`movingReads`) or real-time (`moveDuration`) pacing; `detectsMovement` (:27), `onMove` (:29, wire to `SimulatedAudioIO.moveToSpot`), `moves` |
| `LiveSpectrum` | `LiveSpectrum.swift:19` | `init(io:)` (:36), `bands()` (:42): an `AsyncStream<MagnitudeResponse>` of third-octave levels (dBFS RMS, 20 Hz–20 kHz, 31 bands); `smoothingCoefficient(time:)` (:73), `smoothed(previous:current:)` (:78) |

| `SeatMeasurementSession.captured`, `capturedSpots` | `SeatMeasurementSession.swift:85`, `:88` | The spots captured so far with the floor and sweep, updated at each `spotCaptured` (nil before the floor, then empty spots), so the app analyses a spot while the next is measured; at the end it equals the result |
| `SeatWaitPhase`, `SeatMeasurementProgress.wait` | `SeatMeasurementTypes.swift:102`, `:90` | While a spot is waited for: `waitingForMove` (not yet seen moving; never at the first spot), `settling`, `still`; once moved it never returns to `waitingForMove` |
| `SeatSpot.spacing` | `SeatMeasurementTypes.swift:16` | 0.30 m, the one spacing the instruction and the plan's spot markers read |

### Naming the noise and the session's words

| Symbol | Where | Holds |
|---|---|---|
| `CapturedAudio` | `CapturedAudio.swift:3` | `samples`, `sampleRate`, `sweepPlaying`, `duration`; `pausedDuration`, `minimumDuration` (1.5 s, one classifier window), `sweepDecayAllowance` (0.5 s) |
| `pausedAudio()` | `MeasurementSession.swift:70`, `SeatMeasurementSession.swift:96` | While `paused` for noise: the latest audio of the pause (a ring of `CapturedAudio.pausedDuration`, emptied at each new pause), `sweepPlaying` false; nil otherwise, and nil until `minimumDuration` has been kept. The first block of the pause, the route's delay (`maximumRouteDelay` while unknown) and `sweepDecayAllowance` are not kept (`PausedAudioKeeper.sweepArrival`): what was already sent to the speakers keeps arriving after playback stops, and the app's own sweep over a 1 s AirPlay-class route was named "music or a TV, 83 %" |
| `noisyRecording` | `MeasurementSession.swift:66`, `SeatMeasurementSession.swift:92` | What to classify when noise ended or spoiled a run: the paused audio at `failed(.tooNoisy)`, or the recording whose check said too noisy (`sweepPlaying` true); the latest wins. The app hands it to `InterferenceAdvisor` (diagnostics) |
| `SeatSessionText` | `SessionText.swift:48` | Three spots' sentences from the session's state: `instruction(for:wait:channels:)` (:83; one sentence per wait phase), `moveInstruction(to:)`, `waitingLine`, `playingLine`, `pausedHeadline`, `pausedSentence`, `noticeTitle`/`noticeText` (`RunNote`), `failureHeadline`/`failureBody`/`inconclusiveBasis` (`MeasurementFailure`), `spotName`, `speakerWord` |
| `ReadingText` | `SessionText.swift:9` | The live readings: `frequencyReading` ("1.02" "kHz"), `room` ("Quiet · 34 dB"), `decibels`, `spokenRoom`, `phone`, `barFraction` over `roomNoiseScaleDecibels` (70 dB) |

**Between spots** the phone must first be seen moving, then be still for `stillnessHold`; the first spot only needs it still. If no movement is reported within `movementTimeout`, the spot is captured once the phone is still and `movementDetected` is false (the app passes it to `SpotAnalyzer`, and the seat result says when that may mean one position). A phone that never holds still for `stillnessHold` within `maximumStillnessWait` ends the measurement as `phoneNeverStill`. In both sessions, a room that gives no steady, quiet enough floor within `maximumFloorWait` ends it as `tooNoisy`, before any sound.

**An output route that cannot be told** (`AudioIO.outputRoute` nil) is measured, and nothing is said about the route; only a route known to be the phone's own is refused (`MeasurementOpening.open`). A spot whose recording is bad twice fails the measurement (`recordingUnusable`), as in Diagnose. `skipToResult()` finishes with the spots already captured (a spot in progress is dropped); before the floor is known it is `failed(.cancelled)`.

### Playing the test sound from another device (phase 7)

The user plays a WAV file on their own system and the phone only listens. Plan: [phase-7-external-playback.md](../plans/phase-7-external-playback.md). The file module lives here, not in `ResoniqDSP`, because its gaps are set by `MeasurementConfiguration`'s recorded tail.

| Symbol | Where | Holds |
|---|---|---|
| `TestSoundFile` | `TestSoundFile.swift:68` | `Kind` (`speakerTest(SpeakerChannel)`, `seat([.left, .right] or [.both])`, :70), `init(kind:)` (:119), `layout` (:173), `channels()` (:190), `data()` (:218, 44-byte RIFF header and 24-bit little-endian PCM), `write(to:)` (:266), `quantised(_:)` (:277), `suggestedFileName` (:284), `summary` (:287), `sweepChannels` (:166), `allKinds` (:138) |
| `TestSoundFile` timing | `TestSoundFile.swift:85–153` | `toneGap(for:)` (:85), `identify(secondsAfterTone:)` (:97, the kind and sweep index for a time after the tone), `gap(for:)` (:128), `kind(forSpacing:)` (:144), `recordedTail(for:)` (:153, the tail the sessions keep, the one definition the gaps are checked against) |
| `TestSoundLayout` | `TestSoundFile.swift:5` | `Sweep` (offset, channel, count, :7), `Tone` (:17), `sampleRate`, `tone`, `sweeps`, `totalSamples` (:23–28), `duration` (:31), `spacing` (:34) |
| `ExternalMeasurementSession` | `ExternalMeasurementSession.swift:27` | `@MainActor @Observable`. `State` (:29): `idle`, `measuringNoiseFloor`, `waitingForSound`, `hearing(run:)`, `checking(run:)`, `needsAnotherPlay(have:reason:)`, `finished(MeasurementResult)`, `failed(ExternalMeasurementFailure)`; `init(io:channel:permission:stillness:configuration:thresholds:)` (:88), `file` (:59), `start()` (:106), `run()` (:114), `cancel()` (:126), `progressUpdates()` (:135), `state`, `progress` |
| `ExternalSeatMeasurementSession` | `ExternalSeatMeasurementSession.swift:23` | `State` (:25): `idle`, `measuringNoiseFloor`, `waitingForStillness(spot:)`, `waitingForSound(spot:)`, `hearing(spot:channel:)`, `checking(spot:channel:)`, `needsAnotherPlay(spot:reason:)`, `spotCaptured(spot:)`, `finished(SeatMeasurementResult)`, `failed(ExternalMeasurementFailure)`; `init(io:channels:permission:stillness:configuration:thresholds:)` (:88), `file` (:58), `captured`, `capturedSpots` (:74), `start()`, `run()`, `cancel()`, `skipToResult()` (:131), `progressUpdates()` (:139) |
| `ExternalMeasurementProgress`, `ExternalSeatMeasurementProgress` | `ExternalMeasurementTypes.swift:83`, `:122` | Runs in hand and needed (or the spot), the run or channel being heard, `frequency` and `sweepFraction` (the portrait), `isHearingTone`, `clockOffsetPPM`, room level and its mark, input level, peak and clipping, `isPhoneSteady`, `silentFor` and `isSilenceLong` (say what to check); the seat adds `stillness` and `wait` |
| `ExternalPlayProblem` | `ExternalMeasurementTypes.swift:4` | Why another play is needed: `run(RunProblem)`, `wrongFile(heard:)`, `missedSweeps`, `clockUnknown` |
| `ExternalMeasurementFailure` | `ExternalMeasurementTypes.swift:21` | `measurement(MeasurementFailure)`, `nothingHeard` (nothing louder than the room), `soundNotRecognised` (sound heard, none of it the test sound: music, a converted copy, a subwoofer alone), `playerClockOff(ratio:)`, `listeningTimeUp(lastProblem:)`. A new type, because the app switches over `MeasurementFailure` and `RunProblem` exhaustively |
| `ExternalListening` | `ExternalMeasurementTypes.swift:41` | The sessions' limits (below) |
| `ExternalHearing`; `progress.hearing` | `ExternalMeasurementTypes.swift:68` | What is heard while waiting, the three cases the screen tells apart plus the test sound itself: `nothing`, `notTheTestSound` (louder than the room for `unrecognisedSoundMinimum` with nothing recognised, or the latest play was another file), `testSound`, `testSoundIncomplete` (the latest play too quiet, missed or cut short, or its tone missed); each has its sentence (`ExternalSessionText.hearingLine(_:file:)`, :77) |
| `PlaybackSource`; `MeasurementResult.source`, `SeatMeasurementResult.source`, `RunRecording.clockRatio` | `MeasurementTypes.swift:88`, `:102`; `SeatMeasurementTypes.swift:54`; `MeasurementTypes.swift:84` | `thisPhone` (the default) or `anotherDevice`; the clock each run was corrected for (nil when the phone played) |
| `SimulatedExternalPlay`, `SimulatedAudioIO.playExternally(_:)`, `externalPlayCount` | `SimulatedExternalPlay.swift:11`; `SimulatedAudioIO.swift:257`, `:263` | Another device playing a file into the simulation, after `delay`, at `clockRatio` (each piece resampled before the speakers), `gain`, with `bursts` counted from the file's start; a new play stops the one before. The sessions cannot tell it from a player |
| `ExternalSessionText` | `ExternalSessionText.swift:8` | File names (:12), titles (:22), summaries (:32), `fileNote` (:46); headlines (:52, :126), waiting lines (:66, :143), `hearingLine(_:file:)` (:77), `toneLine`, another play (:94, :150), failures (:157, :178) |
| `ExternalListener`, `SweepInspection` (internal) | `ExternalListener.swift` | The shared machinery: keeps 30 s of audio, follows it (`SweepFollower`), reads the tone, groups what is heard into plays, identifies each sweep by the tone or the spacing, cuts it once its tail is in; `SweepInspection.inspect` (off the main actor) finds it exactly (`SweepFinder.find`), cuts `leadIn` before and `recordedTail` after, corrects the clock, then checks it as a normal run (`RecordingQuality.assess`, every sweep block to `SweepNoiseDetector`, then the whole sweep in the response) |

**How it listens.** Floor (`FloorListener`, `tooNoisy` after `maximumFloorWait`), then "Press play now". Every file starts with 3 s of silence and a 1 kHz clock tone; the tone gives the player's clock (fraction of a ppm) and starts a play. Each sweep heard is identified by the time from the tone onset (`TestSoundFile.identify`) or, without the tone, by the spacing from the previous sweep (`kind(forSpacing:)`); a sweep of another file makes the play `wrongFile` and nothing of it is kept. Once a sweep's tail is in it is cut and checked off the main actor; a sweep already placed by the file's timing is found with `SweepFinder`'s anchored rule, so a speaker that plays only part of the range (a dead tweeter, a dead woofer) is measured and its quiet band goes on to the analysis; a cut the finder refuses before it is placed waits, and is checked again anchored once the next sweep's spacing places it (a speaker whose tone was not heard); a usable run of the right file is kept, an unusable one is not (no pause, no splice) and its problem is remembered. When the play is over (every sweep of the file heard, or `playTimeout` of nothing) with fewer runs than needed, the state is `needsAnotherPlay` and listening goes on. A run is corrected for its play's clock (the tone; else, for the speaker test, the spacing of the play's sweeps as found, usable or not, on one path: the fallback for a speaker that cannot play 1 kHz, within 0.03 ppm in the test; else the latest tone). The seat has no spacing fallback: its left and right sweeps take different paths, and a metre's difference is 340 ppm over the 8.5 s spacing, so a seat whose tone is never heard keeps no spot (`clockUnknown`) unless an earlier spot heard it; without any it is not kept (`clockUnknown`); beyond `SweepFinder.maximumClockOffset` the session fails (`playerClockOff`). The result's runs have a normal run's shape (lead-in 0.05 s, measured delay 0.05 s), so `RunAnalyzer`, `SpotAnalyzer` and `SeatDiagnosis` take them unchanged.

**What "wrong file" can and cannot tell.** The files differ in timing: the silence after the tone (2, 2.5, 3, 3.5, 4 s for left, right, both, seat pair, seat one) and between sweeps (3, 3.5, 4, 4.5 s). So any sweep heard after the tone, or any two sweeps, say which file is playing, and a seat file during a speaker test or the right file during a left test is refused. What one microphone cannot tell is which speaker played: a left file through swapped cables, or with the balance turned, reads as left. A single sweep heard without the tone, and no second sweep, cannot be placed and is not kept (`missedSweeps`).

### Around the test

| Symbol | Where | Holds |
|---|---|---|
| `MicrophoneAccess`, `MicrophonePermission` | `MicrophonePermission.swift:6`, `:14` | Granted, denied, undetermined; `status`, `request()` |
| `SystemMicrophonePermission`, `SimulatedMicrophonePermission` | `MicrophonePermission.swift:36`, `:21` | `AVAudioApplication`, and a fixed answer for tests |
| `StillnessMonitor` | `StillnessMonitor.swift:12` | `isSteady`, `start()`, `stop()` |
| `MotionStillnessMonitor`, `ConstantStillnessMonitor` | `StillnessMonitor.swift:36`, `:20` | Core Motion, and a settable value for tests |
| `TonePlayer` | `TonePlayer.swift:22` | "Hold to hear": `start(frequency:on:)` (:56; schedules on the first microphone block, refuses the phone's own output), `stop()` (:109; safe in any state, the lifecycle hook), `stopAndWait()` (:120), `fadeDuration` (:24), `loopDurations` (:27), `maximumDuration` (:30) |
| `TonePlayerError` | `TonePlayer.swift:5` | `audioUnavailable`, `speakersNotConnected` |

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
| `SweepNoiseDetector.reverberationAllowance` | 0.8 s | Was 0.3; a tail as loud as the direct sound with a 0.5 s decay paused every run about six times at 0.3, and none at 0.8 (0.5 and 0.8 s decays). First guess |
| `SweepNoiseDetector.mainLobeBins` | 6 | Blackman–Harris lobe plus two |
| `SweepNoiseDetector.presenceMarginDecibels` | 10 dB | First guess |
| `ArrivalTracker` (internal) | 100 Hz, 20 dB, 2 estimates, 64 kept | `CaptureTimeline.swift:45–51`; presence first guess |
| `EngineAudioIO.preferredSampleRate`, `tapBufferSize`, `schedulingLead` | 48 kHz, 4800, 0.1 | |
| `MotionStillnessMonitor` limits | 0.2 rad/s, 0.05 g, 0.5 s, 50 Hz | `StillnessMonitor.swift:39–48`; first guesses for a hand-held phone, not checked on a device |
| `MeasurementConfiguration.maximumFloorWait` | 30 s | Then `tooNoisy`. First guess, as `maximumPauseWait` |
| `SeatMeasurementSession.maximumStillnessWait` | 30 s | Then `phoneNeverStill`. First guess for a hand-held phone |
| `CapturedAudio.minimumDuration` | 1.5 s | One sound-classifier window; less is not offered |
| `CapturedAudio.sweepDecayAllowance` | 0.5 s | The room window; first guess |
| `TonePlayer.fadeDuration`, `loopDurations` | 0.02, 0.1…0.25 | |
| `TonePlayer.maximumDuration` | 20 s | Then it fades out by itself. First guess |
| `MeasurementConfiguration.maximumPauses` | 6 a run | Then noise is recorded through and the check decides. First guess |
| `MeasurementConfiguration.maximumPauseWait` | 30 s | Then `tooNoisy`. First guess |
| `MeasurementConfiguration.sweepTiedTolerance` | 0.15 s of sweep | Noise back within this of an earlier pause is tied to the sweep. First guess |
| `MeasurementConfiguration.maximumSpliceMisalignment` | 30 µs (1.5 samples at 48 kHz) | Takes further apart restart the run. First guess |
| `RunRecorder.misalignmentSearch` (internal) | ±24 samples | A peak at the edge counts as misaligned |
| `EngineAudioIO.stopFade` | 6 ms in four volume steps | First guess; check for clicks on a phone |
| `MeasurementConfiguration.seat` | `minimumTail` 2 s, `maximumDecay` 3 s, `runCount` 1, the rest `standard` | First guess: `Decay` wants the decay plus noise (2 s for a 1 s bass decay), the room window 0.5 s |
| `SeatMeasurementSession.stillnessHold` | 1 s | First guess for a hand-held phone |
| `SeatMeasurementSession.movementTimeout` | 10 s | First guess for a hand-held phone |
| `SeatMeasurementSession.capturedHold` | 0.5 s | First guess |
| `LiveSpectrum.updateRate` | 15 a second of audio | One update per `sampleRate / 15` captured samples |
| `LiveSpectrum.attackTime`, `releaseTime` | 0.05 s, 0.4 s | First guesses; steps of 0.74 and 0.15 of the way per update |
| `LiveSpectrum.analysisLength` | 16 384 samples | 0.34 s at 48 kHz; every band down to 20 Hz holds a bin |
| `CapturedAudio.pausedDuration` | 4 s | First guess: four 1.5 s classifier windows at half overlap |
| `SeatSpot.spacing` | 0.30 m | First guess; the instruction and the plan's markers read it |
| `ReadingText.roomNoiseScaleDecibels` | 70 dB | The room-noise bar's right end; the mockup's 52 dB at 78 %, its mark at 55 % |
| `TestSoundFile.sampleRate`, `bitDepth` | 48 kHz, 24 | 24-bit: the samples pass to −138 dBFS, no dither, no quantisation distortion in the THD |
| `TestSoundFile.leadIn` | 3 s | Before the tone. First guess |
| `TestSoundFile.toneGap(for:)` | 2, 2.5, 3, 3.5, 4 s | Left, right, both, seat pair, seat one; tells the files apart |
| `TestSoundFile.gap(for:)` | 3, 3.5, 4, 4.5 s | Between sweeps: left, right, both, seat pair; each ≥ `recordedTail` + `roomDecayAllowance` (tested) |
| `TestSoundFile.tail` | 3 s | ≥ the seat's recorded tail (2.4 s) |
| `TestSoundFile.roomDecayAllowance` | 1 s | First guess: a large living room's reverberation |
| `TestSoundFile.spacingTolerance` | 0.2 s | The kinds are 0.5 s apart |
| `TestSoundFile.recordedTail(for:)` | 0.6 s (`.standard`), 2.4 s (`.seat`) | `minimumTail + decayHold + blockDuration` |
| File lengths | 28, 29.5, 31, 24, 16 s | Left, right, both, seat pair, seat one |
| `ExternalListening.nothingHeardHint` | 15 s | Then the progress says to check volume, file and input. First guess |
| `ExternalListening.nothingHeardLimit` | 60 s | Then `nothingHeard`. First guess |
| `ExternalListening.maximumListeningTime` | 300 s (each seat spot's share) | Then `listeningTimeUp`. First guess |
| `ExternalListening.playTimeout` | 9.5 s | The longest silence inside a file (6 s) plus recognising a sweep (about 2.5 s) and 1 s |
| `ExternalListening.bufferHorizon` (internal) | 30 s | Audio kept for cutting |
| `ExternalListening.unrecognisedSoundMinimum` | 2 s | Louder than the room by `pauseMarginDecibels` with nothing recognised: `notTheTestSound`, and `soundNotRecognised` instead of `nothingHeard` at the limit. First guess |
| `SimulatedRoom.livingRoom` | Modes 38, 57, 85 Hz (levels per spot [12, 9, 14], [−5, 2, −3], [5, 7, 2] dB), Q for 0.5 s, right +1 dB, tail 0.5 s at −26 dB | A test fixture, not a claim about rooms |

`SweepNoiseDetector` and the live gate are unaffected by the DSP's move to dBFS RMS: the detector compares a block's bins with the floor's same bins (a ratio), and adds that rise to the floor's broadband `LevelMeter` RMS, which was RMS before and after.

## Loops that read captured audio

Every loop that reads the capture stream (`MeasurementSession`, `SeatMeasurementSession`,
`ExternalMeasurementSession`, `ExternalSeatMeasurementSession`, `TonePlayer`, `LiveSpectrum`) yields after each block. The engine's stream is unbounded, so when blocks pile up it hands them
over without suspending; without the yield a backlog would hold the main actor or a pool thread until it was
gone. With it, a backlog holds a thread for one block's work at most. The whole package's tests pass on a
one-thread cooperative pool (`LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 swift test --package-path ResoniqKit`).

## Tests

`ResoniqKit/Tests/ResoniqAudioTests/`, run on the Mac by `make test`, all on `SimulatedAudioIO` with the app's own configuration (4 s sweeps), each test as short as its rule allows (two runs where the second only needs the delay known, one where it only needs to have finished, a 6 s longest wait where the rule is the configured wait, a seat run skipped after the spot that shows the rule). One clean seat run (`CleanSeatRun`) is made once and read by every test that only looks at a clean run.

- `SessionAdditionsTests`: each spot's recordings are in `capturedSpots` at its `spotCaptured` ([seat], [seat, left], [seat, left, right]) and `captured` equals the result; the wait's phases never return to `waitingForMove` once the phone moved and follow steadiness; one instruction per phase and every other moment's sentence; the readings; a paused speaker test offers at most 4 s of the pause's audio (−34 dBFS for 0.02 RMS noise), growing block by block, and keeps it as `noisyRecording` when it ends too noisy; a paused seat measurement offers its audio; the ring.

- `MeasurementSessionTests`: a clean test deconvolves to the speaker within 0.5 dB; a 1.5 s route delay is waited for and measured; a noise burst pauses, resumes earlier in the sweep and splices cleanly; noise early restarts the run; endless noise stays paused until cancelled; a clipped run is repeated once, then fails; denied permission plays nothing; an interruption ends the test; a moving phone is noted; cancelling in every state releases everything; progress rises run by run; any block size; a stream under 44.1 kHz fails before any sound.
- `RecordingCheckTests`: a whole recording passes, a non-finite sample is `.unusable(.corrupt)`, a recording cut 0.3 s before the sweep's end is `.didNotArrive`.
- `SeatMeasurementSessionTests` (in `SimulatedRoom.livingRoom`, immediate pacing): a pair gives three spots × two channels, each deconvolving (room window, sixth-octave, 30 Hz–16 kHz) to its own spot's simulated response within 0.006 dB and 2.9 dB or more from the other spots'; one speaker gives three × one; movement then stillness between spots, `spotCaptured` three times in order, the microphone at the right spot for each sweep; noise pauses and splices (within 0.005 dB); the 2.25 s tail lets `Decay.bass` read the room's 0.5 s within 7.2 % (0.464–0.494 s, T30, 98 dB of range); a spot that clips twice fails; skipping after one spot and in the middle of a spot; cancelling in every state; denied permission; undetected movement waits `movementTimeout` and is marked; an interruption.
- `LiveSpectrumTests` (on a sine `AudioIO` double): a 1 kHz tone at 0.1 reads −23.01 dBFS in its band (expected −23.01) with its neighbours under −120; the stream ends and the IO stops on cancellation (waited for on signalled updates, and no block asked for after the stop, where it used to spin on `Task.yield`) and when the consumer stops; 15 updates a second for blocks of 4800, 1031 and 48 000; the smoothing steps; the release after the tone stops.
- `SweepNoiseDetectorTests`: a quiet room is never too noisy while the sweep plays (three speakers, one with a buzz), the tone found follows the sweep, a burst is too noisy in exactly its blocks, without a sweep it is the plain gate.
- `SweepTiedSoundTests`: a rattle 40 dB under the sweep at 180–320 Hz pauses 5 times in three runs and finishes, each run marked tied at about 92–433 Hz (the band-pass skirt); a tail as loud as the direct sound with a 0.5 or 0.8 s decay finishes with no pause and nothing marked; a 1.5 s decay pauses up to the cap (12 in three runs) and finishes; noise that never stops ends as `tooNoisy` after the configured longest wait (6 s in the test, 30 s in the app). Before the fix all four ran past a minute.
- `SpliceAlignmentTests`: takes that line up are spliced with an offset under 0.2 samples and a deconvolved delay within 1 ms; a 5-sample drift during a pause restarts the run (0.0006 dB from the speaker, where splicing it gave 0.56 dB); the misalignment of a shifted signal is measured within 0.1 sample.
- `OutputRouteTests`: a speaker test, a seat measurement and the tone through the receiver or the phone's speaker fail before any sound; the user's own outputs are measured.
- `ReviewFixTests`: at route delays of 0.25, 1 and 2 s a clean pause offers no audio of the sweep (before the fix it offered the sweep's tail at −20 to −22 dBFS at 1 and 2 s), and noise that goes on through the pause is still offered, at its own level from its first second; the keeper's skip and minimum; a room too loud for a floor ends a speaker test and a seat measurement as `tooNoisy` with nothing played (before, it listened for ever); a phone that never stops moving ends the seat measurement as `phoneNeverStill`, with its words; an IO whose route cannot be told is measured.
- `LifecycleTests`: both sessions' `cancel()` before, during, after and twice.
- `DemoSpeakerTests`: the app's simulated left speaker (`buzzingBookshelf`, the app's configuration, three runs of the measurement sweep) measures THD over 10 % from 103 to 161 Hz, peaking at 19.1 %, and under 1 % at 400 Hz and 2 kHz; the diagnosis's rule (1/12-octave smoothing, measurable, over 10 % for at least 1/6 octave) is restated because this target cannot import ResoniqDiagnostics.
- `TestSoundFileTests`: each file read back with `AVAudioFile` gives exactly the quantised sweep and tone where the layout says, silence elsewhere, nothing above the safe level; a left file's right channel is exactly zero; the header's sizes, format tag, channels, rate, byte rate and block align; the gaps hold each recording's tail and the room's decay; every sweep of every file is identified by its time after the tone (±0.15 s) and the files with more than one sweep by their spacing; names and summaries.
- `ExternalMeasurementSessionTests` (the simulated external player, immediate pacing): a clean play finishes with three runs that deconvolve to the speaker within 0.001 dB (asserted 0.5), measured delay the lead-in, nothing scheduled by the phone; play pressed 10 s late; a player 300 ppm fast (corrected to within 2 ppm, 0.003 dB); noise over run 2 asks for another play with `have: 2` and `tooNoisy`, the next play completes it (attempts 1, 1, 2); the seat file then the right file during a left test are each refused as `wrongFile`, then the left file completes it; nothing played waits, says what to check after 15 s and fails as `nothingHeard` at 60 s; a play too loud clips, asks again with `have: 0`, and a normal one completes it; a player 1500 ppm off fails as `playerClockOff`; denied permission; `cancel()` at every state.
- `ExternalSeatMeasurementSessionTests` (`SimulatedRoom.livingRoom`, a player 250 ppm slow): three spots with noise over the right sweep at the left spot, which asks for another play there only; every recording within 0.02 dB of its spot's simulated response (asserted 1), a tail of at least 2 s and `Decay.bass` within 10 % of the room's; one speaker gives three spots of one recording; the speaker test's file at a spot is refused; cancel while waiting for the sound. That `SpotAnalyzer` and `SeatDiagnosis` read such recordings as they read a normal seat is `SoundSourceTests` in ResoniqDiagnostics (no test target imports both modules).
- `ExternalFaultySpeakerTests`: through the simulated player, a dead tweeter (8th-order low-pass at 2 kHz) and a dead woofer (8th-order high-pass at 500 Hz) each finish with three runs whose responses show the dead band 72 and 89–97 dB down; a 200 Hz–2 kHz speaker finishes with three runs (8 kHz 40 dB and 60 Hz 34 dB under 700 Hz); a subwoofer alone (8th-order low-pass at 150 Hz) is never recognised, the progress says `notTheTestSound` and the session ends as `soundNotRecognised`, never entering `hearing`; a tweeter alone (12th-order high-pass at 1.8 kHz, the tone not heard) finishes in one play with its clock from the sweeps' spacing within 0.03 ppm; nothing played reads `nothing` and ends as `nothingHeard`; ten seconds of loud noise reads `notTheTestSound` and ends as `soundNotRecognised`; a play 46 dB too quiet asks again for `tooQuiet` and reads `testSoundIncomplete`. That a dead tweeter's runs are reported as "I could barely hear the tweeter" is `SoundSourceTests` in ResoniqDiagnostics.
- `ExternalSessionTextTests`: the words, verbatim where they matter.
- `SweepSplicerTests`, `SimulatedAudioIOTests` (real-time pacing against an injected clock), `TonePlayerTests` (no scheduling before the first block, the tone fades out by itself after 20 s of captured audio, awaited with the internal `waitUntilSilent()` rather than a spin, a clear error when the audio cannot start, `stop()` in any state).

The suite takes about 18 s on a loaded Mac (it took 74–86 s): the simulator's, the noise detector's and the splice alignment's per-sample and per-bin loops are plain `while` loops with plain assignments (same arithmetic and noise order, so every figure above is unchanged), because range iterators, tuple swaps and a configuration copy per sample dominated the debug build; the detector zero-pads before the transform; and the tests above are shorter. What is left is mostly the per-block work of every session on the one main actor and the DSP's transforms in a debug build. No test is skipped by default.

## Limits

- `SweepNoiseDetector` cannot tell a steady tone near the sweep from the sweep, ignores rumble under 100 Hz, and counts a rattle that is not a harmonic as noise, so a badly rattling speaker can pause a test.
- The route delay must stay under `maximumRouteDelay`; a longer one is `didNotArrive`.
- The live arrival estimate is good to a fraction of a block; when it is early the recording can stop too soon. The run check catches a recording that misses the sweep's end, but a tail shorter than `minimumTail` is not a failure: the run is kept and its distortion is then not measurable.
- A route that runs under 44.1 kHz (Bluetooth hands-free) cannot be measured.
- `SoundLevel` is approximate: the microphone is not calibrated.
- Sound tied to the sweep is recognised only where it comes back within `sweepTiedTolerance` of an earlier pause; a room whose reverberation outlasts `reverberationAllowance` and pauses at ever new places is stopped by `maximumPauses` instead, unmarked. Speech that starts again within 0.15 s of sweep of where it paused the run would be taken as tied. Below the sweep's last 2.2 octaves noise is not watched.
- `EngineAudioIO`'s fixes (host-clock scheduling, the volume fade, restarting on a configuration change that moves nothing, one session owner) are verified only by an iOS build.
- `LiveSpectrum`'s rate is steady in audio time; with 100 ms tap blocks the updates arrive in ones and twos per block.
- `Decay.bass` on the simulated room reads 1–7 % short of the modes' 0.5 s: the direct sound in the band shortens the energy decay.
- Listening to another device: a run spoiled by noise is not kept and cannot be saved by a pause; the file is played again. Which speaker played cannot be told, only which file. The phone's route is not checked (nothing plays through it). The portrait fills from about 2.3 s into each sweep, when the follower is sure. A play that overlaps the previous one (play pressed again before the file ended) is taken as a new play from its tone. A subwoofer on its own cannot be tested this way (nothing of it reaches the finder's band, nor the 1 kHz tone): the session says it heard sound it could not recognise. A part-range speaker whose tone is not heard and of whose play only one sweep is found cannot be placed, so that sweep is not kept.

## Open questions

- Is 4 s right on a phone held at arm's length in a living room, or should the DSP's sweep be longer for signal-to-noise?
- Should a run whose tail is shorter than `HarmonicDistortion.minimumTail` be repeated rather than kept with unmeasurable distortion?
- Only on a real iPhone, for the seat measurement: the stillness limits for a phone held by hand at ear height (`MotionStillnessMonitor`'s 0.2 rad/s and 0.05 g, `stillnessHold`), whether a 30 cm move registers as movement within `movementTimeout`, whether 2 s of tail covers a real room's bass decay (over 1 s it would want more) and what dynamic range a phone reaches there, and how the live spectrum's smoothing reads on screen.
- Only with real players and a real room, for listening to another device: players' clock offsets and whether they resample the 48 kHz file; whether old players read 24-bit WAV at all (a 16-bit file, dithered, would be the fallback); lossy formats and AirPlay or a receiver's own processing between the file and the speakers; how long a real player takes from play to sound; whether the 15 s and 60 s silence limits and the 9.5 s play timeout suit people; whether the tone survives a room's noise at the volumes people choose.
- Only on a real iPhone: the `.measurement` mode's actual processing on current models, the input's real latency and whether the host-clock mapping of the timeline holds, AirPlay and Bluetooth delays and their drift over a 4 s sweep, real clock offsets between output and input, interruptions and route changes as they really arrive, the sample rate a Bluetooth or AirPlay route settles on, the 110 dB on-screen offset, the stillness limits against a hand-held phone, and whether `SweepNoiseDetector`'s margins hold in a real room with a real speaker's harmonics.
