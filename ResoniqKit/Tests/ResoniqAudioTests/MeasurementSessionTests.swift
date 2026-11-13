import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

@MainActor
@Suite struct MeasurementSessionTests {
    @Test func `a clean test ends with three recordings that deconvolve to the speaker`() async throws {
        let io = Fixture.io()
        let session = Fixture.session(io: io)
        let log = StateLog(session)
        let final = await session.run()

        let result = try #require(final.result, "ended \(final)")
        #expect(result.runs.map(\.run) == [1, 2, 3])
        #expect(result.runs.allSatisfy { $0.spliceCount == 0 && $0.attempt == 1 && !$0.phoneMoved })
        #expect(log.pauses.isEmpty)
        for run in result.runs {
            let measured = ResponseCheck.response(run.samples)
            let worst = ResponseCheck.worstDifference(measured, ResponseCheck.expected(.bookshelf, like: measured))
            print("clean run \(run.run): worst response error \(worst) dB")
            #expect(worst < 0.5)
        }
        #expect(!io.isRunning && !io.isPlaying && !session.isRunning)
    }

    @Test func `a route delay of 1.5 s is waited for and measured`() async throws {
        let io = Fixture.io(routeDelay: 1.5)
        let session = Fixture.session(io: io)
        let final = await session.run()

        let result = try #require(final.result, "ended \(final)")
        for run in result.runs {
            let response = Deconvolution.impulseResponse(recording: run.samples, sweep: Fixture.sweep)
            // The recording starts `leadIn` before the sweep was sent; the filters add under a millisecond.
            let expected = 1.5 + Double(run.leadIn) / Fixture.sampleRate
            #expect(abs(response.delay - expected) < 0.002)
            let estimate = try #require(run.arrivalDelay)
            print("1.5 s route: live estimate \(estimate) s, deconvolved \(response.delay) s")
            #expect(abs(estimate - expected) < 0.05)
            let measured = response.frequencyResponse()
            #expect(ResponseCheck.worstDifference(measured, ResponseCheck.expected(.bookshelf, like: measured)) < 0.5)
        }
    }

    @Test func `a noise burst pauses the run, which resumes before the pause and splices cleanly`() async throws {
        // Run 2 is the second buffer scheduled. Noise 2.0 s into it, at about 470 Hz of the 4 s sweep, for 0.6 s.
        let burst = NoiseBurst(start: .afterScheduling(buffer: 1, offset: 2.0), duration: 0.6, rms: 0.02)
        let io = Fixture.io(bursts: [burst])
        let session = Fixture.session(io: io)
        let log = StateLog(session)
        let final = await session.run()

        let result = try #require(final.result, "ended \(final)")
        let pause = try #require(log.pauses.first)
        #expect(log.pauses.count == 1)
        #expect(pause.run == 2)
        // The sweep sent at the burst was at f(2.0 s); the resume point is earlier, by the overlap and more.
        let atNoise = Fixture.sweep.frequency(at: 2.0 - 0.02)
        #expect(pause.frequency < atNoise)
        #expect(pause.frequency > Fixture.sweep.frequency(at: 2.0 - 0.02 - 0.7))
        #expect(result.runs.map(\.spliceCount) == [0, 1, 0])

        let uninterrupted = ResponseCheck.response(result.runs[0].samples)
        let spliced = ResponseCheck.response(result.runs[1].samples)
        let worst = ResponseCheck.worstDifference(spliced, uninterrupted)
        print("spliced run against an uninterrupted one: worst difference \(worst) dB; resumed at \(pause.frequency) Hz")
        #expect(worst < 0.5)
        #expect(ResponseCheck.worstDifference(spliced, ResponseCheck.expected(.bookshelf, like: spliced)) < 0.5)
    }

    @Test func `noise early in a run restarts it from the beginning`() async throws {
        // 0.3 s in, at about 18 Hz, long before the sweep reaches 100 Hz, so there is no delay estimate to place a splice by.
        let burst = NoiseBurst(start: .afterScheduling(buffer: 0, offset: 0.3), duration: 0.5, rms: 0.02)
        let io = Fixture.io(bursts: [burst])
        let session = Fixture.session(io: io)
        let log = StateLog(session)
        let final = await session.run()

        let result = try #require(final.result, "ended \(final)")
        #expect(log.pauses.first?.frequency == Fixture.sweep.startFrequency)
        #expect(log.notes.contains(.restarted(.noiseTooEarly)))
        #expect(result.runs.map(\.spliceCount) == [0, 0, 0])
    }

