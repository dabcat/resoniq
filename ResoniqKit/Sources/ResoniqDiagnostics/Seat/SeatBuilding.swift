import Foundation

/// What the "Building the average" panel draws while a seat measurement runs: each valid spot's curve so far and
/// their running average, on `ResponseGrid`, in dB against the average's middle, nil outside what may be drawn
/// (`SeatReport.drawableRange`), and the progress line.
public struct SeatBuilding: Sendable, Equatable {
    /// One curve per valid spot so far, in capture order.
    public let spotCurves: [[Float?]]
    /// The running average of the valid spots; nil before any spot is valid.
    public let average: [Float?]?
    /// "1 of 3 in": the valid spots, as `SeatReport.progress` counts them.
    public let progress: String
    public let validSpotCount: Int
    public let requiredSpotCount: Int

    /// Nothing in yet.
    public static let empty = SeatDiagnosis.building(spots: [])
}

extension SeatDiagnosis {
    /// The running average from the spots analysed so far (`SpotAnalyzer.analyze` per captured spot, in order). The
    /// same curves the finished report holds, from the same code: the report of these spots (`diagnose`), cut to what
    /// may be drawn. Cheap: no recording is touched.
    public static func building(spots: [SpotAnalysis], thresholds: SeatThresholds = .standard) -> SeatBuilding {
        let report = diagnose(spots: spots, room: nil, thresholds: thresholds)
        return SeatBuilding(
            spotCurves: report.drawableSpotCurves.compactMap { $0 },
            average: report.drawableCurve,
            progress: report.progress,
            validSpotCount: report.validSpotCount,
            requiredSpotCount: report.requiredSpotCount
        )
    }
}
