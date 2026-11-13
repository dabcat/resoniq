import Foundation
import ResoniqDSP

/// Everything the Result and Finding screens show about one speaker.
public struct SpeakerReport: Sendable, Codable, Equatable {
    /// The headline verdict, a sentence: "Sounds healthy, except the woofer may be buzzing."
    public let verdict: String
    /// In display order: unusable runs first, then from the top of the portrait down (highest frequency first).
    public let findings: [Finding]
    /// The finished portrait, from the median of the valid runs; `PortraitProfile.notHeard` when inconclusive.
    public let profile: PortraitProfile
    /// Every run made, in order, valid or not. A finding's `numbers.perRun` is indexed like this.
    public let runs: [RunRecord]
    /// The median of the valid runs' normalised responses (0 dB at each run's own mid level), on `ResponseGrid`;
    /// nil when inconclusive.
    public let consensusResponse: [Float]?
    /// Whether enough runs were valid to conclude anything (`DiagnosisThresholds.minimumValidRuns`).
    public let isConclusive: Bool

    /// The findings that are suspected defects.
    public var suspectedDefects: [Finding] { findings.filter(\.kind.isDeviation) }
}

/// Turns a test's runs into findings, following the plan's rules of evidence:
///
/// - A deviation found in every valid run at the same place is `inferred`, basis "3 of 3 runs", medium confidence
///   (never high from one microphone position). In fewer runs, but at least `minimumAgreeingRuns`, it is
///   `inferred` with low confidence. In one run it is dropped.
/// - A dip above `topEndFrequency` is `inconclusive`: it could be the phone's angle.
/// - A buzz is claimed only where THD is a measurement (`DistortionReading.measured`: clear of the noise floor by
///   the DSP's margin). Where THD reads above `distortionPercent` but not clear of the noise, the finding is
///   `inconclusive` ("too noisy to tell"), never a buzz.
/// - A statement that drivers are even is `measured`, and what it says about distortion covers only the stretch
///   where every run ruled a buzz out; it says nothing about rattle, which a sweep does not measure.
/// - Nothing is read outside a run's `responseBand`, where its response holds the edge value.
/// - An invalid run is reported as such, and nothing is drawn from it; with fewer than `minimumValidRuns` valid
///   runs nothing is concluded at all.
/// - Words hedge, and there is no score.
public enum SpeakerDiagnosis {
    /// - Parameters:
    ///   - runs: This speaker's runs, in the order they were made.
    ///   - counterpart: The other speaker's runs, for a left/right comparison, when it has been tested.
    public static func diagnose(
        runs: [RunAnalysis],
        counterpart: [RunAnalysis]?,
        thresholds: DiagnosisThresholds = .standard
    ) -> SpeakerReport {
        let records = runs.map(\.record)
        let invalid = invalidFindings(records)
        let valid = records.enumerated().compactMap { index, record in record.measurement.map { (index, $0) } }
        guard valid.count >= thresholds.minimumValidRuns else {
            return SpeakerReport(
                verdict: DiagnosisText.inconclusiveVerdict,
                findings: invalid,
                profile: .notHeard,
                runs: records,
                consensusResponse: nil,
                isConclusive: false
            )
        }
        let measurements = Dictionary(uniqueKeysWithValues: valid)
        let compared = valid.count
        let audible = audiblePoints(measurements, thresholds: thresholds)
        let assessed = assessedPoints(measurements, audible: audible)

        var findings: [Finding] = []
        let response = responseClusters(measurements, assessed: assessed, thresholds: thresholds)
        for cluster in response.dips where cluster.runs >= thresholds.minimumAgreeingRuns {
            if cluster.coreLower >= thresholds.topEndFrequency {
                findings.append(topEndFinding(cluster, compared: compared, runCount: records.count, thresholds: thresholds))
            } else {
                findings.append(deviationFinding(.responseDip, cluster, compared: compared, runCount: records.count, thresholds: thresholds))
            }
        }
        for cluster in response.peaks where cluster.runs >= thresholds.minimumAgreeingRuns {
            findings.append(deviationFinding(.responsePeak, cluster, compared: compared, runCount: records.count, thresholds: thresholds))
        }
        let distortion = distortionClusters(measurements, audible: audible, thresholds: thresholds)
        let buzzes = distortion.measured.filter { $0.runs >= thresholds.minimumAgreeingRuns }
        for cluster in buzzes {
            findings.append(deviationFinding(.distortion, cluster, compared: compared, runCount: records.count, thresholds: thresholds))
        }
        // Where THD read above the threshold but did not stand clear of the noise, no buzz is claimed; the report
        // says it could not tell, unless a measured buzz is already at the same place (its noisy skirt).
        for cluster in distortion.belowNoise
        where cluster.runs >= thresholds.minimumAgreeingRuns
            && !buzzes.contains(where: { $0.range.overlaps(cluster.range, toleranceOctaves: thresholds.samePlaceOctaves) }) {
            findings.append(distortionUnclearFinding(cluster, compared: compared, runCount: records.count, thresholds: thresholds))
        }
        if let counterpart {
            let explained = findings.filter { $0.kind == .responseDip || $0.kind == .responsePeak }.compactMap(\.frequencyRange)
            findings += leftRightFindings(
                measurements,
                assessed: assessed,
                counterpart: counterpart.map(\.record),
                explained: explained,
                runCount: records.count,
                thresholds: thresholds
            )
        }
        let clean = distortionRuledOut(measurements, audible: audible, thresholds: thresholds)
        if let even = evenFinding(findings: findings, assessed: assessed, distortionRuledOut: clean, compared: compared, thresholds: thresholds) {
            findings.append(even)
        }

        let ordered = invalid + findings.sorted { ($0.frequencyRange?.centre ?? 0) > ($1.frequencyRange?.centre ?? 0) }
        let consensus = consensusResponse(Array(measurements.values))
        let suspected = ordered.filter(\.kind.isDeviation)
        return SpeakerReport(
            verdict: DiagnosisText.verdict(suspected: suspected),
            findings: ordered,
            profile: PortraitProfile(
                levels: consensus,
                deviations: suspected.compactMap(\.frequencyRange)
            ),
            runs: records,
            consensusResponse: consensus,
            isConclusive: true
        )
    }