    @Test func `noise that never stops leaves the test paused until it is cancelled`() async throws {
        let burst = NoiseBurst(start: .afterScheduling(buffer: 0, offset: 2.0), duration: nil, rms: 0.02)
        let io = Fixture.io(bursts: [burst])
        let session = Fixture.session(io: io)
        let updates = session.progressUpdates()
        session.start()

        var blocksWhilePaused = 0
        for await progress in updates {
            if session.state.isPaused {
                blocksWhilePaused += 1
                #expect(!progress.isRoomQuiet)
                #expect(!io.isPlaying)
                // 5 s of noise, ten times the quiet a resume needs.
                if blocksWhilePaused == 50 { break }
            }
        }
        #expect(session.state.isPaused)
        session.cancel()
        let final = await session.run()
        #expect(final == .failed(.cancelled))
        #expect(!io.isRunning && !session.isRunning)
    }

    @Test func `a clipped run is repeated once and then the test fails`() async throws {
        let loud = SimulatedSpeaker(gain: 8)
        let io = Fixture.io(speaker: loud)
        let session = Fixture.session(io: io)
        let log = StateLog(session)
        let final = await session.run()

        let failure = try #require(final.failure)
        guard case .recordingUnusable(.unusable(.clipped)) = failure else {
            Issue.record("failed with \(failure)")
            return
        }
        #expect(io.scheduledBufferCount == 2)
        #expect(log.notes.count == 1)
        if case .repeating(.unusable(.clipped))? = log.notes.first {} else { Issue.record("notes \(log.notes)") }
    }

    @Test func `denied permission fails before any sound`() async {
        let io = Fixture.io()
        let session = Fixture.session(io: io, permission: .denied)
        let final = await session.run()
        #expect(final == .failed(.permissionDenied))
        #expect(io.startCount == 0 && io.scheduledBufferCount == 0)
    }

    @Test func `an interruption ends the test with that reason`() async {
        let io = Fixture.io()
        let session = Fixture.session(io: io)
        _ = StateLog(session) { state, _ in
            if state == .playing(run: 2, note: nil) { io.fail(with: .interrupted) }
        }
        let final = await session.run()
        #expect(final == .failed(.interrupted))
        #expect(!io.isRunning)
    }

    @Test func `a phone that moves is noted on its run`() async throws {
        let io = Fixture.io()
        let stillness = ConstantStillnessMonitor()
        let session = Fixture.session(io: io, stillness: stillness)
        _ = StateLog(session) { state, _ in
            if state == .playing(run: 2, note: nil) { stillness.isSteady = false }
            if state == .checking(run: 2) { stillness.isSteady = true }
        }
        let final = await session.run()
        let result = try #require(final.result)
        #expect(result.runs.map(\.phoneMoved) == [false, true, false])
        #expect(!stillness.isStarted)
    }

    enum Moment: String, CaseIterable, Sendable {
        case idle, measuringNoiseFloor, playing, paused, checking
    }

