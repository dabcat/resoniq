import Foundation
import ResoniqDSP

/// The recording check of one run, in a form that can be stored: `RecordingVerdict` with the one number that
/// explains it.
public enum RecordingCheck: Sendable, Codable, Equatable {
    /// Fit to analyse; the broadband signal-to-noise ratio in dB.
    case valid(signalToNoise: Float)
    /// Part of the waveform was pinned at one value; the fraction of samples affected.
    case clipped(clippedFraction: Float)
    /// The recording's peak, in dBFS, was under the minimum.
    case tooQuiet(peakDecibels: Float)
    /// The room was too loud against the recording; the broadband signal-to-noise ratio in dB.
    case tooNoisy(signalToNoise: Float)
    /// The microphone delivered nothing.
    case silent
    /// Samples that were not finite numbers (NaN or infinity); how many. The data is broken, not the room.
    case corrupt(nonFiniteSampleCount: Int)
    /// Fit by level, but the recording does not hold the whole sweep (`ImpulseResponse.capturesWholeSweep` is
    /// false): it started after the sweep or stopped before the sweep's end arrived. Carries the part it does hold,
    /// nil when none.
    ///
    /// Such a run is not analysed at all, rather than analysed over the part it holds: the audio session already
    /// repeats a run whose recording is cut short, a cut edge rings so the trusted band loses an octave next to it
    /// (`Deconvolution.cutMargin`), a recording stopped early also lacks the tail the distortion floor is measured
    /// on, and runs covering different ranges would make "3 of 3 runs" mean a different range for every finding.
    case incomplete(capturedBand: FrequencyRange?)

    /// Why a recording could not be used.
    public enum Problem: String, Sendable, Codable, CaseIterable {
        case clipped, tooQuiet, tooNoisy, silent, corrupt, incomplete
    }

    public init(_ verdict: RecordingVerdict) {
        switch verdict {
        case .valid(_, let signalToNoise): self = .valid(signalToNoise: signalToNoise)
        case .clipped(let report): self = .clipped(clippedFraction: report.clippedFraction)
        case .tooQuiet(let level): self = .tooQuiet(peakDecibels: level.peakDecibels)
        case .tooNoisy(let signalToNoise, _): self = .tooNoisy(signalToNoise: signalToNoise)
        case .silent: self = .silent
        case .corrupt(let count): self = .corrupt(nonFiniteSampleCount: count)
        }
    }

    public var isValid: Bool { problem == nil }

    /// Nil for a valid recording.
    public var problem: Problem? {
        switch self {
        case .valid: nil
        case .clipped: .clipped
        case .tooQuiet: .tooQuiet
        case .tooNoisy: .tooNoisy
        case .silent: .silent
        case .corrupt: .corrupt
        case .incomplete: .incomplete
        }
    }
}

/// What THD at one grid point of one run is known to be.
public enum DistortionReading: Sendable, Equatable {
    /// Nothing was read here: outside the band where the DSP trusts the second harmonic
    /// (`HarmonicDistortion.trustedBand(order:sweep:)`), or a record stored without readings.
    case notRead
    /// THD is a measurement (`SweepDistortion.isMeasurable(at:)`: at least `measurableMarginDecibels` above the noise
    /// floor), in per cent.
    case measured(percent: Float)
    /// THD did not stand clear of the noise. `readPercent` is what was read, noise included; all that is known is
    /// that THD is under `upperBoundPercent` (the floor raised by the DSP's margin), nil when the recording left no
    /// stretch to measure the floor on.
    case belowNoise(readPercent: Float, upperBoundPercent: Float?)
}

