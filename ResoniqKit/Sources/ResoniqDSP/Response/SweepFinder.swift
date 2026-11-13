import Accelerate

/// One occurrence of a sweep found in a long recording.
public struct FoundSweep: Sendable, Equatable {
    /// Where the sweep's first sample arrived, in samples from the recording's first sample, refined between samples:
    /// the peak of the sweep's matched filter, so the route's and the room's delay are included, as in
    /// `ImpulseResponse.delay`. Negative when the sweep began before the recording did.
    public var start: Double
    /// How far the matched filter's peak stands over the filter's output around it, in dB: about the recording's
    /// signal-to-noise ratio plus the sweep's processing gain, less the envelope's averaging. At least
    /// `SweepFinder.minimumStrength` for anything returned.
    public var strength: Float
    /// Whether the whole sweep lies inside the recording: its start is not before the recording's first sample and its
    /// end, allowing for `SweepFinder.maximumClockOffset`, is not after the last.
    public var isComplete: Bool

    public init(start: Double, strength: Float, isComplete: Bool) {
        self.start = start
        self.strength = strength
        self.isComplete = isComplete
    }
}

/// Finds a known sweep in a recording made without any timing: the phone only listens while another device plays a
/// file of sweeps at an unknown moment, through an unknown route, on a clock that is not the phone's.
///
/// **Method.** A matched filter: the recording is correlated with the sweep whitened by its own spectrum
/// (`S / (|S|² + ε)`, limited to `detectionBand`), which turns each occurrence into a short peak, its impulse
/// response, whatever its position. The filter runs by overlap-save on blocks, so a minute of recording is a handful
/// of large transforms. A peak counts when its short-time energy (`envelopeDuration`) stands `minimumStrength` over
/// the median energy of the second and a half around it, so a recording that is louder in places (music, a voice)
/// does not raise peaks by its loudness alone. Peaks closer than the sweep's length are one sweep (the harmonics of a
/// distorting speaker arrive before the linear response, inside that span).
///
/// **What rejects what.** Stationary sound (pink noise, a hum, a held note) passes through the matched filter as
/// stationary sound and makes no peak. Music makes no peak either: only a rising exponential chirp with this sweep's
/// rate is compressed into one.
///
/// **The player's clock.** A player whose clock runs fast by a ratio `r` plays the sweep `r` times shorter. Seen by
/// the matched filter, that is a dispersion: the treble arrives up to `r − 1` times the sweep's duration (2 ms at
/// 500 ppm) earlier than the bass. The envelope is wider than that, so detection is unaffected; the position is the
/// peak's, consistently biased for every sweep of one play, so the spacing of two sweeps on one path gives the ratio
/// exactly (`clockRatio(starts:expectedSpacing:sampleRate:)`). One sweep alone cannot give it robustly: stretching an
/// exponential sweep in time is the same as shifting it, except for a delay that grows with frequency, and a
/// speaker's own phase (a crossover, the bass roll-off) makes delays of the same size (a search for the sharpest peak
/// was tried and missed by up to 360 ppm on a speaker with one all-pass crossover). So every test sound file starts
/// with a steady clock tone, whose frequency gives the ratio to a fraction of a ppm
/// (`clockRatio(ofTone:sampleRate:)`). `corrected(_:ratio:)` undoes a known ratio before deconvolution; uncorrected,
/// a slow player's bass arrives before the response's peak by more than the analysis window keeps (−4 dB at 500 Hz at
/// −500 ppm), so a run is never analysed without it.
public enum SweepFinder {
    /// The band the matched filter listens in, hertz: above most rumble and below the top octave, where a phone's
    /// microphone and a small speaker both still do well. *First guess*.
    public static let detectionBand: ClosedRange<Double> = 150...12000
    /// The envelope's length, seconds: wide enough to hold a peak dispersed by `maximumClockOffset` (4 ms at 1000
    /// ppm for a 4 s sweep), short enough to stay sharp.
    public static let envelopeDuration: Double = 0.005
    /// How far the envelope of a peak must stand over its surroundings, dB, to be a candidate. Pink noise stays under
    /// it; a synthetic tune with gliding notes reached 16 dB over a minute, which the band check
    /// (`verificationBands`) then rejected; a sweep through a speaker in room noise makes 60 dB. *First guess*,
    /// checked only against simulated input.
    public static let minimumStrength: Float = 13
    /// The surroundings a peak is measured against, seconds on each side, and the span next to the peak left out of
    /// them (the room's reverberation of the sweep itself).
    public static let surroundings: Double = 1.5
    public static let surroundingsGuard: Double = 0.15
    /// The largest clock offset accepted, as a fraction: 1000 ppm. Players keep within ±100 ppm, cheap ones ±500;
    /// beyond 1000 something resamples the file wrongly (playing 48 kHz as 44.1 kHz is 8.8 %), its sound is
    /// pitch-shifted, and a run is invalid. Corrected, offsets up to this are measured as accurately as none; see
    /// `docs/modules/ResoniqDSP.md` for the figures.
    public static let maximumClockOffset: Double = 0.001

