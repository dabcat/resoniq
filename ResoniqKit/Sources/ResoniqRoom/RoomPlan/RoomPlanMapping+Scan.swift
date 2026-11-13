import Foundation

/// A whole scan on primitive values: what `RoomPlanConverter` destructures a `CapturedRoom` into, and the rules that
/// turn it into a `RoomModel`. No RoomPlan types, so every rule is tested on the Mac (RoomScan's split between
/// `CapturedRoomAdapter`, which has no logic, and `SurfaceMapping`).
extension RoomPlanMapping {
    /// RoomPlan's confidence in a surface or object. An unknown future value is read as `.low` (RoomScan's rule).
    public enum Confidence: String, Sendable, Codable, CaseIterable {
        case high
        case medium
        case low
    }

    /// A wall, door, window or doorless opening as RoomPlan reports it.
    public struct SurfaceInput: Sendable {
        public enum Kind: Sendable, Equatable {
            case wall
            case door
            case window
            /// A doorless opening (a passage). The model has no such kind; it is kept as a door, the opening that
            /// behaves most like it for sound (a gap in the wall).
            case opening
        }

        public var id: UUID
        /// The wall a door or window sits in, when RoomPlan says.
        public var parentID: UUID?
        public var kind: Kind
        public var confidence: Confidence
        /// 16 numbers, column-major; the translation is the surface's centre.
        public var transform: [Double]
        /// The local x dimension: a wall's length, an opening's width.
        public var width: Double
        /// The local y dimension.
        public var height: Double

        public init(id: UUID, parentID: UUID? = nil, kind: Kind, confidence: Confidence, transform: [Double],
                    width: Double, height: Double) {
            self.id = id
            self.parentID = parentID
            self.kind = kind
            self.confidence = confidence
            self.transform = transform
            self.width = width
            self.height = height
        }
    }

    /// A piece of furniture or a fixture as RoomPlan reports it.
    public struct ObjectInput: Sendable {
        public var id: UUID
        /// RoomPlan's category case name (`"sofa"`); see `category(named:)`.
        public var categoryName: String
        public var confidence: Confidence
        public var transform: [Double]
        public var width: Double
        public var height: Double
        public var depth: Double

        public init(id: UUID, categoryName: String, confidence: Confidence, transform: [Double], width: Double,
                    height: Double, depth: Double) {
            self.id = id
            self.categoryName = categoryName
            self.confidence = confidence
            self.transform = transform
            self.width = width
            self.height = height
            self.depth = depth
        }
    }

    /// A floor surface: its polygon in its own plane and its transform.
    public struct FloorInput: Sendable {
        public var corners: [(x: Double, y: Double, z: Double)]
        public var transform: [Double]

        public init(corners: [(x: Double, y: Double, z: Double)], transform: [Double]) {
            self.corners = corners
            self.transform = transform
        }
    }

    /// Something the scan reported that the model does not hold, and why.
    public struct Dropped: Sendable, Hashable {
        public enum Reason: String, Sendable, Codable {
            /// A non-finite value, a zero-length wall, a transform without a usable axis.
            case invalidGeometry
            /// A door or window when the scan has no wall to put it on.
            case noWall
        }

        public var id: UUID
        public var reason: Reason

        public init(id: UUID, reason: Reason) {
            self.id = id
            self.reason = reason
        }
    }

    /// The room built from a scan, and what the model could not say about it.
    ///
    /// `RoomModel` has no confidence field, so items RoomPlan reported with low confidence are kept in the room and
    /// named in `lowConfidence` for whoever wants to show or store the doubt.
    public struct Conversion: Sendable, Equatable {
        public var room: RoomModel
        public var lowConfidence: Set<UUID>
        public var dropped: [Dropped]

        public init(room: RoomModel, lowConfidence: Set<UUID> = [], dropped: [Dropped] = []) {
            self.room = room
            self.lowConfidence = lowConfidence
            self.dropped = dropped
        }
    }

