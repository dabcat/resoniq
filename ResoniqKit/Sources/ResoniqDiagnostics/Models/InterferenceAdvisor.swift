import Foundation

/// The numbers that turn a sound classifier's labels into a sentence about interference.
public struct InterferenceThresholds: Sendable, Equatable {
    /// Below this confidence in every stretch, a kind is not named. **First guess**: 0.5. On the Mac the system
    /// classifier gave a synthetic voice "speech" at 0.99 and white noise nothing above 0.24 ("waterfall").
    public var minimumConfidence: Float

    public init(minimumConfidence: Float) {
        self.minimumConfidence = minimumConfidence
    }

    public static let standard = InterferenceThresholds(minimumConfidence: 0.5)
}

/// What the audio held while the classifier listened.
public enum InterferenceContext: String, Sendable, Codable {
    /// The sweep was not playing: the paused stretch, or the noise-floor listen. Every kind can be named.
    case sweepSilent
    /// The sweep was playing (a recording judged too noisy). Kinds the sweep can pass for
    /// (`InterferenceKind.isMimickedBySweep`: music, animals, alarms, unknown) are not named.
    case sweepPlaying
}

/// The interfering sound a classifier heard, ready to show under a noisy run's reason.
///
/// Always `inferred`: it is a model's reading of the room, never a measurement, and it never changes a finding.
public struct InterferenceReport: Sendable, Codable, Equatable {
    /// The kind heard for longest.
    public let kind: InterferenceKind
    /// The mean confidence over the stretches it was heard in, 0 to 1.
    public let confidence: Float
    /// Seconds of the audio it was heard in.
    public let duration: Double
    /// That share of the audio classified, 0 to 1.
    public let fraction: Double
    /// "It sounds like someone talking."
    public let sentence: String
    /// "sound classifier, 82 %".
    public let basis: String
    /// "Inferred · sound classifier, 82 %".
    public let tagLine: String

    public var tag: EvidenceTag { .inferred }

    init(kind: InterferenceKind, confidence: Float, duration: Double, fraction: Double) {
        self.kind = kind
        self.confidence = confidence
        self.duration = duration
        self.fraction = fraction
        self.sentence = ModelText.interference(kind)
        self.basis = ModelText.soundClassifierBasis(confidence)
        self.tagLine = ModelText.tagLine(basis)
    }
}

/// Turns a sound classifier's labels into the interference the screens name. Pure, except for the one call that
/// runs a classifier.
///
/// Rules:
/// - Labels are grouped by the stretch they describe. In each stretch a kind's confidence is its most confident
///   mapped label (`InterferenceMapping`). Test-signal labels are never counted; while the sweep plays, kinds it can
///   pass for are not counted either.
/// - A kind is heard in a stretch when its confidence there reaches `minimumConfidence`. The kind heard over the
///   longest time (stretches merged where they overlap) is named; a tie goes to the higher mean confidence.
/// - With no mapped kind heard, but an unmapped label at least as confident, the kind is `unknown` (not while the
///   sweep plays: it may be the sweep).
/// - Otherwise nothing is said.
public enum InterferenceAdvisor {
    public static func describe(
        classifications: [SoundClassification],
        context: InterferenceContext = .sweepSilent,
        thresholds: InterferenceThresholds = .standard
    ) -> InterferenceReport? {
        let stretches = Dictionary(grouping: classifications) { Stretch(start: $0.start, end: $0.end) }
        guard !stretches.isEmpty else { return nil }
        let total = coveredDuration(Array(stretches.keys))

        var heard: [InterferenceKind: [(Stretch, Float)]] = [:]
        var unknown: Float = 0
        for (stretch, labels) in stretches {
            var best: [InterferenceKind: Float] = [:]
            for label in labels where !InterferenceMapping.ignored.contains(label.identifier) {
                switch InterferenceMapping.label(for: label.identifier) {
                case .testSignal:
                    continue
                case .kind(let kind):
                    if context == .sweepPlaying && kind.isMimickedBySweep { continue }
                    best[kind] = max(best[kind] ?? 0, label.confidence)
                case nil:
                    if label.confidence >= thresholds.minimumConfidence { unknown = max(unknown, label.confidence) }
                }
            }
            for (kind, confidence) in best where confidence >= thresholds.minimumConfidence {
                heard[kind, default: []].append((stretch, confidence))
            }
        }

        let ranked = heard.map { kind, hits in
            (kind: kind, duration: coveredDuration(hits.map(\.0)), confidence: hits.map(\.1).reduce(0, +) / Float(hits.count))
        }
        .sorted { ($0.duration, $0.confidence, $0.kind.rawValue) > ($1.duration, $1.confidence, $1.kind.rawValue) }

        if let top = ranked.first {
            return InterferenceReport(kind: top.kind, confidence: top.confidence, duration: top.duration,
                                      fraction: total > 0 ? min(top.duration / total, 1) : 0)
        }
        if unknown > 0, !(context == .sweepPlaying && InterferenceKind.unknown.isMimickedBySweep) {
            return InterferenceReport(kind: .unknown, confidence: unknown, duration: 0, fraction: 0)
        }
        return nil
    }

