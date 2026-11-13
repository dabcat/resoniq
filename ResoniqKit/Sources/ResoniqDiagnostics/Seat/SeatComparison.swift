import Foundation

/// Whether something got better, measured twice.
public enum ComparisonChange: String, Sendable, Codable, CaseIterable {
    case improved, unchanged, worse
}

/// How a move turned out overall.
public enum ComparisonOutcome: String, Sendable, Codable, CaseIterable {
    /// Something targeted got better and nothing got worse.
    case improved
    /// Nothing changed by more than the measurement's repeatability (or the second measurement was incomplete).
    case unchanged
    /// Something got worse and nothing got better.
    case worse
    /// Something got better and something else got worse.
    case mixed
}

/// One row of Before and after: "Missing note, 61 Hz  −11 dB → −4 dB", or "Voices and treble  Unchanged, still even".
public struct ComparisonRow: Sendable, Codable, Equatable {
    public let label: String
    /// "−11 dB"; nil for a row that is described in words (`status`).
    public let before: String?
    public let after: String?
    /// "Unchanged, still even"; nil for a row with values.
    public let status: String?
    public let change: ComparisonChange
    /// The values behind `before` and `after`, dB against each measurement's middle level.
    public let beforeDecibels: Float?
    public let afterDecibels: Float?
    /// The frequency the row is about, hertz; nil for a region.
    public let frequency: Float?
    /// Always `measured`: read from the two measurements.
    public let tag: EvidenceTag

    public init(label: String, before: String?, after: String?, status: String?, change: ComparisonChange,
                beforeDecibels: Float?, afterDecibels: Float?, frequency: Float?, tag: EvidenceTag = .measured) {
        self.label = label
        self.before = before
        self.after = after
        self.status = status
        self.change = change
        self.beforeDecibels = beforeDecibels
        self.afterDecibels = afterDecibels
        self.frequency = frequency
        self.tag = tag
    }
}

/// What changed between two seat measurements made at the same spots.
public struct ComparisonReport: Sendable, Codable, Equatable {
    /// The version of this encoding; bump `currentSchemaVersion` when the stored form changes.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    /// "The missing bass note is back."
    public let verdict: String
    /// Targeted problems first (largest improvement first), then untargeted bass changes, then voices and treble.
    public let rows: [ComparisonRow]
    /// "All measured just now. The 41 Hz boom is still a little strong; the next suggestion targets it."
    public let note: String
    public let outcome: ComparisonOutcome
    /// The strongest extreme left in the second measurement, for the next suggestion; nil when none is left.
    public let nextTarget: SeatExtreme?
    /// Whether both measurements were complete; when not, nothing is compared.
    public let isConclusive: Bool
    /// Always `measured`: "improved" is said only from the second measurement.
    public let tag: EvidenceTag

    public init(schemaVersion: Int = ComparisonReport.currentSchemaVersion, verdict: String, rows: [ComparisonRow], note: String,
                outcome: ComparisonOutcome, nextTarget: SeatExtreme?, isConclusive: Bool, tag: EvidenceTag = .measured) {
        self.schemaVersion = schemaVersion
        self.verdict = verdict
        self.rows = rows
        self.note = note
        self.outcome = outcome
        self.nextTarget = nextTarget
        self.isConclusive = isConclusive
        self.tag = tag
    }
}