    /// Every occurrence of `sweep` in `recording`, by position, strongest kept first when there are more than
    /// `expectedCount` (nil: all of them). Both are at `sampleRate`, which must be the sweep's.
    ///
    /// - Parameter anchored: Whether the caller already knows from the file's timing that a sweep is due in
    ///   `recording` (it follows the clock tone, or another sweep, at the file's interval). An anchored candidate need
    ///   only be there in two neighbouring `verificationBands` instead of all but one, so the sweep of a speaker that
    ///   plays only part of the range (a dead tweeter, a dead woofer, a small speaker) is still found; an unanchored
    ///   one must span the range, so music and noise are not taken for a sweep. See `spansEveryBand`.
    public static func find(
        in recording: [Float],
        sampleRate: Double,
        sweep: LogSweep,
        expectedCount: Int? = nil,
        anchored: Bool = false
    ) -> [FoundSweep] {
        precondition(sampleRate == sweep.sampleRate, "the recording and the sweep differ in sample rate")
        let sweepSamples = sweep.samples()
        guard !recording.isEmpty, !sweepSamples.isEmpty, LevelMeter.nonFiniteCount(recording) == 0 else { return [] }
        let correlation = matchedFilter(recording, sweepSamples: sweepSamples, sweep: sweep)
        // Index i of `correlation` is a start at i − sweep length.
        let offset = sweepSamples.count
        let window = max(1, Int((envelopeDuration * sampleRate).rounded()))
        let energy = vDSP.square(correlation)
        guard energy.count > window else { return [] }
        let envelope = vDSP.slidingWindowSum(energy, usingWindowLength: window)

        // Blocks of 50 ms: each block's peak against the median of the block means around it.
        let blockLength = max(window, Int((0.05 * sampleRate).rounded()))
        let blockCount = envelope.count / blockLength
        guard blockCount > 0 else { return [] }
        var means = [Float](repeating: 0, count: blockCount)
        var peaks = [Float](repeating: 0, count: blockCount)
        var peakIndices = [Int](repeating: 0, count: blockCount)
        envelope.withUnsafeBufferPointer { buffer in
            for block in 0..<blockCount {
                let slice = UnsafeBufferPointer(rebasing: buffer[(block * blockLength)..<((block + 1) * blockLength)])
                means[block] = vDSP.mean(slice)
                let (index, value) = vDSP.indexOfMaximum(slice)
                peaks[block] = value
                peakIndices[block] = block * blockLength + Int(index)
            }
        }
        let reach = Int((surroundings / 0.05).rounded())
        let guardBlocks = Int((surroundingsGuard / 0.05).rounded(.up))
        // A floor far under any real noise, so the silence of the padding past the recording's ends (or a digital
        // silence) never makes a ratio of its own.
        let floor = max(means.max() ?? 0, Float.leastNormalMagnitude) * 1e-9
        var candidates: [(index: Int, strength: Float)] = []
        for block in 0..<blockCount {
            // Each side's median, and the louder of the two: a peak stands over both sides, while the top of a
            // slope (the noise fading where the recording ends) stands over one only.
            let before = Array(means[max(0, block - reach)..<max(0, block - guardBlocks)])
            let after = Array(means[min(blockCount, block + guardBlocks + 1)..<min(blockCount, block + reach + 1)])
            let sides = [before, after].filter { $0.count >= 5 }
            guard !sides.isEmpty else { continue }
            let level = max(sides.map(Statistics.median).max() ?? 0, floor)
            let strength = Decibels.fromPower(peaks[block] / level)
            if strength >= minimumStrength { candidates.append((peakIndices[block], strength)) }
        }

        // One sweep per sweep length, the strongest; the rest are its harmonics, its reverberation or its neighbours.
        candidates.sort { $0.strength > $1.strength }
        // Each is then checked band by band, so a chirp that matches the sweep over part of its range only (a
        // gliding note in music) is not taken for it.
        var kept: [(index: Int, strength: Float)] = []
        var rejected: [Int] = []
        for candidate in candidates where !kept.contains(where: { abs($0.index - candidate.index) < offset }) {
            if rejected.contains(where: { abs($0 - candidate.index) < blockLength }) { continue }
            guard spansEveryBand(recording, start: candidate.index - offset, sweep: sweep, sweepSamples: sweepSamples, anchored: anchored) else {
                rejected.append(candidate.index)
                continue
            }
            kept.append(candidate)
            if let expectedCount, kept.count == expectedCount { break }
        }

        let span = Double(sweepSamples.count) * (1 + maximumClockOffset)
        return kept.map { candidate -> FoundSweep in
            // The envelope's window ends at its index; the peak sample lies inside it.
            let first = max(0, candidate.index)
            let last = min(correlation.count - 1, candidate.index + window)
            var best = first
            for index in first...last where abs(correlation[index]) > abs(correlation[best]) { best = index }
            let start = Double(best - offset) + parabolicOffset(correlation, at: best)
            return FoundSweep(start: start, strength: candidate.strength, isComplete: start >= 0 && start + span <= Double(recording.count))
        }
        .sorted { $0.start < $1.start }
    }

