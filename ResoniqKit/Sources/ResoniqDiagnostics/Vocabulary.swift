import Foundation

/// How a finding is known (design/DESIGN_SYSTEM.md, "Evidence tags").
public enum EvidenceTag: String, Sendable, Codable, CaseIterable {
    /// Read directly from this session's recordings.
    case measured
    /// Concluded from measurements; the finding states its basis ("3 of 3 runs").
    case inferred
    /// Could not be decided; the finding states why ("could be the phone's angle").
    case inconclusive
    /// A rough figure where measurement quality is limited.
    case estimate

    /// The tag's label, as the evidence-tag component shows it.
    public var displayName: String { DiagnosisText.tagName(self) }
}

/// A span of frequencies, in hertz.
public struct FrequencyRange: Sendable, Codable, Hashable {
    public var lower: Float
    public var upper: Float

    public init(lower: Float, upper: Float) {
        precondition(lower > 0 && upper >= lower, "a frequency range must be positive and rising")
        self.lower = lower
        self.upper = upper
    }

    /// The geometric centre, the middle on a log axis.
    public var centre: Float { (lower * upper).squareRoot() }

    /// The width in octaves.
    public var octaves: Float { log2(upper / lower) }

    public func contains(_ frequency: Float) -> Bool { frequency >= lower && frequency <= upper }

    /// Whether the two ranges share a frequency once each is widened by `toleranceOctaves` on both sides.
    public func overlaps(_ other: FrequencyRange, toleranceOctaves: Float = 0) -> Bool {
        let factor = pow(2, toleranceOctaves)
        return lower / factor <= other.upper * factor && other.lower / factor <= upper * factor
    }

    /// The range widened by `octaves` on both sides, kept within 20 Hz to 20 kHz.
    public func widened(octaves: Float) -> FrequencyRange {
        let factor = pow(2, octaves)
        return FrequencyRange(
            lower: max(lower / factor, ResponseGrid.lowerFrequency),
            upper: min(upper * factor, ResponseGrid.upperFrequency)
        )
    }
}

/// Which driver of a speaker a frequency belongs to.
///
/// The limits are the usual crossover regions of a three-way speaker: a woofer up to about 300 Hz, a mid up to about
/// 3 kHz, a tweeter above. Many speakers are two-way, with the woofer playing up to the tweeter; the names then say
/// where in the range something is, not which cone. The same 300 Hz–3 kHz band is the one responses are level
/// matched in (`ResponseComparison.defaultMatchBand`).
public enum DriverBand: String, Sendable, Codable, CaseIterable {
    case woofer
    case middle
    case tweeter

    /// The lowest frequency that belongs to the middle driver, in hertz.
    public static let wooferUpperFrequency: Float = 300
    /// The lowest frequency that belongs to the tweeter, in hertz.
    public static let tweeterLowerFrequency: Float = 3000

    public init(frequency: Float) {
        if frequency < Self.wooferUpperFrequency {
            self = .woofer
        } else if frequency < Self.tweeterLowerFrequency {
            self = .middle
        } else {
            self = .tweeter
        }
    }

    /// The frequencies the driver covers, within 20 Hz to 20 kHz.
    public var range: FrequencyRange {
        switch self {
        case .woofer: FrequencyRange(lower: ResponseGrid.lowerFrequency, upper: Self.wooferUpperFrequency)
        case .middle: FrequencyRange(lower: Self.wooferUpperFrequency, upper: Self.tweeterLowerFrequency)
        case .tweeter: FrequencyRange(lower: Self.tweeterLowerFrequency, upper: ResponseGrid.upperFrequency)
        }
    }

    /// "Woofer", "Middle driver", "Tweeter".
    public var displayName: String { DiagnosisText.bandName(self) }
}

/// The one log-frequency grid every curve in this module is on: responses, distortion, the portrait.
///
/// 241 points from 20 Hz to 20 kHz inclusive, equally spaced in log frequency: 80 a decade, about 24 an octave, so
/// a 1/3-octave feature spans eight points and an edge is placed to about 3 %.
public enum ResponseGrid {
    public static let lowerFrequency: Float = 20
    public static let upperFrequency: Float = 20000
    public static let count = 241

    /// Hertz, rising.
    public static let frequencies: [Float] = (0..<count).map { index in
        Float(Double(lowerFrequency) * pow(1000, Double(index) / Double(count - 1)))
    }

    /// Grid points per octave.
    public static let pointsPerOctave: Float = Float(count - 1) / log2(1000)

    /// The index of the grid point nearest `frequency` in log frequency.
    public static func nearestIndex(to frequency: Float) -> Int {
        let position = log2(max(frequency, lowerFrequency) / lowerFrequency) * pointsPerOctave
        return min(max(Int(position.rounded()), 0), count - 1)
    }
}

func median(_ values: [Float]) -> Float? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}
