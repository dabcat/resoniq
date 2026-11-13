---
type: "checklist"
status: "active"
tags:
  - "checklist"
---
# Device checklist

Nothing in Resoniq has run on an iPhone. The Kit's tests, the simulator build and the simulated flows pass; the
real microphone, speakers, LiDAR and camera have never been used. This is what to check, in order, with what
should happen and what to write down when it does not. It is collected from the "only a device can verify"
lists in [ResoniqAudio](modules/ResoniqAudio.md), [ResoniqDSP](modules/ResoniqDSP.md),
[ResoniqDiagnostics](modules/ResoniqDiagnostics.md), [ResoniqRoom](modules/ResoniqRoom.md) and
[ResoniqStore](modules/ResoniqStore.md), and the plan notes ([phase 2](plans/phase-2-diagnose.md) to
[phase 6](plans/phase-6-ai-finish.md)).

**Blocks** means a failing step stops us calling the feature working. **Tune** means the feature works, and the
result tells us what to change in a first-guess constant; the constants and where they live are in
[Constants to tune](#constants-to-tune) at the end.

## Before you start

- Xcode 26 or later; your team in `Config/Signing.local.xcconfig` ([Signing.xcconfig](../Config/Signing.xcconfig)); build and run the app on the iPhone from Xcode.
- A LiDAR iPhone (Pro model) for the scan; if you have one without LiDAR, use it for step 4.5 too.
- Speakers on a cable, on Bluetooth and on AirPlay, one pair at least on the cable; a vented (bass-reflex) speaker if you have one.
- A quiet room, and something that makes noise on demand (a voice, a TV, a tap running).
- Write down for every failure: the iPhone model and iOS version, the route (cable, Bluetooth, AirPlay, its name), the screen, what you saw, and what the Xcode console printed.
- Do not use the launch arguments `-simulatedAudio` or `-screen` on the device; they replace the real thing.

## 1. First launch and permissions

**1.1 Launch on a clean install. Blocks.**
Do: delete the app, install, open it.
Expect: the Diagnose tab opens with "My room · My speakers" at the top. No crash, no network prompt. The three intro screens are not shown (known gap: `IntroView` is not wired, see [App](modules/App.md)).
Write down: anything else shown; the console.

**1.2 Microphone, first use. Blocks.**
Do: Diagnose → start a test.
Expect: the system prompt appears once with the app's sentence ("I play a test sound through your speaker and listen to it with the microphone…"). Allow: the test goes on.
Write down: the prompt's text if it differs; what happens after Allow.

**1.3 Microphone denied. Blocks.**
Do: delete and reinstall, Don't Allow.
Expect: the denied screen, in the app's voice, explaining what to do. Turn the microphone on in iOS Settings → Resoniq and return: a test can start without relaunching. (The in-app Settings button does nothing yet.)
Write down: what the screen says; whether returning from iOS Settings needs a relaunch.

**1.4 Camera, first use. Blocks.**
Do: Optimize → scan (LiDAR phone), and later AR guidance.
Expect: the system prompt with the camera sentence; Allow starts the camera. Deny shows the denied state; allowing it in iOS Settings and returning works.
Write down: the prompt; what the denied state shows; whether returning works.

**1.5 Leaving the app stops the sound. Blocks.**
Do: start a test, and while the sweep plays lock the phone; again with an incoming call or by switching apps. Then the same during a seat measurement and while holding to hear.
Expect: sound stops at once (no tail), the run is cancelled, nothing keeps recording (no orange dot in the status bar after leaving). Returning shows a calm state, not a hang.
Write down: which of the four ways left sound playing.

## 2. Diagnose with real speakers

Run each of 2.1 to 2.6 once per route: **cable**, **Bluetooth**, **AirPlay**. Put the phone where a person would hold it, 1–2 m from the speaker, screen up.

**2.1 Nothing connected. Blocks.**
Do: no cable, no Bluetooth, start a test.
Expect: the "speakers not connected" screen before any sound; the phone's own speaker stays silent. Same for hold to hear.
Write down: whether any sound played; what the screen said.

**2.2 Route detection. Blocks.**
Do: connect a cable, Bluetooth, AirPlay in turn and start a test.
Expect: each is accepted as an output (not refused as the phone). Disconnecting during a test ends it with the route-changed message.
Write down: the route kind and name the app took (console), and any route refused or accepted wrongly.

**2.3 The sweep's level and the 10 Hz start. Blocks.**
Do: set the speaker to a normal listening volume, then to loud; run a test; listen. On a vented speaker, watch the woofer at the start (the sweep starts at 10 Hz).
Expect: a smooth rising sweep, not loud enough to hurt, no clicks at the start or end, no woofer flapping or bottoming out.
Write down: speaker and volume; any click, flap, distortion you could hear; whether the 10 Hz start looked unsafe. This is the open question in [ResoniqDSP](modules/ResoniqDSP.md).

**2.4 A whole test, quiet room. Blocks.**
Do: Aim → Left → Start. Let three runs finish.
Expect: Listening shows run 1, 2, 3 of 3, the portrait filling up as the sweep climbs; a result with a portrait, a verdict sentence and findings each with an evidence tag. A healthy speaker is not called broken. Total time is noted (see step 7.1).
Write down: the verdict and findings; whether a healthy speaker got a deviation; any run repeated and why (the screen says).

**2.5 Delay on each route. Blocks.**
Do: as 2.4 on Bluetooth and AirPlay.
Expect: the test finishes; the route delay is waited for (AirPlay about 2 s), nothing cut off at the end of the sweep.
Write down: for a failure, "did not arrive" or "recording unusable"; the route's delay if you can read it (`MeasurementProgress.routeDelay`, not shown on screen); whether the sample rate on the route was under 44.1 kHz (Bluetooth hands-free cannot be measured and fails before any sound).

**2.6 Pause on noise and resume. Blocks.**
Do: during a run make a noise (talk, clap, run a tap) for a few seconds, then stop.
Expect: Paused appears, saying what it heard when the sound classifier can tell ("It sounds like someone talking."); when the room is quiet the sweep picks up a little before where it stopped, and the run completes. The result is the same kind as an uninterrupted run (no step in the portrait at the splice).
Write down: whether a quiet room paused by itself (the detector's margins are first guesses), whether resume landed, whether the paused sentence named the noise correctly, and how many pauses a run needed. If the room never goes quiet the test ends "too noisy" after 30 s: note it.

**2.7 Hold to hear. Blocks.**
Do: open a finding with a frequency; press and hold "hold to hear"; release. With VoiceOver on, double-tap toggles.
Expect: a steady tone at the stated frequency that starts without a click, stops at once on release and fades out by itself after 20 s. Nothing plays through the phone's speaker.
Write down: clicks, delay before the tone, the frequency you hear against the one shown, anything left playing.

**2.8 "Sound is coming from the iPhone" refusal. Blocks.**
Do: with the cable unplugged and Bluetooth off, press hold to hear.
Expect: a clear message under the control, no tone.
Write down: any tone from the phone.

**2.9 A speaker with a real defect. Tune.**
Do: if you have one (a buzzing woofer, a cone rubbing), test it and a healthy one.
Expect: the defect shows as a "possible" buzz or rattle with a range; the healthy one does not.
Write down: the speaker, the finding, and a healthy speaker flagged. The 10 % distortion threshold at 80–110 Hz may read normal for a small woofer played loud.

**2.10 Left and right. Blocks.**
Do: test the left, keep it, test the right.
Expect: the right result includes the left/right comparison; a quick check (not kept) does not feed it.
Write down: a comparison against a speaker you did not keep.

## 3. Measure at the seat

**3.1 Stillness at ear height. Blocks.**
Do: Measure → Sit and aim → "I'm seated, start". Hold the phone at ear height, screen to the ceiling, as the instruction says.
Expect: the first spot starts when the phone has been still for about a second; shaking it keeps it waiting; a rigid haptic marks each captured spot.
Write down: whether it waits for you or never starts (hand tremor vs the 0.2 rad/s and 0.05 g limits), and the console's steadiness if shown.

**3.2 Three spots, 30 cm apart. Blocks.**
Do: after the seat, move 30 cm left, then 30 cm right.
Expect: the app sees you move and then be still; each spot is captured once; if it never sees the move it waits 10 s and goes on, marking the spot. The left speaker then the right play at each spot.
Write down: whether 30 cm registers as movement; how long each wait took.

**3.3 The seat result. Blocks.**
Do: finish the measurement; open The numbers.
Expect: a verdict sentence, the curve with the even band and labelled peaks and dips, up to three findings with evidence tags, and a numbers table. A peak or dip you can hear or know (a bass note that booms) is reported near the right frequency. Levels are labelled approximate.
Write down: findings against what you hear; "it's the room" said only with its basis.

**3.4 Decay. Tune.**
Do: look at The numbers in a room with obvious bass ringing and in a dead room.
Expect: decay shown with "≈" only when the recording supports it; otherwise not shown.
Write down: whether it is ever shown; the values; whether 2 s of recording after the sweep was enough.

**3.5 Noise during a seat spot. Blocks.**
Do: make noise during a spot's sweep.
Expect: the same pause and resume as 2.6, and the spot is captured.
Write down: as 2.6.

**3.6 Live spectrum. Tune.**
Do: Measure → Watch the sound live; play music; stop.
Expect: bars follow the sound smoothly, rise quickly and fall slowly, and the screen says what is loudest; stopping ends the microphone.
Write down: jitter, lag, battery heat; whether the microphone stops when you leave.

## 4. Scan (LiDAR) and the no-LiDAR path

**4.1 Scan a room. Blocks (LiDAR phone).**
Do: Optimize → scan; walk round a real room slowly; Finish.
Expect: the camera with RoomPlan's outlines, a floor-plan inset that follows you, the instruction line, labels on things; Finish processes and goes to Confirm layout with walls, doors, windows and furniture roughly right.
Write down: missing walls or wrong sizes (measure one wall), doors or windows on the wrong wall, how long processing took, any capture error (world tracking failure, scene size limit, device too hot).

**4.2 Close mid-scan. Blocks.**
Do: close the scan before Finish, and leave the app during a scan.
Expect: nothing is stored, the camera stops.
Write down: a stored room that should not exist.

**4.3 The guessed layout. Blocks.**
Do: on Confirm layout after a scan, read the hint; drag the speakers and seat; use the buttons to move and turn; add a subwoofer and a seat.
Expect: the hint says the speakers were guessed (the scan cannot see speakers); items stop at walls and furniture; with VoiceOver the buttons do what dragging does.
Write down: a guess that put the seat or speakers somewhere absurd; whether the sofa's facing looks right (RoomPlan's local +z).

**4.4 Keep the room. Blocks.**
Do: "Looks right, measure the room"; quit and reopen the app.
Expect: Optimize home shows the room's plan with the layout and the scan is kept.
Write down: lost layout.

**4.5 No LiDAR. Blocks.**
Do: on a phone without LiDAR open the scan.
Expect: the unsupported state and a way to enter the room by hand (width, length, height); the hand-entered room reaches Confirm layout.
Write down: a dead end.

## 5. AR guidance

**5.1 Find the floor and mark the speaker. Blocks (LiDAR phone, after 4.4 and a seat measurement).**
Do: Optimize → "Guide me in AR"; point at the floor; put the reticle on the front of the speaker to be moved; mark it.
Expect: the camera is shown, the floor is found within a few seconds on a plain floor, a reticle sits at the screen's centre on the floor (not on a table or seat), marking fixes the speaker's place.
Write down: how long the floor took, how well you could aim at the speaker's front, a reticle that jumps to furniture.

**5.2 Slide it to the outline. Blocks.**
Do: hold "Follow" and slide the speaker toward the dashed outline; release near it; turn the speaker by eye.
Expect: "To go" counts down; taps in the hand come faster as it nears; the turn arc is shown; at the target it says it is in place with a success haptic. One-handed use is bearable.
Write down: wobble of the outline near the 3 cm tolerance, haptics too faint or too many, whether the arc's direction is right.

**5.3 Tracking trouble. Tune.**
Do: cover the camera, then dim the room, then take a call mid-guide.
Expect: a plain "tracking limited" or "too dark" sentence; after an interruption the target stays where it was, or the screen says to start over.
Write down: which reasons appeared; whether the target drifted.

**5.4 Before and after. Blocks.**
Do: "It's in place", re-measure at the same three spots; read Before and after. Then do a move that changes nothing, and one that makes it worse.
Expect: an improvement is stated only from the second measurement, tagged measured; no change is called unchanged; worse says so plainly and offers to put the speaker back.
Write down: a result that disagrees with what you hear.

## 6. Data

**6.1 Keep and relaunch. Blocks.**
Do: keep a speaker test and a seat measurement; force-quit; relaunch.
Expect: Diagnose home and Measure home show them with their dates; opening one shows the same result.
Write down: anything missing or unreadable.

**6.2 Migration from an older build. Blocks.**
Do: build the commit `0512091` (Diagnose wired, store schema 1; or any build from before seat measurements were stored) on the phone, keep a test, then build the current commit over it without deleting the app.
Expect: the old test is still listed and opens; the new tabs work; no crash at launch.
Write down: the console's SwiftData error if any; whether "My room" and the old test survive.

**6.3 Delete. Blocks.**
Do: there is no Settings button yet (see [App](modules/App.md)); when it is wired: Delete all results, then Delete everything.
Expect: counts match what is removed; after Delete everything the app has "My room · My speakers" and no scan file remains.
Write down: leftovers. Until the screens are wired, skip and note that the delete path is untested on a device.

## 7. Accessibility

**7.1 VoiceOver through one full test. Blocks.**
Do: turn VoiceOver on and run Diagnose from Aim to Finding without looking.
Expect: every control is named; the result's verdict and each finding are read as sentences with their tag; progress during Listening is announced without chatter; hold to hear toggles on double-tap.
Write down: unlabelled controls, announcements that repeat, anything you could not do.

**7.2 VoiceOver in Measure and Optimize. Blocks.**
Do: the same through a seat measurement, Confirm layout (use the move and turn buttons) and AR guidance.
Expect: the plan, curve and spot diagram are each one sentence; the AR progress and the turn are spoken, so the guide works without sight.
Write down: as 7.1.

**7.3 Largest text size. Blocks.**
Do: Settings → Accessibility → Larger Text at the largest accessibility size; open every screen of 2.4, 3.3, 4.3 and 5.4.
Expect: nothing clipped, the primary button always reachable (the footer stays, content scrolls), tables and trackers stack instead of overflowing.
Write down: screen and what is cut.

**7.4 Reduce Motion. Tune.**
Do: turn Reduce Motion on and look at Listening, Paused, The spots, the room plan and AR guidance.
Expect: loops and pulses stand still, drawings are complete; nothing depends on motion to be understood.
Write down: anything still moving.

## 8. Performance and heat

**8.1 A full session's duration. Tune.**
Do: time a Diagnose test of one speaker (three runs), a seat measurement (three spots, two speakers) and a scan.
Expect: no stage looks hung; the screen always says what it is doing.
Write down: the three durations, and the longest silent stretch.

**8.2 Battery and heat. Tune.**
Do: note battery and the phone's warmth before and after one test of each speaker, a seat measurement, five minutes of scan, five minutes of AR, five minutes of live spectrum.
Expect: no thermal warning; the scan does not end with "device too hot".
Write down: percent used by each, any thermal message.

**8.3 Clicks and glitches in sound. Tune.**
Do: listen for clicks when a test is paused, cancelled or finished, and when hold to hear stops.
Expect: none (stops fade over 6 ms).
Write down: where a click was heard; the phone model.

## Constants to tune

Each is a first guess checked only against simulated rooms and speakers. When a step above says "Tune", change
the constant where it lives, with a test, and note it in the module's note. Paths are relative to
`ResoniqKit/Sources/`.

| What | Constant | Where | Seen in |
|---|---|---|---|
| Sweep start, length, level | 10 Hz, 4 s, −12 dBFS | `ResoniqDSP/Foundation/LogSweep+Measurement.swift:33`, `LogSweep.swift:10` | 2.3 |
| Recording verdict | peak, signal-to-noise, clipping | `QualityThresholds.standard`, `ResoniqDSP/Quality/QualityThresholds.swift:123` | 2.4 |
| Route delay, pause and resume timing | `maximumRouteDelay` 2.5 s, `resumeOverlap`, `maximumPauses` 6, `maximumPauseWait` 30 s | `MeasurementConfiguration.standard`, `ResoniqAudio/MeasurementConfiguration.swift:135` | 2.5, 2.6 |
| Noise while the sweep plays | analysis band, margins, `reverberationAllowance` | `SweepNoiseDetector`, `ResoniqAudio/SweepNoiseDetector.swift` | 2.6, 3.5 |
| On-screen decibel offset | 110 dB | `SoundLevel.approximateOffsetDecibels`, `ResoniqAudio/SoundLevel.swift:16` | 2.4, 3.3 |
| Phone still or moving | 0.2 rad/s, 0.05 g, 0.5 s | `MotionStillnessMonitor`, `ResoniqAudio/StillnessMonitor.swift:39` | 3.1 |
| Seat timing | `stillnessHold` 1 s, `movementTimeout` 10 s, `capturedHold` 0.5 s, spacing 0.30 m | `ResoniqAudio/SeatMeasurementSession.swift:51`, `SeatMeasurementTypes.swift:16` | 3.1, 3.2 |
| Seat recording tail | 2 s, up to 3 s | `MeasurementConfiguration.seat`, `ResoniqAudio/SeatMeasurementTypes.swift:136` | 3.4 |
| Live spectrum | 15 updates a second, attack 0.05 s, release 0.4 s | `LiveSpectrum`, `ResoniqAudio/LiveSpectrum.swift:21` | 3.6 |
| Stop fade | 6 ms | `EngineAudioIO.stopFade`, `ResoniqAudio/EngineAudioIO.swift:55` | 8.3 |
| Hold-to-hear limit | 20 s | `TonePlayer.maximumDuration`, `ResoniqAudio/TonePlayer.swift:30` | 2.7 |
| What counts as a deviation or a buzz | 6 dB, 10 % THD, 5-octave trend, band signal-to-noise 10 dB | `DiagnosisThresholds.standard`, `ResoniqDiagnostics/DiagnosisThresholds.swift:148` | 2.4, 2.9 |
| Seat findings | even band ±3 dB, spot disagreement 3 dB, repeatability 1.5 dB | `SeatThresholds.standard`, `ResoniqDiagnostics/Seat/SeatThresholds.swift:185` | 3.3, 5.4 |
| Naming the noise | confidence 0.5 | `InterferenceThresholds.standard`, `ResoniqDiagnostics/Models/InterferenceAdvisor.swift:13` | 2.6 |
| Layout guess and tolerances | wall distance 0.6 m, spacing 1–3 m, angle 10° | [ResoniqRoom constants](modules/ResoniqRoom.md#thresholds-and-constants), e.g. `ListeningGeometry.angleTolerance`, `ResoniqRoom/Geometry/ListeningGeometry.swift:13` | 4.3 |
| Placement advice weights | penalties, couplings, limits | `PlacementAdvisor` and `PlacementLimits.standard`, `ResoniqRoom/Advice/Suggestion.swift:206` | 5.4 |
| AR guide | 3 cm, 3°, haptic interval 0.08–0.8 s, dark below 120 lm, alignment residual 0.10 m | `MoveGuidance`, `ARTrackingIssue`, `WorldAlignment`, `ResoniqRoom/Guidance/MoveGuidance.swift:60`, `ARGuidanceState.swift:29`, `WorldAlignment.swift:13` | 5.2, 5.3 |