    /// **The call the app makes when a run pauses or fails for noise.** Classifies the audio captured during the
    /// noisy stretch and returns what to show under "It got noisy, so I stopped.": `sentence` with `tagLine`, or nil
    /// when nothing was heard clearly, the sound could not be named (`unknown` adds nothing to "it got noisy"), or the
    /// classifier failed. Never throws: naming the noise is a courtesy and must not stop a test.
    ///
    /// - Parameters:
    ///   - samples: Mono audio from the noisy stretch: preferably while the sweep was stopped (the paused stretch);
    ///     for a recording judged too noisy, the recording itself with `context: .sweepPlaying`.
    public static func noiseNote(
        heard samples: [Float],
        sampleRate: Double,
        context: InterferenceContext,
        classifier: some SoundClassifying,
        thresholds: InterferenceThresholds = .standard
    ) async -> InterferenceReport? {
        guard let classifications = try? await classifier.classify(samples, sampleRate: sampleRate),
              let report = describe(classifications: classifications, context: context, thresholds: thresholds),
              report.kind != .unknown
        else { return nil }
        return report
    }

    /// `noiseNote`'s sentence alone: "It sounds like someone talking.", or nil.
    public static func noiseSentence(
        heard samples: [Float],
        sampleRate: Double,
        context: InterferenceContext,
        classifier: some SoundClassifying,
        thresholds: InterferenceThresholds = .standard
    ) async -> String? {
        await noiseNote(heard: samples, sampleRate: sampleRate, context: context, classifier: classifier, thresholds: thresholds)?.sentence
    }

    // MARK: Helpers

    struct Stretch: Hashable {
        let start: Double
        let end: Double
    }

    /// The length of the union of `stretches`.
    static func coveredDuration(_ stretches: [Stretch]) -> Double {
        var total = 0.0
        var current: Stretch?
        for stretch in stretches.sorted(by: { $0.start < $1.start }) {
            if let open = current, stretch.start <= open.end {
                current = Stretch(start: open.start, end: max(open.end, stretch.end))
            } else {
                if let open = current { total += open.end - open.start }
                current = stretch
            }
        }
        if let open = current { total += open.end - open.start }
        return total
    }
}

extension RunRecord {
    /// This record with the interference heard during it, for a run whose recording was judged too noisy.
    public func adding(interference: InterferenceReport?) -> RunRecord {
        RunRecord(check: check, measurement: measurement, interference: interference, sweepTiedSound: sweepTiedSound)
    }
}

extension RunAnalysis {
    /// This run with the interference heard during it (see `RunRecord.adding(interference:)`).
    public func adding(interference: InterferenceReport?) -> RunAnalysis {
        RunAnalysis(verdict: verdict, record: record.adding(interference: interference))
    }
}
