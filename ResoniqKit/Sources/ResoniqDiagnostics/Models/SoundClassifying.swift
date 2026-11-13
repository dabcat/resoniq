import Foundation

/// One label a sound classifier gave one stretch of audio.
public struct SoundClassification: Sendable, Codable, Equatable {
    /// The classifier's own label identifier, as it names it ("speech", "vacuum_cleaner").
    public let identifier: String
    /// 0 to 1.
    public let confidence: Float
    /// The stretch it describes, in seconds from the start of the audio given to the classifier.
    public let start: Double
    public let duration: Double

    public init(identifier: String, confidence: Float, start: Double, duration: Double) {
        self.identifier = identifier
        self.confidence = min(max(confidence, 0), 1)
        self.start = start
        self.duration = duration
    }

    public var end: Double { start + duration }
}

/// Names the sounds in a buffer of audio. The app's implementation is `SystemSoundClassifier` (Apple's built-in
/// classifier); tests use stand-ins.
///
/// An implementation runs on the device and sends nothing anywhere. It returns an empty array, not an error, for
/// audio too short to classify.
public protocol SoundClassifying: Sendable {
    /// Labels for `samples` (mono), each with its confidence and the stretch it describes. Stretches may overlap.
    func classify(_ samples: [Float], sampleRate: Double) async throws -> [SoundClassification]
}
