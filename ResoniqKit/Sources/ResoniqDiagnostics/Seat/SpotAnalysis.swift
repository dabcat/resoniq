import Foundation
import ResoniqDSP

/// What one valid recording at a spot measured, on `ResponseGrid`.
public struct SpotMeasurement: Sendable, Codable, Equatable {
    /// The room curve in dB re the sweep (uncalibrated: only its shape and differences mean anything): the response
    /// read with the room window (`ImpulseResponse.roomPostWindow`) and smoothed as `SpotAnalyzer.roomCurve` says.
    /// Outside `responseBand` it holds the value at the nearer edge, and nothing is read from it.
    public let response: [Float]
    /// The part of the grid measured: the impulse response's `trustedBand` within 20 Hz to 20 kHz.
    public let responseBand: FrequencyRange
    /// Octave-band centres, hertz, and the recording's level over the room's noise floor in each, dB.
    public let bandCentres: [Float]
    public let bandSignalToNoise: [Float]
    /// THD at `SeatThresholds.distortionFrequency`, per cent; nil where it was not a measurement
    /// (`SweepDistortion.isMeasurable(at:)`) or not read.
    public let distortionPercent: Float?
    /// The bass decay (`Decay.bass`); nil when the recording cannot support an estimate.
    public let bassDecay: SeatDecay?

    public init(
        response: [Float],
        responseBand: FrequencyRange,
        bandCentres: [Float],
        bandSignalToNoise: [Float],
        distortionPercent: Float?,
        bassDecay: SeatDecay?
    ) {
        precondition(response.count == ResponseGrid.count, "curves must be on ResponseGrid")
        precondition(bandCentres.count == bandSignalToNoise.count, "bands and ratios differ in length")
        self.response = response
        self.responseBand = responseBand
        self.bandCentres = bandCentres
        self.bandSignalToNoise = bandSignalToNoise
        self.distortionPercent = distortionPercent
        self.bassDecay = bassDecay
    }

    /// Whether grid point `index` is a measurement with at least `minimumSignalToNoise` dB in its octave band.
    func isAssessed(atIndex index: Int, minimumSignalToNoise: Float) -> Bool {
        let frequency = ResponseGrid.frequencies[index]
        guard responseBand.contains(frequency), !bandCentres.isEmpty else { return false }
        let nearest = bandCentres.indices.min { abs(log2(bandCentres[$0] / frequency)) < abs(log2(bandCentres[$1] / frequency)) }!
        return bandSignalToNoise[nearest] >= minimumSignalToNoise
    }
}

/// One recording at a spot: its check, and the measurement when it was valid.
public struct SpotRecording: Sendable, Codable, Equatable {
    public let check: RecordingCheck
    public let measurement: SpotMeasurement?

    public init(check: RecordingCheck, measurement: SpotMeasurement?) {
        precondition(check.isValid == (measurement != nil), "only a valid recording has a measurement")
        self.check = check
        self.measurement = measurement
    }

    public var isValid: Bool { check.isValid }
}

/// One measuring spot: the left speaker's recording and the right's (nil for a single speaker).
public struct SpotAnalysis: Sendable, Codable, Equatable {
    public let left: SpotRecording
    public let right: SpotRecording?

    public init(left: SpotRecording, right: SpotRecording?) {
        self.left = left
        self.right = right
    }

    /// Valid only when every recording it needs is: a spot with one bad channel is measured again.
    public var isValid: Bool { left.isValid && (right?.isValid ?? true) }

    /// What was wrong, left first; empty for a valid spot.
    public var problems: [RecordingCheck.Problem] { [left.check.problem, right?.check.problem].compactMap { $0 } }

    var measurements: [SpotMeasurement] { [left.measurement, right?.measurement].compactMap { $0 } }
}

