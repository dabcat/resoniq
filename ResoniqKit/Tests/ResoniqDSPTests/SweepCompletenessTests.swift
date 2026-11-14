import Foundation
import Testing
@testable import ResoniqDSP

/// A sweep stopped or paused part-way by the player, told from a speaker that does not play the top.
@Suite struct SweepCompletenessTests {
    static let sampleRate = 48000.0
    static let sweep = LogSweep.measurement(sampleRate: 48000)
    static let start = 0.5 * 48000

    /// One run: the sweep through `filters`, stopped `stoppedAt` seconds in (at the player, so the room still rings),
    /// in `room`, with noise.
    static func response(filters: [Biquad] = bookshelfFilters, stoppedAt: Double? = nil, room: ReverberantRoom? = nil, noise: Double = 0.0003) -> ImpulseResponse {
        var dry = ExternalRecording(starts: [start], filters: filters, duration: 6).record()
        if let stoppedAt {
            for index in Int(start + stoppedAt * sampleRate)..<dry.count { dry[index] = 0 }
        }
        var recording = room.map { $0.apply(dry, sampleRate: sampleRate) } ?? dry
        var generator = SeededGenerator(state: 3)
        recording = zip(recording, generator.noise(count: recording.count, rms: noise)).map { $0 + Float($1) }
        return Deconvolution.impulseResponse(recording: recording, sweep: sweep)
    }

    @Test(arguments: [nil, ReverberantRoom(directToReverberant: -6, reverberationTime: 0.6)])
    func `a whole sweep has not stopped, whatever the speaker`(room: ReverberantRoom?) {
        #expect(SweepCompleteness.stopFrequency(of: Self.response(room: room)) == nil)
        for speaker in [FaultySpeaker.deadTweeter, .deadWoofer, .narrow] {
            let stop = SweepCompleteness.stopFrequency(of: Self.response(filters: speaker.filters, room: room))
            #expect(stop == nil, "\(speaker) read as stopped at \(stop ?? 0) Hz")
        }
    }

    /// The review's cases: stopped 3.0 and 3.4 s into the sweep (3.2 and 6.9 kHz), in a quiet and a noisy room, dry
    /// and reverberant.
    @Test(arguments: [3.0, 3.4])
    func `a sweep stopped part-way is caught where it stopped`(seconds: Double) {
        let expected = Self.sweep.frequency(at: seconds)
        for (room, noise) in [(nil, 0.0003), (ReverberantRoom(directToReverberant: -6, reverberationTime: 0.6), 0.0003), (nil, 0.0056)] {
            let stop = SweepCompleteness.stopFrequency(of: Self.response(stoppedAt: seconds, room: room, noise: noise))
            let place = room.map { "\($0)" } ?? "dry"
            print("stopped at \(seconds) s (\(Int(expected)) Hz), \(place), noise \(noise): read at \(stop.map { Int($0) } ?? 0) Hz")
            if let stop {
                #expect(abs(log2(stop / expected)) < 0.25)
            } else {
                Issue.record("not caught: \(place), noise \(noise)")
            }
        }
    }

    @Test func `of three runs, the one cut short disagrees with the other two`() throws {
        let good = Self.response()
        let disagreement = try #require(SweepCompleteness.disagreement([good, Self.response(stoppedAt: 3.4), good]))
        #expect(disagreement[0] < 1 && disagreement[2] < 1)
        #expect(disagreement[1] > 20)
        // Late in the sweep, above `checkedBand`, only this comparison can see a stop.
        for seconds in [3.6, 3.7, 3.8] {
            let late = try #require(SweepCompleteness.disagreement([good, Self.response(stoppedAt: seconds), good]))
            print("stopped at \(seconds) s (\(Int(Self.sweep.frequency(at: seconds))) Hz): disagrees by \(late[1]) dB")
        }
        let alike = try #require(SweepCompleteness.disagreement([good, Self.response(room: nil, noise: 0.001), good]))
        #expect(alike.allSatisfy { $0 < 1 })
    }
}
