import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// The listening sessions at the listening seat: the room's sound outweighs the direct sound.
@MainActor
@Suite(.timeLimit(.minutes(5))) struct ExternalListeningRoomTests {
    static func session(_ signal: [Float], channel: SpeakerChannel = .left) -> (ExternalMeasurementSession, ExternalStateLog) {
        let session = ExternalMeasurementSession(
            io: PreparedAudioIO(signal), channel: channel, permission: SimulatedMicrophonePermission(.granted),
            stillness: ConstantStillnessMonitor(), configuration: Fixture.configuration
        )
        return (session, ExternalStateLog(session))
    }

    /// The seat case of the review: 2–3 m from the speakers in a furnished room, the reverberant sound 6–10 dB over
    /// the direct sound. One play finishes the test.
    @Test(arguments: [DenseRoom(directToReverberant: -6, reverberationTime: 0.6), DenseRoom(directToReverberant: -10, reverberationTime: 1.0)])
    func `a speaker test at the listening seat finishes with one play`(room: DenseRoom) async throws {
        let signal = heardFile(TestSoundFile(kind: .speakerTest(.left)), noise: 1e-3, room: room)
        let (session, log) = Self.session(signal)
        let final = await session.run()
        let result = try #require(final.result, "\(room): \(log.summary)")
        #expect(result.runs.count == 3)
        #expect(log.anotherPlays.isEmpty, "\(log.summary)")
    }

    enum Interruption: CustomTestStringConvertible, Sendable {
        /// The player stopped `at` seconds into the third sweep.
        case stopped(at: Double)
        /// The player paused for six seconds `at` seconds into the second sweep.
        case paused(at: Double)

        var testDescription: String {
            switch self {
            case .stopped(let at): "stopped \(at) s into sweep 3"
            case .paused(let at): "paused 6 s at \(at) s into sweep 2"
            }
        }
    }

    /// The review's cases: each finished with the cut-short run kept, reading 70 dB down above the stop. Now that run
    /// is refused as stopped part-way and the file asked for again; the second play completes the test with runs that
    /// agree.
    @Test(arguments: [Interruption.stopped(at: 3.0), .stopped(at: 3.4), .paused(at: 3.0), .paused(at: 3.4)])
    func `a sweep cut short by the player is refused, and another play completes the test`(interruption: Interruption) async throws {
        let file = TestSoundFile(kind: .speakerTest(.left))
        let first = heardFile(file, after: 12) { mono, layout in
            switch interruption {
            case .stopped(let at):
                for index in (layout.sweeps[2].offset + Int(at * 48000))..<mono.count { mono[index] = 0 }
            case .paused(let at):
                mono.insert(contentsOf: [Float](repeating: 0, count: 6 * 48000), at: layout.sweeps[1].offset + Int(at * 48000))
            }
        }
        let (session, log) = Self.session(first + heardFile(file, before: 2))
        let final = await session.run()
        let result = try #require(final.result, "\(log.summary)")
        let reasons = log.anotherPlays.compactMap { if case .needsAnotherPlay(_, let reason) = $0 { reason } else { nil } }
        if case .stopped = interruption { #expect(reasons.first == .stoppedPartWay, "\(log.summary)") }
        #expect(!reasons.isEmpty)
        // No run in the result is cut short: they agree with each other above the stop.
        let responses = result.runs.map { Deconvolution.impulseResponse(recording: $0.samples, sweep: Fixture.sweep) }
        #expect(responses.allSatisfy { SweepCompleteness.stopFrequency(of: $0) == nil })
        let disagreement = try #require(SweepCompleteness.disagreement(responses))
        #expect(disagreement.allSatisfy { $0 < 1 }, "\(disagreement)")
    }
}
