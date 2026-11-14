import Foundation
import ResoniqAudio
import ResoniqDiagnostics
import ResoniqDSP

/// Everything the app knew about one kept speaker test besides its audio, as `manifest.json` beside the recordings
/// (`RecordingStore`). The fields follow the dataset plan's table "What one saved example must hold"
/// (`docs/research/2026-11-13-defect-dataset-plan.md`), limited to what the app knows today: the speaker's make,
/// model and unit, and a label, are optional and absent until something asks for them. `DefectFeatures` and the
/// spectrogram are not stored: they are recomputed from the audio, which is the point of keeping it.
///
/// Bump `currentSchemaVersion` when a field changes meaning or is removed; a new optional field does not need it.
public struct RecordingManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public enum Kind: String, Codable, Sendable { case speakerTest }

    /// What played the test sound.
    public enum Playback: String, Codable, Sendable {
        case thisPhone, anotherDevice
    }

    public struct Device: Codable, Sendable, Equatable {
        /// The hardware identifier ("iPhone17,1"); in the simulator, the simulated model's.
        public var model: String
        public var systemName: String
        public var systemVersion: String
        /// "0.1.0 (1)": the app's version and build, as the app gives them.
        public var appVersion: String?

        public init(model: String, systemName: String, systemVersion: String, appVersion: String? = nil) {
            self.model = model
            self.systemName = systemName
            self.systemVersion = systemVersion
            self.appVersion = appVersion
        }

        /// This device, read from the system.
        public static func current(appVersion: String? = nil) -> Device {
            let environment = ProcessInfo.processInfo.environment
            let model = environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardwareModel()
            let version = ProcessInfo.processInfo.operatingSystemVersion
            #if os(iOS)
            let system = "iOS"
            #else
            let system = "macOS"
            #endif
            return Device(
                model: model, systemName: system,
                systemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                appVersion: appVersion
            )
        }

        private static func hardwareModel() -> String {
            var info = utsname()
            uname(&info)
            let machine = withUnsafeBytes(of: &info.machine) { buffer in
                String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            }
            return machine.isEmpty ? "unknown" : machine
        }
    }

    /// The routes the IO reported when the test opened. No output when another device played the sound.
    public struct Route: Codable, Sendable, Equatable {
        public var output: AudioOutputRoute?
        public var input: AudioInputRoute?
    }

    public struct Speaker: Codable, Sendable, Equatable {
        public enum Channel: String, Codable, Sendable { case left, right, both }

        public var position: SpeakerPosition
        /// The channel the sweep played on.
        public var channel: Channel
        /// Not known to the app yet; absent.
        public var make: String?
        public var model: String?
        /// An id for this unit, to split a dataset by speaker; absent.
        public var unitID: String?

        public init(position: SpeakerPosition, channel: Channel, make: String? = nil, model: String? = nil, unitID: String? = nil) {
            self.position = position
            self.channel = channel
            self.make = make
            self.model = model
            self.unitID = unitID
        }
    }

    public struct System: Codable, Sendable, Equatable {
        public var name: String
        public var kind: SoundSystemKind
    }

    public struct Room: Codable, Sendable, Equatable {
        public var name: String
    }

    /// `LogSweep`'s parameters: what the runs are deconvolved against.
    public struct Sweep: Codable, Sendable, Equatable {
        public var startFrequency: Double
        public var endFrequency: Double
        public var duration: Double
        public var sampleRate: Double
        public var amplitude: Float
        public var fadeDuration: Double
        public var sampleCount: Int
    }

    public struct NoiseFloor: Codable, Sendable, Equatable {
        public var file: String
        public var sampleCount: Int
        public var rmsDecibels: Float
        public var fluctuationDecibels: Float
        public var isSteady: Bool
    }

    public struct FrequencySpan: Codable, Sendable, Equatable {
        public var lower: Double
        public var upper: Double
    }

    public enum ClockSource: String, Codable, Sendable { case tone, sweepSpacing, earlierPlay }

    /// One run, as `RunRecording` had it.
    public struct Run: Codable, Sendable, Equatable {
        /// 1-based.
        public var run: Int
        public var file: String
        public var sampleCount: Int
        /// Samples recorded before the sweep's scheduled first sample.
        public var leadInSamples: Int
        /// Seconds to the sweep's arrival, estimated live.
        public var arrivalDelay: Double?
        /// Seconds from the first sample to the deconvolved response's peak (the route's delay plus the lead-in).
        public var measuredDelay: Double?
        /// The route's own delay, seconds: `measuredDelay` less the lead-in.
        public var routeDelay: Double?
        /// The report's check of this run; nil only if the report has fewer runs than were recorded.
        public var check: RecordingCheck?
        public var spliceCount: Int
        public var phoneMoved: Bool
        /// 1, or 2 when the first recording of the run was unusable.
        public var attempt: Int
        public var sweepTiedSound: FrequencySpan?
        /// Samples between each spliced take and the one before; empty when not spliced.
        public var takeOffsets: [Double]
        /// Another device's clock against the phone's; the samples are already corrected for it.
        public var clockRatio: Double?
        public var clockSource: ClockSource?
        public var clockDisagreementPPM: Double?
    }

    /// The report the app made from these runs, with the version of its encoding.
    public struct Report: Codable, Sendable, Equatable {
        public var schemaVersion: Int
        public var value: SpeakerReport
    }

    /// A label, as the dataset plan describes it. Never written by the app yet.
    public struct Label: Codable, Sendable, Equatable {
        public var value: String
        public var givenBy: String?
        public var how: String?
        public var confidence: String?
    }

    public var schemaVersion: Int
    public var kind: Kind
    public var createdAt: Date
    /// The stream's rate; every file is at it.
    public var sampleRate: Double
    public var playback: Playback
    public var device: Device
    public var audioRoute: Route
    public var speaker: Speaker
    public var system: System
    public var room: Room
    public var sweep: Sweep
    public var noiseFloor: NoiseFloor
    public var runs: [Run]
    public var report: Report
    public var label: Label?

    /// Pretty, sorted, dates as ISO 8601 text; a number that is not finite as text rather than a failed write.
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return decoder
    }
}

