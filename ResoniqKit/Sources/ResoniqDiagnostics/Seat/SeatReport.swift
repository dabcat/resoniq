import Foundation

/// The room's size, as far as it is known, in metres; any dimension may be missing. The app fills it from a scan;
/// this module computes the axial modes from it itself, so it does not depend on the room module.
public struct RoomHint: Sendable, Codable, Equatable {
    public var width: Double?
    public var length: Double?
    public var height: Double?

    public init(width: Double?, length: Double?, height: Double?) {
        self.width = width
        self.length = length
        self.height = height
    }
}

/// A peak or dip of the seat curve that leaves the even band.
public struct SeatExtreme: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// Louder than the middle: a booming note.
        case peak
        /// Quieter than the middle: a missing note.
        case dip
    }

    public let kind: Kind
    /// Where the extreme is, hertz, interpolated between grid points (a parabola through the three around it in
    /// log frequency).
    public let frequency: Float
    /// Its size against the seat curve's middle level, dB: positive for a peak, negative for a dip.
    public let deviation: Float
    /// Where it leaves and re-enters the even band.
    public let range: FrequencyRange
    /// The spot-to-spot spread at `frequency`, dB.
    public let spread: Float

    public init(kind: Kind, frequency: Float, deviation: Float, range: FrequencyRange, spread: Float) {
        self.kind = kind
        self.frequency = frequency
        self.deviation = deviation
        self.range = range
        self.spread = spread
    }

    /// "41 Hz +9 dB", as the curve and the plan label it.
    public var label: String { SeatText.extremeLabel(frequency: frequency, deviation: deviation) }
    /// "41 Hz".
    public var frequencyLabel: String { SeatText.frequency(frequency) }
    /// "+9.2 dB", as the numbers table shows it.
    public var valueLabel: String { SeatText.signedDecibelsTenths(deviation) }
}

/// Where a measured problem is, as far as a seat measurement can say.
public enum MeasuredPlace: String, Sendable, Codable, CaseIterable {
    /// At the listening seat: where the spots were measured and averaged. Not an extent.
    case seat
}

/// Why the report says the room, not the speakers, is behind the unevenness.
public enum SeatBasis: String, Sendable, Codable, CaseIterable {
    /// The extremes sit on the room's axial modes, computed from its size.
    case roomSize
    /// The extremes are in the bass, narrow, and change between the spots.
    case spotToSpot
}

/// One thing the seat result says, with how it is known. All text is ready to show.
public struct SeatFinding: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// Peaks and dips in the bass.
        case bass
        /// Whether voices and treble are even (a deviation when they are not); merged with the left/right match
        /// when both are fine, as the mockup shows.
        case rest
        /// How closely left matches right (a deviation when they differ beyond `SeatThresholds.leftRightDecibels`).
        case leftRight
        /// "It's probably the room, not the speakers": always `inferred`, with its `basis`.
        case roomCause
        /// A spot whose recording could not be used.
        case invalidSpot
        /// The phone was not seen to move between spots and the spots sound alike, so the result may rest on one
        /// position: always `inconclusive`.
        case singlePosition
    }

    public var id: String { "\(kind.rawValue)-\(headline)" }
    public let kind: Kind
    public let tag: EvidenceTag
    /// For `roomCause` only.
    public let basis: SeatBasis?
    /// Whether it describes something wrong (drawn with the deviation colour).
    public let isDeviation: Bool
    /// The line in the result: "One bass note booms, one nearly vanishes".
    public let headline: String
    /// The line under it: "Measured", "Measured · within 1.2 dB", "Inferred from room size. Moving speakers should
    /// help."
    public let tagLine: String
    /// A sentence with the numbers, for a closer look: "41 Hz is 9 dB louder than the middle, 61 Hz 11 dB quieter."
    public let detail: String
    /// The largest deviation behind it, dB, for ordering; 0 for a statement that something is fine.
    public let strength: Float

    public init(kind: Kind, tag: EvidenceTag, basis: SeatBasis?, isDeviation: Bool, headline: String, tagLine: String, detail: String, strength: Float) {
        self.kind = kind
        self.tag = tag
        self.basis = basis
        self.isDeviation = isDeviation
        self.headline = headline
        self.tagLine = tagLine
        self.detail = detail
        self.strength = strength
    }
}

/// A row of "The numbers": "41 Hz · +9.2 dB · peak · Measured".
public struct SeatNumberRow: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case peak, dip, leftRight, distortion, decay
    }

    public let kind: Kind
    public let label: String
    public let value: String
    public let word: String
    public let tag: EvidenceTag

    public init(kind: Kind, label: String, value: String, word: String, tag: EvidenceTag) {
        self.kind = kind
        self.label = label
        self.value = value
        self.word = word
        self.tag = tag
    }
}