    /// The player's clock against the phone's (above 1: the player runs fast and the sweeps arrive closer together),
    /// from where sweeps of one play on one path were found and the spacing the file puts between consecutive ones,
    /// in seconds. Sweeps that were missed are allowed for: each spacing is rounded to a whole number of the
    /// expected one. Nil with fewer than two starts, or when a spacing is not within 10 % of a whole number of
    /// expected spacings (the sweeps are not consecutive sweeps of one such file).
    public static func clockRatio(starts: [Double], expectedSpacing: Double, sampleRate: Double) -> Double? {
        let sorted = starts.sorted()
        guard sorted.count >= 2, expectedSpacing > 0 else { return nil }
        let spacing = expectedSpacing * sampleRate
        // A least-squares line through (expected step, observed position).
        var steps: [Double] = [0]
        for index in 1..<sorted.count {
            let observed = (sorted[index] - sorted[index - 1]) / spacing
            let whole = observed.rounded()
            guard whole >= 1, abs(observed - whole) < 0.1 else { return nil }
            steps.append(steps[index - 1] + whole)
        }
        let meanStep = steps.reduce(0, +) / Double(steps.count)
        let meanStart = sorted.reduce(0, +) / Double(sorted.count)
        var covariance = 0.0
        var variance = 0.0
        for (step, start) in zip(steps, sorted) {
            covariance += (step - meanStep) * (start - meanStart)
            variance += (step - meanStep) * (step - meanStep)
        }
        guard variance > 0 else { return nil }
        let observedSpacing = covariance / variance
        return observedSpacing > 0 ? spacing / observedSpacing : nil
    }

    /// The clock tone every test sound file carries before its sweeps: a steady sine, played on one path, whose
    /// frequency the phone measures to read the player's clock (`clockRatio(ofTone:sampleRate:)`). 1 kHz, which any
    /// speaker plays well; 2 s; at −18 dBFS, under the sweep's safe level.
    public static let clockToneFrequency: Double = 1000
    public static let clockToneDuration: Double = 2
    public static let clockToneAmplitude: Float = 0.125
    /// The least steady tone `clockRatio(ofTone:sampleRate:)` reads, seconds, after its ends are trimmed.
    public static let minimumToneDuration: Double = 0.8

