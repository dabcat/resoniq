import Accelerate
import Foundation
@testable import ResoniqDSP

/// A listening room as an impulse response, for the tests of finding a sweep at the listening seat: the direct sound,
/// a few discrete early reflections (the floor, a side wall, the ceiling), and a dense diffuse tail: Gaussian noise
/// whose energy decays 60 dB in `reverberationTime`, starting `tailStart` after the direct sound with a short build-up.
///
/// **The direct-to-reverberant ratio** (`directToReverberant`, dB) is the direct sound's energy over everything after
/// it (reflections and tail together). At 2–3 m from a pair of speakers in a furnished living room it is typically
/// −3 to −10 dB: the room's sound outweighs the direct sound. The reflections keep their own gains relative to the
/// direct sound, but take at most half of the reverberant energy; the tail takes the rest.
///
/// **The level** is normalised so the whole response has unit energy: what reaches the microphone is as loud whatever
/// the ratio, as it is for a phone at the seat with the volume set by ear. So a low ratio means a weak direct sound,
/// not a louder room.
struct ReverberantRoom: CustomStringConvertible, Sendable {
    struct Reflection: Sendable {
        var delay: Double
        var gain: Double
    }

    var directToReverberant: Double
    var reverberationTime: Double
    var reflections: [Reflection] = [
        Reflection(delay: 0.0029, gain: 0.55),
        Reflection(delay: 0.0071, gain: -0.4),
        Reflection(delay: 0.0118, gain: 0.3),
    ]
    var tailStart: Double = 0.004
    var seed: UInt64 = 99

    var description: String {
        "D/R \(String(format: "%+.0f", directToReverberant)) dB, RT60 \(reverberationTime) s"
    }

    func impulseResponse(sampleRate: Double) -> [Float] {
        let length = Int((reverberationTime * 1.2 + tailStart) * sampleRate)
        var response = [Double](repeating: 0, count: length)
        response[0] = 1
        let reverberant = pow(10, -directToReverberant / 10)
        // The reflections, held to half the reverberant energy.
        let reflectionEnergy = reflections.reduce(0) { $0 + $1.gain * $1.gain }
        let reflectionScale = reflectionEnergy > 0.5 * reverberant ? (0.5 * reverberant / reflectionEnergy).squareRoot() : 1
        for reflection in reflections {
            let index = Int((reflection.delay * sampleRate).rounded())
            if index > 0, index < length { response[index] += reflection.gain * reflectionScale }
        }
        // The tail: decaying noise with a 3 ms build-up, scaled to the energy left.
        var generator = SeededGenerator(state: seed)
        let noise = generator.noise(count: length, rms: 1)
        let first = Int(tailStart * sampleRate)
        let buildUp = 0.003 * sampleRate
        var tail = [Double](repeating: 0, count: length)
        for index in first..<length {
            let t = Double(index - first)
            let decay = pow(10, -3 * Double(index) / (reverberationTime * sampleRate))
            tail[index] = noise[index] * decay * min(1, t / buildUp)
        }
        let tailEnergy = tail.reduce(0) { $0 + $1 * $1 }
        let wanted = max(0, reverberant - reflectionEnergy * reflectionScale * reflectionScale)
        let tailScale = tailEnergy > 0 ? (wanted / tailEnergy).squareRoot() : 0
        for index in first..<length { response[index] += tail[index] * tailScale }
        let total = response.reduce(0) { $0 + $1 * $1 }
        return response.map { Float($0 / total.squareRoot()) }
    }

    /// `signal` heard in the room: convolved with the impulse response (by FFT), as long as `signal`.
    func apply(_ signal: [Float], sampleRate: Double) -> [Float] {
        convolve(signal, impulseResponse(sampleRate: sampleRate))
    }
}

/// `signal` convolved with `kernel`, cut to the signal's length.
func convolve(_ signal: [Float], _ kernel: [Float]) -> [Float] {
    guard !signal.isEmpty, !kernel.isEmpty else { return signal }
    let plan = FFT.Plan(size: FFT.nextPowerOfTwo(signal.count + kernel.count))
    let a = plan.forward(signal)
    let b = plan.forward(kernel)
    let product = ComplexSpectrum(
        real: vDSP.subtract(vDSP.multiply(a.real, b.real), vDSP.multiply(a.imaginary, b.imaginary)),
        imaginary: vDSP.add(vDSP.multiply(a.real, b.imaginary), vDSP.multiply(a.imaginary, b.real))
    )
    return Array(plan.inverse(product).prefix(signal.count))
}

/// One sweep, with the clock tone before it, as a player `ratio` times fast plays it, heard in `room` with white noise
/// at `noiseDecibels` dBFS RMS: the tone starts at 0.5 s and the sweep at `sweepStart` samples.
func reverberantRecording(
    room: ReverberantRoom?,
    ratio: Double = 1,
    noiseDecibels: Double = -60,
    filters: [Biquad] = bookshelfFilters,
    sweepStart: Double = 6 * 48000 + 0.3,
    duration: Double = 12,
    seed: UInt64 = 5
) -> [Float] {
    let dry = ExternalRecording(
        starts: [sweepStart], ratio: ratio, filters: filters, duration: duration, toneStart: 0.5 * 48000
    ).record()
    let wet = room.map { $0.apply(dry, sampleRate: 48000) } ?? dry
    var generator = SeededGenerator(state: seed)
    let noise = generator.noise(count: wet.count, rms: pow(10, noiseDecibels / 20))
    return zip(wet, noise).map { $0 + Float($1) }
}
