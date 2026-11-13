import Foundation

/// Whether the camera may be used, as the system says (`AVCaptureDevice.authorizationStatus(for: .video)`), without
/// AVFoundation so the decision is tested on the Mac.
public enum CameraPermission: Sendable, Equatable {
    case notDetermined
    case authorized
    case denied
    /// Parental controls or device management; the person cannot change it, so it reads as denied.
    case restricted
}

/// What the Scan screen should show before a scan can start.
public enum ScanReadiness: Sendable, Equatable {
    /// No LiDAR (`RoomCaptureSession.isSupported` is false): offer to enter the room by hand.
    case unsupported
    /// The camera has not been asked for yet: say why, then ask.
    case needsPermission
    /// The camera is off for the app: explain and link to Settings.
    case denied
    case ready

    /// The device decides first: without LiDAR the camera question does not arise.
    public init(isSupported: Bool, camera: CameraPermission) {
        guard isSupported else {
            self = .unsupported
            return
        }
        switch camera {
        case .authorized: self = .ready
        case .notDetermined: self = .needsPermission
        case .denied, .restricted: self = .denied
        }
    }
}

/// RoomPlan's coaching instruction (`RoomCaptureSession.Instruction`), as a plain value the app can send across
/// isolation and test.
public enum ScanInstruction: Sendable, Equatable, CaseIterable {
    case moveCloser
    case moveAway
    case slowDown
    case turnOnLight
    case lowTexture
    case normal
}

/// Which way the instruction's arrow points, when it has one. The app maps it to `DirectionArrowInstruction`.
public enum ScanDirection: Sendable, Equatable {
    case forward
    case back
    case left
    case right
}

/// Why a scan ended without a room. The RoomPlan capture errors (`RoomCaptureSession.CaptureError`) map one to one;
/// `noWalls` is a scan that finished with nothing in it (RoomScan's `emptyScan`).
public enum ScanFailure: Sendable, Equatable, CaseIterable {
    case worldTrackingFailure
    case sceneTooLarge
    case deviceTooHot
    case deviceNotSupported
    case invalidConfiguration
    case internalError
    case noWalls
    case unknown
}

/// The live progress of a scan, for the floor-plan inset.
public enum ScanProgress {
    /// Where the walls still missing probably are: for each open chain of two or more joined walls, the segment
    /// between its two free ends. A single wall, or chains that do not say where they close, give nothing.
    ///
    /// A guess for drawing only (a dashed line on the inset); the coverage count is `RoomGeometry.coverage(of:)`.
    public static func missingWalls(of room: RoomModel) -> [Wall] {
        let walls = room.walls
        guard walls.count >= 2 else { return [] }
        var parent = Array(walls.indices)
        func root(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { i = parent[i] }
            return i
        }
        func ends(_ i: Int) -> [PlanPoint] { [walls[i].start, walls[i].end] }
        var freeEnds: [(chain: Int, point: PlanPoint)] = []
        var isFree = Array(repeating: [true, true], count: walls.count)
        for i in walls.indices {
            for j in walls.indices where j != i {
                for (e, end) in ends(i).enumerated()
                where ends(j).contains(where: { $0.distance(to: end) <= RoomGeometry.cornerJoin }) {
                    isFree[i][e] = false
                    parent[root(i)] = root(j)
                }
            }
        }
        for i in walls.indices {
            for (e, end) in ends(i).enumerated() where isFree[i][e] { freeEnds.append((root(i), end)) }
        }
        let chains = Dictionary(grouping: freeEnds, by: \.chain)
        return chains.keys.sorted().compactMap { key -> Wall? in
            guard let points = chains[key], points.count == 2 else { return nil }
            let size = walls.indices.filter { root($0) == key }.count
            guard size >= 2 else { return nil }
            return Wall(
                id: walls[key].id, start: points[0].point, end: points[1].point,
                height: RoomGeometry.height(of: room))
        }
    }

    /// A plan angle as the inset's facing: degrees clockwise from up the plan, where up is −z (ARKit's forward
    /// from the start of the session), 0…360.
    public static func insetFacing(planAngle: Double) -> Double {
        let direction = PlanPoint(angle: planAngle)
        let degrees = PlanAngle.degrees(atan2(direction.x, -direction.z))
        return degrees < 0 ? degrees + 360 : degrees
    }
}