/// Compares two seat measurements.
///
/// - **Repeatability.** A change counts only when it is larger than the measurement's repeatability at that
///   frequency: `SeatThresholds.repeatabilityDecibels`, or `repeatabilitySpreadShare` of the two measurements' mean
///   spot-to-spot spread there when that is larger (`repeatability(at:before:after:)`, the one definition). A
///   smaller change is "unchanged", even when it carries a curve across the edge of the even band: 3.2 dB before and
///   2.9 dB after is the same curve measured twice, not "even now".
/// - **Following a bass extreme.** Each targeted extreme, and each bass extreme of the first measurement that was not
///   targeted, is looked for in the second within `samePlaceOctaves` of where it was, as the larger excursion of
///   either sign there (`excursion(in:near:octaves:)`). Its size before is its own. It improved when its magnitude
///   fell by more than the repeatability, and got worse when it grew by more. One that changed sign and now lies
///   outside the even band (a dip that became a peak) is a new problem, `worse`, never a fix.
/// - **New bass extremes** of the second measurement away from every followed one are reported when they grew by
///   more than the repeatability.
/// - **Voices and treble** are compared by the largest excursion of each curve above the bass, where both were
///   assessed (`restComparison`).
/// - **The verdict** is built from the row that decided the outcome, named for what it is (a peak is a booming note,
///   a dip a missing note): an improved bass row says "back" (a dip) or "calmer" (a peak) only when its value now lies
///   inside the even band, and otherwise "less quiet" or "less strong" with the figure left. Targeted rows decide
///   first, then the other bass rows, then voices and treble. With nothing targeted (a room-shape suggestion) the
///   verdict is built the same way from what measurably changed.
/// - **Only the second measurement** can say "improved"; every row is `measured`. An incomplete measurement on
///   either side compares nothing.
public enum SeatComparison {
    /// The line under a comparison of two measurements made on different occasions, in place of `ComparisonReport.note`
    /// (whose "All measured just now." is about a move measured straight after): they are two measurements, not the
    /// before and after of a move, and a change counts only above the measurement's own repeatability.
    public static let occasionsNote =
        "These are two measurements, not a before and after of a move. I only call something a change when it is bigger than the usual difference between two measurements of the same room."

    /// One compared bass extreme, before its row is ordered.
    private struct Followed {
        let row: ComparisonRow
        /// Magnitude before less magnitude after, dB.
        let improvement: Float
        let kind: SeatExtreme.Kind
        /// It changed sign and now lies outside the even band.
        let flipped: Bool
    }

