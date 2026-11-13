import Accelerate

/// Follows a test sound file as it is heard, block by block, cheaply enough to run on every block: says when the
/// clock tone and each sweep start and end, and which frequency of a sweep is arriving now. It only triggers and
/// shows progress; the positions a measurement is cut at come from `SweepFinder.find`, which is exact.
///
/// **Method.** One Hann-windowed transform per block. A block whose strongest frequency (in
/// `SweepFinder.detectionBand` widened to 16 kHz) stands `minimumProminence` over the median of the octave either
/// side of it is a candidate, and its frequency says when the sweep would have started (`LogSweep.time(of:)` back
/// from the block's centre). A sweep has started when `confirmingBlocks` of the last `confirmingBlocks + 2`
/// candidates agree on that start within `startTolerance`: a sweep's frequency rises by the same factor every block
/// (21 % per 100 ms for the measurement sweep) for seconds, which a held note, speech or noise does not do, and a
/// gliding note does only briefly. It has ended once its last sample has arrived plus one block. The clock tone is
/// a block whose strongest frequency is within `toneTolerance` of `SweepFinder.clockToneFrequency`, held for at
/// least `toneBlocks` blocks.
///
/// Blocks must be contiguous; after a gap, `reset()`.
public struct SweepFollower: Sendable {
    /// Something heard. Positions are on the timeline of the blocks fed.
    public enum Event: Sendable, Equatable {
        /// The clock tone has been heard for `toneBlocks` blocks; `start` is its first block's position.
        case toneStarted(start: Int64)
        /// The clock tone stopped: it was heard from `start` to `end`.
        case toneEnded(start: Int64, end: Int64)
        /// A sweep is arriving; `start` is where its first sample arrived, estimated to within `startTolerance`.
        case sweepStarted(start: Int64)
        /// The sweep that started at `start` has arrived whole, one block ago.
        case sweepEnded(start: Int64)
    }

    /// How far a block's strongest frequency must stand over the median of the octave either side, dB. *First guess*.
    public static let minimumProminence: Float = 15
    /// How far the clock tone must stand over it, dB: a tone puts all its power in one bin. *First guess*.
    public static let toneProminence: Float = 25
    /// Agreeing candidates that make a sweep. 8 of 10 blocks: 0.8 s of a 4 s sweep, longer than a gliding note.
    public static let confirmingBlocks = 8
    /// How closely the candidates' starts must agree, seconds: the frequency of a block's strongest bin is good to a
    /// few per cent, which is a few tens of milliseconds of the sweep.
    public static let startTolerance: Double = 0.06
    /// How close to the clock tone's frequency a block's strongest frequency must be, as a fraction: 0.5 %, room for
    /// `SweepFinder.maximumClockOffset` and the bin's resolution.
    public static let toneTolerance: Double = 0.005
    /// Blocks of tone that make the clock tone. 5: half a second, where a sweep passes 1 kHz in one block.
    public static let toneBlocks = 5
    /// The top of the band searched, hertz.
    public static let topFrequency: Double = 16000

    public let sweep: LogSweep
    /// The frequency of the sweep arriving at the latest block's centre; nil when no sweep is arriving.
    public private(set) var heardFrequency: Double?
    /// How far through the sweep the arriving sound is, 0 to 1; nil when `heardFrequency` is.
    public private(set) var sweepFraction: Double?
    /// Where the sweep being heard started; nil when none is.
    public private(set) var activeSweepStart: Int64?
    /// Whether the clock tone is being heard.
    public var isHearingTone: Bool { toneStart != nil && toneRun >= Self.toneBlocks }

    private var candidates: [Double?] = []
    private var lastSweepStart: Int64?
    private var toneStart: Int64?
    private var toneRun = 0
    private var toneEnd: Int64 = 0

    public init(sweep: LogSweep) {
        self.sweep = sweep
    }

    /// Forgets everything heard: after a gap in the blocks, or to listen afresh.
    public mutating func reset() {
        self = SweepFollower(sweep: sweep)
    }

