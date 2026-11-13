import ResoniqDSP

/// A level as the microphone heard it, in dBFS, and the approximate sound level shown on screen.
public struct SoundLevel: Sendable, Equatable {
    /// The offset from dBFS to the "dB" shown on screen ("Quiet · 34 dB").
    ///
    /// *Estimate, first guess*: 110 dB. The iPhone microphone is not calibrated and its gain in measurement mode
    /// differs between models. A MEMS capsule of typical sensitivity (−26 dBFS at 94 dB SPL) gives 120; a quiet room
    /// (30 to 35 dB SPL) has been seen around −75 dBFS in measurement mode, which gives about 110. Every number shown
    /// with it is "approximate", and nothing is decided from it: decisions use dBFS.
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
