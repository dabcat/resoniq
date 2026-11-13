import Foundation

/// Where a model's say comes from and how sure it was, in storable form.
public struct ModelEvidence: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable {
        case soundClassifier, defectClassifier, anomalyCheck
    }

    public let source: Source
    /// The class the model gave, for a classifier ("buzzing"); nil for the anomaly check.
    public let defectClass: DefectClass?
    /// The model's confidence, 0 to 1, for a classifier; for the anomaly check, the error as a multiple of a
    /// healthy recording's (`AnomalyScore.ratio`).
    public let value: Float
    /// "defect classifier, 74 %", "anomaly check, 3.1 × usual".
    public let basis: String
    /// The line it adds: "A defect classifier also heard a buzz (74 %)."
    public let statement: String
}

/// A line a model added to a speaker report. Always `inferred` with low confidence, never a deviation, never in the
/// verdict: "DSP first, AI second".
public struct ModelFinding: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case defect, anomaly
    }

    /// "model-defect-mechanicalRattling", "model-anomaly".
    public let id: String
    public let kind: Kind
    public let evidence: ModelEvidence
    /// "Possible rattle".
    public let headline: String
    /// "A defect classifier heard something like a rattle. It's a hint, not a measurement."
    public let detail: String
    /// "I may have heard a rattle."
    public let sentence: String
    /// "Inferred · defect classifier, 74 %".
    public let tagLine: String

    public var tag: EvidenceTag { .inferred }
    public var confidence: Finding.Confidence { .low }
}

/// The confidences below which a model says nothing.
public struct ModelAdviceThresholds: Sendable, Equatable {
    /// A defect class below this confidence is not mentioned. **First guess**: 0.7, above any second class of a
    /// classifier whose probabilities add up to 1, so at most one class can speak.
    public var minimumDefectConfidence: Float
    /// An anomaly ratio (`AnomalyScore.ratio`) below this is not mentioned. **First guess**: 3, three times the error
    /// a healthy recording typically gives.
    public var minimumAnomalyRatio: Float

    public init(minimumDefectConfidence: Float, minimumAnomalyRatio: Float) {
        self.minimumDefectConfidence = minimumDefectConfidence
        self.minimumAnomalyRatio = minimumAnomalyRatio
    }

    public static let standard = ModelAdviceThresholds(minimumDefectConfidence: 0.7, minimumAnomalyRatio: 3)
}

/// Joins a model's output to a report under the plan's rules ("DSP first, AI second"):
///
/// - A report that is not conclusive gets nothing: there is no measurement for a model to add to.
/// - The verdict, every `measured` and `inconclusive` finding, and every finding's tag, basis and confidence stay as
///   the DSP made them. A model never removes or contradicts a finding.
/// - Below `minimumDefectConfidence` nothing is said; when the most confident class is `normal`, nothing at all.
/// - Otherwise only the most confident class speaks: when the report already has an `inferred` finding of the kind
///   it supports (a buzz: `distortion`), that finding gains `modelSupport`; otherwise one `ModelFinding` is added
///   (an earlier defect line from a model is replaced, never doubled).
/// - Every line states its basis: "defect classifier, 74 %".
/// - The anomaly check adds a low-confidence "something unusual" line only at or above `minimumAnomalyRatio`, and
///   like every model line it is never a verdict and never a deviation.
public enum ModelAdvice {
    public static func join(
        _ predictions: [DefectPrediction],
        to report: SpeakerReport,
        thresholds: ModelAdviceThresholds = .standard
    ) -> SpeakerReport {
        guard report.isConclusive,
              let top = predictions.max(by: { $0.confidence < $1.confidence }),
              top.defectClass != .normal,
              top.confidence >= thresholds.minimumDefectConfidence
        else { return report }

        let evidence = ModelEvidence(
            source: .defectClassifier,
            defectClass: top.defectClass,
            value: top.confidence,
            basis: ModelText.defectClassifierBasis(top.confidence),
            statement: ModelText.defectSupport(top.defectClass, confidence: top.confidence)
        )
        var joined = report
        if let kind = top.defectClass.supportedKind,
           let index = report.findings.firstIndex(where: { $0.kind == kind && $0.tag == .inferred }) {
            var findings = report.findings
            findings[index].modelSupport = evidence
            joined = joined.replacingFindings(findings)
            return joined
        }
        let finding = ModelFinding(
            id: "model-defect-\(top.defectClass.rawValue)",
            kind: .defect,
            evidence: evidence,
            headline: ModelText.defectHeadline(top.defectClass),
            detail: ModelText.defectDetail(top.defectClass),
            sentence: ModelText.defectSentence(top.defectClass),
            tagLine: ModelText.tagLine(evidence.basis)
        )
        joined.modelFindings = (report.modelFindings ?? []).filter { $0.kind != .defect } + [finding]
        return joined
    }

    public static func join(
        anomaly: AnomalyScore,
        to report: SpeakerReport,
        thresholds: ModelAdviceThresholds = .standard
    ) -> SpeakerReport {
        let ratio = anomaly.ratio
        guard report.isConclusive, ratio.isFinite, ratio >= thresholds.minimumAnomalyRatio else { return report }
        let basis = ModelText.anomalyBasis(ratio)
        let finding = ModelFinding(
            id: "model-anomaly",
            kind: .anomaly,
            evidence: ModelEvidence(source: .anomalyCheck, defectClass: nil, value: ratio, basis: basis, statement: ModelText.anomalySentence),
            headline: ModelText.anomalyHeadline,
            detail: ModelText.anomalyDetail,
            sentence: ModelText.anomalySentence,
            tagLine: ModelText.tagLine(basis)
        )
        var joined = report
        joined.modelFindings = (report.modelFindings ?? []).filter { $0.kind != .anomaly } + [finding]
        return joined
    }
}

extension SpeakerReport {
    func replacingFindings(_ findings: [Finding]) -> SpeakerReport {
        var report = SpeakerReport(
            verdict: verdict,
            findings: findings,
            profile: profile,
            runs: runs,
            consensusResponse: consensusResponse,
            isConclusive: isConclusive
        )
        report.modelFindings = modelFindings
        return report
    }
}
