import Foundation

/// A response's own trend, against which dips and peaks are measured.
enum Trend {
    /// Passes of outlier rejection after the first median.
    static let rejectionPasses = 3

    /// The sliding median of `curve` over `trendWindowOctaves`, centred on each grid point and clipped to the grid,
    /// made robust to broad features: after the first pass, points more than `edgeDecibels` from the trend are left
    /// out of the next median (`rejectionPasses` times), so a dip's own skirts cannot pull the trend down into it.
    /// A window left with no points keeps the previous pass's value.
    static func of(_ curve: [Float], thresholds: DiagnosisThresholds) -> [Float] {
        let half = Int((thresholds.trendWindowOctaves / 2 * ResponseGrid.pointsPerOctave).rounded())
        var included = [Bool](repeating: true, count: curve.count)
        var trend = curve
        for pass in 0...rejectionPasses {
            if pass > 0 {
                for index in curve.indices { included[index] = abs(curve[index] - trend[index]) <= thresholds.edgeDecibels }
            }
            // The window slides one point at a time, so it is kept sorted and updated rather than sorted afresh.
            var window = SortedWindow()
            for point in 0...min(curve.count - 1, half) where included[point] { window.insert(curve[point]) }
            var next = trend
            for index in curve.indices {
                if let middle = window.median { next[index] = middle }
                let entering = index + half + 1
                if entering < curve.count, included[entering] { window.insert(curve[entering]) }
                let leaving = index - half
                if leaving >= 0, included[leaving] { window.remove(curve[leaving]) }
            }
            trend = next
        }
        return trend
    }

    /// `curve` less its trend, in dB: negative in a dip, positive in a peak.
    static func deviation(of curve: [Float], thresholds: DiagnosisThresholds) -> [Float] {
        zip(curve, of(curve, thresholds: thresholds)).map { $0 - $1 }
    }
}

/// A sorted multiset of values with a median.
struct SortedWindow {
    private(set) var values: [Float] = []

    private func position(of value: Float) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    mutating func insert(_ value: Float) { values.insert(value, at: position(of: value)) }

    /// Removes one copy of `value`, which must be present.
    mutating func remove(_ value: Float) { values.remove(at: position(of: value)) }

    var median: Float? {
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        return values.count % 2 == 1 ? values[middle] : (values[middle - 1] + values[middle]) / 2
    }
}

/// A stretch of a grid curve that crossed a threshold.
struct Region: Equatable {
    /// Between the edges: where the curve came back under `edge`, interpolated between grid points.
    var range: FrequencyRange
    /// Where the curve first crossed `threshold`, from below: the start of the deep part.
    var coreLower: Float
    /// The largest value inside, and its frequency.
    var extreme: Float
    var extremeFrequency: Float
    /// Whether the region ran into the end of the assessed span, so its edge there is unknown.
    var touchesLower: Bool
    var touchesUpper: Bool
}

enum RegionFinder {
    /// The regions where `values` (larger is more deviant; nil is not assessed) reach `threshold`, extended out to
    /// where they fall under `edge`, within `span`, at least `minimumOctaves` wide.
    static func regions(
        in values: [Float?],
        span: FrequencyRange,
        threshold: Float,
        edge: Float,
        minimumOctaves: Float
    ) -> [Region] {
        let grid = ResponseGrid.frequencies
        precondition(values.count == grid.count, "values must be on ResponseGrid")
        func value(_ index: Int) -> Float? {
            guard grid.indices.contains(index), span.contains(grid[index]) else { return nil }
            return values[index]
        }
        /// The frequency between grid points `outside` and `inside` where the curve crosses `level`.
        func crossing(outside: Int, inside: Int, level: Float) -> Float {
            guard let a = value(outside), let b = value(inside), b != a else { return grid[inside] }
            let t = min(max((level - a) / (b - a), 0), 1)
            return grid[outside] * pow(grid[inside] / grid[outside], t)
        }

        var found: [(first: Int, last: Int, region: Region)] = []
        var index = 0
        while index < grid.count {
            guard let v = value(index), v >= threshold else { index += 1; continue }
            var coreEnd = index
            while let next = value(coreEnd + 1), next >= threshold { coreEnd += 1 }
            var first = index
            while let previous = value(first - 1), previous >= edge { first -= 1 }
            var last = coreEnd
            while let next = value(last + 1), next >= edge { last += 1 }

            let touchesLower = value(first - 1) == nil
            let touchesUpper = value(last + 1) == nil
            let lower = touchesLower ? grid[first] : crossing(outside: first - 1, inside: first, level: edge)
            let upper = touchesUpper ? grid[last] : crossing(outside: last + 1, inside: last, level: edge)
            let coreLower = value(index - 1) == nil ? grid[index] : crossing(outside: index - 1, inside: index, level: threshold)
            let peak = (first...last).max { (value($0) ?? -.infinity) < (value($1) ?? -.infinity) }!
            let region = Region(
                range: FrequencyRange(lower: lower, upper: max(upper, lower)),
                coreLower: coreLower,
                extreme: value(peak)!,
                extremeFrequency: grid[peak],
                touchesLower: touchesLower,
                touchesUpper: touchesUpper
            )
            // Two deep parts within one stretch above `edge` are one region.
            if let previous = found.last, previous.last >= first {
                if region.extreme > previous.region.extreme {
                    found[found.count - 1].region.extreme = region.extreme
                    found[found.count - 1].region.extremeFrequency = region.extremeFrequency
                }
            } else {
                found.append((first, last, region))
            }
            index = last + 1
        }
        return found.map(\.region).filter { $0.range.octaves >= minimumOctaves }
    }
}

/// Regions from several runs that are at the same place.
struct Cluster {
    /// Run index (in the report's runs) → that run's region.
    var members: [Int: Region]

    var runs: Int { members.count }

    /// The median of the members' edges, and the median extreme.
    var range: FrequencyRange {
        let lower = median(members.values.map(\.range.lower))!
        let upper = median(members.values.map(\.range.upper))!
        return FrequencyRange(lower: lower, upper: max(upper, lower))
    }
    var coreLower: Float { median(members.values.map(\.coreLower))! }
    var extreme: Float { median(members.values.map(\.extreme))! }
    var extremeFrequency: Float { median(members.values.map(\.extremeFrequency))! }

    /// Groups the runs' regions: a region joins the first cluster that does not yet hold its run and holds a region
    /// it overlaps within `toleranceOctaves`.
    static func group(_ regions: [Int: [Region]], toleranceOctaves: Float) -> [Cluster] {
        var all: [(run: Int, region: Region)] = []
        for (run, list) in regions {
            for region in list { all.append((run, region)) }
        }
        all.sort { first, second in
            let a = first.region.range.centre
            let b = second.region.range.centre
            return a != b ? a < b : first.run < second.run
        }
        var clusters: [Cluster] = []
        for (run, region) in all {
            if let index = clusters.firstIndex(where: { cluster in
                cluster.members[run] == nil
                    && cluster.members.values.contains { $0.range.overlaps(region.range, toleranceOctaves: toleranceOctaves) }
            }) {
                clusters[index].members[run] = region
            } else {
                clusters.append(Cluster(members: [run: region]))
            }
        }
        return clusters
    }
}
