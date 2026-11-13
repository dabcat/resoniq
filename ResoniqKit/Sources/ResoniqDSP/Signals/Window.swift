import Accelerate

/// A window applied to a frame before a Fourier transform, to trade frequency resolution for leakage.
///
/// Every window here is a periodic (DFT-even) cosine sum, `w[n] = Σₖ (−1)ᵏ aₖ cos(2πkn/N)`: the form for
/// spectral analysis, whose mean is exactly `a₀` and whose transform is zero at every whole-bin offset of at
/// least as many bins as it has terms (1 for rectangular, 2 for Hann and Hamming, 4 for Blackman–Harris).
public enum Window: Sendable, CaseIterable, Hashable {
    /// All ones: the best resolution and the worst leakage.
    case rectangular
    /// Raised cosine; the default for a spectrum. Sidelobes −31 dB, falling 18 dB an octave.
    case hann
    /// Sidelobes −43 dB, but they do not fall away.
    case hamming
    /// Four-term Blackman–Harris: sidelobes −92 dB, the widest main lobe here. For tones near loud ones.
    case blackmanHarris

    /// The cosine-sum coefficients a₀, a₁, … (Harris 1978).
    var coefficients: [Double] {
        switch self {
        case .rectangular: [1]
        case .hann: [0.5, 0.5]
        case .hamming: [0.54, 0.46]
        case .blackmanHarris: [0.35875, 0.48829, 0.14128, 0.01168]
        }
    }

    /// `count` samples of the window, peaking at 1 at sample `count / 2`. A one-sample window is that peak, `[1]`,
    /// for every shape (the periodic formula would give 0 and wipe the frame out).
    public func samples(count: Int) -> [Float] {
        precondition(count > 0, "a window needs at least one sample")
        let coefficients = coefficients
        guard coefficients.count > 1, count > 1 else { return [Float](repeating: 1, count: count) }
        return (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            var value = 0.0
            for (order, coefficient) in coefficients.enumerated() {
                value += (order.isMultiple(of: 2) ? 1 : -1) * coefficient * cos(Double(order) * angle)
            }
            return Float(value)
        }
    }

    /// The mean of the window, as a fraction of 1: how much a windowed tone's peak in the spectrum is lowered.
    /// Dividing a spectrum by `count · coherentGain` puts a tone on a bin at its amplitude.
    public var coherentGain: Float {
        Float(coefficients[0])
    }

    /// The equivalent noise bandwidth, in bins: `N · Σw² / (Σw)²`. A noise spectrum reads this much higher in
    /// power per bin than a rectangular window would show it, and a tone's power is spread over this many
    /// bins. 1 for rectangular, 1.5 for Hann.
    public var equivalentNoiseBandwidth: Float {
        let coefficients = coefficients
        let a0 = coefficients[0]
        let others = coefficients.dropFirst().reduce(0) { $0 + $1 * $1 }
        return Float((a0 * a0 + others / 2) / (a0 * a0))
    }

    /// `signal` multiplied sample by sample by a window of its own length.
    public func apply(to signal: [Float]) -> [Float] {
        guard !signal.isEmpty else { return [] }
        return vDSP.multiply(signal, samples(count: signal.count))
    }
}
