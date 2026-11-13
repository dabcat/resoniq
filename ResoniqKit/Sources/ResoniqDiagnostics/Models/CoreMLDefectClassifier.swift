import Foundation

/// What a speaker-defect model must look like for the app to use it, checked before it is used. Pure, so it is
/// tested without Core ML.
///
/// The contract:
/// - Input `features`: a multi-array of `DefectFeatures.vectorLength` numbers (shape `[n]` or `[1, n]`), filled
///   with `DefectFeatures.vector`. Required.
/// - Input `spectrogram`: a multi-array whose last dimension is the band count of
///   `LogMelSpectrogram.Configuration.standard` (64), shape `[frames, bands]` or `[1, frames, bands]`, filled with
///   `LogMelSpectrogram.values` and cut or padded with its floor to the model's frame count. Optional.
/// - No other input: the app has nothing else to give.
/// - A classifier: a predicted label and a probability for each label, every label a `DefectClass` raw value
///   ("normal", "buzzing", …).
public struct DefectModelDescription: Sendable, Equatable {
    public enum ValueType: Sendable, Equatable {
        case multiArray(shape: [Int])
        case other(String)
    }

    public var inputs: [String: ValueType]
    /// The classifier's label output; nil when the model is not a classifier.
    public var predictedLabelName: String?
    /// The classifier's probabilities output.
    public var probabilitiesName: String?
    public var classLabels: [String]

    public init(inputs: [String: ValueType], predictedLabelName: String?, probabilitiesName: String?, classLabels: [String]) {
        self.inputs = inputs
        self.predictedLabelName = predictedLabelName
        self.probabilitiesName = probabilitiesName
        self.classLabels = classLabels
    }

    public static let featuresInput = "features"
    public static let spectrogramInput = "spectrogram"

    /// Throws `DefectModelError` naming the first way the model breaks the contract.
    public func validate(bandCount: Int = LogMelSpectrogram.Configuration.standard.bandCount) throws(DefectModelError) {
        guard let features = inputs[Self.featuresInput] else { throw .missingInput(Self.featuresInput) }
        guard case .multiArray(let shape) = features else { throw .wrongInputType(Self.featuresInput) }
        let length = DefectFeatures.vectorLength
        guard shape == [length] || shape == [1, length] else {
            throw .wrongShape(input: Self.featuresInput, expected: "[\(length)]", found: shape)
        }
        if let spectrogram = inputs[Self.spectrogramInput] {
            guard case .multiArray(let shape) = spectrogram else { throw .wrongInputType(Self.spectrogramInput) }
            let rankFits = shape.count == 2 || (shape.count == 3 && shape[0] == 1)
            guard rankFits, shape.last == bandCount, (shape.dropLast().last ?? 0) > 0 else {
                throw .wrongShape(input: Self.spectrogramInput, expected: "[frames, \(bandCount)]", found: shape)
            }
        }
        if let extra = inputs.keys.sorted().first(where: { $0 != Self.featuresInput && $0 != Self.spectrogramInput }) {
            throw .unexpectedInput(extra)
        }
        guard predictedLabelName != nil, probabilitiesName != nil, !classLabels.isEmpty else { throw .notAClassifier }
        if let unknown = classLabels.first(where: { DefectClass(rawValue: $0) == nil }) { throw .unknownClassLabel(unknown) }
    }
}

/// Why a model was refused.
public enum DefectModelError: Error, Equatable, CustomStringConvertible {
    case missingInput(String)
    case wrongInputType(String)
    case wrongShape(input: String, expected: String, found: [Int])
    case unexpectedInput(String)
    case notAClassifier
    case unknownClassLabel(String)
    /// The model loaded but a prediction did not give the probabilities output.
    case missingOutput(String)

    public var description: String {
        switch self {
        case .missingInput(let name): "The defect model has no input named \(name)."
        case .wrongInputType(let name): "The defect model's input \(name) is not a multi-array."
        case .wrongShape(let input, let expected, let found): "The defect model's input \(input) has shape \(found); expected \(expected)."
        case .unexpectedInput(let name): "The defect model wants an input named \(name), which the app does not provide."
        case .notAClassifier: "The defect model is not a classifier."
        case .unknownClassLabel(let label): "The defect model has a class \(label) that is not a defect class."
        case .missingOutput(let name): "The defect model gave no output named \(name)."
        }
    }
}

#if canImport(CoreML)
import CoreML

