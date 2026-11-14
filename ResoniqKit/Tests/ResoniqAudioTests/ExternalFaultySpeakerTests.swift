import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// The speakers the app exists to diagnose, played from another device: each must still be found, measured and
/// handed to the analysis, or, when this mode cannot test it, told truthfully.
@MainActor
@Suite(.timeLimit(.minutes(8))) struct ExternalFaultySpeakerTests {
    /// An edge of `order` sections (12 dB an octave each).
    static func edge(_ filter: SimulatedFilter, order: Int = 4) -> [SimulatedFilter] { Array(repeating: filter, count: order) }

    static let deadTweeter = SimulatedSpeaker(gain: 0.5, filters: [.highPass(frequency: 60, q: 0.707)] + edge(.lowPass(frequency: 2000, q: 0.707)))
    static let deadWoofer = SimulatedSpeaker(gain: 0.5, filters: edge(.highPass(frequency: 500, q: 0.707)))
    static let narrow = SimulatedSpeaker(gain: 0.5, filters: edge(.highPass(frequency: 200, q: 0.707)) + edge(.lowPass(frequency: 2000, q: 0.707)))
    static let subwoofer = SimulatedSpeaker(gain: 0.5, filters: edge(.lowPass(frequency: 150, q: 0.707)))
    /// A tweeter alone (a two-way speaker whose woofer is gone): too little at 1 kHz for the clock tone to be heard.
    static let tweeterOnly = SimulatedSpeaker(gain: 0.5, filters: edge(.highPass(frequency: 1800, q: 0.707), order: 6))

    struct Outcome {
        let final: ExternalMeasurementSession.State
        let states: [ExternalMeasurementSession.State]
        let progress: [ExternalMeasurementProgress]
    }

    /// A left speaker test of `speaker`: play when asked, again (up to `plays` in all) when asked to.
    static func listen(to speaker: SimulatedSpeaker, ratio: Double = 1, gain: Double = 1, noiseRMS: Double = 1e-4, plays: Int = 2) async -> Outcome {
        let io = Fixture.io(speaker: speaker, noiseRMS: noiseRMS)
        let session = ExternalFixture.session(io: io)
        var asked: [ExternalPlayProblem?] = []
        let log = ExternalStateLog(session) { state in
            switch state {
            case .waitingForSound where io.externalPlayCount == 0 && plays > 0:
                io.playExternally(ExternalFixture.play(ratio: ratio, gain: gain))
            case .needsAnotherPlay(_, let reason) where io.externalPlayCount < plays && !asked.contains(reason):
                asked.append(reason)
                io.playExternally(ExternalFixture.play(delay: 1, ratio: ratio, gain: gain))
            default: break
            }
        }
        var progress: [ExternalMeasurementProgress] = []
        let watcher = Task { for await update in session.progressUpdates() { progress.append(update) } }
        let final = await session.run()
        await watcher.value
        return Outcome(final: final, states: log.states, progress: progress)
    }

    /// Level of a run's response at `frequency`, dB, read from the deconvolved recording.
    static func level(_ run: RunRecording, at frequency: Float) -> Float {
        Smoothing.fractionalOctave(ResponseCheck.response(run.samples), fraction: 3).decibels(at: frequency)
    }

    @Test func `a dead tweeter is found, measured, and its silence above 2 kHz is in the runs`() async throws {
        let outcome = await Self.listen(to: Self.deadTweeter)
        let result = try #require(outcome.final.result, "ended \(outcome.final)")
        #expect(result.runs.count == 3)
        for run in result.runs {
            let drop = Self.level(run, at: 500) - Self.level(run, at: 8000)
            print("dead tweeter run \(run.run): 8 kHz is \(drop) dB under 500 Hz")
            #expect(drop > 40)
            #expect(abs((run.clockRatio ?? 0) - 1) < 2e-6)
        }
    }

    @Test func `a dead woofer is found, measured, and its silence under 500 Hz is in the runs`() async throws {
        let outcome = await Self.listen(to: Self.deadWoofer)
        let result = try #require(outcome.final.result, "ended \(outcome.final)")
        #expect(result.runs.count == 3)
        for run in result.runs {
            let drop = Self.level(run, at: 2000) - Self.level(run, at: 100)
            print("dead woofer run \(run.run): 100 Hz is \(drop) dB under 2 kHz")
            #expect(drop > 40)
        }
    }

    @Test func `a speaker that plays only 200 Hz to 2 kHz is found and measured`() async throws {
        let outcome = await Self.listen(to: Self.narrow)
        let result = try #require(outcome.final.result, "ended \(outcome.final)")
        #expect(result.runs.count == 3)
        for run in result.runs {
            #expect(Self.level(run, at: 700) - Self.level(run, at: 8000) > 40)
            let bass = Self.level(run, at: 700) - Self.level(run, at: 60)
            print("narrow run \(run.run): 60 Hz is \(bass) dB under 700 Hz")
            // 83 dB in the filter; the deconvolution's bass and its noise read less.
            #expect(bass > 20)
        }
    }

    @Test func `a subwoofer alone is heard but not recognised, and the session says so`() async {
        let outcome = await Self.listen(to: Self.subwoofer)
        #expect(outcome.final.failure == .soundNotRecognised)
        #expect(outcome.progress.contains { $0.hearing == .notTheTestSound })
        #expect(!outcome.states.contains { if case .hearing = $0 { true } else { false } })
    }

    @Test func `without the clock tone the clock comes from the spacing of the sweeps`() async throws {
        let outcome = await Self.listen(to: Self.tweeterOnly, ratio: 1.0002, noiseRMS: 1e-3, plays: 3)
        let result = try #require(outcome.final.result, "ended \(outcome.final)")
        #expect(!outcome.progress.contains { $0.isHearingTone }, "the tone was heard; the fallback is not tested")
        print("tweeter only: runs from plays \(result.runs.map(\.attempt)), asked again \(outcome.states.filter { if case .needsAnotherPlay = $0 { true } else { false } }.count) times")
        for run in result.runs {
            let error = ((run.clockRatio ?? 0) - 1.0002) * 1e6
            print("tweeter only run \(run.run): clock from the spacing, off by \(error) ppm")
            #expect(abs(error) < 10)
        }
    }

    @Test func `the three things the screen tells apart: nothing, not the test sound, the test sound incomplete`() async {
        // Nothing at all.
        let silent = await Self.listen(to: .bookshelf, plays: 0)
        #expect(silent.final.failure == .nothingHeard)
        #expect(silent.progress.contains { $0.hearing == .nothing && $0.silentFor != nil })
        #expect(!silent.progress.contains { $0.hearing == .notTheTestSound })

        // Sound, but not the test sound: ten seconds of loud noise while waiting.
        let io = Fixture.io(bursts: [NoiseBurst(start: .at(3), duration: 10, rms: 0.01)])
        let session = ExternalFixture.session(io: io)
        var hearings: [ExternalHearing] = []
        let watcher = Task { for await update in session.progressUpdates() { hearings.append(update.hearing) } }
        let final = await session.run()
        await watcher.value
        #expect(final.failure == .soundNotRecognised)
        #expect(hearings.contains(.notTheTestSound))

        // The test sound, but far too quiet.
        let quiet = await Self.listen(to: .bookshelf, gain: 0.005, plays: 1)
        #expect(quiet.states.contains { if case .needsAnotherPlay(_, .run(.unusable(.tooQuiet))) = $0 { true } else { false } })
        #expect(quiet.progress.contains { $0.hearing == .testSoundIncomplete })
    }
}