    // MARK: Runs

    /// For each grid point, whether every valid run's octave band there had enough signal over the room's noise.
    static func audiblePoints(_ measurements: [Int: RunMeasurement], thresholds: DiagnosisThresholds) -> [Bool] {
        ResponseGrid.frequencies.map { frequency in
            measurements.values.allSatisfy { $0.signalToNoise(at: frequency) >= thresholds.minimumBandSignalToNoise }
        }
    }

    /// For each grid point, whether the response can be read there: audible, and inside every valid run's
    /// `responseBand`. Outside the band a run's response holds its edge value, and nothing is raised from it.
    static func assessedPoints(_ measurements: [Int: RunMeasurement], audible: [Bool]) -> [Bool] {
        ResponseGrid.frequencies.indices.map { index in
            audible[index] && measurements.values.allSatisfy { $0.isResponseMeasured(atIndex: index) }
        }
    }

    /// For each grid point, whether every valid run rules a buzz out there: THD is measured under
    /// `distortionPercent`, or it is below the noise and the noise's bound (`DistortionReading.belowNoise`'s
    /// `upperBoundPercent`) is itself under it.
    static func distortionRuledOut(_ measurements: [Int: RunMeasurement], audible: [Bool], thresholds: DiagnosisThresholds) -> [Bool] {
        ResponseGrid.frequencies.indices.map { index in
            audible[index] && ResponseGrid.frequencies[index] >= thresholds.distortionLowerFrequency
                && measurements.values.allSatisfy { measurement in
                    switch measurement.distortion(atIndex: index) {
                    case .measured(let percent): percent < thresholds.distortionPercent
                    case .belowNoise(_, let bound?): bound < thresholds.distortionPercent
                    case .belowNoise(_, nil), .notRead: false
                    }
                }
        }
    }

