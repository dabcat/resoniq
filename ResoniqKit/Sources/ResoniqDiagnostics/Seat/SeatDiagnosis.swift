import Foundation
import ResoniqDSP

/// Grid curves for the seat: averaging, spread, and reading between grid points.
enum SeatCurve {
    static func response(_ curve: [Float]) -> MagnitudeResponse {
        MagnitudeResponse(frequencies: ResponseGrid.frequencies, decibels: curve)
    }

    static func onGrid(_ response: MagnitudeResponse) -> [Float] {
        ResponseGrid.frequencies.map(response.decibels(at:))
    }

    /// The power average of grid curves (`ResponseAverage.power`), back on the grid.
    static func power(_ curves: [[Float]]) -> [Float] {
        curves.count == 1 ? curves[0] : onGrid(ResponseAverage.power(curves.map(response)))
    }

    /// The spot-to-spot spread of grid curves (`ResponseAverage.spread`), back on the grid.
    static func spread(_ curves: [[Float]]) -> [Float] {
        onGrid(ResponseAverage.spread(curves.map(response)))
    }

    /// The curve at `frequency`, interpolated linearly in log frequency, held at the ends.
    static func value(_ curve: [Float], at frequency: Float) -> Float {
        let position = log2(max(frequency, ResponseGrid.lowerFrequency) / ResponseGrid.lowerFrequency) * ResponseGrid.pointsPerOctave
        let lower = min(max(Int(position.rounded(.down)), 0), ResponseGrid.count - 1)
        let upper = min(lower + 1, ResponseGrid.count - 1)
        let t = min(max(position - Float(lower), 0), 1)
        return curve[lower] + t * (curve[upper] - curve[lower])
    }
}

/// Turns the spots measured around a seat into the seat's result, following the plan's rules:
///
/// - The seat curve is the power average over the valid spots of left and right together, against its own middle
///   level (the median over `SeatThresholds.middleBand`). A peak or dip is reported, with its exact frequency and
///   size, only when it leaves the even band (±`evenBandDecibels`) in that average, between `lowerFrequency` and
///   `upperFrequency`, at points every recording measured with enough signal over the noise. A dip that runs into
///   the bottom of that span is the speakers' roll-off and is not reported.
/// - Bass peaks and dips, the evenness of the rest and the left/right match are `measured`, with their figures.
/// - "It's the room, not the speakers" is `inferred`, and said only with a basis: with a room hint, every bass
///   extreme lies on one of the room's axial modes ("Inferred from room size."); otherwise every bass extreme is
///   narrow and the spots disagree there ("Inferred from how it changes between spots."). Without either it is not
///   said. A hint whose modes miss the extremes is no basis, and the spots are then asked.
/// - Decay is an `estimate` and is given only when the recordings support it; distortion only where measurable.
/// - A result needs `requiredSpots` valid spots; with fewer the report says why, draws the running average, and
///   concludes nothing. A spot that failed is reported only while the result is inconclusive (once it has been
///   measured again it no longer matters).
/// - No score; at most three findings are shown, strongest first.
public enum SeatDiagnosis {
    /// Speed of sound for the room's axial modes, metres per second, at about 20 °C (as `ResoniqRoom` uses).
    static let speedOfSound: Double = 343

