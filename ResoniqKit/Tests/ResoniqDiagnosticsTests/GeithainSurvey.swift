import AVFoundation
import Foundation
import ResoniqDSP
import Synchronization
import Testing
@testable import ResoniqDiagnostics

/// A measurement, not a check: what the diagnosis says about the healthy Geithain RL900A monitors over a broad sample
/// of the dataset (`GeithainRuns` has the layout), written as JSON lines for the research note
/// `docs/research/2026-11-14-healthy-speakers-real-room.md`. It asserts nothing about the rules and changes none.
///
/// It runs only when `RESONIQ_GEITHAIN_SURVEY` is set and the data is at `data/geithain-sweeps/`, so `make test`
/// skips it. The sample comes from the environment:
///
/// - `RESONIQ_GEITHAIN_LENGTHS`: sweep lengths in seconds, comma-separated (default `4`; all five are 4,8,16,32,64).
/// - `RESONIQ_GEITHAIN_SPEAKERS`: sweep channels (default `0,1,2`).
/// - `RESONIQ_GEITHAIN_SURVEY_OUT`: the folder written to (default `ResoniqKit/.build/geithain-survey`).
///
/// It is slow in a debug build; run it optimised, one suite at a time:
/// `RESONIQ_GEITHAIN_SURVEY=1 swift test --package-path ResoniqKit -c release -Xswiftc -enable-testing --filter GeithainSurvey`.
///
/// Three recordings of one speaker at one microphone under one condition are three runs, each analysed by
/// `RunAnalyzer` against that microphone's floor (`GeithainRuns.floor`). Even indices drive the sweep at a peak of 0.5,
/// odd ones at 0.25. Clean recordings make triplets of consecutive indices at one drive; with an impulse or birdsong a
/// triplet is one noise channel, noise level and drive with the noise in the first, second and last third of the sweep
/// (intervals 0, 1, 2), and the recordings with the noise after the sweep (`reverbration`) make one triplet per noise
/// channel and drive, its three noise levels.
enum GeithainSurvey {
    static let environment = ProcessInfo.processInfo.environment
    static var isRequested: Bool { environment["RESONIQ_GEITHAIN_SURVEY"] != nil }
    static var isEnabled: Bool { isRequested && GeithainRuns.isAvailable }

