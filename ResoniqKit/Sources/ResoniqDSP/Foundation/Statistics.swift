import Accelerate

/// The module's one median.
enum Statistics {
    /// The middle value of `values`, or the mean of the two middle values for an even count; NaN when empty.
    static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return .nan }
        var sorted = values
        vDSP.sort(&sorted, sortOrder: .ascending)
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
