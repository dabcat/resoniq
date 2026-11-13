import CoreGraphics
import Foundation
import Testing
@testable import ResoniqDesign

@Suite struct RoomPlanGeometryTests {
    private let room = CGRect(x: 0, y: 0, width: 4.2, height: 5.6)
    private let frame = CGSize(width: 340, height: 322)

    private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1e-6) -> Bool { abs(a - b) <= tolerance }

    // MARK: Fit

    @Test func `a room is fitted at one scale, centred, inside the padding`() {
        let fit = PlanFit.fit(bounds: room, in: frame, padding: 20)
        // Height is the tight side: (322 - 40) / 5.6 points per metre.
        #expect(close(fit.scale, 282 / 5.6))
        let topLeft = fit.point(CGPoint(x: 0, y: 0))
        let bottomRight = fit.point(CGPoint(x: 4.2, y: 5.6))
        #expect(close(topLeft.y, 20))
        #expect(close(bottomRight.y, 302))
        // Centred across the width, with the same space left and right.
        #expect(close(topLeft.x, frame.width - bottomRight.x))
        #expect(topLeft.x >= 20)
    }

    @Test func `a wide room is limited by its width`() {
        let fit = PlanFit.fit(bounds: CGRect(x: 0, y: 0, width: 10, height: 2), in: frame, padding: 20)
        #expect(close(fit.scale, 300 / 10))
        #expect(close(fit.point(CGPoint(x: 0, y: 0)).x, 20))
    }

    @Test func `metres and points round trip`() {
        let fit = PlanFit.fit(bounds: room, in: frame, padding: 20)
        for metres in [CGPoint(x: 0, y: 0), CGPoint(x: 1.234, y: 4.321), CGPoint(x: 4.2, y: 5.6), CGPoint(x: -1, y: 9)] {
            let back = fit.metres(fit.point(metres))
            #expect(close(back.x, metres.x, 1e-9))
            #expect(close(back.y, metres.y, 1e-9))
        }
        #expect(close(fit.length(2), 2 * fit.scale))
    }

    @Test func `a room with one wall or one point still fits`() {
        let oneWall = RoomPlanContent(walls: [.init(x1: 0, y1: 0, x2: 3, y2: 0)])
        let bounds = RoomPlanGeometry.bounds(of: oneWall)
        #expect(bounds == CGRect(x: 0, y: 0, width: 3, height: 0))
        let fit = PlanFit.fit(bounds: bounds, in: frame, padding: 20)
        #expect(fit.scale.isFinite && fit.scale > 0)
        let line = [fit.point(CGPoint(x: 0, y: 0)), fit.point(CGPoint(x: 3, y: 0))]
        #expect(line.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        #expect(close(line[0].y, frame.height / 2))

        let point = PlanFit.fit(bounds: CGRect(x: 2, y: 2, width: 0, height: 0), in: frame, padding: 20)
        #expect(point.scale.isFinite && point.scale > 0)
    }

    @Test func `no content, no frame and non finite sizes give a finite fit`() {
        let broken = CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1)
        let cases: [(bounds: CGRect?, size: CGSize)] = [
            (nil, frame), (nil, CGSize.zero), (room, CGSize.zero), (room, CGSize(width: CGFloat.nan, height: CGFloat.infinity)),
            (broken, frame), (room, CGSize(width: 30, height: 30)),
        ]
        for (bounds, size) in cases {
            let fit = PlanFit.fit(bounds: bounds, in: size, padding: 20)
            let mapped = fit.point(CGPoint(x: 1, y: 1))
            #expect(fit.scale.isFinite && fit.scale > 0)
            #expect(mapped.x.isFinite && mapped.y.isFinite)
        }
    }

    @Test func `bounds ignore non finite numbers and cover every kind of item`() {
        var content = RoomPlanContent(
            walls: [.init(x1: 0, y1: 0, x2: 4, y2: 0), .init(x1: CGFloat.nan, y1: 0, x2: 99, y2: 99)],
            speakers: [.init(id: "l", position: CGPoint(x: CGFloat.infinity, y: 1), label: "Left")],
            measuredSpots: [CGPoint(x: 1, y: 3)]
        )
        #expect(RoomPlanGeometry.bounds(of: content) == CGRect(x: 0, y: 0, width: 4, height: 3))
        content.suggestions = [.init(speakerID: "l", target: CGPoint(x: 6, y: -1))]
        #expect(RoomPlanGeometry.bounds(of: content) == CGRect(x: 0, y: -1, width: 6, height: 4))
        #expect(RoomPlanGeometry.bounds(of: RoomPlanContent()) == nil)
    }

    // MARK: Hit testing

    @Test func `a small item still answers within 44 points`() {
        let target = RoomPlanGeometry.Target(id: "seat", kind: .item, centre: CGPoint(x: 100, y: 100), halfSide: 4)
        #expect(RoomPlanGeometry.hit(at: CGPoint(x: 100, y: 100), targets: [target]) == target)
        #expect(RoomPlanGeometry.hit(at: CGPoint(x: 121, y: 79), targets: [target]) == target)
        #expect(RoomPlanGeometry.hit(at: CGPoint(x: 123, y: 100), targets: [target]) == nil)
        #expect(RoomPlanGeometry.hit(at: CGPoint(x: 100, y: 123), targets: [target]) == nil)
    }

    @Test func `a larger item answers over its whole drawn size`() {
        let target = RoomPlanGeometry.Target(id: "big", kind: .item, centre: .zero, halfSide: 40)
        #expect(RoomPlanGeometry.hit(at: CGPoint(x: 39, y: -39), targets: [target]) != nil)
        #expect(RoomPlanGeometry.hit(at: CGPoint(x: 41, y: 0), targets: [target]) == nil)
    }

    @Test func `the nearest centre wins and a handle wins over an item`() {
        let left = RoomPlanGeometry.Target(id: "left", kind: .item, centre: CGPoint(x: 0, y: 0), halfSide: 12)
        let right = RoomPlanGeometry.Target(id: "right", kind: .item, centre: CGPoint(x: 30, y: 0), halfSide: 12)
        #expect(RoomPlanGeometry.hit(at: CGPoint(x: 10, y: 0), targets: [left, right])?.id == "left")
        #expect(RoomPlanGeometry.hit(at: CGPoint(x: 20, y: 0), targets: [left, right])?.id == "right")
        let handle = RoomPlanGeometry.Target(id: "left", kind: .rotateHandle, centre: CGPoint(x: 20, y: 0), halfSide: 8)
        #expect(RoomPlanGeometry.hit(at: CGPoint(x: 10, y: 0), targets: [left, right, handle])?.kind == .rotateHandle)
        #expect(RoomPlanGeometry.hit(at: CGPoint(x: CGFloat.nan, y: 0), targets: [left]) == nil)
        #expect(RoomPlanGeometry.hit(at: .zero, targets: []) == nil)
    }

    // MARK: Hatching

    @Test func `hatching lines stay inside a square`() {
        let square = [CGPoint(x: 0, y: 0), CGPoint(x: 70, y: 0), CGPoint(x: 70, y: 70), CGPoint(x: 0, y: 70)]
        let lines = RoomPlanGeometry.hatchLines(in: square, spacing: 7, angle: 45)
        #expect(lines.count > 12)
        for (from, to) in lines {
            for point in [from, to] {
                #expect(point.x >= -1e-6 && point.x <= 70 + 1e-6)
                #expect(point.y >= -1e-6 && point.y <= 70 + 1e-6)
            }
            // At 45 degrees, equal steps in x and y.
            #expect(close(abs(to.x - from.x), abs(to.y - from.y), 1e-6))
        }
    }

    @Test func `hatching a circle leaves its outside alone`() {
        let polygon = RoomPlanGeometry.ellipsePolygon(centre: CGPoint(x: 100, y: 100), radii: CGSize(width: 40, height: 40))
        let lines = RoomPlanGeometry.hatchLines(in: polygon, spacing: 7, angle: 45)
        #expect(!lines.isEmpty)
        for (from, to) in lines {
            for point in [from, to] {
                #expect(hypot(point.x - 100, point.y - 100) <= 40 + 1e-6)
            }
        }
    }

    @Test func `hatching a concave polygon skips the notch`() {
        // A U shape: the notch between x 30 and 60, from y 0 to 50.
        let u = [
            CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0), CGPoint(x: 30, y: 50), CGPoint(x: 60, y: 50),
            CGPoint(x: 60, y: 0), CGPoint(x: 90, y: 0), CGPoint(x: 90, y: 80), CGPoint(x: 0, y: 80),
        ]
        let lines = RoomPlanGeometry.hatchLines(in: u, spacing: 10, angle: 0)
        for (from, to) in lines {
            let y = from.y
            if y < 50 {
                // Above the base the line is in two pieces, none crossing the notch.
                #expect(to.x <= 30 + 1e-6 || from.x >= 60 - 1e-6)
            }
        }
        #expect(lines.contains { $0.0.y < 50 && $0.0.x <= 1e-6 && abs($0.1.x - 30) < 1e-6 })
    }

    @Test func `hatching is empty for degenerate input`() {
        let triangle = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)]
        #expect(RoomPlanGeometry.hatchLines(in: [], spacing: 7, angle: 45).isEmpty)
        #expect(RoomPlanGeometry.hatchLines(in: Array(triangle.prefix(2)), spacing: 7, angle: 45).isEmpty)
        #expect(RoomPlanGeometry.hatchLines(in: triangle, spacing: 0, angle: 45).isEmpty)
        #expect(RoomPlanGeometry.hatchLines(in: triangle, spacing: CGFloat.nan, angle: 45).isEmpty)
        #expect(RoomPlanGeometry.hatchLines(in: triangle + [CGPoint(x: CGFloat.nan, y: 3)], spacing: 7, angle: 45).isEmpty)
        // A polygon of no area gives nothing visible.
        let flat = [CGPoint(x: 0, y: 5), CGPoint(x: 10, y: 5), CGPoint(x: 20, y: 5)]
        #expect(RoomPlanGeometry.hatchLines(in: flat, spacing: 5, angle: 0).allSatisfy { $0.0.y.isFinite })
        // So many lines that they would hang the drawing are refused.
        let huge = [CGPoint(x: 0, y: 0), CGPoint(x: 1e6, y: 0), CGPoint(x: 1e6, y: 1e6)]
        #expect(RoomPlanGeometry.hatchLines(in: huge, spacing: 1, angle: 0).isEmpty)
    }

    // MARK: Marching outline

    @Test func `the dash phase moves the dashes two patterns per second and wraps`() {
        let pattern: [CGFloat] = [7, 4]
        #expect(MarchingOutline.dashPhase(at: 0, pattern: pattern) == 0)
        #expect(close(MarchingOutline.dashPhase(at: 0.5, pattern: pattern), -11))
        #expect(close(MarchingOutline.dashPhase(at: 0.25, pattern: pattern), -5.5))
        #expect(MarchingOutline.dashPhase(at: 1, pattern: pattern) == 0)
        #expect(close(MarchingOutline.dashPhase(at: 1.5, pattern: pattern), -11))
        #expect(close(MarchingOutline.dashPhase(at: -0.25, pattern: pattern), -16.5))
    }

    @Test func `the dash phase is zero for patterns and times it cannot use`() {
        #expect(MarchingOutline.dashPhase(at: 0.5, pattern: []) == 0)
        #expect(MarchingOutline.dashPhase(at: 0.5, pattern: [0, 0]) == 0)
        #expect(MarchingOutline.dashPhase(at: CGFloat.nan, pattern: [7, 4]) == 0)
        #expect(MarchingOutline.dashPhase(at: CGFloat.infinity, pattern: [7, 4]) == 0)
    }

    // MARK: Labels

    @Test func `a label that fits goes on its first side`() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let request = RoomPlanGeometry.LabelRequest(
            size: CGSize(width: 40, height: 16), anchor: CGPoint(x: 100, y: 100), sides: [.right, .left], offset: 10, ownObstacle: nil
        )
        let placed = RoomPlanGeometry.place([request], in: frame)
        #expect(placed == [CGRect(x: 110, y: 92, width: 40, height: 16)])
    }

    @Test func `labels stay inside the frame`() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let requests = [
            RoomPlanGeometry.LabelRequest(size: CGSize(width: 60, height: 16), anchor: CGPoint(x: 190, y: 50), sides: [.right], offset: 10, ownObstacle: nil),
            RoomPlanGeometry.LabelRequest(size: CGSize(width: 60, height: 16), anchor: CGPoint(x: 5, y: 2), sides: [.left, .above], offset: 10, ownObstacle: nil),
            RoomPlanGeometry.LabelRequest(size: CGSize(width: 60, height: 16), anchor: CGPoint(x: 100, y: 99), sides: [.below], offset: 10, ownObstacle: nil),
        ]
        for rect in RoomPlanGeometry.place(requests, in: frame) {
            #expect(frame.contains(rect))
        }
    }

    @Test func `a label moves to the next side when the first would meet a wall or a label`() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let wall = (CGPoint(x: 115, y: 0), CGPoint(x: 115, y: 300))
        let first = RoomPlanGeometry.LabelRequest(size: CGSize(width: 40, height: 16), anchor: CGPoint(x: 100, y: 100), sides: [.right, .left], offset: 10, ownObstacle: nil)
        let placed = RoomPlanGeometry.place([first], in: frame, segments: [wall])
        #expect(placed[0].maxX <= 90 + 1e-6)

        let a = RoomPlanGeometry.LabelRequest(size: CGSize(width: 40, height: 16), anchor: CGPoint(x: 100, y: 100), sides: [.right, .below], offset: 10, ownObstacle: nil)
        let both = RoomPlanGeometry.place([a, a], in: frame)
        #expect(!both[0].intersects(both[1]))
    }

    @Test func `a label may touch the thing it names but not others`() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let own = CGRect(x: 90, y: 90, width: 20, height: 20)
        let other = CGRect(x: 110, y: 90, width: 60, height: 20)
        let request = RoomPlanGeometry.LabelRequest(
            size: CGSize(width: 40, height: 16), anchor: CGPoint(x: 100, y: 100), sides: [.centre, .right, .above], offset: 14, ownObstacle: 0
        )
        let placed = RoomPlanGeometry.place([request], in: frame, obstacles: [own, other])
        #expect(placed[0] == CGRect(x: 80, y: 92, width: 40, height: 16).applying(.identity) || !placed[0].intersects(other))
        #expect(!placed[0].intersects(other))
    }

    @Test func `label placement survives degenerate input`() {
        let frame = CGRect(x: 0, y: 0, width: 50, height: 20)
        let big = RoomPlanGeometry.LabelRequest(size: CGSize(width: 400, height: 90), anchor: CGPoint(x: 25, y: 10), sides: [], offset: 5, ownObstacle: nil)
        let nan = RoomPlanGeometry.LabelRequest(size: CGSize(width: CGFloat.nan, height: 10), anchor: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), sides: [.right], offset: CGFloat.nan, ownObstacle: 7)
        let placed = RoomPlanGeometry.place([big, nan], in: frame, obstacles: [], segments: [(CGPoint(x: CGFloat.nan, y: 0), .zero)])
        #expect(placed.count == 2)
        #expect(placed.allSatisfy { $0.origin.x.isFinite && $0.origin.y.isFinite })
        #expect(RoomPlanGeometry.place([], in: frame).isEmpty)
    }

    @Test func `a segment is found inside and across a rectangle but not beside it`() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        #expect(RoomPlanGeometry.segmentIntersects((CGPoint(x: 0, y: 20), CGPoint(x: 40, y: 20)), rect))
        #expect(RoomPlanGeometry.segmentIntersects((CGPoint(x: 15, y: 15), CGPoint(x: 20, y: 20)), rect))
        #expect(!RoomPlanGeometry.segmentIntersects((CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 0)), rect))
        #expect(!RoomPlanGeometry.segmentIntersects((CGPoint(x: 0, y: 40), CGPoint(x: 8, y: 31)), rect))
    }

    // MARK: Angles, shapes, moves

    @Test func `facing zero points up the screen and 90 points right`() {
        let up = RoomPlanGeometry.forward(facing: 0)
        let right = RoomPlanGeometry.forward(facing: 90)
        let down = RoomPlanGeometry.forward(facing: 180)
        #expect(close(up.dx, 0) && close(up.dy, -1))
        #expect(close(right.dx, 1) && close(right.dy, 0))
        #expect(close(down.dx, 0) && close(down.dy, 1))
        #expect(RoomPlanGeometry.facing(from: .zero, to: CGPoint(x: 0, y: -5)) == 0)
        #expect(close(CGFloat(RoomPlanGeometry.facing(from: .zero, to: CGPoint(x: 5, y: 0)) ?? CGFloat.nan), 90))
        #expect(RoomPlanGeometry.facing(from: .zero, to: .zero) == nil)
    }

    @Test func `angles are brought into half a turn each way`() {
        #expect(RoomPlanGeometry.normalised(degrees: 190) == -170)
        #expect(RoomPlanGeometry.normalised(degrees: -190) == 170)
        #expect(RoomPlanGeometry.normalised(degrees: 180) == 180)
        #expect(RoomPlanGeometry.normalised(degrees: -180) == 180)
        #expect(RoomPlanGeometry.normalised(degrees: 725) == 5)
        #expect(RoomPlanGeometry.normalised(degrees: CGFloat.nan) == 0)
    }

    @Test func `a move goes the way the item faces`() {
        // Facing down the screen: forward is down, its left is the screen's right.
        let forward = RoomPlanGeometry.moveVector(.forward, facing: 180, step: 0.1)
        let left = RoomPlanGeometry.moveVector(.left, facing: 180, step: 0.1)
        #expect(close(forward.dx, 0) && close(forward.dy, 0.1))
        #expect(close(left.dx, 0.1) && close(left.dy, 0))
        let back = RoomPlanGeometry.moveVector(.back, facing: 0, step: 0.1)
        let right = RoomPlanGeometry.moveVector(.right, facing: 0, step: 0.1)
        #expect(close(back.dx, 0) && close(back.dy, 0.1))
        #expect(close(right.dx, 0.1) && close(right.dy, 0))
        let broken = RoomPlanGeometry.moveVector(.left, facing: CGFloat.nan, step: CGFloat.nan)
        #expect(broken.dx == 0 && broken.dy == 0)
    }

    @Test func `the open end of a door is a quarter turn from its closed end`() {
        let door = RoomPlanContent.Door(leaf: .init(x1: 0, y1: 4.8, x2: 0, y2: 4.1), swing: .clockwise)
        let tip = RoomPlanGeometry.doorOpenTip(door)
        #expect(close(tip.x, 0.7) && close(tip.y, 4.8))
        let other = RoomPlanGeometry.doorOpenTip(.init(leaf: door.leaf, swing: .counterclockwise))
        #expect(close(other.x, -0.7) && close(other.y, 4.8))
    }

    @Test func `an oriented rectangle has the right corners`() {
        let corners = RoomPlanGeometry.orientedCorners(centre: CGPoint(x: 5, y: 5), size: CGSize(width: 4, height: 2), angle: 0)
        let xs = corners.map(\.x), ys = corners.map(\.y)
        #expect(close(xs.min()!, 3) && close(xs.max()!, 7))
        #expect(close(ys.min()!, 4) && close(ys.max()!, 6))
        let turned = RoomPlanGeometry.orientedCorners(centre: CGPoint(x: 5, y: 5), size: CGSize(width: 4, height: 2), angle: 90)
        #expect(close(turned.map(\.x).min()!, 4) && close(turned.map(\.x).max()!, 6))
        #expect(RoomPlanGeometry.orientedCorners(centre: .zero, size: CGSize(width: CGFloat.nan, height: 1), angle: CGFloat.nan).count == 4)
    }

    @Test func `an arc takes the short way round and stays on its circle`() {
        let points = RoomPlanGeometry.arc(centre: CGPoint(x: 10, y: 10), radius: 20, from: 170, to: -170)
        #expect(points.count == 25)
        for point in points { #expect(close(hypot(point.x - 10, point.y - 10), 20, 1e-6)) }
        // Through the bottom (facing 180), not the top.
        #expect(points.allSatisfy { $0.y > 10 })
        #expect(RoomPlanGeometry.arc(centre: .zero, radius: 0, from: 0, to: 10).isEmpty)
        #expect(RoomPlanGeometry.arc(centre: .zero, radius: CGFloat.nan, from: 0, to: 10).isEmpty)
    }

    @Test func `dimension ticks cross the line at both ends and vanish for no length`() {
        let ticks = RoomPlanGeometry.dimensionTicks(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), length: 12)
        #expect(ticks.count == 2)
        #expect(close(ticks[0].0.x, 0) && close(abs(ticks[0].1.y - ticks[0].0.y), 12))
        #expect(close(ticks[1].0.x, 100))
        #expect(RoomPlanGeometry.dimensionTicks(from: .zero, to: .zero, length: 12).isEmpty)
        #expect(RoomPlanGeometry.dimensionTicks(from: .zero, to: CGPoint(x: CGFloat.nan, y: 0), length: 12).isEmpty)
        let moved = RoomPlanGeometry.offsetLine(from: .zero, to: CGPoint(x: 10, y: 0), by: 5)
        #expect(close(moved.0.y, 5) && close(moved.1.y, 5))
        let same = RoomPlanGeometry.offsetLine(from: .zero, to: .zero, by: 5)
        #expect(same.0 == .zero && same.1 == .zero)
    }

    // MARK: Whole sample

    #if DEBUG
    @Test func `the sample room fits and every point of it lands inside the frame`() {
        let content = RoomPlanContent.sample
        let bounds = try! #require(RoomPlanGeometry.bounds(of: content))
        #expect(bounds == room)
        let fit = PlanFit.fit(bounds: bounds, in: frame, padding: 20)
        for point in content.walls.flatMap({ [$0.a, $0.b] }) + content.measuredSpots + content.speakers.map(\.position) {
            let mapped = fit.point(point)
            #expect(CGRect(origin: .zero, size: frame).contains(mapped))
        }
    }
    #endif
}
