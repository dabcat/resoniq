import CoreGraphics
import Testing
@testable import ResoniqDesign

@Suite struct RunOverlayTests {
    static let slack = 1e-3
    static let frame = CGRect(x: 0, y: 0, width: 312, height: 104)

    @Test(arguments: [[], [0.5], [0, 1, 0, 1, 0], [-4, .nan, 9], [0.2, nil, 0.8], Array(repeating: 1.0, count: 50)] as [[Double?]])
    func `a trace stays inside its lane`(levels: [Double?]) {
        for lane in 0..<3 {
            let path = RunTraceShape(levels: levels, lane: lane, laneCount: 3, span: 0...1).path(in: Self.frame)
            guard !path.isEmpty else { continue }
            let box = path.boundingRect
            let laneHeight = Self.frame.height / 3
            #expect(box.minY >= laneHeight * CGFloat(lane) - Self.slack)
            #expect(box.maxY <= laneHeight * CGFloat(lane + 1) + Self.slack)
            #expect(box.minX >= 0 && box.maxX <= Self.frame.width + Self.slack)
        }
    }

    @Test func `a span draws only its part of the width`() {
        let levels: [Double?] = (0..<30).map { Double($0 % 2) }
        let box = RunTraceShape(levels: levels, lane: 0, laneCount: 1, span: 0.25...0.5).path(in: Self.frame).boundingRect
        #expect(abs(box.minX - Self.frame.width * 0.25) < Self.slack)
        #expect(abs(box.maxX - Self.frame.width * 0.5) < Self.slack)
    }

    @Test func `no lane, an empty span or a lane outside the count draws nothing`() {
        #expect(RunTraceShape(levels: [0.5], lane: 0, laneCount: 0, span: 0...1).path(in: Self.frame).isEmpty)
        #expect(RunTraceShape(levels: [0.5], lane: 3, laneCount: 3, span: 0...1).path(in: Self.frame).isEmpty)
        #expect(RunTraceShape(levels: [0.5], lane: 0, laneCount: 3, span: 0.5...0.5).path(in: Self.frame).isEmpty)
    }

    @Test func `level is interpolated between samples`() throws {
        #expect(RunTraceShape.level(at: 0.5, in: [0, 1, 0]) == 1)
        #expect(abs(try #require(RunTraceShape.level(at: 0.25, in: [0, 1, 0])) - 0.5) < 1e-12)
        #expect(RunTraceShape.level(at: 0.3, in: []) == nil)
    }

    @Test func `a gap is not drawn through`() {
        // Five samples at 0, 0.25 ... 1; the middle one was not measured.
        let levels: [Double?] = [0.2, 0.8, nil, 0.8, 0.2]
        #expect(RunTraceShape.level(at: 0.5, in: levels) == nil)
        #expect(RunTraceShape.level(at: 0.4, in: levels) == nil)
        #expect(RunTraceShape.level(at: 0.25, in: levels) == 0.8)
        #expect(RunTraceShape.level(at: 0.1, in: levels) != nil)
        let gap = RunTraceShape(levels: levels, lane: 0, laneCount: 1, span: 0.3...0.7).path(in: Self.frame)
        #expect(gap.isEmpty)
        let ends = RunTraceShape(levels: levels, lane: 0, laneCount: 1, span: 0...1).path(in: Self.frame).boundingRect
        #expect(abs(ends.minX) < Self.slack && abs(ends.maxX - Self.frame.width) < Self.slack)
    }

    @Test func `a trace with nothing measured draws nothing`() {
        #expect(RunTraceShape(levels: [nil, nil, nil], lane: 0, laneCount: 1, span: 0...1).path(in: Self.frame).isEmpty)
    }
}
