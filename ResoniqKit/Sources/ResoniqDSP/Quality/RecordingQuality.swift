import Foundation

/// Whether a recording is fit to analyse and, if not, the numbers that say why.
///
/// A verdict judges the recording, not the speaker: `tooNoisy` says the room drowned the measurement, never that
/// the speaker is quiet or faulty.
public enum RecordingVerdict: Sendable, Equatable {
    /// Fit to analyse: the recording's level and its broadband signal-to-noise ratio in dB.
    case valid(level: Level, signalToNoise: Float)
    /// Some of the waveform was pinned at one value; lowering the playback volume or moving away helps.
    case clipped(ClippingReport)
    /// The peak was under the minimum; raising the playback volume or moving closer helps.
    case tooQuiet(level: Level)
    /// The room was too loud against the recording, or the floor was not steady when it was measured. Carries the
    /// broadband signal-to-noise ratio in dB and the floor it was measured against.
    case tooNoisy(signalToNoise: Float, noiseFloor: NoiseFloorReport)
    /// The microphone delivered nothing: permission, routing or hardware, not the room.
    case silent(level: Level)
    /// Some samples were not finite numbers (NaN or infinity): the data is broken, upstream of the room and the
    /// speaker. Carries how many. Nothing in such a recording is analysed.
    case corrupt(nonFiniteSampleCount: Int)
}

/// Decides whether a finished recording is fit to analyse.
public enum RecordingQuality {
    /// The verdict on `recording` given the room's `noiseFloor`, measured at the same microphone gain.
    ///
    /// The checks run in this order, and the first that fails decides, so the problem the user can fix first
    /// is the one reported:
    /// 1. **Corrupt**: a sample that is not a finite number poisons every level computed from it.
    /// 2. **Silent**: nothing else can be judged in an empty recording.
    /// 3. **Clipped**: a clipped waveform is wrong however loud or quiet the rest is.
    /// 4. **Too quiet**: turning the volume up also raises the signal-to-noise ratio, so it comes before noise.
    /// 5. **Too noisy**: the ratio is under the minimum, or the floor was not steady (a corrupt floor never is) and
    ///    so cannot be trusted.
    ///
    /// The signal level is the whole recording's RMS, so silence before and after the sweep lowers it slightly.
    /// The ratio is broadband; one band can be drowned while this passes (see `SignalToNoise.bandRatios`).
    public static func assess(
        recording: [Float],
        noiseFloor: NoiseFloorReport,
        thresholds: QualityThresholds = .standard
    ) -> RecordingVerdict {
        let nonFinite = LevelMeter.nonFiniteCount(recording)
        if nonFinite > 0 {
            return .corrupt(nonFiniteSampleCount: nonFinite)
        }
        let level = LevelMeter.measure(recording)
        if level.peakDecibels <= thresholds.silencePeakDecibels {
            return .silent(level: level)
        }
        let clipping = ClippingDetector.detect(recording, thresholds: thresholds)
        if clipping.isClipped {
            return .clipped(clipping)
        }
        if level.peakDecibels < thresholds.minimumPeakDecibels {
            return .tooQuiet(level: level)
        }
        let signalToNoise = level.rmsDecibels - noiseFloor.rmsDecibels
        if signalToNoise < thresholds.minimumSignalToNoiseDecibels || !noiseFloor.isSteady {
            return .tooNoisy(signalToNoise: signalToNoise, noiseFloor: noiseFloor)
        }
        return .valid(level: level, signalToNoise: signalToNoise)
    }
}
