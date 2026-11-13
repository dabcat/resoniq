import Foundation
import Observation
import ResoniqRoom
import SwiftUI

/// What a finished scan hands back: the room to store (`Codable`), what RoomPlan was unsure of or the model could
/// not hold, and the scan's USDZ in a temporary file when it could be written. The caller moves the file somewhere
/// lasting or lets it go; nothing here persists anything.
nonisolated struct RoomScanResult: Sendable, Equatable {
    var room: RoomModel
    var lowConfidence: Set<UUID> = []
    var dropped: [RoomPlanMapping.Dropped] = []
    var usdzURL: URL?
}

/// Where a scan is.
nonisolated enum ScanPhase: Sendable, Equatable {
    /// The camera is starting.
    case preparing
    case scanning
    /// Finish was tapped; RoomPlan is building the room.
    case processing
    case finished(RoomScanResult)
    case failed(ScanFailure)

    var isFinished: Bool {
        if case .finished = self { true } else { false }
    }
}

/// A label over the camera at a point of the camera view, in unit coordinates (0…1 from the top left).
nonisolated struct ScanLabel: Sendable, Equatable, Identifiable {
    var id: UUID
    var text: String
    /// A wall length (`ResoniqChip.measurement`); otherwise a thing found (`.detected`).
    var isMeasurement: Bool
    var position: UnitPoint
}

/// Where the phone is on the plan and which way it points (a plan angle), for the inset's dot and wedge.
nonisolated struct ScanCameraPose: Sendable, Equatable {
    var position: PlanPoint
    var heading: Double
}

/// What drives a scan: RoomPlan on a LiDAR device (`LiveRoomScanSource`), or a script in the simulator and
/// previews (`ScriptedRoomScanSource`). The screen only talks to `RoomScanModel`; the source reports into it.
protocol RoomScanSource: AnyObject {
    /// The picture behind the screen: RoomPlan's own camera view, or a stand-in.
    func makeCameraView(for model: RoomScanModel) -> AnyView
    /// Begin. A live source starts when its camera view appears; a script starts its clock.
    func start(_ model: RoomScanModel)
    /// Stop capturing and build the room; the result arrives through `RoomScanModel.didFinish` or `didFail`.
    func finish()
    /// Stop and throw the scan away.
    func cancel()
}

/// The live state of the Scan screen (V3OScan): the room so far for the inset and the wall count, the labels over
/// the camera, RoomPlan's instruction, and the phase.
@Observable
final class RoomScanModel {
    private(set) var phase: ScanPhase
    /// The walls, openings and furniture captured so far; no guessed speakers.
    private(set) var room = RoomModel(source: .scanned, walls: [])
    private(set) var instruction: ScanInstruction = .normal
    private(set) var labels: [ScanLabel] = []
    private(set) var camera: ScanCameraPose?

    @ObservationIgnored let source: any RoomScanSource
    @ObservationIgnored private var hasStarted = false

    init(source: any RoomScanSource, phase: ScanPhase = .preparing) {
        self.source = source
        self.phase = phase
    }

    var coverage: WallCoverage { RoomGeometry.coverage(of: room) }
    var guidance: ScanGuidance { ScanText.guidance(for: instruction, coverage: coverage) }
    var missingWalls: [Wall] { ScanProgress.missingWalls(of: room) }
    var canFinish: Bool { phase == .scanning }

    // MARK: From the screen

    func start() {
        guard !hasStarted, phase == .preparing else { return }
        hasStarted = true
        source.start(self)
    }

    func finish() {
        guard canFinish else { return }
        labels = []
        phase = .processing
        source.finish()
    }

    func cancel() {
        source.cancel()
    }

    // MARK: From the source

    func didStart() {
        if phase == .preparing { phase = .scanning }
    }

    func update(room: RoomModel) {
        guard phase == .scanning else { return }
        self.room = room
    }

    func update(instruction: ScanInstruction) {
        guard phase == .scanning, instruction != self.instruction else { return }
        self.instruction = instruction
    }

    func update(labels: [ScanLabel], camera: ScanCameraPose?) {
        guard phase == .scanning else { return }
        if labels != self.labels { self.labels = labels }
        if camera != self.camera { self.camera = camera }
    }

    func didFinish(_ result: RoomScanResult) {
        guard !phase.isFinished else { return }
        labels = []
        phase = .finished(result)
    }

    func didFail(_ failure: ScanFailure) {
        guard !phase.isFinished else { return }
        labels = []
        phase = .failed(failure)
    }
}