/// Turns one spot's recordings into its numbers.
///
/// Each recording is checked as a run is (`RecordingQuality.assess`, then whether it holds the whole sweep); one
/// that fails is not analysed, and its spot is not valid. A valid recording is deconvolved and read with the room
/// window (`ImpulseResponse.roomPostWindow`, the room is the subject here, so reflections and the bass's ring stay
/// in), smoothed into a room curve, distortion is read at `SeatThresholds.distortionFrequency` where it is a
/// measurement, and the bass decay is estimated (`Decay.bass`, given the sweep).
///
/// The recording must start no later than the sweep's playback and run past its end by the route's delay and at
/// least `ImpulseResponse.roomPostWindow`; a decay estimate needs about a second more (`Decay.minimumDuration`).
public enum SpotAnalyzer {
    public static func analyze(
        left: [Float],
        right: [Float]?,
        sweep: LogSweep,
        noiseFloor: NoiseFloorReport,
        thresholds: SeatThresholds = .standard,
        quality: QualityThresholds = .standard
    ) -> SpotAnalysis {
        SpotAnalysis(
            left: recording(left, sweep: sweep, noiseFloor: noiseFloor, thresholds: thresholds, quality: quality),
            right: right.map { recording($0, sweep: sweep, noiseFloor: noiseFloor, thresholds: thresholds, quality: quality) }
        )
    }

    static func recording(
        _ samples: [Float],
        sweep: LogSweep,
        noiseFloor: NoiseFloorReport,
        thresholds: SeatThresholds,
        quality: QualityThresholds
    ) -> SpotRecording {
        let verdict = RecordingQuality.assess(recording: samples, noiseFloor: noiseFloor, thresholds: quality)
        guard case .valid = verdict else { return SpotRecording(check: RecordingCheck(verdict), measurement: nil) }
        let impulse = Deconvolution.impulseResponse(recording: samples, sweep: sweep)
        guard impulse.capturesWholeSweep, let band = impulse.trustedBand.flatMap(RunAnalyzer.gridBand) else {
            let captured = impulse.capturedBand.map { FrequencyRange(lower: Float($0.lowerBound), upper: Float($0.upperBound)) }
            return SpotRecording(check: .incomplete(capturedBand: captured), measurement: nil)
        }
        let response = roomCurve(impulse.frequencyResponse(postWindow: ImpulseResponse.roomPostWindow), thresholds: thresholds)

        let distortion = HarmonicDistortion.analyze(impulseResponse: impulse, sweep: sweep)
        let read = SweepDistortion(
            fundamental: distortion.fundamental,
            harmonics: distortion.harmonics,
            thd: Smoothing.fractionalOctave(distortion.thd, fraction: thresholds.distortionSmoothingFraction),
            noiseFloor: distortion.noiseFloor
        )
        let at = thresholds.distortionFrequency
        let percent = read.thdPercent(at: at)
        let distortionPercent: Float? = percent.isFinite && read.isMeasurable(at: at) ? percent : nil

        let decay = Decay.bass(impulseResponse: impulse, sweep: sweep).map {
            SeatDecay(lower: Float($0.band.lowerBound), upper: Float($0.band.upperBound), seconds: $0.seconds)
        }
        let bands = RunAnalyzer.bandSignalToNoise(recording: samples, sampleRate: sweep.sampleRate, noiseFloor: noiseFloor)
        let check = RecordingCheck(verdict)
        return SpotRecording(
            check: check,
            measurement: SpotMeasurement(
                response: response,
                responseBand: band,
                bandCentres: bands.frequencies,
                bandSignalToNoise: bands.decibels,
                distortionPercent: distortionPercent,
                bassDecay: decay
            )
        )
    }

    /// The room curve on `ResponseGrid`: the response smoothed to 1/`bassSmoothingFraction` octave in the bass and
    /// 1/`smoothingFraction` octave above it, blended over an octave around `smoothingCrossoverFrequency`
    /// (`SeatThresholds.coarseWeight(at:)`). The one definition of how a seat response is smoothed.
    public static func roomCurve(_ response: MagnitudeResponse, thresholds: SeatThresholds = .standard) -> [Float] {
        let fine = Smoothing.fractionalOctave(response, fraction: thresholds.bassSmoothingFraction)
        let coarse = Smoothing.fractionalOctave(response, fraction: thresholds.smoothingFraction)
        return ResponseGrid.frequencies.map { frequency in
            let weight = thresholds.coarseWeight(at: frequency)
            if weight == 0 { return fine.decibels(at: frequency) }
            if weight == 1 { return coarse.decibels(at: frequency) }
            return (1 - weight) * fine.decibels(at: frequency) + weight * coarse.decibels(at: frequency)
        }
    }
}
