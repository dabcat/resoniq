import Foundation
import ResoniqAudio
import ResoniqDiagnostics
import ResoniqDSP
import SwiftData
import Testing

@testable import ResoniqStore

/// A kept speaker test's raw recordings: what one example holds, that it reads back exactly, and that every delete
/// of the test takes its folder with it.
enum RecordingFixtures {
    static let sampleRate = 48000.0

    /// A finished three-run test by hand: short runs of a quiet sine and a second of hiss for the floor.
    static func result(source: PlaybackSource = .thisPhone, runLength: Int = 4800) -> MeasurementResult {
        let floorSamples = (0..<48000).map { Float(sin(Double($0) * 1.7)) * 1e-4 }
        let floor = NoiseFloor.measure(floorSamples, sampleRate: sampleRate)
        let runs = (1...3).map { run in
            let samples = (0..<runLength).map { Float(sin(Double($0) * 0.05 * Double(run))) * 0.2 }
            return RunRecording(
                run: run, samples: samples, sampleRate: sampleRate, leadIn: 2400, arrivalDelay: 0.07,
                verdict: RecordingQuality.assess(recording: samples, noiseFloor: floor),
                spliceCount: run == 2 ? 1 : 0, phoneMoved: run == 3, attempt: 1,
                sweepTiedSound: run == 2 ? 120...160 : nil, takeOffsets: run == 2 ? [0.4] : [],
                measuredDelay: 0.0712 + Double(run) * 0.0001,
                clockRatio: source == .anotherDevice ? 1.0003 : nil,
                clockSource: source == .anotherDevice ? .tone : nil
            )
        }
        return MeasurementResult(
            channel: .left, sweep: LogSweep.measurement(sampleRate: sampleRate), noiseFloor: floor, runs: runs,
            source: source, noiseFloorSamples: floorSamples,
            outputRoute: source == .thisPhone ? AudioOutputRoute(kind: .airPlay, name: "Living Room") : nil,
            inputRoute: AudioInputRoute(kind: .builtInMicrophone, name: "iPhone Microphone")
        )
    }

    /// Three runs the app could not use (silent), so the report has a check per run without any DSP.
    static func report() -> SpeakerReport {
        let silent = RecordingQuality.assess(recording: [Float](repeating: 0, count: 4800), noiseFloor: result().noiseFloor)
        return SpeakerDiagnosis.diagnose(runs: Array(repeating: RunAnalysis(verdict: silent, measurement: nil), count: 3), counterpart: nil)
    }

    static let device = RecordingManifest.Device(model: "iPhone17,1", systemName: "iOS", systemVersion: "26.1", appVersion: "0.1.0 (1)")
    static let date = Date(timeIntervalSince1970: 1_794_661_200) // 2026-11-14 13:00 UTC

