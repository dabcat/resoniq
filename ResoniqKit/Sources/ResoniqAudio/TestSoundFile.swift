import Foundation
import ResoniqDSP

/// Where everything sits in a test sound file, in samples at `sampleRate`.
public struct TestSoundLayout: Sendable, Equatable {
    /// One sweep of the file.
    public struct Sweep: Sendable, Equatable {
        /// The sample of the file at which the sweep's first sample sits.
        public var offset: Int
        /// The channel it is on; `both` is the same samples on left and right.
        public var channel: SpeakerChannel
        /// Its length: `LogSweep.measurement(sampleRate:)`'s `sampleCount`.
        public var count: Int
    }

    /// The clock tone (`SweepFinder.clockToneFrequency`), before the sweeps.
    public struct Tone: Sendable, Equatable {
        public var offset: Int
        public var channel: SpeakerChannel
        public var count: Int
    }

    public var sampleRate: Double
    public var tone: Tone
    /// In the order they play.
    public var sweeps: [Sweep]
    /// The file's length in samples per channel.
    public var totalSamples: Int

    /// The file's length, seconds.
    public var duration: Double { Double(totalSamples) / sampleRate }

    /// Seconds from one sweep's start to the next's; nil for a file of one sweep.
    public var spacing: Double? {
        guard sweeps.count >= 2 else { return nil }
        return Double(sweeps[1].offset - sweeps[0].offset) / sampleRate
    }
}

/// A test sound to play from another device: the measurement sweep, at the safe level, in a WAV file the user plays
/// on their own system while the phone only listens (`ExternalMeasurementSession`, `ExternalSeatMeasurementSession`).
///
/// **What is in a file.** `leadIn` of silence, so pressing play is not heard as part of the measurement; the clock
/// tone (`SweepFinder.clockToneFrequency` for `SweepFinder.clockToneDuration`, on the measured channel, or the left
/// one for a pair), from which the phone reads the player's clock; the kind's `toneGap(for:)` of silence; the sweeps, separated by the
/// kind's `gap`; and `tail` of silence. A speaker test has three sweeps on its channel; a seat file has one on the
/// left then one on the right, or one on both channels for a single speaker.
///
/// **The gaps tell the files apart.** One microphone cannot hear which speaker a sweep came from, so the files are
/// told apart by timing instead. Each kind has its own silence between the tone and the first sweep
/// (`toneGap(for:)`), so the time from the tone to any sweep heard says which file is playing and which of its sweeps
/// that is (`identify(secondsAfterTone:)`); and each kind with more than one sweep has its own gap between sweeps
/// (`gap(for:)`), so two sweeps heard without the tone say it too (`kind(forSpacing:)`). The kinds are half a second
/// apart in both; a clock offset of `SweepFinder.maximumClockOffset` moves a timing by 20 ms at most and the
/// distance between two speakers by a few, far inside `spacingTolerance`. What cannot be told is which speaker
/// actually played: a left file played through a swapped cable sounds like a left file.
///
/// **Why the gaps are as long as they are.** Each gap must hold the recording kept after a sweep
/// (`recordedTail(for:)`: the configuration's `minimumTail` and `decayHold` and one block) and then let the room die
/// away for `roomDecayAllowance` before the next sweep; a seat recording keeps 2 s after its sweep for the bass decay
/// estimate (`MeasurementConfiguration.seat`), so the seat file's gap is the longest. The checks are in the tests.
///
/// **Format.** WAV, PCM, 48 kHz, stereo, 24-bit, written by hand (`data()`), byte for byte testable. 24-bit because
/// the samples then pass through unchanged to 2⁻²³ (−138 dBFS), 120 dB under the sweep's −12 dBFS peak, so no dither
/// is needed and no quantisation distortion can enter the distortion figures. 16-bit would be adequate for the noise
/// (−98 dBFS) but without dither its error is correlated with the sweep and reads as distortion around −90 dB.
/// Some old players read only 16-bit WAV; that is for the device checklist.
public struct TestSoundFile: Sendable, Hashable {
    /// What the file is for.
    public enum Kind: Sendable, Hashable {
        /// Three sweeps on one channel (`both`: on both at once), for testing one speaker.
        case speakerTest(SpeakerChannel)
        /// One sweep per channel, in order: `[.left, .right]` for a pair, `[.both]` for one speaker. Played once at
        /// each of the three spots.
        case seat([SpeakerChannel])
    }

