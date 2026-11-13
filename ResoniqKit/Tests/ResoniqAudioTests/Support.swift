import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// Shared settings: the app's own configuration at 48 kHz, so every run plays the measurement sweep (4 s); a three-run
/// test is about 18 s of audio and runs in well under a second.
enum Fixture {
    static let sampleRate = 48000.0
    static let configuration = MeasurementConfiguration.standard
    static let sweep = configuration.sweep(sampleRate: sampleRate)

    static func io(
        routeDelay: Double = 0.02,
        bursts: [NoiseBurst] = [],
        speaker: SimulatedSpeaker = .bookshelf,
        blockSize: Int = 4800,
        noiseRMS: Double = 1e-4
    ) -> SimulatedAudioIO {
        SimulatedAudioIO(configuration: .init(
            sampleRate: sampleRate,
            blockSize: blockSize,
            routeDelay: routeDelay,
            noiseRMS: noiseRMS,
            bursts: bursts,
            left: speaker,
            right: speaker,
            pacing: .immediate
        ))
    }

    @MainActor
    static func session(
        io: SimulatedAudioIO,
        permission: MicrophoneAccess = .granted,
        stillness: ConstantStillnessMonitor = ConstantStillnessMonitor(),
        channel: SpeakerChannel = .left
    ) -> MeasurementSession {
        MeasurementSession(
            io: io,
            channel: channel,
            permission: SimulatedMicrophonePermission(permission),
            stillness: stillness,
            configuration: configuration
        )
    }
}

/// How far a recording's deconvolved response strays from what it should be.
enum ResponseCheck {
    /// The response of `recording`, deconvolved against `sweep`, on its linear grid.
    static func response(_ recording: [Float], sweep: LogSweep = Fixture.sweep) -> MagnitudeResponse {
        Deconvolution.impulseResponse(recording: recording, sweep: sweep).frequencyResponse()
    }

    /// The worst absolute difference in dB between two responses from 100 Hz to 16 kHz, after level matching and
    /// sixth-octave smoothing (which both sides get, so it hides nothing a speaker test cares about).
    static func worstDifference(_ measured: MagnitudeResponse, _ reference: MagnitudeResponse) -> Float {
        let smoothedMeasured = Smoothing.fractionalOctave(measured, fraction: 6)
        let smoothedReference = Smoothing.fractionalOctave(reference, fraction: 6)
        let matched = ResponseComparison.levelMatched(smoothedMeasured, to: smoothedReference)
        let difference = ResponseComparison.difference(matched, smoothedReference)
        return zip(difference.frequencies, difference.decibels)
            .filter { $0.0 >= 100 && $0.0 <= 16000 }
            .map { abs($0.1) }
            .max() ?? .infinity
    }

    /// The simulated speaker's own response on the same grid as `measured`.
    static func expected(_ speaker: SimulatedSpeaker, like measured: MagnitudeResponse) -> MagnitudeResponse {
        MagnitudeResponse(
            frequencies: measured.frequencies,
            decibels: measured.frequencies.map {
                Float(20 * log10(speaker.linearGain(at: Double($0), sampleRate: Fixture.sampleRate)))
            }
        )
    }
}

/// Records every state a session passes through, and can act on one.
@MainActor
final class StateLog {
    private(set) var states: [MeasurementSession.State] = []

    init(_ session: MeasurementSession, onState: ((MeasurementSession.State, MeasurementSession) -> Void)? = nil) {
        session.onStateChange = { [self, unowned session] state in
            states.append(state)
            onState?(state, session)
        }
    }

    var pauses: [(run: Int, frequency: Double)] {
        states.compactMap {
            if case .paused(let run, let frequency) = $0 { return (run, frequency) }
            return nil
        }
    }

    var notes: [RunNote] {
        states.compactMap {
            if case .playing(_, let note?) = $0 { return note }
            return nil
        }
    }
}

extension MeasurementSession.State {
    var result: MeasurementResult? {
        if case .finished(let result) = self { return result }
        return nil
    }

    var failure: MeasurementFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var isChecking: Bool {
        if case .checking = self { return true }
        return false
    }
}