/// What one valid run measured, on `ResponseGrid`.
public struct RunMeasurement: Sendable, Codable, Equatable {
    /// The response in dB re the sweep (uncalibrated: only its shape means anything), smoothed to
    /// 1/`DiagnosisThresholds.smoothingFraction` octave, at each `ResponseGrid` frequency. Inside `responseBand` it
    /// is the measurement; outside it, it holds the value at the nearer edge of the band (what the portrait draws
    /// there), and nothing is read from it.
    public let response: [Float]
    /// The median of `response` from 300 Hz to 3 kHz (`ResponseComparison.defaultMatchBand`): the level a
    /// response is drawn and compared against.
    public let referenceLevel: Float
    /// The part of the grid the response was measured over: the impulse response's `trustedBand`, within 20 Hz to
    /// 20 kHz. With `LogSweep.measurement` that is the whole grid. Nil only in a record stored before the band was
    /// kept; such a record counts as measured nowhere.
    public let responseBand: FrequencyRange?
    /// Total harmonic distortion (orders 2 to 5) in dB relative to the fundamental at each `ResponseGrid`
    /// frequency, smoothed to 1/`DiagnosisThresholds.distortionSmoothingFraction` octave. Gross: it includes the
    /// noise the harmonic windows collected (`SweepDistortion.thd`), so read it with `distortion(atIndex:)`. Nil
    /// outside the second harmonic's trusted band, 80 Hz to about 9.3 kHz for the measurement sweep.
    public let thdDecibels: [Float?]
    /// Whether THD at each grid point is a measurement: `SweepDistortion.isMeasurable(at:)` on the smoothed THD.
    /// Nil only in a record stored before it was kept: nowhere measurable.
    public let thdMeasurable: [Bool]?
    /// What noise alone reads as THD at each grid point, dB relative to the fundamental
    /// (`SweepDistortion.noiseFloor`); nil where there is none. Nil as a whole only in a record stored before it
    /// was kept.
    public let thdNoiseFloorDecibels: [Float?]?
    /// Seconds from the sweep's start to the sound's arrival in the recording (`ImpulseResponse.delay`).
    public let delay: Double
    /// Octave-band centres, hertz (the noise floor's bands, `OctaveBands` centres 31.62 Hz to 15.85 kHz).
    public let bandCentres: [Float]
    /// The recording's level over the room's noise floor in each band, dB.
    public let bandSignalToNoise: [Float]

    public init(
        response: [Float],
        referenceLevel: Float,
        responseBand: FrequencyRange?,
        thdDecibels: [Float?],
        thdMeasurable: [Bool]?,
        thdNoiseFloorDecibels: [Float?]?,
        delay: Double,
        bandCentres: [Float],
        bandSignalToNoise: [Float]
    ) {
        precondition(response.count == ResponseGrid.count && thdDecibels.count == ResponseGrid.count, "curves must be on ResponseGrid")
        precondition(thdMeasurable.map { $0.count == ResponseGrid.count } ?? true, "curves must be on ResponseGrid")
        precondition(thdNoiseFloorDecibels.map { $0.count == ResponseGrid.count } ?? true, "curves must be on ResponseGrid")
        precondition(bandCentres.count == bandSignalToNoise.count, "bands and ratios differ in length")
        self.response = response
        self.referenceLevel = referenceLevel
        self.responseBand = responseBand
        self.thdDecibels = thdDecibels
        self.thdMeasurable = thdMeasurable
        self.thdNoiseFloorDecibels = thdNoiseFloorDecibels
        self.delay = delay
        self.bandCentres = bandCentres
        self.bandSignalToNoise = bandSignalToNoise
    }

    /// `response` less `referenceLevel`: 0 dB is the speaker's own mid level.
    public var normalizedResponse: [Float] { response.map { $0 - referenceLevel } }

    /// Whether the response at grid point `index` is a measurement rather than a held edge value.
    public func isResponseMeasured(atIndex index: Int) -> Bool {
        responseBand?.contains(ResponseGrid.frequencies[index]) ?? false
    }

    /// THD in per cent at grid point `index`, noise included; nil where it was not read.
    public func thdPercent(atIndex index: Int) -> Float? {
        thdDecibels[index].map { 100 * Decibels.toAmplitude($0) }
    }

    /// What THD at grid point `index` is known to be.
    public func distortion(atIndex index: Int) -> DistortionReading {
        guard let read = thdPercent(atIndex: index), let thdMeasurable else { return .notRead }
        if thdMeasurable[index] { return .measured(percent: read) }
        let bound = thdNoiseFloorDecibels?[index].map {
            100 * Decibels.toAmplitude($0 + SweepDistortion.measurableMarginDecibels)
        }
        return .belowNoise(readPercent: read, upperBoundPercent: bound)
    }

