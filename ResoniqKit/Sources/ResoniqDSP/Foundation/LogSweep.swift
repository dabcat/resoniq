import Foundation

/// An exponential sine sweep: the test signal every measurement plays.
///
/// The frequency rises exponentially, so each octave gets the same time and the harmonics a speaker adds
/// can be separated from its linear response after deconvolution (Farina's method).
public struct LogSweep: Sendable, Equatable {
    /// The loudest a test signal may be, as a fraction of full scale (−12 dBFS). The one definition of the
    /// safe level; the playback volume is the user's.
    public static let maximumAmplitude: Float = 0.25

    public let startFrequency: Double
    public let endFrequency: Double
    /// Seconds.
    public let duration: Double
    public let sampleRate: Double
    /// Peak, as a fraction of full scale; never above `maximumAmplitude`.
    public let amplitude: Float
    /// Seconds of raised-cosine fade at each end, so the sweep starts and stops without a click.
    public let fadeDuration: Double

    public init(
        startFrequency: Double,
        endFrequency: Double,
        duration: Double,
        sampleRate: Double,
        amplitude: Float = LogSweep.maximumAmplitude,
        fadeDuration: Double = 0.02
    ) {
        precondition(startFrequency > 0 && endFrequency > startFrequency, "the sweep must rise from a positive frequency")
        precondition(endFrequency <= sampleRate / 2, "the sweep ends above the Nyquist frequency")
        precondition(duration > 0 && sampleRate > 0, "duration and sample rate must be positive")
        self.startFrequency = startFrequency
        self.endFrequency = endFrequency
        self.duration = duration
        self.sampleRate = sampleRate
        self.amplitude = min(max(amplitude, 0), LogSweep.maximumAmplitude)
        self.fadeDuration = min(max(fadeDuration, 0), duration / 2)
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
        let fadeSamples = Int(fadeDuration * sampleRate)
        return (0..<count).map { index in
            let time = Double(index) / sampleRate
            let phase = scale * (exp(time / duration * logRatio) - 1)
            var gain = 1.0
            if fadeSamples > 0 {
                let fromEnd = count - 1 - index
                if index < fadeSamples {
                    gain = 0.5 * (1 - cos(Double.pi * Double(index) / Double(fadeSamples)))
                } else if fromEnd < fadeSamples {
                    gain = 0.5 * (1 - cos(Double.pi * Double(fromEnd) / Double(fadeSamples)))
                }
            }
            return Float(Double(amplitude) * gain * sin(phase))
        }
    }
}