    static func example(source: PlaybackSource = .thisPhone) -> RecordingExample {
        RecordingExample(
            result: result(source: source), report: report(), speaker: .left, systemName: "My speakers",
            systemKind: .stereoPair, roomName: "My room", date: date, device: device
        )
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("resoniq-recordings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct RecordingManifestTests {
    @Test func `the manifest holds what the dataset plan lists and the app knows`() throws {
        let example = RecordingFixtures.example()
        let manifest = example.manifest
        #expect(manifest.schemaVersion == RecordingManifest.currentSchemaVersion)
        #expect(manifest.kind == .speakerTest)
        #expect(manifest.createdAt == RecordingFixtures.date)
        #expect(manifest.sampleRate == 48000)
        #expect(manifest.playback == .thisPhone)
        #expect(manifest.device == RecordingFixtures.device)
        #expect(manifest.audioRoute.output == AudioOutputRoute(kind: .airPlay, name: "Living Room"))
        #expect(manifest.audioRoute.input == AudioInputRoute(kind: .builtInMicrophone, name: "iPhone Microphone"))
        #expect(manifest.speaker == .init(position: .left, channel: .left))
        #expect(manifest.speaker.make == nil && manifest.speaker.model == nil && manifest.speaker.unitID == nil)
        #expect(manifest.system == .init(name: "My speakers", kind: .stereoPair))
        #expect(manifest.room == .init(name: "My room"))
        #expect(manifest.label == nil)

        let sweep = LogSweep.measurement(sampleRate: 48000)
        #expect(manifest.sweep == .init(
            startFrequency: sweep.startFrequency, endFrequency: sweep.endFrequency, duration: sweep.duration,
            sampleRate: sweep.sampleRate, amplitude: sweep.amplitude, fadeDuration: sweep.fadeDuration,
            sampleCount: sweep.sampleCount
        ))
        let floor = RecordingFixtures.result().noiseFloor
        #expect(manifest.noiseFloor == .init(
            file: "noise-floor.wav", sampleCount: 48000, rmsDecibels: floor.rmsDecibels,
            fluctuationDecibels: floor.fluctuationDecibels, isSteady: floor.isSteady
        ))

        #expect(manifest.runs.map(\.run) == [1, 2, 3])
        #expect(manifest.runs.map(\.file) == ["run-1.wav", "run-2.wav", "run-3.wav"])
        #expect(manifest.runs.map(\.sampleCount) == [4800, 4800, 4800])
        #expect(manifest.runs.map(\.spliceCount) == [0, 1, 0])
        #expect(manifest.runs.map(\.phoneMoved) == [false, false, true])
        #expect(manifest.runs.map(\.leadInSamples) == [2400, 2400, 2400])
        // The route's delay is the measured delay less the lead-in.
        #expect(abs((manifest.runs[0].routeDelay ?? 0) - (0.0713 - 0.05)) < 1e-9)
        #expect(manifest.runs[1].sweepTiedSound == .init(lower: 120, upper: 160))
        #expect(manifest.runs[1].takeOffsets == [0.4])
        // Each run's check is the report's.
        #expect(manifest.runs.map(\.check) == RecordingFixtures.report().runs.map(\.check))
        #expect(manifest.report.schemaVersion == SpeakerTest.currentReportSchemaVersion)
        #expect(manifest.report.value == RecordingFixtures.report())
        #expect(example.runs.count == 3 && example.noiseFloor.count == 48000)
    }

    @Test func `a test played from another device says so, with its clock`() {
        let manifest = RecordingFixtures.example(source: .anotherDevice).manifest
        #expect(manifest.playback == .anotherDevice)
        #expect(manifest.audioRoute.output == nil)
        #expect(manifest.runs.allSatisfy { $0.clockRatio == 1.0003 && $0.clockSource == .tone })
    }

    @Test func `the manifest is readable JSON with dates as text and the absent fields left out`() throws {
        let data = try RecordingManifest.encoder.encode(RecordingFixtures.example().manifest)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(text.contains("\"createdAt\" : \"2026-11-14T13:00:00Z\""))
        #expect(!text.contains("\"label\""))
        #expect(!text.contains("\"make\""))
        let back = try RecordingManifest.decoder.decode(RecordingManifest.self, from: data)
        #expect(back == RecordingFixtures.example().manifest)
    }

    @Test func `the current device is named`() {
        let device = RecordingManifest.Device.current(appVersion: "1.0 (2)")
        #expect(!device.model.isEmpty && !device.systemVersion.isEmpty)
        #expect(device.appVersion == "1.0 (2)")
    }

    @Test func `folder names sort by date and say which speaker`() {
        let name = RecordingStore.folderName(date: RecordingFixtures.date, speaker: .left, id: UUID(uuidString: "1A2B3C4D-0000-0000-0000-000000000000")!, timeZone: TimeZone(identifier: "UTC")!)
        #expect(name == "2026-11-14_130000_left_1A2B3C4D")
    }
}

struct RecordingStoreTests {
    @Test func `an example reads back bit for bit`() throws {
        let files = RecordingStore(root: try RecordingFixtures.directory())
        let example = RecordingFixtures.example()
        try files.write(example, named: "one")
        let names = try FileManager.default.contentsOfDirectory(atPath: files.folder.appendingPathComponent("one").path).sorted()
        #expect(names == ["manifest.json", "noise-floor.wav", "run-1.wav", "run-2.wav", "run-3.wav"])
        let back = try files.read("one")
        #expect(back.manifest == example.manifest)
        #expect(back.runs.map { $0.map(\.bitPattern) } == example.runs.map { $0.map(\.bitPattern) })
        #expect(back.noiseFloor.map(\.bitPattern) == example.noiseFloor.map(\.bitPattern))
        // Mono 32-bit float at the recorded rate.
        let wav = try WAVFile.read(Data(contentsOf: files.folder.appendingPathComponent("one/run-1.wav")))
        #expect(wav.sampleRate == 48000 && wav.channels.count == 1)
    }

