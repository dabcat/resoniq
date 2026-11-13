import Foundation
import ResoniqAudio
import SwiftUI

/// The one place that decides which audio, microphone permission and motion sensor the app uses.
///
/// On a device that is the real engine, the system's permission and Core Motion. In the iOS simulator, which has no
/// loop from the speaker to the microphone, it is `SimulatedAudioIO` paced in real time with a speaker on the left
/// that buzzes between about 100 and 160 Hz (`SimulatedSpeaker.buzzingBookshelf`, about 19 % THD, which the
/// diagnosis reports as "Possible buzz at 100–160 Hz") and a clean one on the right, so both outcomes can be seen.
/// A Debug build on a device can ask for the same with `-simulatedAudio YES`; `-simulatedNoise YES` adds a burst of
/// noise a few seconds into the second run so the Paused screen can be seen.
///
/// The seat measurement and the live spectrum get their own simulation: the seat's runs on a `SimulatedRoom` like the
/// Measure mockup's (a peak near 41 Hz, a dip near 61 Hz, even above) with a stillness monitor that acts out "moved,
/// then still" between spots, so the whole flow runs unattended; the live spectrum hears a steady hiss.
///
/// The IO and the stillness monitor are made per test (an IO is single-use); the permission is shared.
struct AudioEnvironment {
    /// What one seat measurement runs on: its IO and the stillness monitor that goes with it. Made together because
    /// the simulated monitor moves the simulated microphone.
    struct SeatAudio {
        var io: any AudioIO
        var stillness: any StillnessMonitor
    }

    /// What one listening test or seat measurement runs on when another device plays the test sound: the IO that only
    /// listens, the stillness monitor, and, in the simulation, the "player" that plays the file into it.
    struct ExternalAudio {
        var io: any AudioIO
        var stillness: any StillnessMonitor
        /// Plays a test sound file into the simulated room, as a person pressing play on another device would;
        /// nil on a device, where the person does it.
        var simulatedPlay: (@MainActor (TestSoundFile) -> Void)?
    }

    var makeIO: @MainActor () -> any AudioIO
    var permission: any MicrophonePermission
    var makeStillness: @MainActor () -> any StillnessMonitor
    var makeSeat: @MainActor () -> SeatAudio
    /// The audio of a speaker test whose sound another device plays.
    var makeExternal: @MainActor () -> ExternalAudio
    /// The audio of a seat measurement whose sound another device plays.
    var makeExternalSeat: @MainActor () -> ExternalAudio
    /// The IO "Watch the sound live" listens through.
    var makeLiveIO: @MainActor () -> any AudioIO
    /// Whether the audio is simulated, for a note on screen where one helps.
    var isSimulated: Bool

    /// The environment this launch uses.
    static var current: AudioEnvironment {
        #if targetEnvironment(simulator)
        return .simulated(noise: launchFlag("simulatedNoise"))
        #else
        #if DEBUG
        if launchFlag("simulatedAudio") { return .simulated(noise: launchFlag("simulatedNoise")) }
        #endif
        return .device
        #endif
    }

    static var device: AudioEnvironment {
        AudioEnvironment(
            makeIO: { EngineAudioIO() },
            permission: SystemMicrophonePermission(),
            makeStillness: { MotionStillnessMonitor() },
            makeSeat: { SeatAudio(io: EngineAudioIO(), stillness: MotionStillnessMonitor()) },
            makeExternal: { ExternalAudio(io: EngineAudioIO(), stillness: MotionStillnessMonitor(), simulatedPlay: nil) },
            makeExternalSeat: { ExternalAudio(io: EngineAudioIO(), stillness: MotionStillnessMonitor(), simulatedPlay: nil) },
            makeLiveIO: { EngineAudioIO() },
            isSimulated: false
        )
    }

    /// Simulated audio. `access` is what the microphone permission answers.
    static func simulated(
        noise: Bool = false,
        access: MicrophoneAccess = .granted,
        pacing: SimulatedAudioIO.Pacing = .realTime
    ) -> AudioEnvironment {
        AudioEnvironment(
            makeIO: { SimulatedAudioIO(configuration: simulatedConfiguration(noise: noise, pacing: pacing)) },
            permission: SimulatedMicrophonePermission(access),
            makeStillness: { ConstantStillnessMonitor() },
            makeSeat: { simulatedSeat(noise: noise, pacing: pacing) },
            makeExternal: { simulatedExternal(pacing: pacing) },
            makeExternalSeat: { simulatedExternalSeat(pacing: pacing) },
            makeLiveIO: { SimulatedAudioIO(configuration: .init(noiseRMS: liveNoiseRMS, pacing: pacing)) },
            isSimulated: true
        )
    }

