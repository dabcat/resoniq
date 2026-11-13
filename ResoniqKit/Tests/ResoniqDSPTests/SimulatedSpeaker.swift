import Foundation
@testable import ResoniqDSP

/// A second-order IIR section (RBJ cookbook), in double precision, whose magnitude response is known exactly.
struct Biquad {
    let b0, b1, b2, a1, a2: Double

    static func highPass(frequency: Double, q: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: (1 + cos(w)) / 2 / a0, b1: -(1 + cos(w)) / a0, b2: (1 + cos(w)) / 2 / a0,
            a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0
        )
    }

    static func peaking(frequency: Double, q: Double, gain decibels: Double, sampleRate: Double) -> Biquad {
        let w = 2 * Double.pi * frequency / sampleRate
        let alpha = sin(w) / (2 * q)
        let a = pow(10, decibels / 40)
        let a0 = 1 + alpha / a
        return Biquad(
            b0: (1 + alpha * a) / a0, b1: -2 * cos(w) / a0, b2: (1 - alpha * a) / a0,
            a1: -2 * cos(w) / a0, a2: (1 - alpha / a) / a0
        )
    }

    func process(_ input: [Double]) -> [Double] {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        return input.map { x in
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            return y
        }
    }

    /// |H(e^{jω})| at `frequency` hertz.
    func magnitude(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        func evaluate(_ c0: Double, _ c1: Double, _ c2: Double) -> Double {
            let real = c0 + c1 * cos(w) + c2 * cos(2 * w)
            let imaginary = -c1 * sin(w) - c2 * sin(2 * w)
            return (real * real + imaginary * imaginary).squareRoot()
        }
        return evaluate(b0, b1, b2) / evaluate(1, a1, a2)
    }
}

/// A deterministic generator (SplitMix64), so noisy tests give the same answer every run.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Gaussian white noise with standard deviation `rms` (Box–Muller).
    mutating func noise(count: Int, rms: Double) -> [Double] {
        (0..<count).map { _ in
            let u = Double.random(in: Double.ulpOfOne..<1, using: &self)
            let v = Double.random(in: 0..<1, using: &self)
            return rms * (-2 * log(u)).squareRoot() * cos(2 * Double.pi * v)
        }
    }
}

/// A loudspeaker in a test: the sweep, delayed by a fractional number of samples, through linear `filters`, then
/// the memoryless nonlinearity `y = x + quadratic·x² + cubic·x³`, plus white noise, with silence after.
///
/// The nonlinearity comes after the filters, so the sine reaching it at frequency `f` has amplitude `A·|H(f)|`;
/// the expected values below account for that.
struct SimulatedSpeaker {
    var delaySamples: Double = 0
    var filters: [Biquad] = []
    var quadratic: Double = 0
    var cubic: Double = 0
    var noiseRMS: Double = 0
    var tailSeconds: Double = 0.5
    var seed: UInt64 = 1

    func record(_ sweep: LogSweep) -> [Float] {
        let source = sweep.samples()
        let length = source.count + Int(delaySamples.rounded(.up)) + Int(tailSeconds * sweep.sampleRate)
        var signal = Self.delayed(source, by: delaySamples, length: length).map(Double.init)
        for filter in filters { signal = filter.process(signal) }
        signal = signal.map { $0 + quadratic * $0 * $0 + cubic * $0 * $0 * $0 }
        if noiseRMS > 0 {
            var generator = SeededGenerator(state: seed)
            signal = zip(signal, generator.noise(count: length, rms: noiseRMS)).map(+)
        }
        return signal.map(Float.init)
    }

    /// |H(f)| of the linear filters alone.
    func filterGain(at frequency: Double, sampleRate: Double) -> Double {
        filters.reduce(1) { $0 * $1.magnitude(at: frequency, sampleRate: sampleRate) }
    }

    /// The fundamental's output over the input amplitude `amplitude` at `f`: |H(f)|·(1 + ¾·cubic·(A·|H(f)|)²),
    /// because x³ puts ¾·A′³ back into the fundamental.
    func fundamentalGain(at frequency: Double, amplitude: Double, sampleRate: Double) -> Double {
        let gain = filterGain(at: frequency, sampleRate: sampleRate)
        let reaching = amplitude * gain
        return gain * (1 + 0.75 * cubic * reaching * reaching)
    }

    /// THD as a fraction, for a sine of `amplitude` at `f`: h₂ = quadratic·A′²/2, h₃ = cubic·A′³/4, over the
    /// fundamental A′ + ¾·cubic·A′³, with A′ = A·|H(f)|.
    func expectedTHD(at frequency: Double, amplitude: Double, sampleRate: Double) -> Double {
        let reaching = amplitude * filterGain(at: frequency, sampleRate: sampleRate)
        let second = quadratic * reaching * reaching / 2
        let third = cubic * reaching * reaching * reaching / 4
        let fundamental = reaching + 0.75 * cubic * reaching * reaching * reaching
        return (second * second + third * third).squareRoot() / fundamental
    }

    /// `signal` delayed by `delay` samples (any real number ≥ 0) into a buffer of `length`, by a linear phase
    /// shift in the frequency domain: exact for a band-limited signal.
    static func delayed(_ signal: [Float], by delay: Double, length: Int) -> [Float] {
        let size = FFT.nextPowerOfTwo(length + 1024)
        let spectrum = FFT.forward(signal, size: size)
        var real = spectrum.real
        var imaginary = spectrum.imaginary
        for bin in 0..<size {
            let signedBin = bin <= size / 2 ? Double(bin) : Double(bin - size)
            let phase = -2 * Double.pi * signedBin * delay / Double(size)
            let (c, s) = (Float(cos(phase)), Float(sin(phase)))
            (real[bin], imaginary[bin]) = (real[bin] * c - imaginary[bin] * s, real[bin] * s + imaginary[bin] * c)
        }
        return Array(FFT.inverse(ComplexSpectrum(real: real, imaginary: imaginary)).prefix(length))
    }
}
