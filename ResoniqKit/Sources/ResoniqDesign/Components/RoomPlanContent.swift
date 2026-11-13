import CoreGraphics

/// What a room plan shows, as plain values in metres on a top-down plane: x to the right, y down the screen.
///
/// The Design module knows nothing of RoomPlan or the Kit's room model; the caller converts. The drawing fits
/// the room into its frame, so the origin and the extent of the numbers do not matter. Non-finite numbers are
/// ignored rather than drawn.
///
/// Angles are in degrees, clockwise as seen on screen, with 0 pointing up the screen. A speaker on the front wall
/// that faces the seat, at the bottom of the plan, has a facing of 180.
public struct RoomPlanContent: Sendable, Equatable {
    /// A straight piece of the plan between two points.
    public struct Segment: Sendable, Equatable {
        public var a: CGPoint
        public var b: CGPoint

        public init(_ a: CGPoint, _ b: CGPoint) {
            self.a = a
            self.b = b
        }

        public init(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) {
            self.init(CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2))
        }
    }

    /// A door: the closed leaf runs from the hinge (`leaf.a`) to the latch (`leaf.b`) along the wall, and the
    /// dashed arc shows where the free end swings.
    public struct Door: Sendable, Equatable {
        public enum Swing: Sendable {
            /// The free end swings clockwise as seen on screen, about the hinge.
            case clockwise
            case counterclockwise
        }

        public var leaf: Segment
        public var swing: Swing

        public init(leaf: Segment, swing: Swing) {
            self.leaf = leaf
            self.swing = swing
        }
    }

    /// An oriented rectangle: a sofa, a table.
    public struct Furniture: Sendable, Equatable, Identifiable {
        public var id: String
        public var centre: CGPoint
        public var size: CGSize
        public var angle: Double
        public var label: String?

        public init(id: String, centre: CGPoint, size: CGSize, angle: Double = 0, label: String? = nil) {
            self.id = id
            self.centre = centre
            self.size = size
            self.angle = angle
            self.label = label
        }
    }

    public struct Speaker: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable {
            /// A filled square.
            case speaker
            /// A filled circle with a ring in it: the driver seen from the front.
            case subwoofer
        }

        public var id: String
        public var position: CGPoint
        /// The direction the speaker faces, in degrees (see the type's note).
        public var facing: Double
        /// "Left", "Right", "Sub".
        public var label: String
        /// The footprint in metres. A glyph is never drawn smaller than a legible minimum.
        public var size: CGSize
        public var kind: Kind

        public init(
            id: String, position: CGPoint, facing: Double = 180, label: String,
            size: CGSize = CGSize(width: 0.3, height: 0.3), kind: Kind = .speaker
        ) {
            self.id = id
            self.position = position
            self.facing = facing
            self.label = label
            self.size = size
            self.kind = kind
        }
    }

    /// The listening seat: a ringed dot.
    public struct Seat: Sendable, Equatable, Identifiable {
        public var id: String
        public var position: CGPoint
        public var label: String

        public init(id: String, position: CGPoint, label: String = "Your seat") {
            self.id = id
            self.position = position
            self.label = label
        }
    }

    /// A measured problem area: hatched in `signal`.
    public struct ProblemArea: Sendable, Equatable, Identifiable {
        public enum Shape: Sendable, Equatable {
            case polygon([CGPoint])
            case ellipse(centre: CGPoint, radii: CGSize)
        }

        public var id: String
        public var shape: Shape
        /// "61 Hz −11 dB".
        public var label: String?

        public init(id: String, shape: Shape, label: String? = nil) {
            self.id = id
            self.shape = shape
            self.label = label
        }
    }

    /// A suggested move: a dashed `guide` outline at the target, a dimension line from where the speaker is now,
    /// and optionally an arc for the turn. It is not yet tested, so it is never drawn in a verified colour.
    public struct Suggestion: Sendable, Equatable, Identifiable {
        public var speakerID: String
        public var target: CGPoint
        /// The facing at the target; when it differs from the speaker's, the turn arc is drawn.
        public var targetFacing: Double?
        /// "35 cm".
        public var distanceLabel: String?
        /// "turn 12°".
        public var turnLabel: String?

        public var id: String { speakerID }

        public init(
            speakerID: String, target: CGPoint, targetFacing: Double? = nil,
            distanceLabel: String? = nil, turnLabel: String? = nil
        ) {
            self.speakerID = speakerID
            self.target = target
            self.targetFacing = targetFacing
            self.distanceLabel = distanceLabel
            self.turnLabel = turnLabel
        }
    }

    public var walls: [Segment]
    public var windows: [Segment]
    public var doors: [Door]
    public var furniture: [Furniture]
    public var speakers: [Speaker]
    public var seats: [Seat]
    public var measuredSpots: [CGPoint]
    public var problemAreas: [ProblemArea]
    public var suggestions: [Suggestion]

    public init(
        walls: [Segment] = [],
        windows: [Segment] = [],
        doors: [Door] = [],
        furniture: [Furniture] = [],
        speakers: [Speaker] = [],
        seats: [Seat] = [],
        measuredSpots: [CGPoint] = [],
        problemAreas: [ProblemArea] = [],
        suggestions: [Suggestion] = []
    ) {
        self.walls = walls
        self.windows = windows
        self.doors = doors
        self.furniture = furniture
        self.speakers = speakers
        self.seats = seats
        self.measuredSpots = measuredSpots
        self.problemAreas = problemAreas
        self.suggestions = suggestions
    }
}