    /// The player's clock against the phone's from a recording of the clock tone: the tone's frequency over
    /// `clockToneFrequency`. Its phase, demodulated at the nominal frequency in 10 ms steps, turns at the frequency
    /// offset; a straight line through it gives the offset. A room changes the tone's level and phase but not its
    /// frequency, so the estimate is as good in a room as at the speaker: within 1 ppm at a signal-to-noise ratio of
    /// 20 dB (measured). A phone moving towards or away from the speaker adds its Doppler shift, 30 ppm per cm/s, so it
    /// must be held still. Reads the part of `samples` where the tone is at least half its loudest, less 0.2 s at each
    /// end; nil when that is shorter than `minimumToneDuration`, the phase does not follow a line (no tone, or two), or
    /// the offset is beyond twice `maximumClockOffset`.
    public static func clockRatio(ofTone samples: [Float], sampleRate: Double) -> Double? {
        readClockTone(samples, sampleRate: sampleRate)?.ratio
    }

    /// What `clockRatio(ofTone:sampleRate:)` reads, and where the tone began: the first 10 ms step at which it
    /// reached half its level, in samples from the start of `samples` (good to about 10 ms, the fade and the room's
    /// build-up included). The listening sessions tell the files apart by the time from this onset to the first sweep.
    public static func readClockTone(_ samples: [Float], sampleRate: Double) -> (ratio: Double, onset: Double)? {
        let step = max(1, Int((0.01 * sampleRate).rounded()))
        let chunks = samples.count / step
        guard chunks >= 4, LevelMeter.nonFiniteCount(samples) == 0 else { return nil }
        let omega = 2 * Double.pi * clockToneFrequency / sampleRate
        let phases = vDSP.ramp(withInitialValue: 0, increment: omega, count: samples.count)
        let signal = vDSP.floatToDouble(samples)
        let inPhase = vDSP.multiply(signal, vForce.cos(phases))
        let quadrature = vDSP.multiply(signal, vForce.sin(phases))
        var points: [(real: Double, imaginary: Double)] = []
        points.reserveCapacity(chunks)
        for chunk in 0..<chunks {
            let range = (chunk * step)..<((chunk + 1) * step)
            points.append((vDSP.mean(inPhase[range]), -vDSP.mean(quadrature[range])))
        }
        let magnitudes = points.map { ($0.real * $0.real + $0.imaginary * $0.imaginary).squareRoot() }
        guard let loudest = magnitudes.max(), loudest > 0 else { return nil }
        guard let first = magnitudes.firstIndex(where: { $0 >= loudest / 2 }),
              let last = magnitudes.lastIndex(where: { $0 >= loudest / 2 }) else { return nil }
        let trim = Int((0.2 / 0.01).rounded())
        let steady = (first + trim)...max(first + trim, last - trim)
        let seconds = Double(steady.count) * Double(step) / sampleRate
        guard seconds >= minimumToneDuration, magnitudes[steady].allSatisfy({ $0 >= loudest / 4 }) else { return nil }
        // Unwrapped phase against time, and a straight line through it.
        var unwrapped: [Double] = []
        var previous = 0.0
        var turns = 0.0
        for index in steady {
            let phase = atan2(points[index].imaginary, points[index].real)
            if !unwrapped.isEmpty {
                var delta = phase - previous
                while delta > Double.pi { delta -= 2 * Double.pi; turns -= 2 * Double.pi }
                while delta < -Double.pi { delta += 2 * Double.pi; turns += 2 * Double.pi }
            }
            previous = phase
            unwrapped.append(phase + turns)
        }
        let times = steady.map { (Double($0) + 0.5) * Double(step) / sampleRate }
        let meanTime = times.reduce(0, +) / Double(times.count)
        let meanPhase = unwrapped.reduce(0, +) / Double(unwrapped.count)
        var covariance = 0.0
        var variance = 0.0
        for (time, phase) in zip(times, unwrapped) {
            covariance += (time - meanTime) * (phase - meanPhase)
            variance += (time - meanTime) * (time - meanTime)
        }
        guard variance > 0 else { return nil }
        let slope = covariance / variance
        var residual = 0.0
        for (time, phase) in zip(times, unwrapped) {
            let error = phase - meanPhase - slope * (time - meanTime)
            residual += error * error
        }
        // A tone follows its line within a few hundredths of a radian; noise or two tones do not.
        guard (residual / Double(times.count)).squareRoot() < 0.3 else { return nil }
        let ratio = 1 + slope / (2 * Double.pi) / clockToneFrequency
        guard abs(ratio - 1) <= 2 * maximumClockOffset else { return nil }
        return (ratio, Double(first * step))
    }

