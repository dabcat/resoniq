import Foundation
@testable import ResoniqDSP

// Sound that is not the test sound, for the rejection tests of `SweepFinder` and `SweepFollower`: closer to real
// speech and music than `syntheticTune`, and with the parts most like a sweep (gliding pitch, gliding formants,
// portamento) on purpose.

/// Something like speech: syllables of 120–300 ms, each voiced (a harmonic series whose pitch glides up or down by up to
/// half an octave, shaped by two formants that glide as in a diphthong, the second rising from about 1 to 2.5 kHz at
/// times: a short upward chirp) or unvoiced (a burst of noise tilted towards 2–8 kHz), with pauses between words.
func syntheticSpeech(seconds: Double, sampleRate: Double, seed: UInt64 = 21) -> [Float] {
    let count = Int(seconds * sampleRate)
    var signal = [Double](repeating: 0, count: count)
    var generator = SeededGenerator(state: seed)
    func uniform() -> Double { Double(generator.next() >> 11) * 0x1p-53 }
    var time = 0.2
    while time < seconds {
        let length = 0.12 + 0.18 * uniform()
        let first = min(count, Int(time * sampleRate))
        let last = min(count, first + Int(length * sampleRate))
        if uniform() < 0.75 {
            let f0Start = 90 + 130 * uniform()
            let f0End = f0Start * pow(2, uniform() - 0.5)
            let f1 = (300 + 500 * uniform(), 300 + 500 * uniform())
            let f2 = (900 + 600 * uniform(), 1200 + 1300 * uniform())
            var phase = 0.0
            var index = first
            while index < last {
                let fraction = Double(index - first) / Double(max(1, last - first))
                let f0 = f0Start + (f0End - f0Start) * fraction
                phase += 2 * Double.pi * f0 / sampleRate
                let formant1 = f1.0 + (f1.1 - f1.0) * fraction
                let formant2 = f2.0 + (f2.1 - f2.0) * fraction
                var value = 0.0
                var harmonic = 1.0
                while harmonic * f0 < 4000 {
                    let frequency = harmonic * f0
                    let a = log2(frequency / formant1) / 0.35
                    let b = log2(frequency / formant2) / 0.3
                    value += (exp(-a * a) + 0.6 * exp(-b * b) + 0.02) * sin(harmonic * phase)
                    harmonic += 1
                }
                signal[index] += 0.05 * sin(Double.pi * fraction) * value
                index += 1
            }
        } else if last > first {
            let noise = generator.noise(count: last - first + 2, rms: 1)
            for index in first..<last {
                let k = index - first + 2
                let fraction = Double(index - first) / Double(max(1, last - first))
                signal[index] += 0.03 * sin(Double.pi * fraction) * (noise[k] - 2 * noise[k - 1] + noise[k - 2])
            }
        }
        time += length + (uniform() < 0.3 ? 0.15 + 0.3 * uniform() : 0.03)
    }
    return signal.map(Float.init)
}

/// Something like a song's accompaniment: a chord progression (C, Am, F, G, two seconds each) in three voices with
/// harmonics and a 5.5 Hz vibrato of ±25 cents, each voice gliding to its next note over 150 ms (portamento), and a
/// bass an octave and a half under the root.
func syntheticChords(seconds: Double, sampleRate: Double) -> [Float] {
    let count = Int(seconds * sampleRate)
    var signal = [Double](repeating: 0, count: count)
    let chords: [[Double]] = [[261.63, 329.63, 392.0], [220.0, 261.63, 329.63], [174.61, 220.0, 261.63], [196.0, 246.94, 293.66]]
    let chordLength = 2.0
    for voice in 0..<4 {
        func note(_ chord: Int) -> Double {
            let notes = chords[chord % chords.count]
            return voice < 3 ? notes[voice] : notes[0] / 2.83
        }
        var phase = 0.0
        var index = 0
        while index < count {
            let t = Double(index) / sampleRate
            let chord = Int(t / chordLength)
            let within = t - Double(chord) * chordLength
            var frequency = note(chord)
            if within < 0.15, chord > 0 {
                let from = note(chord - 1)
                frequency = from * pow(frequency / from, within / 0.15)
            }
            frequency *= pow(2, 0.025 * sin(2 * Double.pi * 5.5 * t + Double(voice)))
            phase += 2 * Double.pi * frequency / sampleRate
            let attack = min(1, within * 20) * exp(-0.4 * within)
            let tone = sin(phase) + 0.5 * sin(2 * phase) + 0.33 * sin(3 * phase) + 0.2 * sin(4 * phase) + 0.1 * sin(6 * phase)
            signal[index] += (voice < 3 ? 0.04 : 0.07) * attack * tone
            index += 1
        }
    }
    return signal.map(Float.init)
}
