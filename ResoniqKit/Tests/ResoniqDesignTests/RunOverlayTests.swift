import CoreGraphics
import Testing
@testable import ResoniqDesign

@Suite struct RunOverlayTests {
    static let slack = 1e-3
    static let frame = CGRect(x: 0, y: 0, width: 312, height: 104)

    @Test(arguments: [[], [0.5], [0, 1, 0, 1, 0], [-4, .nan, 9], Array(repeating: 1.0, count: 50)])
    func `a trace stays inside its lane`(levels: [Double]) {
        for lane in 0..<3 {
            let path = RunTraceShape(levels: levels, lane: lane, laneCount: 3, span: 0...1).path(in: Self.frame)
            let box = path.boundingRect
            let laneHeight = Self.frame.height / 3
            #expect(box.minY >= laneHeight * CGFloat(lane) - Self.slack)
            #expect(box.maxY <= laneHeight * CGFloat(lane + 1) + Self.slack)
            #expect(box.minX >= 0 && box.maxX <= Self.frame.width + Self.slack)
        }
    }

    @Test func `a span draws only its part of the width`() {
        let levels = (0..<30).map { Double($0 % 2) }
        let box = RunTraceShape(levels: levels, lane: 0, laneCount: 1, span: 0.25...0.5).path(in: Self.frame).boundingRect
        #expect(abs(box.minX - Self.frame.width * 0.25) < Self.slack)
        #expect(abs(box.maxX - Self.frame.width * 0.5) < Self.slack)
    }

    @Test func `no lane, an empty span or a lane outside the count draws nothing`() {
        #expect(RunTraceShape(levels: [0.5], lane: 0, laneCount: 0, span: 0...1).path(in: Self.frame).isEmpty)
        #expect(RunTraceShape(levels: [0.5], lane: 3, laneCount: 3, span: 0...1).path(in: Self.frame).isEmpty)
        #expect(RunTraceShape(levels: [0.5], lane: 0, laneCount: 3, span: 0.5...0.5).path(in: Self.frame).isEmpty)
    }

    @Test func `level is interpolated between samples`() {
        #expect(RunTraceShape.level(at: 0.5, in: [0, 1, 0]) == 1)
        #expect(abs(RunTraceShape.level(at: 0.25, in: [0, 1, 0]) - 0.5) < 1e-12)
        #expect(RunTraceShape.level(at: 0.3, in: []) == 0.5)
    }
}
