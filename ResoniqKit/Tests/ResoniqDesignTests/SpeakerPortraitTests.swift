import CoreGraphics
import SwiftUI
import Testing
@testable import ResoniqDesign

@Suite struct SpeakerPortraitTests {
    static let frame = CGRect(x: 10, y: 20, width: 120, height: 430)

    static let profiles: [(name: String, widths: [Double])] = [
        ("empty", []),
        ("single", [0.6]),
        ("pair", [0, 1]),
        ("unknown speaker", SpeakerPortrait.unknownSpeakerWidths),
        ("full width", Array(repeating: 1, count: 40)),
        ("out of range and not a number", [-3, 0.5, 7, .nan, 1, .infinity, -.infinity]),
        ("spiky", (0..<64).map { $0.isMultiple(of: 2) ? 1.0 : 0.0 }),
    ]

    /// Paths keep their points as Float, so allow for that rounding.
    static let slack = 1e-3

    private func boundsHold(_ path: Path) -> Bool {
        guard !path.isEmpty else { return true }
        let box = path.boundingRect
        let slack = Self.slack
        return box.minX >= Self.frame.minX - slack && box.maxX <= Self.frame.maxX + slack
            && box.minY >= Self.frame.minY - slack && box.maxY <= Self.frame.maxY + slack
    }

    @Test(arguments: profiles.map(\.widths))
    func `portrait stays inside its bounds`(widths: [Double]) {
        let path = SpeakerPortraitShape(widths: widths).path(in: Self.frame)
        #expect(boundsHold(path))
    }

