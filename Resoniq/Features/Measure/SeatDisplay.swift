import Foundation
import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

// The one place that maps the seat report onto component inputs. Mapping only: every number and every sentence
// about the system or the room comes from the Kit. The only things written here are the scales that place a
// measured value on screen (`SeatScale`), the day line's wording, and the few static sentences listed in `SeatWords`.

/// How the seat's curves are laid out. The curves are in decibels against their middle, as the report gives them.
nonisolated enum SeatScale {
    /// Decibels shown above and below the middle, on the home curve and on The numbers' grid (V3Measure, V3MDetail).
    static let decibelsEachWay: Double = 12
    /// Decibels between the labelled grid lines on The numbers (+12, +6, 0, ...).
    static let gridStepDecibels: Double = 6
}

/// Static copy of the Measure result screens that no report provides. Everything else on them is the Kit's.
enum SeatWords {
    /// Measure home with nothing measured yet (no mockup): what measuring from the seat will tell.
    static let emptyHeadline = "Sit where you listen, and I'll tell you how it sounds there."
    static let emptyCurveLabel = "Loudness at your seat. Not measured yet."
    /// Under the empty state when a stored result exists but cannot be read.
    static let unreadable = "I couldn't open a saved result from your seat, so it isn't shown."
    static let measureTitle = "Measure from my seat"
    static let measureAgainTitle = "Measure again from my seat"
    static let showNumbers = "Show the numbers"
    static let watchLive = "Watch the sound live"
    static let curveTitle = "Loudness at your seat"
    /// V3Measure's title above the curve panel on the left; the right side is `SeatDisplay.evenBandLabel`.
    static let numbersTitle = "The numbers"
    static let numbersAdvanced = "Advanced"
    static let numbersBack = "Back"
    static let segmentsLabel = "View"
    /// Legend name of the one trace of a single speaker.
    static let singleSpeaker = "Speaker"
    static let noDistortion = "I couldn't measure distortion in these recordings."
    static let noDecay = "These recordings can't support a decay time, so I'm not giving one."
    static let today = "Today"
    static let yesterday = "Yesterday"
    static let cause = "Opens Optimize"
}

// MARK: - The day line

enum SeatDisplay {
    /// "Tuesday": when the measurement was made, for the line at the top right of Measure home. Today and yesterday
    /// by name, a weekday for the six days before that, otherwise the date ("3 March"). `now`, `calendar` and
    /// `locale` are parameters so the choice can be checked; the app passes the defaults.
    static func day(of date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ...0: return SeatWords.today
        case 1: return SeatWords.yesterday
        case 2...6: return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).weekday(.wide))
        default: return date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).day().month(.wide))
        }
    }

    /// "3 spots at your seat" for a finished measurement, "2 of 3 in" (the report's own words) while it cannot
    /// conclude.
    static func spotsLine(of report: SeatReport) -> String {
        guard report.isConclusive else { return report.progress }
        let count = report.validSpotCount
        return "\(count) \(count == 1 ? "spot" : "spots") at your seat"
    }

    /// "Even band ±3 dB", from the report's own band.
    static func evenBandLabel(_ decibels: Float) -> String {
        let whole = decibels.rounded() == decibels
        return "Even band \u{00B1}\(whole ? String(Int(decibels)) : String(format: "%.1f", decibels)) dB"
    }

    /// What VoiceOver should say for a written figure: "−11.4 dB" is "minus 11.4 decibels", "≈ 0.7 s" "about 0.7 s".
    static func spoken(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{2212}", with: "minus ")
            .replacingOccurrences(of: "\u{00B1}", with: "plus or minus ")
            .replacingOccurrences(of: "\u{2248} ", with: "about ")
            .replacingOccurrences(of: "< ", with: "below ")
            .replacingOccurrences(of: " dB", with: " decibels")
            .replacingOccurrences(of: " %", with: " percent")
    }

    /// "Peak, 41 Hz plus 9 decibels".
    static func spokenExtreme(_ extreme: SeatExtreme) -> String {
        "\(extreme.kind.rawValue.capitalized), \(spoken(extreme.label))"
    }

    /// Ends a sentence the Kit may or may not have ended.
    static func sentence(_ text: String) -> String {
        text.hasSuffix(".") || text.hasSuffix("?") || text.hasSuffix("!") ? text : text + "."
    }
}

// MARK: - From the report

/// What The numbers' control chooses between.
nonisolated enum NumbersSegment: String, CaseIterable, Hashable {
    case response, distortion, decay

    var title: String {
        switch self {
        case .response: "Response"
        case .distortion: "Distortion"
        case .decay: "Decay"
        }
    }
}

