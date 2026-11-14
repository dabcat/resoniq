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
}
