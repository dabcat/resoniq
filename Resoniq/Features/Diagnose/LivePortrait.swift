import ResoniqAudio
import ResoniqDiagnostics
import ResoniqDSP

/// The portrait as it fills while a sweep is heard: the level at each moment of the sweep, kept as an envelope, and the
/// Kit's `PortraitProfile.live` drawn from it. Shared by the flows that follow a sweep (`DiagnoseFlow`,
/// `ExternalDiagnoseFlow`), which feed it what the session reports and read `widths` and `heardUpTo`.
///
/// The envelope is kept at 1 kHz: the portrait only needs the level at each moment of the sweep, and the sessions
/// report one block every 100 ms.
struct LivePortrait {
    /// 0...1, bottom (20 Hz) to top (20 kHz): `PortraitProfile.live`.
    private(set) var widths: [Double] = []
    /// The highest frequency drawn so far, hertz.
    private(set) var heardUpTo: Double?

    private static let envelopeRate = 1_000.0
    /// A sweep position this far behind what is drawn means the run started again from the beginning (a resume only
    /// backs up by the overlap, well under this).
    private static let restartTolerance = 1.0

    private let sweep: LogSweep
    private var envelope = LevelEnvelope(sampleRate: envelopeRate)
    private var run = 1

    /// - Parameter sweep: Only used for its time-to-frequency map, which does not depend on the sample rate.
    init(sweep: LogSweep) {
        self.sweep = sweep
    }

    /// Forgets what was drawn.
    mutating func reset() {
        envelope = LevelEnvelope(sampleRate: Self.envelopeRate)
        run = 1
        widths = []
        heardUpTo = nil
    }

    /// Adds one block's level at the moment of the sweep it carries, then redraws from the Kit's
    /// `PortraitProfile.live`. The delay is 0 because `frequency` is already the frequency arriving now. A different
    /// `run` starts the drawing again.
    mutating func ingest(run newRun: Int, frequency: Double?, level: SoundLevel) {
        if newRun != run {
            reset()
            run = newRun
        }
        guard let frequency else { return }
        let moment = sweep.time(of: frequency)
        if moment < envelope.duration - Self.restartTolerance {
            envelope = LevelEnvelope(sampleRate: Self.envelopeRate)
        }
        let missing = Int(((moment - envelope.duration) * Self.envelopeRate).rounded())
        guard missing > 0 else { return }
        let amplitude = Decibels.toAmplitude(level.dBFS)
        envelope.append([Float](repeating: amplitude, count: missing))
        let profile = PortraitProfile.live(envelope: envelope, sweep: sweep, delay: 0)
        widths = profile.widths.map(Double.init)
        heardUpTo = profile.heardUpTo.map(Double.init)
    }
}