    static func list(_ name: String, default value: [Int]) -> [Int] {
        environment[name].map { $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } } ?? value
    }
    static var lengths: [Int] { list("RESONIQ_GEITHAIN_LENGTHS", default: [4]) }
    static var speakers: [Int] { list("RESONIQ_GEITHAIN_SPEAKERS", default: [0, 1, 2]) }
    static let microphones = Array(0..<7)

    static var outputFolder: URL {
        if let path = environment["RESONIQ_GEITHAIN_SURVEY_OUT"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/geithain-survey")
    }

    // MARK: The playlist

    struct Row: Sendable, Codable {
        let index: Int
        let speaker: Int
        let length: Int
        /// "clean", "impulse" or "birds".
        let noise: String
        let noiseChannel: Int
        /// "0", "1", "2" or "reverbration".
        let interval: String
        let noiseLevel: Double
        /// The sweep's peak in the played file.
        var drive: Double { index % 2 == 0 ? 0.5 : 0.25 }
    }

    static func playlist() throws -> [Row] {
        let text = try String(contentsOf: GeithainRuns.folder.appendingPathComponent("playlist.csv"), encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).dropFirst().map { line in
            let field = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            let file = field[3]
            return Row(
                index: Int(field[0])!, speaker: Int(field[1])!, length: Int(field[2])!,
                noise: file.isEmpty ? "clean" : file.contains("impulse") ? "impulse" : "birds",
                noiseChannel: Int(field[4])!, interval: field[5], noiseLevel: Double(field[6])!
            )
        }
    }

    /// One three-run test.
    struct Group: Sendable, Codable {
        let speaker: Int
        let length: Int
        let noise: String
        /// The noise's channel, as its rank among this speaker's two noise channels (0 or 1), so the two speakers' tests
        /// pair up; -1 when clean.
        let noiseRank: Int
        let noiseChannel: Int
        /// The noise level; 0 when clean, -1 for a triplet of the three levels.
        let noiseLevel: Double
        let drive: Double
        /// "012" (the noise in each third of the sweep), "after" (after the sweep), or "clean".
        let timing: String
        /// The triplet's number among the clean ones of that drive; 0 otherwise.
        let ordinal: Int
        let indices: [Int]

        /// The same test of another speaker has the same key.
        var key: String { "\(length)|\(noise)|\(noiseRank)|\(noiseLevel)|\(drive)|\(timing)|\(ordinal)" }
    }

    static func groups(_ rows: [Row], speaker: Int, length: Int) -> [Group] {
        let mine = rows.filter { $0.speaker == speaker && $0.length == length }.sorted { $0.index < $1.index }
        var groups: [Group] = []
        for drive in [0.5, 0.25] {
            let clean = mine.filter { $0.noise == "clean" && $0.drive == drive }
            for (ordinal, start) in stride(from: 0, to: clean.count - 2, by: 3).enumerated() {
                groups.append(Group(speaker: speaker, length: length, noise: "clean", noiseRank: -1, noiseChannel: -1, noiseLevel: 0,
                                    drive: drive, timing: "clean", ordinal: ordinal, indices: clean[start..<(start + 3)].map(\.index)))
            }
        }
        for noise in ["impulse", "birds"] {
            let noisy = mine.filter { $0.noise == noise }
            let channels = Array(Set(noisy.map(\.noiseChannel))).sorted()
            for (rank, channel) in channels.enumerated() {
                for drive in [0.5, 0.25] {
                    let these = noisy.filter { $0.noiseChannel == channel && $0.drive == drive }
                    for level in [1.0, 0.5, 0.25] {
                        let triplet = these.filter { $0.noiseLevel == level && $0.interval != "reverbration" }.sorted { $0.interval < $1.interval }
                        guard triplet.count == 3 else { continue }
                        groups.append(Group(speaker: speaker, length: length, noise: noise, noiseRank: rank, noiseChannel: channel,
                                            noiseLevel: level, drive: drive, timing: "012", ordinal: 0, indices: triplet.map(\.index)))
                    }
                    let after = these.filter { $0.interval == "reverbration" }.sorted { $0.noiseLevel > $1.noiseLevel }
                    if after.count == 3 {
                        groups.append(Group(speaker: speaker, length: length, noise: noise, noiseRank: rank, noiseChannel: channel,
                                            noiseLevel: -1, drive: drive, timing: "after", ordinal: 0, indices: after.map(\.index)))
                    }
                }
            }
        }
        return groups
    }

    // MARK: Reading

    static func channels(_ url: URL) throws -> [[Float]] {
        struct Unreadable: Error {}
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData
        else { throw Unreadable() }
        let count = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: count)) }
    }

    /// Each microphone's floor for the room recording `index` uses, made once.
    static let floors = Mutex([String: [NoiseFloorReport]]())
    static func floors(for index: Int) throws -> [NoiseFloorReport] {
        let url = GeithainRuns.silence(index)
        if let known = floors.withLock({ $0[url.path] }) { return known }
        let quiet = try channels(url)
        let made = microphones.map { GeithainRuns.floor(quiet[$0]) }
        floors.withLock { $0[url.path] = made }
        return made
    }

    static func sweep(seconds: Int) -> LogSweep {
        LogSweep(startFrequency: 50, endFrequency: 22000, duration: Double(seconds), sampleRate: 48000)
    }

    // MARK: Output

    struct RunOut: Codable {
        let index: Int
        let mic: Int
        let speaker: Int
        let length: Int
        let noise: String
        let noiseChannel: Int
        let interval: String
        let noiseLevel: Double
        let drive: Double
        /// "valid", "tooNoisy", "tooQuiet", "clipped", "silent", "corrupt", "incomplete".
        let check: String
        /// The broadband signal-to-noise ratio (valid or too noisy), or the peak in dBFS (too quiet).
        let number: Float?
        let floorDecibels: Float
        let floorSteady: Bool
        var delay: Double?
        var deviation: [Float]?
        /// "1" where the response is measured and the band's signal-to-noise is at least 10 dB.
        var audible: String?
        var thd: [Float?]?
        var thdMeasurable: String?
        var thdFloor: [Float?]?
        var highOrder: [Float?]?
        var highOrderMeasurable: String?
        var bandSignalToNoise: [Float]?
    }

    struct FindingOut: Codable {
        let kind: String
        let headline: String
        let lower: Float?
        let upper: Float?
        let extreme: Float?
        let extremeFrequency: Float?
        let runs: Int
        let compared: Int
        let tag: String
        let suspected: Bool
        let shared: Bool
    }

    struct Variant: Sendable {
        let name: String
        let thresholds: DiagnosisThresholds
    }

    /// Candidate rules for the note's question 5, as analysis only: the same diagnosis with other thresholds.
    static let variants: [Variant] = {
        func with(_ name: String, _ change: (inout DiagnosisThresholds) -> Void) -> Variant {
            var thresholds = DiagnosisThresholds.standard
            change(&thresholds)
            return Variant(name: name, thresholds: thresholds)
        }
        return [
            with("deviation7") { $0.deviationDecibels = 7 },
            with("deviation8") { $0.deviationDecibels = 8 },
            with("deviation9") { $0.deviationDecibels = 9 },
            with("deviation10") { $0.deviationDecibels = 10 },
            with("deviation12") { $0.deviationDecibels = 12 },
            with("width0.5") { $0.minimumDeviationOctaves = 0.5 },
            with("width0.67") { $0.minimumDeviationOctaves = 2.0 / 3 },
            with("width1") { $0.minimumDeviationOctaves = 1 },
            with("deviation8width0.5") { $0.deviationDecibels = 8; $0.minimumDeviationOctaves = 0.5 },
        ]
    }()

    struct TestOut: Codable {
        let group: Group
        let mic: Int
        let key: String
        let checks: [String]
        let verdict: String
        let findings: [FindingOut]
        /// With the other speaker's same test at the same microphone as the counterpart; nil when there is none.
        var pairedVerdict: String?
        var pairedFindings: [FindingOut]?
        /// Suspected dips and peaks under each candidate rule.
        var variants: [String: [FindingOut]]
    }

    static func describe(_ findings: [Finding]) -> [FindingOut] {
        findings.map { finding in
            FindingOut(
                kind: finding.kind.rawValue, headline: finding.headline,
                lower: finding.frequencyRange?.lower, upper: finding.frequencyRange?.upper,
                extreme: finding.numbers?.extreme, extremeFrequency: finding.numbers?.extremeFrequency,
                runs: finding.basis.runsAgreeing, compared: finding.basis.runsCompared, tag: finding.tag.rawValue,
                suspected: finding.isSuspectedDefect, shared: finding.sharedWithOtherSpeaker == true
            )
        }
    }

    static func bits(_ values: [Bool]) -> String { String(values.map { $0 ? "1" : "0" }) }
    static func rounded(_ value: Float) -> Float { (value * 100).rounded() / 100 }

    static func runOut(_ row: Row, mic: Int, analysis: RunAnalysis, floor: NoiseFloorReport) -> RunOut {
        let check: String
        var number: Float?
        switch analysis.record.check {
        case .valid(let ratio): check = "valid"; number = ratio
        case .tooNoisy(let ratio): check = "tooNoisy"; number = ratio
        case .tooQuiet(let peak): check = "tooQuiet"; number = peak
        case .clipped(let fraction): check = "clipped"; number = fraction
        case .silent: check = "silent"
        case .corrupt: check = "corrupt"
        case .incomplete: check = "incomplete"
        }
        var out = RunOut(
            index: row.index, mic: mic, speaker: row.speaker, length: row.length, noise: row.noise,
            noiseChannel: row.noiseChannel, interval: row.interval, noiseLevel: row.noiseLevel, drive: row.drive,
            check: check, number: number, floorDecibels: floor.rmsDecibels, floorSteady: floor.isSteady
        )
        guard let measurement = analysis.measurement else { return out }
        let thresholds = DiagnosisThresholds.standard
        out.delay = measurement.delay
        out.deviation = Trend.deviation(of: measurement.response, thresholds: thresholds).map(rounded)
        out.audible = bits(ResponseGrid.frequencies.indices.map { index in
            measurement.isResponseMeasured(atIndex: index)
                && measurement.signalToNoise(at: ResponseGrid.frequencies[index]) >= thresholds.minimumBandSignalToNoise
        })
        out.thd = measurement.thdDecibels.map { $0.map(rounded) }
        out.thdMeasurable = measurement.thdMeasurable.map(bits)
        out.thdFloor = measurement.thdNoiseFloorDecibels?.map { $0.map(rounded) }
        out.highOrder = measurement.highOrderDecibels?.map { $0.map(rounded) }
        out.highOrderMeasurable = measurement.highOrderMeasurable.map(bits)
        out.bandSignalToNoise = measurement.bandSignalToNoise.map(rounded)
        return out
    }

    /// Writes JSON lines to a file, emptied first.
    final class Lines: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()
        private let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
            encoder.outputFormatting = [.sortedKeys]
            return encoder
        }()

        init(_ url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }

        func write<T: Encodable>(_ value: T) {
            guard var data = try? encoder.encode(value) else { return }
            data.append(0x0A)
            lock.lock()
            handle.write(data)
            lock.unlock()
        }

        deinit { try? handle.close() }
    }
}