    /// Whether `ratio` is close enough to 1 to be corrected and measured: within `maximumClockOffset`.
    public static func isCorrectable(_ ratio: Double) -> Bool {
        ratio.isFinite && abs(ratio - 1) <= maximumClockOffset
    }

    /// `segment` as the phone would have recorded it had the player's clock been its own: resampled so that a sweep
    /// played `ratio` times fast is stretched back to its length (`Interpolation`). Deconvolve the result against the
    /// nominal sweep. A ratio of 1 returns the segment unchanged.
    public static func corrected(_ segment: [Float], ratio: Double) -> [Float] {
        precondition(ratio > 0 && ratio.isFinite, "the clock ratio must be a positive number")
        guard ratio != 1, !segment.isEmpty else { return segment }
        let count = Int((Double(segment.count - 1) * ratio).rounded(.down)) + 1
        return Interpolation.resample(segment, from: 0, step: 1 / ratio, count: count)
    }

    // MARK: - The matched filter

    /// The recording correlated with the whitened sweep, for every start from one sweep length before the recording
    /// to its end: index `i` is a start at `i − sweepSamples.count`.
    static func matchedFilter(_ recording: [Float], sweepSamples: [Float], sweep: LogSweep) -> [Float] {
        let length = sweepSamples.count
        let outputs = recording.count + length
        // Overlap-save: a block of `size` input samples gives `size − length` outputs.
        let size = min(FFT.nextPowerOfTwo(4 * length), FFT.nextPowerOfTwo(outputs + length))
        let valid = size - length
        let plan = FFT.Plan(size: size)
        let filter = whitenedFilter(plan.forward(sweepSamples), sweep: sweep, size: size)
        var output = [Float](repeating: 0, count: outputs)
        var first = 0
        while first < outputs {
            // Output i reads the padded recording (length zeros, then the recording) from i to i + length.
            var block = [Float](repeating: 0, count: size)
            let from = max(0, first - length)
            let to = min(recording.count, first - length + size)
            if from < to {
                let at = from - (first - length)
                block.replaceSubrange(at..<(at + to - from), with: recording[from..<to])
            }
            let correlation = correlate(plan.forward(block), with: filter, plan: plan)
            let count = min(valid, outputs - first)
            output.replaceSubrange(first..<(first + count), with: correlation[0..<count])
            first += count
        }
        return output
    }

    /// The inverse transform of `spectrum · conj(filter)`: the signal correlated with the filter, lag by lag.
    static func correlate(_ spectrum: ComplexSpectrum, with filter: ComplexSpectrum, plan: FFT.Plan) -> [Float] {
        let real = vDSP.add(vDSP.multiply(spectrum.real, filter.real), vDSP.multiply(spectrum.imaginary, filter.imaginary))
        let imaginary = vDSP.subtract(vDSP.multiply(spectrum.imaginary, filter.real), vDSP.multiply(spectrum.real, filter.imaginary))
        return plan.inverse(ComplexSpectrum(real: real, imaginary: imaginary))
    }

