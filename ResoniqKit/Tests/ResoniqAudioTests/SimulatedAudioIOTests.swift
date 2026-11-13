import Foundation
import ResoniqDSP
import Synchronization
import Testing
@testable import ResoniqAudio

@Suite(.timeLimit(.minutes(3))) struct SimulatedAudioIOTests {
    @Test func `a buffer arrives at the scheduled position plus the route delay`() async throws {
        let io = SimulatedAudioIO(configuration: .init(
            routeDelay: 0.1, noiseRMS: 0, left: SimulatedSpeaker(), right: SimulatedSpeaker(), pacing: .immediate
        ))
        let stream = try await io.start()
        var recorded: [Float] = []
        var scheduled: Int64 = 0
        for try await block in stream.blocks {
            if block.position == 0 { scheduled = try io.schedule([0.25], on: .left, mode: .once) }
            recorded += block.samples
            if recorded.count > 20000 { break }
        }
        await io.stop()
        #expect(scheduled == 2400 + 4800) // the 50 ms lead after the block just delivered
        #expect(recorded.firstIndex { $0 != 0 } == Int(scheduled) + 4800)
        #expect(!io.isRunning)
    }

    @Test func `a channel plays only through its own speaker`() async throws {
        // `capture` plays on the left.
        let heard = SimulatedAudioIO(configuration: .init(
            noiseRMS: 0, left: SimulatedSpeaker(gain: 1), right: SimulatedSpeaker(gain: 0), pacing: .immediate
        ))
        #expect(try await capture(heard, seconds: 0.5, schedule: [(0.1, [0.25])]).contains { $0 != 0 })
        let silent = SimulatedAudioIO(configuration: .init(
            noiseRMS: 0, left: SimulatedSpeaker(gain: 0), right: SimulatedSpeaker(gain: 1), pacing: .immediate
        ))
        #expect(try await capture(silent, seconds: 0.5, schedule: [(0.1, [0.25])]).allSatisfy { $0 == 0 })
    }

    @Test func `stopping playback silences what is queued`() async throws {
        let io = Fixture.io(noiseRMS: 0)
        let stream = try await io.start()
        var after: [Float] = []
        for try await block in stream.blocks {
            if block.position == 0 { _ = try io.schedule([Float](repeating: 0.25, count: 48000), on: .both, mode: .once) }
            if block.position == 9600 {
                #expect(io.isPlaying)
                io.stopPlayback()
                #expect(!io.isPlaying)
            }
            // Past the route delay and the filters' ring.
            if block.position >= 9600 + 4800 * 2 { after += block.samples }
            if block.position >= 48000 { break }
        }
        await io.stop()
        #expect(after.allSatisfy { abs($0) < 1e-3 })
    }

    /// Real-time pacing asks to wake each block one block's time after the previous, counted from the start: the
    /// clock is injected, so the test checks the instants asked for instead of how late a loaded machine wakes.
    @Test func `real-time pacing waits one block of time per block`() async throws {
        let asked = Mutex<[ContinuousClock.Instant]>([])
        let io = SimulatedAudioIO(configuration: .init(blockSize: 480, pacing: .realTime)) { instant in
            asked.withLock { $0.append(instant) }
        }
        let before = ContinuousClock.now
        let stream = try await io.start()
        var count = 0
        for try await _ in stream.blocks {
            count += 1
            if count == 10 { break }
        }
        await io.stop()
        let instants = asked.withLock { $0 }
        #expect(instants.count >= 10)
        // The first wake is one block (10 ms) after the stream began, which was after `before`.
        #expect(instants[0] - before >= .milliseconds(10))
        for (a, b) in zip(instants, instants.dropFirst()) {
            #expect(abs((b - a - .milliseconds(10)) / .microseconds(1)) < 1, "\(b - a)")
        }
    }

    @Test func `real-time pacing really waits`() async throws {
        // One coarse wall-clock check, with no upper bound that a loaded machine could break.
        let io = SimulatedAudioIO(configuration: .init(blockSize: 480, pacing: .realTime))
        let began = ContinuousClock.now
        let stream = try await io.start()
        var count = 0
        for try await _ in stream.blocks {
            count += 1
            if count == 5 { break }
        }
        await io.stop()
        #expect(ContinuousClock.now - began >= .milliseconds(45))
    }

    @Test func `a failure ends the stream with its error`() async throws {
        let io = Fixture.io()
        let stream = try await io.start()
        await #expect(throws: AudioIOError.routeChanged) {
            for try await block in stream.blocks where block.position == 9600 {
                io.fail(with: .routeChanged)
            }
        }
        #expect(!io.isRunning)
        #expect(throws: AudioIOError.notRunning) { try io.schedule([0], on: .left, mode: .once) }
    }

    @Test func `blocks of any size come out as fixed blocks, and a gap is noticed`() {
        var reblocker = Reblocker(length: 100)
        var out: [CapturedBlock] = []
        var position: Int64 = 0
        for size in [30, 170, 1, 99, 250] {
            let result = reblocker.append(CapturedBlock(position: position, samples: (0..<size).map { Float(position) + Float($0) }))
            #expect(!result.gap)
            out += result.blocks
            position += Int64(size)
        }
        #expect(out.map(\.position) == [0, 100, 200, 300, 400])
        #expect(out.allSatisfy { block in block.samples.enumerated().allSatisfy { Float(block.position) + Float($0.offset) == $0.element } })
        let gap = reblocker.append(CapturedBlock(position: position + 7, samples: [Float](repeating: 0, count: 100)))
        #expect(gap.gap)
        #expect(gap.blocks.map(\.position) == [position + 7])
    }
}
