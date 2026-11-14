import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// What a finished speaker test hands on so its recordings can be kept: the room's floor as it was recorded, and the
/// routes the IO reported when the test opened.
@MainActor
@Suite(.timeLimit(.minutes(3))) struct KeptRecordingTests {
    @Test func `a finished test carries the floor it was measured against`() async throws {
        let session = Fixture.session(io: Fixture.io())
        let final = await session.run()
        guard case .finished(let result) = final else {
            Issue.record("ended \(final)")
            return
        }
        // The floor recording is the noise-floor window: a second at the stream's rate.
        let expected = Fixture.configuration.samples(Fixture.configuration.noiseFloorDuration, at: Fixture.sampleRate)
        #expect(result.noiseFloorSamples.count == expected)
        // It is the very recording the report was made from.
        let again = NoiseFloor.measure(result.noiseFloorSamples, sampleRate: Fixture.sampleRate)
        #expect(again == result.noiseFloor)
    }

    @Test func `a finished test carries the routes the IO reported`() async throws {
        let io = SimulatedAudioIO(configuration: .init(
            pacing: .immediate,
            outputRoute: AudioOutputRoute(kind: .wired, name: "Line out"),
            inputRoute: AudioInputRoute(kind: .builtInMicrophone, name: "iPhone Microphone")
        ))
        let final = await Fixture.session(io: io).run()
        guard case .finished(let result) = final else {
            Issue.record("ended \(final)")
            return
        }
        #expect(result.outputRoute == AudioOutputRoute(kind: .wired, name: "Line out"))
        #expect(result.inputRoute == AudioInputRoute(kind: .builtInMicrophone, name: "iPhone Microphone"))
    }

    @Test func `a listening test carries its floor and its input, and no output of its own`() async throws {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        _ = ExternalStateLog(session, onState: ExternalMeasurementSessionTests.pressPlayOnce(io, ExternalFixture.play()))
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")
        let expected = Fixture.configuration.samples(Fixture.configuration.noiseFloorDuration, at: Fixture.sampleRate)
        #expect(result.noiseFloorSamples.count == expected)
        #expect(NoiseFloor.measure(result.noiseFloorSamples, sampleRate: Fixture.sampleRate) == result.noiseFloor)
        #expect(result.inputRoute == .simulatedMicrophone)
        // Another device played the sound: what the phone's own output was says nothing about it.
        #expect(result.outputRoute == nil)
    }

    @Test func `an IO that cannot tell reports no input`() {
        final class Plain: AudioIO, @unchecked Sendable {
            func start() async throws -> CaptureStream { throw AudioIOError.notRunning }
            func schedule(_ samples: [Float], on channel: SpeakerChannel, mode: PlaybackMode) throws -> Int64 { 0 }
            func stopPlayback() {}
            func stop() async {}
        }
        #expect(Plain().inputRoute == nil)
    }
}
