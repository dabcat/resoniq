import Accelerate

/// A complex spectrum in split form. Bin `k` of an `N`-point transform is the frequency `k · sampleRate / N`.
public struct ComplexSpectrum: Sendable, Equatable {
    public var real: [Float]
    public var imaginary: [Float]

    public init(real: [Float], imaginary: [Float]) {
        precondition(real.count == imaginary.count, "real and imaginary parts differ in length")
        self.real = real
        self.imaginary = imaginary
    }

    public var count: Int { real.count }

    /// |X[k]| for every bin, including the mirrored upper half.
    public var magnitudes: [Float] {
        vDSP.hypot(real, imaginary)
    }
}

/// Discrete Fourier transforms on power-of-two sizes. Unnormalised forward, 1/N on the inverse,
/// so `inverse(forward(x)) == x`.
public enum FFT {
    public static func nextPowerOfTwo(_ count: Int) -> Int {
        precondition(count > 0, "count must be positive")
        var size = 1
        while size < count { size <<= 1 }
        return size
    }

    /// Transforms a real signal, zero-padded to `size` (default: the next power of two).
    public static func forward(_ signal: [Float], size: Int? = nil) -> ComplexSpectrum {
        let size = size ?? nextPowerOfTwo(max(signal.count, 1))
        precondition(size >= signal.count && size == nextPowerOfTwo(size), "size must be a power of two that fits the signal")
        var real = signal
        real.append(contentsOf: [Float](repeating: 0, count: size - signal.count))
        return transform(ComplexSpectrum(real: real, imaginary: [Float](repeating: 0, count: size)), .forward)
    }

    /// Transforms a complex sequence whose length is a power of two.
    public static func forward(_ input: ComplexSpectrum) -> ComplexSpectrum {
        transform(input, .forward)
    }

    /// The real part of the inverse transform, scaled by 1/N.
    public static func inverse(_ spectrum: ComplexSpectrum) -> [Float] {
        vDSP.divide(transform(spectrum, .inverse).real, Float(spectrum.count))
    }

    public static func frequency(ofBin bin: Int, size: Int, sampleRate: Double) -> Double {
        Double(bin) * sampleRate / Double(size)
    }

    public static func bin(nearest frequency: Double, size: Int, sampleRate: Double) -> Int {
        Int((frequency * Double(size) / sampleRate).rounded())
    }

    private static func transform(_ input: ComplexSpectrum, _ direction: vDSP.FourierTransformDirection) -> ComplexSpectrum {
        precondition(input.count == nextPowerOfTwo(input.count), "length must be a power of two")
        guard input.count > 1 else { return input }
        guard let setup = try? vDSP.DiscreteFourierTransform(
            count: input.count, direction: direction, transformType: .complexComplex, ofType: Float.self
        ) else {
            preconditionFailure("vDSP cannot transform \(input.count) points")
        }
        let output = setup.transform(real: input.real, imaginary: input.imaginary)
        return ComplexSpectrum(real: output.real, imaginary: output.imaginary)
    }
}
