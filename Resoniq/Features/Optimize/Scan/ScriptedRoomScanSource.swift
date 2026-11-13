import Foundation
import ResoniqRoom
import SwiftUI

/// A scan without RoomPlan, for the simulator and previews (RoomPlan cannot run there): it "captures" the walls of
/// `ScanSample.livingRoom` one by one, with an instruction on the way and the mockup's labels, then finishes with
/// that room and a guessed layout, so the rest of the Optimize flow can be used in the simulator.
final class ScriptedRoomScanSource: RoomScanSource {
    private let room: RoomModel
    private let step: Duration
    private let autoFinish: Bool
    private var task: Task<Void, Never>?
    private weak var model: RoomScanModel?

    /// - Parameters:
    ///   - step: The time between two walls.
    ///   - autoFinish: Finish on its own a little after the last wall, as a person tapping "Finish scan" would.
    init(room: RoomModel = ScanSample.livingRoom, step: Duration = .seconds(1.5), autoFinish: Bool = true) {
        self.room = room
        self.step = step
        self.autoFinish = autoFinish
    }

    func makeCameraView(for model: RoomScanModel) -> AnyView { AnyView(ScanCameraStandIn()) }

    func start(_ model: RoomScanModel) {
        self.model = model
        task = Task { [weak self] in await self?.run() }
    }

    func finish() {
        task?.cancel()
        task = Task { [weak self] in await self?.complete() }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        guard let model else { return }
        model.didStart()
        let centre = PlanPoint(x: 0.2, z: 0.9)
        for count in 1...room.walls.count {
            guard (try? await Task.sleep(for: step)) != nil else { return }
            var partial = room
            partial.walls = Array(room.walls.prefix(count))
            partial.furniture = count >= 2 ? room.furniture : []
            partial.floorOutline = []
            model.update(room: partial)
            model.update(instruction: count == 2 ? .slowDown : .normal)
            let next = room.walls[min(count, room.walls.count - 1)]
            let target = (next.start + next.end) * 0.5
            model.update(labels: ScanSample.labels(afterWalls: count), camera: ScanCameraPose(position: centre, heading: (target - centre).angle))
        }
        guard autoFinish, (try? await Task.sleep(for: step * 2)) != nil else { return }
        model.finish()
    }

    private func complete() async {
        guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
        model?.didFinish(RoomScanResult(room: LayoutGuess.place(in: room)))
    }
}

/// The mockups' living room as a scan would give it: 4.20 × 5.60 m, 2.40 m high, a window in the back wall, a
/// door in the left wall, a sofa facing a television. Walls run in the order the script captures them, the right
/// wall last as in V3OScan.
enum ScanSample {
    static let livingRoom: RoomModel = {
        let corners = [
            PlanPoint(x: 2.1, z: -2.8), PlanPoint(x: -2.1, z: -2.8), PlanPoint(x: -2.1, z: 2.8), PlanPoint(x: 2.1, z: 2.8),
        ]
        var walls = corners.indices.map {
            Wall(id: wallIDs[$0], start: corners[$0], end: corners[($0 + 1) % corners.count], height: 2.4)
        }
        walls[0].openings = [Opening(id: windowID, kind: .window, offset: 2.6, width: 1.2)]
        walls[1].openings = [Opening(id: doorID, kind: .door, offset: 0.9, width: 0.9)]
        let furniture = [
            Furniture(
                id: sofaID, category: .sofa,
                footprint: OrientedRect(centre: PlanPoint(x: 0, z: 1.6), width: 2.1, depth: 0.95, heading: -.pi / 2),
                height: 0.8),
            Furniture(
                category: .television,
                footprint: OrientedRect(centre: PlanPoint(x: 0, z: -2.6), width: 1.2, depth: 0.1, heading: .pi / 2),
                height: 1.1),
        ]
        return RoomModel(source: .scanned, walls: walls, floorOutline: corners, furniture: furniture)
    }()

    static let wallIDs = (1...4).map { UUID(uuidString: "5CA00000-0000-4000-8000-00000000000\($0)")! }
    static let windowID = UUID(uuidString: "5CA00000-0000-4000-8000-000000000011")!
    static let doorID = UUID(uuidString: "5CA00000-0000-4000-8000-000000000012")!
    static let sofaID = UUID(uuidString: "5CA00000-0000-4000-8000-000000000013")!

    /// V3OScan's labels where the mockup puts them (centres of the chips on the 390 × 844 screen), as each thing
    /// would come into view.
    static func labels(afterWalls count: Int) -> [ScanLabel] {
        func at(_ x: Double, _ y: Double) -> UnitPoint { UnitPoint(x: x / 390, y: y / 844) }
        var labels: [ScanLabel] = []
        if count >= 1 {
            labels.append(ScanLabel(id: wallIDs[0], text: ScanText.label(for: .wall(length: 4.2)) ?? "", isMeasurement: true, position: at(192, 139)))
            labels.append(ScanLabel(id: windowID, text: ScanText.label(for: .opening(.window)) ?? "", isMeasurement: false, position: at(194, 288)))
        }
        if count >= 2 {
            labels.append(ScanLabel(id: doorID, text: ScanText.label(for: .opening(.door)) ?? "", isMeasurement: false, position: at(47, 204)))
            labels.append(ScanLabel(id: sofaID, text: ScanText.label(for: .furniture(.sofa)) ?? "", isMeasurement: false, position: at(198, 446)))
        }
        return labels
    }
}
