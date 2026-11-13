import Accelerate

/// Reading a sampled signal between its samples, with a windowed-sinc (band-limited) interpolator.
///
/// Used to undo the stretch of a sweep played by a device whose clock is not the phone's
/// (`SweepFinder.corrected(_:ratio:)`), and by the simulation to apply one.
///
/// **Kernel.** A sinc cut to `halfWidth` samples on each side by a Kaiser window (β `kaiserBeta`), tabulated at
/// `phases` fractional offsets with linear interpolation between neighbouring phases. The pass band is flat to within
/// 0.01 dB up to 21 kHz at 48 kHz (where the measurement sweep's trusted band ends); the image above Nyquist is down
/// about 80 dB. It is meant for steps near 1 (a clock off by a fraction of a per cent): a step well above 1 would need
/// a lower cut-off to avoid aliasing, which this does not apply.
public enum Interpolation {
    /// Samples of kernel on each side of the point read.
    public static let halfWidth = 48
    /// Fractional offsets tabulated between two samples.
    public static let phases = 256
    /// The Kaiser window's shape parameter: about 80 dB of stop band.
    public static let kaiserBeta = 8.6

    /// `count` values of `samples` read at `start`, `start + step`, `start + 2·step`, …, in samples (index 0 is the
    /// first sample). The signal counts as zero outside its samples, so reading past either end fades to silence over
    /// `halfWidth` samples instead of trapping.
    public static func resample(_ samples: [Float], from start: Double, step: Double, count: Int) -> [Float] {
        precondition(step > 0, "the step must be positive")
        guard count > 0 else { return [] }
        guard !samples.isEmpty else { return [Float](repeating: 0, count: count) }
        let taps = 2 * halfWidth
        // Padded so that every kernel lies inside the buffer.
        let front = halfWidth + taps
        var padded = [Float](repeating: 0, count: front)
        padded.reserveCapacity(samples.count + 2 * front)
        padded.append(contentsOf: samples)
        padded.append(contentsOf: repeatElement(0, count: halfWidth + taps))
        let table = kernelTable
        var output = [Float](repeating: 0, count: count)
        padded.withUnsafeBufferPointer { signal in
            table.withUnsafeBufferPointer { kernels in
                for index in 0..<count {
                    let position = start + Double(index) * step
                    let whole = position.rounded(.down)
                    // The first tap sits at whole − halfWidth + 1, which is padded index whole + 1 + taps.
                    guard whole > -Double(front), whole < Double(signal.count) else { continue }
                    let first = Int(whole) + 1 + taps
                    guard first >= 0, first + taps <= signal.count else { continue }
                    let fraction = (position - whole) * Double(phases)
                    let phase = min(Int(fraction), phases - 1)
                    let blend = Float(fraction - Double(phase))
                    var low: Float = 0
                    var high: Float = 0
                    vDSP_dotpr(signal.baseAddress! + first, 1, kernels.baseAddress! + phase * taps, 1, &low, vDSP_Length(taps))
                    vDSP_dotpr(signal.baseAddress! + first, 1, kernels.baseAddress! + (phase + 1) * taps, 1, &high, vDSP_Length(taps))
                    output[index] = low + blend * (high - low)
                }
            }
        }
        return output
    }

    /// `phases + 1` kernels of `2·halfWidth` taps: kernel `p` weights samples `−halfWidth + 1 … halfWidth` around a
    /// point `p / phases` of a sample after sample 0.
    static let kernelTable: [Float] = {
        let taps = 2 * halfWidth
        var table = [Float](repeating: 0, count: (phases + 1) * taps)
        let normaliser = besselI0(kaiserBeta)
        for phase in 0...phases {
            let fraction = Double(phase) / Double(phases)
            for tap in 0..<taps {
                let offset = Double(tap - halfWidth + 1) - fraction
                let ratio = offset / Double(halfWidth)
                guard abs(ratio) < 1 else { continue }
                let window = besselI0(kaiserBeta * (1 - ratio * ratio).squareRoot()) / normaliser
                let sinc = offset == 0 ? 1 : sin(Double.pi * offset) / (Double.pi * offset)
                table[phase * taps + tap] = Float(sinc * window)
            }
        }
        return table
    }()

    /// The modified Bessel function of the first kind, order zero, by its power series.
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let quarter = x * x / 4
        for k in 1...50 {
            term *= quarter / Double(k * k)
            sum += term
            if term < sum * 1e-16 { break }
        }
        return sum
    }
}
