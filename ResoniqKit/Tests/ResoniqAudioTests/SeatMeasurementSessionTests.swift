import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// A seat measurement in `SimulatedRoom.livingRoom`, with the app's seat configuration (4 s sweeps, 2 s tail).
@MainActor
enum SeatFixture {
    static let room = SimulatedRoom.livingRoom
    static let configuration = MeasurementConfiguration.seat

    static func io(
        bursts: [NoiseBurst] = [],
        speaker: SimulatedSpeaker = .bookshelf,
        room: SimulatedRoom? = SeatFixture.room
    ) -> SimulatedAudioIO {
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

    static func stillness(for io: SimulatedAudioIO, detectsMovement: Bool = true) -> SimulatedStillnessMonitor {
        let monitor = SimulatedStillnessMonitor(pacing: .immediate, detectsMovement: detectsMovement)
        monitor.onMove = { io.moveToSpot($0.index) }
        return monitor
    }

    static func session(
        io: SimulatedAudioIO,
        channels: [SpeakerChannel] = [.left, .right],
        permission: MicrophoneAccess = .granted,
        stillness: (any StillnessMonitor)? = nil
    ) -> SeatMeasurementSession {
        SeatMeasurementSession(
            io: io,
            channels: channels,
            permission: SimulatedMicrophonePermission(permission),
            stillness: stillness ?? Self.stillness(for: io),
            configuration: configuration
        )
    }

    /// The worst difference in dB, 30 Hz to 16 kHz, between a recording's room response (`roomPostWindow`) and the
    /// simulation's speaker and room at `spot`, both sixth-octave smoothed and level matched.
    static func worstDifference(_ recording: RunRecording, spot: Int, channel: SpeakerChannel) -> Float {
        let measured = Deconvolution.impulseResponse(recording: recording.samples, sweep: Fixture.sweep)
            .frequencyResponse(postWindow: ImpulseResponse.roomPostWindow)
        let expected = MagnitudeResponse(
            frequencies: measured.frequencies,
            decibels: measured.frequencies.map { frequency in
                let f = Double(frequency)
                let gain = SimulatedSpeaker.bookshelf.linearGain(at: f, sampleRate: Fixture.sampleRate)
                    * room.magnitude(at: f, spot: spot, channel: channel, sampleRate: Fixture.sampleRate)
                return Float(20 * log10(gain))
            }
        )
        let smoothedMeasured = Smoothing.fractionalOctave(measured, fraction: 6)
        let smoothedExpected = Smoothing.fractionalOctave(expected, fraction: 6)
        let matched = ResponseComparison.levelMatched(smoothedMeasured, to: smoothedExpected)
        let difference = ResponseComparison.difference(matched, smoothedExpected)
        return zip(difference.frequencies, difference.decibels)
            .filter { $0.0 >= 30 && $0.0 <= 16000 }
            .map { abs($0.1) }
            .max() ?? .infinity
    }
}

/// Every state a seat session passes through.
@MainActor
final class SeatStateLog {
    private(set) var states: [SeatMeasurementSession.State] = []

    init(_ session: SeatMeasurementSession, onState: ((SeatMeasurementSession.State, SeatMeasurementSession) -> Void)? = nil) {
        session.onStateChange = { [self, unowned session] state in
            states.append(state)
            onState?(state, session)
        }
    }

    var captured: [SeatSpot] {
        states.compactMap {
            if case .spotCaptured(let spot) = $0 { return spot }
            return nil
        }
    }

    var waited: [SeatSpot] {
        states.compactMap {
            if case .waitingForStillness(let spot) = $0 { return spot }
            return nil
        }
    }

    var played: [String] {
        states.compactMap {
            if case .playing(let spot, let channel, _) = $0 { return "\(spot) \(channel)" }
            return nil
        }
    }

    var pauses: Int {
        states.filter { if case .paused = $0 { true } else { false } }.count
    }
}

extension SeatMeasurementSession.State {
    var result: SeatMeasurementResult? {
        if case .finished(let result) = self { return result }
        return nil
    }

