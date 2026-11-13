import Accelerate

/// How long sound in one frequency band took to die away, read from an impulse response, and what the reading
/// rests on. Always an estimate: a phone microphone, one position, an uncalibrated level.
public struct DecayEstimate: Sendable, Equatable {
    /// The part of the Schroeder curve a decay time is fitted over, ISO 3382-1 §A.2: from 5 dB under the start
    /// to 25 dB under it (T20) or to 35 dB under it (T30), extrapolated to 60 dB.
    public enum EvaluationRange: Sendable, Equatable {
        case t20
        case t30

        /// Decibels under the start where the fit begins: −5.
        public var top: Double { -5 }
        /// Decibels under the start where the fit ends: −25 for T20, −35 for T30.
        public var bottom: Double { self == .t20 ? -25 : -35 }
    }

    /// The band, in hertz, the impulse response was filtered to.
    public let band: ClosedRange<Double>
    /// The time to decay by 60 dB (RT60), in seconds, extrapolated from `evaluationRange`.
    public let seconds: Double
    public let evaluationRange: EvaluationRange
    /// How far, in dB, the band's decay starts above the noise it ends in (the start is the loudest
    /// `Decay.blockDuration(of:sampleRate:)` block, the noise the mean after the decay).
    public let dynamicRangeDecibels: Double
    /// How far the decay curve is from a straight line over the evaluation range, in per mille: ISO 3382-2
    /// Annex B's ξ = 1000·(1 − r²), with r the correlation of the fit. A curved decay (two slopes, a mode beating
    /// against the rest of the room) reads high, and its single figure means less. ISO 3382-2 calls a decay over
    /// 10 ‰ curved, but that is for broad bands: a perfectly exponential decay of random sound reads 5–20 ‰ in an
    /// octave at 500 Hz and 10–70 ‰ in the bass, where the band holds few independent fluctuations, so no limit is
    /// applied here.
    public let nonlinearity: Double

    public init(
        band: ClosedRange<Double>,
        seconds: Double,
        evaluationRange: EvaluationRange,
        dynamicRangeDecibels: Double,
        nonlinearity: Double
    ) {
        self.band = band
        self.seconds = seconds
        self.evaluationRange = evaluationRange
        self.dynamicRangeDecibels = dynamicRangeDecibels
        self.nonlinearity = nonlinearity
    }
}

