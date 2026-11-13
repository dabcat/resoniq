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
        #expect(TestSoundFile(kind: .speakerTest(.left)).summary == "Three sweeps on the left speaker, for testing it. About 28 seconds.")
        #expect(Set(TestSoundFileTests.kinds.map { TestSoundFile(kind: $0).suggestedFileName }).count == TestSoundFileTests.kinds.count)
    }
}