    public static func diagnose(spots: [SpotAnalysis], room: RoomHint?, thresholds: SeatThresholds = .standard) -> SeatReport {
        let t = thresholds
        let checks = spots.map { SpotCheck(left: $0.left.check, right: $0.right?.check) }
        let valid = spots.indices.filter { spots[$0].isValid }
        let stereo = !valid.isEmpty && valid.allSatisfy { spots[$0].right != nil }
        let invalid = spots.indices.filter { !spots[$0].isValid }.map { index in
            SeatFinding(
                kind: .invalidSpot, tag: .inconclusive, basis: nil, isDeviation: false,
                headline: SeatText.invalidSpotHeadline(index), tagLine: SeatText.inconclusiveTag,
                detail: SeatText.invalidSpotDetail(spots[index].problems[0]), strength: 0
            )
        }
        func inconclusive(curve: [Float]? = nil, left: [Float]? = nil, right: [Float]? = nil, spotCurves: [[Float]?]? = nil,
                          spread: [Float]? = nil, assessed: [Bool]? = nil) -> SeatReport {
            SeatReport(
                verdict: SeatText.inconclusiveVerdict, isConclusive: false, validSpotCount: valid.count,
                requiredSpotCount: t.requiredSpots, spots: checks, curve: curve, leftCurve: left, rightCurve: right,
                spotCurves: spotCurves ?? spots.map { _ in nil }, spread: spread, assessed: assessed,
                evenBandDecibels: t.evenBandDecibels, extremes: [], leftRightDifference: nil, findings: invalid,
                numbers: [], distortionPercent: nil, bassDecay: nil
            )
        }
        guard !valid.isEmpty else { return inconclusive() }

        // Curves, against the seat's middle level.
        let measurements = valid.flatMap { spots[$0].measurements }
        let grid = ResponseGrid.frequencies
        let assessed = grid.indices.map { index in
            measurements.allSatisfy { $0.isAssessed(atIndex: index, minimumSignalToNoise: t.minimumBandSignalToNoise) }
        }
        let seatRaw = SeatCurve.power(measurements.map(\.response))
        let middleIndices = grid.indices.filter { t.middleBand.contains(grid[$0]) }
        let middle = median(middleIndices.filter { assessed[$0] }.map { seatRaw[$0] })
            ?? median(middleIndices.map { seatRaw[$0] }) ?? 0
        func relative(_ curve: [Float]) -> [Float] { curve.map { $0 - middle } }
        let curve = relative(seatRaw)
        let spotCurves: [[Float]?] = spots.indices.map { index in
            valid.contains(index) ? relative(SeatCurve.power(spots[index].measurements.map(\.response))) : nil
        }
        let left = relative(SeatCurve.power(valid.map { spots[$0].left.measurement!.response }))
        let right = stereo ? relative(SeatCurve.power(valid.map { spots[$0].right!.measurement!.response })) : nil
        let spread = valid.count >= 2 ? SeatCurve.spread(valid.map { spotCurves[$0]! }) : nil
        guard valid.count >= t.requiredSpots else {
            return inconclusive(curve: curve, left: left, right: right, spotCurves: spotCurves, spread: spread, assessed: assessed)
        }
        let spreadCurve = spread ?? [Float](repeating: 0, count: grid.count)

        // Extremes and the left/right match.
        let extremes = findExtremes(curve, assessed: assessed, spread: spreadCurve, thresholds: t)
        let leftRight = right.flatMap { leftRightDifference(left: left, right: $0, assessed: assessed, thresholds: t) }
        let bass = extremes.filter { $0.frequency < t.bassUpperFrequency }
        let rest = extremes.filter { $0.frequency >= t.bassUpperFrequency }
        let voices = rest.contains { $0.frequency < t.trebleLowerFrequency }
        let treble = rest.contains { $0.frequency >= t.trebleLowerFrequency }
        let differ = leftRight.map { $0.difference > t.leftRightDecibels } ?? false

        var deviations: [SeatFinding] = []
        var statements: [SeatFinding] = []
        if !bass.isEmpty {
            let peaks = bass.filter { $0.kind == .peak }
            let dips = bass.filter { $0.kind == .dip }
            let deep = dips.contains { abs($0.deviation) >= t.vanishingDipDecibels }
            deviations.append(SeatFinding(
                kind: .bass, tag: .measured, basis: nil, isDeviation: true,
                headline: SeatText.bassHeadline(peaks: peaks.count, dips: dips.count, deepDip: deep),
                tagLine: SeatText.measuredTag, detail: SeatText.extremesDetail(bass),
                strength: bass.map { abs($0.deviation) }.max()!
            ))
        }
        if rest.isEmpty {
            let merged = leftRight != nil && !differ
            statements.append(SeatFinding(
                kind: .rest, tag: .measured, basis: nil, isDeviation: false,
                headline: SeatText.restEven(leftMatches: merged),
                tagLine: merged ? SeatText.matchTagLine(leftRight!.difference) : SeatText.measuredTag,
                detail: merged ? SeatText.restEvenDetail + " " + SeatText.leftMatchesDetail(leftRight!.difference) : SeatText.restEvenDetail,
                strength: 0
            ))
        } else {
            deviations.append(SeatFinding(
                kind: .rest, tag: .measured, basis: nil, isDeviation: true,
                headline: SeatText.restUneven(voices: voices, treble: treble), tagLine: SeatText.measuredTag,
                detail: SeatText.extremesDetail(rest), strength: rest.map { abs($0.deviation) }.max()!
            ))
        }
        if let leftRight, differ {
            deviations.append(SeatFinding(
                kind: .leftRight, tag: .measured, basis: nil, isDeviation: true,
                headline: SeatText.leftRightDiffer(treble: leftRight.frequency >= t.trebleLowerFrequency),
                tagLine: SeatText.differTagLine(leftRight.difference),
                detail: SeatText.leftRightDetail(rightLouder: leftRight.rightLouder, at: leftRight.frequency),
                strength: leftRight.difference
            ))
        } else if let leftRight, !rest.isEmpty {
            statements.append(SeatFinding(
                kind: .leftRight, tag: .measured, basis: nil, isDeviation: false,
                headline: SeatText.leftMatches, tagLine: SeatText.matchTagLine(leftRight.difference),
                detail: SeatText.leftMatchesDetail(leftRight.difference), strength: 0
            ))
        }
        var findings = deviations.sorted { $0.strength > $1.strength } + statements
        if let basis = cause(bass: bass, room: room, thresholds: t) {
            findings.append(SeatFinding(
                kind: .roomCause, tag: .inferred, basis: basis, isDeviation: false,
                headline: SeatText.causeHeadline, tagLine: SeatText.causeTagLine(basis),
                detail: SeatText.causeDetail(basis, extremes: bass), strength: 0
            ))
        }

        // Figures that need enough recordings behind them.
        let enough = Int((t.minimumFigureShare * Float(measurements.count)).rounded(.up))
        let distortions = measurements.compactMap(\.distortionPercent)
        let distortion = distortions.count >= max(enough, 1) ? median(distortions) : nil
        let decays = measurements.compactMap(\.bassDecay).sorted { $0.seconds < $1.seconds }
        let decay = decays.count >= max(enough, 1) ? decays[(decays.count - 1) / 2] : nil

        var numbers = extremes.map { extreme in
            SeatNumberRow(
                kind: extreme.kind == .peak ? .peak : .dip, label: extreme.frequencyLabel, value: extreme.valueLabel,
                word: extreme.kind == .peak ? SeatText.peakWord : SeatText.dipWord, tag: .measured
            )
        }
        if let leftRight {
            numbers.append(SeatNumberRow(
                kind: .leftRight, label: SeatText.leftRightLabel, value: SeatText.plusMinus(leftRight.difference),
                word: differ ? SeatText.differWord : SeatText.matchWord, tag: .measured
            ))
        }
        if let distortion {
            numbers.append(SeatNumberRow(
                kind: .distortion, label: SeatText.frequency(t.distortionFrequency), value: SeatText.percent(distortion),
                word: SeatText.distortionWord, tag: .measured
            ))
        }
        if let decay {
            numbers.append(SeatNumberRow(
                kind: .decay, label: SeatText.below(decay.upper), value: SeatText.approximately(seconds: decay.seconds),
                word: SeatText.decayWord, tag: .estimate
            ))
        }

        return SeatReport(
            verdict: SeatText.verdict(bassUneven: !bass.isEmpty, voices: voices, treble: treble, leftRightDiffer: differ),
            isConclusive: true, validSpotCount: valid.count, requiredSpotCount: t.requiredSpots, spots: checks,
            curve: curve, leftCurve: left, rightCurve: right, spotCurves: spotCurves, spread: spread, assessed: assessed,
            evenBandDecibels: t.evenBandDecibels, extremes: extremes, leftRightDifference: leftRight?.difference,
            findings: findings, numbers: numbers, distortionPercent: distortion, bassDecay: decay
        )
    }

