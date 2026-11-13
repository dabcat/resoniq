import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

@Suite struct TonePlayerTests {
    @Test(arguments: [40.0, 1000.0, 1234.5, 15000.0])
    func `the loop holds whole periods within a fraction of a percent of the frequency`(frequency: Double) {
        let (length, exact) = TonePlayer.loop(for: frequency, sampleRate: 48000)
        #expect(TonePlayer.loopDurations.contains(Double(length) / 48000))
        #expect(abs(exact - frequency) / frequency < 0.002)
        let periods = exact * Double(length) / 48000
        #expect(abs(periods - periods.rounded()) < 1e-9)
    }

    /// Fade in, the loop several times, the fade out taking over at a loop point: one continuous tone that starts
    /// and ends at silence, at the safe level, with no step anywhere.
    @Test func `a held tone is seamless, safe, and fades in and out`() async throws {
        let tone = TonePlayer.segments(frequency: 1000, sampleRate: 48000)
        let io = SimulatedAudioIO(configuration: .init(
            noiseRMS: 0, left: SimulatedSpeaker(), right: SimulatedSpeaker(gain: 0), pacing: .immediate
        ))
        let stream = try await io.start()
        var recorded: [Float] = []
        for try await block in stream.blocks {
            if block.position == 0 {
                _ = try io.schedule(tone.fadeIn, on: .left, mode: .once)
                _ = try io.schedule(tone.loop, on: .left, mode: .loop)
            }
            if block.position == 48000 { _ = try io.schedule(tone.fadeOut, on: .left, mode: .afterLoop) }
            recorded += block.samples
            if block.position >= 72000 { break }
        }
        await io.stop()

        let peak = recorded.map(abs).max() ?? 0
        #expect(peak <= LogSweep.maximumAmplitude + 1e-6)
        #expect(peak > LogSweep.maximumAmplitude * 0.99)
        // A 1 kHz sine at 0.25 changes by at most 2π·1000/48000·0.25 ≈ 0.033 a sample; a seam would jump further.
        let step = zip(recorded, recorded.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        #expect(step < 0.034)
        #expect(recorded.prefix(2400).allSatisfy { $0 == 0 })
        #expect(recorded.suffix(4800).allSatisfy { $0 == 0 })
    }

    @MainActor
    @Test func `stopping releases the audio`() async throws {
        let io = Fixture.io()
        let player = TonePlayer(io: io)
        try await player.start(frequency: 440, on: .right)
        #expect(player.isPlaying)
        #expect(abs((player.frequency ?? 0) - 440) < 1)
        #expect(io.isRunning && io.isPlaying)
        await player.stopAndWait()
        #expect(!player.isPlaying && player.frequency == nil)
        #expect(!io.isRunning)
        #expect(io.scheduledBufferCount == 3)
    }
}
