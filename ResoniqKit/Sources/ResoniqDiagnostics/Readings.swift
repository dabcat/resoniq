import Foundation
import ResoniqDSP

/// The microphone's level as the Listening and Three spots screens read it out while the sweep plays.
///
/// **Rule.** Clipping (`ClippingDetector`, the session's `isClipping`) is "too loud". "Too quiet" is judged only once
/// the sweep arriving is above the woofer's range (`DriverBand.wooferUpperFrequency`), where a speaker is not
/// rolling off, and against the recording check's own minimum peak (`QualityThresholds.minimumPeakDecibels`), so the
/// screen warns about exactly what would fail the check. Otherwise it is good.
public enum InputLevel: String, Sendable, Equatable, CaseIterable {
    case good
    case tooQuiet
    case tooLoud

    /// - Parameters:
    ///   - frequency: The sweep frequency arriving now; nil before it is heard and while paused.
    ///   - peakDecibels: The block's peak, dBFS.
    public init(isClipping: Bool, frequency: Double?, peakDecibels: Float, thresholds: QualityThresholds = .standard) {
        if isClipping {
            self = .tooLoud
        } else if let frequency, Float(frequency) > DriverBand.wooferUpperFrequency, peakDecibels < thresholds.minimumPeakDecibels {
            self = .tooQuiet
        } else {
            self = .good
        }
    }

    /// Listening's reading: "Good, no clipping", "Too quiet", "Too loud, clipping".
    public var label: String {
        switch self {
        case .good: "Good, no clipping"
        case .tooQuiet: "Too quiet"
        case .tooLoud: "Too loud, clipping"
        }
    }

    /// What to do about it, under the reading: nil when the level is good. The same advice the notice gives when a run
    /// is played again.
    public var advice: String? {
        switch self {
        case .good: nil
        case .tooQuiet: "Turn the volume up or hold the phone closer."
        case .tooLoud: "Turn the volume down a little."
        }
    }

    /// Three spots' shorter reading: "Good", "Too quiet", "Too loud".
    public var shortLabel: String {
        switch self {
        case .good: "Good"
        case .tooQuiet: "Too quiet"
        case .tooLoud: "Too loud"
        }
    }
}

extension SpeakerReport {
    /// `consensusResponse` with nil outside the stretch every valid run measured (`RunMeasurement.responseBand`),
    /// where it only holds the edge value; nil when inconclusive. With `LogSweep.measurement` every run measures the
    /// whole grid, so nothing is cut; a chart that can leave a gap draws this, not the held curve.
    public var drawableResponse: [Float?]? {
        guard let consensusResponse else { return nil }
        let measurements = runs.compactMap(\.measurement)
        guard !measurements.isEmpty else { return nil }
        return consensusResponse.indices.map { index in
            measurements.allSatisfy { $0.isResponseMeasured(atIndex: index) } ? consensusResponse[index] : nil
        }
    }
}