    public static func compare(
        before: SeatReport,
        after: SeatReport,
        targeting targets: [SeatExtreme],
        thresholds: SeatThresholds = .standard
    ) -> ComparisonReport {
        let t = thresholds
        guard before.isConclusive, after.isConclusive, let beforeCurve = before.curve, let afterCurve = after.curve else {
            return ComparisonReport(verdict: SeatText.compareInconclusive, rows: [], note: SeatText.notePrefix,
                                    outcome: .unchanged, nextTarget: nil, isConclusive: false)
        }
        func repeatabilityAt(_ frequency: Float) -> Float {
            repeatability(at: frequency, before: before, after: after, thresholds: t)
        }
        func follow(_ extreme: SeatExtreme) -> Followed {
            let now = excursion(in: afterCurve, near: extreme.frequency, octaves: t.samePlaceOctaves)
            let improvement = abs(extreme.deviation) - abs(now)
            let flipped = now * extreme.deviation < 0 && abs(now) > t.evenBandDecibels
            let limit = repeatabilityAt(extreme.frequency)
            let change: ComparisonChange = flipped ? .worse : (improvement > limit ? .improved : (improvement < -limit ? .worse : .unchanged))
            return Followed(
                row: ComparisonRow(
                    label: SeatText.rowLabel(extreme.kind, frequency: extreme.frequency, depth: extreme.deviation, threshold: t.vanishingDipDecibels),
                    before: SeatText.signedDecibels(extreme.deviation), after: SeatText.signedDecibels(now), status: nil,
                    change: change, beforeDecibels: extreme.deviation, afterDecibels: now, frequency: extreme.frequency
                ),
                improvement: improvement, kind: extreme.kind, flipped: flipped
            )
        }
        func near(_ a: Float, _ b: Float) -> Bool { abs(log2(a / b)) <= t.samePlaceOctaves }

        // Targeted problems, largest improvement first; then the first measurement's other bass extremes.
        let targetRows = targets.map(follow).sorted { $0.improvement > $1.improvement }
        let untargeted = before.placementTargets.filter { old in !targets.contains { near($0.frequency, old.frequency) && $0.kind == old.kind } }
        var otherRows = untargeted.map(follow)
        // New bass extremes, away from everything already followed (a followed one that changed sign is its own row).
        let followed = targets + untargeted
        for new in after.placementTargets where !followed.contains(where: { near($0.frequency, new.frequency) }) {
            let then = SeatCurve.value(beforeCurve, at: new.frequency)
            let worsening = abs(new.deviation) - abs(then)
            guard worsening > repeatabilityAt(new.frequency) else { continue }
            otherRows.append(Followed(
                row: ComparisonRow(
                    label: SeatText.rowLabel(new.kind, frequency: new.frequency, depth: new.deviation, threshold: t.vanishingDipDecibels, new: true),
                    before: SeatText.signedDecibels(then), after: SeatText.signedDecibels(new.deviation), status: nil,
                    change: .worse, beforeDecibels: then, afterDecibels: new.deviation, frequency: new.frequency
                ),
                improvement: -worsening, kind: new.kind, flipped: false
            ))
        }

        // Voices and treble.
        let restRow = restComparison(before: before, after: after, beforeCurve: beforeCurve, afterCurve: afterCurve, thresholds: t)

        let bassRows = targetRows + otherRows
        let rows = bassRows.map(\.row) + [restRow]
        let improved = rows.contains { $0.change == .improved }
        let worse = rows.contains { $0.change == .worse }
        let outcome: ComparisonOutcome = improved ? (worse ? .mixed : .improved) : (worse ? .worse : .unchanged)
        let flip = bassRows.first { $0.flipped }

        let verdict: String
        switch outcome {
        case .improved:
            // Targets first (already ordered by improvement), then the other bass rows by improvement.
            let decisive = targetRows.first { $0.row.change == .improved }
                ?? otherRows.filter { $0.row.change == .improved }.max { $0.improvement < $1.improvement }
            if let decisive, let now = decisive.row.afterDecibels {
                verdict = abs(now) <= t.evenBandDecibels
                    ? SeatText.fixedVerdict(decisive.kind)
                    : SeatText.partlyVerdict(decisive.kind, now: now)
            } else {
                verdict = restRow.status == SeatText.restEvenNow ? SeatText.restEvenVerdict : SeatText.restBetterVerdict
            }
        case .unchanged: verdict = SeatText.unchangedVerdict
        case .worse: verdict = flip.map { SeatText.flippedVerdict($0.kind) } ?? SeatText.worseVerdict
        case .mixed: verdict = SeatText.mixedVerdict
        }

        let remaining = after.extremes.max { abs($0.deviation) < abs($1.deviation) }
        var note = SeatText.notePrefix
        if outcome == .worse, flip == nil {
            note += " " + SeatText.putBack
        } else if let remaining {
            let isNew = flip.map { near($0.row.frequency ?? 0, remaining.frequency) } ?? false
            note += " " + SeatText.remaining(remaining, threshold: t.vanishingDipDecibels, bass: remaining.frequency < t.bassUpperFrequency, new: isNew)
        } else {
            note += " " + SeatText.nothingRemains
        }

        return ComparisonReport(verdict: verdict, rows: rows, note: note, outcome: outcome, nextTarget: remaining, isConclusive: true)
    }

    /// The least change that counts at `frequency`, dB: `repeatabilityDecibels`, or `repeatabilitySpreadShare` of the
    /// mean of the two measurements' spot-to-spot spread there, whichever is larger.
    public static func repeatability(at frequency: Float, before: SeatReport, after: SeatReport, thresholds: SeatThresholds = .standard) -> Float {
        let spreads = [before.spread, after.spread].compactMap { $0 }.map { SeatCurve.value($0, at: frequency) }
        let mean = spreads.isEmpty ? 0 : spreads.reduce(0, +) / Float(spreads.count)
        return max(thresholds.repeatabilityDecibels, thresholds.repeatabilitySpreadShare * mean)
    }

