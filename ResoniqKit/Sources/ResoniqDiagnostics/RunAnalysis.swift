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

    /// Why a recording could not be used.
    public enum Problem: String, Sendable, Codable, CaseIterable {
        case clipped, tooQuiet, tooNoisy, silent
    }

    public init(_ verdict: RecordingVerdict) {
        switch verdict {
        case .valid(_, let signalToNoise): self = .valid(signalToNoise: signalToNoise)
        case .clipped(let report): self = .clipped(clippedFraction: report.clippedFraction)
        case .tooQuiet(let level): self = .tooQuiet(peakDecibels: level.peakDecibels)
        case .tooNoisy(let signalToNoise, _): self = .tooNoisy(signalToNoise: signalToNoise)
        case .silent: self = .silent
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
        }
    }
}

/// What one valid run measured, on `ResponseGrid`.
public struct RunMeasurement: Sendable, Codable, Equatable {
    /// The response in dB re the sweep (uncalibrated: only its shape means anything), smoothed to
    /// 1/`DiagnosisThresholds.smoothingFraction` octave, at each `ResponseGrid` frequency.
    public let response: [Float]
    /// The median of `response` from 300 Hz to 3 kHz (`ResponseComparison.defaultMatchBand`): the level a
    /// response is drawn and compared against.
    public let referenceLevel: Float
    /// Total harmonic distortion (orders 2 to 5) in dB relative to the fundamental at each `ResponseGrid`
    /// frequency, smoothed to 1/`DiagnosisThresholds.distortionSmoothingFraction` octave. Nil where it cannot be
    /// measured: above `HarmonicDistortion.upperFrequency(order: 2, sweep:)`, about 8.9 kHz for a sweep to 20 kHz.
    public let thdDecibels: [Float?]
    /// Seconds from the sweep's start to the sound's arrival in the recording (`ImpulseResponse.delay`).
    public let delay: Double
    /// Octave-band centres, hertz (the noise floor's bands, 31.5 Hz to 16 kHz).
    public let bandCentres: [Float]
    /// The recording's level over the room's noise floor in each band, dB.
    public let bandSignalToNoise: [Float]

    public init(
        response: [Float],
        referenceLevel: Float,
        thdDecibels: [Float?],
        delay: Double,
        bandCentres: [Float],
        bandSignalToNoise: [Float]
    ) {
        precondition(response.count == ResponseGrid.count && thdDecibels.count == ResponseGrid.count, "curves must be on ResponseGrid")
        precondition(bandCentres.count == bandSignalToNoise.count, "bands and ratios differ in length")
        self.response = response
        self.referenceLevel = referenceLevel
        self.thdDecibels = thdDecibels
        self.delay = delay
        self.bandCentres = bandCentres
        self.bandSignalToNoise = bandSignalToNoise
    }

    /// `response` less `referenceLevel`: 0 dB is the speaker's own mid level.
    public var normalizedResponse: [Float] { response.map { $0 - referenceLevel } }

    /// THD in per cent at grid point `index`; nil where it was not measured.
    public func thdPercent(atIndex index: Int) -> Float? {
        thdDecibels[index].map { 100 * Decibels.toAmplitude($0) }
    }

    /// The signal-to-noise ratio of the octave band holding `frequency`; the nearest band outside their range.
    public func signalToNoise(at frequency: Float) -> Float {
        guard !bandCentres.isEmpty else { return .infinity }
        let nearest = bandCentres.indices.min { abs(log2(bandCentres[$0] / frequency)) < abs(log2(bandCentres[$1] / frequency)) }!
        return bandSignalToNoise[nearest]
    }
}

/// One run as kept in a report: the recording check, and the measurement when the recording was valid.
public struct RunRecord: Sendable, Codable, Equatable {
    public let check: RecordingCheck
    public let measurement: RunMeasurement?

    public init(check: RecordingCheck, measurement: RunMeasurement?) {
        precondition(check.isValid == (measurement != nil), "only a valid recording has a measurement")
        self.check = check
        self.measurement = measurement
    }
}

/// One run's numbers from its recording.
///
/// **An invalid recording is not analysed at all.** Its `measurement` is nil, and only the verdict (with the
/// numbers that explain it) is kept: a clipped or drowned recording gives a response and distortion that are wrong
/// in ways that look like a speaker's faults, and anything computed from it would invite a conclusion.
public struct RunAnalysis: Sendable, Equatable {
    /// The check on the recording, with its full numbers.
    public let verdict: RecordingVerdict
    /// What is kept of the run in a report.
    public let record: RunRecord

