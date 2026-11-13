import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

// MARK: - Features

@Suite struct DefectFeaturesTests {
    @Test func `the bands are the noise floor's ten octaves`() {
        #expect(DefectFeatures.bandCentres.count == 10)
        #expect(abs(DefectFeatures.bandCentres.first! - 31.62) < 0.1)
        #expect(abs(DefectFeatures.bandCentres.last! - 15849) < 2)
        #expect(DefectFeatures.vectorLength == 84)
    }

    @Test func `a flat hand-built run reads flat, with THD only where measured (80 Hz to 9 kHz)`() throws {
        let runs = (0..<3).map { _ in handRun() }
        let features = DefectFeatures(runs: runs)
        #expect(features.validRunCount == 3 && features.runCount == 3)
        let band500 = try #require(DefectFeatures.bandCentres.firstIndex { abs($0 - 501) < 2 })
        #expect(abs((features.thdPercent[band500] ?? 0) - 1) < 0.01)
        #expect(features.thdPercent.first! == nil && features.thdPercent.last! == nil)
        #expect(features.broadbandSignalToNoise == 30)
        for deviation in features.responseDeviation { #expect(abs(try #require(deviation)) < 0.01) }
        for spread in features.runToRunSpread { #expect(abs(try #require(spread)) < 0.01) }
        #expect(features.signalToNoise.allSatisfy { $0 == 40 })
        #expect(features.vector.count == DefectFeatures.vectorLength)
    }

    @Test func `a dip shows in its band, and runs that disagree show their spread`() throws {
        let runs = [-2, 0, 2].map { offset in
            handRun(response: { bell($0, centre: 1000, gain: -9, width: 0.3) + ($0 > 3000 && $0 < 5000 ? Float(offset) : 0) })
        }
        let features = DefectFeatures(runs: runs)
        let band1k = try #require(DefectFeatures.bandCentres.firstIndex { abs($0 - 1000) < 2 })
        #expect(try #require(features.responseDeviation[band1k]) < -3)
        let band4k = try #require(DefectFeatures.bandCentres.firstIndex { abs($0 - 3981) < 5 })
        #expect(abs(try #require(features.runToRunSpread[band4k]) - 2) < 0.6)
        #expect(try #require(features.runToRunSpread[band1k]) < 0.01)
    }

    @Test func `unusable runs are left out, and nothing is made up`() throws {
        let features = DefectFeatures(runs: [Bench.clippedRun, Bench.noisyRun])
        #expect(features.validRunCount == 0 && features.runCount == 2)
        #expect(features.thdPercent.allSatisfy { $0 == nil })
        #expect(features.runToRunSpread.allSatisfy { $0 == nil })
        #expect(features.broadbandSignalToNoise == nil)
        let vector = features.vector
        // Every value and its presence are 0, then the run counts.
        #expect(vector.dropLast(2).allSatisfy { $0 == 0 })
        #expect(Array(vector.suffix(2)) == [0, 2])
        let decoded = try JSONDecoder().decode(DefectFeatures.self, from: JSONEncoder().encode(features))
        #expect(decoded == features)
    }
}

// MARK: - The model contract

@Suite struct DefectModelContractTests {
    static let length = DefectFeatures.vectorLength
    static let good = DefectModelDescription(
        inputs: ["features": .multiArray(shape: [length]), "spectrogram": .multiArray(shape: [1, 400, 64])],
        predictedLabelName: "defectClass",
        probabilitiesName: "defectClassProbability",
        classLabels: DefectClass.allCases.map(\.rawValue)
    )

    static func modified(_ change: (inout DefectModelDescription) -> Void) -> DefectModelDescription {
        var description = good
        change(&description)
        return description
    }

    @Test func `a model that fits the contract passes`() throws {
        try Self.good.validate()
        try Self.modified { $0.inputs["spectrogram"] = nil }.validate()
        try Self.modified { $0.inputs["features"] = .multiArray(shape: [1, Self.length]) }.validate()
        try Self.modified { $0.classLabels = ["normal", "buzzing"] }.validate()
    }

    @Test func `a mismatched model is refused with the reason`() {
        let cases: [(DefectModelDescription, DefectModelError)] = [
            (Self.modified { $0.inputs["features"] = nil }, .missingInput("features")),
            (Self.modified { $0.inputs["features"] = .other("image") }, .wrongInputType("features")),
            (Self.modified { $0.inputs["features"] = .multiArray(shape: [5]) }, .wrongShape(input: "features", expected: "[\(Self.length)]", found: [5])),
            (Self.modified { $0.inputs["spectrogram"] = .multiArray(shape: [400, 128]) }, .wrongShape(input: "spectrogram", expected: "[frames, 64]", found: [400, 128])),
            (Self.modified { $0.inputs["spectrogram"] = .multiArray(shape: [2, 400, 64]) }, .wrongShape(input: "spectrogram", expected: "[frames, 64]", found: [2, 400, 64])),
            (Self.modified { $0.inputs["image"] = .other("image") }, .unexpectedInput("image")),
            (Self.modified { $0.predictedLabelName = nil }, .notAClassifier),
            (Self.modified { $0.classLabels = [] }, .notAClassifier),
            (Self.modified { $0.classLabels = ["normal", "broken"] }, .unknownClassLabel("broken")),
        ]
        for (description, expected) in cases {
            #expect(throws: expected) { try description.validate() }
            checkWording(expected.description)
        }
    }
}

#if canImport(CoreML)
import CoreML

@Suite struct CoreMLDefectClassifierTests {
    @Test func `with no model in the bundle the loader returns nil`() throws {
        // The test runner's bundle and an empty bundle hold no model: the shipped state.
        #expect(try CoreMLDefectClassifier.load(from: Bundle.main) == nil)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let bundle = try #require(Bundle(url: empty))
        #expect(try CoreMLDefectClassifier.load(from: bundle) == nil)
        #expect(CoreMLDefectClassifier.modelName == "ResoniqDefectClassifier")
    }
}
#endif

#if canImport(CreateML) && canImport(CoreML) && os(macOS)
import CreateML
import TabularData

/// A stand-in model trained here with Create ML (a logistic regression on the feature vector): it shows the loader
/// accepts a model that fits the contract, runs it, and refuses one that does not. It knows nothing about speakers.
///
/// Training runs off the concurrency pool (`OffPool`) with `trainingTimeout`: Create ML blocks its thread waiting
/// for work it queues on that pool, so trained on a pool thread it can starve the pool on a small runner and hang
/// every test in the process.
enum StandIn {
    /// The first training took 24 s on a loaded 12-core Mac (Create ML's start-up), later ones 0.04 s.
    /// **First guess**: 120 s.
    static let trainingTimeout: Duration = .seconds(120)

    /// The default stand-in, trained once; nil where Create ML cannot train it in time, or where
    /// `RESONIQ_TEST_CREATE_ML=unavailable` simulates that.
    static let standard = Task<URL?, Never> {
        guard ProcessInfo.processInfo.environment["RESONIQ_TEST_CREATE_ML"] != "unavailable" else { return nil }
        return try? await model()
    }

    static func isAvailable() async -> Bool { await standard.value != nil }

    static func model(featureLength: Int = DefectFeatures.vectorLength, featureName: String = "features",
                      classes: [String] = ["normal", "buzzing", "mechanicalRattling"]) async throws -> URL {
        try await OffPool.run(timeout: trainingTimeout) {
            try train(featureLength: featureLength, featureName: featureName, classes: classes)
        }
    }

    private static func train(featureLength: Int, featureName: String, classes: [String]) throws -> URL {
        var features: [MLShapedArray<Double>] = []
        var labels: [String] = []
        for example in 0..<60 {
            let label = example % classes.count
            // Class k puts its weight on feature k; a little deterministic jitter elsewhere.
            let values = (0..<featureLength).map { index in index == label ? 10.0 : Double((example * 7 + index) % 5) / 10 }
            features.append(MLShapedArray(scalars: values, shape: [featureLength]))
            labels.append(classes[label])
        }
        var frame = DataFrame()
        frame.append(column: Column(name: featureName, contents: features))
        frame.append(column: Column(name: "defectClass", contents: labels))
        let classifier = try MLLogisticRegressionClassifier(trainingData: frame, targetColumn: "defectClass", featureColumns: [featureName])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-standin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("StandIn.mlmodel")
        try classifier.write(to: url)
        return try MLModel.compileModel(at: url)
    }

    /// Features whose vector puts its weight on index `index`, as the stand-in learnt.
    static func features(weightOn index: Int) -> DefectFeatures {
        var thd = [Float?](repeating: nil, count: 10)
        thd[index / 2] = index.isMultiple(of: 2) ? 10 : nil
        return DefectFeatures(thdPercent: thd)
    }
}

extension DefectFeatures {
    /// A hand-built value: only THD, so the vector's first entries are under the test's control.
    init(thdPercent: [Float?]) {
        let none = [Float?](repeating: nil, count: thdPercent.count)
        self.init(thdPercent: thdPercent, responseDeviation: none, signalToNoise: none, runToRunSpread: none,
                  broadbandSignalToNoise: nil, validRunCount: 3, runCount: 3)
    }
}

@Suite(.serialized, .enabled("Create ML could not train a stand-in model on this machine in time") { await StandIn.isAvailable() },
       .timeLimit(.minutes(5)))
struct StandInModelTests {
    @Test func `a stand-in model that fits the contract loads and classifies`() async throws {
        let url = try #require(await StandIn.standard.value)
        let classifier = try CoreMLDefectClassifier.load(compiledModelAt: url)
        let contract = await classifier.contract
        #expect(Set(contract.classLabels) == ["normal", "buzzing", "mechanicalRattling"])
        let spectrogram = LogMelSpectrogram.compute([Float](repeating: 0, count: 4800), sampleRate: 48000)
        // Index 0 is THD of the first band: weight there is "normal" to the stand-in.
        let predictions = try await classifier.classify(features: StandIn.features(weightOn: 0), spectrogram: spectrogram)
        #expect(predictions.count == 3)
        #expect(predictions.first?.defectClass == .normal)
        #expect(abs(predictions.map(\.confidence).reduce(0, +) - 1) < 0.01)
        #expect(zip(predictions, predictions.dropFirst()).allSatisfy { $0.confidence >= $1.confidence })
        // Found in a bundle by name, it would be the same; with the wrong name, nothing.
        let bundle = try #require(Bundle(url: url.deletingLastPathComponent()))
        #expect(try CoreMLDefectClassifier.load(from: bundle, name: url.deletingPathExtension().lastPathComponent) != nil)
        #expect(try CoreMLDefectClassifier.load(from: bundle) == nil)
    }

    @Test func `a stand-in model with the wrong inputs or classes is refused, not run`() async throws {
        let short = try await StandIn.model(featureLength: 12)
        #expect(throws: DefectModelError.wrongShape(input: "features", expected: "[\(DefectFeatures.vectorLength)]", found: [12])) {
            _ = try CoreMLDefectClassifier.load(compiledModelAt: short)
        }
        let misnamed = try await StandIn.model(featureName: "numbers")
        #expect(throws: DefectModelError.missingInput("features")) {
            _ = try CoreMLDefectClassifier.load(compiledModelAt: misnamed)
        }
        let unknownClass = try await StandIn.model(classes: ["normal", "broken"])
        #expect(throws: DefectModelError.unknownClassLabel("broken")) {
            _ = try CoreMLDefectClassifier.load(compiledModelAt: unknownClass)
        }
    }
}
#endif