@Suite(.enabled(if: GeithainSurvey.isEnabled, "set RESONIQ_GEITHAIN_SURVEY, with the Geithain sweeps in data/geithain-sweeps/"),
       .serialized)
struct GeithainSurveyTests {
    /// Every recording of the sample at every microphone, analysed; then every three-run test diagnosed alone, with the
    /// other speaker's same test as its counterpart, and under each candidate rule.
    @Test func `the healthy monitors' diagnosis over the sample`() throws {
        let rows = try GeithainSurvey.playlist()
        let folder = GeithainSurvey.outputFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let grid = try JSONEncoder().encode(ResponseGrid.frequencies)
        try grid.write(to: folder.appendingPathComponent("grid.json"))

        for length in GeithainSurvey.lengths {
            let started = Date()
            let runLines = try GeithainSurvey.Lines(folder.appendingPathComponent("runs-\(length).jsonl"))
            let testLines = try GeithainSurvey.Lines(folder.appendingPathComponent("tests-\(length).jsonl"))
            let sample = rows.filter { $0.length == length && GeithainSurvey.speakers.contains($0.speaker) }
            let sweep = GeithainSurvey.sweep(seconds: length)

            // Every recording at every microphone; the samples are dropped once analysed.
            let analyses = Mutex([String: RunAnalysis]())
            DispatchQueue.concurrentPerform(iterations: sample.count) { position in
                let row = sample[position]
                guard let recording = try? GeithainSurvey.channels(GeithainRuns.output(row.index)),
                      let floors = try? GeithainSurvey.floors(for: row.index) else {
                    print("Geithain survey: could not read \(row.index)")
                    return
                }
                for mic in GeithainSurvey.microphones {
                    let analysis = RunAnalyzer.analyze(recording: recording[mic], sweep: sweep, noiseFloor: floors[mic])
                    runLines.write(GeithainSurvey.runOut(row, mic: mic, analysis: analysis, floor: floors[mic]))
                    analyses.withLock { $0["\(row.index)/\(mic)"] = analysis }
                }
            }
            let all = analyses.withLock { $0 }
            print("Geithain survey: \(length) s, \(sample.count) recordings × 7 microphones analysed in \(Int(Date().timeIntervalSince(started))) s")

            let groups = GeithainSurvey.speakers.flatMap { GeithainSurvey.groups(rows, speaker: $0, length: length) }
            @Sendable func runs(_ group: GeithainSurvey.Group, mic: Int) -> [RunAnalysis]? {
                let found = group.indices.compactMap { all["\($0)/\(mic)"] }
                return found.count == group.indices.count ? found : nil
            }
            // Speaker 0's counterpart is speaker 1 and the other way round; speaker 2 is diagnosed alone.
            let byKey = Dictionary(groups.map { ("\($0.speaker)|\($0.key)", $0) }) { first, _ in first }
            let work = groups.flatMap { group in GeithainSurvey.microphones.map { (group, $0) } }
            DispatchQueue.concurrentPerform(iterations: work.count) { position in
                let (group, mic) = work[position]
                guard let mine = runs(group, mic: mic) else { return }
                let report = SpeakerDiagnosis.diagnose(runs: mine, counterpart: nil)
                var out = GeithainSurvey.TestOut(
                    group: group, mic: mic, key: group.key,
                    checks: mine.map { "\($0.record.check.problem?.rawValue ?? "valid")" },
                    verdict: report.verdict, findings: GeithainSurvey.describe(report.findings), variants: [:]
                )
                let other = group.speaker == 0 ? 1 : group.speaker == 1 ? 0 : nil
                if let other, let theirs = byKey["\(other)|\(group.key)"].flatMap({ runs($0, mic: mic) }) {
                    let paired = SpeakerDiagnosis.diagnose(runs: mine, counterpart: theirs)
                    out.pairedVerdict = paired.verdict
                    out.pairedFindings = GeithainSurvey.describe(paired.findings)
                }
                for variant in GeithainSurvey.variants {
                    let changed = SpeakerDiagnosis.diagnose(runs: mine, counterpart: nil, thresholds: variant.thresholds)
                    out.variants[variant.name] = GeithainSurvey.describe(changed.findings.filter {
                        $0.isSuspectedDefect && ($0.kind == .responseDip || $0.kind == .responsePeak)
                    })
                }
                testLines.write(out)
            }
            print("Geithain survey: \(length) s, \(work.count) tests diagnosed, \(Int(Date().timeIntervalSince(started))) s in all")
        }
    }

