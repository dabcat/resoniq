import Foundation
import ResoniqDSP

/// Another device playing a test sound file into a `SimulatedAudioIO` (`SimulatedAudioIO.playExternally(_:)`): for
/// the tests of the listening sessions and for the app in the iOS simulator, where nothing can play a file to the
/// microphone.
///
/// The file is played on the player's own clock: every piece of it (the clock tone, each sweep) is resampled by
/// `clockRatio` (`Interpolation`) before it enters the simulated speakers, so a player running 300 ppm fast arrives
/// 300 ppm short and 300 ppm sharp, as on a device. Only the pieces are rendered, not the silence between them.
public struct SimulatedExternalPlay: Sendable, Hashable {
    public var file: TestSoundFile
    /// Seconds from the call to the file's first sample leaving the player: the user's hand, and the player's own
    /// start-up. The route's delay (`SimulatedAudioIO.Configuration.routeDelay`) comes on top.
    public var delay: Double
    /// The player's clock against the phone's: above 1 it runs fast.
    public var clockRatio: Double
    /// The player's volume, linear: 1 plays the file as written; the speakers' gain comes on top.
    public var gain: Double
    /// Noise at the microphone during the play; each `.at` start is counted from the file's first sample (other
    /// starts are ignored).
    public var bursts: [NoiseBurst]

    public init(file: TestSoundFile, delay: Double = 0.5, clockRatio: Double = 1, gain: Double = 1, bursts: [NoiseBurst] = []) {
        precondition(clockRatio > 0.9 && clockRatio < 1.1, "a simulated player's clock is within 10 % of the phone's")
        self.file = file
        self.delay = delay
        self.clockRatio = clockRatio
        self.gain = gain
        self.bursts = bursts
    }

    /// The pieces of the file as the phone's clock sees them.
    struct Rendered: Sendable {
        struct Piece: Sendable {
            /// Samples from the play's start, on the phone's clock.
            var offset: Int64
            var samples: [Float]
            var channel: SpeakerChannel
        }

        var pieces: [Piece]

        init(_ play: SimulatedExternalPlay, sampleRate: Double) {
            let file = play.file
            let layout = file.layout
            let ratio = play.clockRatio * layout.sampleRate / sampleRate
            let tone = TestSignal.sine(
                frequency: SweepFinder.clockToneFrequency,
                duration: SweepFinder.clockToneDuration,
                sampleRate: layout.sampleRate,
                amplitude: SweepFinder.clockToneAmplitude
            )
            let sweep = LogSweep.measurement(sampleRate: layout.sampleRate).samples()
            var placed: [(samples: [Float], offset: Int, channel: SpeakerChannel)] = [(tone, layout.tone.offset, layout.tone.channel)]
            for piece in layout.sweeps { placed.append((sweep, piece.offset, piece.channel)) }
            let margin = Interpolation.halfWidth
            pieces = placed.map { content, offset, channel in
                // Output sample m (on the phone's clock, from the play's start) reads the file at m · ratio.
                let first = Int((Double(offset) / ratio).rounded(.down)) - margin
                let count = Int((Double(content.count) / ratio).rounded(.up)) + 2 * margin
                var samples = ratio == 1 && first + margin == offset
                    ? [Float](repeating: 0, count: margin) + content + [Float](repeating: 0, count: margin)
                    : Interpolation.resample(content, from: Double(first) * ratio - Double(offset), step: ratio, count: count)
                if play.gain != 1 { samples = samples.map { $0 * Float(play.gain) } }
                return Piece(offset: Int64(first), samples: samples, channel: channel)
            }
        }
    }
}
