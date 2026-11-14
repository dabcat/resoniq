import Foundation
import Testing
@testable import ResoniqAudio

struct WAVFileTests {
    private func u16(_ data: Data, _ offset: Int) -> Int {
        Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
    }

    private func u32(_ data: Data, _ offset: Int) -> Int {
        u16(data, offset) | u16(data, offset + 2) << 16
    }

    @Test func `a mono float file has an IEEE float header at the recorded rate`() {
        let samples: [Float] = [0, 0.5, -0.25, 1.5]
        let data = WAVFile.float32(channels: [samples], sampleRate: 44100)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(u16(data, 20) == 3)            // IEEE float
        #expect(u16(data, 22) == 1)            // mono
        #expect(u32(data, 24) == 44100)
        #expect(u32(data, 28) == 44100 * 4)    // byte rate
        #expect(u16(data, 32) == 4)            // block align
        #expect(u16(data, 34) == 32)
        #expect(String(decoding: data[36..<40], as: UTF8.self) == "data")
        #expect(u32(data, 40) == samples.count * 4)
        #expect(data.count == 44 + samples.count * 4)
        #expect(u32(data, 4) == data.count - 8)
    }

    @Test func `float samples come back bit for bit, over full scale too`() throws {
        var samples: [Float] = (0..<1000).map { Float(sin(Double($0) * 0.37)) * 0.3 }
        samples += [1.75, -2, .leastNonzeroMagnitude, 0, -0.0, Float.ulpOfOne]
        let data = WAVFile.float32(channels: [samples], sampleRate: 48000)
        let read = try WAVFile.read(data)
        #expect(read.sampleRate == 48000)
        #expect(read.channels.count == 1)
        #expect(read.channels[0].map(\.bitPattern) == samples.map(\.bitPattern))
    }

    @Test func `stereo PCM files read back to their codes`() throws {
        let left: [Float] = [0, 0.5, -0.5, 0.999]
        let right: [Float] = [0.25, -0.25, 0, -1]
        for bits in [16, 24] {
            let full = Float(1 << (bits - 1))
            let codes = [left, right].map { channel in channel.map { Int32(min(max(($0 * full).rounded(), -full), full - 1)) } }
            let data = WAVFile.pcm(codes: codes, bitDepth: bits, sampleRate: 48000)
            #expect(u16(data, 20) == 1)
            #expect(u16(data, 22) == 2)
            #expect(u16(data, 34) == bits)
            let read = try WAVFile.read(data)
            #expect(read.channels.count == 2)
            for (channel, expected) in zip(read.channels, codes) {
                #expect(channel == expected.map { Float($0) / full })
            }
        }
    }

    @Test func `the reader refuses what is not a WAV file`() {
        #expect(throws: WAVFile.ReadError.self) { try WAVFile.read(Data("not a wave file at all, just text".utf8)) }
        let cut = WAVFile.float32(channels: [[0.1, 0.2, 0.3]], sampleRate: 48000).dropLast(3)
        #expect(throws: WAVFile.ReadError.self) { try WAVFile.read(Data(cut)) }
    }
}
