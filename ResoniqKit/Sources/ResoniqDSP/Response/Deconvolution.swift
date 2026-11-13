import Accelerate

/// Turns a recording of a played `LogSweep` into the impulse response of whatever it passed through.
///
/// Method: regularised spectral division, `H = R·S* / (|S|² + ε(f))`, on a transform long enough
/// (`recording.count + sweep.count`, rounded up to a power of two) that the circular result equals the linear
/// one. Spectral division is chosen over Farina's time-reversed inverse filter because it is exact where the sweep
/// has energy (a recording identical to the sweep gives a unit impulse, with no envelope approximation) and
/// because it scales each harmonic's response so that its magnitude at `n·f` is the harmonic's amplitude relative
/// to the sweep's at `f`, which is what `HarmonicDistortion` reads.
///
/// Band limiting, so noise outside the sweep's range is not amplified:
/// - From the sweep's start to its end, `ε` is `inBandRegularisation` times the sweep's mean in-band power:
///   negligible next to `|S|²`.
/// - Above the end, and below `lowStopRatio` times the start, `ε` is `outOfBandRegularisation` times that power,
///   so out-of-band content comes out at least 40 dB under the in-band gain at the nearest edge. Between
///   `lowStopRatio` times the start and the start, `ε` rises smoothly (a raised cosine in log frequency, from the
///   in-band to the out-of-band value), so rumble just under the sweep is attenuated, not amplified, and the edge
///   rings briefly enough to stay out of the trusted band.
/// - A causal 4th-order Butterworth high-pass at `startFrequency · lowCutRatio` rolls the bass off further.
///   Causal, so it adds no precursor before the peak.
///
/// What it cannot tell you: anything outside the sweep's range, or outside the part the recording holds
/// (`ImpulseResponse.capturedBand`); the absolute sound pressure (the microphone is uncalibrated); or whether a
/// feature of the response belongs to the speaker, the room or the microphone.
public enum Deconvolution {
    /// ε in band, as a fraction of the sweep's mean in-band power (−60 dB).
    public static let inBandRegularisation: Float = 1e-6
    /// ε out of band, as a multiple of the sweep's mean in-band power (+40 dB).
    public static let outOfBandRegularisation: Float = 1e4
    /// The high-pass corner, as a fraction of the sweep's start frequency: 0.35. The regularisation already rejects
    /// what lies under the sweep; a lower corner rings for less time inside the response's window, which keeps the
    /// bottom of the trusted band within 0.3 dB.
    public static let lowCutRatio: Double = 0.35
    /// The fraction of the start frequency at which ε has risen to the out-of-band value: 0.7, so a 10–14 Hz tone
    /// under a sweep from 20 Hz comes out at least 10 dB under an equal 40 Hz tone. Raising it towards 1 rejects
    /// more and bends the bottom of the trusted band; lowering it does the reverse.
    public static let lowStopRatio: Double = 0.7
    /// How far inside a cut in the recording the response is trusted, in octaves: where the recording started
    /// late, the trusted band starts this far above the first frequency recorded; where it stopped early, it ends
    /// this far below the last. A cut is abrupt, unlike the sweep's own faded ends, so it rings for longer.
    public static let cutMargin: Double = 1

