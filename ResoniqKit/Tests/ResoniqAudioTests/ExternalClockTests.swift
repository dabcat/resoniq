import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// A stillness monitor that can be told the phone is moving, over another that handles the seat's moves.
@MainActor
final class NudgedStillnessMonitor: SpotAwareStillnessMonitor {
    let base: SimulatedStillnessMonitor
    var isMoving = false

    init(base: SimulatedStillnessMonitor) {
        self.base = base
    }

    var isSteady: Bool { !isMoving && base.isSteady }
    func start() { base.start() }
    func stop() { base.stop() }
    func willWaitForStillness(at spot: SeatSpot) { base.willWaitForStillness(at: spot) }
}

/// The player's clock read two ways: from the tone, which a phone drifting while it plays reads 30 ppm off per cm/s,
/// and from the sweeps' spacing, which it barely moves. And the room's level while the test sound plays.
@MainActor
@Suite(.timeLimit(.minutes(4))) struct ExternalClockTests {
    /// The speaker test's file as heard by a phone drifting towards the speaker at `speed` m/s while the tone plays,
    /// still afterwards: the tone arrives shifted by `speed / 343`, the sweeps on the player's true clock.
    static func driftingDuringTone(_ speed: Double) -> [Float] {
        heardFile(TestSoundFile(kind: .speakerTest(.left))) { mono, layout in
            let shift = 1 + speed / 343
            for index in 0..<layout.tone.count {
                let t = Double(index) / layout.sampleRate
                let edge = min(1, min(t, Double(layout.tone.count - index) / layout.sampleRate) / 0.01)
                mono[layout.tone.offset + index] = Float(0.5 * edge * Double(SweepFinder.clockToneAmplitude)
                    * sin(2 * Double.pi * SweepFinder.clockToneFrequency * shift * t))
            }
        }
    }

    static func run(_ signal: [Float]) async -> (ExternalMeasurementSession.State, [ExternalMeasurementProgress]) {
        let session = ExternalMeasurementSession(
            io: PreparedAudioIO(signal), channel: .left, permission: SimulatedMicrophonePermission(.granted),
            stillness: ConstantStillnessMonitor(), configuration: Fixture.configuration
        )
        var progress: [ExternalMeasurementProgress] = []
        let watcher = Task { for await update in session.progressUpdates() { progress.append(update) } }
        let final = await session.run()
        await watcher.value
        return (final, progress)
    }

    /// The review's figure: 2 cm/s during the tone reads 58 ppm off, which bends the response by about 1 dB at 20 Hz.
    @Test func `a phone drifting during the tone is timed from the sweeps, and the progress says so`() async throws {
        let (final, progress) = await Self.run(Self.driftingDuringTone(0.02))
        let result = try #require(final.result, "ended \(final)")
        for run in result.runs {
            print("drifting 2 cm/s: clock \(((run.clockRatio ?? 0) - 1) * 1e6) ppm from \(String(describing: run.clockSource)), disagreement \(run.clockDisagreementPPM ?? -1) ppm")
            #expect(abs((run.clockRatio ?? 0) - 1) < 3e-6)
            #expect(run.clockSource == .sweepSpacing)
            #expect(abs((run.clockDisagreementPPM ?? 0) - 58) < 5)
        }
        let said = progress.compactMap(\.clockDisagreementPPM)
        #expect(!said.isEmpty)
        #expect(abs((said.last ?? 0) - 58) < 5)
    }

    @Test func `a still phone is timed from the tone, the two agreeing`() async throws {
        let (final, progress) = await Self.run(Self.driftingDuringTone(0))
        let result = try #require(final.result, "ended \(final)")
        for run in result.runs {
            #expect(run.clockSource == .tone)
            #expect((run.clockDisagreementPPM ?? .infinity) < 2)
        }
        #expect(progress.allSatisfy { $0.clockDisagreementPPM == nil })
    }

    /// The seat's two sweeps take different paths, so only the tone gives its clock: a spot whose tone was heard while
    /// the stillness monitor said the phone moved is played again.
    @Test func `at the seat a tone heard while the phone moved is refused`() async throws {
        let io = SeatFixture.io()
        let stillness = NudgedStillnessMonitor(base: SeatFixture.stillness(for: io))
        let session = ExternalSeatMeasurementSession(
            io: io, channels: [.left, .right], permission: SimulatedMicrophonePermission(.granted),
            stillness: stillness, configuration: SeatFixture.configuration
        )
        let file = TestSoundFile(kind: .seat([.left, .right]))
        var plays: [SeatSpot: Int] = [:]
        var states: [ExternalSeatMeasurementSession.State] = []
        session.onStateChange = { state in
            states.append(state)
            switch state {
            case .waitingForSound(let spot) where plays[spot] == nil:
                plays[spot] = 1
                io.playExternally(SimulatedExternalPlay(file: file, delay: 0.8))
            case .hearing(.seat, nil) where plays[.seat] == 1:
                // The tone is heard: the phone is moving.
                stillness.isMoving = true
            case .hearing(.seat, .some):
                stillness.isMoving = false
            case .needsAnotherPlay(let spot, _) where plays[spot] == 1:
                plays[spot] = 2
                stillness.isMoving = false
                io.playExternally(SimulatedExternalPlay(file: file, delay: 1))
            default:
                break
            }
        }
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")
        #expect(result.isComplete)
        let reasons = states.compactMap { if case .needsAnotherPlay(let spot, let reason) = $0 { (spot, reason) } else { nil } }
        #expect(reasons.first?.0 == .seat)
        #expect(reasons.first?.1 == .phoneMovedDuringTone)
        #expect(result.spots.allSatisfy { spot in spot.recordings.values.allSatisfy { $0.clockSource == .tone } })
    }

    /// While the tone or a sweep is heard, the room's level is the room's, with the test sound taken out, as in the
    /// normal test; it read the whole block (the sweep itself, 60 dB over the room).
    @Test func `the room's level while the test sound plays leaves the test sound out`() async throws {
        let io = Fixture.io()
        let session = ExternalFixture.session(io: io)
        _ = ExternalStateLog(session) { state in
            if state == .waitingForSound, io.externalPlayCount == 0 { io.playExternally(ExternalFixture.play()) }
        }
        var heard: [ExternalMeasurementProgress] = []
        let watcher = Task {
            for await update in session.progressUpdates() where update.hearingRun != nil || update.isHearingTone { heard.append(update) }
        }
        _ = await session.run()
        await watcher.value
        #expect(heard.count > 50)
        let loud = heard.filter { $0.roomLevel.dBFS > -60 }
        print("room level while hearing: \(heard.count) blocks, \(loud.count) over −60 dBFS; input up to \(heard.map(\.inputLevel.dBFS).max() ?? 0) dBFS")
        #expect(Double(loud.count) <= 0.05 * Double(heard.count))
        #expect(heard.filter(\.isRoomQuiet).count >= heard.count * 9 / 10)
    }
}