    /// The file's sample rate, hertz. A player that runs at 44.1 kHz resamples it; what is left is its clock's offset.
    public static let sampleRate: Double = 48000
    /// Silence before the clock tone, seconds. *First guess*: 3 s, time for the press of play to die away.
    public static let leadIn: Double = 3
    /// Silence between the clock tone's end and the first sweep, seconds: at least 2 s, for the tone's reverberation
    /// to die away, and different for each kind: 2 s for a left speaker test, 2.5 s right, 3 s both, 3.5 s a seat
    /// pair, 4 s a seat file of one speaker.
    public static func toneGap(for kind: Kind) -> Double {
        switch kind {
        case .speakerTest(.left): 2
        case .speakerTest(.right): 2.5
        case .speakerTest(.both): 3
        case .seat(let channels): channels.count > 1 ? 3.5 : 4
        }
    }

    /// The kind of file, and which of its sweeps (0-based), that puts a sweep `seconds` after the start of its clock
    /// tone, within `spacingTolerance`; nil when none does. The seconds are the file's: divide what was heard by the
    /// clock ratio when it is known (it moves them by 20 ms at most).
    public static func identify(secondsAfterTone seconds: Double) -> (kind: Kind, index: Int)? {
        for kind in allKinds {
            let layout = TestSoundFile(kind: kind).layout
            for (index, sweep) in layout.sweeps.enumerated() {
                let expected = Double(sweep.offset - layout.tone.offset) / layout.sampleRate
                if abs(seconds - expected) <= spacingTolerance { return (kind, index) }
            }
        }
        return nil
    }
    /// Silence after the last sweep, seconds: at least the seat's recorded tail.
    public static let tail: Double = 3
    /// The time a room is given to fall quiet after the recorded tail, before the next sweep, seconds. *First guess*:
    /// 1 s, a reverberation time of a large living room.
    public static let roomDecayAllowance: Double = 1
    /// How far a heard spacing may be from a kind's for the file to be taken for that kind, seconds.
    public static let spacingTolerance: Double = 0.2
    /// Speaker test files take three sweeps: one test (`MeasurementConfiguration.runCount`).
    public static let speakerTestSweepCount = 3

    public let kind: Kind

    public init(kind: Kind) {
        if case .seat(let channels) = kind {
            precondition(channels == [.left, .right] || channels == [.both], "a seat file plays left then right, or both once")
        }
        self.kind = kind
    }

    /// Silence between one sweep's end and the next's start, seconds: 3 s for a left speaker test, 3.5 s for the right,
    /// 4 s for both, 4.5 s for a seat pair; 0 for a file of one sweep.
    public static func gap(for kind: Kind) -> Double {
        switch kind {
        case .speakerTest(.left): 3
        case .speakerTest(.right): 3.5
        case .speakerTest(.both): 4
        case .seat(let channels): channels.count > 1 ? 4.5 : 0
        }
    }

    /// Every kind of file.
    public static let allKinds: [Kind] = [
        .speakerTest(.left), .speakerTest(.right), .speakerTest(.both), .seat([.left, .right]), .seat([.both]),
    ]

    /// The kind of file whose spacing (sweep length plus gap) is within `spacingTolerance` of `seconds`, also when
    /// one sweep between was missed (twice the spacing); nil when none is.
    public static func kind(forSpacing seconds: Double) -> Kind? {
        allKinds.first { kind in
            guard let spacing = TestSoundFile(kind: kind).layout.spacing else { return false }
            return abs(seconds - spacing) <= spacingTolerance || abs(seconds - 2 * spacing) <= spacingTolerance
        }
    }

    /// Recording kept after each sweep's end by the listening sessions, seconds: `minimumTail`, `decayHold` and one
    /// block of `configuration`. The one definition the files' gaps and the sessions share.
    public static func recordedTail(for configuration: MeasurementConfiguration) -> Double {
        configuration.minimumTail + configuration.decayHold + configuration.blockDuration
    }

    /// The channel the clock tone plays on.
    var toneChannel: SpeakerChannel {
        switch kind {
        case .speakerTest(let channel): channel
        case .seat(let channels): channels.count > 1 ? .left : .both
        }
    }

    /// The channels of the sweeps, in order.
    public var sweepChannels: [SpeakerChannel] {
        switch kind {
        case .speakerTest(let channel): Array(repeating: channel, count: Self.speakerTestSweepCount)
        case .seat(let channels): channels
        }
    }

