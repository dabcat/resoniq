import Accelerate
import Foundation
import Testing
@testable import ResoniqAudio
@testable import ResoniqDSP

// What the listening tests need beyond `SimulatedAudioIO`: a microphone that hears a prepared recording (a file played
// in a reverberant room, a player that mutes or stops), and that room.

/// A microphone that hears `signal`, mono at 48 kHz, in blocks of `blockSize`; the stream ends with it.
final class PreparedAudioIO: AudioIO, @unchecked Sendable {
    let signal: [Float]
    let blockSize: Int
    private final class Cursor: @unchecked Sendable { var position = 0 }

    init(_ signal: [Float], blockSize: Int = 4800) {
        self.signal = signal
        self.blockSize = blockSize
    }

    func start() async throws -> CaptureStream {
        let cursor = Cursor()
        let signal = signal
        let blockSize = blockSize
        let blocks = AsyncThrowingStream<CapturedBlock, any Error>(unfolding: {
            await Task.yield()
            if Task.isCancelled || cursor.position >= signal.count { return nil }
            let end = min(signal.count, cursor.position + blockSize)
            let block = CapturedBlock(position: Int64(cursor.position), samples: Array(signal[cursor.position..<end]))
            cursor.position = end
            return block
        })
        return CaptureStream(sampleRate: 48000, blocks: blocks)
    }

    func schedule(_ samples: [Float], on channel: SpeakerChannel, mode: PlaybackMode) throws -> Int64 { throw AudioIOError.notRunning }
    func stopPlayback() {}
    func stop() async {}
}

/// A listening room as an impulse response: the direct sound, three early reflections, and a dense tail of Gaussian
/// noise decaying 60 dB in `reverberationTime`, with the reverberant energy (reflections and tail) `directToReverberant`
/// dB under the direct sound's and the whole normalised to unit energy. As `ReverberantRoom` in the DSP tests.
struct DenseRoom: Sendable, CustomTestStringConvertible {
    var directToReverberant: Double
    var reverberationTime: Double

    var testDescription: String { "D/R \(Int(directToReverberant)) dB, RT60 \(reverberationTime) s" }

    func impulseResponse(sampleRate: Double = 48000) -> [Float] {
        let length = Int((reverberationTime * 1.2 + 0.004) * sampleRate)
        var response = [Double](repeating: 0, count: length)
        response[0] = 1
        let reverberant = pow(10, -directToReverberant / 10)
        let reflections: [(Double, Double)] = [(0.0029, 0.55), (0.0071, -0.4), (0.0118, 0.3)]
        let reflectionEnergy = reflections.reduce(0) { $0 + $1.1 * $1.1 }
        let scale = reflectionEnergy > 0.5 * reverberant ? (0.5 * reverberant / reflectionEnergy).squareRoot() : 1
        for (delay, gain) in reflections { response[Int((delay * sampleRate).rounded())] += gain * scale }
        var random = SplitMix(state: 99)
        let first = Int(0.004 * sampleRate)
        var tail = [Double](repeating: 0, count: length)
        for index in first..<length {
            let decay = pow(10, -3 * Double(index) / (reverberationTime * sampleRate))
            tail[index] = random.gaussian() * decay * min(1, Double(index - first) / (0.003 * sampleRate))
        }
        let tailEnergy = tail.reduce(0) { $0 + $1 * $1 }
        let tailScale = (max(0, reverberant - reflectionEnergy * scale * scale) / tailEnergy).squareRoot()
        for index in first..<length { response[index] += tail[index] * tailScale }
        let total = response.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return response.map { Float($0 / total) }
    }

    /// `signal` heard in the room, as long as `signal`.
    func apply(_ signal: [Float]) -> [Float] {
        let kernel = impulseResponse()
        let plan = FFT.Plan(size: FFT.nextPowerOfTwo(signal.count + kernel.count))
        let a = plan.forward(signal)
        let b = plan.forward(kernel)
        let product = ComplexSpectrum(
            real: vDSP.subtract(vDSP.multiply(a.real, b.real), vDSP.multiply(a.imaginary, b.imaginary)),
            imaginary: vDSP.add(vDSP.multiply(a.real, b.imaginary), vDSP.multiply(a.imaginary, b.real))
        )
        return Array(plan.inverse(product).prefix(signal.count))
    }
}

/// What one microphone hears of `file` (both channels, each at half gain), after `before` seconds of the room and
/// followed by `after`: `edit` changes the file's mono mix first (a mute, a stop, a pause), `room` reverberates it, and
/// white noise of `noise` RMS is added last.
func heardFile(
    _ file: TestSoundFile,
    before: Double = 4,
    after: Double = 14,
    noise: Double = 1e-4,
    room: DenseRoom? = nil,
    edit: (inout [Float], TestSoundLayout) -> Void = { _, _ in }
) -> [Float] {
    let (left, right) = file.channels()
    var mono = vDSP.multiply(0.5, vDSP.add(left, right))
    edit(&mono, file.layout)
    var signal = [Float](repeating: 0, count: Int(before * 48000)) + mono + [Float](repeating: 0, count: Int(after * 48000))
    if let room { signal = room.apply(signal) }
    var random = SplitMix(state: 5)
    for index in signal.indices { signal[index] += Float(noise * random.gaussian()) }
    return signal
}

extension ExternalStateLog {
    /// The states in a line, the long reasons cut short: for a test's message.
    var summary: String {
        states.map { state -> String in
            switch state {
            case .finished(let result): "finished(\(result.runs.count))"
            case .needsAnotherPlay(let have, let reason): "again(\(have), \(reason.map { String(describing: $0).prefix(60) } ?? "nil"))"
            case .hearing, .checking: ""
            default: "\(state)"
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
    }
}