/// The decay of the bass at the seat: always an estimate.
public struct SeatDecay: Sendable, Codable, Equatable {
    /// The band, hertz (`Decay.bassBand(for:)`: 20 to 80 Hz with the measurement sweep).
    public let lower: Float
    public let upper: Float
    /// RT60, seconds.
    public let seconds: Double

    public init(lower: Float, upper: Float, seconds: Double) {
        self.lower = lower
        self.upper = upper
        self.seconds = seconds
    }
}

/// The checks of one spot's recordings, as kept in a report.
public struct SpotCheck: Sendable, Codable, Equatable {
    public let left: RecordingCheck
    /// Nil for a single speaker.
    public let right: RecordingCheck?

    public init(left: RecordingCheck, right: RecordingCheck?) {
        self.left = left
        self.right = right
    }
}

/// Everything the Measure screens show about the seat.
///
/// Every curve is on `ResponseGrid`, in dB against the seat curve's middle level (0 dB is the median from 200 Hz to
/// 4 kHz of the seat curve, `SeatThresholds.middleBand`), so the left, right and spot curves sit on the same scale
/// and a balance error shows. Outside the stretch every recording measured, a curve holds the value at its edge.
public struct SeatReport: Sendable, Codable, Equatable {
    /// The version of this encoding; bump `currentSchemaVersion` when the stored form changes.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// "From your seat, the bass is uneven. The rest is balanced."
    public let verdict: String
    /// Whether enough spots were valid to conclude anything (`SeatThresholds.requiredSpots`).
    public let isConclusive: Bool
    public let validSpotCount: Int
    public let requiredSpotCount: Int
    /// Every spot measured, in order, valid or not.
    public let spots: [SpotCheck]
    /// The seat curve: the power average over the valid spots of left and right together. Nil before any spot is
    /// valid; present (the running average) while inconclusive.
    public let curve: [Float]?
    /// Each channel power averaged over the valid spots; `rightCurve` nil for a single speaker.
    public let leftCurve: [Float]?
    public let rightCurve: [Float]?
    /// Each spot's curve (its channels power averaged), indexed like `spots`; nil for an invalid spot.
    public let spotCurves: [[Float]?]
    /// The spot-to-spot spread, loudest spot less quietest, dB; nil under two valid spots.
    public let spread: [Float]?
    /// Where the curve is a measurement: inside every recording's measured band, with enough signal over the noise.
    public let assessed: [Bool]?
    /// ±`evenBandDecibels` is "even".
    public let evenBandDecibels: Float
    /// The peaks and dips that leave the even band, rising in frequency; empty while inconclusive.
    public let extremes: [SeatExtreme]
    /// The largest |right − left| above the bass, dB; nil for a single speaker or while inconclusive.
    public let leftRightDifference: Float?
    /// All findings, in display order: invalid spots first, then deviations strongest first, then statements, then
    /// the inferred cause.
    public let findings: [SeatFinding]
    /// The rows of "The numbers".
    public let numbers: [SeatNumberRow]
    /// THD at `SeatThresholds.distortionFrequency`, per cent, where measurable.
    public let distortionPercent: Float?
    /// The bass decay estimate, when the recordings support one.
    public let bassDecay: SeatDecay?
    /// True when the phone was not seen to move between spots and the spots' curves are near-identical
    /// (`SeatThresholds.singlePositionSpreadDecibels`): the result may rest on one position, the verdict says so and
    /// nothing is inferred from how the spots differ. Nil otherwise; optional, so reports stored before it decode.
    public let restsOnOnePosition: Bool?
    /// How the sound was played; nil when the phone played it (and in every report stored before this existed).
    public internal(set) var source: SoundSource? = nil

    /// "Measured from a test sound played on another device."; nil when the phone played the sound.
    public var sourceNote: String? { SeatText.sourceNote(source) }

