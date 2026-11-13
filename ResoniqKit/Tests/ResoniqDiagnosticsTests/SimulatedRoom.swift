import Foundation
import ResoniqDSP
import ResoniqDiagnostics
import Synchronization

// A listening room for the seat tests: one speaker (or a pair) playing into a room whose bass modes change from spot
// to spot, recorded at three spots around the seat. Not a test.

extension Biquad {
    /// RBJ high shelf with a slope of 1: `gain` decibels above `frequency`, 0 dB well below it.
    static func highShelf(frequency: Double, gain decibels: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, decibels / 40)
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / 2 * 2.0.squareRoot()
        let rootA = a.squareRoot()
        let a0 = (a + 1) - (a - 1) * cos(w) + 2 * rootA * alpha
        return Biquad(
            b0: a * ((a + 1) + (a - 1) * cos(w) + 2 * rootA * alpha) / a0,
            b1: -2 * a * ((a - 1) + (a + 1) * cos(w)) / a0,
            b2: a * ((a + 1) + (a - 1) * cos(w) - 2 * rootA * alpha) / a0,
            a1: 2 * ((a - 1) - (a + 1) * cos(w)) / a0,
            a2: ((a + 1) - (a - 1) * cos(w) - 2 * rootA * alpha) / a0
        )
    }

    /// |H(e^jω)|² at `frequency`, from the coefficients: the independent expectation the tests compare with.
    func power(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        func evaluate(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let real = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let imaginary = -(c1 * sin(w) + c2 * sin(2 * w))
            return real * real + imaginary * imaginary
        }
        return evaluate(b0, b1, b2) / evaluate(1, a1, a2)
    }

    /// The time a pole pair of radius √a2 takes to decay by 60 dB, seconds.
    func ringTime(sampleRate: Double) -> Double {
        let radius = a2.squareRoot()
        return 6.908 / (-log(radius) * sampleRate)
    }
}

/// A room mode at the seat: a peaking filter whose gain differs from spot to spot (position dependence).
struct RoomMode: Sendable {
    var frequency: Double
    var q: Double
    /// Decibels at each spot: seat, left, right.
    var gains: [Double]
}

/// A speaker pair in a room, recorded at three spots.
///
/// One recording: the sweep times `gain`, delayed by `delaySamples` (the route), through the speaker's memoryless
/// nonlinearity `x + quadratic·x² + cubic·x³`, its high-pass at `rollOff`, the channel's high shelf (`tilt`), the
/// room's modes at that spot, a single early reflection of strength `reflection` arriving `reflectionDelays[spot]`
/// seconds after the direct sound, plus white noise (or noise low-passed at `noiseLowPass`), then an optional limiter.
struct SimulatedRoom: Sendable {
    static let sampleRate = 48000.0

    var gain: Double = 1
    var delaySamples: Double = 2400.5
    var quadratic: Double = 0.03
    var cubic: Double = 0.06
    var rollOff: Double = 25
    var modes: [RoomMode] = []
    /// Decibels of high shelf at `tiltFrequency`, left and right.
    var leftTilt: Double = 0
    var rightTilt: Double = 0
    var tiltFrequency: Double = 3000
    var reflection: Double = 0.2
    var reflectionDelays: [Double] = [0.0031, 0.0037, 0.0043]
    var noiseRMS: Double = 0.0005
    var noiseLowPass: Double?
    var clipLevel: Double?
    var tailSeconds: Double = 0.9
    var stereo = true

    enum Channel: Sendable { case left, right }

    /// The linear filters of one channel at one spot, in the order they are applied.
    func filters(spot: Int, channel: Channel) -> [Biquad] {
        let tilt = channel == .left ? leftTilt : rightTilt
        var list = [Biquad.highPass(frequency: rollOff, q: 0.707, sampleRate: Self.sampleRate)]
        if tilt != 0 { list.append(.highShelf(frequency: tiltFrequency, gain: tilt, sampleRate: Self.sampleRate)) }
        for mode in modes where mode.gains[spot] != 0 {
            list.append(.peaking(frequency: mode.frequency, q: mode.q, gain: mode.gains[spot], sampleRate: Self.sampleRate))
        }
        return list
    }