    @Test(arguments: profiles.map(\.widths))
    func `portrait is symmetric about its centre line`(widths: [Double]) {
        let path = SpeakerPortraitShape(widths: widths).path(in: Self.frame)
        guard !path.isEmpty else { return }
        let box = path.boundingRect
        // The shape's extent is the same either side of the middle.
        #expect(abs((box.midX) - Self.frame.midX) < Self.slack)
        // Mirroring it about the middle gives the same outline.
        let mirrored = path.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 2 * Self.frame.midX, ty: 0))
        let mirroredBox = mirrored.boundingRect
        #expect(abs(mirroredBox.minX - box.minX) < Self.slack)
        #expect(abs(mirroredBox.maxX - box.maxX) < Self.slack)
    }

    @Test func `empty widths draw nothing and one width draws a column`() {
        #expect(SpeakerPortraitShape(widths: []).path(in: Self.frame).isEmpty)
        let column = SpeakerPortraitShape(widths: [0.5]).path(in: Self.frame).boundingRect
        #expect(abs(column.width - Self.frame.width * 0.5) < Self.slack)
        #expect(abs(column.height - Self.frame.height) < Self.slack)
    }

    @Test func `width follows the widths`() {
        let path = SpeakerPortraitShape(widths: [0, 1, 0]).path(in: Self.frame)
        // Full width at the middle height, none at the ends.
        let middle = CGPoint(x: Self.frame.minX + 1, y: Self.frame.midY)
        #expect(path.contains(middle))
        let nearTop = CGPoint(x: Self.frame.minX + 1, y: Self.frame.minY + 2)
        #expect(!path.contains(nearTop))
    }

    @Test(arguments: profiles.map(\.widths), [0.0...0.2, 0.19...0.26, 0.9...1.0, -1.0...2.0])
    func `deviation patch stays inside the bounds and is symmetric`(widths: [Double], range: ClosedRange<Double>) {
        let path = DeviationBandShape(widths: widths, range: range).path(in: Self.frame)
        #expect(boundsHold(path))
        guard !path.isEmpty else { return }
        let box = path.boundingRect
        #expect(abs(box.midX - Self.frame.midX) < Self.slack)
    }

    @Test func `patch with no width to follow or an empty range is empty`() {
        #expect(DeviationBandShape(widths: [], range: 0.2...0.4).path(in: Self.frame).isEmpty)
        #expect(DeviationBandShape(widths: [1, 1], range: 0.4...0.4).path(in: Self.frame).isEmpty)
    }

    @Test func `half width follows the samples`() {
        let widths = [0.2, 0.8, 0.4]
        #expect(abs(PortraitGeometry.halfWidth(at: 0, widths: widths) - 0.2) < 1e-12)
        #expect(abs(PortraitGeometry.halfWidth(at: 0.5, widths: widths) - 0.8) < 1e-12)
        #expect(abs(PortraitGeometry.halfWidth(at: 1, widths: widths) - 0.4) < 1e-12)
        #expect(PortraitGeometry.halfWidth(at: 0.25, widths: widths) > 0.2)
        #expect(PortraitGeometry.halfWidth(at: 0.25, widths: widths) < 0.8)
        #expect(PortraitGeometry.halfWidth(at: 0.5, widths: []) == 0)
    }

    // MARK: Smoothness

    /// The left edge of the portrait as a polyline, bottom to top, each Bezier piece sampled `perPiece` times.
    private func leftEdge(_ widths: [Double], perPiece: Int = 24) -> [CGPoint] {
        let path = SpeakerPortraitShape(widths: widths).path(in: Self.frame)
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var finished = false
        path.forEach { element in
            guard !finished else { return }
            switch element {
            case .move(let to):
                current = to
                points.append(to)
            case .curve(let to, let control1, let control2):
                for step in 1...perPiece {
                    let t = CGFloat(step) / CGFloat(perPiece)
                    let u = 1 - t
                    points.append(CGPoint(
                        x: u * u * u * current.x + 3 * u * u * t * control1.x + 3 * u * t * t * control2.x + t * t * t * to.x,
                        y: u * u * u * current.y + 3 * u * u * t * control1.y + 3 * u * t * t * control2.y + t * t * t * to.y
                    ))
                }
                current = to
            case .line:
                finished = true
            default:
                break
            }
        }
        return points
    }

    @Test(arguments: [
        [0, 0.5, 0.9, 0.6, 0],
        [0, 0.3, 0.8, 0.8, 0.3, 0],
        [0, 0.9, 0.2, 0.9, 0],
        [0.2, 0.5, 0.7, 0.4, 0.1, 0.0, 0.4, 0.4, 0],
    ] as [[Double]])
    func `a coarse portrait has no abrupt direction change along its edge`(widths: [Double]) {
        let points = leftEdge(widths)
        #expect(points.count > 10)
        var worst = 0.0
        for index in 1..<(points.count - 1) {
            let before = (x: points[index].x - points[index - 1].x, y: points[index].y - points[index - 1].y)
            let after = (x: points[index + 1].x - points[index].x, y: points[index + 1].y - points[index].y)
            let turn = atan2(before.x * after.y - before.y * after.x, before.x * after.x + before.y * after.y)
            worst = max(worst, abs(Double(turn)))
        }
        // 24 samples a piece keep a smooth curve's turn small; a step or a corner turns by a good part of a radian.
        #expect(worst < 0.35, "the sharpest turn is \(worst) radians")
    }

    @Test func `a steady rise is drawn as a straight edge, not as steps`() throws {
        let points = leftEdge([0, 0.2, 0.4, 0.6, 0.8])
        let bottom = Self.frame.maxY
        let height = Self.frame.height
        let half = Self.frame.width / 2
        var checked = 0
        for point in points {
            let along = (bottom - point.y) / height
            // The ends close to a point; between them the edge is the straight rise of 0.2 a quarter.
            guard along > PortraitGeometry.tipSpan * 2, along < 1 - PortraitGeometry.tipSpan * 2 else { continue }
            let expected = Self.frame.midX - half * 0.8 * along
            #expect(abs(point.x - expected) < 0.5, "x \(point.x) should be near \(expected)")
            checked += 1
        }
        #expect(checked > 100)
    }

    @Test(arguments: profiles.map(\.widths).filter { !$0.isEmpty })
    func `the portrait closes to a point at both ends`(widths: [Double]) {
        let path = SpeakerPortraitShape(widths: widths).path(in: Self.frame)
        let tip = Self.frame.height * PortraitGeometry.tipSpan
        // The first and last samples are the points of the outline, on the centre line.
        #expect(abs(PortraitGeometry.drawnHalfWidth(at: 0, widths: widths)) < 1e-12)
        #expect(abs(PortraitGeometry.drawnHalfWidth(at: 1, widths: widths)) < 1e-12)
        // A hair above the bottom point and below the top point the shape is narrow, not the flat end of a rectangle.
        let nearBottom = CGRect(x: Self.frame.minX, y: Self.frame.maxY - 1, width: Self.frame.width, height: 1)
        let nearTop = CGRect(x: Self.frame.minX, y: Self.frame.minY, width: Self.frame.width, height: 1)
        for strip in [nearBottom, nearTop] {
            let corners = [CGPoint(x: strip.minX + 1, y: strip.midY), CGPoint(x: strip.maxX - 1, y: strip.midY)]
            #expect(corners.allSatisfy { !path.contains($0) }, "the corners of the end are empty (tip \(tip) pt)")
        }
    }

    @Test func `the taper leaves the body of the curve alone`() {
        let widths = [0.4, 0.8, 0.6, 0.3, 0.5]
        #expect(PortraitGeometry.taper(at: 0.5) == 1)
        #expect(PortraitGeometry.taper(at: PortraitGeometry.tipSpan) == 1)
        #expect(PortraitGeometry.taper(at: 0) == 0)
        #expect(PortraitGeometry.taper(at: 1) == 0)
        #expect(PortraitGeometry.taper(at: .nan) == 0)
        for fraction in stride(from: 0.1, through: 0.9, by: 0.1) {
            #expect(PortraitGeometry.drawnHalfWidth(at: fraction, widths: widths) == PortraitGeometry.halfWidth(at: fraction, widths: widths))
        }
        // Rising monotonically from the point to the body.
        var previous = 0.0
        for step in 0...20 {
            let value = PortraitGeometry.taper(at: Double(step) / 20 * PortraitGeometry.tipSpan)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test func `the curve passes through every sample and never overshoots`() {
        let widths = [0, 0.5, 0.9, 0.6, 0.0, 0.7, 0.7, 0.2]
        for (index, width) in widths.enumerated() {
            let fraction = Double(index) / Double(widths.count - 1)
            #expect(abs(PortraitGeometry.halfWidth(at: fraction, widths: widths) - width) < 1e-9)
        }
        for step in 0...400 {
            let value = PortraitGeometry.halfWidth(at: Double(step) / 400, widths: widths)
            #expect(value >= 0 && value <= 0.9 + 1e-9)
        }
    }

    @Test func `drawn part excludes the deviations`() {
        let kept = PortraitGeometry.intervals(upTo: 1, excluding: [0.19...0.26])
        #expect(kept == [0...0.19, 0.26...1])
        // Overlapping, unsorted and out-of-range cuts.
        let messy = PortraitGeometry.intervals(upTo: 0.5, excluding: [0.4...0.9, 0.1...0.2, 0.15...0.3, -1...0])
        #expect(messy == [0...0.1, 0.3...0.4])
        #expect(PortraitGeometry.intervals(upTo: 0, excluding: []).isEmpty)
        #expect(PortraitGeometry.intervals(upTo: 0.3, excluding: [0.5...0.6]) == [0...0.3])
    }

    @Test func `default profile is a usable width list`() {
        let widths = SpeakerPortrait.unknownSpeakerWidths
        #expect(widths.count >= 2)
        #expect(widths.allSatisfy { (0...1).contains($0) })
    }
}