    /// The impulse response of the system that turned `sweep` into `recording`, in the layout `ImpulseResponse`
    /// documents, with `band` the sweep's range and `capturedBand` and `trustedBand` what the recording holds.
    ///
    /// The recording should start no later than the sweep's playback and run past the sweep's end by the system's
    /// delay plus its decay. Where it does not, `capturedBand` says which frequencies were never recorded: the
    /// linear peak gives the delay, and the sweep played `frequency(at: t)` at `delay + t` into the recording.
    /// An empty, too short, all-zero or corrupt (non-finite) recording gives a response that captured nothing
    /// (`capturedBand` and `trustedBand` nil), never a trap. Both are at `sweep.sampleRate`.
    public static func impulseResponse(recording: [Float], sweep: LogSweep) -> ImpulseResponse {
        let sweepSamples = sweep.samples()
        let size = FFT.nextPowerOfTwo(max(recording.count + sweepSamples.count, 2))
        let sampleRate = sweep.sampleRate
        let plan = FFT.Plan(size: size)
        let s = plan.forward(sweepSamples)
        let r = plan.forward(recording)

        // R·S*
        let numeratorReal = vDSP.add(vDSP.multiply(r.real, s.real), vDSP.multiply(r.imaginary, s.imaginary))
        let numeratorImaginary = vDSP.subtract(vDSP.multiply(r.imaginary, s.real), vDSP.multiply(r.real, s.imaginary))
        let sweepPower = vDSP.add(vDSP.square(s.real), vDSP.square(s.imaginary))

        let firstInBand = max(1, FFT.bin(nearest: sweep.startFrequency, size: size, sampleRate: sampleRate))
        let lastInBand = min(size / 2, FFT.bin(nearest: sweep.endFrequency, size: size, sampleRate: sampleRate))
        let meanPower = firstInBand <= lastInBand ? vDSP.mean(sweepPower[firstInBand...lastInBand]) : 0
        // A silent sweep (amplitude 0) has nothing to divide by: the response is zero.
        let (gainReal, gainImaginary) = meanPower > 0
            ? bandLimit(sweepPower: sweepPower, meanPower: meanPower, lastInBand: lastInBand, sweep: sweep, size: size)
            : ([Float](repeating: 0, count: size), [Float](repeating: 0, count: size))

        let real = vDSP.subtract(vDSP.multiply(numeratorReal, gainReal), vDSP.multiply(numeratorImaginary, gainImaginary))
        let imaginary = vDSP.add(vDSP.multiply(numeratorReal, gainImaginary), vDSP.multiply(numeratorImaginary, gainReal))
        let samples = plan.inverse(ComplexSpectrum(real: real, imaginary: imaginary))

        let band = sweep.startFrequency...sweep.endFrequency
        let uncut = ImpulseResponse(samples: samples, sampleRate: sampleRate, band: band)
        let recordingDuration = Double(recording.count) / sampleRate
        let captured = capturedBand(of: uncut, recordingDuration: recordingDuration, sweep: sweep)
        return ImpulseResponse(
            samples: samples,
            sampleRate: sampleRate,
            peakIndex: uncut.peakIndex,
            band: band,
            capturedBand: captured,
            trustedBand: captured.flatMap { trustedBand(captured: $0, sweep: sweep) },
            recordingDuration: recordingDuration
        )
    }

    /// The frequencies of `sweep` that a recording of `recordingDuration` seconds holds, given the delay of the
    /// response's linear peak; nil when the response is silent or corrupt or the recording missed the sweep.
    static func capturedBand(of response: ImpulseResponse, recordingDuration: Double, sweep: LogSweep) -> ClosedRange<Double>? {
        let peak = abs(response.samples[response.peakIndex])
        guard peak > 0, LevelMeter.nonFiniteCount(response.samples) == 0 else { return nil }
        let delay = response.delay
        // The sweep's sample at time t was recorded at delay + t.
        let first = max(0, -delay)
        let last = min(sweep.duration, recordingDuration - delay)
        guard last > first else { return nil }
        let lower = first > 0 ? sweep.frequency(at: first) : sweep.startFrequency
        let upper = last < sweep.duration ? sweep.frequency(at: last) : sweep.endFrequency
        return lower < upper ? lower...upper : nil
    }

    /// The sweep's `trustedBand`, narrowed by `cutMargin` octaves inside each edge of `captured` that a cut in the
    /// recording made; nil when nothing is left.
    static func trustedBand(captured: ClosedRange<Double>, sweep: LogSweep) -> ClosedRange<Double>? {
        guard let trusted = sweep.trustedBand else { return nil }
        let lower = captured.lowerBound > sweep.startFrequency
            ? max(trusted.lowerBound, captured.lowerBound * pow(2, cutMargin))
            : trusted.lowerBound
        let upper = captured.upperBound < sweep.endFrequency
            ? min(trusted.upperBound, captured.upperBound * pow(2, -cutMargin))
            : trusted.upperBound
        return lower < upper ? lower...upper : nil
    }