    func record(_ sweep: LogSweep, spot: Int, channel: Channel, seed: UInt64) -> [Float] {
        let length = sweep.sampleCount + Int(delaySamples.rounded(.up)) + Int(tailSeconds * sweep.sampleRate)
        var signal = SimulatedSpeaker.delayedSweep(sweep, by: delaySamples, length: length).map { Double($0) * gain }
        signal = signal.map { $0 + quadratic * $0 * $0 + cubic * $0 * $0 * $0 }
        for filter in filters(spot: spot, channel: channel) { signal = filter.process(signal) }
        let lag = Int((reflectionDelays[spot] * sweep.sampleRate).rounded())
        if reflection != 0 {
            let direct = signal
            for index in lag..<signal.count { signal[index] += reflection * direct[index - lag] }
        }
        if noiseRMS > 0 { signal = zip(signal, noise(count: length, seed: seed)).map(+) }
        if let ceiling = clipLevel { signal = signal.map { min(max($0, -ceiling), ceiling) } }
        return signal.map(Float.init)
    }

    func noise(count: Int, seed: UInt64) -> [Double] {
        var generator = SeededGenerator(state: seed)
        var noise = generator.noise(count: count, rms: noiseRMS)
        if let corner = noiseLowPass {
            // Two sections, then scaled back to `noiseRMS`.
            let lowPass = Biquad.lowPass(frequency: corner, q: 0.707, sampleRate: Self.sampleRate)
            noise = lowPass.process(lowPass.process(noise))
            let rms = (noise.reduce(0) { $0 + $1 * $1 } / Double(noise.count)).squareRoot()
            noise = noise.map { $0 * noiseRMS / rms }
        }
        return noise
    }

    /// The room's noise floor, as the app measures it before the spots: one second of the noise alone.
    func noiseFloor() -> NoiseFloorReport {
        let quiet = noise(count: Int(Self.sampleRate), seed: 0xF100).map(Float.init)
        return NoiseFloor.measure(quiet, sampleRate: Self.sampleRate)
    }

    // MARK: Expectations, from the filters' coefficients alone

    /// The power response of one channel at one spot, reflection included, at `frequency`.
    func expectedPower(at frequency: Double, spot: Int, channel: Channel) -> Double {
        let filtersPower = filters(spot: spot, channel: channel).reduce(1.0) { $0 * $1.power(at: frequency, sampleRate: Self.sampleRate) }
        let phase = 2 * Double.pi * frequency * reflectionDelays[spot]
        let comb = 1 + reflection * reflection + 2 * reflection * cos(phase)
        return gain * gain * filtersPower * comb
    }

    var channels: [Channel] { stereo ? [.left, .right] : [.left] }

    /// The seat's curve in dB: the power average over spots and channels.
    func expectedSeatDecibels(at frequency: Double) -> Double {
        var sum = 0.0
        for spot in 0..<3 { for channel in channels { sum += expectedPower(at: frequency, spot: spot, channel: channel) } }
        return 10 * log10(sum / Double(3 * channels.count))
    }

    /// The seat's middle level, as defined (the median from 200 Hz to 4 kHz), on the module's grid.
    func expectedMiddle() -> Double {
        let values = ResponseGrid.frequencies.filter { $0 >= 200 && $0 <= 4000 }.map { expectedSeatDecibels(at: Double($0)) }.sorted()
        return values.count % 2 == 1 ? values[values.count / 2] : (values[values.count / 2 - 1] + values[values.count / 2]) / 2
    }

    /// The largest deviation from the middle near `frequency` (within a sixth of an octave), in the given direction,
    /// and where it is, searched on a fine grid.
    func expectedExtreme(near frequency: Double, peak: Bool) -> (frequency: Double, decibels: Double) {
        let middle = expectedMiddle()
        let points = (0...400).map { frequency * pow(2, (Double($0) - 200) / 1200) }
        let values = points.map { (f: $0, d: expectedSeatDecibels(at: $0) - middle) }
        let best = peak ? values.max { $0.d < $1.d }! : values.min { $0.d < $1.d }!
        return (best.f, best.d)
    }