    public init(
        schemaVersion: Int = SeatReport.currentSchemaVersion,
        verdict: String,
        isConclusive: Bool,
        validSpotCount: Int,
        requiredSpotCount: Int,
        spots: [SpotCheck],
        curve: [Float]?,
        leftCurve: [Float]?,
        rightCurve: [Float]?,
        spotCurves: [[Float]?],
        spread: [Float]?,
        assessed: [Bool]?,
        evenBandDecibels: Float,
        extremes: [SeatExtreme],
        leftRightDifference: Float?,
        findings: [SeatFinding],
        numbers: [SeatNumberRow],
        distortionPercent: Float?,
        bassDecay: SeatDecay?,
        restsOnOnePosition: Bool? = nil
    ) {
        self.restsOnOnePosition = restsOnOnePosition
        for grid in [curve, leftCurve, rightCurve, spread].compactMap({ $0 }) + spotCurves.compactMap({ $0 }) {
            precondition(grid.count == ResponseGrid.count, "curves must be on ResponseGrid")
        }
        self.schemaVersion = schemaVersion
        self.verdict = verdict
        self.isConclusive = isConclusive
        self.validSpotCount = validSpotCount
        self.requiredSpotCount = requiredSpotCount
        self.spots = spots
        self.curve = curve
        self.leftCurve = leftCurve
        self.rightCurve = rightCurve
        self.spotCurves = spotCurves
        self.spread = spread
        self.assessed = assessed
        self.evenBandDecibels = evenBandDecibels
        self.extremes = extremes
        self.leftRightDifference = leftRightDifference
        self.findings = findings
        self.numbers = numbers
        self.distortionPercent = distortionPercent
        self.bassDecay = bassDecay
    }

    /// At most three findings, as the result shows them.
    public var displayedFindings: [SeatFinding] { Array(findings.prefix(3)) }

    /// The extremes a speaker move can fix: those in the bass, for the placement advisor (frequency, deviation, kind).
    ///
    /// **Where they are.** A measured problem has no place in the room of its own: it was measured at the seat (the
    /// spots around it, `SeatSpot.spacing` either side in the audio module, are averaged), so its location is the
    /// seat (`location(of:)`). A plan marks it there; nothing here says how far it extends.
    public var placementTargets: [SeatExtreme] {
        extremes.filter { $0.frequency < SeatThresholds.standard.bassUpperFrequency }
    }

    /// Where `extreme` was measured: always the seat, the only place this report knows.
    public func location(of extreme: SeatExtreme) -> MeasuredPlace { .seat }

    // MARK: What may be drawn

    /// The grid indices a curve of this report may be drawn over: the stretch from the first to the last point that
    /// is both assessed (`assessed`) and inside the band the report judges (`SeatThresholds.lowerFrequency` to
    /// `upperFrequency`, 30 Hz to 10 kHz). Outside it the curves hold values nothing was judged on (the speakers'
    /// roll-off, the microphone's top octave, a held edge), which drawn in the deviation colour would read as a
    /// finding. Nil when nothing was assessed. A report stored without `assessed` is drawn over the judged band.
    public var drawableRange: ClosedRange<Int>? {
        let t = SeatThresholds.standard
        let grid = ResponseGrid.frequencies
        let points = grid.indices.filter { index in
            grid[index] >= t.lowerFrequency && grid[index] <= t.upperFrequency && (assessed?[index] ?? true)
        }
        guard let first = points.first, let last = points.last else { return nil }
        return first...last
    }

    /// `curve` with nil outside `drawableRange`, for a chart that can leave a gap.
    public func drawable(_ curve: [Float]) -> [Float?] {
        guard let range = drawableRange else { return curve.map { _ in nil } }
        return curve.indices.map { range.contains($0) ? curve[$0] : nil }
    }

    /// The seat curve as it may be drawn; nil before any spot is valid.
    public var drawableCurve: [Float?]? { curve.map(drawable) }
    public var drawableLeftCurve: [Float?]? { leftCurve.map(drawable) }
    public var drawableRightCurve: [Float?]? { rightCurve.map(drawable) }
    /// Indexed like `spots`; nil for an invalid spot.
    public var drawableSpotCurves: [[Float?]?] { spotCurves.map { $0.map(drawable) } }

    /// For a chart that draws every grid point: `curve` with each missing point holding the nearest drawn value, so
    /// the line runs flat at the level of the band's edge instead of following what was not judged. All zero when
    /// nothing may be drawn.
    public static func heldAtEdges(_ curve: [Float?]) -> [Float] {
        guard let first = curve.firstIndex(where: { $0 != nil }), let last = curve.lastIndex(where: { $0 != nil }) else {
            return curve.map { _ in 0 }
        }
        var held = [Float](repeating: 0, count: curve.count)
        var previous = curve[first]!
        for index in curve.indices {
            if index < first { held[index] = curve[first]!; continue }
            if index > last { held[index] = curve[last]!; continue }
            if let value = curve[index] { previous = value }
            held[index] = previous
        }
        return held
    }

    /// "1 of 3 in", for the running average.
    public var progress: String { SeatText.progress(valid: validSpotCount, required: requiredSpotCount) }

    /// The note under "The numbers" about the uncalibrated microphone.
    public var footnote: String { SeatText.footnote }

    /// The seat curve's value at `frequency`, interpolated in log frequency; nil when there is no curve.
    public func level(at frequency: Float) -> Float? {
        curve.map { SeatCurve.value($0, at: frequency) }
    }
}
