import Accelerate
import Foundation
import ResoniqDSP

/// A log-mel spectrogram: the input a custom speaker-defect or anomaly model takes alongside `DefectFeatures`.
///
/// Levels follow the DSP's one convention, **dBFS RMS**: a band's level is its share of the frame's mean square, so
/// a sine of amplitude `A` lying inside one band's flat top reads `20·log10(A/√2)` there (a full-scale sine −3.01 dB)
/// and white noise's bands add up to its RMS. Per bin, power is `2|X|² / (N · coherentGain)²` (DC and Nyquist
/// unhalved), as in `SpectrumAnalyzer`; a band sums its bins through its triangular filter and divides by the
/// window's `equivalentNoiseBandwidth`, as `OctaveBands.levels` does. Silence reads `floorDecibels`.
///
/// The mel scale is HTK's, `2595·log10(1 + f/700)`. The bands are triangles with peak 1 between `bandCount + 2`
/// points equally spaced in mel from `lowerFrequency` to `upperFrequency`; neighbours overlap so that from the first
/// band's centre to the last one's the weights add up to exactly 1 at every frequency.
public struct LogMelSpectrogram: Sendable, Codable, Equatable {
    public struct Configuration: Sendable, Codable, Equatable {
        /// Samples per frame; a power of two. Default 2048 (42.7 ms at 48 kHz, 23.4 Hz bins): the shortest power of
        /// two whose bins still put three or more inside the lowest band of the default range.
        public var windowLength: Int
        /// Samples between frame starts. Default 480: 10 ms at 48 kHz, short enough to catch a rattle's tick.
        public var hopLength: Int
        /// Default Hann.
        public var window: Window
        /// Default 64.
        public var bandCount: Int
        /// Hertz. Default 20 Hz to 20 kHz, the report's band.
        public var lowerFrequency: Float
        public var upperFrequency: Float
        /// The mean square that reads 0 dB. Default 1: dBFS RMS.
        public var referencePower: Float
        /// The lowest level written, dB. Default −120 dB, below a 24-bit recording's noise.
        public var floorDecibels: Float

        public init(
            windowLength: Int = 2048,
            hopLength: Int = 480,
            window: Window = .hann,
            bandCount: Int = 64,
            lowerFrequency: Float = 20,
            upperFrequency: Float = 20000,
            referencePower: Float = 1,
            floorDecibels: Float = -120
        ) {
            precondition(windowLength >= 16 && windowLength == FFT.nextPowerOfTwo(windowLength), "the window must be a power of two of at least 16")
            precondition(hopLength > 0 && bandCount > 0 && lowerFrequency > 0 && upperFrequency > lowerFrequency && referencePower > 0)
            self.windowLength = windowLength
            self.hopLength = hopLength
            self.window = window
            self.bandCount = bandCount
            self.lowerFrequency = lowerFrequency
            self.upperFrequency = upperFrequency
            self.referencePower = referencePower
            self.floorDecibels = floorDecibels
        }

        /// The defaults, suited to the app's 48 kHz speaker recordings.
        public static let standard = Configuration()

        /// The number of frames `sampleCount` samples give: none under one window, otherwise
        /// `1 + (sampleCount − windowLength) / hopLength` (no padding; a trailing part shorter than a hop is left out).
        public func frameCount(sampleCount: Int) -> Int {
            sampleCount < windowLength ? 0 : 1 + (sampleCount - windowLength) / hopLength
        }

        enum CodingKeys: String, CodingKey {
            case windowLength, hopLength, window, bandCount, lowerFrequency, upperFrequency, referencePower, floorDecibels
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let name = try container.decode(String.self, forKey: .window)
            guard let window = Window.allCases.first(where: { String(describing: $0) == name }) else {
                throw DecodingError.dataCorruptedError(forKey: .window, in: container, debugDescription: "unknown window \(name)")
            }
            self.init(
                windowLength: try container.decode(Int.self, forKey: .windowLength),
                hopLength: try container.decode(Int.self, forKey: .hopLength),
                window: window,
                bandCount: try container.decode(Int.self, forKey: .bandCount),
                lowerFrequency: try container.decode(Float.self, forKey: .lowerFrequency),
                upperFrequency: try container.decode(Float.self, forKey: .upperFrequency),
                referencePower: try container.decode(Float.self, forKey: .referencePower),
                floorDecibels: try container.decode(Float.self, forKey: .floorDecibels)
            )
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(windowLength, forKey: .windowLength)
            try container.encode(hopLength, forKey: .hopLength)
            try container.encode(String(describing: window), forKey: .window)
            try container.encode(bandCount, forKey: .bandCount)
            try container.encode(lowerFrequency, forKey: .lowerFrequency)
            try container.encode(upperFrequency, forKey: .upperFrequency)
            try container.encode(referencePower, forKey: .referencePower)
            try container.encode(floorDecibels, forKey: .floorDecibels)
        }
    }