    /// The spot-to-spot spread at `frequency`: each spot's power average over channels, loudest less quietest.
    func expectedSpread(at frequency: Double) -> Double {
        let spots = (0..<3).map { spot in
            10 * log10(channels.reduce(0) { $0 + expectedPower(at: frequency, spot: spot, channel: $1) } / Double(channels.count))
        }
        return spots.max()! - spots.min()!
    }

    /// The largest |right − left| over 200 Hz to 10 kHz, each channel power averaged over the spots.
    func expectedLeftRight() -> Double {
        ResponseGrid.frequencies.filter { $0 >= 200 && $0 <= 10000 }.map { f in
            let left = (0..<3).reduce(0) { $0 + expectedPower(at: Double(f), spot: $1, channel: .left) }
            let right = (0..<3).reduce(0) { $0 + expectedPower(at: Double(f), spot: $1, channel: .right) }
            return abs(10 * log10(right / left))
        }.max()!
    }
}

/// The seat measurements the tests share, each made once.
enum SeatBench {
    /// The mockup's sweep length where distortion is asserted (the DSP states THD accuracy from 3 s); 2 s elsewhere.
    static let sweep = Bench.sweep
    static let shortSweep = Bench.responseSweep

    private static let cache = Mutex([String: [SpotAnalysis]]())

    /// Three spots of `room`, each spot's recordings seeded from `seed`. `adjust` changes one spot's room.
    static func spots(
        _ room: SimulatedRoom,
        seed: UInt64,
        sweep: LogSweep = shortSweep,
        key: String,
        quality: QualityThresholds = .standard,
        adjust: @Sendable (Int, inout SimulatedRoom) -> Void = { _, _ in }
    ) -> [SpotAnalysis] {
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let floor = room.noiseFloor()
        let results = Mutex([Int: SpotAnalysis]())
        DispatchQueue.concurrentPerform(iterations: 3) { spot in
            var here = room
            adjust(spot, &here)
            let left = here.record(sweep, spot: spot, channel: .left, seed: seed &* 7919 &+ UInt64(2 * spot))
            let right = here.stereo ? here.record(sweep, spot: spot, channel: .right, seed: seed &* 7919 &+ UInt64(2 * spot + 1)) : nil
            let analysis = SpotAnalyzer.analyze(left: left, right: right, sweep: sweep, noiseFloor: floor, quality: quality)
            results.withLock { $0[spot] = analysis }
        }
        let spots = results.withLock { all in (0..<3).map { all[$0]! } }
        cache.withLock { $0[key] = spots }
        return spots
    }

    /// The mockup's room: a boom at 41 Hz and a missing note at 61 Hz whose strength changes from spot to spot, even
    /// above 100 Hz, the right speaker a touch brighter than the left.
    static let mockupRoom = SimulatedRoom(
        modes: [
            RoomMode(frequency: 41, q: 8, gains: [12, 9.5, 7]),
            RoomMode(frequency: 61, q: 7, gains: [-16.3, -11.1, -13.4]),
        ],
        rightTilt: 1.2
    )

    /// The same room after a move: the missing note mostly back, the boom smaller.
    static let improvedRoom = SimulatedRoom(
        modes: [
            RoomMode(frequency: 41, q: 8, gains: [6.5, 5.5, 4.5]),
            RoomMode(frequency: 61, q: 7, gains: [-5, -4, -4.5]),
        ],
        rightTilt: 1.2
    )

    /// A room with nothing to find: the speakers' own roll-off under 25 Hz and a small reflection.
    static let evenRoom = SimulatedRoom()

    static var mockup: [SpotAnalysis] { spots(mockupRoom, seed: 41, sweep: sweep, key: "mockup") }
    static var improved: [SpotAnalysis] { spots(improvedRoom, seed: 42, key: "improved") }
    static func even(seed: UInt64) -> [SpotAnalysis] { spots(evenRoom, seed: seed, key: "even-\(seed)") }

    /// A room hint whose axial modes sit on 41 Hz (length) and 61 Hz (width).
    static let matchingHint = RoomHint(width: 343.0 / (2 * 61), length: 343.0 / (2 * 41), height: 2.5)
    /// One whose modes are nowhere near 41 or 61 Hz: 47.6, 55.3 and 71.5 Hz and their multiples.
    static let mismatchedHint = RoomHint(width: 3.1, length: 3.6, height: 2.4)
}
