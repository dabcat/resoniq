import Foundation

/// Conversions between linear amplitude and decibels. Full scale (1.0) is 0 dB.
public enum Decibels {
    /// What silence converts to, instead of minus infinity.
    public static let floor: Float = -160

    public static func fromAmplitude(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return floor }
        return max(20 * log10(amplitude), floor)
    }

    public static func fromPower(_ power: Float) -> Float {
        guard power > 0 else { return floor }
        return max(10 * log10(power), floor)
    }

    public static func toAmplitude(_ decibels: Float) -> Float {
        pow(10, decibels / 20)
    }
}
