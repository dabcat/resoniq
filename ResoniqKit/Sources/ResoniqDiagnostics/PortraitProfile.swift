import Foundation
import ResoniqDSP

/// The data behind the speaker portrait: a symmetric shape, 20 Hz at the bottom and 20 kHz at the top, whose width
/// at each frequency is the measured level there.
///
/// **From decibels to width.** The level is taken relative to a reference (the median from 300 Hz to 3 kHz), which
/// is drawn at `referenceWidth`; every `dynamicRange` dB below it takes the width to 0, linearly in dB:
/// `width = referenceWidth · (1 + (level − reference) / dynamicRange)`, clamped to 0…1. So an even speaker is an even
/// shape at 0.8, a 6 dB dip is a fifth narrower (0.64: plain to see, nowhere near vanishing), a peak has room up to
/// +7.5 dB, and a bass roll-off of 24 dB narrows the shape to a stem rather than cutting it off.
///
/// **Outside the measured band.** The axis always runs 20 Hz to 20 kHz, but a response is measured only over its
/// trusted band (`RunMeasurement.responseBand`). Between 20 Hz and the band's lower edge, and between its upper edge
/// and 20 kHz, the finished portrait holds the width at that edge: the shape neither invents a roll-off nor a rise
/// it did not hear, and no finding is raised from those held widths. With `LogSweep.measurement` the trusted band
/// covers 20 Hz to 20.8 kHz, so nothing is held.
public struct PortraitProfile: Sendable, Codable, Equatable {
    /// The width of the reference level, as a fraction of the full width.
    public static let referenceWidth: Float = 0.8
    /// Decibels below the reference that take the width to zero.
    public static let dynamicRange: Float = 30

    /// Hertz, rising: `ResponseGrid.frequencies`.
    public let frequencies: [Float]
    /// 0…1 at each frequency; 0 where nothing has been heard yet.
    public let widths: [Float]
    /// The bands to cut out and redraw in the deviation style: the report's suspected defects. Data only; the view
    /// decides how a deviation looks.
    public let deviations: [FrequencyRange]
    /// The frequency the shape is filled up to, hertz: the sweep line while it plays, 20 kHz when finished, nil
    /// before anything was heard.
    public let heardUpTo: Float?

    /// The portrait of a finished response (smoothed, such as `RunMeasurement.response` or a report's consensus),
    /// read at each `ResponseGrid` frequency.
    public init(response: MagnitudeResponse, deviations: [FrequencyRange] = []) {
        self.init(levels: ResponseGrid.frequencies.map(response.decibels(at:)), deviations: deviations)
    }

    /// The portrait of a curve already on `ResponseGrid`.
    init(levels: [Float], deviations: [FrequencyRange]) {
        let reference = RunAnalyzer.referenceLevel(of: levels)
        self.frequencies = ResponseGrid.frequencies
        self.widths = levels.map { Self.width(level: $0, reference: reference) }
        self.deviations = deviations
        self.heardUpTo = ResponseGrid.upperFrequency
    }

    private init(widths: [Float], heardUpTo: Float?) {
        self.frequencies = ResponseGrid.frequencies
        self.widths = widths
        self.deviations = []
        self.heardUpTo = heardUpTo
    }

    /// The "not heard yet" portrait: no width anywhere.
    public static let notHeard = PortraitProfile(widths: [Float](repeating: 0, count: ResponseGrid.count), heardUpTo: nil)

    static func width(level: Float, reference: Float) -> Float {
        min(max(referenceWidth * (1 + (level - reference) / dynamicRange), 0), 1)
    }

    /// The portrait while the sweep plays: the level of the recording at each moment is the level at the frequency
    /// playing at that moment.
    ///
    /// The sweep's frequency `f` reaches the microphone `delay + sweep.time(of: f)` seconds into the recording; its
    /// level there is the RMS over the longer of 20 ms and two periods of `f` around that moment. A frequency counts
    /// as heard once that whole window is in `envelope`. The reference is the median level heard so far above
    /// 100 Hz (the loudest so far before then), so the shape can rescale a little as the sweep rises. It is a
    /// preview: the finished portrait (`init(response:)`) replaces it.
    ///
    /// - Parameter delay: Seconds from the sweep's start to the sound's arrival in the recording; 0 if unknown.
    public static func live(envelope: LevelEnvelope, sweep: LogSweep, delay: Double) -> PortraitProfile {
        let grid = ResponseGrid.frequencies
        let heard = envelope.duration - delay
        guard heard > 0 else { return .notHeard }
        let levels: [Float?] = grid.map { frequency in
            let f = Double(frequency)
            guard f >= sweep.startFrequency, f <= sweep.endFrequency else { return nil }
            let moment = delay + sweep.time(of: f)
            let half = max(0.01, 1 / f)
            guard moment - half >= 0, moment + half <= envelope.duration else { return nil }
            return envelope.level(from: moment - half, to: moment + half)
        }
        let played = zip(grid, levels).compactMap { frequency, level in level.map { (frequency, $0) } }
        guard !played.isEmpty else {
            return PortraitProfile(widths: [Float](repeating: 0, count: grid.count), heardUpTo: Float(sweep.frequency(at: min(heard, sweep.duration))))
        }
        let reference = median(played.filter { $0.0 >= 100 }.map(\.1)) ?? played.map(\.1).max()!
        return PortraitProfile(
            widths: levels.map { $0.map { width(level: $0, reference: reference) } ?? 0 },
            heardUpTo: Float(sweep.frequency(at: min(heard, sweep.duration)))
        )
    }
}

/// The recording's level over time in 5 ms blocks, kept up to date as samples arrive: what the live portrait reads.
/// Appending a block costs one pass over its samples.
public struct LevelEnvelope: Sendable, Equatable {
    /// Seconds per block.
    public static let blockDuration: Double = 0.005

    public let sampleRate: Double
    /// The mean square of each whole block, linear.
    public private(set) var meanSquares: [Float] = []
    private var partialSum: Float = 0
    private var partialCount = 0

    public init(sampleRate: Double) {
        precondition(sampleRate > 0, "sample rate must be positive")
        self.sampleRate = sampleRate
    }

    public init(samples: [Float], sampleRate: Double) {
        self.init(sampleRate: sampleRate)
        append(samples)
    }

    /// Samples per block.
    public var blockLength: Int { max(1, Int((Self.blockDuration * sampleRate).rounded())) }

    /// Seconds covered by whole blocks.
    public var duration: Double { Double(meanSquares.count * blockLength) / sampleRate }

    /// Adds the next samples of the recording.
    public mutating func append(_ samples: [Float]) {
        let length = blockLength
        for sample in samples {
            partialSum += sample * sample
            partialCount += 1
            if partialCount == length {
                meanSquares.append(partialSum / Float(length))
                partialSum = 0
                partialCount = 0
            }
        }
    }

    /// The RMS level, dBFS, of the blocks from `start` to `end` seconds; nil when no whole block lies there.
    public func level(from start: Double, to end: Double) -> Float? {
        let seconds = Double(blockLength) / sampleRate
        let first = max(0, Int((start / seconds).rounded()))
        let last = min(meanSquares.count, Int((end / seconds).rounded()))
        guard last > first else { return nil }
        let mean = meanSquares[first..<last].reduce(0, +) / Float(last - first)
        return Decibels.fromPower(mean)
    }
}
