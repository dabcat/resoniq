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
/// The IO and the stillness monitor are made per test (an IO is single-use); the permission is shared.
struct AudioEnvironment {
    var makeIO: @MainActor () -> any AudioIO
    var permission: any MicrophonePermission
    var makeStillness: @MainActor () -> any StillnessMonitor
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