/// The decay time of a room, band by band, from an impulse response.
///
/// Method, per band:
/// 1. **Band filter.** The response from its linear peak to the end of what holds data (below) is filtered in the
///    frequency domain by a real, even gain: 1 inside the band, a raised cosine in log frequency
///    `filterSkirtOctaves` wide centred on each edge (−6 dB at the edge), 0 beyond. Zero phase, so the filter
///    adds no delay and its own ringing is split evenly before and after each arrival rather than all trailing
///    it, which is what lengthens a decay read through a causal filter (Jacobsen and Rindel, 1987); the smooth
///    skirts keep that ringing short. The response is zero-padded to twice its length, so nothing wraps.
/// 2. **Noise and truncation** (Lundeby et al., 1995). The squared response is averaged in blocks; the noise is the
///    mean square after the decay; a line fitted to the block levels from the loudest down to 10 dB above the noise
///    meets the noise at the crossing point. The noise is re-read from 5 dB past the crossing (and at least the
///    last `noiseTailFraction`), and the line refitted, `lundebyIterations` times at most.
/// 3. **Schroeder integration** (Schroeder, 1965). The squared response is integrated backwards from the crossing
///    point, plus the energy the fitted line holds beyond it, so the curve neither bends up into the noise nor
///    drops at the cut.
/// 4. **Fit.** A least-squares line through the curve over T30 when the dynamic range allows it
///    (`minimumDynamicRangeT30`), otherwise T20 (`minimumDynamicRangeT20`), extrapolated to 60 dB.
///
/// Where the data ends. An impulse response from `Deconvolution` holds, at a time τ after time zero and a frequency
/// F, what the recording held at τ plus the moment the sweep played F. Past the recording's end, the response is
/// empty, not quiet, and reading that as the noise would make any decay look clean. Pass the sweep, and the band
/// is read only up to the recording's end less the moment the sweep reached the band's top (with its skirt). Without
/// it, the band is read up to the recording's end counted from time zero, right only for the bottom of the sweep;
/// a response built by hand (no `recordingDuration`) is read to the end of its positive half.
///
/// Accuracy, on synthetic decays of random sound with an exact exponential envelope: on average within 2 % where
/// bandwidth times decay time is 24 or more, and within about 10 % from `minimumBandwidthTimeProduct` to 12, where
/// the band filter's own decay starts to lengthen the reading; a decay made by a resonance's poles (no randomness)
/// reads within 1 %. One reading scatters further, because a decay of random sound in a narrow band holds few
/// independent fluctuations: 12 to 17 % (one standard deviation) in the 40 to 80 Hz band for 0.3 to 1.2 s, and 6 %
/// in the 500 Hz octave. A real room's decay is random sound too. That, a phone's microphone and one seat make every
/// figure an estimate.
///
/// What it cannot tell you: anything about the room at large from one position (a decay at one seat is that seat's);
/// a decay faster than the band filter's own (`minimumBandwidthTimeProduct`); anything outside `trustedBand`; and
/// whether a long decay is the room or a resonance in the speaker or the furniture.
public enum Decay {
    /// The least dynamic range, in dB, for any estimate: 35, so T20's bottom (−25 dB) lies 10 dB above the noise.
    /// ISO 3382-1 §5.3.3 asks the bottom of the evaluation range to be at least 10 dB above the noise (15 dB for
    /// precision); 10 is the engineering grade a phone can hope for.
    public static let minimumDynamicRangeT20: Double = 35
    /// The dynamic range, in dB, from which T30 is fitted instead of T20: 45, the same 10 dB under T30's bottom.
    public static let minimumDynamicRangeT30: Double = 45
    /// The fewest periods of the band's lowest frequency the response must hold after its peak: 20. A low band
    /// needs many cycles: its filter rings for several, and its noise level is read from a stretch long enough to
    /// average many of them (1/2 s in the 63 Hz octave, 1 s in a band from 20 Hz). First guess.
    public static let minimumCycles: Double = 20
    /// Width, in octaves, of the band filter's raised-cosine skirt at each edge: half an octave. Narrower skirts
    /// ring longer (a brick wall rings as 1/t); wider ones let in more of the neighbouring bands. First guess.
    public static let filterSkirtOctaves: Double = 0.5
    /// The least share of the analysed stretch, at its end, the noise is read from: 10 % (Lundeby et al.).
    public static let noiseTailFraction: Double = 0.1
    /// The shortest block the squared response is averaged over to find the noise and the crossing: 10 ms. A band
    /// narrower than 100 Hz gets `1 / bandwidth` instead, the time its envelope takes to change.
    public static let minimumBlockDuration: Double = 0.01
    /// How many times the noise and the crossing are re-estimated: 5 (Lundeby et al. report convergence in 2–5).
    public static let lundebyIterations = 5
    /// The least product of the band's width in hertz and the decay time for an estimate: 7. The band filter has a
    /// decay of its own, measured on a unit impulse at 5.8 / bandwidth seconds (0.13 s in the 63 Hz octave, 8 ms in
    /// the 1 kHz one); a reading under 7 / bandwidth is within 20 % of it and may be the filter, not the room. A real
    /// decay just above the limit can read under it (one reading scatters, see the type's notes) and gives nothing.
    /// First guess.
    public static let minimumBandwidthTimeProduct: Double = 7
    /// The octaves `estimates(impulseResponse:sweep:)` covers, in hertz: the base-ten octaves from 63 Hz to 4 kHz.
    public static let octaveRange: ClosedRange<Float> = 63...4000
    /// The top of the bass band, in hertz: 80, the "< 80 Hz" the app shows.
    public static let bassUpperFrequency: Double = 80
    /// The bottom the bass band reaches when the response allows it, in hertz: `LogSweep.reportedBand`'s 20.
    public static let bassLowerFrequency: Double = LogSweep.reportedBand.lowerBound
    /// The narrowest bass band, in octaves, worth a figure: half an octave. First guess.
    public static let minimumBassOctaves: Double = 0.5