    /// The signal-to-noise ratio of the octave band holding `frequency`; the nearest band outside their range, and
    /// minus infinity (nothing assessed) when there are no bands.
    public func signalToNoise(at frequency: Float) -> Float {
        guard !bandCentres.isEmpty else { return -.infinity }
        let nearest = bandCentres.indices.min { abs(log2(bandCentres[$0] / frequency)) < abs(log2(bandCentres[$1] / frequency)) }!
        return bandSignalToNoise[nearest]
    }
}

/// One run as kept in a report: the recording check, and the measurement when the recording was valid.
public struct RunRecord: Sendable, Codable, Equatable {
    public let check: RecordingCheck
    public let measurement: RunMeasurement?
    /// What a sound classifier heard while the run was noisy (`InterferenceAdvisor`), `inferred`; nil when nothing
    /// was classified or nothing clear was heard. Optional, so records stored before it still decode.
    public let interference: InterferenceReport?

    public init(check: RecordingCheck, measurement: RunMeasurement?, interference: InterferenceReport? = nil) {
        precondition(check.isValid == (measurement != nil), "only a valid recording has a measurement")
        self.check = check
        self.measurement = measurement
        self.interference = interference
    }
}

/// One run's numbers from its recording.
///
/// **An invalid recording is not analysed at all.** Its `measurement` is nil, and only the verdict (with the
/// numbers that explain it) is kept: a clipped or drowned recording gives a response and distortion that are wrong
/// in ways that look like a speaker's faults, and anything computed from it would invite a conclusion.
public struct RunAnalysis: Sendable, Equatable {
    /// The check on the recording's level, with its full numbers. `.valid` for an `incomplete` recording, which
    /// passed it.
    public let verdict: RecordingVerdict
    /// What is kept of the run in a report.
    public let record: RunRecord

    /// A run whose check is the verdict's.
    public init(verdict: RecordingVerdict, measurement: RunMeasurement?) {
        self.init(verdict: verdict, check: RecordingCheck(verdict), measurement: measurement)
    }

    /// A run whose check says more than the verdict (`RecordingCheck.incomplete`).
    public init(verdict: RecordingVerdict, check: RecordingCheck, measurement: RunMeasurement?) {
        self.verdict = verdict
        self.record = RunRecord(check: check, measurement: measurement)
    }

    init(verdict: RecordingVerdict, record: RunRecord) {
        self.verdict = verdict
        self.record = record
    }

    public var isValid: Bool { record.check.isValid }
    public var measurement: RunMeasurement? { record.measurement }
}

/// Turns one run's recording into its numbers.
///
/// **What is not measured.** The plan lists the non-harmonic residue (rub and buzz that is not a harmonic of the
/// sweep) among a run's numbers. It is not computed: the DSP measures it only on a steady tone
/// (`ToneDistortionResult.nonHarmonicResidue`), and a sweep's deconvolution offers no such figure
/// (`HarmonicDistortion` does not see rattles). Nothing in a report may therefore claim that rattle was looked for.
public enum RunAnalyzer {
    /// Analyses one recording of `sweep`, made at the same microphone gain as `noiseFloor`.
    ///
    /// The recording must start no later than the sweep's playback and run past its end by the route's delay, the
    /// room's decay and `HarmonicDistortion.minimumTail` (see `Deconvolution.impulseResponse(recording:sweep:)`).
    /// One that fails `RecordingQuality.assess`, or holds less than the whole sweep (`RecordingCheck.incomplete`),
    /// is not analysed. Without the tail, distortion is never measurable.
    public static func analyze(
        recording: [Float],
        sweep: LogSweep,
        noiseFloor: NoiseFloorReport,
        thresholds: DiagnosisThresholds = .standard,
        quality: QualityThresholds = .standard
    ) -> RunAnalysis {
        let verdict = RecordingQuality.assess(recording: recording, noiseFloor: noiseFloor, thresholds: quality)
        guard case .valid = verdict else {
            return RunAnalysis(verdict: verdict, measurement: nil)
        }

        let impulse = Deconvolution.impulseResponse(recording: recording, sweep: sweep)
        guard impulse.capturesWholeSweep, let responseBand = impulse.trustedBand.flatMap(gridBand) else {
            let captured = impulse.capturedBand.map { FrequencyRange(lower: Float($0.lowerBound), upper: Float($0.upperBound)) }
            return RunAnalysis(verdict: verdict, check: .incomplete(capturedBand: captured), measurement: nil)
        }
        let grid = ResponseGrid.frequencies
        // `frequencyResponse()` covers only the trusted band; read on the grid, the smoothed curve holds its edge
        // values outside it (`MagnitudeResponse.decibels(at:)`), which is what the portrait draws there.
        let smoothed = Smoothing.fractionalOctave(impulse.frequencyResponse(), fraction: thresholds.smoothingFraction)
        let response = grid.map(smoothed.decibels(at:))

        // THD is smoothed before it is read and judged against the floor: one point scatters by up to floor / THD,
        // which the average removes. Measurability is the DSP's own test, applied to the smoothed curve.
        let distortion = HarmonicDistortion.analyze(impulseResponse: impulse, sweep: sweep)
        let smoothedTHD = Smoothing.fractionalOctave(distortion.thd, fraction: thresholds.distortionSmoothingFraction)
        let read = SweepDistortion(
            fundamental: distortion.fundamental,
            harmonics: distortion.harmonics,
            thd: smoothedTHD,
            noiseFloor: distortion.noiseFloor
        )
        let thd: [Float?] = grid.map { read.thdPercent(at: $0).isNaN ? nil : smoothedTHD.decibels(at: $0) }
        let measurable = grid.map(read.isMeasurable(at:))
        let floor: [Float?] = grid.map { frequency in
            read.noiseFloorPercent(at: frequency).map { Decibels.fromAmplitude($0 / 100) }
        }

        let bands = bandSignalToNoise(recording: recording, sampleRate: sweep.sampleRate, noiseFloor: noiseFloor)
        return RunAnalysis(
            verdict: verdict,
            measurement: RunMeasurement(
                response: response,
                referenceLevel: referenceLevel(of: response),
                responseBand: responseBand,
                thdDecibels: thd,
                thdMeasurable: measurable,
                thdNoiseFloorDecibels: floor,
                delay: impulse.delay,
                bandCentres: bands.frequencies,
                bandSignalToNoise: bands.decibels
            )
        )
    }