    /// Takes the next block, which starts at `position`; returns what it made happen, in order.
    public mutating func feed(_ samples: [Float], at position: Int64) -> [Event] {
        guard samples.count >= 64 else { return [] }
        var events: [Event] = []
        let sampleRate = sweep.sampleRate
        let centre = Double(position) + Double(samples.count) / 2
        let end = position + Int64(samples.count)
        let peak = Self.strongest(samples, sampleRate: sampleRate)

        // The clock tone.
        let isTone = peak.map {
            $0.prominence >= Self.toneProminence && abs($0.frequency / SweepFinder.clockToneFrequency - 1) <= Self.toneTolerance
        } ?? false
        if isTone {
            if toneStart == nil { toneStart = position; toneRun = 0 }
            toneRun += 1
            toneEnd = end
            if toneRun == Self.toneBlocks, let toneStart { events.append(.toneStarted(start: toneStart)) }
        } else if let start = toneStart {
            if toneRun >= Self.toneBlocks { events.append(.toneEnded(start: start, end: toneEnd)) }
            toneStart = nil
            toneRun = 0
        }

        // The sweep: each candidate block says when its sweep would have started.
        var implied: Double?
        if let peak, !isTone, peak.prominence >= Self.minimumProminence,
           peak.frequency > sweep.startFrequency, peak.frequency < sweep.endFrequency {
            implied = centre - sweep.time(of: peak.frequency) * sampleRate
        }
        candidates.append(implied)
        if candidates.count > Self.confirmingBlocks + 2 { candidates.removeFirst() }

        let length = Double(sweep.sampleCount)
        if activeSweepStart == nil {
            let starts = candidates.compactMap { $0 }
            if starts.count >= Self.confirmingBlocks {
                let middle = Self.median(starts)
                let agreeing = starts.filter { abs($0 - middle) <= Self.startTolerance * sampleRate }
                let isNew = lastSweepStart.map { abs(Double($0) - middle) > length / 2 } ?? true
                if agreeing.count >= Self.confirmingBlocks, isNew, middle + length > centre {
                    let start = Int64(Self.median(agreeing).rounded())
                    activeSweepStart = start
                    events.append(.sweepStarted(start: start))
                }
            }
        }
        if let start = activeSweepStart {
            let heard = centre - Double(start)
            if heard >= 0, heard <= length {
                heardFrequency = sweep.frequency(at: heard / sampleRate)
                sweepFraction = heard / length
            } else {
                heardFrequency = nil
                sweepFraction = nil
            }
            // Whole, and one block more for the route's delay estimate to be off.
            if Double(position) >= Double(start) + length {
                events.append(.sweepEnded(start: start))
                lastSweepStart = start
                activeSweepStart = nil
                heardFrequency = nil
                sweepFraction = nil
                candidates.removeAll()
            }
        }
        return events
    }

    /// The strongest frequency of a Hann-windowed block in 150 Hz to `topFrequency`, refined between bins, and how
    /// far it stands over the median power of the octave either side of it (leaving out a quarter of an octave around
    /// it), dB; nil for silence.
    static func strongest(_ samples: [Float], sampleRate: Double) -> (frequency: Double, prominence: Float)? {
        let size = FFT.nextPowerOfTwo(samples.count)
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: samples.count, isHalfWindow: false)
        let spectrum = FFT.Plan(size: size, inverse: false).forward(vDSP.multiply(samples, window))
        let power = vDSP.add(vDSP.square(spectrum.real), vDSP.square(spectrum.imaginary))
        let low = max(1, FFT.bin(nearest: SweepFinder.detectionBand.lowerBound, size: size, sampleRate: sampleRate))
        let high = min(size / 2 - 1, FFT.bin(nearest: min(topFrequency, sampleRate / 2), size: size, sampleRate: sampleRate))
        guard low < high else { return nil }
        let band = Array(power[low...high])
        let (index, value) = vDSP.indexOfMaximum(band)
        let bin = low + Int(index)
        let lower = max(1, bin / 2)
        let upper = min(size / 2 - 1, bin * 2)
        let near = max(1, bin / 8)
        let around = Array(power[lower..<max(lower, bin - near)]) + Array(power[min(upper + 1, bin + near + 1)..<(upper + 1)])
        let median = Statistics.median(around)
        guard value > 0, median.isFinite, bin > 0, bin + 1 < power.count else { return nil }
        // A parabola through the log powers of the peak and its neighbours.
        let before = log(Double(max(power[bin - 1], .leastNormalMagnitude)))
        let middle = log(Double(value))
        let after = log(Double(max(power[bin + 1], .leastNormalMagnitude)))
        let curvature = before - 2 * middle + after
        let fraction = curvature < 0 ? 0.5 * (before - after) / curvature : 0
        let frequency = (Double(bin) + fraction) * sampleRate / Double(size)
        return (frequency, median > 0 ? Decibels.fromPower(value / median) : .infinity)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
