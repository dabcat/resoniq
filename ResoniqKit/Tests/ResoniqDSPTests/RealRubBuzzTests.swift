import AVFoundation
import Foundation
import Testing
@testable import ResoniqDSP

/// Real recordings of three units of one loudspeaker model playing a steady tone, published by a maker of test
/// equipment as a good, a borderline and a bad unit for rub and buzz. They are third-party audio and are not in the
/// repository: put them in `data/listen-rub-buzz/` (see `docs/research/2026-11-14-rub-buzz-recordings.md`) and these
/// tests run; without them they are skipped.
enum RubBuzzRecordings {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("data/listen-rub-buzz")
    /// Serial numbers: 57 has strong distortion, 76 is borderline, 97 is the good reference.
    static let units = ["57", "76", "97"]

    static func url(_ unit: String) -> URL {
        folder.appendingPathComponent("rtw-tone-sn-\(unit)-scaled-10E0-Pa-FSD.wav")
    }

    static var isAvailable: Bool { units.allSatisfy { FileManager.default.fileExists(atPath: url($0).path) } }

    /// The settled middle of the tone, and the file's sample rate.
    static func tone(_ unit: String) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url(unit))
        struct Unreadable: Error {}
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw Unreadable() }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { throw Unreadable() }
        let all = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let rate = file.processingFormat.sampleRate
        return (Array(all[Int(rate)..<(all.count - Int(rate))]), rate)
    }

}

@Suite(.enabled(if: RubBuzzRecordings.isAvailable, "the recordings are not in data/listen-rub-buzz/"))
struct RealRubBuzzTests {
    @Test func `the bad unit stands out in what is neither the tone nor a low harmonic, not in THD`() throws {
        var results: [String: ToneDistortionResult] = [:]
        for unit in RubBuzzRecordings.units {
            let (samples, rate) = try RubBuzzRecordings.tone(unit)
            let result = ToneDistortion.analyze(recording: samples, frequency: 256, sampleRate: rate)
            results[unit] = result
            print("sn-\(unit): f0 \(result.fundamentalFrequency ?? .nan) Hz, THD \(result.thdPercent) %, THD+N \(result.thdPlusNoisePercent) %, residue \(result.nonHarmonicResidue) dB, floor \(result.noiseFloorPercent) %")
        }
        let bad = try #require(results["57"])
        let borderline = try #require(results["76"])
        let good = try #require(results["97"])
        #expect(bad.isToneFound && borderline.isToneFound && good.isToneFound)
        // The app's buzz threshold is 10 % THD: the bad unit is far under it, so THD alone calls it clean.
        #expect(bad.thdPercent < 10)
        // What gives it away is the energy above the tenth harmonic.
        #expect(bad.nonHarmonicResidue > borderline.nonHarmonicResidue + 10)
        #expect(bad.nonHarmonicResidue > good.nonHarmonicResidue + 10)
        // The borderline unit reads over the good one, by a few dB only.
        #expect(borderline.nonHarmonicResidue > good.nonHarmonicResidue)
    }
}
