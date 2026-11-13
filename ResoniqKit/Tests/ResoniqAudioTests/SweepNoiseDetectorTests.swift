import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

/// Records `seconds` of a simulated IO, scheduling `buffers` at the given times.
func capture(
    _ io: SimulatedAudioIO,
    seconds: Double,
    schedule: [(at: Double, samples: [Float])] = []
) async throws -> [Float] {
    let stream = try await io.start()
    var pending = schedule
    var recorded: [Float] = []
    let total = Int(seconds * stream.sampleRate)
    for try await block in stream.blocks {
        while let next = pending.first, Double(block.end) / stream.sampleRate >= next.at {
            _ = try io.schedule(next.samples, on: .left, mode: .once)
            pending.removeFirst()
        }
        recorded += block.samples
        if recorded.count >= total { break }
    }
    await io.stop()
    return recorded
}

func blocks(_ samples: [Float], length: Int = 4800) -> [[Float]] {
    stride(from: 0, through: samples.count - length, by: length).map { Array(samples[$0..<($0 + length)]) }
}

@Suite(.timeLimit(.minutes(3))) struct SweepNoiseDetectorTests {
    static let floorSeconds = 1.0

    /// A floor, then a sweep played through `speaker`.
    func record(speaker: SimulatedSpeaker = .bookshelf, bursts: [NoiseBurst] = []) async throws -> (floor: [Float], run: [Float]) {
        let io = Fixture.io(bursts: bursts, speaker: speaker)
        let samples = try await capture(io, seconds: Self.floorSeconds + Fixture.sweep.duration + 0.5, schedule: [(Self.floorSeconds, Fixture.sweep.samples())])
        let split = Int(Self.floorSeconds * Fixture.sampleRate)
        return (Array(samples[0..<split]), Array(samples[split...]))
    }

    @Test(arguments: [
        SimulatedSpeaker.bookshelf,
        SimulatedSpeaker(gain: 0.5, filters: [.highPass(frequency: 70, q: 0.707)], defect: .init(band: 200...400, cubic: 20)),
        SimulatedSpeaker(gain: 0.5, filters: [.peaking(frequency: 3000, q: 4, gain: -15), .peaking(frequency: 300, q: 2, gain: 10)]),
    ])
    func `a quiet room is never too noisy while the sweep plays`(speaker: SimulatedSpeaker) async throws {
        let (floor, run) = try await record(speaker: speaker)
        let detector = SweepNoiseDetector(noiseFloor: floor, sweep: Fixture.sweep, blockLength: 4800)
        let assessments = blocks(run).map(detector.assess)
        let worst = assessments.map(\.riseDecibels).max() ?? 0
        print("quiet room, sweep playing: worst rise \(worst) dB over \(assessments.count) blocks")
        #expect(!assessments.contains { $0.isTooNoisy })
        #expect(worst < 6)
    }

    @Test func `the tone found is the sweep's frequency at the block's centre`() async throws {
        let (floor, run) = try await record()
        let detector = SweepNoiseDetector(noiseFloor: floor, sweep: Fixture.sweep, blockLength: 4800)
        // The sweep was scheduled 50 ms after the floor ended (the lead) and the route adds 20 ms.
        let offset = 0.05 + 0.02
        for (index, block) in blocks(run).enumerated() {
            let centre = (Double(index) + 0.5) * 0.1 - offset
            // From about 60 Hz (a bin is 5.9 Hz wide) to about 17 kHz, short of the sweep's fade-out.
            guard centre > 1.0, centre < 3.9 else { continue }
            let expected = Fixture.sweep.frequency(at: centre)
            let found = try #require(detector.assess(block).sweepFrequency)
            #expect(abs(log2(found / expected)) < 0.05, "block \(index): \(found) Hz, expected \(expected) Hz")
        }
    }

    @Test func `noise during the sweep is too noisy`() async throws {
        // 20 dB above the −80 dBFS floor would be 1e-3; 3e-3 is about 30 dB above.
        let burst = NoiseBurst(start: .at(Self.floorSeconds + 1.5), duration: 0.3, rms: 3e-3)
        let (floor, run) = try await record(bursts: [burst])
        let detector = SweepNoiseDetector(noiseFloor: floor, sweep: Fixture.sweep, blockLength: 4800)
        let noisy = blocks(run).map(detector.assess).enumerated().filter { $0.element.isTooNoisy }.map(\.offset)
        #expect(noisy == [15, 16, 17])
    }

    @Test func `without a sweep it is the plain gate`() async throws {
        let io = Fixture.io(bursts: [NoiseBurst(start: .at(1.0), duration: nil, rms: 1e-3)])
        let samples = try await capture(io, seconds: 2)
        let detector = SweepNoiseDetector(noiseFloor: Array(samples[0..<48000]), sweep: Fixture.sweep, blockLength: 4800)
        let quiet = detector.assess(Array(samples[24000..<28800]))
        let loud = detector.assess(Array(samples[72000..<76800]))
        #expect(!quiet.isTooNoisy && quiet.sweepFrequency == nil)
        #expect(loud.isTooNoisy)
        #expect(abs(loud.roomLevel.dBFS - -60) < 1)
    }

    /// The strongest tone is chosen by its rise over the floor, so it need not be the loudest bin around it. A
    /// parabola through a bin that is not a local maximum puts its vertex far away (here about 20 bins up), and the
    /// excluded band's bounds then crossed and trapped (seen with 1031-sample blocks and a 0.7 s route, and in a
    /// simulated room).
    @Test func `a strongest tone that is not the loudest of its neighbours is placed at the louder bin beside it`() {
        // −40, −20 and −1 dB: the middle bin is above its neighbours' mean but below the louder one.
        let power: [Float] = [1e-3, 1e-4, 1e-2, 0.79, 1e-3]
        let bin = SweepNoiseDetector.interpolatedBin(power, at: 2)
        #expect(bin >= 2.5 && bin <= 3.5, "\(bin)")
    }
}
