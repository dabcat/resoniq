import Foundation
import ResoniqAudio
import SwiftUI

/// The one place that decides which audio, microphone permission and motion sensor the app uses.
///
/// On a device that is the real engine, the system's permission and Core Motion. In the iOS simulator, which has no
/// loop from the speaker to the microphone, it is `SimulatedAudioIO` paced in real time with a speaker on the left
/// that buzzes between about 70 and 110 Hz and a clean one on the right, so both outcomes can be seen. A Debug
/// build on a device can ask for the same with `-simulatedAudio YES`; `-simulatedNoise YES` adds a burst of noise a
/// few seconds into the second run so the Paused screen can be seen.
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

    var makeIO: @MainActor () -> any AudioIO
    var permission: any MicrophonePermission
    var makeStillness: @MainActor () -> any StillnessMonitor
    var makeSeat: @MainActor () -> SeatAudio
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
            makeLiveIO: { SimulatedAudioIO(configuration: .init(noiseRMS: liveNoiseRMS, pacing: pacing)) },
            isSimulated: true
        )
    }

    private static func simulatedConfiguration(noise: Bool, pacing: SimulatedAudioIO.Pacing) -> SimulatedAudioIO.Configuration {
        var buzzing = SimulatedSpeaker.bookshelf
        buzzing.defect = SimulatedSpeaker.Defect(band: 70...110, cubic: 12)
        // The second scheduled buffer is the second run's sweep.
        let bursts = noise ? [NoiseBurst(start: .afterScheduling(buffer: 1, offset: 3), duration: 4, rms: 0.02)] : []
        return SimulatedAudioIO.Configuration(bursts: bursts, left: buzzing, right: .bookshelf, pacing: pacing)
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
