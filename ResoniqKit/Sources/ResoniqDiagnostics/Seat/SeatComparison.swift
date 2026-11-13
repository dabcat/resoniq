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
///   smaller change is "unchanged".
/// - **Targets.** Each targeted extreme is looked for in the second measurement within `samePlaceOctaves` of where
///   it was, in its own direction (the deepest point for a dip, the highest for a peak); its size before is the
///   target's own.
/// - **What was not targeted** is reported too: bass extremes of the first measurement that were not targeted, any
///   new bass extreme in the second, and voices and treble, so a move that made something else worse is never hidden.
/// - **Only the second measurement** can say "improved"; every row is `measured`. An incomplete measurement on
///   either side compares nothing.
public enum SeatComparison {
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
        func judge(_ improvement: Float, at frequency: Float) -> ComparisonChange {
            let limit = repeatabilityAt(frequency)
            return improvement > limit ? .improved : (improvement < -limit ? .worse : .unchanged)
        }

        // Targeted problems.
        var targetRows: [(row: ComparisonRow, improvement: Float, kind: SeatExtreme.Kind)] = []
        for target in targets {
            let now = extreme(in: afterCurve, kind: target.kind, near: target.frequency, octaves: t.samePlaceOctaves)
            let improvement = target.kind == .dip ? now - target.deviation : target.deviation - now
            targetRows.append((
                ComparisonRow(
                    label: SeatText.rowLabel(target.kind, frequency: target.frequency, depth: target.deviation, threshold: t.vanishingDipDecibels),
                    before: SeatText.signedDecibels(target.deviation), after: SeatText.signedDecibels(now), status: nil,
                    change: judge(improvement, at: target.frequency), beforeDecibels: target.deviation, afterDecibels: now,
                    frequency: target.frequency
                ),
                improvement, target.kind
            ))
        }
        targetRows.sort { $0.improvement > $1.improvement }

        // Untargeted bass: the first measurement's other bass extremes, and new ones in the second.
        func near(_ a: Float, _ b: Float) -> Bool { abs(log2(a / b)) <= t.samePlaceOctaves }
        var otherRows: [ComparisonRow] = []
        for old in before.placementTargets where !targets.contains(where: { near($0.frequency, old.frequency) && $0.kind == old.kind }) {
            let now = extreme(in: afterCurve, kind: old.kind, near: old.frequency, octaves: t.samePlaceOctaves)
            let improvement = old.kind == .dip ? now - old.deviation : old.deviation - now
            otherRows.append(ComparisonRow(
                label: SeatText.rowLabel(old.kind, frequency: old.frequency, depth: old.deviation, threshold: t.vanishingDipDecibels),
                before: SeatText.signedDecibels(old.deviation), after: SeatText.signedDecibels(now), status: nil,
                change: judge(improvement, at: old.frequency), beforeDecibels: old.deviation, afterDecibels: now, frequency: old.frequency
            ))
        }
        for new in after.placementTargets where !before.placementTargets.contains(where: { near($0.frequency, new.frequency) && $0.kind == new.kind }) {
            let then = SeatCurve.value(beforeCurve, at: new.frequency)
            let worsening = abs(new.deviation) - abs(then)
            guard judge(-worsening, at: new.frequency) == .worse else { continue }
            otherRows.append(ComparisonRow(
                label: SeatText.rowLabel(new.kind, frequency: new.frequency, depth: new.deviation, threshold: t.vanishingDipDecibels, new: true),
                before: SeatText.signedDecibels(then), after: SeatText.signedDecibels(new.deviation), status: nil,
                change: .worse, beforeDecibels: then, afterDecibels: new.deviation, frequency: new.frequency
            ))
        }

        // Voices and treble.
        let restRow = restComparison(before: before, after: after, beforeCurve: beforeCurve, afterCurve: afterCurve, thresholds: t)

        let rows = targetRows.map(\.row) + otherRows + [restRow]
        let improved = rows.contains { $0.change == .improved }
        let worse = rows.contains { $0.change == .worse }
        let outcome: ComparisonOutcome = improved ? (worse ? .mixed : .improved) : (worse ? .worse : .unchanged)

        let verdict: String
        switch outcome {
        case .improved:
            if let best = targetRows.first(where: { $0.row.change == .improved }) {
                let fixed = abs(best.row.afterDecibels ?? 0) < t.vanishingDipDecibels
                verdict = fixed ? SeatText.fixedVerdict(best.kind) : SeatText.partlyVerdict(best.kind)
            } else {
                verdict = SeatText.partlyVerdict(.dip)
            }
        case .unchanged: verdict = SeatText.unchangedVerdict
        case .worse: verdict = SeatText.worseVerdict
        case .mixed: verdict = SeatText.mixedVerdict
        }

        let remaining = after.extremes.max { abs($0.deviation) < abs($1.deviation) }
        var note = SeatText.notePrefix
        if outcome == .worse {
            note += " " + SeatText.putBack
        } else if let remaining {
            note += " " + SeatText.remaining(remaining, threshold: t.vanishingDipDecibels, bass: remaining.frequency < t.bassUpperFrequency)
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

    /// The deepest (dip) or highest (peak) value of `curve` within `octaves` of `frequency`, read between grid points.
    static func extreme(in curve: [Float], kind: SeatExtreme.Kind, near frequency: Float, octaves: Float) -> Float {
        let steps = 48
        let values = (0...steps).map { step in
            SeatCurve.value(curve, at: frequency * pow(2, octaves * (2 * Float(step) / Float(steps) - 1)))
        }
        return kind == .dip ? values.min()! : values.max()!
    }

    /// Voices and treble: even before and after, or how far the largest excursion beyond the even band changed.
    static func restComparison(before: SeatReport, after: SeatReport, beforeCurve: [Float], afterCurve: [Float], thresholds t: SeatThresholds) -> ComparisonRow {
        let rest = { (extremes: [SeatExtreme]) in extremes.filter { $0.frequency >= t.bassUpperFrequency } }
        let then = rest(before.extremes)
        let now = rest(after.extremes)
        let worstThen = then.map { abs($0.deviation) }.max() ?? 0
        let worstNow = now.map { abs($0.deviation) }.max() ?? 0
        let label = SeatText.restRowLabel
        func row(_ status: String, _ change: ComparisonChange) -> ComparisonRow {
            ComparisonRow(label: label, before: nil, after: nil, status: status, change: change,
                          beforeDecibels: worstThen, afterDecibels: worstNow, frequency: nil)
        }
        switch (then.isEmpty, now.isEmpty) {
        case (true, true):
            let points = ResponseGrid.frequencies.indices.filter {
                ResponseGrid.frequencies[$0] >= t.bassUpperFrequency && ResponseGrid.frequencies[$0] <= t.upperFrequency
            }
            let moved = points.contains { abs(afterCurve[$0] - beforeCurve[$0]) > t.repeatabilityDecibels }
            return row(moved ? SeatText.restChangedEven : SeatText.restUnchangedEven, .unchanged)
        case (true, false): return row(SeatText.restUnevenNow, .worse)
        case (false, true): return row(SeatText.restEvenNow, .improved)
        case (false, false):
            let improvement = worstThen - worstNow
            if improvement > t.repeatabilityDecibels { return row(SeatText.restBetter, .improved) }
            if improvement < -t.repeatabilityDecibels { return row(SeatText.restWorse, .worse) }
            return row(SeatText.restUnchangedUneven, .unchanged)
        }
    }
}