    var failure: MeasurementFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SeatMeasurementSessionTests {
    @Test func `a clean pair measurement captures three spots of left and right, each the room at that spot`() async throws {
        let io = SeatFixture.io()
        let session = SeatFixture.session(io: io)
        let log = SeatStateLog(session)
        let final = await session.run()

        let result = try #require(final.result, "ended \(final)")
        #expect(result.isComplete)
        #expect(result.channels == [.left, .right])
        #expect(result.spots.map(\.spot) == [.seat, .left, .right])
        #expect(log.played == ["seat left", "seat right", "left left", "left right", "right left", "right right"])
        for (index, spot) in result.spots.enumerated() {
            #expect(Set(spot.recordings.keys) == [.left, .right])
            #expect(!spot.phoneMoved && spot.movementDetected)
            for channel in [SpeakerChannel.left, .right] {
                let recording = try #require(spot.recording(for: channel))
                #expect(recording.run == (channel == .left ? 1 : 2))
                let own = SeatFixture.worstDifference(recording, spot: index, channel: channel)
                let others = (0..<3).filter { $0 != index }.map { SeatFixture.worstDifference(recording, spot: $0, channel: channel) }
                print("spot \(spot.spot) \(channel): worst error \(own) dB against its own spot, \(others) against the others")
                #expect(own < 1)
                #expect(others.allSatisfy { $0 > own + 2 })
            }
        }
        #expect(!io.isRunning && !io.isPlaying && !session.isRunning)
    }

    @Test func `a single speaker yields three spots of one recording`() async throws {
        let io = SeatFixture.io()
        let final = await SeatFixture.session(io: io, channels: [.both]).run()
        let result = try #require(final.result, "ended \(final)")
        #expect(result.spots.count == 3)
        #expect(result.spots.allSatisfy { Array($0.recordings.keys) == [.both] })
        #expect(io.scheduledBufferCount == 3)
    }

    @Test func `the session waits for movement then stillness between spots and captures each in order`() async throws {
        let io = SeatFixture.io()
        let stillness = SeatFixture.stillness(for: io)
        let session = SeatFixture.session(io: io, stillness: stillness)
        var spotWhenPlaying: [Int] = []
        let log = SeatStateLog(session) { state, _ in
            if case .playing = state { spotWhenPlaying.append(io.currentSpot) }
        }
        let updates = session.progressUpdates()
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")

        #expect(log.waited == [.seat, .left, .right])
        #expect(log.captured == [.seat, .left, .right])
        #expect(stillness.moves == [.left, .right])
        #expect(spotWhenPlaying == [0, 0, 1, 1, 2, 2])
        #expect(result.spots.allSatisfy { $0.movementDetected })
        // Each spot is captured only after the phone was seen unsteady (it moved) and then steady for the hold.
        var seen: [SeatMeasurementProgress] = []
        for await progress in updates { seen.append(progress) }
        for spot in [SeatSpot.left, .right] {
            let waiting = seen.filter { $0.spot == spot && $0.channel == nil && $0.stillness != nil }
            let firstSteady = try #require(waiting.firstIndex { $0.isPhoneSteady })
            #expect(firstSteady > 0 && !waiting[0].isPhoneSteady)
            #expect(waiting.last?.stillness == 1)
        }
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0.spotsCaptured <= $1.spotsCaptured })
        #expect(seen.last?.spotsCaptured == 3)
    }

    @Test func `noise during a sweep pauses it and resumes with a splice, as in Diagnose`() async throws {
        // The third buffer is the left speaker at the second spot; noise 2.0 s into it for 0.6 s.
        let burst = NoiseBurst(start: .afterScheduling(buffer: 2, offset: 2.0), duration: 0.6, rms: 0.02)
        let io = SeatFixture.io(bursts: [burst])
        let session = SeatFixture.session(io: io)
        let log = SeatStateLog(session)
        let final = await session.run()

        let result = try #require(final.result, "ended \(final)")
        #expect(log.pauses == 1)
        #expect(log.states.contains { if case .paused(.left, .left, _) = $0 { true } else { false } })
        let spliced = try #require(result.spots[1].recording(for: .left))
        #expect(spliced.spliceCount == 1)
        let worst = SeatFixture.worstDifference(spliced, spot: 1, channel: .left)
        print("spliced seat recording: worst error \(worst) dB")
        #expect(worst < 1)
    }

    @Test func `the tail is long enough for the bass decay of the room`() async throws {
        let io = SeatFixture.io()
        let final = await SeatFixture.session(io: io).run()
        let result = try #require(final.result, "ended \(final)")
        for spot in result.spots {
            for channel in [SpeakerChannel.left, .right] {
                let recording = try #require(spot.recording(for: channel))
                let tail = Double(recording.samples.count - recording.leadIn) / recording.sampleRate - Fixture.sweep.duration
                let response = Deconvolution.impulseResponse(recording: recording.samples, sweep: Fixture.sweep)
                let estimate = try #require(Decay.bass(impulseResponse: response, sweep: Fixture.sweep), "no decay at \(spot.spot) \(channel)")
                print("bass decay at \(spot.spot) \(channel): \(estimate.seconds) s (room \(SeatFixture.room.reverberationTime) s), tail \(tail) s, \(estimate.evaluationRange), \(estimate.dynamicRangeDecibels) dB")
                #expect(tail >= MeasurementConfiguration.seat.minimumTail)
                // `Decay`'s stated accuracy: 10 %.
                #expect(abs(estimate.seconds / SeatFixture.room.reverberationTime - 1) < 0.10)
            }
        }
    }

