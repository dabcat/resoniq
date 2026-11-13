import Accelerate

/// The level of a buffer of samples, relative to digital full scale.
///
/// dBFS only: the microphone is uncalibrated, so this says nothing about sound pressure, and nothing about which
/// frequencies carry the level.
public struct Level: Sendable, Equatable {
    /// The largest sample magnitude, linear (1 is full scale).
    public var peak: Float
    /// Root mean square of the samples as given, DC included, linear.
    public var rms: Float
    /// The mean of the samples, linear. Anything far from zero points at the input stage, not the room.
    public var dcOffset: Float

    public init(peak: Float, rms: Float, dcOffset: Float) {
        self.peak = peak
        self.rms = rms
        self.dcOffset = dcOffset
    }

    /// The peak in dBFS; `Decibels.floor` for silence.
    public var peakDecibels: Float { Decibels.fromAmplitude(peak) }

    /// The RMS in dBFS; `Decibels.floor` for silence. A full-scale sine reads −3.01 dBFS.
    public var rmsDecibels: Float { Decibels.fromAmplitude(rms) }

    /// Peak over RMS in dB: 3.01 for a sine, 0 for a square wave, 0 for silence. A high figure means the level is
    /// carried by a few transients.
    public var crestFactorDecibels: Float {
        guard rms > 0 else { return 0 }
        return peakDecibels - rmsDecibels
    }
}

/// Measures the level of a buffer. Cheap enough to run on every 100 ms block.
public enum LevelMeter {
    /// Peak, RMS and DC offset of `samples`; all zero for an empty buffer.
    public static func measure(_ samples: [Float]) -> Level {
        guard !samples.isEmpty else { return Level(peak: 0, rms: 0, dcOffset: 0) }
        return Level(
            peak: vDSP.maximumMagnitude(samples),
            rms: vDSP.rootMeanSquare(samples),
            dcOffset: vDSP.mean(samples)
        )
    }
}
