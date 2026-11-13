import Foundation

/// A room and what is in it, as plain values: the one model every screen, the store and the advisor share.
///
/// Conventions, ported from RoomScan (docs/reference/iosar-roomplan-arkit.md, "Coordinate and unit conventions"):
/// metres and radians; the plan is the x–z plane with y up; the floor is at y = 0; angles are plan angles
/// (`PlanAngle`). The model holds no RoomPlan or ARKit types, so it is `Codable` and tested on the Mac; the RoomPlan
/// converter is a thin mapping onto `RoomPlanMapping`.
public struct RoomModel: Sendable, Codable, Equatable {
    /// The version of this encoding. Readers accept missing optional fields added later.
    public static let currentSchemaVersion = 1

    /// The ceiling height assumed when no wall states one, metres. A first guess: a common ceiling.
    public static let defaultHeight = 2.4

    public var schemaVersion: Int
    public var source: RoomSource
    public var walls: [Wall]
    /// The floor's outline in order around the room, without repeating the first point. Empty when the scan gave
    /// no floor polygon; the walls then stand in for it (`RoomGeometry.outline(of:)`).
    public var floorOutline: [PlanPoint]
    public var furniture: [Furniture]
    public var speakers: [PlacedSpeaker]
    public var seats: [Seat]

    public init(
        source: RoomSource,
        walls: [Wall],
        floorOutline: [PlanPoint] = [],
        furniture: [Furniture] = [],
        speakers: [PlacedSpeaker] = [],
        seats: [Seat] = [],
        schemaVersion: Int = RoomModel.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.source = source
        self.walls = walls
        self.floorOutline = floorOutline
        self.furniture = furniture
        self.speakers = speakers
        self.seats = seats
    }

    public func speaker(_ id: UUID) -> PlacedSpeaker? { speakers.first { $0.id == id } }
    public func seat(_ id: UUID) -> Seat? { seats.first { $0.id == id } }

    /// The first speaker with a role, if any.
    public func speaker(role: SpeakerRole) -> PlacedSpeaker? { speakers.first { $0.role == role } }

    /// The seat the advisor works for: the first confirmed seat, else the first seat.
    public var primarySeat: Seat? { seats.first(where: \.isConfirmed) ?? seats.first }
}

/// Where a room model came from.
public enum RoomSource: String, Sendable, Codable, CaseIterable {
    /// From a RoomPlan scan.
    case scanned
    /// Entered by hand (`ManualRoom`), for devices without LiDAR.
    case manual
}

/// A straight wall: a segment on the plan with a height and its doors and windows.
public struct Wall: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var start: PlanPoint
    public var end: PlanPoint
    public var height: Double
    public var openings: [Opening]

    public init(id: UUID = UUID(), start: PlanPoint, end: PlanPoint, height: Double, openings: [Opening] = []) {
        self.id = id
        self.start = start
        self.end = end
        self.height = height
        self.openings = openings
    }

    public var length: Double { start.distance(to: end) }

    /// The unit vector from `start` to `end`.
    public var direction: PlanPoint { (end - start).normalized }
}

/// A door or window in a wall.
public struct Opening: Sendable, Codable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case door
        case window
    }

    public var id: UUID
    public var kind: Kind
    /// The distance from the wall's `start` to the opening's centre, along the wall, metres.
    public var offset: Double
    /// The opening's width along the wall, metres.
    public var width: Double

    public init(id: UUID = UUID(), kind: Kind, offset: Double, width: Double) {
        self.id = id
        self.kind = kind
        self.offset = offset
        self.width = width
    }
}

/// A piece of furniture RoomPlan found, or that a person drew.
public struct Furniture: Sendable, Codable, Equatable, Identifiable {
    public enum Category: String, Sendable, Codable, CaseIterable {
        case sofa
        case chair
        case table
        case storage
        case television
        case bed
        case other
    }

    public var id: UUID
    public var category: Category
    public var footprint: OrientedRect
    /// The height of the top above the floor, when known.
    public var height: Double?

    public init(id: UUID = UUID(), category: Category, footprint: OrientedRect, height: Double? = nil) {
        self.id = id
        self.category = category
        self.footprint = footprint
        self.height = height
    }
}

/// What a speaker plays in the system.
public enum SpeakerRole: String, Sendable, Codable, CaseIterable {
    case left
    case right
    /// One speaker on its own (mono, a smart speaker).
    case single
    case subwoofer
}

/// A loudspeaker on the plan. RoomPlan does not recognise loudspeakers, so a scanned room's speakers start as
/// `LayoutGuess` guesses with `isConfirmed == false` until a person confirms them.
public struct PlacedSpeaker: Sendable, Codable, Equatable, Identifiable {
    /// Footprint of a main speaker when nothing better is known, metres: a large bookshelf or a slim floorstander.
    /// A first guess.
    public static let defaultSize = FootprintSize(width: 0.25, depth: 0.30)
    /// Footprint of a subwoofer when nothing better is known, metres. A first guess.
    public static let defaultSubwooferSize = FootprintSize(width: 0.35, depth: 0.35)
    /// Height of the drivers above the floor when nothing better is known, metres: a speaker on a stand or a
    /// floorstander's woofer and tweeter averaged. A first guess.
    public static let defaultDriverHeight = 0.9
    /// Height of a subwoofer's driver above the floor when nothing better is known, metres. A first guess.
    public static let defaultSubwooferDriverHeight = 0.2

    public var id: UUID
    public var role: SpeakerRole
    /// The centre of the footprint. Acoustic distances are measured from here (the baffle's few centimetres of
    /// offset are ignored).
    public var position: PlanPoint
    /// The plan angle the front faces.
    public var facing: Double
    public var size: FootprintSize
    /// The drivers' height above the floor, metres.
    public var driverHeight: Double
    public var isConfirmed: Bool

    public init(
        id: UUID = UUID(),
        role: SpeakerRole,
        position: PlanPoint,
        facing: Double,
        size: FootprintSize? = nil,
        driverHeight: Double? = nil,
        isConfirmed: Bool
    ) {
        self.id = id
        self.role = role
        self.position = position
        self.facing = facing
        self.size = size ?? (role == .subwoofer ? Self.defaultSubwooferSize : Self.defaultSize)
        self.driverHeight = driverHeight ?? (role == .subwoofer ? Self.defaultSubwooferDriverHeight : Self.defaultDriverHeight)
        self.isConfirmed = isConfirmed
    }

    public var footprint: OrientedRect {
        OrientedRect(centre: position, width: size.width, depth: size.depth, heading: facing)
    }

    public var pose: PlanPose { PlanPose(position: position, facing: facing) }
}

/// The width (across the front) and depth of a footprint, metres.
public struct FootprintSize: Sendable, Codable, Hashable {
    public var width: Double
    public var depth: Double

    public init(width: Double, depth: Double) {
        self.width = width
        self.depth = depth
    }
}

/// A listening position: where the listener's head is on the plan.
public struct Seat: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var position: PlanPoint
    public var isConfirmed: Bool

    public init(id: UUID = UUID(), position: PlanPoint, isConfirmed: Bool) {
        self.id = id
        self.position = position
        self.isConfirmed = isConfirmed
    }
}
