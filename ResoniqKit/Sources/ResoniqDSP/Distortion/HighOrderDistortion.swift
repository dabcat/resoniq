import Accelerate

/// The power a speaker adds above a high harmonic of the tone, along a sweep, relative to the tone.
///
/// All curves share the sweep's frequency axis (hertz, log-spaced at the analysis hop): a point at `f` describes what
/// the recording held while the sweep was playing `f`. Read them on `ResponseGrid` with `MagnitudeResponse.decibels(at:)`
/// after smoothing, as `SweepDistortion` is read.
public struct SweepHighOrderDistortion: Sendable, Equatable {
    /// At each frequency `f`, the power from just above the `minimumOrder`-th harmonic of `f` to the top of the band,
    /// over the power of the tone itself, in dB. **Gross**: it includes the room's noise in that band, so a clean
    /// speaker reads as its floor, never as nothing; read it with `noiseFloor` and `isMeasurable(at:)`.
    public let level: MagnitudeResponse
    /// What `level` would read from the room's noise alone: the noise-floor recording's power over the same band at
    /// each frequency, over the same tone power, in dB. Same frequencies as `level`. Nil when the floor holds no usable
    /// level (a corrupt floor recording); then nothing is measurable.
    public let noiseFloor: MagnitudeResponse?

    public init(level: MagnitudeResponse, noiseFloor: MagnitudeResponse?) {
        self.level = level
        self.noiseFloor = noiseFloor
    }

    /// `level` at `frequency` hertz, interpolated in log frequency; NaN outside its band, where nothing was read.
    public func levelDecibels(at frequency: Float) -> Float {
        Self.covers(level, frequency) ? level.decibels(at: frequency) : .nan
    }

    /// What noise alone reads at `frequency`; nil where there is no floor.
    public func noiseFloorDecibels(at frequency: Float) -> Float? {
        guard let noiseFloor, Self.covers(noiseFloor, frequency) else { return nil }
        return noiseFloor.decibels(at: frequency)
    }

    /// Whether `level` at `frequency` is a measurement: inside its band and at least
    /// `SweepDistortion.measurableMarginDecibels` above `noiseFloor` there, the same margin THD is held to. When false,
    /// all that is known is that the level is below the floor raised by the margin.
    public func isMeasurable(at frequency: Float) -> Bool {
        guard let floor = noiseFloorDecibels(at: frequency), Self.covers(level, frequency) else { return false }
        return level.decibels(at: frequency) - floor >= SweepDistortion.measurableMarginDecibels
    }

    private static func covers(_ curve: MagnitudeResponse, _ frequency: Float) -> Bool {
        guard let first = curve.frequencies.first, let last = curve.frequencies.last else { return false }
        return frequency >= first && frequency <= last
    }
}

/// Rub and buzz as the energy above the high harmonics, read from the sweep the app already plays.
///
/// A rubbing voice coil or a buzzing part touches once per excursion and adds a burst of sound each cycle: energy far
/// above the tone, at orders the harmonic analysis (`HarmonicDistortion`, orders 2 to 5) does not read. A real unit
/// with strong rub reads 4.2 % THD, under the buzz threshold, but about 18 dB more than a good unit above its tenth
/// harmonic (docs/research/2026-11-14-rub-buzz-recordings.md). This measures that energy.
///
/// **Method: short-time spectra aligned to the sweep.** Once the recording is aligned (`delay`, the linear response's
/// arrival), the sweep's instantaneous frequency at every moment is known: `sweep.frequency(at: t − delay)`. A short
/// Hann frame is cut around each moment and transformed; in it the tone's own lobe gives the tone's power, and
/// everything from just above the `minimumOrder`-th harmonic to the top of the measured band gives the power above
/// the high orders. The sweep rises, so the room's reverberation of what was already played lies *below* the tone,
/// never above it: with a linear room the band above the high orders holds only what the speaker adds, and the
/// room's noise. The noise is read from the noise-floor recording (`NoiseFloorReport.bandLevels`) over the same band,
/// against the same tone power, so a reading counts only where it stands clear of what noise alone would give.
///
/// Why this and not the deconvolved response: after deconvolution, harmonic `n`'s response lands
/// `LogSweep.harmonicAdvance(order:)` before the linear one, and above the tenth they crowd into a few tens of
/// milliseconds that overlap each other's windows; a frame of the recording sees all of them at once, and needs
/// nothing but the sweep's known frequency.
///
/// What it cannot tell you: which part of the chain or the room added the sound (a loose panel or an object on the
/// shelf buzzing along reads the same), or anything about a noise that does not follow the tone; steady noise is held
/// out by the floor, but a noise that rises during the run above the floor measured before it is not.
public enum HighOrderDistortion {
    /// The harmonic above which power is counted, unless told otherwise: 10, as `ToneDistortion.maximumOrder`, so a
    /// steady tone's reading is its non-harmonic residue above the tenth harmonic. Rub and buzz spread over tens of
    /// orders; a healthy speaker's distortion is almost all in the first few.
    public static let defaultMinimumOrder = 10

