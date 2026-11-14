import Foundation
import Testing
@testable import ResoniqDSP

/// Finding the sweep at the listening seat: a phone 2–3 m from the speakers hears more of the room than of the
/// speakers, so the reverberant tail after each arrival is legitimately large. The grid runs the finder (both rules)
/// and the follower over direct-to-reverberant ratios from +6 to −12 dB, three reverberation times, two noise levels
/// and three player clocks. The results and the limit are stated in `docs/modules/ResoniqDSP.md`.
@Suite struct ReverberantFinderTests {
    static let sampleRate = 48000.0
    static let sweep = LogSweep.measurement(sampleRate: 48000)
    static let ratios: [Double] = [6, 3, 0, -3, -6, -9, -12]
    static let start = 6 * 48000 + 0.3

    struct Condition: CustomTestStringConvertible, Sendable {
        var reverberationTime: Double
        var noiseDecibels: Double
        var ppm: Double
        var testDescription: String { "RT60 \(reverberationTime) s, noise \(Int(noiseDecibels)) dBFS, clock \(Int(ppm)) ppm" }
    }

    static let conditions: [Condition] = [0.3, 0.6, 1.0].flatMap { time in
        [-60.0, -45].flatMap { noise in [-300.0, 0, 300].map { Condition(reverberationTime: time, noiseDecibels: noise, ppm: $0) } }
    }

    /// What was found in one room: by each rule, how far from where the sweep arrived, and whether the follower heard
    /// the tone and the sweep.
    struct Outcome: CustomStringConvertible {
        var strict: [FoundSweep]
        var anchored: [FoundSweep]
        var followerTone: Bool
        var followerSweep: Bool

        func error(_ found: [FoundSweep]) -> Double? { found.first.map { $0.start - ReverberantFinderTests.start } }
        var description: String {
            func one(_ found: [FoundSweep]) -> String { error(found).map { String(format: "%.1f", $0) } ?? "none" }
            return "strict \(one(strict)), anchored \(one(anchored)), follower tone \(followerTone) sweep \(followerSweep)"
        }
    }

    static func outcome(_ recording: [Float]) -> Outcome {
        let strict = SweepFinder.find(in: recording, sampleRate: sampleRate, sweep: sweep, expectedCount: 1)
        let anchored = SweepFinder.find(in: recording, sampleRate: sampleRate, sweep: sweep, expectedCount: 1, anchored: true)
        var follower = SweepFollower(sweep: sweep)
        var tone = false
        var heard = false
        var position = 0
        while position + 4800 <= recording.count {
            for event in follower.feed(Array(recording[position..<(position + 4800)]), at: Int64(position)) {
                if case .toneStarted = event { tone = true }
                // Within the margin the sessions cut with: reverberation makes the follower's estimate late.
                if case .sweepStarted(let start) = event, abs(Double(start) - Self.start) < (SweepFollower.startTolerance + 0.1) * sampleRate {
                    heard = true
                }
            }
            position += 4800
        }
        return Outcome(strict: strict, anchored: anchored, followerTone: tone, followerSweep: heard)
    }

    /// A speaker toed away from the seat: a wall's reflection 4 ms after the direct sound arrives 3.5 dB stronger than
    /// it. The arrival is the direct sound.
    @Test func `the arrival is the direct sound, not a stronger reflection`() {
        let room = ReverberantRoom(
            directToReverberant: -7, reverberationTime: 0.5, reflections: [.init(delay: 0.004, gain: 1.5)]
        )
        for ppm in [0.0, 300] {
            let recording = reverberantRecording(room: room, ratio: 1 + ppm * 1e-6)
            let outcome = Self.outcome(recording)
            print("stronger reflection, \(ppm) ppm: \(outcome)")
            let allowed = 4 * ppm * 1e-6 * Self.sampleRate + 24
            #expect(abs(outcome.error(outcome.anchored) ?? .infinity) < allowed)
        }
    }

    @Test(arguments: conditions)
    func `the sweep is found at its arrival across the grid of rooms`(condition: Condition) {
        for ratio in Self.ratios {
            let room = ReverberantRoom(directToReverberant: ratio, reverberationTime: condition.reverberationTime)
            let recording = reverberantRecording(room: room, ratio: 1 + condition.ppm * 1e-6, noiseDecibels: condition.noiseDecibels)
            let outcome = Self.outcome(recording)
            print("GRID \(condition.testDescription), \(room): \(outcome)")
            // The direct sound, not a reflection, is the arrival; the clock moves the matched filter's peak by up to
            // the sweep's length times the offset (the treble, most of the filter's band, arrives that much early).
            let allowed = 4 * abs(condition.ppm) * 1e-6 * Self.sampleRate + 24
            for (rule, found) in [("strict", outcome.strict), ("anchored", outcome.anchored)] {
                #expect(found.count == 1, "\(rule) rule, \(room)")
                if let error = outcome.error(found) { #expect(abs(error) < allowed, "\(rule) rule, \(room): \(error) samples off") }
            }
            #expect(outcome.followerTone, "follower missed the tone, \(room)")
            #expect(outcome.followerSweep, "follower missed the sweep, \(room)")
        }
    }
}