    /// The per-point median of the runs' normalised responses, held at the edge value outside the stretch every run
    /// measured (see `PortraitProfile`, "Outside the measured band").
    static func consensusResponse(_ measurements: [RunMeasurement]) -> [Float] {
        let normalised = measurements.map(\.normalizedResponse)
        var consensus = (0..<ResponseGrid.count).map { index in median(normalised.map { $0[index] }) ?? 0 }
        let measured = ResponseGrid.frequencies.indices.filter { index in
            measurements.allSatisfy { $0.isResponseMeasured(atIndex: index) }
        }
        if let first = measured.first, let last = measured.last {
            for index in consensus.indices where index < first { consensus[index] = consensus[first] }
            for index in consensus.indices where index > last { consensus[index] = consensus[last] }
        }
        return consensus
    }

    static func invalidFindings(_ records: [RunRecord]) -> [Finding] {
        RecordingCheck.Problem.allCases.compactMap { problem in
            let count = records.filter { $0.check.problem == problem }.count
            guard count > 0 else { return nil }
            let words = DiagnosisText.invalid(problem, runs: count)
            let basis = Finding.Basis(runsAgreeing: count, runsCompared: records.count)
            return Finding(
                id: "\(Finding.Kind.invalidRecording.rawValue)-\(problem.rawValue)",
                kind: .invalidRecording,
                frequencyRange: nil,
                bands: [],
                tag: .inconclusive,
                basis: basis,
                confidence: nil,
                headline: words.headline,
                detail: words.detail,
                sentence: words.sentence,
                tagLine: DiagnosisText.tagLine(tag: .inconclusive, basis: basis),
                confidenceStatement: DiagnosisText.invalidConfidence,
                repeatability: nil,
                listenFrequency: nil,
                context: nil,
                numbers: nil,
                recordingProblem: problem
            )
        }
    }

    // MARK: Deviations

    static func responseClusters(
        _ measurements: [Int: RunMeasurement],
        assessed: [Bool],
        thresholds: DiagnosisThresholds
    ) -> (dips: [Cluster], peaks: [Cluster]) {
        var dips: [Int: [Region]] = [:]
        var peaks: [Int: [Region]] = [:]
        for (run, measurement) in measurements {
            let deviation = Trend.deviation(of: measurement.response, thresholds: thresholds)
            let below: [Float?] = deviation.indices.map { assessed[$0] ? -deviation[$0] : nil }
            let above: [Float?] = deviation.indices.map { assessed[$0] ? deviation[$0] : nil }
            // A dip that runs into the bottom of the span is the bass rolling off, not a dip: it never comes back.
            dips[run] = RegionFinder.regions(
                in: below,
                span: FrequencyRange(lower: thresholds.responseLowerFrequency, upper: ResponseGrid.upperFrequency),
                threshold: thresholds.deviationDecibels,
                edge: thresholds.edgeDecibels,
                minimumOctaves: thresholds.minimumDeviationOctaves
            ).filter { !$0.touchesLower }.map { region in
                var region = region
                region.extreme = -region.extreme
                return region
            }
            peaks[run] = RegionFinder.regions(
                in: above,
                span: FrequencyRange(lower: thresholds.responseLowerFrequency, upper: thresholds.topEndFrequency),
                threshold: thresholds.deviationDecibels,
                edge: thresholds.edgeDecibels,
                minimumOctaves: thresholds.minimumDeviationOctaves
            )
        }
        return (
            Cluster.group(dips, toleranceOctaves: thresholds.samePlaceOctaves),
            Cluster.group(peaks, toleranceOctaves: thresholds.samePlaceOctaves)
        )
    }