    @Test func `its size is the audio and the manifest`() throws {
        let files = RecordingStore(root: try RecordingFixtures.directory())
        #expect(files.totalSize() == 0)
        try files.write(RecordingFixtures.example(), named: "one")
        let samples: Int64 = 48000 + 3 * 4800
        let audio: Int64 = samples * 4 + 4 * 44
        let size = files.totalSize()
        #expect(size > audio && size < audio + 64_000, "size \(size)")
        try files.write(RecordingFixtures.example(), named: "two")
        #expect(files.totalSize() == 2 * size)
        #expect(files.names() == ["one", "two"])
    }

    @Test func `the folder is left out of the backup`() throws {
        let files = RecordingStore(root: try RecordingFixtures.directory())
        try files.write(RecordingFixtures.example(), named: "one")
        let values = try files.folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func `writing over a name replaces it, and a write in progress is not an example`() throws {
        let files = RecordingStore(root: try RecordingFixtures.directory())
        try files.write(RecordingFixtures.example(), named: "one")
        try files.write(RecordingFixtures.example(source: .anotherDevice), named: "one")
        #expect(try files.read("one").manifest.playback == .anotherDevice)
        // A partial folder left by a write that never finished is not listed, and the sweep takes it.
        try FileManager.default.createDirectory(at: files.folder.appendingPathComponent(".two.partial"), withIntermediateDirectories: true)
        #expect(files.names() == ["one"])
        #expect(files.sweep(keeping: ["one"]) == [".two.partial"])
        #expect(files.names() == ["one"])
    }

    @Test func `delete, delete all and odd names`() throws {
        let files = RecordingStore(root: try RecordingFixtures.directory())
        try files.write(RecordingFixtures.example(), named: "one")
        try files.write(RecordingFixtures.example(), named: "two")
        files.delete("../one")
        files.delete("missing")
        #expect(files.names() == ["one", "two"])
        files.delete("one")
        #expect(files.names() == ["two"])
        #expect(throws: (any Error).self) { try files.read("one") }
        files.deleteAll()
        #expect(files.names().isEmpty && files.totalSize() == 0)
        // A missing folder is not an error.
        #expect(RecordingStore(root: try RecordingFixtures.directory()).sweep(keeping: []).isEmpty)
    }
}

@MainActor
struct StoreRecordingTests {
    let files: RecordingStore
    let store: ResoniqStore

    init() throws {
        files = RecordingStore(root: try RecordingFixtures.directory())
        store = ResoniqStore(container: try ResoniqStore.inMemoryContainer(), recordings: files)
    }

    private func keptTest() throws -> SpeakerTest {
        let system = try store.defaultContext().system
        return try store.keep(RecordingFixtures.report(), speaker: .left, in: system, date: RecordingFixtures.date)
    }

    @Test func `keeping a recording names its folder on the test`() async throws {
        let test = try keptTest()
        let written = await store.keepRecording(RecordingFixtures.example(), for: test)
        #expect(written)
        let name = try #require(test.recordingFileName)
        #expect(name == RecordingStore.folderName(date: RecordingFixtures.date, speaker: .left, id: try #require(UUID(uuidString: String(name.suffix(8)) + "-0000-0000-0000-000000000000"))))
        #expect(files.names() == [name])
        #expect(try files.read(name).manifest == RecordingFixtures.example().manifest)
        #expect(store.recordingsSize() == files.totalSize())
        // Saved, not only held in memory.
        let again = try ModelContext(store.container).fetch(FetchDescriptor<SpeakerTest>())
        #expect(again.map(\.recordingFileName) == [name])
    }

