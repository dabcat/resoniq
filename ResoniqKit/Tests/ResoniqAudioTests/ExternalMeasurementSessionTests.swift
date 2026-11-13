import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// A listening speaker test driven by a simulated external player: the test presses play when the session says so.
@MainActor
enum ExternalFixture {
    static func session(io: SimulatedAudioIO, channel: SpeakerChannel = .left, permission: MicrophoneAccess = .granted,
                        stillness: ConstantStillnessMonitor = ConstantStillnessMonitor()) -> ExternalMeasurementSession {
        ExternalMeasurementSession(
            io: io, channel: channel, permission: SimulatedMicrophonePermission(permission), stillness: stillness,
            configuration: Fixture.configuration
        )
    }

    /// The speaker test's file, played as told.
    static func play(_ kind: TestSoundFile.Kind = .speakerTest(.left), delay: Double = 0.5, ratio: Double = 1, gain: Double = 1,
                     bursts: [NoiseBurst] = []) -> SimulatedExternalPlay {
        SimulatedExternalPlay(file: TestSoundFile(kind: kind), delay: delay, clockRatio: ratio, gain: gain, bursts: bursts)
    }

    /// Seconds from a file's first sample to its sweep `index`.
    static func sweepTime(_ kind: TestSoundFile.Kind, _ index: Int) -> Double {
        Double(TestSoundFile(kind: kind).layout.sweeps[index].offset) / 48000
    }
}

/// Every state a listening session passes through; `onState` may press play.
@MainActor
final class ExternalStateLog {
    private(set) var states: [ExternalMeasurementSession.State] = []

    init(_ session: ExternalMeasurementSession, onState: ((ExternalMeasurementSession.State) -> Void)? = nil) {
        session.onStateChange = { [self] state in
            states.append(state)
            onState?(state)
        }
    }

    var anotherPlays: [ExternalMeasurementSession.State] {
        states.filter { if case .needsAnotherPlay = $0 { true } else { false } }
    }
}

extension ExternalMeasurementSession.State {
    var result: MeasurementResult? {
        if case .finished(let result) = self { return result }
        return nil
    }

