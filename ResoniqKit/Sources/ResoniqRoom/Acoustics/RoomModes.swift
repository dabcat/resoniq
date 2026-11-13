import Foundation

/// The speed of sound the room models use.
public enum Acoustics {
    /// Metres a second in air at about 20 °C (343.2 m/s; 331.3 · √(1 + 20/273.15)). It changes about 0.6 m/s per
    /// degree, so a cold or warm room moves every predicted frequency by under 2 %.
    public static let speedOfSound = 343.0
}

/// A dimension of the bounding rectangle.
public enum RoomDimension: String, Sendable, Codable, CaseIterable {
    /// Along x.
    case width
    /// Along z.
    case length
    case height
}

/// One axial resonance: a standing wave between two opposite surfaces.
public struct RoomMode: Sendable, Codable, Hashable {
    public var dimension: RoomDimension
    /// 1 for the lowest mode of the dimension.
    public var order: Int
    /// The distance between the two surfaces, metres.
    public var span: Double
    public var frequency: Double

    public init(dimension: RoomDimension, order: Int, span: Double, frequency: Double) {
        self.dimension = dimension
        self.order = order
        self.span = span
        self.frequency = frequency
    }

    /// The mode's relative pressure at a coordinate measured from one of its two surfaces, `cos(nπx/L)`: ±1 at the
    /// surfaces and at the antinodes, 0 at a null.
    public func pressure(atCoordinate coordinate: Double) -> Double {
        cos(Double(order) * .pi * coordinate / span)
    }
}

/// The lowest axial resonances of a room, f = n·c / 2L.
///
/// A simple model. It uses the bounding rectangle only, so an L-shaped or open-plan room is treated as its
/// rectangle; it ignores tangential and oblique modes, furniture, openings, wall construction (a light wall leaks
/// bass) and absorption, which sets how strong and how wide each mode is. Above roughly 200 Hz in a living room the
/// modes overlap and stop being distinct notes, so a match there means little.
public enum RoomModes {
    /// The highest mode returned by default, hertz: about the Schroeder frequency of a living room
    /// (2000·√(T/V) with T ≈ 0.4 s and V ≈ 50–60 m³ is about 170 Hz). A first guess.
    public static let defaultMaximumFrequency = 200.0

    /// The axial modes up to `maximumFrequency`, lowest first; ties keep width, length, height order.
    public static func axial(for room: RoomModel, upTo maximumFrequency: Double = defaultMaximumFrequency)
        -> [RoomMode]
    {
        guard let dimensions = RoomGeometry.dimensions(of: room) else { return [] }
        return axial(dimensions: dimensions, upTo: maximumFrequency)
    }

    public static func axial(dimensions: RoomDimensions, upTo maximumFrequency: Double = defaultMaximumFrequency)
        -> [RoomMode]
    {
        var modes: [RoomMode] = []
        let spans: [(RoomDimension, Double)] = [
            (.width, dimensions.width), (.length, dimensions.length), (.height, dimensions.height),
        ]
        for (dimension, span) in spans where span.isFinite && span > 0 {
            let fundamental = Acoustics.speedOfSound / (2 * span)
            var order = 1
            while Double(order) * fundamental <= maximumFrequency {
                modes.append(
                    RoomMode(dimension: dimension, order: order, span: span, frequency: Double(order) * fundamental))
                order += 1
            }
        }
        let rank: [RoomDimension: Int] = [.width: 0, .length: 1, .height: 2]
        return modes.sorted { ($0.frequency, rank[$0.dimension]!) < ($1.frequency, rank[$1.dimension]!) }
    }

    /// The coordinate of a point along a mode's dimension, measured from the bounding rectangle's low side (or the
    /// floor, for height).
    public static func coordinate(of point: PlanPoint, height: Double, along dimension: RoomDimension,
                                  in bounds: PlanRect) -> Double {
        switch dimension {
        case .width: point.x - bounds.minX
        case .length: point.z - bounds.minZ
        case .height: height
        }
    }
}

/// A surface near a speaker whose reflection cancels the direct sound at one note.
public enum BoundarySurface: String, Sendable, Codable, CaseIterable {
    case wallBehind
    case sideWall
    case floor
}

/// The first cancellation a boundary causes: the reflection arrives half a period late at f = c / 4d.
public struct BoundaryDip: Sendable, Codable, Hashable {
    public var surface: BoundarySurface
    /// From the speaker's position (or its drivers, for the floor) to the surface, metres.
    public var distance: Double
    public var frequency: Double

    public init(surface: BoundarySurface, distance: Double) {
        self.surface = surface
        self.distance = distance
        self.frequency = BoundaryInterference.dipFrequency(distance: distance)
    }
}

/// Speaker-boundary interference: the quarter-wavelength dips from the wall behind a speaker, the nearest side
/// wall and the floor.
///
/// A simple model. It gives only the first and deepest dip of each surface (the next ones are at 3, 5, 7… times
/// it); it treats each surface as a perfect rigid reflector, so absorption, wall construction, openings and
/// furniture in the way are ignored; it assumes the speaker radiates equally all ways, which holds in the bass and
/// fails higher up; and it does not add the three reflections together, so how deep a dip is at the seat is not
/// predicted.
public enum BoundaryInterference {
    public static func dipFrequency(distance: Double) -> Double { Acoustics.speedOfSound / (4 * distance) }

    /// The dips for a speaker in a room: the wall behind it, the nearest wall that is not that one and runs across
    /// it, and the floor. A surface the model cannot find (no wall behind, a speaker on the floor) is left out.
    public static func dipFrequencies(for speaker: PlacedSpeaker, in room: RoomModel) -> [BoundaryDip] {
        dipFrequencies(position: speaker.position, facing: speaker.facing, driverHeight: speaker.driverHeight, in: room)
    }

    static func dipFrequencies(position: PlanPoint, facing: Double, driverHeight: Double, in room: RoomModel)
        -> [BoundaryDip]
    {
        var dips: [BoundaryDip] = []
        let behind = RoomGeometry.wallBehind(position: position, facing: facing, in: room)
        if let behind, behind.distance > 0 { dips.append(BoundaryDip(surface: .wallBehind, distance: behind.distance)) }
        if let side = sideWallDistance(position: position, behindIndex: behind?.wallIndex, in: room), side > 0 {
            dips.append(BoundaryDip(surface: .sideWall, distance: side))
        }
        if driverHeight > 0 { dips.append(BoundaryDip(surface: .floor, distance: driverHeight)) }
        return dips
    }

    /// Two walls whose directions differ by more than this run across each other; nearer to parallel, one is a
    /// continuation or the opposite wall.
    static let crossingWallCosine = cos(Double.pi / 4)

    static func sideWallDistance(position: PlanPoint, behindIndex: Int?, in room: RoomModel) -> Double? {
        let behindDirection = behindIndex.map { room.walls[$0].direction }
        return room.walls.enumerated().compactMap { index, wall -> Double? in
            if index == behindIndex { return nil }
            if let behindDirection, abs(wall.direction.dot(behindDirection)) > crossingWallCosine { return nil }
            return Planar.distance(from: position, toSegment: wall.start, wall.end)
        }.min()
    }
}