    @Test(arguments: Moment.allCases)
    func `cancelling stops playback and leaves nothing running`(at moment: Moment) async {
        let burst = NoiseBurst(start: .afterScheduling(buffer: 0, offset: 2.0), duration: nil, rms: 0.02)
        let io = Fixture.io(bursts: moment == .paused ? [burst] : [])
        let session = Fixture.session(io: io)
        var cancelledIn: MeasurementSession.State?
        _ = StateLog(session) { state, session in
            guard cancelledIn == nil else { return }
            let matches = switch moment {
            case .idle: false
            case .measuringNoiseFloor: state == .measuringNoiseFloor
            case .playing: state.isPlaying
            case .paused: state.isPaused
            case .checking: state.isChecking
            }
            if matches {
                cancelledIn = state
                session.cancel()
            }
        }
        if moment == .idle { session.cancel() }
        let final = await session.run()
        #expect(final == .failed(.cancelled))
        #expect(moment == .idle || cancelledIn != nil)
        #expect(!io.isRunning && !io.isPlaying && !session.isRunning)
        if moment == .idle { #expect(io.startCount == 0) }
    }

    @Test func `progress reports each run in turn with the frequency rising`() async throws {
        let io = Fixture.io(routeDelay: 0.3)
        let session = Fixture.session(io: io)
        let updates = session.progressUpdates()
        let final = await session.run()
        #expect(final.result != nil)

        var seen: [MeasurementProgress] = []
        for await progress in updates { seen.append(progress) }
        #expect(seen.allSatisfy { $0.runCount == 3 })
        // Run numbers never go back.
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.run <= $1.run })
        for run in 1...3 {
            let frequencies = seen.filter { $0.run == run }.compactMap(\.frequency)
            #expect(frequencies.count > 20)
            #expect(zip(frequencies, frequencies.dropFirst()).allSatisfy { $0 < $1 })
            // Run 1 shows a frequency once the delay is known, a few blocks after 100 Hz; later runs know it from the start.
            #expect((frequencies.first ?? .infinity) < (run == 1 ? 250 : 30), "run \(run): \(frequencies.prefix(3))")
            #expect((frequencies.last ?? 0) > 10000)
        }
        #expect(seen.contains { $0.isRoomQuiet && $0.quietEnoughLevel != nil })
        #expect(!seen.contains { $0.isClipping })
        let delay = try #require(seen.last?.routeDelay)
        #expect(abs(delay - 0.3) < 0.05)
    }

    /// Two runs: the first learns the route's delay, the second starts with it known, which is all a third would add.
    static let twoRuns = MeasurementConfiguration(runCount: 2)

    @Test func `blocks of any size are accepted`() async throws {
        let io = Fixture.io(blockSize: 1031)
        let final = await Fixture.session(io: io, configuration: Self.twoRuns).run()
        #expect(final.result?.runs.count == 2)
    }

    @Test func `odd blocks, a long route and a loud burst do not trap the noise detector`() async throws {
        // This trapped in `SweepNoiseDetector.assess` (crossed range bounds) before its peak interpolation was bounded.
        // The burst comes 3 s into a run after the first, as it did in the third of three.
        let burst = NoiseBurst(start: .afterScheduling(buffer: 1, offset: 3.0), duration: 0.4, rms: 0.05)
        let io = Fixture.io(routeDelay: 0.7, bursts: [burst], blockSize: 1031)
        let final = await Fixture.session(io: io, configuration: Self.twoRuns).run()
        #expect(final.result?.runs.count == 2, "ended \(final)")
    }

    @Test func `a stream slower than 44.1 kHz fails before any sound`() async {
        let io = SimulatedAudioIO(configuration: .init(sampleRate: 22050, pacing: .immediate))
        let final = await Fixture.session(io: io).run()
        guard case .failed(.audioUnavailable) = final else {
            Issue.record("ended \(final)")
            return
        }
        #expect(io.scheduledBufferCount == 0 && !io.isRunning)
    }
}

/// The check every finished recording gets (`MeasurementSession.check`), on recordings made by hand.
@Suite struct RecordingCheckTests {
    static let leadIn = 2400

    /// Deterministic low-level hiss, steady enough to be a floor.
    static func hiss(count: Int, offset: Int = 0) -> [Float] {
        (0..<count).map { index in
            let x = sin(Double(index + offset) * 12.9898) * 43758.5453
            return Float(x - x.rounded(.down) - 0.5) * 2e-4
        }
    }

    static let floor = NoiseFloor.measure(hiss(count: 48000), sampleRate: Fixture.sampleRate)

    /// The sweep, `leadIn` samples late, with `tail` seconds after it, over the hiss.
    static func recording(tail: Double = 0.5) -> [Float] {
        let sweep = Fixture.sweep.samples()
        let count = leadIn + sweep.count + Int(tail * Fixture.sampleRate)
        var samples = hiss(count: max(count, 0), offset: 7)
        for (index, value) in sweep.enumerated() where leadIn + index < samples.count {
            samples[leadIn + index] += value
        }
        return samples
    }

    func check(_ samples: [Float]) async -> (verdict: RecordingVerdict, problem: RunProblem?) {
        await MeasurementSession.check(samples, sweep: Fixture.sweep, floor: Self.floor, thresholds: .standard)
    }

    @Test func `a whole recording passes`() async {
        let result = await check(Self.recording())
        #expect(result.problem == nil, "\(result.verdict)")
    }

    @Test func `a recording holding a non-finite sample is a bad run`() async {
        var samples = Self.recording()
        samples[100_000] = .nan
        let result = await check(samples)
        #expect(result.problem == .unusable(.corrupt(nonFiniteSampleCount: 1)))
    }

    @Test func `a recording that stopped before the sweep's end arrived did not arrive`() async {
        // Cut 0.3 s before the sweep's last sample: valid by level, but the top of the sweep is missing.
        let result = await check(Self.recording(tail: -0.3))
        guard case .valid = result.verdict else {
            Issue.record("verdict \(result.verdict)")
            return
        }
        #expect(result.problem == .didNotArrive)
    }
}