    var failure: ExternalMeasurementFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

@MainActor
@Suite(.timeLimit(.minutes(3))) struct ExternalMeasurementSessionTests {
    /// Presses play once, when the session first asks.
    static func pressPlayOnce(_ io: SimulatedAudioIO, _ play: SimulatedExternalPlay) -> (ExternalMeasurementSession.State) -> Void {
        { state in
            if state == .waitingForSound, io.externalPlayCount == 0 { io.playExternally(play) }
        }
    }

    static func expectSpeaker(_ result: MeasurementResult, ratio: Double, sourceLine: SourceLocation = #_sourceLocation) {
        #expect(result.source == .anotherDevice, sourceLocation: sourceLine)
        #expect(result.runs.map(\.run) == [1, 2, 3], sourceLocation: sourceLine)
        for run in result.runs {
            #expect(abs((run.clockRatio ?? 0) - ratio) < 2e-6, "clock \(run.clockRatio ?? 0)", sourceLocation: sourceLine)
            #expect(run.spliceCount == 0 && !run.phoneMoved, sourceLocation: sourceLine)
            if case .valid = run.verdict {} else { Issue.record("run \(run.run) is \(run.verdict)", sourceLocation: sourceLine) }
            // The recording starts the lead-in before the sweep, as a normal run's does.
            #expect(abs((run.measuredDelay ?? 0) - Fixture.configuration.leadIn) < 0.003, "delay \(run.measuredDelay ?? 0)", sourceLocation: sourceLine)
            let measured = ResponseCheck.response(run.samples)
            let worst = ResponseCheck.worstDifference(measured, ResponseCheck.expected(.bookshelf, like: measured))
            print("external run \(run.run): worst response error \(worst) dB")
            #expect(worst < 0.5, sourceLocation: sourceLine)
        }
    }

    @Test func `a clean play finishes with three runs that deconvolve to the speaker`() async throws {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        let log = ExternalStateLog(session, onState: Self.pressPlayOnce(io, ExternalFixture.play()))
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")
        Self.expectSpeaker(result, ratio: 1)
        #expect(io.scheduledBufferCount == 0, "the phone played nothing")
        #expect(log.anotherPlays.isEmpty)
        #expect(log.states.contains(.waitingForSound) && log.states.contains(.hearing(run: 3)) && log.states.contains(.checking(run: 3)))
        #expect(!io.isRunning && !session.isRunning)
    }

    @Test func `play pressed ten seconds late is waited for`() async throws {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        _ = ExternalStateLog(session, onState: Self.pressPlayOnce(io, ExternalFixture.play(delay: 10)))
        var silences: [Double] = []
        let watcher = Task { for await progress in session.progressUpdates() { if let silent = progress.silentFor { silences.append(silent) } } }
        let final = await session.run()
        await watcher.value
        Self.expectSpeaker(try #require(final.result, "ended \(final)"), ratio: 1)
        #expect((silences.max() ?? 0) > 10)
    }

    @Test func `a player 300 ppm fast is measured as accurately as a true one`() async throws {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        _ = ExternalStateLog(session, onState: Self.pressPlayOnce(io, ExternalFixture.play(ratio: 1.0003)))
        var offsets: [Double] = []
        let watcher = Task { for await progress in session.progressUpdates() { if let ppm = progress.clockOffsetPPM { offsets.append(ppm) } } }
        let final = await session.run()
        await watcher.value
        Self.expectSpeaker(try #require(final.result, "ended \(final)"), ratio: 1.0003)
        #expect(abs((offsets.last ?? 0) - 300) < 2)
    }

    @Test func `noise over run 2 asks for another play, which completes the test`() async throws {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        let burst = NoiseBurst(start: .at(ExternalFixture.sweepTime(.speakerTest(.left), 1) + 1.5), duration: 1, rms: 0.03)
        let log = ExternalStateLog(session) { state in
            if state == .waitingForSound, io.externalPlayCount == 0 { io.playExternally(ExternalFixture.play(bursts: [burst])) }
            if case .needsAnotherPlay = state, io.externalPlayCount == 1 { io.playExternally(ExternalFixture.play(delay: 2)) }
        }
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")
        let asked = try #require(log.anotherPlays.first)
        guard case .needsAnotherPlay(let have, let reason) = asked else { return }
        #expect(have == 2)
        if case .run(.unusable(.tooNoisy)) = reason {} else { Issue.record("asked again for \(String(describing: reason))") }
        #expect(result.runs.map(\.attempt) == [1, 1, 2])
        #expect(io.externalPlayCount == 2)
    }

    @Test func `another file's timing is recognised and refused`() async throws {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        let plays: [TestSoundFile.Kind] = [.seat([.left, .right]), .speakerTest(.right), .speakerTest(.left)]
        // The next file is played each time the session names a new reason, as a user reading the screen would.
        var answered: [ExternalPlayProblem?] = []
        let log = ExternalStateLog(session) { state in
            let next = io.externalPlayCount
            switch state {
            case .waitingForSound where next == 0:
                io.playExternally(ExternalFixture.play(plays[next], delay: 1))
            case .needsAnotherPlay(_, let reason) where next < plays.count && !answered.contains(reason):
                answered.append(reason)
                io.playExternally(ExternalFixture.play(plays[next], delay: 1))
            default: break
            }
        }
        let final = await session.run()
        _ = try #require(final.result, "ended \(final)")
        let reasons = log.anotherPlays.compactMap { state -> ExternalPlayProblem? in
            if case .needsAnotherPlay(_, let reason) = state { return reason }
            return nil
        }
        #expect(reasons.contains(.wrongFile(heard: .seat([.left, .right]))))
        #expect(reasons.contains(.wrongFile(heard: .speakerTest(.right))))
        #expect(io.externalPlayCount == 3)
    }

    @Test func `nothing ever played waits, says what to check, then fails at the limit`() async {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        let log = ExternalStateLog(session)
        var long = false
        let watcher = Task { for await progress in session.progressUpdates() where progress.isSilenceLong { long = true } }
        let final = await session.run()
        await watcher.value
        #expect(final.failure == .nothingHeard)
        #expect(long)
        #expect(log.states.contains(.waitingForSound))
        #expect(!log.states.contains { if case .hearing = $0 { true } else { false } })
    }

    @Test func `a play too loud clips, asks for another, and a quieter play completes it`() async throws {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        let log = ExternalStateLog(session) { state in
            if state == .waitingForSound, io.externalPlayCount == 0 { io.playExternally(ExternalFixture.play(gain: 12)) }
            if case .needsAnotherPlay = state, io.externalPlayCount == 1 { io.playExternally(ExternalFixture.play(delay: 1)) }
        }
        let final = await session.run()
        _ = try #require(final.result, "ended \(final)")
        let first = try #require(log.anotherPlays.first)
        guard case .needsAnotherPlay(let have, .run(.unusable(.clipped))) = first else {
            Issue.record("asked for another play with \(first)")
            return
        }
        #expect(have == 0)
    }

    @Test func `a player far off its clock ends the test with that reason`() async {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        _ = ExternalStateLog(session, onState: Self.pressPlayOnce(io, ExternalFixture.play(ratio: 1.0015)))
        let final = await session.run()
        guard case .playerClockOff(let ratio) = final.failure else {
            Issue.record("ended \(final)")
            return
        }
        #expect(abs(ratio - 1.0015) < 1e-5)
    }

    @Test func `denied permission fails before listening`() async {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io, permission: .denied)
        #expect(await session.run().failure == .measurement(.permissionDenied))
        #expect(io.startCount == 0)
    }

    enum Moment: CaseIterable {
        case idle, measuringNoiseFloor, waitingForSound, hearing, checking, needsAnotherPlay
    }

    @Test(arguments: Moment.allCases)
    func `cancel is safe at every state`(moment: Moment) async {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        if moment == .idle {
            session.cancel()
            #expect(session.state == .failed(.measurement(.cancelled)))
            return
        }
        _ = ExternalStateLog(session) { [unowned session] state in
            if state == .waitingForSound, io.externalPlayCount == 0 {
                io.playExternally(ExternalFixture.play(gain: moment == .needsAnotherPlay ? 12 : 1))
            }
            let now: Moment? = switch state {
            case .measuringNoiseFloor: .measuringNoiseFloor
            case .waitingForSound: .waitingForSound
            case .hearing: .hearing
            case .checking: .checking
            case .needsAnotherPlay: .needsAnotherPlay
            default: nil
            }
            if now == moment { session.cancel() }
        }
        let final = await session.run()
        #expect(final == .failed(.measurement(.cancelled)))
        #expect(!io.isRunning)
        session.cancel()
        #expect(session.state == .failed(.measurement(.cancelled)))
    }
}
