import Foundation

/// One thing the diagnosis says about a speaker, with how it is known.
///
/// All text is in the product's voice and ready to show; a view never composes it. The numbers behind a finding are
/// in `numbers`, and the runs it rests on are in the report, so a "show the numbers" screen recomputes nothing.
public struct Finding: Sendable, Codable, Identifiable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        /// A band quieter than the rest of the response.
        case responseDip
        /// A band louder than the rest of the response.
        case responsePeak
        /// Harmonic distortion high enough to be heard as a buzz.
        case distortion
        /// A dip above `DiagnosisThresholds.topEndFrequency`: inconclusive, it could be the phone's angle.
        case topEndDip
        /// A statement that drivers are even and clean.
        case even
        /// A run whose recording could not be used.
        case invalidRecording
        /// The response differs from the other speaker's.
        case leftRightDifference
        /// Distortion read above the buzz threshold but did not stand clear of the room's noise: inconclusive, it
        /// could be the noise.
        case distortionUnclear
        /// A driver's band far quieter than the others (`DiagnosisThresholds.quietBandDecibels`): "I could barely hear
        /// the woofer". The level difference is `measured`; its cause (the driver, its connection, the phone's
        /// position) is not known.
        case quietBand
        /// A driver's band whose signal over the room's noise was too low to assess (`inconclusive`): "Couldn't check
        /// the woofer". Nothing is said about it, healthy or not.
        case notAssessed

        /// Whether the finding is a suspected defect (drawn as a deviation, named in the verdict).
        public var isDeviation: Bool {
            switch self {
            case .responseDip, .responsePeak, .distortion, .leftRightDifference, .quietBand: true
            case .topEndDip, .even, .invalidRecording, .distortionUnclear, .notAssessed: false
            }
        }
    }

    /// How sure an inferred finding is. Never high from one microphone position.
    public enum Confidence: String, Sendable, Codable, CaseIterable {
        case low, medium, high
    }

    /// What a finding rests on: the runs that agree out of the runs compared.
    public struct Basis: Sendable, Codable, Equatable {
        public let runsAgreeing: Int
        public let runsCompared: Int
        /// "3 of 3 runs".
        public let text: String

        public init(runsAgreeing: Int, runsCompared: Int) {
            self.runsAgreeing = runsAgreeing
            self.runsCompared = runsCompared
            self.text = DiagnosisText.basis(agreeing: runsAgreeing, compared: runsCompared)
        }
    }

    /// The measured numbers behind a finding.
    public struct Numbers: Sendable, Codable, Equatable {
        public enum Unit: String, Sendable, Codable {
            /// Decibels relative to the response's trend, or to the other speaker.
            case decibels
            /// Total harmonic distortion, per cent of the fundamental.
            case percent
        }

        public let unit: Unit
        /// The median over the agreeing runs of each run's most extreme value: negative dB for a dip or a quieter
        /// band, positive for a peak or a louder one, THD for distortion.
        public let extreme: Float
        /// Where that extreme was, hertz (median over the agreeing runs).
        public let extremeFrequency: Float
        /// Each run's extreme, indexed like the report's runs; nil for a run where the finding did not appear or
        /// that could not be used.
        public let perRun: [Float?]
        /// The threshold the extreme crossed, in the same unit (a magnitude).
        public let threshold: Float
    }

    /// Stable for one report: the kind and the range.
    public let id: String
    public let kind: Kind
    /// Nil for a finding about a recording rather than a frequency.
    public let frequencyRange: FrequencyRange?
    /// The drivers concerned, top of the portrait first; one for most findings, several for an even statement.
    public let bands: [DriverBand]
    public let tag: EvidenceTag
    public let basis: Basis
    /// Set for inferred findings only.
    public let confidence: Confidence?

    /// The short title beside the portrait: "Buzz at 70–110 Hz".
    public let headline: String
    /// The line under it: "Above 14 kHz. Could be the phone's angle."
    public let detail: String
    /// The Finding screen's headline, a sentence: "A buzz around 90 Hz."
    public let sentence: String
    /// The evidence-tag label: "Inferred · 3 of 3 runs", or the tag alone.
    public let tagLine: String
    /// How the tag was arrived at, in a sentence or two: "Inferred, medium confidence. It repeats every run, …"
    public let confidenceStatement: String
    /// For a finding compared across runs: "Same place every time", "Same place in 2 of 3 runs".
    public let repeatability: String?

    /// The tone to play so the user can hear it, hertz (rounded as it is written); nil when there is none.
    public let listenFrequency: Float?
    /// The span to show the runs over around the finding (the range widened by 0.85 octave each side).
    public let context: FrequencyRange?
    public let numbers: Numbers?
    /// For `invalidRecording`, what was wrong.
    public let recordingProblem: RecordingCheck.Problem?

    /// The one driver concerned, when there is one.
    public var band: DriverBand? { bands.count == 1 ? bands[0] : nil }
}