    /// The bands a candidate is checked in (`spansEveryBand`), hertz: `detectionBand` in four, each about 1.6
    /// octaves, so a match over one or two octaves only fails at least two of them.
    public static let verificationBands: [ClosedRange<Double>] = [150...500, 500...1500, 1500...4500, 4500...12000]
    /// How far a band's matched-filter peak must stand over the largest output around it (from 20 ms to a quarter of
    /// a second away on either side), dB, for the band to agree. A sweep's band is a short peak; music and noise in
    /// that band are smeared over the band's quarter to half second of sweep. *First guess*.
    public static let minimumBandStrength: Float = 6

    /// The finer bands an anchored candidate is checked in: `detectionBand` in eight of about 0.8 octave each, so how
    /// much of the range agrees is counted closely. A band partly covered can agree, so a chirp of one octave touches
    /// two or three of them.
    public static let anchoredBands: [ClosedRange<Double>] = {
        let low = detectionBand.lowerBound
        let ratio = pow(detectionBand.upperBound / low, 1.0 / 8)
        return (0..<8).map { low * pow(ratio, Double($0))...low * pow(ratio, Double($0 + 1)) }
    }()
    /// Neighbouring `anchoredBands` that must agree for an anchored candidate: 4, about 3.2 octaves of the sweep at
    /// its exact rate and timing. A speaker playing only 200 Hz to 2 kHz still makes five (three whole, two edges);
    /// an exact-rate glide of an octave and a half after a 1 kHz tone is refused (`FaultySpeakerFinderTests`). *First guess*.
    public static let minimumAnchoredBands = 4

    /// Whether a sweep starting at `start` (in recording samples) is there across the verification bands whose part of
    /// the sweep the recording holds. Each band's matched filter must peak within 5 ms of `start` (room for a
    /// dispersion of `maximumClockOffset`) by `minimumBandStrength`.
    ///
    /// **The rule.** Unanchored: every band, all but one when there are three or more, so only something that rises
    /// at the sweep's rate over most of 150 Hz to 12 kHz passes; a gliding note covers an octave or two. Anchored (the
    /// file's timing says a sweep is due): `minimumAnchoredBands` neighbouring `anchoredBands`, about three octaves at the
    /// sweep's exact rate and timing, so a speaker missing its tweeter (nothing above 2 kHz), its woofer (nothing
    /// under 500 Hz) or both (200 Hz to 2 kHz) is still found, while a tone followed by a glissando is not. A speaker
    /// heard only under 150 Hz (a subwoofer alone) is never found: the detection band starts there. A sweep cut so
    /// short that fewer than two bands are held cannot be checked and passes; it is not complete anyway.
    static func spansEveryBand(_ recording: [Float], start: Int, sweep: LogSweep, sweepSamples: [Float], anchored: Bool = false) -> Bool {
        let length = sweepSamples.count
        let sampleRate = sweep.sampleRate
        let available = (anchored ? anchoredBands : verificationBands).filter { band in
            let opening = Double(start) + sweep.time(of: band.lowerBound) * sampleRate
            let closing = Double(start) + sweep.time(of: band.upperBound) * sampleRate
            return opening >= 0 && closing <= Double(recording.count)
        }
        guard available.count >= 2 else { return true }
        let around = Int((0.25 * sampleRate).rounded())
        let first = max(0, start - around)
        let last = min(recording.count, start + length + around)
        guard last > first else { return false }
        let lag = start - first
        let plan = FFT.Plan(size: FFT.nextPowerOfTwo(last - first + length + around))
        let spectrum = plan.forward(Array(recording[first..<last]))
        let sweepSpectrum = plan.forward(sweepSamples)
        let reach = Int((0.005 * sampleRate).rounded())
        let exclusion = Int((0.02 * sampleRate).rounded())
        func value(_ power: [Float], at offset: Int) -> Float {
            power[((lag + offset) % plan.size + plan.size) % plan.size]
        }
        var agreeing: [Bool] = []
        for band in available {
            let filter = whitenedFilter(sweepSpectrum, sweep: sweep, size: plan.size, band: band)
            let power = vDSP.square(correlate(spectrum, with: filter, plan: plan))
            let peak = (-reach...reach).map { value(power, at: $0) }.max() ?? 0
            let nearby = stride(from: exclusion, through: around, by: 2).map { max(value(power, at: $0), value(power, at: -$0)) }.max() ?? 0
            agreeing.append(peak > 0 && Decibels.fromPower(peak / max(nearby, .leastNormalMagnitude)) >= minimumBandStrength)
        }
        if anchored {
            // The longest run of neighbouring bands that agree. `available` keeps the table's order and drops bands
            // only at its ends, so neighbours in it are neighbours in the table.
            var longest = 0
            var run = 0
            for agrees in agreeing {
                run = agrees ? run + 1 : 0
                longest = max(longest, run)
            }
            return longest >= minimumAnchoredBands
        }
        let count = agreeing.filter { $0 }.count
        return count >= (available.count >= 3 ? available.count - 1 : available.count)
    }