    /// The band-limit `G = HP(f) / (|S|² + ε(f))` on all `size` bins: computed on bins 0 through `size / 2` and
    /// mirrored as its conjugate, so the impulse response is real.
    private static func bandLimit(
        sweepPower: [Float],
        meanPower: Float,
        lastInBand: Int,
        sweep: LogSweep,
        size: Int
    ) -> (real: [Float], imaginary: [Float]) {
        let half = size / 2
        let binWidth = sweep.sampleRate / Double(size)
        let frequencies = vDSP.ramp(withInitialValue: 0, increment: binWidth, count: half + 1)

        // ε: in band from the start to the end, out of band above the end and below lowStopRatio · start, and a
        // raised cosine in log frequency between, from the in-band value up to the out-of-band one.
        let inBand = Double(inBandRegularisation * meanPower)
        let outOfBand = Double(outOfBandRegularisation * meanPower)
        let rampTop = sweep.startFrequency
        let rampBottom = sweep.startFrequency * lowStopRatio
        var epsilon = [Double](repeating: outOfBand, count: half + 1)
        let firstInBand = min(Int((rampTop / binWidth).rounded(.up)), half + 1)
        if firstInBand <= lastInBand {
            epsilon.replaceSubrange(firstInBand...lastInBand, with: repeatElement(inBand, count: lastInBand - firstInBand + 1))
        }
        for bin in max(Int((rampBottom / binWidth).rounded(.up)), 1)..<max(firstInBand, 1) {
            let rise = RaisedCosine.rise(log(rampTop / frequencies[bin]), over: log(rampTop / rampBottom))
            epsilon[bin] = inBand * pow(outOfBand / inBand, rise)
        }
        let denominator = vDSP.add(vDSP.floatToDouble(sweepPower[0...half]), epsilon)

        // The causal 4th-order Butterworth high-pass at lowCutRatio · start: two sections
        // s² / (s² + c·s + 1) with s = j·f/fc and c = 2·sin(π/8), 2·sin(3π/8).
        let x = vDSP.divide(frequencies, sweep.startFrequency * lowCutRatio)
        let xSquared = vDSP.square(x)
        let oneMinusXSquared = vDSP.add(1, vDSP.negative(xSquared))
        func section(_ damping: Double) -> (real: [Double], imaginary: [Double]) {
            // −x² / ((1 − x²) + j·c·x), with a real numerator.
            let b = vDSP.multiply(damping, x)
            let scale = vDSP.divide(xSquared, vDSP.add(vDSP.square(oneMinusXSquared), vDSP.square(b)))
            return (vDSP.negative(vDSP.multiply(scale, oneMinusXSquared)), vDSP.multiply(scale, b))
        }
        let first = section(0.7653668647301796)
        let second = section(1.8477590650225735)
        let highPassReal = vDSP.subtract(vDSP.multiply(first.real, second.real), vDSP.multiply(first.imaginary, second.imaginary))
        let highPassImaginary = vDSP.add(vDSP.multiply(first.real, second.imaginary), vDSP.multiply(first.imaginary, second.real))

        var real = vDSP.doubleToFloat(vDSP.divide(highPassReal, denominator))
        var imaginary = vDSP.doubleToFloat(vDSP.divide(highPassImaginary, denominator))
        // DC carries nothing, and at the Nyquist bin a real signal needs a real spectrum.
        real[0] = 0
        imaginary[0] = 0
        imaginary[half] = 0
        real.append(contentsOf: real[1..<half].reversed())
        imaginary.append(contentsOf: vDSP.negative(imaginary[1..<half]).reversed())
        return (real, imaginary)
    }
}
