import AVFoundation
import Foundation
import Testing
@testable import ResoniqDSP

/// Real sweep measurements of Geithain RL900A monitors in a real room: per measurement, the played signal
/// (`input_files/INPUT_<n>.flac`, 8 channels at 48 kHz, the sweep on one of channels 0–2), seven microphones
/// (`measurements_without_static_noise/output_files/OUTPUT_<n>.flac`), the room alone
/// (`silence_recordings/SILENCE_<n>.flac`) and a playlist. Third-party data, not in the repository: put it (or a link to
/// it) at `data/geithain-sweeps/` and these tests run; without it they are skipped.
enum GeithainSweeps {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("data/geithain-sweeps")
    static var measurements: URL { folder.appendingPathComponent("measurements_without_static_noise") }

    static func input(_ index: Int) -> URL { folder.appendingPathComponent("input_files/INPUT_\(index).flac") }
    static func output(_ index: Int) -> URL { measurements.appendingPathComponent("output_files/OUTPUT_\(index).flac") }
    static func silence(_ index: Int) -> URL { measurements.appendingPathComponent("silence_recordings/SILENCE_\(index).flac") }

    /// The clean 4 s measurements used here, by speaker (the sweep's channel): the even indices play at a peak of 0.5.
    static let clean: [Int: [Int]] = [0: [0, 2, 4], 1: [720, 722, 724], 2: [1440, 1442, 1444]]

    static func isAvailable(_ indices: [Int]) -> Bool {
        indices.allSatisfy {
            FileManager.default.fileExists(atPath: input($0).path) && FileManager.default.fileExists(atPath: output($0).path)
        } && FileManager.default.fileExists(atPath: silence(0).path)
    }

    /// The room alone recorded for `index`; the first one when there is none for it (the folder holds 932, for the
    /// first indices only). The room and the microphones are the same throughout.
    static func silenceURL(_ index: Int) -> URL {
        FileManager.default.fileExists(atPath: silence(index).path) ? silence(index) : silence(0)
    }

    static var isAvailable: Bool { isAvailable(clean.values.flatMap { $0 }) }

    /// Every channel of a file, and its sample rate.
    static func channels(_ url: URL) throws -> (channels: [[Float]], sampleRate: Double) {
        struct Unreadable: Error {}
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw Unreadable() }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw Unreadable() }
        let count = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: count)) }
        return (channels, file.processingFormat.sampleRate)
    }

    /// The played sweep as `LogSweep` represents it: 50 Hz to 22 kHz over `seconds`, fitted to the input files by
    /// correlation (`playedSweepFits`). It starts half a second (24000 samples) into the files; the deconvolution finds
    /// that lead-in as part of the delay. The files' peak (0.5) is over `LogSweep.maximumAmplitude`, which changes only
    /// the impulse response's scale, which nothing here reads.
    static func sweep(seconds: Double) -> LogSweep {
        LogSweep(startFrequency: 50, endFrequency: 22000, duration: seconds, sampleRate: 48000)
    }

    /// One microphone's run of a measurement, its delay, and the high orders read from it against its own silence.
    static func highOrder(_ index: Int, mic: Int) throws -> SweepHighOrderDistortion {
        let sweep = sweep(seconds: 4)
        let recording = try channels(output(index)).channels[mic]
        let quiet = try channels(silenceURL(index)).channels[mic]
        let impulse = Deconvolution.impulseResponse(recording: recording, sweep: sweep)
        return HighOrderDistortion.analyze(
            recording: recording, sweep: sweep, delay: impulse.delay,
            noise: NoiseFloor.measure(quiet, sampleRate: 48000),
            // From just above the sweep's start, to see the bass the app's own sweep (from 10 Hz) would show.
            measuredBand: 52...(sweep.trustedBand!.upperBound)
        )
    }
}

@Suite(.enabled(if: GeithainSweeps.isAvailable, "the Geithain sweeps are not in data/geithain-sweeps/"))
struct GeithainHighOrderTests {
    @Test(arguments: [0, 720, 1440])
    func `the played sweep is a LogSweep from 50 Hz to 22 kHz`(index: Int) throws {
        let input = try GeithainSweeps.channels(GeithainSweeps.input(index)).channels
        let played = input.max { $0.map(abs).max()! < $1.map(abs).max()! }!
        let sweep = GeithainSweeps.sweep(seconds: 4).samples()
        let piece = Array(played[24000..<(24000 + sweep.count)])
        func energy(_ x: [Float]) -> Double { x.reduce(0) { $0 + Double($1) * Double($1) } }
        let correlation = zip(sweep, piece).reduce(0) { $0 + Double($1.0) * Double($1.1) } / (energy(sweep) * energy(piece)).squareRoot()
        #expect(correlation > 0.99, "\(correlation)")
    }

