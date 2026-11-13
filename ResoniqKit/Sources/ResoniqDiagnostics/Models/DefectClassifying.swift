import Foundation

/// What a speaker-defect classifier can say, exactly as the product spec lists it (§3.4).
public enum DefectClass: String, Sendable, Codable, CaseIterable {
    case normal
    case mechanicalRattling
    case voiceCoilRubbing
    case buzzing
    case crackling
    case potentialDriverMalfunction
    case environmentalInterference
    case unknownAnomaly

    /// The finding kind a prediction of this class supports, when the DSP has one: only a buzz, which the sweep's
    /// harmonic distortion measures. Rattle, rub and crackle are not measured from a sweep (`RunAnalyzer`).
    var supportedKind: Finding.Kind? {
        switch self {
        case .buzzing: .distortion
        case .normal, .mechanicalRattling, .voiceCoilRubbing, .crackling, .potentialDriverMalfunction,
             .environmentalInterference, .unknownAnomaly: nil
        }
    }
}

/// One class a defect classifier gave, with its confidence.
public struct DefectPrediction: Sendable, Codable, Equatable {
    public let defectClass: DefectClass
    /// 0 to 1.
    public let confidence: Float

    public init(defectClass: DefectClass, confidence: Float) {
        self.defectClass = defectClass
        self.confidence = min(max(confidence, 0), 1)
    }
}

/// A speaker-defect classifier: the DSP's numbers and a spectrogram in, classes with confidences out.
///
/// The app's implementation is `CoreMLDefectClassifier`, which needs a trained model; none ships, because no
/// dataset of defective loudspeakers exists (see `docs/research/2026-11-13-defect-dataset-plan.md`). What a
/// prediction may do to a report is decided by `ModelAdvice.join`.
public protocol DefectClassifying: Sendable {
    /// Every class the model gives, most confident first.
    func classify(features: DefectFeatures, spectrogram: LogMelSpectrogram) async throws -> [DefectPrediction]
}

/// How far a recording stands from healthy ones, as an anomaly model measures it.
public struct AnomalyScore: Sendable, Codable, Equatable {
    /// The model's reconstruction error for this recording's spectrogram (any unit, as long as both are in it).
    public let reconstructionError: Float
    /// The error the model typically makes on healthy recordings, in the same unit (for example the median over its
    /// healthy validation set).
    public let typicalHealthyError: Float

    public init(reconstructionError: Float, typicalHealthyError: Float) {
        self.reconstructionError = reconstructionError
        self.typicalHealthyError = typicalHealthyError
    }

    /// The error as a multiple of the healthy one; 0 when the healthy error is not positive.
    public var ratio: Float { typicalHealthyError > 0 ? reconstructionError / typicalHealthyError : 0 }
}

/// An anomaly model: trained on healthy speakers only, it reconstructs a spectrogram and reports how badly it
/// managed. No implementation ships (no model exists); `ModelAdvice.join(anomaly:to:)` decides what a result may add.
public protocol AnomalyScoring: Sendable {
    /// - Parameter reference: A spectrogram of a healthy recording made the same way, when the model compares
    ///   against one (for example the other speaker of a pair); nil to use only what the model learnt.
    func score(_ spectrogram: LogMelSpectrogram, reference: LogMelSpectrogram?) async throws -> AnomalyScore
}
