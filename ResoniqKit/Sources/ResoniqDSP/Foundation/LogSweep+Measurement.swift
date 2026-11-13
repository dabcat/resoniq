import Foundation

extension LogSweep {
    /// How far above the start the response is trusted, as a ratio: one octave. Below it the deconvolution's low
    /// cut (`Deconvolution.lowStopRatio`, `lowCutRatio`) and the 100 ms window's limited resolution bend the bass.
    public static let trustedStartRatio: Double = 2
    /// How far below the end the response is trusted, in octaves: a twelfth. Above it the deconvolution's edge
    /// at the end of the sweep rings and the response falls away (−0.7 dB at the end itself).
    public static let trustedEndMargin: Double = 1.0 / 12

    /// The frequencies, in hertz, over which a response measured with this sweep is reported, because there it is
    /// accurate: from `trustedStartRatio` times the start to `trustedEndMargin` octaves under the end. Nil when the
    /// sweep is too narrow to leave any.
    ///
    /// The accuracy, for a start of 10 Hz or more and the default 100 ms window: a system that passes the sweep
    /// unchanged reads flat within 0.3 dB across the band and within 0.1 dB from three times the start. It holds
    /// for sweeps of 1 s and longer; harmonic distortion needs `HarmonicDistortion.minimumAccurateDuration`.
    public var trustedBand: ClosedRange<Double>? {
        let lower = startFrequency * Self.trustedStartRatio
        let upper = endFrequency * pow(2, -Self.trustedEndMargin)
        return lower < upper ? lower...upper : nil
    }

    /// The band the app reports a frequency response over, in hertz: 20 Hz to 20 kHz. The measurement sweep is
    /// wider so that this band lies inside its `trustedBand`.
    public static let reportedBand: ClosedRange<Double> = 20...20000

    /// The measurement sweep's start, end and length: 10 Hz to 22 kHz over 4 seconds.
    ///
    /// 10 Hz puts the trusted band's bottom at 20 Hz. 22 kHz is under the Nyquist frequency of 44.1 kHz and puts
    /// its top above 20 kHz. Four seconds clears `HarmonicDistortion.minimumAccurateDuration` with room to spare
    /// and buys 1.2 dB of signal-to-noise over three.
    public static let measurementStartFrequency: Double = 10
    public static let measurementEndFrequency: Double = 22000
    public static let measurementDuration: Double = 4

    /// The sweep every measurement plays: `measurementStartFrequency` to `measurementEndFrequency` over
    /// `measurementDuration`, at the safe level with the default fade. Its `trustedBand` covers `reportedBand`.
    /// The sample rate must be at least 44.1 kHz.
    public static func measurement(sampleRate: Double) -> LogSweep {
        precondition(sampleRate >= 44100, "the measurement sweep needs a sample rate of at least 44.1 kHz")
        return LogSweep(
            startFrequency: measurementStartFrequency,
            endFrequency: measurementEndFrequency,
            duration: measurementDuration,
            sampleRate: sampleRate
        )
    }

    /// The minimum length, in seconds, for which every accuracy stated in the module holds (the harmonic
    /// distortion's being the most demanding).
    public static var minimumAccurateDuration: Double { HarmonicDistortion.minimumAccurateDuration }
}