    /// `S / (|S|² + ε)` on `size` bins from the sweep's spectrum `spectrum`, inside `band` (`detectionBand` unless
    /// given; with a sixth of an octave's raised-cosine edge) and zero outside it, with ε a thousandth of the sweep's
    /// mean power in the band.
    static func whitenedFilter(
        _ spectrum: ComplexSpectrum,
        sweep: LogSweep,
        size: Int,
        band requested: ClosedRange<Double> = detectionBand
    ) -> ComplexSpectrum {
        var real = [Float](repeating: 0, count: size)
        var imaginary = [Float](repeating: 0, count: size)
        let band = max(requested.lowerBound, sweep.startFrequency)...min(requested.upperBound, sweep.endFrequency)
        let low = max(1, FFT.bin(nearest: band.lowerBound, size: size, sampleRate: sweep.sampleRate))
        let high = min(size / 2 - 1, FFT.bin(nearest: band.upperBound, size: size, sampleRate: sweep.sampleRate))
        guard low < high else { return ComplexSpectrum(real: real, imaginary: imaginary) }
        let bandReal = Array(spectrum.real[low...high])
        let bandImaginary = Array(spectrum.imaginary[low...high])
        let power = vDSP.add(vDSP.square(bandReal), vDSP.square(bandImaginary))
        let epsilon = 1e-3 * vDSP.mean(power)
        guard epsilon > 0 else { return ComplexSpectrum(real: real, imaginary: imaginary) }
        var gain = vDSP.divide(1, vDSP.add(epsilon, power))
        // The raised-cosine edges, a sixth of an octave wide; the bins between keep their gain.
        let edge = pow(2, 1.0 / 6)
        let binWidth = sweep.sampleRate / Double(size)
        let lowEdgeEnd = min(high, Int((band.lowerBound * edge / binWidth).rounded(.up)))
        let highEdgeStart = max(low, Int((band.upperBound / edge / binWidth).rounded(.down)))
        for bin in Array(low...lowEdgeEnd) + Array(highEdgeStart...high) {
            let frequency = Double(bin) * binWidth
            let taper = RaisedCosine.rise(log(frequency / band.lowerBound), over: log(edge))
                * RaisedCosine.rise(log(band.upperBound / frequency), over: log(edge))
            gain[bin - low] *= Float(taper)
        }
        let filteredReal = vDSP.multiply(bandReal, gain)
        let filteredImaginary = vDSP.multiply(bandImaginary, gain)
        real.replaceSubrange(low...high, with: filteredReal)
        imaginary.replaceSubrange(low...high, with: filteredImaginary)
        // The conjugate mirror, so the filter is real.
        real.replaceSubrange((size - high)...(size - low), with: filteredReal.reversed())
        imaginary.replaceSubrange((size - high)...(size - low), with: vDSP.negative(filteredImaginary).reversed())
        return ComplexSpectrum(real: real, imaginary: imaginary)
    }

    /// The offset, in samples, of the summit of a parabola through `values[index]`'s magnitude and its neighbours.
    static func parabolicOffset(_ values: [Float], at index: Int) -> Double {
        guard index > 0, index + 1 < values.count else { return 0 }
        let before = abs(values[index - 1])
        let centre = abs(values[index])
        let after = abs(values[index + 1])
        let curvature = before - 2 * centre + after
        return curvature < 0 ? Double(0.5 * (before - after) / curvature) : 0
    }
}
