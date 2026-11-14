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
    /// What `level` would read from noise alone, in dB over the same tone power, at the same frequencies: the higher of
    /// the noise-floor recording's power over the same band (the room before the runs) and the run's own tail's (the
    /// room during it), raised where the run's frames all stand alike over it (`HighOrderDistortion.localMarginDecibels`).
    /// Nil when the recording's tail is too short to read (`HighOrderDistortion.minimumTailFrames`); then nothing is
    /// measurable.
    public let noiseFloor: MagnitudeResponse?
    /// How far each frame's sound above the high orders was locked to the tone (`HighOrderDistortion.lockingThreshold`),
    /// one per point of `level` as `analyze` made it; empty for a result built by hand or smoothed.
    public let locking: [Float]

    public init(level: MagnitudeResponse, noiseFloor: MagnitudeResponse?, locking: [Float] = []) {
        self.level = level
        self.noiseFloor = noiseFloor
        self.locking = locking
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
/// room's noise. The noise is read twice over the same band, against the same tone power: from the noise-floor
/// recording made before the runs (`NoiseFloorReport.bandLevels`), and from the run's own recording after the sweep's
/// end has arrived and the speaker has decayed (`tailGuard`, the last `tailFloorDuration`), as `HarmonicDistortion`
/// reads its floor from the response's tail. The higher counts, so a fridge or a fan that started after the floor was
/// measured is held out. The tail is chosen over a lead-in before the sweep because the app always records it
/// (`HarmonicDistortion.minimumTail`), while the lead-in is only the route's delay, often a few milliseconds. Last, a
/// reading must stand out of the run's own profile (`localMarginDecibels`). It counts only where it stands clear of all
/// of that.
///
/// Why this and not the deconvolved response: after deconvolution, harmonic `n`'s response lands
/// `LogSweep.harmonicAdvance(order:)` before the linear one, and above the tenth they crowd into a few tens of
/// milliseconds that overlap each other's windows; a frame of the recording sees all of them at once, and needs
/// nothing but the sweep's known frequency.
///
/// What it cannot tell you: which part of the chain or the room added the sound (a loose panel or an object on the
/// shelf buzzing along reads the same), or anything about a noise that does not follow the tone. Steady noise is held
/// out by the floors and a noise during the sweep alone by the profile, but a noise that rises over part of the sweep
/// only (a voice, a door) is held out only by the diagnosis's rule that two runs agree on the place.
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

    /// How long after the sweep's end has arrived (`delay + duration`) the run's own noise is read from, in seconds:
    /// `ImpulseResponse.defaultPostWindow`, 0.1 s, where `HarmonicDistortion` starts reading its floor too, so the
    /// speaker's own decay is over. **First guess** for the room's: in a live room the treble's reverberation may still
    /// be there, which raises the floor and errs towards "not a measurement", never towards a finding.
    public static let tailGuard: Double = ImpulseResponse.defaultPostWindow

    /// How much of the recording's end the run's own noise is read from, at most, in seconds: the last 0.1 s, three
    /// half-overlapping frames. **First guess**: the latest stretch, where a live room's decay has died the most; the app
    /// records at least `HarmonicDistortion.minimumTail` (0.205 s) after the sweep's end has arrived, which leaves
    /// 0.105 s past `tailGuard`.
    public static let tailFloorDuration: Double = 0.1

    /// The fewest frames the run's own noise must be read from: 2 (75 ms of tail past `tailGuard`). With fewer the run
    /// has no floor and nothing in it is a measurement.
    public static let minimumTailFrames = 2

    /// How far, in dB, a reading must stand further over its floor than the run's median frame does to count:
    /// 6 dB. **First guess.** A rub or buzz is tied to where the excursion is large, so it lifts the frames of a stretch
    /// of the sweep; a noise that neither floor holds (one that played during the sweep and stopped before its tail)
    /// lifts every frame alike, so the median frame stands as far over its floor as any. The floor is raised by
    /// `median excess + localMarginDecibels − measurableMarginDecibels` when that is positive, so the margin test does
    /// both. It cannot tell a rub that spans most of 40 Hz–1.7 kHz from such a noise (it would not be measured), nor a
    /// coloured noise whose excess falls with frequency from a rub in the bass; the floor from the tail is what holds
    /// steady noise out.
    public static let localMarginDecibels: Float = 6

    /// How far the sound above the high orders must be locked to the tone's cycle (`Frame.locking`: the share of its
    /// power envelope that repeats once or twice per cycle, in both halves of the frame) for a frame to count: 0.3.
    /// **First guess.** A part that touches once per excursion bursts at the same phase of every cycle (the bad real
    /// unit's energy above its tenth harmonic repeats every cycle with a correlation of 0.99), while birdsong, a voice
    /// or the room's decay after a click are not tied to the tone. Below it the whole of the frame's band counts as
    /// noise (the floor is raised to the level), so no finding can rest on it. Noise alone reads about
    /// `1/√(bandwidth · 25 ms)`, under 0.2 for the bands read; the simulated rub reads (see the tests).
    public static let lockingThreshold: Float = 0.3

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

        let tail = tailPower(recording, frame: frame, sweepEnd: delay + sweep.duration, sampleRate: sampleRate)
        // The sweep's phase at a moment τ into it: 2π·f₁·D / ln(f₂/f₁) · (exp(τ·ln(f₂/f₁) / D) − 1).
        let rate = sweep.logRatio / sweep.duration
        let phaseScale = 2 * Double.pi * sweep.startFrequency / rate
        var frequencies: [Float] = []
        var levels: [Float] = []
        var floors: [Float] = []
        var lockings: [Float] = []
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
            // The higher of the two floors: the room before the runs, and the run's own tail. Without the tail, none.
            let before = noisePower(noise, in: band) ?? 0
            let floor = tail.flatMap { frame.sum($0, over: band) }.map { max($0, before) }
            floors.append(floor.map { Decibels.fromPower($0 / powers.tone) } ?? .nan)
            lockings.append(frame.locking(recording, start: centre - frame.length / 2, band: band) { sample in
                phaseScale * (exp((Double(sample) / sampleRate - delay) * rate) - 1)
            } ?? 0)
        }
        let level = MagnitudeResponse(frequencies: frequencies, decibels: levels)
        guard !floors.isEmpty, floors.allSatisfy(\.isFinite) else {
            return SweepHighOrderDistortion(level: level, noiseFloor: nil, locking: lockings)
        }
        // The profile, from the floors alone: a noise neither floor holds lifts every frame alike, a rub only where the
        // excursion is large.
        let excess = zip(levels, floors).map { $0 - $1 }
        let raise = max(0, Statistics.median(excess) + localMarginDecibels - SweepDistortion.measurableMarginDecibels)
        // Then sound not locked to the tone (birdsong, a click's decay, a voice) counts as noise, all of it.
        let floor = floors.indices.map { index in
            lockings[index] < lockingThreshold ? max(floors[index] + raise, levels[index]) : floors[index] + raise
        }
        return SweepHighOrderDistortion(
            level: level, noiseFloor: MagnitudeResponse(frequencies: frequencies, decibels: floor), locking: lockings
        )
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
        let inversePlan: FFT.Plan

        init(sampleRate: Double) {
            self.sampleRate = sampleRate
            length = max(Int((frameDuration * sampleRate).rounded()), 16)
            size = FFT.nextPowerOfTwo(length)
            window = Window.hann.samples(count: length)
            windowPower = vDSP.sumOfSquares(window)
            plan = FFT.Plan(size: size, inverse: false)
            inversePlan = FFT.Plan(size: size, forward: false)
        }

        /// The frame starting at sample `start` as mean-square power per bin, DC to Nyquist: `2|X[k]|² / (size · Σw²)`
        /// (Parseval, positive frequencies doubled), so a sine of amplitude `A` sums to `A²/2` over its lobe and white
        /// noise of variance σ² to σ² times the band's share of Nyquist, the convention of `NoiseFloorReport.bandLevels`:
        /// the floor's power and the frame's compare directly. Nil when the frame does not lie inside the recording.
        func power(_ recording: [Float], start: Int) -> [Float]? {
            guard start >= 0, start + length <= recording.count else { return nil }
            let spectrum = plan.forward(vDSP.multiply(recording[start..<(start + length)], window))
            let nyquist = size / 2
            let power = vDSP.add(vDSP.square(spectrum.real[0...nyquist]), vDSP.square(spectrum.imaginary[0...nyquist]))
            return vDSP.multiply(2 / (Float(size) * windowPower), power)
        }

        /// The power of `power` (from `power(_:start:)`) summed over the bins in `range`, hertz; nil when there are none.
        func sum(_ power: [Float], over range: ClosedRange<Double>) -> Float? {
            let nyquist = size / 2
            let low = max(1, Int((range.lowerBound * Double(size) / sampleRate).rounded(.up)))
            let high = min(nyquist, Int((range.upperBound * Double(size) / sampleRate).rounded(.down)))
            return high >= low ? vDSP.sum(power[low...high]) : nil
        }

        /// How far the sound in `band`, in the frame starting at sample `start`, is locked to the tone: the band is
        /// isolated (its bins kept, the rest zeroed, transformed back), its power envelope `e(n)` taken, and for each half
        /// of the frame the larger of `|Σ e(n)·exp(i·k·phase(n))| / Σ e(n)` for k = 1 and 2 (bursts once or twice per
        /// cycle); the smaller half is the result, so one click in one half does not count as locked. 1 for bursts at the
        /// same phase of every cycle, about `1/√(bandwidth · half-frame)` for noise. Nil outside the recording.
        func locking(_ recording: [Float], start: Int, band: ClosedRange<Double>, phase: (Int) -> Double) -> Float? {
            guard start >= 0, start + length <= recording.count else { return nil }
            let spectrum = plan.forward(vDSP.multiply(recording[start..<(start + length)], window))
            let nyquist = size / 2
            let low = max(1, Int((band.lowerBound * Double(size) / sampleRate).rounded(.up)))
            let high = min(nyquist - 1, Int((band.upperBound * Double(size) / sampleRate).rounded(.down)))
            guard high >= low else { return nil }
            var real = [Float](repeating: 0, count: size)
            var imaginary = [Float](repeating: 0, count: size)
            for bin in low...high {
                real[bin] = spectrum.real[bin]
                imaginary[bin] = spectrum.imaginary[bin]
                real[size - bin] = spectrum.real[size - bin]
                imaginary[size - bin] = spectrum.imaginary[size - bin]
            }
            let isolated = inversePlan.inverse(ComplexSpectrum(real: real, imaginary: imaginary))
            let envelope = vDSP.square(isolated[0..<length])
            func locked(_ range: Range<Int>) -> Float {
                let total = envelope[range].reduce(0, +)
                guard total > 0 else { return 0 }
                return [1.0, 2.0].map { k in
                    var c = 0.0
                    var s = 0.0
                    for n in range {
                        let angle = k * phase(start + n)
                        c += Double(envelope[n]) * cos(angle)
                        s += Double(envelope[n]) * sin(angle)
                    }
                    return Float((c * c + s * s).squareRoot()) / total
                }.max()!
            }
            return min(locked(0..<(length / 2)), locked((length / 2)..<length))
        }

        /// The mean-square power of the tone (its lobe: `tone · exp(±spread)` widened by the main lobe) and of `band`
        /// in the frame centred on sample `centre`; nil when the frame does not lie inside the recording.
        func powers(_ recording: [Float], centre: Int, tone: Double, spread: Double, band: ClosedRange<Double>) -> (tone: Float, band: Float)? {
            guard let power = power(recording, start: centre - length / 2) else { return nil }
            let lobe = (tone * exp(-spread) - mainLobeHalfWidth)...(tone * exp(spread) + mainLobeHalfWidth)
            guard let tonePower = sum(power, over: lobe), let bandPower = sum(power, over: band) else { return nil }
            return (tonePower, bandPower)
        }
    }

    /// The mean power spectrum (as `Frame.power`) of the recording's own noise: half-overlapping frames over the last
    /// `tailFloorDuration` of the recording, none starting before `tailGuard` after the sweep's end has arrived. Nil
    /// when fewer than `minimumTailFrames` fit.
    static func tailPower(_ recording: [Float], frame: Frame, sweepEnd: Double, sampleRate: Double) -> [Float]? {
        let earliest = Int(((sweepEnd + tailGuard) * sampleRate).rounded(.up))
        var start = max(earliest, recording.count - Int((tailFloorDuration * sampleRate).rounded()))
        var total: [Float]?
        var frames = 0
        while let power = frame.power(recording, start: start) {
            total = total.map { vDSP.add($0, power) } ?? power
            frames += 1
            start += frame.length / 2
        }
        guard frames >= minimumTailFrames, let total else { return nil }
        return vDSP.divide(total, Float(frames))
    }
}