    private static func simulatedConfiguration(noise: Bool, pacing: SimulatedAudioIO.Pacing) -> SimulatedAudioIO.Configuration {
        // The second scheduled buffer is the second run's sweep.
        let bursts = noise ? [NoiseBurst(start: .afterScheduling(buffer: 1, offset: 3), duration: 4, rms: 0.02)] : []
        return SimulatedAudioIO.Configuration(bursts: bursts, left: .buzzingBookshelf, right: .bookshelf, pacing: pacing)
    }

    /// The room of the Measure mockup: +9 dB at 41 Hz and -11 dB at 61 Hz, a little different at each spot and at the
    /// right speaker, nothing else. The modes ring for 0.5 s, as `SimulatedRoom.livingRoom` does.
    static let simulatedSeatRoom = SimulatedRoom(
        modes: [
            SimulatedRoom.Mode(
                frequency: 41, q: SimulatedRoom.Mode.q(forDecay: 0.5, frequency: 41, sampleRate: 48_000),
                decibels: [9, 6, 11]
            ),
            SimulatedRoom.Mode(
                frequency: 61, q: SimulatedRoom.Mode.q(forDecay: 0.5, frequency: 61, sampleRate: 48_000),
                decibels: [-11, -7, -13]
            ),
        ],
        rightOffsetDecibels: 1,
        reverberationTime: 0.5,
        reverberationLevel: 0.05
    )

    /// The steady hiss the live spectrum hears in the simulation: loud enough to lift the bars off the bottom.
    private static let liveNoiseRMS = 0.003

    /// A seat measurement in `simulatedSeatRoom`: the phone moves between spots in real time (or at once with
    /// immediate pacing) and takes the simulated microphone with it. With `noise`, a burst of room noise a few
    /// seconds into the seat spot's second sweep pauses it.
    @MainActor
    private static func simulatedSeat(noise: Bool, pacing: SimulatedAudioIO.Pacing) -> SeatAudio {
        // The second scheduled buffer is the second channel's sweep at the first spot.
        let bursts = noise ? [NoiseBurst(start: .afterScheduling(buffer: 1, offset: 3), duration: 4, rms: 0.02)] : []
        let io = SimulatedAudioIO(
            configuration: .init(bursts: bursts, left: .bookshelf, right: .bookshelf, pacing: pacing, room: simulatedSeatRoom)
        )
        let stillness = SimulatedStillnessMonitor(pacing: pacing == .realTime ? .realTime : .immediate)
        stillness.onMove = { [io] spot in io.moveToSpot(spot.index) }
        return SeatAudio(io: io, stillness: stillness)
    }

    /// The simulated "other device": it presses play a second after it is asked, runs 300 ppm fast, and the sound takes
    /// 0.3 s to travel from the player's speakers (the route's delay), so the listening has a delay and a clock offset
    /// to cope with, as with a real player.
    private static let simulatedPlayerDelay = 1.0
    private static let simulatedPlayerClockRatio = 1.0003
    private static let simulatedRouteDelay = 0.3

    private static func simulatedPlay(on io: SimulatedAudioIO) -> @MainActor (TestSoundFile) -> Void {
        { [io] file in
            io.playExternally(SimulatedExternalPlay(file: file, delay: simulatedPlayerDelay, clockRatio: simulatedPlayerClockRatio))
        }
    }

    /// A speaker test listened to: the same simulated speakers as the normal test (the left one buzzes), a route delay.
    @MainActor
    private static func simulatedExternal(pacing: SimulatedAudioIO.Pacing) -> ExternalAudio {
        let io = SimulatedAudioIO(configuration: .init(
            routeDelay: simulatedRouteDelay, left: .buzzingBookshelf, right: .bookshelf, pacing: pacing
        ))
        return ExternalAudio(io: io, stillness: ConstantStillnessMonitor(), simulatedPlay: simulatedPlay(on: io))
    }

    /// A seat measurement listened to: the same room and moving phone as the normal one, a route delay.
    @MainActor
    private static func simulatedExternalSeat(pacing: SimulatedAudioIO.Pacing) -> ExternalAudio {
        let io = SimulatedAudioIO(configuration: .init(
            routeDelay: simulatedRouteDelay, left: .bookshelf, right: .bookshelf, pacing: pacing, room: simulatedSeatRoom
        ))
        let stillness = SimulatedStillnessMonitor(pacing: pacing == .realTime ? .realTime : .immediate)
        stillness.onMove = { [io] spot in io.moveToSpot(spot.index) }
        return ExternalAudio(io: io, stillness: stillness, simulatedPlay: simulatedPlay(on: io))
    }

    private static func launchFlag(_ name: String) -> Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: name)
        #else
        false
        #endif
    }
}

extension EnvironmentValues {
    @Entry var audioEnvironment = AudioEnvironment.current
}