    // MARK: Steps

    /// The peaks and dips of `curve` (dB against the middle) that leave the even band, rising in frequency.
    static func findExtremes(_ curve: [Float], assessed: [Bool], spread: [Float], thresholds t: SeatThresholds) -> [SeatExtreme] {
        let span = FrequencyRange(lower: t.lowerFrequency, upper: t.upperFrequency)
        func regions(sign: Float) -> [Region] {
            RegionFinder.regions(
                in: curve.indices.map { assessed[$0] ? sign * curve[$0] : nil },
                span: span,
                threshold: t.evenBandDecibels,
                edge: t.evenBandDecibels,
                minimumOctaves: t.minimumExtremeOctaves
            )
        }
        let peaks = regions(sign: 1).map { (SeatExtreme.Kind.peak, $0) }
        let dips = regions(sign: -1).filter { !$0.touchesLower }.map { (SeatExtreme.Kind.dip, $0) }
        return (peaks + dips).map { kind, region in
            let summit = refine(curve, assessed: assessed, near: region.extremeFrequency)
            return SeatExtreme(
                kind: kind, frequency: summit.frequency, deviation: summit.value, range: region.range,
                spread: SeatCurve.value(spread, at: summit.frequency)
            )
        }.sorted { $0.frequency < $1.frequency }
    }