    @Test func `a spot that clips twice fails the session`() async throws {
        let io = SeatFixture.io(speaker: SimulatedSpeaker(gain: 8))
        let final = await SeatFixture.session(io: io).run()
        let failure = try #require(final.failure, "ended \(final)")
        guard case .recordingUnusable(.unusable(.clipped)) = failure else {
            Issue.record("failed with \(failure)")
            return
        }
        #expect(io.scheduledBufferCount == 2)
        #expect(!io.isRunning)
    }

    @Test func `skipping to the result after one spot finishes with that spot`() async throws {
        let io = SeatFixture.io()
        let session = SeatFixture.session(io: io)
        _ = SeatStateLog(session) { state, session in
            if state == .spotCaptured(spot: .seat) { session.skipToResult() }
        }
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")
        #expect(result.spots.map(\.spot) == [.seat])
        #expect(!result.isComplete)
        #expect(io.scheduledBufferCount == 2)
        #expect(!io.isRunning && !session.isRunning)
    }

    @Test func `skipping in the middle of a spot keeps only the spots already captured`() async throws {
        let io = SeatFixture.io()
        let session = SeatFixture.session(io: io)
        _ = SeatStateLog(session) { state, session in
            if case .playing(.left, .right, _) = state { session.skipToResult() }
        }
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")
        #expect(result.spots.map(\.spot) == [.seat])
        #expect(!io.isRunning && !io.isPlaying)
    }

    enum Moment: String, CaseIterable, Sendable {
        case idle, measuringNoiseFloor, waitingForStillness, playing, paused, checking, spotCaptured
    }

    @Test(arguments: Moment.allCases)
    func `cancelling stops playback and leaves nothing running`(at moment: Moment) async {
        let burst = NoiseBurst(start: .afterScheduling(buffer: 0, offset: 2.0), duration: nil, rms: 0.02)
        let io = SeatFixture.io(bursts: moment == .paused ? [burst] : [])
        let session = SeatFixture.session(io: io)
        var cancelledIn: SeatMeasurementSession.State?
        _ = SeatStateLog(session) { state, session in
            guard cancelledIn == nil else { return }
            let matches = switch (moment, state) {
            case (.measuringNoiseFloor, .measuringNoiseFloor), (.waitingForStillness, .waitingForStillness),
                 (.playing, .playing), (.paused, .paused), (.checking, .checking), (.spotCaptured, .spotCaptured): true
            default: false
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

    @Test func `denied permission fails before any sound`() async {
        let io = SeatFixture.io()
        let final = await SeatFixture.session(io: io, permission: .denied).run()
        #expect(final == .failed(.permissionDenied))
        #expect(io.startCount == 0 && io.scheduledBufferCount == 0)
    }

    @Test func `movement that is never detected is waited for, then the spot is captured and marked`() async throws {
        let io = SeatFixture.io()
        let stillness = SeatFixture.stillness(for: io, detectsMovement: false)
        let session = SeatFixture.session(io: io, stillness: stillness)
        let updates = session.progressUpdates()
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")
        #expect(result.spots.map(\.movementDetected) == [true, false, false])
        #expect(result.isComplete)

        // Waiting at the second spot lasted the movement timeout, counted on the capture timeline.
        var waitingBlocks = 0
        for await progress in updates where progress.spot == .left && progress.channel == nil && progress.stillness != nil {
            waitingBlocks += 1
        }
        let blockSeconds = MeasurementConfiguration.seat.blockDuration
        #expect(Double(waitingBlocks) * blockSeconds >= SeatMeasurementSession.movementTimeout - blockSeconds)
    }

    @Test func `an interruption ends the measurement with that reason`() async {
        let io = SeatFixture.io()
        let session = SeatFixture.session(io: io)
        _ = SeatStateLog(session) { state, _ in
            if state == .waitingForStillness(spot: .left) { io.fail(with: .interrupted) }
        }
        let final = await session.run()
        #expect(final == .failed(.interrupted))
        #expect(!io.isRunning)
    }
}