    static func lock(_ high: SweepHighOrderDistortion, under: Bool) -> Float {
        let values = high.level.frequencies.indices.filter { (high.level.frequencies[$0] < 80) == under }.map { high.locking[$0] }.sorted()
        return values.isEmpty ? .nan : values[values.count / 2]
    }

    /// Medians by band of the tone's frequency, as the coordinator's independent script read them.
    static func summary(_ high: SweepHighOrderDistortion) -> String {
        func median(_ values: [Float]) -> Float { let s = values.sorted(); return s.isEmpty ? .nan : s[s.count / 2] }
        return [(Float(50), Float(80)), (80, 160), (160, 1800)].map { low, up in
            let points = high.level.frequencies.indices.filter { (low..<up).contains(high.level.frequencies[$0]) }
            let over = points.filter { high.isMeasurable(at: high.level.frequencies[$0]) && high.level.decibels[$0] >= -50 }
            return String(format: "%.0f–%.0f Hz %.1f dB (max %.1f), floor %.1f, %d of %d measured ≥ −50",
                          low, up, median(points.map { high.level.decibels[$0] }), points.map { high.level.decibels[$0] }.max() ?? .nan,
                          median(points.map { high.noiseFloor?.decibels[$0] ?? .nan }), over.count, points.count)
        }.joined(separator: " | ") + String(format: " | locking median %.2f under 80 Hz, %.2f over", lock(high, under: true), lock(high, under: false))
    }

    /// The first two speakers read at their noise from 80 Hz up; the first reads its own bass distortion over the
    /// threshold below 80 Hz, which is why findings start there (`DiagnosisThresholds.highOrderLowerFrequency`).
    @Test(arguments: [0, 2, 720, 722])
    func `a healthy monitor measures nothing over the threshold from 80 Hz up`(index: Int) throws {
        for mic in [0, 1, 3] {
            let high = try GeithainSweeps.highOrder(index, mic: mic)
            print("Geithain \(index) mic \(mic): \(Self.summary(high))")
            for (frequency, level) in zip(high.level.frequencies, high.level.decibels) where frequency >= 80 {
                #expect(!(high.isMeasurable(at: frequency) && level >= -50), "\(index) mic \(mic) at \(frequency) Hz: \(level) dB")
            }
        }
    }

    @Test func `the first monitor's bass reads over the threshold below 80 Hz, and less so at half the drive`() throws {
        let full = try GeithainSweeps.highOrder(0, mic: 0)
        let half = try GeithainSweeps.highOrder(1, mic: 0)
        func median(_ high: SweepHighOrderDistortion) -> Float {
            let values = high.level.frequencies.indices.filter { high.level.frequencies[$0] < 80 }.map { high.level.decibels[$0] }.sorted()
            return values[values.count / 2]
        }
        let fullLevel = median(full)
        let halfLevel = median(half)
        print("Geithain 0 under 80 Hz: median level \(fullLevel) dB re the tone at full drive, \(halfLevel) dB at half")
        #expect(full.level.frequencies.contains { $0 < 80 && full.isMeasurable(at: $0) && full.levelDecibels(at: $0) >= -50 })
        // Against the tone it falls when the drive falls, though the noise's share rises: a nonlinearity of the woofer.
        // Leakage of the tone, or a linear room, would stay at the same level against the tone.
        #expect(fullLevel - halfLevel > 2)
    }

    /// The third channel's unit is not a clean reference: it reads −9 to −17 dB above the tenth harmonic in the bass
    /// on every microphone, and THD of 6 to 19 % measured at 400 Hz–2 kHz. The Kit reads it as distorting.
    @Test func `the third channel's unit reads as distorting`() throws {
        let high = try GeithainSweeps.highOrder(1440, mic: 0)
        print("Geithain 1440 mic 0: \(Self.summary(high))")
        #expect(high.levelDecibels(at: 120) > -25)
        // Most of it is not locked to the tone's cycle (median locking 0.24 from 80 Hz up), so it counts as noise here;
        // its THD (orders 2 to 5) is what the diagnosis raises.
        #expect(Self.lock(high, under: false) < HighOrderDistortion.lockingThreshold)
    }
}