    /// The frame length, in seconds: 50 ms. **First guess**, a trade between two smearings. The sweep's frequency moves
    /// within a frame by a factor `exp(±frameDuration / 2 · ln(end/start) / duration)`: ±4.9 % for the 4 s measurement
    /// sweep, ±6.6 % for a 3 s one, so the tenth harmonic spreads to 10.5 to 10.7 times the frame's centre frequency.
    /// The Hann window's main lobe adds ±2 / `frameDuration` = ±40 Hz. Shorter frames move the band's edge up at low
    /// frequencies (the lobe), longer ones at all frequencies (the sweep's movement); 50 ms keeps the edge under about
    /// 11.5 times the tone from 40 Hz up, and holds two cycles of the lowest tone read.
    public static let frameDuration: Double = 0.05

    /// The step between frames, as a fraction of `frameDuration`: a quarter, 12.5 ms, which the sweep crosses in
    /// 0.035 octave (measurement sweep) to 0.046 octave (3 s): about the spacing of `ResponseGrid` (0.042 octave), so
    /// smoothing to 1/12 octave averages two to three frames.
    public static let hopFraction: Double = 0.25

    /// The lowest tone, in hertz, at which the level is read: 40 Hz, two cycles in a frame. **First guess**; below it the
    /// tone's lobe reaches DC and a phone's microphone barely hears the tone.
    public static let lowestFrequency: Double = 40

    /// The narrowest band, in octaves, from above the high orders to the top, that is read: a sixth of an octave.
    /// **First guess**, so the top of the range still averages a few tens of bins; with the measurement sweep it ends
    /// the reading at about 1.7 kHz.
    public static let minimumBandOctaves: Double = 1.0 / 6

    /// The top of the band read on a steady tone when no other is given, in hertz: `LogSweep.reportedBand`'s top,
    /// 20 kHz.
    public static let defaultToneUpperFrequency: Double = LogSweep.reportedBand.upperBound

    /// The band, in hertz, read in a frame centred on `frequency`: from above the `minimumOrder`-th harmonic as it moves
    /// within the frame (`spread`, the sweep's half-movement in natural-log units, 0 for a steady tone) and the window's
    /// main lobe, to `upper`. Nil when that leaves less than `minimumBandOctaves`.
    public static func band(
        frequency: Double,
        spread: Double,
        minimumOrder: Int = defaultMinimumOrder,
        upper: Double
    ) -> ClosedRange<Double>? {
        let lower = Double(minimumOrder) * frequency * exp(spread) + mainLobeHalfWidth
        return upper >= lower * pow(2, minimumBandOctaves) ? lower...upper : nil
    }

    /// The highest tone at which the level can be read with `sweep` over a band ending at `upper`.
    public static func upperFrequency(sweep: LogSweep, upper: Double, minimumOrder: Int = defaultMinimumOrder) -> Double {
        (upper * pow(2, -minimumBandOctaves) - mainLobeHalfWidth) / (Double(minimumOrder) * exp(spread(sweep)))
    }