#if DEBUG
public extension RoomPlanContent {
    /// The room of the mockups (4.20 x 5.60 m): a window in the front wall, a door in the left wall, a sofa, two
    /// speakers, the seat, three spots, the bass dip around the seat and one suggestion for the right speaker.
    static let sample = RoomPlanContent(
        walls: [
            Segment(x1: 0, y1: 0, x2: 4.2, y2: 0), Segment(x1: 4.2, y1: 0, x2: 4.2, y2: 5.6),
            Segment(x1: 4.2, y1: 5.6, x2: 0, y2: 5.6), Segment(x1: 0, y1: 5.6, x2: 0, y2: 0),
        ],
        windows: [Segment(x1: 1.4, y1: 0, x2: 2.8, y2: 0)],
        doors: [Door(leaf: Segment(x1: 0, y1: 4.8, x2: 0, y2: 4.1), swing: .clockwise)],
        furniture: [Furniture(id: "sofa", centre: CGPoint(x: 2.1, y: 4.35), size: CGSize(width: 2.0, height: 0.8))],
        speakers: [
            Speaker(id: "left", position: CGPoint(x: 0.8, y: 0.65), label: "Left"),
            Speaker(id: "right", position: CGPoint(x: 3.4, y: 1.0), label: "Right"),
        ],
        seats: [Seat(id: "seat", position: CGPoint(x: 2.1, y: 3.7))],
        measuredSpots: [CGPoint(x: 1.75, y: 3.7), CGPoint(x: 2.1, y: 3.7), CGPoint(x: 2.45, y: 3.7)],
        problemAreas: [
            ProblemArea(id: "dip", shape: .ellipse(centre: CGPoint(x: 2.1, y: 3.7), radii: CGSize(width: 0.8, height: 0.8)), label: "61 Hz \u{2212}11 dB"),
        ],
        suggestions: [
            Suggestion(speakerID: "right", target: CGPoint(x: 3.4, y: 0.65), targetFacing: 192, distanceLabel: "35 cm", turnLabel: "turn 12\u{00B0}"),
        ]
    )

    static let sampleSummary = "Plan of the room from above, 4.20 by 5.60 metres. Three measured spots at the seat sit inside a bass dip of 11 decibels at 61 hertz. A dashed outline, not yet tested, shows where the right speaker should move: 35 centimetres forward."
}
#endif