    /// Where THD crosses `distortionPercent`, run by run, grouped across runs: `measured` where THD is a measurement
    /// (`SweepDistortion.isMeasurable`, the only place a buzz may be claimed), `belowNoise` where what was read
    /// crossed it but did not stand clear of the room's noise. Extremes are in per cent.
    static func distortionClusters(
        _ measurements: [Int: RunMeasurement],
        audible: [Bool],
        thresholds: DiagnosisThresholds
    ) -> (measured: [Cluster], belowNoise: [Cluster]) {
        let threshold = Decibels.fromAmplitude(thresholds.distortionPercent / 100)
        func regions(_ values: [Float?]) -> [Region] {
            RegionFinder.regions(
                in: values,
                span: FrequencyRange(lower: thresholds.distortionLowerFrequency, upper: ResponseGrid.upperFrequency),
                threshold: threshold,
                edge: threshold,
                minimumOctaves: thresholds.minimumDistortionOctaves
            ).map { region in
                var region = region
                region.extreme = 100 * Decibels.toAmplitude(region.extreme)
                return region
            }
        }
        var measured: [Int: [Region]] = [:]
        var belowNoise: [Int: [Region]] = [:]
        for (run, measurement) in measurements {
            let readings = measurement.thdDecibels.indices.map { audible[$0] ? measurement.distortion(atIndex: $0) : .notRead }
            measured[run] = regions(readings.indices.map { index in
                if case .measured = readings[index] { return measurement.thdDecibels[index] }
                return nil
            })
            belowNoise[run] = regions(readings.indices.map { index in
                if case .belowNoise = readings[index] { return measurement.thdDecibels[index] }
                return nil
            })
        }
        return (
            Cluster.group(measured, toleranceOctaves: thresholds.samePlaceOctaves),
            Cluster.group(belowNoise, toleranceOctaves: thresholds.samePlaceOctaves)
        )
    }

    static func leftRightFindings(
        _ measurements: [Int: RunMeasurement],
        assessed: [Bool],
        counterpart: [RunRecord],
        explained: [FrequencyRange],
        runCount: Int,
        thresholds: DiagnosisThresholds
    ) -> [Finding] {
        let others = Dictionary(uniqueKeysWithValues: counterpart.enumerated().compactMap { index, record in record.measurement.map { (index, $0) } })
        guard others.count >= thresholds.minimumValidRuns else { return [] }
        let theirs = consensusResponse(Array(others.values))
        let theirAssessed = assessedPoints(others, audible: audiblePoints(others, thresholds: thresholds))
        // A difference the other speaker's own dip or peak explains belongs to that speaker's report.
        let theirDeviations = responseClusters(others, assessed: theirAssessed, thresholds: thresholds)
        let alreadyExplained = explained
            + (theirDeviations.dips + theirDeviations.peaks).filter { $0.runs >= thresholds.minimumAgreeingRuns }.map(\.range)

        var quieter: [Int: [Region]] = [:]
        var louder: [Int: [Region]] = [:]
        for (run, measurement) in measurements {
            let difference = zip(measurement.normalizedResponse, theirs).map { $0 - $1 }
            let usable = difference.indices.map { assessed[$0] && theirAssessed[$0] }
            func regions(sign: Float) -> [Region] {
                RegionFinder.regions(
                    in: difference.indices.map { usable[$0] ? sign * difference[$0] : nil },
                    span: FrequencyRange(lower: thresholds.responseLowerFrequency, upper: thresholds.topEndFrequency),
                    threshold: thresholds.leftRightDecibels,
                    edge: thresholds.edgeDecibels,
                    minimumOctaves: thresholds.minimumDeviationOctaves
                ).map { region in
                    var region = region
                    region.extreme *= sign
                    return region
                }
            }
            quieter[run] = regions(sign: -1)
            louder[run] = regions(sign: 1)
        }
        let clusters = Cluster.group(quieter, toleranceOctaves: thresholds.samePlaceOctaves)
            + Cluster.group(louder, toleranceOctaves: thresholds.samePlaceOctaves)
        return clusters
            .filter { $0.runs >= thresholds.minimumAgreeingRuns }
            .filter { cluster in !alreadyExplained.contains { $0.overlaps(cluster.range) } }
            .map { deviationFinding(.leftRightDifference, $0, compared: measurements.count, runCount: runCount, thresholds: thresholds) }
    }

