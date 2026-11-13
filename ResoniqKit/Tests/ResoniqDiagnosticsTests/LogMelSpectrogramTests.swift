import Foundation
import ResoniqDSP
import Testing
@testable import ResoniqDiagnostics

@Suite struct LogMelSpectrogramTests {
    static let sampleRate = 48000.0
    static let configuration = LogMelSpectrogram.Configuration.standard

    static func sine(frequency: Double, amplitude: Float, seconds: Double = 0.5) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    @Test func `the defaults are the stated ones`() {
        let c = Self.configuration
        #expect(c.windowLength == 2048 && c.hopLength == 480 && c.window == .hann && c.bandCount == 64)
        #expect(c.lowerFrequency == 20 && c.upperFrequency == 20000 && c.referencePower == 1 && c.floorDecibels == -120)
    }

    @Test(arguments: [0, 2047, 2048, 2049, 2528, 48000, 192_000])
    func `the frame count follows the formula`(count: Int) {
        let expected = count < 2048 ? 0 : 1 + (count - 2048) / 480
        let spectrogram = LogMelSpectrogram.compute([Float](repeating: 0.1, count: count), sampleRate: Self.sampleRate)
        #expect(spectrogram.frameCount == expected)
        #expect(spectrogram.values.count == expected * 64)
        #expect(Self.configuration.frameCount(sampleCount: count) == expected)
    }

    @Test func `silence is the floor everywhere`() {
        let spectrogram = LogMelSpectrogram.compute([Float](repeating: 0, count: 24000), sampleRate: Self.sampleRate)
        #expect(spectrogram.frameCount == 46)
        #expect(spectrogram.values.allSatisfy { $0 == -120 })
    }

    @Test func `the filter bank's weights add up to 1 between the first and last centres`() {
        let bank = MelFilterBank(configuration: Self.configuration, sampleRate: Self.sampleRate)
        #expect(bank.centres.count == 64)
        #expect(abs(bank.points.first! - 20) < 0.01 && abs(bank.points.last! - 20000) < 1)
        // Equally spaced in mel.
        let mels = bank.points.map(MelFilterBank.mel)
        let steps = zip(mels, mels.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { abs($0 - steps[0]) < 0.01 })
        // Every filter has bins, and the bins' weights sum to 1 from the first centre to the last.
        #expect(bank.filters.allSatisfy { !$0.weights.isEmpty })
        let binWidth = Float(Self.sampleRate) / 2048
        for bin in 0...1024 {
            let frequency = Float(bin) * binWidth
            guard frequency >= bank.centres.first!, frequency <= bank.centres.last! else { continue }
            var sum: Float = 0
            for filter in bank.filters where (filter.firstBin..<(filter.firstBin + filter.weights.count)).contains(bin) {
                sum += filter.weights[bin - filter.firstBin]
            }
            #expect(abs(sum - 1) < 1e-4, "bin \(bin) sums to \(sum)")
        }
        // Continuous check, independent of the bins.
        for frequency in stride(from: bank.centres.first!, through: bank.centres.last!, by: 37) {
            let sum = (0..<64).map { MelFilterBank.weight(frequency, lower: bank.points[$0], centre: bank.points[$0 + 1], upper: bank.points[$0 + 2]) }.reduce(0, +)
            #expect(abs(sum - 1) < 1e-4)
        }
    }

    /// A sine at a wide band's centre lies on the flat part of its triangle, so the band reads the sine's RMS:
    /// 20·log10(A/√2). At 1 kHz the bands are narrow (about 150 Hz) and the Hann lobe's side bins fall on the slopes,
    /// so only the band is checked there.
    @Test func `a sine lands in the right mel band at the expected level`() throws {
        let bank = MelFilterBank(configuration: Self.configuration, sampleRate: Self.sampleRate)
        let band = 56
        let centre = Double(bank.centres[band])
        let amplitude: Float = 0.5
        let spectrogram = LogMelSpectrogram.compute(Self.sine(frequency: centre, amplitude: amplitude), sampleRate: Self.sampleRate)
        let expected = 20 * log10(amplitude / 2.0.squareRoot().float)
        for frame in 0..<spectrogram.frameCount {
            let levels = Array(spectrogram.frame(frame))
            #expect(levels.indices.max { levels[$0] < levels[$1] } == band)
            #expect(abs(levels[band] - expected) < 0.3, "frame \(frame): \(levels[band]) dB, expected \(expected) dB")
            // Well clear of bands two away.
            #expect(levels[band - 2] < expected - 30 && levels[band + 2] < expected - 30)
        }
        let kilohertz = LogMelSpectrogram.compute(Self.sine(frequency: 1000, amplitude: amplitude), sampleRate: Self.sampleRate)
        let nearest = bank.centres.indices.min { abs(bank.centres[$0] - 1000) < abs(bank.centres[$1] - 1000) }!
        let levels = Array(kilohertz.frame(10))
        #expect(levels.indices.max { levels[$0] < levels[$1] } == nearest)
        #expect(abs(levels[nearest] - expected) < 3)
    }

    /// White noise's bands share its mean square: summed over every band (the weights add up to 1), they give its
    /// variance within the bands' range.
    @Test func `white noise's bands add up to its level`() {
        var generator = SeededGenerator(state: 3)
        let rms = 0.1
        let noise = generator.noise(count: 48000, rms: rms).map(Float.init)
        let spectrogram = LogMelSpectrogram.compute(noise, sampleRate: Self.sampleRate)
        let bank = MelFilterBank(configuration: Self.configuration, sampleRate: Self.sampleRate)
        // The bands cover from the first centre to the last fully, and half of each outer triangle.
        let covered = Double(bank.centres.last! - bank.centres.first!) + Double(bank.points[1] - bank.points[0]) / 2 + Double(bank.points[65] - bank.points[64]) / 2
        let expected = 10 * log10(rms * rms * covered / (Self.sampleRate / 2))
        var total: Double = 0
        for frame in 0..<spectrogram.frameCount {
            total += spectrogram.frame(frame).reduce(0) { $0 + pow(10, Double($1) / 10) }
        }
        let measured = 10 * log10(total / Double(spectrogram.frameCount))
        #expect(abs(measured - expected) < 0.3, "\(measured) dB, expected \(expected) dB")
    }

    @Test func `the configuration is recorded and survives JSON`() throws {
        let spectrogram = LogMelSpectrogram.compute(Self.sine(frequency: 440, amplitude: 0.1, seconds: 0.1), sampleRate: Self.sampleRate)
        #expect(spectrogram.configuration == Self.configuration)
        #expect(spectrogram.sampleRate == Self.sampleRate)
        let decoded = try JSONDecoder().decode(LogMelSpectrogram.self, from: JSONEncoder().encode(spectrogram))
        #expect(decoded == spectrogram)
    }
}

private extension Double {
    var float: Float { Float(self) }
}