    public let configuration: Configuration
    public let sampleRate: Double
    public let frameCount: Int
    public let bandCount: Int
    /// Levels in dB, frame after frame: band `b` of frame `t` is `values[t * bandCount + b]`.
    public let values: [Float]
    /// Each band's centre, hertz.
    public let bandCentres: [Float]

    /// Band `band` of frame `frame`, dB.
    public func level(frame: Int, band: Int) -> Float { values[frame * bandCount + band] }

    /// One frame's bands, dB.
    public func frame(_ index: Int) -> ArraySlice<Float> { values[(index * bandCount)..<((index + 1) * bandCount)] }

    // MARK: Computing

    public static func compute(
        _ samples: [Float],
        sampleRate: Double,
        configuration: Configuration = .standard
    ) -> LogMelSpectrogram {
        let bank = MelFilterBank(configuration: configuration, sampleRate: sampleRate)
        let frames = configuration.frameCount(sampleCount: samples.count)
        let size = configuration.windowLength
        let window = configuration.window.samples(count: size)
        let gain = Float(size) * configuration.window.coherentGain
        let scale = 1 / (gain * gain * configuration.window.equivalentNoiseBandwidth * configuration.referencePower)
        var values = [Float](repeating: configuration.floorDecibels, count: frames * configuration.bandCount)

        for frame in 0..<frames {
            let start = frame * configuration.hopLength
            let segment = vDSP.multiply(samples[start..<(start + size)], window)
            let spectrum = FFT.forward(segment, size: size)
            // One-sided power per bin, divided by the window's gains and the reference.
            var power = vDSP.multiply(scale, vDSP.add(vDSP.square(spectrum.real[0...(size / 2)]), vDSP.square(spectrum.imaginary[0...(size / 2)])))
            vDSP.multiply(2, power, result: &power)
            power[0] /= 2
            power[size / 2] /= 2
            for band in 0..<configuration.bandCount {
                let filter = bank.filters[band]
                guard !filter.weights.isEmpty else { continue }
                let sum = vDSP.dot(power[filter.firstBin..<(filter.firstBin + filter.weights.count)], filter.weights)
                values[frame * configuration.bandCount + band] = max(Decibels.fromPower(sum), configuration.floorDecibels)
            }
        }
        return LogMelSpectrogram(
            configuration: configuration,
            sampleRate: sampleRate,
            frameCount: frames,
            bandCount: configuration.bandCount,
            values: values,
            bandCentres: bank.centres
        )
    }
}

/// The triangular mel filters of a configuration at a sample rate.
struct MelFilterBank: Sendable {
    struct Filter: Sendable {
        /// The first bin with a weight.
        let firstBin: Int
        /// Weights from `firstBin` on, each in (0, 1].
        let weights: [Float]
    }

    let filters: [Filter]
    /// Each band's centre, hertz.
    let centres: [Float]
    /// The `bandCount + 2` edge points, hertz.
    let points: [Float]

    static func mel(_ frequency: Float) -> Float { 2595 * log10(1 + frequency / 700) }
    static func hertz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }

    init(configuration: LogMelSpectrogram.Configuration, sampleRate: Double) {
        let upper = min(configuration.upperFrequency, Float(sampleRate / 2))
        let low = Self.mel(configuration.lowerFrequency)
        let step = (Self.mel(upper) - low) / Float(configuration.bandCount + 1)
        let points = (0...(configuration.bandCount + 1)).map { Self.hertz(low + Float($0) * step) }
        self.points = points
        centres = Array(points[1...configuration.bandCount])
        let size = configuration.windowLength
        let binWidth = Float(sampleRate) / Float(size)
        filters = (0..<configuration.bandCount).map { band in
            let (lower, centre, upper) = (points[band], points[band + 1], points[band + 2])
            var first: Int?
            var weights: [Float] = []
            for bin in 0...(size / 2) {
                let weight = Self.weight(Float(bin) * binWidth, lower: lower, centre: centre, upper: upper)
                if weight > 0 {
                    if first == nil { first = bin }
                    weights.append(weight)
                } else if first != nil {
                    break
                }
            }
            return Filter(firstBin: first ?? 0, weights: weights)
        }
    }

    /// The triangle's weight at `frequency`: 0 outside (lower, upper), 1 at the centre.
    static func weight(_ frequency: Float, lower: Float, centre: Float, upper: Float) -> Float {
        if frequency <= lower || frequency >= upper { return 0 }
        return frequency <= centre ? (frequency - lower) / (centre - lower) : (upper - frequency) / (upper - centre)
    }
}