    // MARK: Building findings

    static func deviationFinding(
        _ kind: Finding.Kind,
        _ cluster: Cluster,
        compared: Int,
        runCount: Int,
        thresholds: DiagnosisThresholds
    ) -> Finding {
        let range = cluster.range
        let basis = Finding.Basis(runsAgreeing: cluster.runs, runsCompared: compared)
        let confidence: Finding.Confidence =
            cluster.runs == compared && cluster.runs >= thresholds.mediumConfidenceRuns ? .medium : .low
        let words: DiagnosisText.Words
        let numbers: Finding.Numbers
        switch kind {
        case .distortion:
            words = DiagnosisText.distortion(range: range, extreme: cluster.extreme, at: cluster.extremeFrequency)
            numbers = Self.numbers(cluster, unit: .percent, threshold: thresholds.distortionPercent, runCount: runCount)
        case .responsePeak:
            words = DiagnosisText.peak(range: range, height: cluster.extreme)
            numbers = Self.numbers(cluster, unit: .decibels, threshold: thresholds.deviationDecibels, runCount: runCount)
        case .leftRightDifference:
            words = DiagnosisText.leftRight(range: range, difference: cluster.extreme)
            numbers = Self.numbers(cluster, unit: .decibels, threshold: thresholds.leftRightDecibels, runCount: runCount)
        default:
            words = DiagnosisText.dip(range: range, depth: cluster.extreme)
            numbers = Self.numbers(cluster, unit: .decibels, threshold: thresholds.deviationDecibels, runCount: runCount)
        }
        return Finding(
            id: identifier(kind, range),
            kind: kind,
            frequencyRange: range,
            bands: [DriverBand(frequency: range.centre)],
            tag: .inferred,
            basis: basis,
            confidence: confidence,
            headline: words.headline,
            detail: words.detail,
            sentence: words.sentence,
            tagLine: DiagnosisText.tagLine(tag: .inferred, basis: basis),
            confidenceStatement: DiagnosisText.confidenceStatement(kind: kind, confidence: confidence, basis: basis),
            repeatability: DiagnosisText.repeatability(basis),
            listenFrequency: DiagnosisText.rounded(range.centre),
            context: range.widened(octaves: 0.85),
            numbers: numbers,
            recordingProblem: nil
        )
    }

    static func topEndFinding(_ cluster: Cluster, compared: Int, runCount: Int, thresholds: DiagnosisThresholds) -> Finding {
        let range = cluster.range
        let basis = Finding.Basis(runsAgreeing: cluster.runs, runsCompared: compared)
        let words = DiagnosisText.topEndDip(range: range)
        return Finding(
            id: identifier(.topEndDip, range),
            kind: .topEndDip,
            frequencyRange: range,
            bands: [.tweeter],
            tag: .inconclusive,
            basis: basis,
            confidence: nil,
            headline: words.headline,
            detail: words.detail,
            sentence: words.sentence,
            tagLine: DiagnosisText.tagLine(tag: .inconclusive, basis: basis),
            confidenceStatement: DiagnosisText.topEndConfidence,
            repeatability: DiagnosisText.repeatability(basis),
            listenFrequency: nil,
            context: range.widened(octaves: 0.85),
            numbers: numbers(cluster, unit: .decibels, threshold: thresholds.deviationDecibels, runCount: runCount),
            recordingProblem: nil
        )
    }

    static func distortionUnclearFinding(_ cluster: Cluster, compared: Int, runCount: Int, thresholds: DiagnosisThresholds) -> Finding {
        let range = cluster.range
        let basis = Finding.Basis(runsAgreeing: cluster.runs, runsCompared: compared)
        let words = DiagnosisText.distortionUnclear(range: range, read: cluster.extreme)
        return Finding(
            id: identifier(.distortionUnclear, range),
            kind: .distortionUnclear,
            frequencyRange: range,
            bands: [DriverBand(frequency: range.centre)],
            tag: .inconclusive,
            basis: basis,
            confidence: nil,
            headline: words.headline,
            detail: words.detail,
            sentence: words.sentence,
            tagLine: DiagnosisText.tagLine(tag: .inconclusive, basis: basis),
            confidenceStatement: DiagnosisText.distortionUnclearConfidence,
            repeatability: DiagnosisText.repeatability(basis),
            listenFrequency: DiagnosisText.rounded(range.centre),
            context: range.widened(octaves: 0.85),
            numbers: numbers(cluster, unit: .percent, threshold: thresholds.distortionPercent, runCount: runCount),
            recordingProblem: nil
        )
    }

