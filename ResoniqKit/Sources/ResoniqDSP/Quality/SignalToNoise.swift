import Foundation

/// Signal-to-noise ratios between a recording and the room's floor, in dB.
///
/// A recording of a sweep also holds the room's noise, so these are (signal + noise) over noise: never below about
/// 0 dB, and close to the true ratio only once it is well above 0. They compare two recordings at one microphone
/// gain; they say nothing about sound pressure.
public enum SignalToNoise {
    /// RMS of `signal` over RMS of `noise`, in dB.
    public static func ratio(signal: Level, noise: Level) -> Float {
        signal.rmsDecibels - noise.rmsDecibels
    }

    /// RMS of the `signal` buffer over RMS of the `noise` buffer, in dB.
    public static func ratio(signal: [Float], noise: [Float]) -> Float {
        ratio(signal: LevelMeter.measure(signal), noise: LevelMeter.measure(noise))
    }

    /// The ratio in each octave band from 31.5 Hz to 16 kHz, in dB, from two buffers at one sample rate.
    /// Low bands may show a poor ratio while the broadband one looks fine: that is where rumble hides.
    public static func bandRatios(signal: [Float], noise: [Float], sampleRate: Double) -> MagnitudeResponse {
        bandRatios(
            signal: NoiseFloor.octaveBandLevels(signal, sampleRate: sampleRate),
            noise: NoiseFloor.octaveBandLevels(noise, sampleRate: sampleRate)
        )
    }

    /// The difference of two band-level responses measured on the same bands (for example a recording's bands
    /// against `NoiseFloorReport.bandLevels`), in dB.
    public static func bandRatios(signal: MagnitudeResponse, noise: MagnitudeResponse) -> MagnitudeResponse {
        precondition(signal.frequencies == noise.frequencies, "signal and noise were measured on different bands")
        return MagnitudeResponse(
            frequencies: signal.frequencies,
            decibels: zip(signal.decibels, noise.decibels).map { $0 - $1 }
        )
    }
}
