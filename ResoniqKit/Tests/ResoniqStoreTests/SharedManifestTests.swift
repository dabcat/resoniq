import Foundation
import ResoniqAudio
import ResoniqDiagnostics
import Testing

@testable import ResoniqStore

/// `RecordingManifest.shared()`: what of a kept test's manifest may leave the phone, field by field.
struct SharedManifestTests {
    /// A manifest with every name filled in, a label with a person, and a speaker with make, model and unit.
    private static func full() -> RecordingManifest {
        var manifest = RecordingFixtures.example().manifest
        manifest.system = .init(name: "Anna's den speakers", kind: .stereoPair)
        manifest.room = .init(name: "Anna's den")
        manifest.audioRoute = .init(
            output: .init(kind: .bluetooth, name: "Anna's JBL Flip 5"),
            input: .init(kind: .builtInMicrophone, name: "Anna's iPhone Microphone")
        )
        manifest.speaker = .init(position: .left, channel: .left, make: "KEF", model: "LS50", unitID: "SN-12345")
        manifest.label = .init(value: "healthy", givenBy: "Anna Example", how: "listening", confidence: "high")
        return manifest
    }

    private static var zurich: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }

    /// Every stored field of the manifest. A new one fails this test until `shared()` and the plan's Notes decide it.
    @Test func `every field of the manifest has been decided`() {
        let fields = Mirror(reflecting: Self.full()).children.compactMap(\.label)
        #expect(fields == [
            "schemaVersion", "kind", "createdAt", "sampleRate", "playback", "device", "audioRoute", "speaker", "system",
            "room", "sweep", "noiseFloor", "runs", "report", "label",
        ])
        let device = Mirror(reflecting: Self.full().device).children.compactMap(\.label)
        #expect(device == ["model", "systemName", "systemVersion", "appVersion"])
        let run = Mirror(reflecting: Self.full().runs[0]).children.compactMap(\.label)
        #expect(run == [
            "run", "file", "sampleCount", "leadInSamples", "arrivalDelay", "measuredDelay", "routeDelay", "check",
            "spliceCount", "phoneMoved", "attempt", "sweepTiedSound", "takeOffsets", "clockRatio", "clockSource",
            "clockDisagreementPPM",
        ])
    }

    @Test func `the names the person typed are left out`() {
        let shared = Self.full().shared(calendar: Self.zurich)
        #expect(shared.system == .init(name: nil, kind: .stereoPair))
        #expect(shared.room == nil)
    }

    @Test func `the routes keep their kind and lose their names`() {
        let shared = Self.full().shared(calendar: Self.zurich)
        #expect(shared.audioRoute.output == .init(kind: .bluetooth, name: nil))
        #expect(shared.audioRoute.input == .init(kind: .builtInMicrophone, name: nil))
        var noOutput = Self.full()
        noOutput.audioRoute.output = nil
        #expect(noOutput.shared().audioRoute.output == nil)
    }

    @Test func `only the day is kept, in the person's calendar, without the time zone`() throws {
        // 2026-11-14 23:30 in Zurich is 22:30 UTC: still the 14th where the person is.
        var manifest = Self.full()
        manifest.createdAt = try #require(Self.zurich.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 23, minute: 30)))
        let shared = manifest.shared(calendar: Self.zurich)
        #expect(shared.createdAt == Date(timeIntervalSince1970: 1_794_614_400)) // 2026-11-14T00:00:00Z
        let text = String(decoding: try RecordingManifest.encoder.encode(shared), as: UTF8.self)
        #expect(text.contains("\"createdAt\" : \"2026-11-14T00:00:00Z\""))
    }

    @Test func `the speaker keeps its position and channel only`() {
        let shared = Self.full().shared(calendar: Self.zurich)
        #expect(shared.speaker == .init(position: .left, channel: .left))
        #expect(shared.speaker.make == nil && shared.speaker.model == nil && shared.speaker.unitID == nil)
    }

    @Test func `a label keeps what it says and loses who gave it`() {
        let shared = Self.full().shared(calendar: Self.zurich)
        #expect(shared.label == .init(value: "healthy", givenBy: nil, how: "listening", confidence: "high"))
    }

    @Test func `the device keeps its model and versions`() {
        let shared = Self.full().shared(calendar: Self.zurich)
        #expect(shared.device == RecordingFixtures.device)
        #expect(shared.device.model == "iPhone17,1")
    }

    @Test func `the measurement is kept whole`() {
        let full = Self.full()
        let shared = full.shared(calendar: Self.zurich)
        #expect(shared.schemaVersion == full.schemaVersion)
        #expect(shared.kind == full.kind)
        #expect(shared.sampleRate == full.sampleRate)
        #expect(shared.playback == full.playback)
        #expect(shared.sweep == full.sweep)
        #expect(shared.noiseFloor == full.noiseFloor)
        #expect(shared.runs == full.runs)
        #expect(shared.report == full.report)
    }

    @Test func `the shared JSON holds no name anywhere, the report included`() throws {
        let shared = Self.full().shared(calendar: Self.zurich)
        let text = String(decoding: try RecordingManifest.encoder.encode(shared), as: UTF8.self)
        for word in ["Anna", "JBL", "KEF", "LS50", "SN-12345", "iPhone Microphone", "My speakers", "My room", "Living Room"] {
            #expect(!text.contains(word), "\(word) is in the shared manifest")
        }
        #expect(!text.contains("\"name\""))
        #expect(!text.contains("\"room\""))
        #expect(!text.contains("\"givenBy\""))
        // The report is made from the runs alone: nothing in it can carry a name.
        let report = String(decoding: try RecordingManifest.encoder.encode(shared.report), as: UTF8.self)
        #expect(!report.contains("\"name\""))
        #expect(!report.contains("Anna") && !report.contains("My speakers") && !report.contains("My room"))
    }

    @Test func `a manifest kept before still reads back and shares the same way`() throws {
        // Phase 9 wrote routes as `{ kind, name }` and a room with a name; the optional names read the same.
        let data = try RecordingManifest.encoder.encode(RecordingFixtures.example().manifest)
        let back = try RecordingManifest.decoder.decode(RecordingManifest.self, from: data)
        #expect(back.audioRoute.output?.name == "Living Room")
        #expect(back.room?.name == "My room")
        #expect(back.shared().room == nil)
    }
}
