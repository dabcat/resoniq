import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// What the sessions hand the app beyond states and progress: spots as they are captured, the wait between spots in
/// phases, the audio of a pause for naming the noise, and the words for each moment.
@MainActor
@Suite(.timeLimit(.minutes(3))) struct SessionAdditionsTests {
    // MARK: Spots as they come in

    @Test func `each spot's recordings are available as soon as it is captured`() async throws {
        let run = await CleanSeatRun.shared.value
        #expect(run.capturedAtEachSpot == [[.seat], [.seat, .left], [.seat, .left, .right]])
        let result = try #require(run.final.result)
        #expect(run.session.captured == result)
        #expect(run.session.capturedSpots == result.spots)
    }

    @Test func `nothing is captured before the floor, and an empty list once it is known`() async {
        let io = SeatFixture.io()
        let session = SeatFixture.session(io: io)
        #expect(session.captured == nil && session.capturedSpots.isEmpty)
        var atFirstWait: SeatMeasurementResult??
        _ = SeatStateLog(session) { state, session in
            if state == .waitingForStillness(spot: .seat) {
                atFirstWait = session.captured
                session.cancel()
            }
        }
        _ = await session.run()
        let captured = try? #require(atFirstWait ?? nil)
        #expect(captured?.spots.isEmpty == true)
        #expect(captured?.channels == [.left, .right])
    }

    // MARK: The wait between spots

    @Test func `the wait has phases that never go back to waiting for the move once the phone moved`() async throws {
        let run = await CleanSeatRun.shared.value
        let waiting = run.progress.filter { $0.channel == nil && $0.stillness != nil }
        #expect(waiting.allSatisfy { $0.wait != nil })
        #expect(run.progress.filter { $0.stillness == nil }.allSatisfy { $0.wait == nil })
        // The first spot has no move to wait for.
        let seat = waiting.filter { $0.spot == .seat }.compactMap(\.wait)
        #expect(!seat.isEmpty && !seat.contains(.waitingForMove))
        for spot in [SeatSpot.left, .right] {
            let phases = waiting.filter { $0.spot == spot }.compactMap(\.wait)
            let firstMoved = try #require(phases.firstIndex { $0 != .waitingForMove }, "\(spot): \(phases)")
            #expect(phases[..<firstMoved].allSatisfy { $0 == .waitingForMove })
            #expect(!phases[firstMoved...].contains(.waitingForMove), "\(spot): \(phases)")
            #expect(phases.last == .still)
            // The phase follows the phone: steady is still, moving is settling.
            for progress in waiting where progress.spot == spot && progress.wait != .waitingForMove {
                #expect((progress.wait == .still) == progress.isPhoneSteady)
            }
        }
    }

    @Test func `one instruction per phase of the wait`() {
        let pair: [SpeakerChannel] = [.left, .right]
        let left = SeatMeasurementSession.State.waitingForStillness(spot: .left)
        #expect(SeatSessionText.instruction(for: left, wait: .waitingForMove, channels: pair) == "Now move the phone 30 cm to your left.")
        #expect(SeatSessionText.instruction(for: left, wait: nil, channels: pair) == "Now move the phone 30 cm to your left.")
        #expect(SeatSessionText.instruction(for: left, wait: .settling, channels: pair) == "Now hold the phone still.")
        #expect(SeatSessionText.instruction(for: left, wait: .still, channels: pair) == "Now hold the phone still.")
        let seat = SeatMeasurementSession.State.waitingForStillness(spot: .seat)
        for wait in [SeatWaitPhase.settling, .still] {
            #expect(SeatSessionText.instruction(for: seat, wait: wait, channels: pair) == "Hold the phone still at your head.")
        }
        #expect(SeatSessionText.moveInstruction(to: .right) == "Now move the phone 30 cm to your right.")
        #expect(SeatSpot.spacing == 0.30)
    }

    @Test func `the sentence for every other moment`() {
        let pair: [SpeakerChannel] = [.left, .right]
        func says(_ state: SeatMeasurementSession.State, _ channels: [SpeakerChannel] = pair) -> String {
            SeatSessionText.instruction(for: state, wait: nil, channels: channels)
        }
        #expect(says(.measuringNoiseFloor) == "Stay quiet while I listen to the room.")
        #expect(says(.playing(spot: .seat, channel: .right, note: nil)) == "Hold still. The right speaker is playing.")
        #expect(says(.playing(spot: .seat, channel: .both, note: nil), [.both]) == "Hold still. The tones are playing.")
        #expect(says(.checking(spot: .left, channel: .left)) == "Hold still. Checking that one.")
        #expect(says(.paused(spot: .left, channel: .left, resumeFrequency: 1000)) == "It got noisy, so I stopped the left speaker.")
        #expect(says(.spotCaptured(spot: .left)) == "Got the left spot.")
        #expect(says(.failed(.cancelled)) == "")
        #expect(SeatSessionText.pausedSentence(resumeFrequency: "1 kHz") == "A measurement taken now would be wrong. I'll pick up at 1 kHz once the room is quiet again.")
        #expect(SeatSessionText.noticeText(.restarted(.noiseTooEarly)) == "The noise came before I'd heard enough to pick up where I stopped, so I'm starting this one over.")
        #expect(SeatSessionText.failureBody(.recordingUnusable(.didNotArrive)).hasPrefix("I tried that spot twice. I never heard"))
        #expect(SeatSessionText.failureBody(.speakersNotConnected(AudioOutputRoute(kind: .builtInSpeaker, name: "")))
            .contains("coming out of the iPhone's own speaker."))
        #expect(SeatSessionText.inconclusiveBasis(.tooNoisy) == "the room stayed too noisy")
        #expect(SeatSessionText.inconclusiveBasis(.interrupted) == nil)
    }

    @Test func `a run the phone moved in says so, with the run numbers, and nothing when none moved`() {
        #expect(ReadingText.phoneMovedNote(runs: []) == nil)
        #expect(ReadingText.phoneMovedNote(runs: [2])
            == "The phone moved while run 2 played. I kept that run, so read its details with a little care.")
        #expect(ReadingText.phoneMovedNote(runs: [3, 1])
            == "The phone moved while runs 1 and 3 played. I kept them, so read the details with a little care.")
        #expect(ReadingText.phoneMovedNote(runs: [1, 2, 3, 2])
            == "The phone moved while runs 1, 2 and 3 played. I kept them, so read the details with a little care.")
        #expect(ReadingText.phoneMovedBasis == "the phone's motion sensor")
    }

    @Test func `the readings`() {
        #expect(ReadingText.frequencyReading(90.4) == ("90", "Hz"))
        #expect(ReadingText.frequencyReading(1020) == ("1.02", "kHz"))
        #expect(ReadingText.frequencyReading(14_480) == ("14.5", "kHz"))
        let quiet = SoundLevel(dBFS: -76)
        #expect(ReadingText.room(quiet, isQuiet: true) == "Quiet · 34 dB")
        #expect(ReadingText.room(SoundLevel(dBFS: -58), isQuiet: false) == "Noisy · 52 dB")
        #expect(ReadingText.spokenRoom(quiet, isQuiet: true) == "Room: quiet, about 34 decibels.")
        #expect(ReadingText.decibels(quiet) == "34 dB")
        #expect(abs(ReadingText.barFraction(SoundLevel(dBFS: -58)) - 52.0 / 70) < 1e-6)
        #expect(ReadingText.barFraction(SoundLevel(dBFS: 0)) == 1)
        #expect(ReadingText.barFraction(SoundLevel(dBFS: -200)) == 0)
        #expect(ReadingText.phone(isSteady: false) == "Moving")
    }

    // MARK: The audio of a pause

    @Test func `a paused speaker test offers the latest audio of the pause, bounded, and keeps it when it ends too noisy`() async throws {
        // Noise that never stops, from 2 s into the first run; a short longest wait so the test ends quickly.
        let burst = NoiseBurst(start: .afterScheduling(buffer: 0, offset: 2.0), duration: nil, rms: 0.02)
        let io = Fixture.io(bursts: [burst])
        var configuration = Fixture.configuration
        configuration.maximumPauseWait = 6
        let session = MeasurementSession(
            io: io, channel: .left, permission: SimulatedMicrophonePermission(.granted),
            stillness: ConstantStillnessMonitor(), configuration: configuration
        )
        #expect(session.pausedAudio() == nil)
        var heard: [CapturedAudio] = []
        _ = StateLog(session)
        let updates = session.progressUpdates()
        session.start()
        for await _ in updates {
            if let audio = session.pausedAudio() { heard.append(audio) }
            if !session.state.isPaused { #expect(session.pausedAudio() == nil) }
        }
        let final = await session.run()
        #expect(final == .failed(.tooNoisy))
        #expect(heard.count > 10)
        let longest = try #require(heard.last)
        #expect(longest.sampleRate == Fixture.sampleRate && !longest.sweepPlaying)
        #expect(longest.duration <= CapturedAudio.pausedDuration + 1e-9)
        #expect(longest.duration >= CapturedAudio.pausedDuration - 0.1)
        // It is the noise: about 0.02 RMS.
        #expect(abs(LevelMeter.measure(longest.samples).rmsDecibels - Float(20 * log10(0.02))) < 1)
        // It grew block by block until it was full.
        #expect(zip(heard, heard.dropFirst()).allSatisfy { $0.samples.count <= $1.samples.count })
        let kept = try #require(session.noisyRecording)
        #expect(kept == longest)
    }

    @Test func `a paused seat measurement offers its audio too`() async throws {
        let burst = NoiseBurst(start: .afterScheduling(buffer: 0, offset: 2.0), duration: nil, rms: 0.02)
        let io = SeatFixture.io(bursts: [burst])
        let session = SeatFixture.session(io: io)
        var audio: CapturedAudio?
        var pausedBlocks = 0
        let updates = session.progressUpdates()
        session.start()
        for await _ in updates where session.pausedAudio() != nil {
            audio = session.pausedAudio()
            pausedBlocks += 1
            if pausedBlocks == 15 { break }
        }
        session.cancel()
        _ = await session.run()
        let heard = try #require(audio)
        #expect(!heard.sweepPlaying && heard.duration > 1 && heard.duration <= CapturedAudio.pausedDuration)
        #expect(session.pausedAudio() == nil)
    }

    @Test func `the ring keeps the latest samples, oldest first`() {
        var ring = AudioRing(capacity: 5)
        ring.append([1, 2, 3])
        #expect(ring.contents == [1, 2, 3])
        ring.append([4, 5, 6, 7])
        #expect(ring.contents == [3, 4, 5, 6, 7])
        ring.append([8, 9, 10, 11, 12, 13])
        #expect(ring.contents == [9, 10, 11, 12, 13])
        ring.reset()
        #expect(ring.isEmpty && ring.contents.isEmpty)
    }
}
