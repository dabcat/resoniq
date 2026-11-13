import Foundation

/// An exponential sine sweep: the test signal every measurement plays.
///
/// The frequency rises exponentially, so each octave gets the same time and the harmonics a speaker adds
/// can be separated from its linear response after deconvolution (Farina's method).
public struct LogSweep: Sendable, Equatable {
    /// The loudest a test signal may be, as a fraction of full scale (−12 dBFS). The one definition of the
    /// safe level; the playback volume is the user's.
    public static let maximumAmplitude: Float = 0.25
    /// The shortest fade a test signal may have, in seconds. A raised cosine over 5 ms (240 samples at 48 kHz)
    /// brings a full-level signal to exactly zero without a step, so the ends cannot click.
    public static let minimumFadeDuration: Double = 0.005
    /// The fade every test signal uses unless told otherwise, in seconds. Kept short on purpose: a longer fade
    /// takes level from the ends of the sweep and narrows the band that can be reported (see `trustedBand`).
    public static let defaultFadeDuration: Double = 0.02

    public let startFrequency: Double
    public let endFrequency: Double
    /// Seconds.
    public let duration: Double
    public let sampleRate: Double
    /// Peak, as a fraction of full scale: the requested amplitude clamped to `0…maximumAmplitude`, and 0 (silence)
    /// when the request was not a finite number.
    public let amplitude: Float
    /// Seconds of raised-cosine fade at each end, so the sweep starts and stops without a click: the requested fade
    /// (the default when it was NaN), at least `minimumFadeDuration` and at most half the sweep. The first and last
    /// samples are exactly zero.
    public let fadeDuration: Double

    public init(
        startFrequency: Double,
        endFrequency: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Float = LogSweep.maximumAmplitude,
        fadeDuration: Double = LogSweep.defaultFadeDuration
    ) {
        precondition(startFrequency > 0 && endFrequency > startFrequency, "the sweep must rise from a positive frequency")
        precondition(endFrequency <= sampleRate / 2, "the sweep ends above the Nyquist frequency")
        precondition(duration > 0 && sampleRate > 0, "duration and sample rate must be positive")
        self.startFrequency = startFrequency
        self.endFrequency = endFrequency
        self.duration = duration
        self.sampleRate = sampleRate
        self.amplitude = LogSweep.safeAmplitude(amplitude)
        self.fadeDuration = RaisedCosine.safeFade(fadeDuration, duration: duration)
    }

    public var sampleCount: Int { Int((duration * sampleRate).rounded()) }

    /// ln(f₂ / f₁)
    public var logRatio: Double { log(endFrequency / startFrequency) }

    /// The frequency being played `time` seconds in.
    public func frequency(at time: Double) -> Double {
        startFrequency * exp(time / duration * logRatio)
    }

    /// When the sweep passes `frequency`, in seconds from its start.
    public func time(of frequency: Double) -> Double {
        duration * log(frequency / startFrequency) / logRatio
    }

    /// How much earlier than the linear response the `order`-th harmonic's response lands after
    /// deconvolution, in seconds (order 2 is the second harmonic).
    public func harmonicAdvance(order: Int) -> Double {
        duration * log(Double(order)) / logRatio
    }

    public func samples() -> [Float] {
        let count = sampleCount
        let scale = 2 * Double.pi * startFrequency * duration / logRatio
        let fadeSamples = RaisedCosine.sampleCount(of: fadeDuration, sampleRate: sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let phase = scale * (exp(time / duration * logRatio) - 1)
            let gain = RaisedCosine.edgeGain(index: index, count: count, fadeSamples: fadeSamples)
            return Float(Double(amplitude) * gain * sin(phase))
        }
    }

    /// `amplitude` made safe: clamped to `0…maximumAmplitude`, and 0 when it is not finite. Silence is safe.
    static func safeAmplitude(_ amplitude: Float) -> Float {
        amplitude.isFinite ? min(max(amplitude, 0), maximumAmplitude) : 0
    }
}
