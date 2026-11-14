import Foundation

/// RIFF/WAVE files, written by hand so every byte is testable, and read back for the files this module writes.
///
/// Two encodings: integer PCM (format 1) at 16 or 24 bits from codes the caller has already rounded (the test sound
/// files, `TestSoundFile`), and IEEE float (format 3) at 32 bits, which keeps a `Float` sample exactly as it was, over
/// full scale too (a kept recording, `RecordingStore` in the store module). Channels are interleaved, little-endian,
/// behind a 44-byte header: `RIFF`, `WAVE`, a 16-byte `fmt ` chunk, `data`.
public enum WAVFile {
    /// What a file holds once read: each channel's samples, as floats (PCM codes over full scale).
    public struct Contents: Sendable, Equatable {
        public var sampleRate: Double
        public var channels: [[Float]]
    }

    public enum ReadError: Error, Sendable, Equatable {
        /// Not a RIFF/WAVE file, or its chunks run past its end.
        case notWAV
        /// A format other than PCM 16/24 or float 32.
        case unsupportedFormat
    }

    /// Integer PCM: each channel's codes, already rounded and held to `bitDepth` (16 or 24).
    public static func pcm(codes channels: [[Int32]], bitDepth: Int, sampleRate: Double) -> Data {
        precondition(bitDepth == 16 || bitDepth == 24, "PCM files are 16- or 24-bit")
        let bytesPerSample = bitDepth / 8
        return interleave(channels.count, frames: channels.first?.count ?? 0, bytesPerSample: bytesPerSample,
                          format: 1, bitDepth: bitDepth, sampleRate: sampleRate) { channel, frame in
            UInt32(bitPattern: channels[channel][frame])
        }
    }

    /// IEEE float, 32 bits: the samples exactly as they are.
    public static func float32(channels: [[Float]], sampleRate: Double) -> Data {
        interleave(channels.count, frames: channels.first?.count ?? 0, bytesPerSample: 4,
                   format: 3, bitDepth: 32, sampleRate: sampleRate) { channel, frame in
            channels[channel][frame].bitPattern
        }
    }

    private static func interleave(
        _ channelCount: Int, frames: Int, bytesPerSample: Int, format: UInt16, bitDepth: Int, sampleRate: Double,
        bits: (Int, Int) -> UInt32
    ) -> Data {
        precondition(channelCount > 0, "a file has at least one channel")
        let dataSize = frames * channelCount * bytesPerSample
        var data = Data(capacity: 44 + dataSize)
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let rate = Int(sampleRate.rounded())
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(format)
        append16(UInt16(channelCount))
        append32(UInt32(rate))
        append32(UInt32(rate * channelCount * bytesPerSample))
        append16(UInt16(channelCount * bytesPerSample))
        append16(UInt16(bitDepth))
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))

        var bytes = [UInt8](repeating: 0, count: dataSize)
        bytes.withUnsafeMutableBufferPointer { buffer in
            // Per sample, so it is fast in a debug build too: plain stores, no temporary arrays.
            var index = 0
            var frame = 0
            while frame < frames {
                for channel in 0..<channelCount {
                    let value = bits(channel, frame)
                    buffer[index] = UInt8(truncatingIfNeeded: value)
                    buffer[index + 1] = UInt8(truncatingIfNeeded: value >> 8)
                    if bytesPerSample >= 3 { buffer[index + 2] = UInt8(truncatingIfNeeded: value >> 16) }
                    if bytesPerSample == 4 { buffer[index + 3] = UInt8(truncatingIfNeeded: value >> 24) }
                    index += bytesPerSample
                }
                frame += 1
            }
        }
        data.append(contentsOf: bytes)
        return data
    }

    /// Reads a PCM 16/24 or float 32 file. Chunks other than `fmt ` and `data` are skipped.
    public static func read(_ data: Data) throws(ReadError) -> Contents {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { u16(at) | u16(at + 2) << 16 }
        guard bytes.count >= 12, bytes[0..<4].elementsEqual("RIFF".utf8), bytes[8..<12].elementsEqual("WAVE".utf8) else {
            throw .notWAV
        }
        var offset = 12
        var format: (code: Int, channels: Int, rate: Int, bits: Int)?
        while offset + 8 <= bytes.count {
            let size = u32(offset + 4)
            let body = offset + 8
            guard body + size <= bytes.count else { throw .notWAV }
            if bytes[offset..<(offset + 4)].elementsEqual("fmt ".utf8) {
                guard size >= 16 else { throw .notWAV }
                format = (u16(body), u16(body + 2), u32(body + 4), u16(body + 14))
            } else if bytes[offset..<(offset + 4)].elementsEqual("data".utf8) {
                guard let format, format.channels > 0 else { throw .notWAV }
                return try decode(bytes[body..<(body + size)], format: format)
            }
            offset = body + size + (size & 1)
        }
        throw .notWAV
    }

    private static func decode(
        _ body: ArraySlice<UInt8>, format: (code: Int, channels: Int, rate: Int, bits: Int)
    ) throws(ReadError) -> Contents {
        let bytesPerSample = format.bits / 8
        switch (format.code, format.bits) {
        case (1, 16), (1, 24), (3, 32): break
        default: throw .unsupportedFormat
        }
        let frames = body.count / (bytesPerSample * format.channels)
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: format.channels)
        var index = body.startIndex
        let full = Float(1 << (format.bits - 1))
        for frame in 0..<frames {
            for channel in 0..<format.channels {
                var value: UInt32 = 0
                for byte in 0..<bytesPerSample { value |= UInt32(body[index + byte]) << (8 * byte) }
                index += bytesPerSample
                if format.code == 3 {
                    channels[channel][frame] = Float(bitPattern: value)
                } else {
                    // Sign-extend the code from its bit depth.
                    let shift = 32 - format.bits
                    let code = Int32(bitPattern: value << UInt32(shift)) >> Int32(shift)
                    channels[channel][frame] = Float(code) / full
                }
            }
        }
        return Contents(sampleRate: Double(format.rate), channels: channels)
    }
}