/// One kept speaker test whole: the manifest and the audio it names.
public struct RecordingExample: Sendable, Equatable {
    public var manifest: RecordingManifest
    /// Each run's recording, in run order, mono, at `manifest.sampleRate`.
    public var runs: [[Float]]
    /// The room's floor as recorded.
    public var noiseFloor: [Float]

    public init(manifest: RecordingManifest, runs: [[Float]], noiseFloor: [Float]) {
        self.manifest = manifest
        self.runs = runs
        self.noiseFloor = noiseFloor
    }

    /// The example of a finished test and the report made from it.
    public init(
        result: MeasurementResult, report: SpeakerReport, speaker: SpeakerPosition, systemName: String,
        systemKind: SoundSystemKind, roomName: String, date: Date, device: RecordingManifest.Device
    ) {
        let sweep = result.sweep
        let sampleRate = result.runs.first?.sampleRate ?? sweep.sampleRate
        let runs = result.runs.enumerated().map { index, run in
            RecordingManifest.Run(
                run: run.run,
                file: RecordingStore.runFileName(run.run),
                sampleCount: run.samples.count,
                leadInSamples: run.leadIn,
                arrivalDelay: run.arrivalDelay,
                measuredDelay: run.measuredDelay,
                routeDelay: run.measuredDelay.map { $0 - Double(run.leadIn) / run.sampleRate },
                check: index < report.runs.count ? report.runs[index].check : nil,
                spliceCount: run.spliceCount,
                phoneMoved: run.phoneMoved,
                attempt: run.attempt,
                sweepTiedSound: run.sweepTiedSound.map { .init(lower: $0.lowerBound, upper: $0.upperBound) },
                takeOffsets: run.takeOffsets,
                clockRatio: run.clockRatio,
                clockSource: run.clockSource.map(RecordingManifest.ClockSource.init),
                clockDisagreementPPM: run.clockDisagreementPPM
            )
        }
        let manifest = RecordingManifest(
            schemaVersion: RecordingManifest.currentSchemaVersion,
            kind: .speakerTest,
            createdAt: date,
            sampleRate: sampleRate,
            playback: result.source == .thisPhone ? .thisPhone : .anotherDevice,
            device: device,
            audioRoute: .init(output: result.source == .thisPhone ? result.outputRoute : nil, input: result.inputRoute),
            speaker: .init(position: speaker, channel: .init(result.channel)),
            system: .init(name: systemName, kind: systemKind),
            room: .init(name: roomName),
            sweep: .init(
                startFrequency: sweep.startFrequency, endFrequency: sweep.endFrequency, duration: sweep.duration,
                sampleRate: sweep.sampleRate, amplitude: sweep.amplitude, fadeDuration: sweep.fadeDuration,
                sampleCount: sweep.sampleCount
            ),
            noiseFloor: .init(
                file: RecordingStore.noiseFloorFileName, sampleCount: result.noiseFloorSamples.count,
                rmsDecibels: result.noiseFloor.rmsDecibels, fluctuationDecibels: result.noiseFloor.fluctuationDecibels,
                isSteady: result.noiseFloor.isSteady
            ),
            runs: runs,
            report: .init(schemaVersion: SpeakerTest.currentReportSchemaVersion, value: report),
            label: nil
        )
        self.init(manifest: manifest, runs: result.runs.map(\.samples), noiseFloor: result.noiseFloorSamples)
    }
}

extension RecordingManifest.Speaker.Channel {
    init(_ channel: SpeakerChannel) {
        switch channel {
        case .left: self = .left
        case .right: self = .right
        case .both: self = .both
        }
    }
}

extension RecordingManifest.ClockSource {
    init(_ source: ResoniqAudio.ClockSource) {
        switch source {
        case .tone: self = .tone
        case .sweepSpacing: self = .sweepSpacing
        case .earlierPlay: self = .earlierPlay
        }
    }
}
