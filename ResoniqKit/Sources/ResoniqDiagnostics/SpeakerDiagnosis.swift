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
/// - A statement that drivers are even and clean is `measured`.
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
        let assessed = assessedPoints(measurements, thresholds: thresholds)

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
        for cluster in distortionClusters(measurements, assessed: assessed, thresholds: thresholds)
        where cluster.runs >= thresholds.minimumAgreeingRuns {
            findings.append(deviationFinding(.distortion, cluster, compared: compared, runCount: records.count, thresholds: thresholds))
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
        if let even = evenFinding(findings: findings, assessed: assessed, compared: compared) {
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

    /// For each grid point, whether every valid run's band there had enough signal over the room's noise.
    static func assessedPoints(_ measurements: [Int: RunMeasurement], thresholds: DiagnosisThresholds) -> [Bool] {
        ResponseGrid.frequencies.map { frequency in
            measurements.values.allSatisfy { $0.signalToNoise(at: frequency) >= thresholds.minimumBandSignalToNoise }
        }
    }

    /// The per-point median of the runs' normalised responses.
    static func consensusResponse(_ measurements: [RunMeasurement]) -> [Float] {
        let normalised = measurements.map(\.normalizedResponse)
        return (0..<ResponseGrid.count).map { index in median(normalised.map { $0[index] }) ?? 0 }
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

    static func distortionClusters(
        _ measurements: [Int: RunMeasurement],
        assessed: [Bool],
        thresholds: DiagnosisThresholds
    ) -> [Cluster] {
        let threshold = Decibels.fromAmplitude(thresholds.distortionPercent / 100)
        var regions: [Int: [Region]] = [:]
        for (run, measurement) in measurements {
            let values: [Float?] = measurement.thdDecibels.indices.map { assessed[$0] ? measurement.thdDecibels[$0] : nil }
            regions[run] = RegionFinder.regions(
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
        return Cluster.group(regions, toleranceOctaves: thresholds.samePlaceOctaves)
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
        let theirAssessed = assessedPoints(others, thresholds: thresholds)
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

    /// The drivers holding no suspected defect's centre, if every point in them could be assessed: measured as even.
    static func evenFinding(findings: [Finding], assessed: [Bool], compared: Int) -> Finding? {
        let suspected = findings.filter(\.kind.isDeviation).compactMap(\.frequencyRange)
        let bands = DriverBand.allCases.reversed().filter { band in
            let points = ResponseGrid.frequencies.indices.filter { band.range.contains(ResponseGrid.frequencies[$0]) }
            return points.allSatisfy { assessed[$0] } && !suspected.contains { band.range.contains($0.centre) }
        }
        guard !bands.isEmpty else { return nil }
        let range = FrequencyRange(
            lower: bands.map(\.range.lower).min()!,
            upper: bands.map(\.range.upper).max()!
        )
        let basis = Finding.Basis(runsAgreeing: compared, runsCompared: compared)
        let words = DiagnosisText.even(bands: Array(bands))
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
