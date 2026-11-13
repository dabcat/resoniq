import ResoniqDSP

/// A level as the microphone heard it, in dBFS, and the approximate sound level shown on screen.
public struct SoundLevel: Sendable, Equatable {
    /// The offset from dBFS to the "dB" shown on screen ("Quiet · 34 dB").
    ///
    /// *Estimate, first guess*: 110 dB. Levels here are dBFS RMS, the DSP's one convention (`Level.rmsDecibels`): a
    /// full-scale sine reads −3.01 dBFS, so 107 "dB" on screen. The constant is unchanged by the DSP's move to that
    /// convention because the level it is applied to (`LevelMeter`'s RMS) was RMS before and after. What it rests
    /// on: a quiet room (30 to 35 dB SPL) has been seen around −75 dBFS RMS in measurement mode, which gives about
    /// 110. A MEMS capsule datasheet's sensitivity (typically −26 dBFS for a 94 dB SPL sine, with a full-scale sine
    /// as 0 dBFS) reads −29 dBFS RMS here and would give 123; the two disagree by more than the guess is worth, which
    /// is why it is an estimate. The iPhone microphone is not calibrated and its gain in measurement mode differs
    /// between models. Every number shown with it is "approximate", and nothing is decided from it: decisions use
    /// dBFS.
    public static let approximateOffsetDecibels: Float = 110

    /// RMS, dBFS.
    public var dBFS: Float

    public init(dBFS: Float) {
        self.dBFS = dBFS
    }

    /// The approximate sound level in dB for the screen: `dBFS + approximateOffsetDecibels`, never below 0.
    public var approximateDecibels: Float { max(dBFS + Self.approximateOffsetDecibels, 0) }

    /// The RMS level of `samples`.
    public init(of samples: [Float]) {
        self.dBFS = LevelMeter.measure(samples).rmsDecibels
    }
}
