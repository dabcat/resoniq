import Foundation

/// Steady test signals: a tone and silence. The sweep is `LogSweep`.
public enum TestSignal {
    /// A sine at `frequency` hertz lasting `duration` seconds, as samples at `sampleRate`.
    ///
    /// The peak is `amplitude` as a fraction of full scale, clamped to `0…LogSweep.maximumAmplitude` and 0 when it
    /// is not finite; the default is that safe level. The first and last `fadeDuration` seconds fade in and out
    /// along a raised cosine, the fade made safe exactly as `LogSweep` makes it (the default when NaN, at least
    /// `LogSweep.minimumFadeDuration`, at most half the tone), so the first and last samples are exactly zero and
    /// the tone cannot click. The first sample has phase zero.
    public static func sine(
        frequency: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Float = LogSweep.maximumAmplitude,
        fadeDuration: Double = LogSweep.defaultFadeDuration
    ) -> [Float] {
        precondition(sampleRate > 0 && duration >= 0, "sample rate must be positive and duration not negative")
        precondition(frequency > 0 && frequency < sampleRate / 2, "the frequency must lie between 0 and Nyquist")
        let count = Int((duration * sampleRate).rounded())
        let peak = Double(LogSweep.safeAmplitude(amplitude))
        let step = 2 * Double.pi * frequency / sampleRate
        let fade = RaisedCosine.safeFade(fadeDuration, duration: duration)
        let fadeSamples = RaisedCosine.sampleCount(of: fade, sampleRate: sampleRate)
        return (0..<count).map { index in
            Float(peak * RaisedCosine.edgeGain(index: index, count: count, fadeSamples: fadeSamples) * sin(step * Double(index)))
        }
    }

    /// `duration` seconds of zeros at `sampleRate`.
    public static func silence(duration: Double, sampleRate: Double) -> [Float] {
        precondition(sampleRate > 0 && duration >= 0, "sample rate must be positive and duration not negative")
        return [Float](repeating: 0, count: Int((duration * sampleRate).rounded()))
    }
}