// MARK: - Joining a model's output to a report

@Suite struct ModelAdviceTests {
    /// A conclusive report with a buzz (`inferred`), an even statement (`measured`) and an unclear stretch.
    static let buzz = DistortionTests.threeOfThree
    /// A conclusive healthy report: only `measured` findings.
    static let healthy = SpeakerDiagnosis.diagnose(runs: Bench.healthyRuns(seed: 1), counterpart: nil)
    /// Not conclusive.
    static let inconclusive = SpeakerDiagnosis.diagnose(runs: [Bench.clippedRun, Bench.noisyRun], counterpart: nil)

    static func predict(_ defect: DefectClass, _ confidence: Float) -> [DefectPrediction] {
        let rest = (1 - confidence) / Float(DefectClass.allCases.count - 1)
        return DefectClass.allCases.map { DefectPrediction(defectClass: $0, confidence: $0 == defect ? confidence : rest) }
    }

    /// Everything the DSP decided, unchanged.
    static func expectUnchanged(_ joined: SpeakerReport, from report: SpeakerReport, exceptSupport: Bool = false) {
        #expect(joined.verdict == report.verdict)
        #expect(joined.isConclusive == report.isConclusive)
        #expect(joined.runs == report.runs)
        #expect(joined.suspectedDefects.map(\.id) == report.suspectedDefects.map(\.id))
        #expect(joined.findings.count == report.findings.count)
        for (after, before) in zip(joined.findings, report.findings) {
            #expect(after.tag == before.tag && after.basis == before.basis && after.confidence == before.confidence)
            #expect(after.headline == before.headline && after.sentence == before.sentence && after.detail == before.detail)
            if before.tag != .inferred || !exceptSupport { #expect(after.modelSupport == before.modelSupport) }
        }
    }

    @Test func `with no prediction, or no model, the report is exactly as it was`() {
        #expect(ModelAdvice.join([], to: Self.buzz) == Self.buzz)
        #expect(Self.buzz.modelFindings == nil)
    }

    @Test func `a buzz prediction supports the inferred buzz and changes nothing else`() throws {
        let joined = ModelAdvice.join(Self.predict(.buzzing, 0.74), to: Self.buzz)
        Self.expectUnchanged(joined, from: Self.buzz, exceptSupport: true)
        let finding = try #require(joined.findings.first { $0.kind == .distortion })
        #expect(finding.tag == .inferred)
        let support = try #require(finding.modelSupport)
        #expect(support.source == .defectClassifier && support.defectClass == .buzzing)
        #expect(support.basis == "defect classifier, 74 %")
        #expect(support.statement == "A defect classifier also heard a buzz (74 %).")
        #expect(joined.modelFindings == nil)
        // Measured findings carry no support.
        #expect(joined.findings.filter { $0.tag != .inferred }.allSatisfy { $0.modelSupport == nil })
    }

    @Test func `a class with no matching inferred finding adds one inferred, low-confidence line`() throws {
        let joined = ModelAdvice.join(Self.predict(.mechanicalRattling, 0.81), to: Self.healthy)
        Self.expectUnchanged(joined, from: Self.healthy)
        let line = try #require(joined.modelFindings?.first)
        #expect(joined.modelFindings?.count == 1)
        #expect(line.kind == .defect && line.tag == .inferred && line.confidence == .low)
        #expect(line.headline == "Possible rattle")
        #expect(line.sentence == "I may have heard a rattle.")
        #expect(line.detail == "A defect classifier heard something like a rattle. It's a hint, not a measurement.")
        #expect(line.tagLine == "Inferred · defect classifier, 81 %")
        // A measured healthy verdict stays; the model is not a verdict.
        #expect(joined.verdict == Self.healthy.verdict)
        #expect(joined.suspectedDefects.isEmpty)
        // A buzz the report has no inferred finding for is a line too, never support to a measured finding.
        let buzzOnHealthy = ModelAdvice.join(Self.predict(.buzzing, 0.9), to: Self.healthy)
        #expect(buzzOnHealthy.modelFindings?.first?.evidence.defectClass == .buzzing)
        #expect(buzzOnHealthy.findings.allSatisfy { $0.modelSupport == nil })
    }

    @Test func `only one line, and a second join replaces it`() {
        let once = ModelAdvice.join(Self.predict(.crackling, 0.8), to: Self.healthy)
        let twice = ModelAdvice.join(Self.predict(.voiceCoilRubbing, 0.75), to: once)
        #expect(twice.modelFindings?.count == 1)
        #expect(twice.modelFindings?.first?.evidence.defectClass == .voiceCoilRubbing)
    }

    @Test func `below the named confidence nothing is said`() {
        let threshold = ModelAdviceThresholds.standard.minimumDefectConfidence
        #expect(threshold == 0.7)
        #expect(ModelAdvice.join(Self.predict(.mechanicalRattling, 0.69), to: Self.healthy) == Self.healthy)
        #expect(ModelAdvice.join(Self.predict(.buzzing, 0.5), to: Self.buzz) == Self.buzz)
        #expect(ModelAdvice.join(Self.predict(.mechanicalRattling, 0.7), to: Self.healthy).modelFindings?.count == 1)
    }

    @Test func `normal says nothing at all, even when another class is also confident`() {
        #expect(ModelAdvice.join(Self.predict(.normal, 0.95), to: Self.buzz) == Self.buzz)
        let both = [DefectPrediction(defectClass: .normal, confidence: 0.9), DefectPrediction(defectClass: .crackling, confidence: 0.8)]
        #expect(ModelAdvice.join(both, to: Self.healthy) == Self.healthy)
    }

    @Test func `an inconclusive report gets nothing from a model`() {
        #expect(!Self.inconclusive.isConclusive)
        #expect(ModelAdvice.join(Self.predict(.crackling, 0.99), to: Self.inconclusive) == Self.inconclusive)
        #expect(ModelAdvice.join(anomaly: AnomalyScore(reconstructionError: 10, typicalHealthyError: 1), to: Self.inconclusive) == Self.inconclusive)
    }

    @Test func `the anomaly check adds a hedged line only above its threshold, never a verdict`() throws {
        #expect(ModelAdviceThresholds.standard.minimumAnomalyRatio == 3)
        #expect(ModelAdvice.join(anomaly: AnomalyScore(reconstructionError: 2.9, typicalHealthyError: 1), to: Self.healthy) == Self.healthy)
        #expect(ModelAdvice.join(anomaly: AnomalyScore(reconstructionError: 5, typicalHealthyError: 0), to: Self.healthy) == Self.healthy)
        let joined = ModelAdvice.join(anomaly: AnomalyScore(reconstructionError: 0.62, typicalHealthyError: 0.2), to: Self.healthy)
        Self.expectUnchanged(joined, from: Self.healthy)
        let line = try #require(joined.modelFindings?.first)
        #expect(line.kind == .anomaly && line.tag == .inferred && line.confidence == .low)
        #expect(line.headline == "Something sounded unusual")
        #expect(line.tagLine == "Inferred · anomaly check, 3.1 × usual")
        // Next to a defect line, not instead of it.
        let both = ModelAdvice.join(Self.predict(.crackling, 0.8), to: joined)
        #expect(both.modelFindings?.map(\.kind) == [.anomaly, .defect])
    }

    @Test func `every model line passes the wording rules`() {
        for defect in DefectClass.allCases where defect != .normal {
            let joined = ModelAdvice.join(Self.predict(defect, 0.9), to: Self.healthy)
            for line in joined.modelFindings ?? [] {
                for text in [line.headline, line.detail, line.sentence, line.tagLine, line.evidence.statement] { checkWording(text) }
                #expect(line.tagLine.hasPrefix("Inferred · defect classifier"))
            }
            checkWording(ModelText.defectSupport(defect, confidence: 0.9))
        }
        for text in [ModelText.anomalyHeadline, ModelText.anomalySentence, ModelText.anomalyDetail] { checkWording(text) }
    }

    @Test func `a report with model lines survives JSON`() throws {
        let joined = ModelAdvice.join(anomaly: AnomalyScore(reconstructionError: 4, typicalHealthyError: 1),
                                      to: ModelAdvice.join(Self.predict(.buzzing, 0.8), to: Self.buzz))
        let decoded = try JSONDecoder().decode(SpeakerReport.self, from: JSONEncoder().encode(joined))
        #expect(decoded == joined)
        #expect(decoded.findings.contains { $0.modelSupport != nil })
    }
}