    /// The shortest stretch after the peak, in seconds, that can support an estimate in `band`:
    /// `minimumCycles` periods of its lowest frequency.
    public static func minimumDuration(of band: ClosedRange<Double>) -> Double {
        minimumCycles / band.lowerBound
    }

    /// The block, in samples, the squared response in `band` is averaged over: `minimumBlockDuration`, or
    /// `1 / bandwidth` when that is longer.
    public static func blockDuration(of band: ClosedRange<Double>, sampleRate: Double) -> Int {
        Int((max(minimumBlockDuration, 1 / (band.upperBound - band.lowerBound)) * sampleRate).rounded())
    }

    /// How long sound in `band` (hertz) takes to decay by 60 dB, from `impulseResponse`. Pass the `sweep` the
    /// response was measured with; see the type's notes for why.
    ///
    /// Nil when the response cannot support an estimate: `band` not inside `trustedBand` and `capturedBand`; less
    /// than `minimumDuration(of:)` of response after the peak; a dynamic range under `minimumDynamicRangeT20`
    /// (silence included); a decay that never reaches the bottom of its evaluation range before the noise; a decay
    /// too fast to tell from the band filter's own (`minimumBandwidthTimeProduct`); or a non-finite sample.
    public static func estimate(
        impulseResponse response: ImpulseResponse,
        band: ClosedRange<Double>,
        sweep: LogSweep? = nil
    ) -> DecayEstimate? {
        var segments: [Int: Segment] = [:]
        return estimate(impulseResponse: response, band: band, sweep: sweep, segments: &segments)
    }

    /// `estimate(impulseResponse:band:sweep:)` in each base-ten octave of `octaveRange` (63 Hz to 4 kHz, from
    /// `OctaveBands`), rising; a band the response cannot support has a nil estimate.
    public static func estimates(
        impulseResponse response: ImpulseResponse,
        sweep: LogSweep? = nil
    ) -> [(band: ClosedRange<Double>, estimate: DecayEstimate?)] {
        // Bands read over the same stretch share its transform.
        var segments: [Int: Segment] = [:]
        return OctaveBands.centres(fraction: 1, from: octaveRange.lowerBound, to: octaveRange.upperBound).map { centre in
            let edges = OctaveBands.edges(ofCentre: centre, fraction: 1)
            let band = Double(edges.lower)...Double(edges.upper)
            return (band, estimate(impulseResponse: response, band: band, sweep: sweep, segments: &segments))
        }
    }

    private static func estimate(
        impulseResponse response: ImpulseResponse,
        band: ClosedRange<Double>,
        sweep: LogSweep?,
        segments: inout [Int: Segment]
    ) -> DecayEstimate? {
        guard band.lowerBound > 0, band.upperBound > band.lowerBound,
              let trusted = response.trustedBand, let captured = response.capturedBand,
              trusted.lowerBound <= band.lowerBound, band.upperBound <= trusted.upperBound,
              captured.lowerBound <= band.lowerBound, band.upperBound <= captured.upperBound,
              LevelMeter.nonFiniteCount(response.samples) == 0 else { return nil }
        let span = analysedSpan(of: response, band: band, sweep: sweep)
        guard Double(span) / response.sampleRate >= minimumDuration(of: band) else { return nil }
        let segment = segments[span] ?? Segment(response: response, span: span)
        segments[span] = segment
        return fit(energy: segment.energy(in: band), band: band, sampleRate: response.sampleRate)
    }

    /// The bass band, in hertz: from `bassLowerFrequency` (or the bottom of `trustedBand`, when higher) to
    /// `bassUpperFrequency`. Nil when less than `minimumBassOctaves` is left.
    public static func bassBand(for response: ImpulseResponse) -> ClosedRange<Double>? {
        guard let trusted = response.trustedBand else { return nil }
        let lower = max(bassLowerFrequency, trusted.lowerBound)
        let upper = min(bassUpperFrequency, trusted.upperBound)
        return log2(upper / lower) >= minimumBassOctaves ? lower...upper : nil
    }

