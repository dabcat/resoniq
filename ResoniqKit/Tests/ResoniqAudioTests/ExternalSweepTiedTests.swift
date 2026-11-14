import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// The listening sessions cannot pause the player to see whether noise follows the sweep, so they compare runs: noise
/// at the same place of the sweep in two or more runs is tied to the sweep (`SweepTiedNoise`); noise at one place in
/// one run is the room's.
@MainActor
@Suite(.timeLimit(.minutes(4))) struct ExternalSweepTiedTests {
    static func rattling(_ level: Double = 0.01) -> SimulatedSpeaker {
        var speaker = SimulatedSpeaker.bookshelf
        speaker.rattle = .init(band: 180...320, level: level)
        return speaker
    }

    /// The fixture the normal test finishes with and reports as a possible rattle: a rattle 40 dB under the sweep at
    /// 180–320 Hz. Every run was refused as too noisy, and the room blamed.
    @Test func `a rattling speaker finishes with one play, each run marked where the rattle was`() async throws {
        let io = Fixture.io(speaker: Self.rattling())
        let session = ExternalFixture.session(io: io)
        let log = ExternalStateLog(session) { state in
            if state == .waitingForSound, io.externalPlayCount == 0 { io.playExternally(ExternalFixture.play()) }
            if case .needsAnotherPlay = state, io.externalPlayCount < 3 { io.playExternally(ExternalFixture.play(delay: 1)) }
        }
        let final = await session.run()
        let result = try #require(final.result, "\(log.summary)")
        print("external rattle: tied \(result.runs.map { $0.sweepTiedSound.map { "\(Int($0.lowerBound))–\(Int($0.upperBound)) Hz" } ?? "none" })")
        #expect(log.anotherPlays.isEmpty, "\(log.summary)")
        #expect(result.runs.count == 3)
        for run in result.runs {
            let tied = try #require(run.sweepTiedSound, "run \(run.run) not marked")
            #expect(tied.lowerBound < 320 && tied.upperBound > 180, "marked at \(tied)")
        }
    }

    /// A door or a voice during one run: that run is dropped and another play is asked for, which completes the test
    /// with nothing marked.
    @Test func `a noise burst in one run is the room's: that run is dropped and another play asked for`() async throws {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        let burst = NoiseBurst(start: .at(ExternalFixture.sweepTime(.speakerTest(.left), 1) + 1.5), duration: 0.6, rms: 0.03)
        let log = ExternalStateLog(session) { state in
            if state == .waitingForSound, io.externalPlayCount == 0 { io.playExternally(ExternalFixture.play(bursts: [burst])) }
            if case .needsAnotherPlay = state, io.externalPlayCount == 1 { io.playExternally(ExternalFixture.play(delay: 2)) }
        }
        let final = await session.run()
        let result = try #require(final.result, "\(log.summary)")
        guard case .needsAnotherPlay(let have, let reason) = try #require(log.anotherPlays.first) else { return }
        #expect(have == 2)
        if case .run(.unusable(.tooNoisy)) = reason {} else { Issue.record("asked again for \(String(describing: reason))") }
        #expect(result.runs.allSatisfy { $0.sweepTiedSound == nil })
        #expect(result.runs.map(\.attempt) == [1, 1, 2])
    }

    /// Noise at different places in different runs is the room's, however often it comes.
    @Test func `noise at different places in two runs is not tied`() {
        var ledger = SweepTiedNoise(tolerance: 0.15)
        ledger.record(id: 1, stretches: [1.0...1.2])
        ledger.record(id: 2, stretches: [2.5...2.7])
        #expect(!ledger.isTied(1) && !ledger.isTied(2))
        ledger.record(id: 3, stretches: [1.1...1.3, 3.5...3.6])
        // Run 3's first stretch matches run 1's, its second matches nothing: run 3 stays the room's; run 1 is tied.
        #expect(ledger.isTied(1))
        #expect(!ledger.isTied(3))
        #expect(SweepTiedNoise.merged([2.0...2.1, 1.0...1.1, 1.1...1.2]) == [1.0...1.2, 2.0...2.1])
    }
}