    /// Analyses a recording of `sweep` whose linear response arrives `delay` seconds after the sweep's start
    /// (`ImpulseResponse.delay`), against `noise`, the floor measured at the same gain before the run.
    ///
    /// Frames are centred every `hopFraction · frameDuration` along the sweep, from `lowestFrequency` (or the bottom of
    /// `measuredBand`) to `upperFrequency(sweep:upper:)`, where `upper` is the top of `measuredBand` (default: the
    /// sweep's `trustedBand`) and never past Nyquist. A frame must lie inside the recording and inside the sweep less
    /// its fades. A recording that holds none gives empty curves.
    public static func analyze(
        recording: [Float],
        sweep: LogSweep,
        delay: Double,
        noise: NoiseFloorReport,
        measuredBand: ClosedRange<Double>? = nil,
        minimumOrder: Int = defaultMinimumOrder
    ) -> SweepHighOrderDistortion {
        precondition(minimumOrder >= 2, "the band starts above a harmonic")
        let empty = SweepHighOrderDistortion(level: MagnitudeResponse(frequencies: [], decibels: []), noiseFloor: nil)
        guard let measured = measuredBand ?? sweep.trustedBand, LevelMeter.nonFiniteCount(recording) == 0 else { return empty }
        let sampleRate = sweep.sampleRate
        let upper = min(measured.upperBound, sampleRate / 2)
        let spread = spread(sweep)
        let frame = Frame(sampleRate: sampleRate)
        let hop = frameDuration * hopFraction
        let lowest = max(lowestFrequency, measured.lowerBound)
        let highest = upperFrequency(sweep: sweep, upper: upper, minimumOrder: minimumOrder)
        guard lowest < highest else { return empty }

        var frequencies: [Float] = []
        var levels: [Float] = []
        var floors: [Float] = []
        var time = max(sweep.time(of: lowest), sweep.fadeDuration + frameDuration / 2)
        let last = min(sweep.time(of: highest), sweep.duration - sweep.fadeDuration - frameDuration / 2)
        while time <= last {
            let frequency = sweep.frequency(at: time)
            let centre = Int(((delay + time) * sampleRate).rounded())
            defer { time += hop }
            guard let band = band(frequency: frequency, spread: spread, minimumOrder: minimumOrder, upper: upper),
                  let powers = frame.powers(recording, centre: centre, tone: frequency, spread: spread, band: band),
                  powers.tone > 0
            else { continue }
            frequencies.append(Float(frequency))
            levels.append(Decibels.fromPower(powers.band / powers.tone))
            floors.append(noisePower(noise, in: band).map { Decibels.fromPower($0 / powers.tone) } ?? .nan)
        }
        let floor = floors.allSatisfy(\.isFinite) && !floors.isEmpty
            ? MagnitudeResponse(frequencies: frequencies, decibels: floors)
            : nil
        return SweepHighOrderDistortion(level: MagnitudeResponse(frequencies: frequencies, decibels: levels), noiseFloor: floor)
    }

    /// The same computation on a steady tone near `frequency` hertz: the power from above its `minimumOrder`-th
    /// harmonic to `upper` over the tone's, in dB, averaged over half-overlapping frames of `frameDuration` across the
    /// whole recording (each power summed over the frames before the ratio is taken). Gross, like the sweep's level.
    /// NaN when the recording is shorter than a frame, the tone is not below `upper / minimumOrder`, or it holds no tone.
    ///
    /// The reference case: on a steady tone whose only addition above the tenth harmonic is rub, it agrees with
    /// `ToneDistortionResult.nonHarmonicResidue`.
    public static func steadyTone(
        recording: [Float],
        frequency: Double,
        sampleRate: Double,
        minimumOrder: Int = defaultMinimumOrder,
        upper: Double = defaultToneUpperFrequency
    ) -> Float {
        let frame = Frame(sampleRate: sampleRate)
        let upper = min(upper, sampleRate / 2)
        guard frame.length <= recording.count, LevelMeter.nonFiniteCount(recording) == 0,
              let band = band(frequency: frequency, spread: 0, minimumOrder: minimumOrder, upper: upper)
        else { return .nan }
        var tone: Float = 0
        var above: Float = 0
        var centre = frame.length / 2
        while centre + frame.length - frame.length / 2 <= recording.count {
            if let powers = frame.powers(recording, centre: centre, tone: frequency, spread: 0, band: band) {
                tone += powers.tone
                above += powers.band
            }
            centre += frame.length / 2
        }
        return tone > 0 ? Decibels.fromPower(above / tone) : .nan
    }

