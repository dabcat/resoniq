import Foundation
import ResoniqDSP

/// The DSP's numbers about one speaker test, in the fixed shape a speaker-defect classifier takes alongside a
/// `LogMelSpectrogram`. Built only from the valid runs' `RunMeasurement`s; nothing here is computed from an
/// unusable recording.
///
/// Every per-band figure is on the octave bands of `bandCentres` (the `OctaveBands` octaves 31.62 Hz to 15.85 kHz,
/// the noise floor's bands). A band is read over the `ResponseGrid` points between its edges. A figure that cannot be
/// read is nil, never a made-up value; `vector` turns nil into 0 with a presence flag beside it.
public struct DefectFeatures: Sendable, Codable, Equatable {
    /// Octave-band centres, hertz.
    public static let bandCentres: [Float] = OctaveBands.centres(fraction: 1, from: 31.62, to: 15849)
        .filter { $0 > 30 && $0 < 16000 }

    /// Per band: the median over valid runs of each run's median THD over the band's points where THD is
    /// `measured`, per cent. Nil where no run measured it (outside 80 Hz to about 9.3 kHz, or below the noise).
    public let thdPercent: [Float?]
    /// Per band: the median over valid runs of each run's mean deviation from its own trend over the band's measured
    /// points (`Trend`, the deviation dips and peaks are found with), dB; negative for a dip.
    public let responseDeviation: [Float?]
    /// Per band: the median over valid runs of the band's signal over the room's noise, dB.
    public let signalToNoise: [Float?]
    /// Per band: the standard deviation across valid runs of the band's mean normalised response, dB: how far the
    /// runs disagree. Nil with fewer than two valid runs.
    public let runToRunSpread: [Float?]
    /// The median of the valid runs' broadband signal-to-noise ratio, dB.
    public let broadbandSignalToNoise: Float?
    public let validRunCount: Int
    public let runCount: Int

    init(thdPercent: [Float?], responseDeviation: [Float?], signalToNoise: [Float?], runToRunSpread: [Float?],
         broadbandSignalToNoise: Float?, validRunCount: Int, runCount: Int) {
        self.thdPercent = thdPercent
        self.responseDeviation = responseDeviation
        self.signalToNoise = signalToNoise
        self.runToRunSpread = runToRunSpread
        self.broadbandSignalToNoise = broadbandSignalToNoise
        self.validRunCount = validRunCount
        self.runCount = runCount
    }

    /// Builds the features from a test's runs.
    public init(runs: [RunAnalysis], thresholds: DiagnosisThresholds = .standard) {
        self.init(records: runs.map(\.record), thresholds: thresholds)
    }

    public init(records: [RunRecord], thresholds: DiagnosisThresholds = .standard) {
        let measurements = records.compactMap(\.measurement)
        let bands = Self.bandCentres.map { OctaveBands.edges(ofCentre: $0, fraction: 1) }
        let points: [[Int]] = bands.map { band in
            ResponseGrid.frequencies.indices.filter { (band.lower..<band.upper).contains(ResponseGrid.frequencies[$0]) }
        }
        let deviations = measurements.map { Trend.deviation(of: $0.response, thresholds: thresholds) }

        func median(_ values: [Float]) -> Float? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            let middle = sorted.count / 2
            return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }

        var thd: [Float?] = []
        var deviation: [Float?] = []
        var snr: [Float?] = []
        var spread: [Float?] = []
        for (band, indices) in zip(Self.bandCentres, points) {
            thd.append(median(measurements.compactMap { measurement in
                median(indices.compactMap { index in
                    if case .measured(let percent) = measurement.distortion(atIndex: index) { return percent }
                    return nil
                })
            }))
            deviation.append(median(zip(measurements, deviations).compactMap { measurement, curve in
                let measured = indices.filter { measurement.isResponseMeasured(atIndex: $0) }
                return measured.isEmpty ? nil : measured.map { curve[$0] }.reduce(0, +) / Float(measured.count)
            }))
            snr.append(median(measurements.compactMap { measurement in
                measurement.bandCentres.isEmpty ? nil : measurement.signalToNoise(at: band)
            }))
            let levels: [Float] = measurements.compactMap { measurement in
                let measured = indices.filter { measurement.isResponseMeasured(atIndex: $0) }
                let normalized = measurement.normalizedResponse
                return measured.isEmpty ? nil : measured.map { normalized[$0] }.reduce(0, +) / Float(measured.count)
            }
            if levels.count >= 2 {
                let mean = levels.reduce(0, +) / Float(levels.count)
                spread.append((levels.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(levels.count - 1)).squareRoot())
            } else {
                spread.append(nil)
            }
        }
        thdPercent = thd
        responseDeviation = deviation
        signalToNoise = snr
        runToRunSpread = spread
        broadbandSignalToNoise = median(records.compactMap {
            if case .valid(let signalToNoise) = $0.check { return signalToNoise }
            return nil
        })
        validRunCount = measurements.count
        runCount = records.count
    }

    /// The length of `vector`.
    public static var vectorLength: Int { bandCentres.count * 4 * 2 + 4 }

    /// The features as one flat vector, the order fixed: for each of THD, response deviation, signal-to-noise and
    /// run-to-run spread, each band's value then its presence (1 read, 0 not; a missing value is 0); then the
    /// broadband signal-to-noise and its presence, the valid-run count and the run count.
    public var vector: [Float] {
        var vector: [Float] = []
        vector.reserveCapacity(Self.vectorLength)
        for figures in [thdPercent, responseDeviation, signalToNoise, runToRunSpread] {
            for value in figures {
                vector.append(value ?? 0)
                vector.append(value == nil ? 0 : 1)
            }
        }
        vector.append(broadbandSignalToNoise ?? 0)
        vector.append(broadbandSignalToNoise == nil ? 0 : 1)
        vector.append(Float(validRunCount))
        vector.append(Float(runCount))
        return vector
    }
}
