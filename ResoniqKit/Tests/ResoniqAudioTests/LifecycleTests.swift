import Foundation
import Testing
@testable import ResoniqAudio

/// The app calls `cancel()` (the tone: `stop()`) when the scene leaves the foreground, whatever is happening: it
/// must be safe before the start, during, after the end and more than once.
@MainActor
@Suite(.timeLimit(.minutes(3))) struct LifecycleTests {
    @Test func `a speaker test can be cancelled before, during, after and twice`() async {
        let early = Fixture.session(io: Fixture.io())
        early.cancel()
        early.cancel()
        #expect(await early.run() == .failed(.cancelled))

        let io = Fixture.io()
        let running = Fixture.session(io: io)
        _ = StateLog(running) { state, session in
            if state.isPlaying { session.cancel(); session.cancel() }
        }
        #expect(await running.run() == .failed(.cancelled))
        #expect(!io.isRunning && !io.isPlaying && !running.isRunning)

        let finished = Fixture.session(io: Fixture.io())
        let final = await finished.run()
        #expect(final.result != nil)
        finished.cancel()
        #expect(finished.state == final)
    }

    @Test func `a seat measurement can be cancelled before, during, after and twice`() async {
        let early = SeatFixture.session(io: SeatFixture.io())
        early.cancel()
        early.cancel()
        #expect(await early.run() == .failed(.cancelled))

        let io = SeatFixture.io()
        let running = SeatFixture.session(io: io)
        _ = SeatStateLog(running) { state, session in
            if case .waitingForStillness(.left) = state { session.cancel(); session.cancel(); session.skipToResult() }
        }
        #expect(await running.run() == .failed(.cancelled))
        #expect(!io.isRunning && !io.isPlaying && !running.isRunning)

        let skipped = SeatFixture.session(io: SeatFixture.io())
        _ = SeatStateLog(skipped) { state, session in
            if state == .spotCaptured(spot: .seat) { session.skipToResult() }
        }
        let final = await skipped.run()
        #expect(final.result?.spots.count == 1)
        skipped.cancel()
        skipped.skipToResult()
        #expect(skipped.state == final)
    }
}