    /// The `steps + 1` values of `curve` read evenly in log frequency within `octaves` of `frequency`.
    private static func window(_ curve: [Float], near frequency: Float, octaves: Float) -> [Float] {
        let steps = 48
        return (0...steps).map { step in
            SeatCurve.value(curve, at: frequency * pow(2, octaves * (2 * Float(step) / Float(steps) - 1)))
        }
    }

    /// The deepest (dip) or highest (peak) value of `curve` within `octaves` of `frequency`, read between grid points.
    static func extreme(in curve: [Float], kind: SeatExtreme.Kind, near frequency: Float, octaves: Float) -> Float {
        let values = window(curve, near: frequency, octaves: octaves)
        return kind == .dip ? values.min()! : values.max()!
    }

    /// The value of `curve` furthest from 0 dB, either sign, within `octaves` of `frequency`: how a followed extreme is
    /// judged, so a dip that turned into a peak there reads as the peak.
    static func excursion(in curve: [Float], near frequency: Float, octaves: Float) -> Float {
        window(curve, near: frequency, octaves: octaves).max { abs($0) < abs($1) }!
    }

    /// Voices and treble, from `bassUpperFrequency` to `upperFrequency`.
    ///
    /// Each measurement's largest excursion there is read from its curve at the points both measurements assessed
    /// (`beforeDecibels`, `afterDecibels`); whether each is even comes from its extremes, as its own report says. The
    /// row improved or got worse only when the largest excursion moved by more than the repeatability at the worse of
    /// the two places; a smaller move is "unchanged", and when it crossed the edge of the even band the status says it
    /// is about the same.
    static func restComparison(before: SeatReport, after: SeatReport, beforeCurve: [Float], afterCurve: [Float], thresholds t: SeatThresholds) -> ComparisonRow {
        let grid = ResponseGrid.frequencies
        let points = grid.indices.filter { index in
            grid[index] >= t.bassUpperFrequency && grid[index] <= t.upperFrequency
                && (before.assessed?[index] ?? true) && (after.assessed?[index] ?? true)
        }
        func worst(_ curve: [Float]) -> (value: Float, frequency: Float) {
            guard let index = points.max(by: { abs(curve[$0]) < abs(curve[$1]) }) else { return (0, t.bassUpperFrequency) }
            return (abs(curve[index]), grid[index])
        }
        let (worstThen, whereThen) = worst(beforeCurve)
        let (worstNow, whereNow) = worst(afterCurve)
        let evenThen = !before.extremes.contains { $0.frequency >= t.bassUpperFrequency }
        let evenNow = !after.extremes.contains { $0.frequency >= t.bassUpperFrequency }
        let limit = max(
            repeatability(at: whereThen, before: before, after: after, thresholds: t),
            repeatability(at: whereNow, before: before, after: after, thresholds: t)
        )
        let improvement = worstThen - worstNow
        func row(_ status: String, _ change: ComparisonChange) -> ComparisonRow {
            ComparisonRow(label: SeatText.restRowLabel, before: nil, after: nil, status: status, change: change,
                          beforeDecibels: worstThen, afterDecibels: worstNow, frequency: nil)
        }
        switch (evenThen, evenNow) {
        case (true, true):
            let moved = points.contains { abs(afterCurve[$0] - beforeCurve[$0]) > t.repeatabilityDecibels }
            return row(moved ? SeatText.restChangedEven : SeatText.restUnchangedEven, .unchanged)
        case (true, false):
            return improvement < -limit ? row(SeatText.restUnevenNow, .worse) : row(SeatText.restAboutSameUneven, .unchanged)
        case (false, true):
            return improvement > limit ? row(SeatText.restEvenNow, .improved) : row(SeatText.restAboutSameEven, .unchanged)
        case (false, false):
            if improvement > limit { return row(SeatText.restBetter, .improved) }
            if improvement < -limit { return row(SeatText.restWorse, .worse) }
            return row(SeatText.restUnchangedUneven, .unchanged)
        }
    }
}