    public init(verdict: RecordingVerdict, measurement: RunMeasurement?) {
        self.verdict = verdict
        self.record = RunRecord(check: RecordingCheck(verdict), measurement: measurement)
    }

    public var isValid: Bool { record.check.isValid }
    public var measurement: RunMeasurement? { record.measurement }
}

/// Turns one run's recording into its numbers.
public enum RunAnalyzer {
    /// Analyses one recording of `sweep`, made at the same microphone gain as `noiseFloor`.
    ///
    /// The recording must start no later than the sweep's playback and run past its end by the route's delay and
    /// the room's decay (see `Deconvolution.impulseResponse(recording:sweep:)`).
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
        let grid = ResponseGrid.frequencies
        let smoothed = Smoothing.fractionalOctave(impulse.frequencyResponse(), fraction: thresholds.smoothingFraction)
        let response = grid.map(smoothed.decibels(at:))

        let distortion = HarmonicDistortion.analyze(impulseResponse: impulse, sweep: sweep)
        let thd = Smoothing.fractionalOctave(distortion.thd, fraction: thresholds.distortionSmoothingFraction)
        let thdRange = (thd.frequencies.first ?? 0)...(thd.frequencies.last ?? 0)
        let thdOnGrid: [Float?] = grid.map { thdRange.contains($0) ? thd.decibels(at: $0) : nil }

        let bands = bandSignalToNoise(recording: recording, sampleRate: sweep.sampleRate, noiseFloor: noiseFloor)
        return RunAnalysis(
            verdict: verdict,
            measurement: RunMeasurement(
                response: response,
                referenceLevel: referenceLevel(of: response),
                thdDecibels: thdOnGrid,
                delay: impulse.delay,
                bandCentres: bands.frequencies,
                bandSignalToNoise: bands.decibels
            )
        )
    }

    /// The median level of a grid curve from 300 Hz to 3 kHz.
    static func referenceLevel(of curve: [Float]) -> Float {
        let band = ResponseComparison.defaultMatchBand
        let inBand = zip(ResponseGrid.frequencies, curve).filter { band.contains($0.0) }.map(\.1)
        return median(inBand) ?? 0
    }

    /// The recording's level over `noiseFloor` in each of the floor's octave bands.
    ///
    /// `SignalToNoise.bandRatios(signal:noise:)` needs the recording's band levels on the floor's bands, and the
    /// function that makes them (`NoiseFloor.octaveBandLevels`) is internal to ResoniqDSP, so they are rebuilt here
    /// the same way: a Welch spectrum (16384-point Hann frames, 50 % overlap), bands between the base-two centre's
    /// 2^∓½ edges, scaled so a band holds its share of the mean square.
    static func bandSignalToNoise(recording: [Float], sampleRate: Double, noiseFloor: NoiseFloorReport) -> MagnitudeResponse {
        let segment = FFT.nextPowerOfTwo(max(Int(sampleRate / 4), 16))
        let window = Window.hann
        let spectrum = SpectrumAnalyzer.averagedSpectrum(of: recording, sampleRate: sampleRate, segmentSize: segment, window: window)
        let nyquist = Float(sampleRate / 2)
        // The spectrum puts a sine of amplitude A at A² in its bin and spreads it over ENBW bins; its mean square
        // is A²/2. Bins 0 and Nyquist are never inside a band.
        let scale = 1 / (2 * window.equivalentNoiseBandwidth)
        let levels = noiseFloor.bandLevels.frequencies.map { nominal -> Float in
            let centre = 1000 * pow(2, (log2(nominal / 1000)).rounded())
            let low = centre / Float(2).squareRoot()
            let high = min(centre * Float(2).squareRoot(), nyquist)
            var power: Float = 0
            for (frequency, level) in zip(spectrum.frequencies, spectrum.decibels) where frequency >= low && frequency < high {
                power += Decibels.toAmplitude(level) * Decibels.toAmplitude(level)
            }
            return Decibels.fromPower(power * scale)
        }
        return SignalToNoise.bandRatios(
            signal: MagnitudeResponse(frequencies: noiseFloor.bandLevels.frequencies, decibels: levels),
            noise: noiseFloor.bandLevels
        )
    }
}