    /// The summit near grid point `frequency`: the vertex of the parabola through it and its neighbours in log
    /// frequency, or the point itself where a neighbour is missing or the three do not bend.
    static func refine(_ curve: [Float], assessed: [Bool], near frequency: Float) -> (frequency: Float, value: Float) {
        let index = ResponseGrid.nearestIndex(to: frequency)
        let point = (ResponseGrid.frequencies[index], curve[index])
        guard index > 0, index < curve.count - 1, assessed[index - 1], assessed[index + 1] else { return point }
        let (a, b, c) = (curve[index - 1], curve[index], curve[index + 1])
        let bend = a - 2 * b + c
        guard bend != 0 else { return point }
        let offset = 0.5 * (a - c) / bend
        guard abs(offset) <= 1 else { return point }
        return (ResponseGrid.frequencies[index] * pow(2, offset / ResponseGrid.pointsPerOctave), b - 0.25 * (a - c) * offset)
    }

    /// The largest |right − left| over `leftRightLowerFrequency` to `upperFrequency` at assessed points: the
    /// difference, where it is, and which side is louder there. Nil when no point is assessed.
    static func leftRightDifference(left: [Float], right: [Float], assessed: [Bool], thresholds t: SeatThresholds)
        -> (difference: Float, frequency: Float, rightLouder: Bool)? {
        let points = ResponseGrid.frequencies.indices.filter { index in
            let frequency = ResponseGrid.frequencies[index]
            return assessed[index] && frequency >= t.leftRightLowerFrequency && frequency <= t.upperFrequency
        }
        guard let worst = points.max(by: { abs(right[$0] - left[$0]) < abs(right[$1] - left[$1]) }) else { return nil }
        let difference = right[worst] - left[worst]
        return (abs(difference), ResponseGrid.frequencies[worst], difference > 0)
    }

    /// The basis on which the bass unevenness can be put down to the room; nil when there is none.
    static func cause(bass: [SeatExtreme], room: RoomHint?, thresholds t: SeatThresholds) -> SeatBasis? {
        guard !bass.isEmpty else { return nil }
        if let room {
            let modes = axialModes(room, upTo: t.roomModeUpperFrequency)
            let onModes = bass.allSatisfy { extreme in
                modes.contains { abs(log2(extreme.frequency / $0)) <= t.roomModeOctaves }
            }
            if !modes.isEmpty, onModes { return .roomSize }
        }
        let changes = bass.allSatisfy { $0.range.octaves <= t.narrowOctaves && $0.spread >= t.spotDisagreementDecibels }
        return changes ? .spotToSpot : nil
    }

    /// The axial modes of the room, hertz: n·c / (2L) for each known dimension, up to `upper`.
    private static func axialModes(_ room: RoomHint, upTo upper: Float) -> [Float] {
        [room.width, room.length, room.height].compactMap { $0 }.filter { $0 > 0 }.flatMap { length in
            let fundamental = Float(speedOfSound / (2 * length))
            return (1...max(Int(upper / fundamental), 1)).map { Float($0) * fundamental }.filter { $0 <= upper }
        }
    }
}
