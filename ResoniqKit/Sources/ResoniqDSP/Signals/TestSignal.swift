import Foundation

/// Steady test signals: a tone and silence. The sweep is `LogSweep`.
public enum TestSignal {
    /// A sine at `frequency` hertz lasting `duration` seconds, as samples at `sampleRate`.
    ///
    /// The peak is `amplitude` as a fraction of full scale, clamped to `0…LogSweep.maximumAmplitude`; the
    /// default is that safe level. The first and last `fadeDuration` seconds (at most half the tone each) fade
    /// in and out along a raised cosine, so the tone starts and stops at zero and cannot click. The first
    /// sample has phase zero.
    public static func sine(
        frequency: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Float = LogSweep.maximumAmplitude,
        fadeDuration: Double = 0.02
    ) -> [Float] {
        precondition(sampleRate > 0 && duration >= 0, "sample rate must be positive and duration not negative")
        precondition(frequency > 0 && frequency < sampleRate / 2, "the frequency must lie between 0 and Nyquist")
        let count = Int((duration * sampleRate).rounded())
        let peak = Double(min(max(amplitude, 0), LogSweep.maximumAmplitude))
        let step = 2 * Double.pi * frequency / sampleRate
        let fadeSamples = Int(min(max(fadeDuration, 0), duration / 2) * sampleRate)
        return (0..<count).map { index in
            Float(peak * raisedCosineGain(index: index, count: count, fadeSamples: fadeSamples) * sin(step * Double(index)))
        }
    }

    /// `duration` seconds of zeros at `sampleRate`.
    public static func silence(duration: Double, sampleRate: Double) -> [Float] {
        precondition(sampleRate > 0 && duration >= 0, "sample rate must be positive and duration not negative")
        return [Float](repeating: 0, count: Int((duration * sampleRate).rounded()))
    }

    /// The gain of a raised-cosine fade in over the first `fadeSamples` samples and out over the last: 0 at
    /// both ends, 1 in between.
    static func raisedCosineGain(index: Int, count: Int, fadeSamples: Int) -> Double {
        guard fadeSamples > 0 else { return 1 }
        let fromEnd = count - 1 - index
        let distance = min(index, fromEnd)
        guard distance < fadeSamples else { return 1 }
        return 0.5 * (1 - cos(Double.pi * Double(distance) / Double(fadeSamples)))
    }
}
