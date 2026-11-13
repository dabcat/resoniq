import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// The cases the final review found in the sessions: the audio offered for naming the noise must not hold the app's
/// own sweep, no wait may last forever, and an output route that cannot be told is measured.
@MainActor
@Suite(.timeLimit(.minutes(3))) struct ReviewFixTests {
    // MARK: The audio of a pause holds no sweep

    /// The level of the room's own noise in the simulation, dBFS (`Fixture.io`'s 1e-4 RMS).
    static let floorDecibels = Float(20 * log10(1e-4))

    /// Every audio a speaker test offers while paused, for a noise of `duration` seconds that begins 1.5 s into the
    /// sweep as heard at the microphone, over a route of `delay` seconds.
    func offeredWhilePaused(delay: Double, duration: Double, rms: Double) async -> (offered: [CapturedAudio], paused: Bool) {
        let burst = NoiseBurst(start: .afterScheduling(buffer: 0, offset: delay + 1.5), duration: duration, rms: rms)
        let io = Fixture.io(routeDelay: delay, bursts: [burst])
        let session = Fixture.session(io: io)
        var offered: [CapturedAudio] = []
        var paused = false
        let updates = session.progressUpdates()
        session.start()
        for await _ in updates {
            if session.state.isPaused { paused = true }
            if let audio = session.pausedAudio() { offered.append(audio) }
            if paused && !session.state.isPaused { break }
        }
        session.cancel()
        _ = await session.run()
        return (offered, paused)
    }

    @Test(arguments: [0.25, 1.0, 2.0])
    func `a clean pause offers no audio of the sweep still arriving`(delay: Double) async {
        // A short knock: the pause that follows is the sweep's tail arriving and dying away, then quiet.
        let (offered, paused) = await offeredWhilePaused(delay: delay, duration: 0.2, rms: 0.05)
        #expect(paused)
        let loudest = offered.map { LevelMeter.measure($0.samples).rmsDecibels }.max()
        print("route delay \(delay) s: \(offered.count) offers, loudest \(String(describing: loudest)) dBFS")
        // Nothing, or the room's own quiet: never the sweep, which would read some 60 dB louder.
        #expect(offered.allSatisfy { LevelMeter.measure($0.samples).rmsDecibels < Self.floorDecibels + 6 })
        #expect(offered.allSatisfy { !$0.sweepPlaying && $0.duration >= CapturedAudio.minimumDuration })
    }

    @Test(arguments: [0.25, 1.0, 2.0])
    func `noise that goes on through the pause is still offered, and only it`(delay: Double) async throws {
        // Someone talking for six seconds: the pause holds them, after the sweep's tail has gone.
        let (offered, paused) = await offeredWhilePaused(delay: delay, duration: 6, rms: 0.02)
        #expect(paused)
        let latest = try #require(offered.last)
        let level = LevelMeter.measure(latest.samples).rmsDecibels
        print("route delay \(delay) s: noise offered over \(latest.duration) s at \(level) dBFS")
        #expect(latest.duration >= CapturedAudio.minimumDuration)
        #expect(abs(level - Float(20 * log10(0.02))) < 1)
        // Its first second is the noise too, not the sweep's tail.
        let first = Array(latest.samples.prefix(Int(Fixture.sampleRate)))
        #expect(abs(LevelMeter.measure(first).rmsDecibels - Float(20 * log10(0.02))) < 1)
    }

    @Test func `the keeper skips the sweep's arrival and offers nothing too short to name`() {
        var keeper = PausedAudioKeeper(sampleRate: 1000)
        keeper.pauseBegan(skipping: 500)
        keeper.keep([Float](repeating: 1, count: 400))
        keeper.keep([Float](repeating: 1, count: 200))
        #expect(keeper.audio == nil)
        keeper.keep([Float](repeating: 2, count: 1400))
        let audio = keeper.audio
        #expect(audio?.samples.count == 1500)
        #expect(audio?.samples.first == 1 && audio?.samples.last == 2)
        // How much to skip: one block, the route's delay (the longest one when it is not known), and the decay.
        let configuration = MeasurementConfiguration.standard
        #expect(PausedAudioKeeper.sweepArrival(delay: 250, blockLength: 100, configuration: configuration, sampleRate: 1000)
            == 100 + 250 + Int(CapturedAudio.sweepDecayAllowance * 1000))
        #expect(PausedAudioKeeper.sweepArrival(delay: nil, blockLength: 100, configuration: configuration, sampleRate: 1000)
            == 100 + Int(configuration.maximumRouteDelay * 1000) + Int(CapturedAudio.sweepDecayAllowance * 1000))
    }

    // MARK: No wait lasts forever

    /// A room that is loud from the start, never quiet enough to give a floor.
    static let loudRoom = [NoiseBurst(start: .at(0), duration: nil, rms: 0.05)]

    @Test func `a speaker test in a room too loud for a floor ends too noisy`() async {
        var configuration = Fixture.configuration
        configuration.maximumFloorWait = 5
        let io = Fixture.io(bursts: Self.loudRoom)
        let session = Fixture.session(io: io, configuration: configuration)
        let final = await session.run()
        #expect(final == .failed(.tooNoisy))
        #expect(io.scheduledBufferCount == 0)
    }

    @Test func `a seat measurement in a room too loud for a floor ends too noisy, by default within the longest wait`() async {
        let io = SeatFixture.io(bursts: Self.loudRoom)
        let session = SeatFixture.session(io: io)
        var states: [SeatMeasurementSession.State] = []
        session.onStateChange = { states.append($0) }
        let final = await session.run()
        #expect(final == .failed(.tooNoisy))
        #expect(io.scheduledBufferCount == 0)
        #expect(!states.contains { if case .waitingForStillness = $0 { true } else { false } })
        #expect(MeasurementConfiguration.standard.maximumFloorWait == 30)
    }

    @Test func `a phone that never stops moving ends the seat measurement, with its own reason`() async {
        let io = SeatFixture.io()
        let session = SeatFixture.session(io: io, stillness: ConstantStillnessMonitor(isSteady: false))
        let final = await session.run()
        #expect(final == .failed(.phoneNeverStill))
        #expect(io.scheduledBufferCount == 0)
        #expect(SeatMeasurementSession.maximumStillnessWait == 30)
        #expect(SeatSessionText.failureHeadline(.phoneNeverStill) == "The phone never settled.")
        #expect(SeatSessionText.failureBody(.phoneNeverStill).hasPrefix("I wait for the phone to be still"))
    }

    // MARK: A route that cannot be told

    @Test func `an output route that cannot be told is measured, and nothing is said about it`() async throws {
        let io = UnknownRouteIO(Fixture.io())
        #expect(io.outputRoute == nil)
        let final = await MeasurementSession(
            io: io, channel: .left, permission: SimulatedMicrophonePermission(.granted), stillness: ConstantStillnessMonitor()
        ).run()
        let result = try #require(final.result)
        #expect(result.runs.count == Fixture.configuration.runCount)
    }
}

/// An IO that plays and records through a simulated one but cannot tell where the sound goes.
final class UnknownRouteIO: AudioIO {
    let inner: SimulatedAudioIO
    init(_ inner: SimulatedAudioIO) { self.inner = inner }
    func start() async throws -> CaptureStream { try await inner.start() }
    func schedule(_ samples: [Float], on channel: SpeakerChannel, mode: PlaybackMode) throws -> Int64 {
        try inner.schedule(samples, on: channel, mode: mode)
    }
    func stopPlayback() { inner.stopPlayback() }
    func stop() async { await inner.stop() }
    var outputRoute: AudioOutputRoute? { nil }
}
