import Foundation

/// A rectangular room entered by hand, for devices without LiDAR.
///
/// The rectangle is centred on the origin: `width` runs along x and `length` along z, so the walls sit at
/// x = ±width/2 and z = ±length/2. That matches the room-anchored frame RoomScan gives a scan (origin at the floor's
/// centre), so a manual room and a scanned one are drawn the same way.
public struct ManualRoom: Sendable, Equatable {
    /// The shortest side accepted, metres. Below this it is a cupboard, or the number was typed in feet. A first guess.
    public static let minimumSide = 1.5
    /// The longest side accepted, metres. A first guess: a large open-plan room.
    public static let maximumSide = 20.0
    /// The lowest ceiling accepted, metres. A first guess.
    public static let minimumHeight = 1.8
    /// The highest ceiling accepted, metres. A first guess: a double-height room.
    public static let maximumHeight = 6.0

    /// Why a hand-entered room cannot be used.
    public enum Issue: Sendable, Equatable, Hashable {
        case widthOutOfRange
        case lengthOutOfRange
        case heightOutOfRange
    }

    public var width: Double
    public var length: Double
    public var height: Double

    public init(width: Double, length: Double, height: Double = RoomModel.defaultHeight) {
        self.width = width
        self.length = length
        self.height = height
    }

    /// Every value outside its plausible range; empty when the room can be used. Non-finite values are out of range.
    public var issues: [Issue] {
        var found: [Issue] = []
        if !Self.isSide(width) { found.append(.widthOutOfRange) }
        if !Self.isSide(length) { found.append(.lengthOutOfRange) }
        if !(height.isFinite && height >= Self.minimumHeight && height <= Self.maximumHeight) {
            found.append(.heightOutOfRange)
        }
        return found
    }

    public var isValid: Bool { issues.isEmpty }

    /// The room as a model with four walls, the floor outline and nothing in it; nil when `issues` is not empty.
    ///
    /// Wall order runs around the room starting with the wall at z = −length/2: back (−z), right (+x), front (+z),
    /// left (−x).
    public func model() -> RoomModel? {
        guard isValid else { return nil }
        let hw = width / 2, hl = length / 2
        let corners = [
            PlanPoint(x: -hw, z: -hl), PlanPoint(x: hw, z: -hl), PlanPoint(x: hw, z: hl), PlanPoint(x: -hw, z: hl),
        ]
        let walls = corners.indices.map { i in
            Wall(start: corners[i], end: corners[(i + 1) % corners.count], height: height)
        }
        return RoomModel(source: .manual, walls: walls, floorOutline: corners)
    }

    private static func isSide(_ value: Double) -> Bool {
        value.isFinite && value >= minimumSide && value <= maximumSide
    }
}