extension SeatReport {
    /// The seat curve for `ResponseCurve`; nil before any spot is valid.
    var curveLevels: [Double]? { curve.map(Self.levels) }

    /// The left trace for `ChannelComparisonChart` (the one speaker's trace for a single speaker); nil before any
    /// spot is valid.
    var leftLevels: [Double]? { leftCurve.map(Self.levels) }

    /// The right trace; nil for a single speaker.
    var rightLevels: [Double]? { rightCurve.map(Self.levels) }

    private static func levels(_ curve: [Float]) -> [Double] { curve.map(Double.init) }

    /// Whether the system has one speaker, so there is no left and right to compare.
    var isSingleSpeaker: Bool { rightCurve == nil }

    /// The labelled dots on the seat curve, with the report's own labels ("41 Hz +9 dB").
    var curveExtremes: [ResponseCurve.Extreme] {
        extremes.map { ResponseCurve.Extreme(frequency: Double($0.frequency), level: Double($0.deviation), label: $0.label) }
    }

    /// One sentence for VoiceOver that states the finding: the verdict, then each extreme.
    var curveAccessibilityLabel: String {
        let spokenExtremes = extremes.map { "\(SeatDisplay.spokenExtreme($0))." }
        return ([SeatDisplay.sentence(verdict)] + spokenExtremes).joined(separator: " ")
    }

    /// The same for the left and right chart: the verdict, then how far apart the channels are.
    var channelsAccessibilityLabel: String {
        let apart = findings.first { $0.kind == .leftRight }
        return [SeatDisplay.sentence(verdict), apart.map { SeatDisplay.sentence($0.headline) }]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// What the chart's caption says about smoothing. The report does not carry a caption, so it is written from
    /// the Kit's own smoothing figures (`SeatThresholds.standard`): the bass is smoothed more finely than the rest.
    var smoothingCaption: String {
        let thresholds = SeatThresholds.standard
        return "1/\(thresholds.bassSmoothingFraction)-octave bass, 1/\(thresholds.smoothingFraction)-octave above"
    }

    /// The finding that leads to Optimize.
    var causeFinding: SeatFinding? { displayedFindings.first { $0.kind == .roomCause } }

    /// The table rows of one segment, in the report's order.
    ///
    /// The report's `numbers` are one list. Nothing in it says which of The numbers' views a row belongs to, so they
    /// are grouped here by the row's kind (a Kit field): peaks, dips and left against right are the response, the
    /// distortion row is distortion, the decay row is decay.
    func tableRows(for segment: NumbersSegment) -> [ResoniqValuesTable.Row] {
        numbers.filter { $0.segment == segment }.map(tableRow)
    }

    private func tableRow(_ row: SeatNumberRow) -> ResoniqValuesTable.Row {
        let differs = row.kind == .leftRight && findings.contains { $0.kind == .leftRight && $0.isDeviation }
        return ResoniqValuesTable.Row(
            row.label, value: row.value, word: row.word, evidence: ResoniqEvidenceKind(row.tag),
            isDeviation: row.kind == .peak || row.kind == .dip || differs,
            spokenLabel: row.kind == .leftRight ? "Left against right" : SeatDisplay.spoken(row.label),
            spokenValue: SeatDisplay.spoken(row.value)
        )
    }
}

extension SeatNumberRow {
    /// Which of The numbers' views shows this row.
    var segment: NumbersSegment {
        switch kind {
        case .peak, .dip, .leftRight: .response
        case .distortion: .distortion
        case .decay: .decay
        }
    }
}

extension SeatFinding {
    var evidenceKind: ResoniqEvidenceKind { ResoniqEvidenceKind(tag) }

    /// Headline, then how it is known, then the sentence with the numbers: what VoiceOver reads for a row.
    var spokenSummary: String {
        [SeatDisplay.sentence(headline), SeatDisplay.sentence(tagLine), detail].joined(separator: " ")
    }
}

// MARK: - What Measure home shows

/// A kept measurement as Measure home shows it: the report and the words that frame it.
struct MeasureSummary {
    let report: SeatReport
    let date: Date
    /// "Tuesday".
    let day: String
    /// "3 spots at your seat", or "2 of 3 in".
    let spots: String

    init(report: SeatReport, date: Date, now: Date = .now) {
        self.report = report
        self.date = date
        self.day = SeatDisplay.day(of: date, now: now)
        self.spots = SeatDisplay.spotsLine(of: report)
    }

    /// One VoiceOver phrase for the two lines at the top right: "Tuesday, 3 spots at your seat".
    var dayAccessibilityLabel: String { "\(day), \(spots)" }
}
