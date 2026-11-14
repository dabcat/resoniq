import AVFAudio
import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqAudio

@Suite struct TestSoundFileTests {
    static let kinds = TestSoundFile.allKinds

    @Test(arguments: TestSoundFileTests.kinds)
    func `the file reads back to the exact samples where the layout says`(kind: TestSoundFile.Kind) throws {
        let file = TestSoundFile(kind: kind)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try file.write(to: url)

        let read = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(read.fileFormat.sampleRate == 48000)
        #expect(read.fileFormat.channelCount == 2)
        #expect(read.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 24)
        let layout = file.layout
        #expect(Int(read.length) == layout.totalSamples)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: AVAudioFrameCount(read.length)))
        try read.read(into: buffer)
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength)))

        let sweep = LogSweep.measurement(sampleRate: 48000).samples().map(TestSoundFile.quantised)
        for placed in layout.sweeps {
            let range = placed.offset..<(placed.offset + placed.count)
            if placed.channel != .right { #expect(Array(left[range]) == sweep) }
            if placed.channel != .left { #expect(Array(right[range]) == sweep) }
            if placed.channel == .left { #expect(right[range].allSatisfy { $0 == 0 }) }
            if placed.channel == .right { #expect(left[range].allSatisfy { $0 == 0 }) }
        }
        let tone = TestSignal.sine(
            frequency: SweepFinder.clockToneFrequency, duration: SweepFinder.clockToneDuration, sampleRate: 48000,
            amplitude: SweepFinder.clockToneAmplitude
        ).map(TestSoundFile.quantised)
        let toneRange = layout.tone.offset..<(layout.tone.offset + layout.tone.count)
        #expect(Array((layout.tone.channel == .right ? right : left)[toneRange]) == tone)
        // Silence where nothing is placed: the lead-in and the tail.
        #expect(left[0..<layout.tone.offset].allSatisfy { $0 == 0 } && right[0..<layout.tone.offset].allSatisfy { $0 == 0 })
        let lastEnd = layout.sweeps.last.map { $0.offset + $0.count } ?? 0
        #expect(left[lastEnd...].allSatisfy { $0 == 0 } && right[lastEnd...].allSatisfy { $0 == 0 })
        // Never above the safe level.
        #expect((left + right).map(abs).max() ?? 1 <= LogSweep.maximumAmplitude)
    }

    @Test func `the silent channel of a left speaker file is exactly zero`() {
        let (left, right) = TestSoundFile(kind: .speakerTest(.left)).channels()
        #expect(right.allSatisfy { $0 == 0 })
        #expect(left.contains { $0 != 0 })
        let (_, rightOfRight) = TestSoundFile(kind: .speakerTest(.right)).channels()
        #expect(rightOfRight.contains { $0 != 0 })
    }

    @Test func `the header is a valid 24-bit stereo PCM WAVE header`() {
        let file = TestSoundFile(kind: .seat([.both]))
        let data = file.data()
        func u32(_ offset: Int) -> UInt32 { data[offset..<(offset + 4)].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        func u16(_ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
        func text(_ offset: Int) -> String { String(decoding: data[offset..<(offset + 4)], as: UTF8.self) }
        let frames = file.layout.totalSamples
        #expect(text(0) == "RIFF")
        #expect(Int(u32(4)) == data.count - 8)
        #expect(text(8) == "WAVE")
        #expect(text(12) == "fmt ")
        #expect(u32(16) == 16)
        #expect(u16(20) == 1)
        #expect(u16(22) == 2)
        #expect(u32(24) == 48000)
        #expect(u32(28) == 48000 * 2 * 3)
        #expect(u16(32) == 6)
        #expect(u16(34) == 24)
        #expect(text(36) == "data")
        #expect(Int(u32(40)) == frames * 6)
        #expect(data.count == 44 + frames * 6)
    }

    @Test func `the gaps hold each recording's tail and the room's decay`() {
        let speakerTail = TestSoundFile.recordedTail(for: .standard)
        let seatTail = TestSoundFile.recordedTail(for: .seat)
        // The seat recording keeps its 2 s for the bass decay estimate.
        #expect(seatTail >= MeasurementConfiguration.seat.minimumTail)
        for kind in TestSoundFileTests.kinds {
            let tail = if case .seat = kind { seatTail } else { speakerTail }
            if TestSoundFile(kind: kind).layout.sweeps.count > 1 {
                #expect(TestSoundFile.gap(for: kind) >= tail + TestSoundFile.roomDecayAllowance, "\(kind)")
            }
            #expect(TestSoundFile.toneGap(for: kind) >= 2)
        }
        #expect(TestSoundFile.tail >= seatTail)
    }

    @Test func `every sweep of every file is told apart by its time after the tone`() {
        for kind in TestSoundFileTests.kinds {
            let layout = TestSoundFile(kind: kind).layout
            for (index, sweep) in layout.sweeps.enumerated() {
                let seconds = Double(sweep.offset - layout.tone.offset) / 48000
                for error in [-0.15, 0, 0.15] {
                    let found = TestSoundFile.identify(secondsAfterTone: seconds + error)
                    #expect(found?.kind == kind && found?.index == index, "\(kind) sweep \(index) at \(seconds + error) s")
                }
            }
        }
        #expect(TestSoundFile.identify(secondsAfterTone: 8) == nil)
    }

    /// The timing the listening sessions use, from the tone's end: half a second apart between kinds, so a misread
    /// end, the follower's estimate of a sweep's start and the clock (20 ms at most) fit in the tolerance.
    @Test func `every sweep of every file is told apart by its time after the tone's end`() {
        for kind in TestSoundFileTests.kinds {
            let layout = TestSoundFile(kind: kind).layout
            for (index, sweep) in layout.sweeps.enumerated() {
                let seconds = Double(sweep.offset - layout.tone.offset - layout.tone.count) / 48000
                for error in [-0.15, 0, 0.15] {
                    let found = TestSoundFile.identify(secondsAfterToneEnd: seconds + error)
                    #expect(found?.kind == kind && found?.index == index, "\(kind) sweep \(index) at \(seconds + error) s")
                }
            }
        }
        #expect(TestSoundFile.identify(secondsAfterToneEnd: 1.5) == nil)
    }

    @Test func `the 16-bit file reads back within half a step of the samples, its silence exactly zero`() throws {
        let file = TestSoundFile(kind: .speakerTest(.right), format: .pcm16)
        #expect(file.suggestedFileName == "Resoniq test sound - right speaker (16-bit).wav")
        #expect(file.suggestedFileName != TestSoundFile(kind: .speakerTest(.right)).suggestedFileName)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try file.write(to: url)
        let read = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(read.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int == 16)
        #expect(read.fileFormat.sampleRate == 48000 && read.fileFormat.channelCount == 2)
        let layout = file.layout
        #expect(Int(read.length) == layout.totalSamples)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: AVAudioFrameCount(read.length)))
        try read.read(into: buffer)
        let left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: Int(buffer.frameLength)))
        let (_, written) = file.channels()
        // Rounded: within half a step.
        let worst = zip(right, written).map { abs($0 - $1) }.max() ?? 1
        #expect(worst <= 0.5 / 32768 + 1e-9)
        #expect(left.allSatisfy { $0 == 0 })
        #expect(right[0..<layout.tone.offset].allSatisfy { $0 == 0 })
        let data = file.data()
        #expect(data.count == 44 + layout.totalSamples * 4)
        #expect(data[34] == 16 && data[32] == 4)
    }

    /// The 16-bit file's own distortion floor, read through the analysis as a run is read: the sweep quantised to 16
    /// bits with and without dither, against the 24-bit file's. The figures are in `docs/modules/ResoniqAudio.md`.
    @Test func `the 16-bit file's distortion floor is far under any speaker's`() {
        let sweep = Fixture.sweep
        let samples = sweep.samples()
        func floor(_ written: [Float]) -> (median: Float, worst: Float) {
            let recording = [Float](repeating: 0, count: 4800) + written + [Float](repeating: 0, count: 48000)
            let response = Deconvolution.impulseResponse(recording: recording, sweep: sweep)
            let distortion = HarmonicDistortion.analyze(impulseResponse: response, sweep: sweep)
            let thd = Smoothing.fractionalOctave(distortion.thd, fraction: 3)
            let points = stride(from: log2(100.0), through: log2(5000.0), by: 1.0 / 6).map { Float(pow(2, $0)) }
            let values = points.map { thd.decibels(at: $0) }.map { Float(100 * pow(10, Double($0) / 20)) }.sorted()
            return (values[values.count / 2], values.last ?? .infinity)
        }
        let full = floor(samples.map(TestSoundFile.quantised))
        let dithered = floor(TestSoundFile.codes16(samples, seed: 1).map { Float($0) / 32768 })
        let rounded = floor(TestSoundFile.codes16(samples, seed: 1, dither: false).map { Float($0) / 32768 })
        print("THD floor, 100 Hz–5 kHz (median / worst %): 24-bit \(full), 16-bit dithered \(dithered), 16-bit rounded \(rounded)")
        // The analysis's own floor sets the worst point (the same for all three); the median is the file's. A speaker's
        // distortion worth reporting is a tenth of a per cent and up.
        #expect(dithered.median < 0.005)
        #expect(rounded.median < 0.005)
        #expect(rounded.median <= dithered.median)
        #expect(abs(rounded.worst - full.worst) < 0.002)
    }

    /// The layout and lengths stated in `docs/modules/ResoniqAudio.md`.
    @Test func `the files' lengths are the documented ones`() {
        let lengths = TestSoundFileTests.kinds.map { TestSoundFile(kind: $0).layout.duration }
        #expect(lengths == [29, 30.5, 32, 25, 17])
        #expect(TestSoundFile(kind: .speakerTest(.left)).layout.tone.count == 3 * 48000)
    }

    @Test func `the files with more than one sweep are told apart by their spacing`() {
        for kind in TestSoundFileTests.kinds {
            guard let spacing = TestSoundFile(kind: kind).layout.spacing else { continue }
            #expect(TestSoundFile.kind(forSpacing: spacing + 0.1) == kind)
            #expect(TestSoundFile.kind(forSpacing: 2 * spacing - 0.1) == kind)
        }
        #expect(TestSoundFile.kind(forSpacing: 5) == nil)
    }

    @Test func `the files have names and summaries`() {
        #expect(TestSoundFile(kind: .speakerTest(.left)).suggestedFileName == "Resoniq test sound - left speaker.wav")
        #expect(TestSoundFile(kind: .seat([.left, .right])).suggestedFileName == "Resoniq seat sound - left then right.wav")
        #expect(TestSoundFile(kind: .speakerTest(.left)).summary == "Three sweeps on the left speaker, for testing it. About 29 seconds.")
        #expect(Set(TestSoundFileTests.kinds.map { TestSoundFile(kind: $0).suggestedFileName }).count == TestSoundFileTests.kinds.count)
    }
}