    /// `band` within the grid's 20 Hz to 20 kHz; nil when they do not overlap.
    static func gridBand(_ band: ClosedRange<Double>) -> FrequencyRange? {
        let lower = max(Float(band.lowerBound), ResponseGrid.lowerFrequency)
        let upper = min(Float(band.upperBound), ResponseGrid.upperFrequency)
        return lower < upper ? FrequencyRange(lower: lower, upper: upper) : nil
    }

    /// The median level of a grid curve from 300 Hz to 3 kHz.
    static func referenceLevel(of curve: [Float]) -> Float {
        let band = ResponseComparison.defaultMatchBand
        let inBand = zip(ResponseGrid.frequencies, curve).filter { band.contains($0.0) }.map(\.1)
        return median(inBand) ?? 0
    }

    /// The recording's level over `noiseFloor` in each of the floor's octave bands.
    ///
    /// The recording's band levels are made as `NoiseFloor` makes the floor's, so the two are on the same bands with
    /// the same reference (dBFS RMS): `OctaveBands.levels` of a Welch spectrum with Hann frames of about a quarter
    /// second and 50 % overlap. (`NoiseFloor`'s own helper is internal to the DSP, so the frame length is restated
    /// here.) When the bands do not match (a floor measured at another sample rate) every ratio is minus infinity,
    /// so nothing is assessed.
    static func bandSignalToNoise(recording: [Float], sampleRate: Double, noiseFloor: NoiseFloorReport) -> MagnitudeResponse {
        let floorBands = noiseFloor.bandLevels
        guard let first = floorBands.frequencies.first, let last = floorBands.frequencies.last else { return floorBands }
        let segment = FFT.nextPowerOfTwo(max(Int(sampleRate / 4), 16))
        let spectrum = SpectrumAnalyzer.averagedSpectrum(of: recording, sampleRate: sampleRate, segmentSize: segment, window: .hann)
        let levels = OctaveBands.levels(
            of: spectrum,
            fraction: 1,
            from: first,
            to: last,
            window: .hann,
            frameLength: min(max(recording.count, 1), segment)
        )
        guard levels.frequencies == floorBands.frequencies else {
            return MagnitudeResponse(frequencies: floorBands.frequencies, decibels: floorBands.decibels.map { _ in -.infinity })
        }
        return SignalToNoise.bandRatios(signal: levels, noise: floorBands)
    }
}