/// The Core ML slot for a speaker-defect classifier.
///
/// **No model ships.** There is no dataset of defective loudspeakers to train one on, so `load(from:)` finds nothing
/// in the app bundle and returns nil, and the app carries on exactly as it does without models. When a model exists
/// it is bundled compiled, as `ResoniqDefectClassifier.mlmodelc`, never downloaded. A model that breaks
/// `DefectModelDescription`'s contract is refused with a `DefectModelError` before any prediction.
///
/// An actor, because `MLModel` is not `Sendable`: predictions run one at a time on the actor.
public actor CoreMLDefectClassifier: DefectClassifying {
    /// The compiled model's resource name in the bundle (`ResoniqDefectClassifier.mlmodelc`).
    public static let modelName = "ResoniqDefectClassifier"

    private let model: MLModel
    private let dataTypes: [String: MLMultiArrayDataType]
    /// The model's inputs and outputs as checked against the contract.
    public let contract: DefectModelDescription

    /// The bundled model, nil when there is none (the shipped state). Throws when the model is present but cannot be
    /// loaded or breaks the contract.
    public static func load(from bundle: Bundle, name: String = modelName) throws -> CoreMLDefectClassifier? {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else { return nil }
        return try load(compiledModelAt: url)
    }

    /// The compiled model (`.mlmodelc`) at `url`.
    public static func load(compiledModelAt url: URL) throws -> CoreMLDefectClassifier {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let contract = Self.describe(model.modelDescription)
        try contract.validate()
        let dataTypes = model.modelDescription.inputDescriptionsByName.compactMapValues { $0.multiArrayConstraint?.dataType }
        return CoreMLDefectClassifier(model: model, dataTypes: dataTypes, contract: contract)
    }

    private init(model: MLModel, dataTypes: [String: MLMultiArrayDataType], contract: DefectModelDescription) {
        self.model = model
        self.dataTypes = dataTypes
        self.contract = contract
    }

    static func describe(_ description: MLModelDescription) -> DefectModelDescription {
        let inputs = description.inputDescriptionsByName.mapValues { feature -> DefectModelDescription.ValueType in
            if feature.type == .multiArray, let constraint = feature.multiArrayConstraint {
                return .multiArray(shape: constraint.shape.map(\.intValue))
            }
            return .other("\(feature.type.rawValue)")
        }
        return DefectModelDescription(
            inputs: inputs,
            predictedLabelName: description.predictedFeatureName,
            probabilitiesName: description.predictedProbabilitiesName,
            classLabels: (description.classLabels ?? []).compactMap { $0 as? String }
        )
    }

    public func classify(features: DefectFeatures, spectrogram: LogMelSpectrogram) async throws -> [DefectPrediction] {
        var values: [String: MLFeatureValue] = [:]
        let featuresName = DefectModelDescription.featuresInput
        let spectrogramName = DefectModelDescription.spectrogramInput
        if case .multiArray(let shape) = contract.inputs[featuresName] {
            values[featuresName] = MLFeatureValue(multiArray: try array(features.vector, shape: shape, input: featuresName))
        }
        if case .multiArray(let shape) = contract.inputs[spectrogramName] {
            let frames = shape[shape.count - 2]
            var cut = [Float](repeating: spectrogram.configuration.floorDecibels, count: frames * spectrogram.bandCount)
            let kept = min(frames, spectrogram.frameCount) * spectrogram.bandCount
            cut.replaceSubrange(0..<kept, with: spectrogram.values[0..<kept])
            values[spectrogramName] = MLFeatureValue(multiArray: try array(cut, shape: shape, input: spectrogramName))
        }
        // Synchronous on the actor: the model is not Sendable, so it does not leave the actor.
        let output = try predict(MLDictionaryFeatureProvider(dictionary: values))
        guard let name = contract.probabilitiesName,
              let probabilities = output.featureValue(for: name)?.dictionaryValue
        else { throw DefectModelError.missingOutput(contract.probabilitiesName ?? "probabilities") }
        return probabilities.compactMap { label, probability in
            guard let label = label as? String, let defect = DefectClass(rawValue: label) else { return nil }
            return DefectPrediction(defectClass: defect, confidence: probability.floatValue)
        }
        .sorted { ($0.confidence, $0.defectClass.rawValue) > ($1.confidence, $1.defectClass.rawValue) }
    }

    private func predict(_ input: MLDictionaryFeatureProvider) throws -> any MLFeatureProvider {
        try model.prediction(from: input)
    }

    /// `values` as a multi-array of the input's shape and number type.
    private func array(_ values: [Float], shape: [Int], input: String) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: dataTypes[input] ?? .float32)
        for (index, value) in values.prefix(array.count).enumerated() { array[index] = NSNumber(value: value) }
        return array
    }
}
#endif