    // MARK: - The core

    /// Half the Hann main lobe of a `frameDuration` frame, in hertz: two bins of `1 / frameDuration`.
    static var mainLobeHalfWidth: Double { 2 / frameDuration }

    /// How far, in natural-log units, the sweep's frequency moves from a frame's centre to its edge.
    static func spread(_ sweep: LogSweep) -> Double {
        frameDuration / 2 * sweep.logRatio / sweep.duration
    }

    /// The noise floor's mean-square power in `band`: each octave band's level spread evenly over its width in hertz
    /// and summed over the overlap. Nil when a band it needs is not a number (a corrupt floor) or none covers it.
    static func noisePower(_ noise: NoiseFloorReport, in band: ClosedRange<Double>) -> Float? {
        var power: Double = 0
        var covered = false
        for (centre, level) in zip(noise.bandLevels.frequencies, noise.bandLevels.decibels) {
            let edges = OctaveBands.edges(ofCentre: centre, fraction: 1)
            let overlap = min(Double(edges.upper), band.upperBound) - max(Double(edges.lower), band.lowerBound)
            guard overlap > 0 else { continue }
            guard level.isFinite else { return nil }
            covered = true
            power += pow(10, Double(level) / 10) * overlap / Double(edges.upper - edges.lower)
        }
        return covered ? Float(power) : nil
    }

    /// One frame's transform, set up once per analysis.
    struct Frame {
        let sampleRate: Double
        let length: Int
        let size: Int
        let window: [Float]
        /// Σw², which with the transform's size turns summed bin power into mean-square power.
        let windowPower: Float
        let plan: FFT.Plan

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
            length = max(Int((frameDuration * sampleRate).rounded()), 16)
            size = FFT.nextPowerOfTwo(length)
            window = Window.hann.samples(count: length)
            windowPower = vDSP.sumOfSquares(window)
            plan = FFT.Plan(size: size, inverse: false)
        }

        /// The mean-square power of the tone (its lobe: `tone · exp(±spread)` widened by the main lobe) and of `band`
        /// in the frame centred on sample `centre`; nil when the frame does not lie inside the recording.
        ///
        /// Both are `2 Σ|X[k]|² / (size · Σw²)` over their bins (Parseval, positive frequencies doubled): a sine of
        /// amplitude `A` gives `A²/2` and white noise of variance σ² gives σ² times the band's share of Nyquist, the
        /// convention of `NoiseFloorReport.bandLevels`, so the floor's power and the frame's compare directly.
        func powers(_ recording: [Float], centre: Int, tone: Double, spread: Double, band: ClosedRange<Double>) -> (tone: Float, band: Float)? {
            let start = centre - length / 2
            guard start >= 0, start + length <= recording.count else { return nil }
            let segment = vDSP.multiply(recording[start..<(start + length)], window)
            let spectrum = plan.forward(segment)
            let nyquist = size / 2
            let power = vDSP.add(vDSP.square(spectrum.real[0...nyquist]), vDSP.square(spectrum.imaginary[0...nyquist]))
            let scale = 2 / (Float(size) * windowPower)
            func bins(_ range: ClosedRange<Double>) -> ClosedRange<Int>? {
                let low = max(1, Int((range.lowerBound * Double(size) / sampleRate).rounded(.up)))
                let high = min(nyquist, Int((range.upperBound * Double(size) / sampleRate).rounded(.down)))
                return high >= low ? low...high : nil
            }
            let lobe = (tone * exp(-spread) - mainLobeHalfWidth)...(tone * exp(spread) + mainLobeHalfWidth)
            guard let toneBins = bins(lobe), let bandBins = bins(band) else { return nil }
            return (scale * vDSP.sum(power[toneBins]), scale * vDSP.sum(power[bandBins]))
        }
    }
}
