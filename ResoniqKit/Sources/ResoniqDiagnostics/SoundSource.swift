import Foundation

/// How the test sound was played, as a report keeps it. A report without one was measured the normal way: the phone
/// played the sound through the user's speakers.
///
/// **No caveat about the player's clock.** Another device's clock is corrected before analysis (`SweepFinder` in
/// `ResoniqDSP`), and corrected, an offset of up to ±500 ppm measures within 0.01 dB of none over 20 Hz to 20 kHz and
/// within 0.2 % of the distortion figure (`ClockOffsetAccuracyTests`): as accurately as the normal way. So the
/// report says how the sound was played and nothing more; it does not lower its confidence for the clock.
public enum SoundSource: String, Sendable, Codable, Hashable {
    /// A test sound file played on another device while the phone listened.
    case anotherDevice
}

extension DiagnosisText {
    /// The line the result screens show for a report measured from another device; nil for the normal way.
    public static func sourceNote(_ source: SoundSource?) -> String? {
        switch source {
        case .anotherDevice: measuredFromAnotherDevice
        case nil: nil
        }
    }

    /// "Measured from a test sound played on another device."
    public static let measuredFromAnotherDevice = "Measured from a test sound played on another device."

    /// What the Finding screen says instead of offering hold-to-hear when the sound came from another device: the
    /// phone cannot play the tone itself. `frequency` is the finding's, as the screen writes it ("120 Hz"); nil for a
    /// finding without one.
    ///
    /// - "I can't play the tone myself in this mode, because the sound comes from your own player. To hear it, play
    ///   the test sound file again and listen as it passes 120 Hz."
    public static func holdToHearUnavailable(frequency: String?) -> String {
        "I can't play the tone myself in this mode, because the sound comes from your own player. To hear it, play the test sound file again and listen "
            + (frequency.map { "as it passes \($0)." } ?? "as it plays.")
    }
}

extension SeatText {
    /// The line the Measure result shows for a seat measured from another device; nil for the normal way. The same
    /// words as `DiagnosisText.sourceNote(_:)`.
    public static func sourceNote(_ source: SoundSource?) -> String? {
        DiagnosisText.sourceNote(source)
    }
}