    /// The drivers holding no suspected defect's centre, if every point in them could be assessed: measured as even.
    ///
    /// The statement about distortion covers only where a buzz was ruled out in every run (`distortionRuledOut`):
    /// the widest unbroken stretch of such points inside those drivers, no narrower than
    /// `minimumDistortionOctaves`, and it is named in the words. Elsewhere in the drivers nothing is said about
    /// distortion, and nothing at all about rattle, which a sweep does not measure.
    static func evenFinding(
        findings: [Finding],
        assessed: [Bool],
        distortionRuledOut: [Bool],
        compared: Int,
        thresholds: DiagnosisThresholds
    ) -> Finding? {
        let suspected = findings.filter(\.kind.isDeviation).compactMap(\.frequencyRange)
        let unclear = findings.filter { $0.kind == .distortionUnclear }.compactMap(\.frequencyRange)
        let bands = DriverBand.allCases.reversed().filter { band in
            let points = ResponseGrid.frequencies.indices.filter { band.range.contains(ResponseGrid.frequencies[$0]) }
            return points.allSatisfy { assessed[$0] } && !suspected.contains { band.range.contains($0.centre) }
        }
        guard !bands.isEmpty else { return nil }
        let range = FrequencyRange(
            lower: bands.map(\.range.lower).min()!,
            upper: bands.map(\.range.upper).max()!
        )
        let grid = ResponseGrid.frequencies
        var clean: FrequencyRange?
        var start: Int?
        for index in grid.indices {
            let frequency = grid[index]
            let inside = distortionRuledOut[index]
                && bands.contains { $0.range.contains(frequency) }
                && !unclear.contains { $0.contains(frequency) }
            if inside, start == nil { start = index }
            if let first = start, !inside || index == grid.count - 1 {
                let last = inside ? index : index - 1
                let stretch = FrequencyRange(lower: grid[first], upper: grid[last])
                if stretch.octaves >= thresholds.minimumDistortionOctaves, stretch.octaves > (clean?.octaves ?? -1) {
                    clean = stretch
                }
                start = nil
            }
        }
        let basis = Finding.Basis(runsAgreeing: compared, runsCompared: compared)
        let words = DiagnosisText.even(bands: Array(bands), distortionBelow: thresholds.distortionPercent, over: clean)
        return Finding(
            id: identifier(.even, range),
            kind: .even,
            frequencyRange: range,
            bands: Array(bands),
            tag: .measured,
            basis: basis,
            confidence: nil,
            headline: words.headline,
            detail: words.detail,
            sentence: words.sentence,
            tagLine: DiagnosisText.tagLine(tag: .measured, basis: basis),
            confidenceStatement: DiagnosisText.evenConfidence(basis: basis),
            repeatability: nil,
            listenFrequency: nil,
            context: nil,
            numbers: nil,
            recordingProblem: nil
        )
    }

    static func numbers(_ cluster: Cluster, unit: Finding.Numbers.Unit, threshold: Float, runCount: Int) -> Finding.Numbers {
        Finding.Numbers(
            unit: unit,
            extreme: cluster.extreme,
            extremeFrequency: cluster.extremeFrequency,
            perRun: (0..<runCount).map { cluster.members[$0]?.extreme },
            threshold: threshold
        )
    }

    static func identifier(_ kind: Finding.Kind, _ range: FrequencyRange) -> String {
        "\(kind.rawValue)-\(Int(range.lower.rounded()))-\(Int(range.upper.rounded()))"
    }
}
