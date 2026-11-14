import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

extension ExternalSeatMeasurementSession.State {
    var result: SeatMeasurementResult? {
        if case .finished(let result) = self { return result }
        return nil
    }

    var failure: ExternalMeasurementFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }
}

@MainActor
@Suite(.timeLimit(.minutes(8))) struct ExternalSeatMeasurementSessionTests {
    static func session(io: SimulatedAudioIO, channels: [SpeakerChannel] = [.left, .right]) -> ExternalSeatMeasurementSession {
        ExternalSeatMeasurementSession(
            io: io, channels: channels, permission: SimulatedMicrophonePermission(.granted),
            stillness: SeatFixture.stillness(for: io), configuration: SeatFixture.configuration
        )
    }

    /// Plays the seat file once at each spot when asked, again when asked to, with `bursts` on the first play at
    /// `noisySpot`, at a clock of `ratio`.
    static func player(
        _ io: SimulatedAudioIO,
        channels: [SpeakerChannel] = [.left, .right],
        ratio: Double = 1,
        noisySpot: SeatSpot? = nil,
        bursts: [NoiseBurst] = []
    ) -> (ExternalSeatMeasurementSession.State) -> Void {
        var playedAt: [SeatSpot: Int] = [:]
        var answered = 0
        return { state in
            let file = TestSoundFile(kind: .seat(channels))
            switch state {
            case .waitingForSound(let spot) where playedAt[spot] == nil:
                playedAt[spot] = 1
                io.playExternally(SimulatedExternalPlay(file: file, delay: 0.8, clockRatio: ratio, bursts: spot == noisySpot ? bursts : []))
            case .needsAnotherPlay(let spot, _) where (playedAt[spot] ?? 0) == 1 && answered == 0:
                answered += 1
                playedAt[spot] = 2
                io.playExternally(SimulatedExternalPlay(file: file, delay: 1, clockRatio: ratio))
            default:
                break
            }
        }
    }

    @Test func `three spots with another play at one, measured as a normal seat measurement is`() async throws {
        let io = SeatFixture.io()
        let session = Self.session(io: io)
        let kind = TestSoundFile.Kind.seat([.left, .right])
        // Noise over the right speaker's sweep on the first play at the left spot.
        let burst = NoiseBurst(start: .at(ExternalFixture.sweepTime(kind, 1) + 1.5), duration: 1, rms: 0.03)
        var states: [ExternalSeatMeasurementSession.State] = []
        let play = Self.player(io, ratio: 0.99975, noisySpot: .left, bursts: [burst])
        session.onStateChange = { state in
            states.append(state)
            play(state)
        }
        let final = await session.run()

        let result = try #require(final.result, "ended \(final)")
        #expect(result.source == .anotherDevice)
        #expect(result.isComplete)
        #expect(result.spots.map(\.spot) == [.seat, .left, .right])
        #expect(io.externalPlayCount == 4)
        #expect(io.scheduledBufferCount == 0)
        let asked = states.compactMap { state -> SeatSpot? in
            if case .needsAnotherPlay(let spot, _) = state { return spot }
            return nil
        }
        #expect(Set(asked) == [.left])
        #expect(states.contains(.hearing(spot: .seat, channel: .right)))
        for (index, spot) in result.spots.enumerated() {
            #expect(spot.movementDetected)
            for channel in [SpeakerChannel.left, .right] {
                let recording = try #require(spot.recording(for: channel), "\(spot.spot) \(channel)")
                #expect(abs((recording.clockRatio ?? 0) - 0.99975) < 2e-6)
                let worst = SeatFixture.worstDifference(recording, spot: index, channel: channel)
                print("external seat \(spot.spot) \(channel): worst error \(worst) dB")
                #expect(worst < 1)
                // The tail holds the bass decay estimate, as a normal seat recording's does.
                let tail = Double(recording.samples.count - recording.leadIn) / recording.sampleRate - Fixture.sweep.duration
                #expect(tail >= MeasurementConfiguration.seat.minimumTail)
                let response = Deconvolution.impulseResponse(recording: recording.samples, sweep: Fixture.sweep)
                let decay = try #require(Decay.bass(impulseResponse: response, sweep: Fixture.sweep), "no decay at \(spot.spot) \(channel)")
                #expect(abs(decay.seconds / SeatFixture.room.reverberationTime - 1) < 0.10)
            }
        }
        #expect(session.capturedSpots == result.spots)
    }

    @Test func `one speaker is one sweep per spot`() async throws {
        let io = SeatFixture.io()
        let session = Self.session(io: io, channels: [.both])
        session.onStateChange = Self.player(io, channels: [.both])
        let final = await session.run()
        let result = try #require(final.result, "ended \(final)")
        #expect(result.spots.count == 3)
        #expect(result.spots.allSatisfy { $0.recordings.keys.sorted { "\($0)" < "\($1)" } == [.both] })
        #expect(io.externalPlayCount == 3)
    }

    @Test func `the speaker test's file at a spot is refused`() async throws {
        let io = SeatFixture.io()
        let session = Self.session(io: io)
        var states: [ExternalSeatMeasurementSession.State] = []
        session.onStateChange = { [unowned session] state in
            states.append(state)
            if state == .waitingForSound(spot: .seat), io.externalPlayCount == 0 {
                io.playExternally(SimulatedExternalPlay(file: TestSoundFile(kind: .speakerTest(.left))))
            }
            if case .needsAnotherPlay(_, .wrongFile) = state { session.cancel() }
        }
        let final = await session.run()
        #expect(final == .failed(.measurement(.cancelled)))
        #expect(states.contains(.needsAnotherPlay(spot: .seat, reason: .wrongFile(heard: .speakerTest(.left)))))
    }

    @Test func `cancel while waiting for the sound ends the session`() async {
        let io = SeatFixture.io()
        let session = Self.session(io: io)
        session.onStateChange = { [unowned session] state in
            if case .waitingForSound = state { session.cancel() }
        }
        #expect(await session.run() == .failed(.measurement(.cancelled)))
        #expect(!io.isRunning)
    }
}
