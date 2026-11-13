import Foundation
import ResoniqDSP
import Synchronization
import Testing
@testable import ResoniqAudio

/// An `AudioIO` whose microphone hears a steady sine, produced as fast as it is read; it records what was asked of it.
final class ToneAudioIO: AudioIO {
    struct Calls: Sendable {
        var starts = 0
        var stops = 0
        var schedules = 0
        var blocksDelivered = 0
    }

    let sampleRate: Double
    let frequency: Double
    let amplitude: Double
    let blockSize: Int
    private let calls = Mutex(Calls())

    init(sampleRate: Double = 48000, frequency: Double = 1000, amplitude: Double = 0.1, blockSize: Int = 4800) {
        self.sampleRate = sampleRate
        self.frequency = frequency
        self.amplitude = amplitude
        self.blockSize = blockSize
    }

    var recorded: Calls { calls.withLock { $0 } }

    func start() async throws -> CaptureStream {
        calls.withLock { $0.starts += 1 }
        let (sampleRate, frequency, amplitude, blockSize) = (sampleRate, frequency, amplitude, blockSize)
        let blocks = AsyncThrowingStream<CapturedBlock, any Error>(unfolding: { [self] in
            if Task.isCancelled { return nil }
            let index = self.calls.withLock { calls in
                defer { calls.blocksDelivered += 1 }
                return calls.blocksDelivered
            }
            let start = index * blockSize
            let samples = (0..<blockSize).map { Float(amplitude * sin(2 * Double.pi * frequency * Double(start + $0) / sampleRate)) }
            return CapturedBlock(position: Int64(start), samples: samples)
        })
        return CaptureStream(sampleRate: sampleRate, blocks: blocks)
    }

    func schedule(_ samples: [Float], on channel: SpeakerChannel, mode: PlaybackMode) throws -> Int64 {
        calls.withLock { $0.schedules += 1 }
        return 0
    }

    func stopPlayback() {}

    func stop() async {
        calls.withLock { $0.stops += 1 }
    }
}

@Suite struct LiveSpectrumTests {
    static func tone(seconds: Double, frequency: Double = 1000, amplitude: Double = 0.1, sampleRate: Double = 48000) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { Float(amplitude * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
    }

    @Test func `a 1 kHz tone reads its level in the 1 kHz band and far less elsewhere`() async throws {
        let io = ToneAudioIO(amplitude: 0.1)
        var latest: MagnitudeResponse?
        var count = 0
        for await update in LiveSpectrum(io: io).bands() {
            latest = update
            count += 1
            if count == 30 { break }
        }
        let bands = try #require(latest)
        #expect(bands.count == 31)
        #expect(abs(bands.frequencies.first! - 19.95) < 0.01 && abs(bands.frequencies.last! - 19953) < 1)
        let index = try #require(bands.frequencies.firstIndex { abs($0 - 1000) < 1 })
        // A sine of amplitude 0.1 has an RMS of 0.0707: −23.0 dBFS.
        let expected = Float(20 * log10(0.1 / 2.0.squareRoot()))
        print("1 kHz band \(bands.decibels[index]) dBFS (expected \(expected)); neighbours \(bands.decibels[index - 1]), \(bands.decibels[index + 1])")
        #expect(abs(bands.decibels[index] - expected) < 0.5)
        for (offset, level) in bands.decibels.enumerated() where offset != index {
            let margin: Float = abs(offset - index) == 1 ? 30 : 60
            #expect(level < expected - margin, "band \(bands.frequencies[offset]) Hz reads \(level)")
        }
        #expect(io.recorded.schedules == 0)
    }

    @Test func `the stream ends and the microphone stops when its task is cancelled`() async throws {
        let io = ToneAudioIO()
        let listener = Task {
            var count = 0
            for await _ in LiveSpectrum(io: io).bands() { count += 1 }
            return count
        }
        // Let it run a little, counted in blocks rather than time.
        while io.recorded.blocksDelivered < 20 { await Task.yield() }
        listener.cancel()
        let count = await listener.value
        #expect(count > 0)
        var spins = 0
        while io.recorded.stops == 0, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(io.recorded.starts == 1 && io.recorded.stops == 1 && io.recorded.schedules == 0)
        // Nothing reads the microphone any more.
        let delivered = io.recorded.blocksDelivered
        for _ in 0..<1000 { await Task.yield() }
        #expect(io.recorded.blocksDelivered == delivered)
    }

    @Test func `the microphone stops when the consumer stops iterating`() async {
        let io = ToneAudioIO()
        for await _ in LiveSpectrum(io: io).bands() { break }
        var spins = 0
        while io.recorded.stops == 0, spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(io.recorded.stops == 1)
    }

    @Test func `there are fifteen updates a second of audio, whatever the block size`() {
        for blockSize in [4800, 1031, 48000] {
            var analyzer = LiveSpectrumAnalyzer(sampleRate: 48000)
            let samples = Self.tone(seconds: 2)
            var updates = 0
            var offset = 0
            while offset < samples.count {
                let end = min(offset + blockSize, samples.count)
                updates += analyzer.append(Array(samples[offset..<end])).count
                offset = end
            }
            #expect(updates == 30, "blocks of \(blockSize)")
        }
    }

    @Test func `a band rises quickly and falls slowly by the documented steps`() {
        let attack = LiveSpectrum.smoothingCoefficient(time: LiveSpectrum.attackTime)
        let release = LiveSpectrum.smoothingCoefficient(time: LiveSpectrum.releaseTime)
        #expect(abs(attack - (1 - exp(-1 / (15 * 0.05)))) < 1e-12)
        #expect(attack > 0.7 && release < 0.2)
        #expect(abs(LiveSpectrum.smoothed(previous: -60, current: -20) - Float(-60 + attack * 40)) < 1e-4)
        #expect(abs(LiveSpectrum.smoothed(previous: -20, current: -60) - Float(-20 - release * 40)) < 1e-4)
    }

    @Test func `after the tone stops its band sinks at the release rate`() throws {
        var analyzer = LiveSpectrumAnalyzer(sampleRate: 48000)
        let toneUpdates = analyzer.append(Self.tone(seconds: 1))
        let silence = [Float](repeating: 0, count: 48000)
        let silentUpdates = analyzer.append(silence)
        let index = try #require(toneUpdates.last?.frequencies.firstIndex { abs($0 - 1000) < 1 })
        let levels = (toneUpdates + silentUpdates).map { $0.decibels[index] }
        let lastTone = levels[toneUpdates.count - 1]
        // Once the analysis window holds only silence, each update moves by `release` of the way down.
        let release = Float(LiveSpectrum.smoothingCoefficient(time: LiveSpectrum.releaseTime))
        let tail = Array(levels.suffix(4))
        for (a, b) in zip(tail, tail.dropFirst()) {
            #expect(b < a)
            #expect(abs((a - b) / (a - Decibels.floor) - release) < 0.01, "\(a) → \(b)")
        }
        // A second after the tone, the band has fallen but not vanished: readable, not a jump.
        #expect(tail.last! < lastTone - 20 && tail.last! > Decibels.floor + 10)
    }
}