    @Test func `a store without a recordings folder keeps nothing`() async throws {
        let bare = ResoniqStore(container: try ResoniqStore.inMemoryContainer())
        let test = try bare.keep(RecordingFixtures.report(), speaker: .left, in: try bare.defaultContext().system)
        #expect(await bare.keepRecording(RecordingFixtures.example(), for: test) == false)
        #expect(test.recordingFileName == nil)
        #expect(bare.recordingsSize() == 0)
    }

    @Test func `a write that fails leaves the report kept and no name`() async throws {
        // The root is a file, so no folder can be made under it.
        let blocked = try RecordingFixtures.directory().appendingPathComponent("file")
        try Data("x".utf8).write(to: blocked)
        let failing = ResoniqStore(container: try ResoniqStore.inMemoryContainer(), recordings: RecordingStore(root: blocked))
        let test = try failing.keep(RecordingFixtures.report(), speaker: .left, in: try failing.defaultContext().system)
        #expect(await failing.keepRecording(RecordingFixtures.example(), for: test) == false)
        #expect(test.recordingFileName == nil)
        #expect(test.report == RecordingFixtures.report())
        #expect(try ModelContext(failing.container).fetchCount(FetchDescriptor<SpeakerTest>()) == 1)
    }

    @Test func `don't keep deletes the folder`() async throws {
        let test = try keptTest()
        _ = await store.keepRecording(RecordingFixtures.example(), for: test)
        try store.discard(test)
        #expect(files.names().isEmpty)
    }

    @Test func `a test discarded while its recording is written leaves nothing behind`() async throws {
        let test = try keptTest()
        let writing = Task { await store.keepRecording(RecordingFixtures.example(), for: test) }
        // The write starts and suspends off the main actor; the test goes while it runs.
        await Task.yield()
        try store.discard(test)
        _ = await writing.value
        #expect(files.names().isEmpty)
    }

    @Test func `deleting the system or the room deletes their recordings`() async throws {
        let room = try store.defaultContext().room
        let other = try store.addSystem(name: "Second", kind: .singleSpeaker, to: room)
        let first = try keptTest()
        let second = try store.keep(RecordingFixtures.report(), speaker: .single, in: other)
        _ = await store.keepRecording(RecordingFixtures.example(), for: first)
        _ = await store.keepRecording(RecordingFixtures.example(), for: second)
        #expect(files.names().count == 2)
        try store.delete(other)
        #expect(files.names() == [first.recordingFileName].compactMap { $0 })
        let secondRoom = try store.addRoom(name: "Room 2")
        _ = try store.addSystem(name: "x", kind: .stereoPair, to: secondRoom)
        try store.delete(room)
        #expect(files.names().isEmpty)
    }

    @Test func `delete all results and delete everything delete every recording`() async throws {
        _ = await store.keepRecording(RecordingFixtures.example(), for: try keptTest())
        try store.deleteAllResults()
        #expect(files.names().isEmpty)
        _ = await store.keepRecording(RecordingFixtures.example(), for: try keptTest())
        try store.deleteEverything()
        #expect(files.names().isEmpty)
    }

    @Test func `delete recordings keeps the results`() async throws {
        let test = try keptTest()
        _ = await store.keepRecording(RecordingFixtures.example(), for: test)
        #expect(try store.counts().recordings == 1)
        try store.deleteRecordings()
        #expect(files.names().isEmpty && store.recordingsSize() == 0)
        #expect(test.recordingFileName == nil && test.report != nil)
        #expect(try store.counts().recordings == 0 && store.counts().speakerTests == 1)
    }

    @Test func `the sweep removes folders no test refers to`() async throws {
        let test = try keptTest()
        _ = await store.keepRecording(RecordingFixtures.example(), for: test)
        try files.write(RecordingFixtures.example(), named: "orphan")
        #expect(try store.sweepRecordings() == ["orphan"])
        #expect(files.names() == [test.recordingFileName].compactMap { $0 })
    }
}

struct RecordingPreferenceTests {
    @Test func `keeping recordings is off until turned on`() throws {
        let defaults = try #require(UserDefaults(suiteName: "resoniq-pref-\(UUID().uuidString)"))
        let preference = RecordingPreference(defaults: defaults)
        #expect(!preference.isOn)
        preference.isOn = true
        #expect(RecordingPreference(defaults: defaults).isOn)
        #expect(defaults.bool(forKey: RecordingPreference.key))
    }
}
