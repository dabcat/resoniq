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
/// - From `startFrequency · lowStopRatio` to the sweep's end, `ε` is `inBandRegularisation` times the sweep's
///   mean in-band power: negligible next to `|S|²`.
/// - Above the sweep's end and below `startFrequency · lowStopRatio`, `ε` is `outOfBandRegularisation` times
///   that power, so out-of-band content is attenuated by at least 40 dB relative to in-band content.
/// - Below the start, a causal 4th-order Butterworth high-pass at `startFrequency · lowCutRatio` rolls the bass
///   off. Causal, so it adds no precursor before the peak; a zero-phase cut this low would smear tens of
///   milliseconds before the peak and spoil the response near 50 Hz once windowed.
///
/// What it cannot tell you: anything outside the sweep's range, the absolute sound pressure (the microphone is
/// uncalibrated), or whether a feature of the response belongs to the speaker, the room or the microphone.
public enum Deconvolution {
    /// ε in band, as a fraction of the sweep's mean in-band power (−60 dB).
    public static let inBandRegularisation: Float = 1e-6
    /// ε out of band, as a multiple of the sweep's mean in-band power (+40 dB).
    public static let outOfBandRegularisation: Float = 1e4
    /// The high-pass corner, as a fraction of the sweep's start frequency.
    public static let lowCutRatio: Double = 0.5
    /// Below this fraction of the start frequency the out-of-band ε applies.
    public static let lowStopRatio: Double = 0.25

    /// The impulse response of the system that turned `sweep` into `recording`, in the layout `ImpulseResponse`
    /// documents, with `band` set to the sweep's range.
    ///
    /// The recording must start no later than the sweep's playback (a later start loses the beginning of the
    /// sweep and with it the bass) and should run past the sweep's end by the system's delay plus its decay.
    /// Both are at `sweep.sampleRate`.
    public static func impulseResponse(recording: [Float], sweep: LogSweep) -> ImpulseResponse {
        precondition(!recording.isEmpty, "the recording is empty")
        let sweepSamples = sweep.samples()
        let size = FFT.nextPowerOfTwo(recording.count + sweepSamples.count)
        let sampleRate = sweep.sampleRate
        let s = FFT.forward(sweepSamples, size: size)
        let r = FFT.forward(recording, size: size)

        // R·S*
        let numeratorReal = vDSP.add(vDSP.multiply(r.real, s.real), vDSP.multiply(r.imaginary, s.imaginary))
        let numeratorImaginary = vDSP.subtract(vDSP.multiply(r.imaginary, s.real), vDSP.multiply(r.real, s.imaginary))
        let sweepPower = vDSP.add(vDSP.square(s.real), vDSP.square(s.imaginary))

        let firstInBand = max(1, FFT.bin(nearest: sweep.startFrequency, size: size, sampleRate: sampleRate))
        let lastInBand = min(size / 2, FFT.bin(nearest: sweep.endFrequency, size: size, sampleRate: sampleRate))
        let meanPower = vDSP.mean(sweepPower[firstInBand...lastInBand])
        let inBand = inBandRegularisation * meanPower
        let outOfBand = outOfBandRegularisation * meanPower
        let lowStopBin = Int((sweep.startFrequency * lowStopRatio * Double(size) / sampleRate).rounded(.down))
        let corner = sweep.startFrequency * lowCutRatio

        // The band-limit, G = HP(f) / (|S|² + ε(f)), built on the lower half and mirrored as its conjugate.
        var gainReal = [Float](repeating: 0, count: size)
        var gainImaginary = [Float](repeating: 0, count: size)
        for bin in 1...(size / 2) {
            let epsilon = (bin <= lowStopBin || bin > lastInBand) ? outOfBand : inBand
            let highPass = butterworthHighPass(frequency: FFT.frequency(ofBin: bin, size: size, sampleRate: sampleRate), corner: corner)
            let denominator = Double(sweepPower[bin] + epsilon)
            gainReal[bin] = Float(highPass.real / denominator)
            gainImaginary[bin] = Float(highPass.imaginary / denominator)
            if bin < size / 2 {
                gainReal[size - bin] = gainReal[bin]
                gainImaginary[size - bin] = -gainImaginary[bin]
            }
        }
        // At the Nyquist bin a real signal needs a real spectrum.
        gainImaginary[size / 2] = 0

        let real = vDSP.subtract(vDSP.multiply(numeratorReal, gainReal), vDSP.multiply(numeratorImaginary, gainImaginary))
        let imaginary = vDSP.add(vDSP.multiply(numeratorReal, gainImaginary), vDSP.multiply(numeratorImaginary, gainReal))
        let samples = FFT.inverse(ComplexSpectrum(real: real, imaginary: imaginary))
        return ImpulseResponse(
            samples: samples,
            sampleRate: sampleRate,
            band: sweep.startFrequency...sweep.endFrequency
        )
    }

    /// The analogue 4th-order Butterworth high-pass at `corner` hertz, evaluated at `frequency`.
    private static func butterworthHighPass(frequency: Double, corner: Double) -> (real: Double, imaginary: Double) {
        // Two sections s² / (s² + c·s + 1) with s = j·f/fc; c = 2·sin(π/8), 2·sin(3π/8).
        let x = frequency / corner
        var real = 1.0
        var imaginary = 0.0
        for damping in [0.7653668647301796, 1.8477590650225735] {
            let numerator = -x * x
            let denominatorReal = 1 - x * x
            let denominatorImaginary = damping * x
            let norm = denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary
            // numerator / denominator, with a real numerator.
            let sectionReal = numerator * denominatorReal / norm
            let sectionImaginary = -numerator * denominatorImaginary / norm
            (real, imaginary) = (real * sectionReal - imaginary * sectionImaginary, real * sectionImaginary + imaginary * sectionReal)
        }
        return (real, imaginary)
    }
}