    /// The decay of the bass, over `bassBand(for:)`: what the app shows as "< 80 Hz ≈ 0.6 s". Nil when there is
    /// no bass band or it cannot support an estimate.
    public static func bass(impulseResponse response: ImpulseResponse, sweep: LogSweep? = nil) -> DecayEstimate? {
        bassBand(for: response).flatMap { estimate(impulseResponse: response, band: $0, sweep: sweep) }
    }

    // MARK: - Steps

    /// The number of samples after the linear peak that hold data in `band`: to the end of the positive half,
    /// and no further than the recording's end (less, with the sweep, the moment it reached the band's top skirt).
    static func analysedSpan(of response: ImpulseResponse, band: ClosedRange<Double>, sweep: LogSweep?) -> Int {
        let peak = response.peakIndex <= response.count / 2 ? response.peakIndex : response.peakIndex - response.count
        var end = response.count / 2
        if let recordingDuration = response.recordingDuration {
            let reached = sweep.map { sweep in
                sweep.time(of: min(max(band.upperBound * pow(2, filterSkirtOctaves / 2), sweep.startFrequency), sweep.endFrequency))
            } ?? 0
            end = min(end, response.seconds(recordingDuration - reached))
        }
        return max(end - peak, 0)
    }

    /// The response from its peak, `span` samples long, transformed once (zero-padded to twice its length, so the
    /// band filter wraps nothing) and ready to be filtered to any band.
    struct Segment {
        let span: Int
        let sampleRate: Double
        let plan: FFT.Plan
        let spectrum: ComplexSpectrum

        init(response: ImpulseResponse, span: Int) {
            let start = response.peakIndex
            let wrapped = max(start + span - response.count, 0)
            let samples = Array(response.samples[start..<(start + span - wrapped)]) + response.samples[0..<wrapped]
            self.span = span
            sampleRate = response.sampleRate
            plan = FFT.Plan(size: FFT.nextPowerOfTwo(max(2 * span, 2)))
            spectrum = plan.forward(samples)
        }

        /// The square of the segment filtered to `band` as the type describes.
        func energy(in band: ClosedRange<Double>) -> [Double] {
            let gains = Decay.bandGains(band: band, size: plan.size, sampleRate: sampleRate)
            let filtered = plan.inverse(ComplexSpectrum(
                real: vDSP.multiply(spectrum.real, gains),
                imaginary: vDSP.multiply(spectrum.imaginary, gains)
            ))
            return vDSP.square(vDSP.floatToDouble(filtered.prefix(span)))
        }
    }

    /// The band filter's gain at every bin of a `size`-point transform, mirrored so the filter is real and even.
    static func bandGains(band: ClosedRange<Double>, size: Int, sampleRate: Double) -> [Float] {
        var gains = [Float](repeating: 0, count: size)
        let half = filterSkirtOctaves / 2
        let binWidth = sampleRate / Double(size)
        let first = max(1, Int((band.lowerBound * pow(2, -half) / binWidth).rounded(.up)))
        let last = min(size / 2, Int((band.upperBound * pow(2, half) / binWidth).rounded(.down)))
        guard first <= last else { return gains }
        for bin in first...last {
            let octaves = log2(Double(bin) * binWidth)
            let rise = RaisedCosine.rise(octaves - log2(band.lowerBound) + half, over: filterSkirtOctaves)
            let fall = RaisedCosine.rise(log2(band.upperBound) - octaves + half, over: filterSkirtOctaves)
            gains[bin] = Float(rise * fall)
            if bin < size / 2 { gains[size - bin] = gains[bin] }
        }
        return gains
    }