    public var layout: TestSoundLayout {
        let rate = Self.sampleRate
        func samples(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }
        let sweepCount = LogSweep.measurement(sampleRate: rate).sampleCount
        let toneCount = samples(SweepFinder.clockToneDuration)
        let tone = TestSoundLayout.Tone(offset: samples(Self.leadIn), channel: toneChannel, count: toneCount)
        var offset = tone.offset + toneCount + samples(Self.toneGap(for: kind))
        var sweeps: [TestSoundLayout.Sweep] = []
        for channel in sweepChannels {
            if !sweeps.isEmpty { offset += samples(Self.gap(for: kind)) }
            sweeps.append(TestSoundLayout.Sweep(offset: offset, channel: channel, count: sweepCount))
            offset += sweepCount
        }
        return TestSoundLayout(sampleRate: rate, tone: tone, sweeps: sweeps, totalSamples: offset + samples(Self.tail))
    }

    /// The file's two channels, linear, full scale 1: exactly the samples `data()` writes before quantisation.
    public func channels() -> (left: [Float], right: [Float]) {
        let layout = layout
        var left = [Float](repeating: 0, count: layout.totalSamples)
        var right = [Float](repeating: 0, count: layout.totalSamples)
        func place(_ samples: [Float], at offset: Int, on channel: SpeakerChannel) {
            let range = offset..<(offset + samples.count)
            if channel != .right { left.replaceSubrange(range, with: samples) }
            if channel != .left { right.replaceSubrange(range, with: samples) }
        }
        let tone = TestSignal.sine(
            frequency: SweepFinder.clockToneFrequency,
            duration: SweepFinder.clockToneDuration,
            sampleRate: layout.sampleRate,
            amplitude: SweepFinder.clockToneAmplitude
        )
        place(tone, at: layout.tone.offset, on: layout.tone.channel)
        let sweep = LogSweep.measurement(sampleRate: layout.sampleRate).samples()
        for placed in layout.sweeps { place(sweep, at: placed.offset, on: placed.channel) }
        return (left, right)
    }

    // MARK: The WAV file

    /// Bits per sample.
    public static let bitDepth = 24

    /// The whole file: a 44-byte RIFF/WAVE header (`fmt ` chunk, PCM format 1, 2 channels, `sampleRate`, 24 bits)
    /// and the interleaved samples, little-endian, each `round(x · 2²³)` held to the 24-bit range.
    public func data() -> Data {
        let (left, right) = channels()
        let frames = left.count
        let bytesPerSample = Self.bitDepth / 8
        let channelCount = 2
        let dataSize = frames * channelCount * bytesPerSample
        var data = Data(capacity: 44 + dataSize)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)
        append16(UInt16(channelCount))
        append32(UInt32(Self.sampleRate))
        append32(UInt32(Int(Self.sampleRate) * channelCount * bytesPerSample))
        append16(UInt16(channelCount * bytesPerSample))
        append16(UInt16(Self.bitDepth))
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))

        var bytes = [UInt8](repeating: 0, count: dataSize)
        let leftCodes = Self.codes(left)
        let rightCodes = Self.codes(right)
        bytes.withUnsafeMutableBufferPointer { buffer in
            // Per sample, so written for a debug build too: plain stores, no temporary arrays.
            var index = 0
            var frame = 0
            while frame < frames {
                var bits = UInt32(bitPattern: leftCodes[frame])
                buffer[index] = UInt8(truncatingIfNeeded: bits)
                buffer[index + 1] = UInt8(truncatingIfNeeded: bits >> 8)
                buffer[index + 2] = UInt8(truncatingIfNeeded: bits >> 16)
                bits = UInt32(bitPattern: rightCodes[frame])
                buffer[index + 3] = UInt8(truncatingIfNeeded: bits)
                buffer[index + 4] = UInt8(truncatingIfNeeded: bits >> 8)
                buffer[index + 5] = UInt8(truncatingIfNeeded: bits >> 16)
                index += 6
                frame += 1
            }
        }
        data.append(contentsOf: bytes)
        return data
    }

    /// Writes `data()` to `url`, replacing what is there.
    public func write(to url: URL) throws {
        try data().write(to: url, options: .atomic)
    }

    /// The 24-bit code of each sample: `round(x · 2²³)`, held to −2²³ … 2²³ − 1.
    static func codes(_ samples: [Float]) -> [Int32] {
        let full = Float(1 << 23)
        return samples.map { Int32(min(max(($0 * full).rounded(), -full), full - 1)) }
    }

    /// The value a sample has once written and read back: its 24-bit code over 2²³.
    public static func quantised(_ sample: Float) -> Float {
        Float(codes([sample])[0]) / Float(1 << 23)
    }

    // MARK: Words

    /// The name to save the file under ("Resoniq test sound - left speaker.wav").
    public var suggestedFileName: String { ExternalSessionText.fileName(for: kind) }

    /// One line on what the file is for ("Three sweeps on the left speaker, for testing it. About 28 seconds.").
    public var summary: String { ExternalSessionText.fileSummary(for: kind, duration: layout.duration) }
}
