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
        Plan(size: size ?? nextPowerOfTwo(max(signal.count, 1)), inverse: false).forward(signal)
    }

    /// Transforms a complex sequence whose length is a power of two.
    public static func forward(_ input: ComplexSpectrum) -> ComplexSpectrum {
        Plan(size: input.count, inverse: false).forward(input)
    }

    /// The real part of the inverse transform, scaled by 1/N.
    public static func inverse(_ spectrum: ComplexSpectrum) -> [Float] {
        Plan(size: spectrum.count, forward: false).inverse(spectrum)
    }

    public static func frequency(ofBin bin: Int, size: Int, sampleRate: Double) -> Double {
        Double(bin) * sampleRate / Double(size)
    }

    public static func bin(nearest frequency: Double, size: Int, sampleRate: Double) -> Int {
        Int((frequency * Double(size) / sampleRate).rounded())
    }

    /// Transforms of one power-of-two size, set up once and reused by a function that transforms repeatedly.
    /// Setting up costs about as much as a transform, so a plan sets up only the directions it is asked for.
    struct Plan {
        let size: Int
        private let forwardSetup: vDSP.DiscreteFourierTransform<Float>?
        private let inverseSetup: vDSP.DiscreteFourierTransform<Float>?

        init(size: Int, forward: Bool = true, inverse: Bool = true) {
            precondition(size > 0 && size == FFT.nextPowerOfTwo(size), "length must be a power of two")
            self.size = size
            forwardSetup = forward ? Plan.setup(size: size, direction: .forward) : nil
            inverseSetup = inverse ? Plan.setup(size: size, direction: .inverse) : nil
        }

        /// A real signal, zero-padded to `size`.
        func forward(_ signal: [Float]) -> ComplexSpectrum {
            precondition(signal.count <= size, "size must be a power of two that fits the signal")
            var real = signal
            real.append(contentsOf: repeatElement(0, count: size - signal.count))
            return transform(ComplexSpectrum(real: real, imaginary: [Float](repeating: 0, count: size)), forwardSetup)
        }

        func forward(_ input: ComplexSpectrum) -> ComplexSpectrum {
            transform(input, forwardSetup)
        }

        /// The real part of the inverse transform, scaled by 1/N.
        func inverse(_ spectrum: ComplexSpectrum) -> [Float] {
            vDSP.divide(transform(spectrum, inverseSetup).real, Float(size))
        }

        private func transform(_ input: ComplexSpectrum, _ setup: vDSP.DiscreteFourierTransform<Float>?) -> ComplexSpectrum {
            precondition(input.count == size, "the input does not match the plan's size")
            guard size > 1 else { return input }
            guard let setup else { preconditionFailure("vDSP cannot transform \(size) points") }
            let output = setup.transform(real: input.real, imaginary: input.imaginary)
            return ComplexSpectrum(real: output.real, imaginary: output.imaginary)
        }

        private static func setup(size: Int, direction: vDSP.FourierTransformDirection) -> vDSP.DiscreteFourierTransform<Float>? {
            guard size > 1 else { return nil }
            return try? vDSP.DiscreteFourierTransform(
                count: size, direction: direction, transformType: .complexComplex, ofType: Float.self
            )
        }
    }
}
