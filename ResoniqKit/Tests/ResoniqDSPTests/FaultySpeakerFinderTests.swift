import Accelerate
import Foundation
import Testing
@testable import ResoniqDSP

/// A second-order low-pass (RBJ), for the faulty speakers below.
func lowPass(at frequency: Double, q: Double = 0.707, sampleRate: Double = 48000) -> Biquad {
    let w = 2 * Double.pi * frequency / sampleRate
    let alpha = sin(w) / (2 * q)
    let a0 = 1 + alpha
    return Biquad(b0: (1 - cos(w)) / 2 / a0, b1: (1 - cos(w)) / a0, b2: (1 - cos(w)) / 2 / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
}

/// The speakers the app exists to diagnose, as filters: each an eighth-order edge (four sections, 48 dB an octave).
enum FaultySpeaker: String, CaseIterable, CustomTestStringConvertible {
    /// A dead tweeter: nothing above 2 kHz (48 dB down by 4 kHz).
    case deadTweeter
    /// A dead woofer: nothing below 500 Hz.
    case deadWoofer
    /// A narrow speaker: 200 Hz to 2 kHz only.
    case narrow
    /// A subwoofer on its own: nothing above 150 Hz.
    case subwooferAlone

    var testDescription: String { rawValue }

    var filters: [Biquad] {
        let high = { (f: Double) in [Biquad](repeating: .highPass(frequency: f, q: 0.707, sampleRate: 48000), count: 4) }
        let low = { (f: Double) in [Biquad](repeating: lowPass(at: f), count: 4) }
        return switch self {
        case .deadTweeter: high(60) + low(2000)
        case .deadWoofer: high(500)
        case .narrow: high(200) + low(2000)
        case .subwooferAlone: low(150)
        }
    }
}

@Suite struct FaultySpeakerFinderTests {
    static let sampleRate = 48000.0
    static let sweep = LogSweep.measurement(sampleRate: 48000)
    static let starts = [2.0, 9.0, 16.0].map { $0 * 48000 + 0.3 }

    static func recording(_ speaker: FaultySpeaker) -> [Float] {
        ExternalRecording(starts: starts, filters: speaker.filters, noiseRMS: 0.001, duration: 22).record()
    }

    @Test(arguments: [FaultySpeaker.deadTweeter, .deadWoofer, .narrow])
    func `a speaker that plays part of the range is found once the file's timing anchors it`(speaker: FaultySpeaker) {
        let recording = Self.recording(speaker)
        let anchored = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep, anchored: true)
        let strict = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep)
        print("\(speaker): \(anchored.count) found anchored, \(strict.count) unanchored")
        #expect(anchored.count == 3)
        for (found, start) in zip(anchored, Self.starts) {
            // An eighth-order edge delays its own band by a few milliseconds.
            #expect(abs(found.start - start) < 0.01 * Self.sampleRate, "found at \(found.start), played at \(start)")
            #expect(found.isComplete)
        }
    }

    @Test func `a subwoofer alone is not found: nothing of it lies in the detection band`() {
        let recording = Self.recording(.subwooferAlone)
        #expect(SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep, anchored: true).isEmpty)
    }

    /// Music with a strong 1 kHz tone, then, where a sweep would be due, a glissando: one that rises at the sweep's own
    /// rate over an octave, a semitone glissando over two octaves, and an exact-rate octave and a half across a band
    /// edge. Even anchored, none is taken for a sweep.
    @Test func `a tone followed by a glissando does not pass for an anchored sweep`() {
        var signal = syntheticTune(seconds: 40, sampleRate: Self.sampleRate).map { Double($0) * 0.5 }
        func add(_ samples: [Double], at seconds: Double) {
            let first = Int(seconds * Self.sampleRate)
            for (index, value) in samples.enumerated() where first + index < signal.count { signal[first + index] += value }
        }
        func tone(at seconds: Double) {
            add((0..<Int(2 * Self.sampleRate)).map { 0.125 * sin(2 * Double.pi * 1000 * Double($0) / Self.sampleRate) }, at: seconds)
        }
        /// The sweep's own law from `low` to `high` hertz.
        func exactGlide(from low: Double, to high: Double) -> [Double] {
            let first = Int(Self.sweep.time(of: low) * Self.sampleRate)
            let last = Int(Self.sweep.time(of: high) * Self.sampleRate)
            return Self.sweep.samples()[first..<last].map { Double($0) * 1.5 }
        }
        func semitones(from low: Double, steps: Int, stepSeconds: Double) -> [Double] {
            var phase = 0.0
            var out: [Double] = []
            for step in 0..<steps {
                let frequency = low * pow(2, Double(step) / 12)
                for _ in 0..<Int(stepSeconds * Self.sampleRate) {
                    phase += 2 * Double.pi * frequency / Self.sampleRate
                    out.append(0.3 * sin(phase))
                }
            }
            return out
        }
        tone(at: 1)
        add(exactGlide(from: 350, to: 700), at: 5 + Self.sweep.time(of: 350))
        tone(at: 13)
        add(semitones(from: 400, steps: 25, stepSeconds: 0.06), at: 17 + Self.sweep.time(of: 400))
        tone(at: 25)
        add(exactGlide(from: 300, to: 850), at: 29 + Self.sweep.time(of: 300))
        let recording = signal.map(Float.init)
        let found = SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep, anchored: true)
        print("tone and glissando, anchored: \(found)")
        #expect(found.isEmpty)
        #expect(SweepFinder.find(in: recording, sampleRate: Self.sampleRate, sweep: Self.sweep).isEmpty)
    }

    @Test func `anchoring does not let noise or the tune through`() {
        let noise = pinkNoise(count: Int(60 * Self.sampleRate), rms: 0.05, seed: 3)
        #expect(SweepFinder.find(in: noise, sampleRate: Self.sampleRate, sweep: Self.sweep, anchored: true).isEmpty)
        let tune = syntheticTune(seconds: 60, sampleRate: Self.sampleRate)
        #expect(SweepFinder.find(in: tune, sampleRate: Self.sampleRate, sweep: Self.sweep, anchored: true).isEmpty)
    }
}