    /// The candidate rules on the simulated speakers the suite already uses for real deviations, and on a range of
    /// simulated bells: which would still be found.
    @Test func `the candidate rules on simulated deviations`() throws {
        let folder = GeithainSurvey.outputFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = try GeithainSurvey.Lines(folder.appendingPathComponent("fixtures.jsonl"))
        struct Fixture: Sendable {
            let name: String
            let speaker: SimulatedSpeaker
            let sweep: LogSweep
            let seed: UInt64
        }
        func bell(_ frequency: Double, q: Double, gain: Double) -> SimulatedSpeaker {
            Bench.healthy(with: [Biquad.peaking(frequency: frequency, q: q, gain: gain, sampleRate: Bench.sampleRate)])
        }
        var fixtures: [Fixture] = [
            // The suite's own defects (ResponseTests, LeftRightTests, UnheardBandTests).
            Fixture(name: "suite: dip 1 kHz Q1 −9 dB", speaker: bell(1000, q: 1, gain: -9), sweep: Bench.responseSweep, seed: 1),
            Fixture(name: "suite: peak 3 kHz Q1 +9 dB", speaker: bell(3000, q: 1, gain: 9), sweep: Bench.responseSweep, seed: 1),
            Fixture(name: "suite: dip 2 kHz Q1 −9 dB", speaker: bell(2000, q: 1, gain: -9), sweep: Bench.responseSweep, seed: 41),
            Fixture(name: "suite: dip 70 Hz Q3 −9 dB", speaker: {
                var speaker = Bench.healthy
                speaker.filters = [
                    Biquad.highPass(frequency: 30, q: 0.707, sampleRate: Bench.sampleRate),
                    Biquad.peaking(frequency: 70, q: 3, gain: -9, sampleRate: Bench.sampleRate),
                ]
                return speaker
            }(), sweep: Bench.sweep, seed: 79),
        ]
        for frequency in [150.0, 400, 1000, 3000] {
            for q in [1.0, 2.0, 4.0] {
                for gain in [-12.0, -10, -9, -8, -7, 7, 8, 9, 10, 12] {
                    fixtures.append(Fixture(
                        name: "bell \(Int(frequency)) Hz Q\(q) \(gain > 0 ? "+" : "")\(Int(gain)) dB",
                        speaker: bell(frequency, q: q, gain: gain), sweep: Bench.responseSweep, seed: 3
                    ))
                }
            }
        }
        struct FixtureOut: Codable {
            let name: String
            let rule: String
            let checks: [String]
            let found: [GeithainSurvey.FindingOut]
        }
        let all = fixtures
        DispatchQueue.concurrentPerform(iterations: all.count) { position in
            let fixture = all[position]
            let runs = Bench.runs(fixture.speaker, seed: fixture.seed, sweep: fixture.sweep)
            let rules = [GeithainSurvey.Variant(name: "standard", thresholds: .standard)] + GeithainSurvey.variants
            for rule in rules {
                let report = SpeakerDiagnosis.diagnose(runs: runs, counterpart: nil, thresholds: rule.thresholds)
                lines.write(FixtureOut(name: fixture.name, rule: rule.name,
                                       checks: runs.map { $0.record.check.problem?.rawValue ?? "valid" }, found: GeithainSurvey.describe(report.findings.filter {
                    $0.kind == .responseDip || $0.kind == .responsePeak || $0.kind == .topEndDip
                })))
            }
        }
    }
    /// What the sound classifier the app runs on a noisy run (`SystemSoundClassifier`, `InterferenceAdvisor`) hears in a
    /// sample of the 4 s recordings at microphone 0: the whole recording as the app classifies one judged too noisy
    /// (`sweepPlaying`), the same labels read as if the sweep were silent, and the stretch after the sweep alone.
    @Test(.enabled("Apple's built-in sound classifier does not answer on this machine") { await SystemSoundClassifier.isWorking() })
    func `the sound classifier on the interfering noise`() async throws {
        let rows = try GeithainSurvey.playlist().filter { $0.length == 4 && $0.speaker < 2 && $0.drive == 0.5 }
        // Per speaker: two clean, and for each noise every interval at the loudest and the quietest noise level, one channel.
        var sample: [GeithainSurvey.Row] = []
        for speaker in [0, 1] {
            let mine = rows.filter { $0.speaker == speaker }
            sample += mine.filter { $0.noise == "clean" }.prefix(2)
            for noise in ["impulse", "birds"] {
                let channel = mine.filter { $0.noise == noise }.map(\.noiseChannel).min()!
                sample += mine.filter { $0.noise == noise && $0.noiseChannel == channel && ($0.noiseLevel == 1 || $0.noiseLevel == 0.25) }
            }
        }
        struct ClassifiedOut: Codable {
            let index: Int
            let speaker: Int
            let noise: String
            let interval: String
            let noiseLevel: Double
            let playing: String?
            let silentReading: String?
            let tail: String?
            let topLabels: [String]
        }
        let classifier = SystemSoundClassifier(timeout: .seconds(60))
        let folder = GeithainSurvey.outputFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = try GeithainSurvey.Lines(folder.appendingPathComponent("classifier.jsonl"))
        func describe(_ report: InterferenceReport?) -> String? {
            report.map { "\($0.kind.rawValue) \(String(format: "%.2f", $0.confidence)) over \(String(format: "%.1f", $0.duration)) s" }
        }
        for row in sample {
            let recording = try GeithainSurvey.channels(GeithainRuns.output(row.index))[0]
            let labels = try await classifier.classify(recording, sampleRate: 48000)
            // The sweep (4 s from 0.5 s) has arrived by 4.6 s; what follows is its decay and then the room.
            let tail = Array(recording[(48000 * 46 / 10)...])
            let tailLabels = try await classifier.classify(tail, sampleRate: 48000)
            var best: [String: Float] = [:]
            for label in labels { best[label.identifier] = max(best[label.identifier] ?? 0, label.confidence) }
            let top = best.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) \(String(format: "%.2f", $0.value))" }
            lines.write(ClassifiedOut(
                index: row.index, speaker: row.speaker, noise: row.noise, interval: row.interval, noiseLevel: row.noiseLevel,
                playing: describe(InterferenceAdvisor.describe(classifications: labels, context: .sweepPlaying)),
                silentReading: describe(InterferenceAdvisor.describe(classifications: labels, context: .sweepSilent)),
                tail: describe(InterferenceAdvisor.describe(classifications: tailLabels, context: .sweepSilent)),
                topLabels: Array(top)
            ))
        }
    }
    /// Harmonics by order for the clean recordings of all three speakers at every microphone, both drives, 4, 8 and 16 s:
    /// each order against the fundamental, smoothed as `RunAnalyzer` smooths THD (1/12 octave), at a few frequencies.
    @Test func `harmonics by order, all three speakers`() throws {
        let rows = try GeithainSurvey.playlist().filter { [4, 8, 16].contains($0.length) && $0.noise == "clean" }
        // Per speaker, length and drive: the first three clean recordings.
        var sample: [GeithainSurvey.Row] = []
        for speaker in [0, 1, 2] {
            for length in [4, 8, 16] {
                for drive in [0.5, 0.25] {
                    sample += rows.filter { $0.speaker == speaker && $0.length == length && $0.drive == drive }.prefix(3)
                }
            }
        }
        struct OrderOut: Codable {
            let index: Int
            let mic: Int
            let speaker: Int
            let length: Int
            let drive: Double
            let frequencies: [Float]
            /// Order → dB re the fundamental at each frequency (nil outside its trusted band).
            let orders: [String: [Float?]]
            let thdPercent: [Float?]
            let floorPercent: [Float?]
            let measurable: [Bool]
            /// The response at each frequency less its median from 300 Hz to 3 kHz, dB.
            let response: [Float]
        }
        let frequencies: [Float] = [100, 150, 200, 300, 400, 500, 600, 800, 1000, 1500, 2000, 3000, 5000, 8000]
        let folder = GeithainSurvey.outputFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lines = try GeithainSurvey.Lines(folder.appendingPathComponent("orders.jsonl"))
        let all = sample
        DispatchQueue.concurrentPerform(iterations: all.count) { position in
            let row = all[position]
            guard let recording = try? GeithainSurvey.channels(GeithainRuns.output(row.index)) else { return }
            let sweep = GeithainSurvey.sweep(seconds: row.length)
            for mic in GeithainSurvey.microphones {
                let impulse = Deconvolution.impulseResponse(recording: recording[mic], sweep: sweep)
                let distortion = HarmonicDistortion.analyze(impulseResponse: impulse, sweep: sweep)
                let fraction = DiagnosisThresholds.standard.distortionSmoothingFraction
                let fundamental = Smoothing.fractionalOctave(distortion.fundamental, fraction: fraction)
                var orders: [String: [Float?]] = [:]
                for (order, curve) in distortion.harmonics {
                    let smoothed = Smoothing.fractionalOctave(curve, fraction: fraction)
                    guard let low = smoothed.frequencies.first, let high = smoothed.frequencies.last else { continue }
                    orders["\(order)"] = frequencies.map { frequency in
                        (low...high).contains(frequency) ? smoothed.decibels(at: frequency) - fundamental.decibels(at: frequency) : nil
                    }
                }
                let thd = Smoothing.fractionalOctave(distortion.thd, fraction: fraction)
                let read = SweepDistortion(fundamental: distortion.fundamental, harmonics: distortion.harmonics, thd: thd,
                                           noiseFloor: distortion.noiseFloor)
                let response = Smoothing.fractionalOctave(impulse.frequencyResponse(), fraction: 3)
                let grid = ResponseGrid.frequencies.map(response.decibels(at:))
                let reference = RunAnalyzer.referenceLevel(of: grid)
                lines.write(OrderOut(
                    index: row.index, mic: mic, speaker: row.speaker, length: row.length, drive: row.drive, frequencies: frequencies,
                    orders: orders,
                    thdPercent: frequencies.map { let value = read.thdPercent(at: $0); return value.isNaN ? nil : value },
                    floorPercent: frequencies.map { read.noiseFloorPercent(at: $0) },
                    measurable: frequencies.map(read.isMeasurable(at:)),
                    response: frequencies.map { response.decibels(at: $0) - reference }
                ))
            }
        }
    }
}