    /// Steps 2 to 4 on the band's squared response.
    static func fit(energy: [Double], band: ClosedRange<Double>, sampleRate: Double) -> DecayEstimate? {
        let count = energy.count
        let block = max(Self.blockDuration(of: band, sampleRate: sampleRate), 1)
        let blockCount = count / block
        guard blockCount >= 10 else { return nil }
        let levels = (0..<blockCount).map { 10 * log10(vDSP.mean(energy[($0 * block)..<(($0 + 1) * block)])) }
        let blockTimes = (0..<blockCount).map { (Double($0) + 0.5) * Double(block) / sampleRate }
        let (peakBlock, peakLevel) = levels.enumerated().max { $0.element < $1.element }.map { ($0.offset, $0.element) }!
        guard peakLevel.isFinite else { return nil }

        // Lundeby's iteration: the noise, the line from the peak down to 10 dB above it, and where they cross.
        let tailStart = Int(Double(count) * (1 - noiseTailFraction))
        // A response that is exactly silent after the decay has no noise; −200 dB under the peak stands for it.
        func noiseLevel(from start: Int) -> Double {
            max(10 * log10(vDSP.mean(energy[start...])), peakLevel - 200)
        }
        var noise = noiseLevel(from: tailStart)
        var line: (intercept: Double, slope: Double)?
        var crossing = Double(count) / sampleRate
        for _ in 0..<lundebyIterations {
            var last = peakBlock
            while last + 1 < blockCount && levels[last + 1] > noise + 10 { last += 1 }
            guard last > peakBlock,
                  let fitted = regression(times: Array(blockTimes[peakBlock...last]), levels: Array(levels[peakBlock...last])),
                  fitted.slope < 0 else { return nil }
            line = (fitted.intercept, fitted.slope)
            let next = min(max((noise - fitted.intercept) / fitted.slope, 0), Double(count) / sampleRate)
            let noiseStart = min(Int(((next + 5 / -fitted.slope) * sampleRate).rounded()), tailStart)
            noise = noiseLevel(from: noiseStart)
            let converged = abs(next - crossing) * sampleRate < Double(block)
            crossing = next
            if converged { break }
        }
        guard let line else { return nil }

        let dynamicRange = peakLevel - noise
        guard dynamicRange >= minimumDynamicRangeT20 else { return nil }
        let range: DecayEstimate.EvaluationRange = dynamicRange >= minimumDynamicRangeT30 ? .t30 : .t20

        // Schroeder's backward integral to the crossing, plus the line's energy beyond it: at the crossing the line
        // is at the noise level, and ∫ 10^((noise + slope·t)/10) dt from there on is 10^(noise/10) · 10 / (−slope·ln 10).
        let cut = min(max(Int((crossing * sampleRate).rounded()), 1), count)
        let tail = pow(10, noise / 10) * sampleRate * 10 / (-line.slope * log(10))
        var integral = [Double](repeating: 0, count: cut)
        var running = tail
        for index in stride(from: cut - 1, through: 0, by: -1) {
            running += energy[index]
            integral[index] = running
        }
        let curve = vDSP.multiply(10, vForce.log10(vDSP.divide(integral, integral[0])))

        guard let top = curve.firstIndex(where: { $0 <= range.top }),
              let bottom = curve[top...].firstIndex(where: { $0 <= range.bottom }),
              bottom > top + 1 else { return nil }
        let times = vDSP.ramp(withInitialValue: Double(top) / sampleRate, increment: 1 / sampleRate, count: bottom - top + 1)
        guard let decay = regression(times: times, levels: Array(curve[top...bottom])), decay.slope < 0 else { return nil }
        let seconds = -60 / decay.slope
        guard seconds * (band.upperBound - band.lowerBound) >= minimumBandwidthTimeProduct else { return nil }
        return DecayEstimate(
            band: band,
            seconds: seconds,
            evaluationRange: range,
            dynamicRangeDecibels: dynamicRange,
            nonlinearity: 1000 * (1 - decay.correlation * decay.correlation)
        )
    }

    /// The least-squares line through `(times, levels)`, with the correlation of the two; nil for fewer than two
    /// points or no spread in time.
    static func regression(times: [Double], levels: [Double]) -> (intercept: Double, slope: Double, correlation: Double)? {
        let count = Double(times.count)
        guard times.count >= 2 else { return nil }
        let meanTime = vDSP.mean(times)
        let meanLevel = vDSP.mean(levels)
        let t = vDSP.add(-meanTime, times)
        let l = vDSP.add(-meanLevel, levels)
        let covariance = vDSP.dot(t, l) / count
        let timeVariance = vDSP.dot(t, t) / count
        let levelVariance = vDSP.dot(l, l) / count
        guard timeVariance > 0 else { return nil }
        let slope = covariance / timeVariance
        let correlation = levelVariance > 0 ? covariance / (timeVariance * levelVariance).squareRoot() : -1
        return (meanLevel - slope * meanTime, slope, correlation)
    }
}
