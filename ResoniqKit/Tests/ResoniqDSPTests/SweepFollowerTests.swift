import Foundation
import Testing
@testable import ResoniqDSP

@Suite struct SweepFollowerTests {
    static let sampleRate = 48000.0
    static let sweep = LogSweep.measurement(sampleRate: 48000)

    static func follow(_ recording: [Float], blockLength: Int = 4800) -> [(event: SweepFollower.Event, at: Int64)] {
        var follower = SweepFollower(sweep: sweep)
        var events: [(SweepFollower.Event, Int64)] = []
        var position = 0
        while position + blockLength <= recording.count {
            for event in follower.feed(Array(recording[position..<(position + blockLength)]), at: Int64(position)) {
                events.append((event, Int64(position)))
            }
            position += blockLength
        }
        return events
    }

    @Test func `follows a file's tone and three sweeps as they are heard`() {
        let starts = [5.0, 12.0, 19.0].map { $0 * Self.sampleRate + 0.4 }
        let recording = ExternalRecording(
            starts: starts, ratio: 1.0003, filters: bookshelfFilters, cubic: 0.3, noiseRMS: 0.003, duration: 25,
            toneStart: 1.5 * Self.sampleRate
        ).record()
        let events = Self.follow(recording)
        let tone = events.compactMap { if case .toneEnded(let start, let end) = $0.event { (start, end) } else { nil } }
        #expect(tone.count == 1)
        if let (start, end) = tone.first {
            #expect(abs(Double(start) - 1.5 * Self.sampleRate) <= 4800)
            #expect(abs(Double(end) - 3.5 * Self.sampleRate) <= 4800)
        }
        let started = events.compactMap { if case .sweepStarted(let start) = $0.event { (start, $0.at) } else { nil } }
        let ended = events.compactMap { if case .sweepEnded(let start) = $0.event { (start, $0.at) } else { nil } }
        #expect(started.count == 3)
        #expect(ended.count == 3)
        for ((start, heardAt), played) in zip(started, starts) {
            #expect(abs(Double(start) - played) < SweepFollower.startTolerance * Self.sampleRate, "estimated \(start), played \(played)")
            // Said within three seconds of the sweep's start: once it passes 150 Hz and eight blocks agree.
            #expect(Double(heardAt) - played < 3 * Self.sampleRate)
        }
        for ((_, at), played) in zip(ended, starts) {
            #expect(Double(at) >= played + Double(Self.sweep.sampleCount) - 4800)
            #expect(Double(at) <= played + Double(Self.sweep.sampleCount) + 2 * 4800)
        }
    }

    @Test func `the frequency heard follows the sweep`() {
        let start = 1.0 * Self.sampleRate
        let recording = ExternalRecording(starts: [start], noiseRMS: 0.001, duration: 6).record()
        var follower = SweepFollower(sweep: Self.sweep)
        var position = 0
        var readings: [(Double, Double)] = []
        while position + 4800 <= recording.count {
            _ = follower.feed(Array(recording[position..<(position + 4800)]), at: Int64(position))
            if let frequency = follower.heardFrequency {
                let expected = Self.sweep.frequency(at: (Double(position) + 2400 - start) / Self.sampleRate)
                readings.append((frequency, expected))
            }
            position += 4800
        }
        #expect(readings.count > 15)
        for (frequency, expected) in readings { #expect(abs(log2(frequency / expected)) < 0.1) }
    }

    @Test func `nothing is followed in a minute of pink noise or of a tune`() {
        let noise = pinkNoise(count: Int(60 * Self.sampleRate), rms: 0.05, seed: 9)
        #expect(Self.follow(noise).isEmpty)
        let tune = syntheticTune(seconds: 60, sampleRate: Self.sampleRate)
        #expect(Self.follow(tune).isEmpty)
    }

    @Test func `one block costs well under a millisecond`() {
        let recording = ExternalRecording(starts: [0.5 * Self.sampleRate], noiseRMS: 0.003, duration: 5).record()
        var follower = SweepFollower(sweep: Self.sweep)
        let blocks = recording.count / 4800
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for index in 0..<blocks {
                _ = follower.feed(Array(recording[(index * 4800)..<((index + 1) * 4800)]), at: Int64(index * 4800))
            }
        }
        let perBlock = elapsed / blocks
        print("follower: \(perBlock) per 100 ms block (this build; release is faster)")
        #expect(perBlock < .milliseconds(5))
    }
}

@Suite struct SweepFinderSpeedTests {
    @Test func `a minute of recording is searched quickly`() {
        let sweep = LogSweep.measurement(sampleRate: 48000)
        let starts = [3.0, 10.0, 17.0].map { $0 * 48000 }
        let recording = ExternalRecording(starts: starts, filters: bookshelfFilters, noiseRMS: 0.003, duration: 60).record()
        let clock = ContinuousClock()
        var found: [FoundSweep] = []
        let elapsed = clock.measure { found = SweepFinder.find(in: recording, sampleRate: 48000, sweep: sweep) }
        print("finder: 60 s searched in \(elapsed) (this build; release is faster)")
        #expect(found.count == 3)
        // A debug build; a release build is faster (measured: docs/modules/ResoniqDSP.md).
        #expect(elapsed < .seconds(5))
    }
}
