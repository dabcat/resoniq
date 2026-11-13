import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// Sound that follows the sweep (a rattle, the room's reverberation) is not the room's background: pausing for it
/// and resuming meets it again at the same place. And a room that never quietens ends the test instead of waiting
/// forever.
@MainActor
@Suite(.timeLimit(.minutes(3))) struct SweepTiedSoundTests {
    static func io(speaker: SimulatedSpeaker = .bookshelf, room: SimulatedRoom? = nil, bursts: [NoiseBurst] = []) -> SimulatedAudioIO {
        SimulatedAudioIO(configuration: .init(
            sampleRate: Fixture.sampleRate,
            routeDelay: 0.02,
            bursts: bursts,
            left: speaker,
            right: speaker,
            pacing: .immediate,
            room: room
        ))
    }

    @Test func `a rattle 40 dB under the sweep is heard as tied to it, and the test finishes`() async throws {
        var speaker = SimulatedSpeaker.bookshelf
        speaker.rattle = .init(band: 180...320, level: 0.01)
        let io = Self.io(speaker: speaker)
        let session = Fixture.session(io: io)
        let log = StateLog(session)
        let final = await session.run()

        let result = try #require(final.result, "ended \(final) after \(log.pauses.count) pauses")
        print("rattle: \(log.pauses.count) pauses; tied \(result.runs.map { $0.sweepTiedSound.map { "\(Int($0.lowerBound))–\(Int($0.upperBound)) Hz" } ?? "none" })")
        #expect(log.pauses.count <= result.runs.count * Fixture.configuration.maximumPauses)
        let tied = try #require(result.runs.compactMap(\.sweepTiedSound).first)
        // The rattle's band, give or take the band-pass skirt and a block.
        #expect(tied.lowerBound < 320 && tied.upperBound > 180)
    }

    @Test(arguments: [0.5, 0.8])
    func `a reverberant room with the tail as loud as the direct sound finishes`(reverberationTime: Double) async throws {
        // Four combs at 0.37: the tail's energy about equals the direct sound's.
        let room = SimulatedRoom(modes: [], reverberationTime: reverberationTime, reverberationLevel: 0.37)
        let io = Self.io(room: room)
        let session = Fixture.session(io: io)
        let log = StateLog(session)
        let final = await session.run()
        let result = try #require(final.result, "ended \(final) after \(log.pauses.count) pauses")
        print("reverberation \(reverberationTime) s: \(log.pauses.count) pauses, tied \(result.runs.map { $0.sweepTiedSound != nil })")
        // The reverberation allowance takes the tail out with the sweep: no pause, and nothing marked as a rattle.
        #expect(log.pauses.isEmpty)
        #expect(result.runs.allSatisfy { $0.sweepTiedSound == nil })
    }

    @Test func `a reverberant room beyond the allowance is caught as sound tied to the sweep and finishes`() async throws {
        // 1.5 s, twice the allowance: the tail pauses the run, then is recognised where it comes back.
        let room = SimulatedRoom(modes: [], reverberationTime: 1.5, reverberationLevel: 0.37)
        let io = Self.io(room: room)
        let session = Fixture.session(io: io)
        let log = StateLog(session)
        let final = await session.run()
        let result = try #require(final.result, "ended \(final) after \(log.pauses.count) pauses")
        print("reverberation 1.5 s: \(log.pauses.count) pauses, tied \(result.runs.map { $0.sweepTiedSound != nil })")
        #expect(log.pauses.count <= result.runs.count * Fixture.configuration.maximumPauses)
    }

    @Test func `noise that never stops ends the test as too noisy after the longest wait`() async throws {
        let burst = NoiseBurst(start: .afterScheduling(buffer: 0, offset: 2.0), duration: nil, rms: 0.02)
        let io = Self.io(bursts: [burst])
        let session = Fixture.session(io: io)
        let updates = session.progressUpdates()
        let final = await session.run()
        #expect(final == .failed(.tooNoisy))
        var pausedBlocks = 0
        for await progress in updates where progress.frequency == nil && !progress.isRoomQuiet && progress.quietEnoughLevel != nil {
            pausedBlocks += 1
        }
        let waited = Double(pausedBlocks) * Fixture.configuration.blockDuration
        #expect(waited >= Fixture.configuration.maximumPauseWait - 0.5)
        #expect(!io.isRunning && !io.isPlaying)
    }
}