    /// The model of a scan, without guessing speakers or seat (`RoomPlanConverter` adds `LayoutGuess` to a
    /// finished scan).
    ///
    /// - Walls: a segment along the local x axis through the centre, `width` long, with the y dimension as height.
    /// - Doors, windows and doorless openings: on their parent wall, or the nearest wall when the parent is missing
    ///   or not among the walls; dropped when there is no wall.
    /// - Objects: a footprint per object, the category by name (`.other` for what the model does not keep).
    /// - Floor: the outline of the largest floor polygon with at least three corners, through its transform.
    ///
    /// Not kept, because the model has no place for it: confidence (see `Conversion.lowConfidence`), whether a door
    /// is open, a wall's thickness and curve (a curved wall becomes its straight chord), opening heights and sill
    /// heights, object attributes and storage subtypes, stories and sections.
    public static func assemble(
        walls: [SurfaceInput], openings: [SurfaceInput] = [], objects: [ObjectInput] = [], floors: [FloorInput] = []
    ) -> Conversion {
        var dropped: [Dropped] = []
        var lowConfidence = Set<UUID>()
        func note(_ id: UUID, _ confidence: Confidence) { if confidence == .low { lowConfidence.insert(id) } }

        var builtWalls: [Wall] = []
        for input in walls {
            guard input.transform.count == 16,
                let built = Self.wall(id: input.id, transform: input.transform, width: input.width, height: input.height)
            else {
                dropped.append(Dropped(id: input.id, reason: .invalidGeometry))
                continue
            }
            builtWalls.append(built)
            note(input.id, input.confidence)
        }

        for input in openings {
            guard input.transform.count == 16, centre(of: input.transform).isFinite else {
                dropped.append(Dropped(id: input.id, reason: .invalidGeometry))
                continue
            }
            guard let index = wallIndex(for: input, in: builtWalls) else {
                dropped.append(Dropped(id: input.id, reason: .noWall))
                continue
            }
            let kind: Opening.Kind = input.kind == .window ? .window : .door
            guard
                let built = Self.opening(
                    id: input.id, kind: kind, transform: input.transform, width: input.width, on: builtWalls[index])
            else {
                dropped.append(Dropped(id: input.id, reason: .invalidGeometry))
                continue
            }
            builtWalls[index].openings.append(built)
            note(input.id, input.confidence)
        }

        var furniture: [Furniture] = []
        for input in objects {
            guard input.transform.count == 16,
                let item = Self.furniture(
                    id: input.id, categoryName: input.categoryName, transform: input.transform, width: input.width,
                    height: input.height, depth: input.depth)
            else {
                dropped.append(Dropped(id: input.id, reason: .invalidGeometry))
                continue
            }
            furniture.append(item)
            note(input.id, input.confidence)
        }

        let outline = floors.filter { $0.transform.count == 16 }
            .map { floorOutline(corners: $0.corners, transform: $0.transform) }
            .filter { $0.count >= 3 }
            .max { area(of: $0) < area(of: $1) } ?? []

        let room = RoomModel(source: .scanned, walls: builtWalls, floorOutline: outline, furniture: furniture)
        return Conversion(room: room, lowConfidence: lowConfidence, dropped: dropped)
    }

    /// Where the labels over the camera go: each wall's centre (with its length), each door and window's centre,
    /// and the top of each object the model keeps a category for. Positions are in ARKit's world, metres.
    public static func markers(walls: [SurfaceInput], openings: [SurfaceInput], objects: [ObjectInput])
        -> [ScanMarker]
    {
        var markers: [ScanMarker] = []
        for input in walls where input.width.isFinite && input.width > 0 {
            if let position = Self.position(of: input.transform) {
                markers.append(ScanMarker(id: input.id, kind: .wall(length: input.width), position: position))
            }
        }
        for input in openings {
            if let position = Self.position(of: input.transform) {
                let kind: Opening.Kind = input.kind == .window ? .window : .door
                markers.append(ScanMarker(id: input.id, kind: .opening(kind), position: position))
            }
        }
        for input in objects {
            let category = Self.category(named: input.categoryName)
            guard category != .other, input.height.isFinite, var position = Self.position(of: input.transform) else {
                continue
            }
            position.y += input.height / 2
            markers.append(ScanMarker(id: input.id, kind: .furniture(category), position: position))
        }
        return markers
    }

    // MARK: Helpers

    static func wallIndex(for opening: SurfaceInput, in walls: [Wall]) -> Int? {
        if let parent = opening.parentID, let index = walls.firstIndex(where: { $0.id == parent }) { return index }
        let point = centre(of: opening.transform)
        return walls.indices.min {
            Planar.distance(from: point, toSegment: walls[$0].start, walls[$0].end)
                < Planar.distance(from: point, toSegment: walls[$1].start, walls[$1].end)
        }
    }

    static func position(of transform: [Double]) -> ScanMarker.Position? {
        guard transform.count == 16 else { return nil }
        let position = ScanMarker.Position(x: transform[12], y: transform[13], z: transform[14])
        return position.x.isFinite && position.y.isFinite && position.z.isFinite ? position : nil
    }

    static func area(of polygon: [PlanPoint]) -> Double {
        abs(Planar.edges(of: polygon).reduce(0) { $0 + $1.0.cross($1.1) }) / 2
    }
}

/// A thing found in the scan that gets a label over the camera (V3OScan "Window", "Sofa", "4.20 m").
public struct ScanMarker: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case wall(length: Double)
        case opening(Opening.Kind)
        case furniture(Furniture.Category)
    }

    /// A point in ARKit's world, metres, y up.
    public struct Position: Sendable, Equatable {
        public var x: Double
        public var y: Double
        public var z: Double

        public init(x: Double, y: Double, z: Double) {
            self.x = x
            self.y = y
            self.z = z
        }
    }

    public var id: UUID
    public var kind: Kind
    public var position: Position

    public init(id: UUID, kind: Kind, position: Position) {
        self.id = id
        self.kind = kind
        self.position = position
    }
}
