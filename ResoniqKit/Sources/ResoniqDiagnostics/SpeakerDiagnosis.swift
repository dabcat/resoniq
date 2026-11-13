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
    /// Lines a model added (`ModelAdvice`): at most one from the defect classifier and one from the anomaly check,
    /// each `inferred` with low confidence. They are not deviations and never change the verdict or a finding above.
    /// Nil when no model said anything, which is always the case while no model ships; optional, so reports stored
    /// before it still decode.
    public internal(set) var modelFindings: [ModelFinding]? = nil
    /// The runs (1-based, rising) in which the phone moved while the sweep played: they were kept, not failed. From
    /// the phone's motion sensor, so `measured`; nil when none moved. Optional, so reports stored before it decode, and
    /// a reopened report says it as the live one did (`phoneMovedNote`).
    public internal(set) var phoneMovedRuns: [Int]? = nil

    /// "The phone moved while run 2 played. I kept that run, so read its details with a little care."; nil when no
    /// run moved.
    public var phoneMovedNote: String? { phoneMovedRuns.flatMap(DiagnosisText.phoneMovedNote(runs:)) }

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
/// - Sound tied to the sweep (`RunRecord.sweepTiedSound`, the session's observation) at the same place in at least
///   `minimumAgreeingRuns` valid runs is a possible rattle, `inferred` with the runs as its basis; in one run it is
///   dropped. Over a measured buzz it is not a second finding but the buzz's second piece of evidence
///   (`Finding.sweepTied`). Either way the drivers it overlaps are left out of the even statement.
/// - Nothing is read outside a run's `responseBand`, where its response holds the edge value.
/// - An invalid run is reported as such, and nothing is drawn from it; with fewer than `minimumValidRuns` valid
///   runs nothing is concluded at all.
/// - Words hedge, and there is no score.
public enum SpeakerDiagnosis {
    /// - Parameters:
    ///   - runs: This speaker's runs, in the order they were made.
    ///   - counterpart: The other speaker's runs, for a left/right comparison, when it has been tested.
    ///   - phoneMovedRuns: The runs (1-based) in which the phone moved while the sweep played (the session's
    ///     `RunRecording.phoneMoved`); kept on the report as `phoneMovedRuns`, changing nothing else.
    public static func diagnose(
        runs: [RunAnalysis],
        counterpart: [RunAnalysis]?,
        phoneMovedRuns: [Int] = [],
        thresholds: DiagnosisThresholds = .standard
    ) -> SpeakerReport {
        var report = diagnosis(runs: runs, counterpart: counterpart, thresholds: thresholds)
        let moved = Array(Set(phoneMovedRuns)).sorted()
        report.phoneMovedRuns = moved.isEmpty ? nil : moved
        return report
    }

    private static func diagnosis(
        runs: [RunAnalysis],
        counterpart: [RunAnalysis]?,
        thresholds: DiagnosisThresholds
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

        // A driver far quieter than the rest is a finding; one too close to the room's noise is unchecked. With
        // nothing assessed at all, nothing is concluded.
        let quiet = quietBandFindings(measurements, compared: compared, runCount: records.count, thresholds: thresholds)
        let quietRanges = quiet.compactMap(\.frequencyRange)
        let unchecked = notAssessedFindings(assessed: assessed, excluding: quiet.compactMap(\.band), compared: compared, thresholds: thresholds)
        let anyAssessed = ResponseGrid.frequencies.indices.contains { index in
            assessed[index] && (thresholds.responseLowerFrequency...thresholds.topEndFrequency).contains(ResponseGrid.frequencies[index])
        }
        guard anyAssessed || !quiet.isEmpty else {
            return SpeakerReport(
                verdict: DiagnosisText.notAssessedVerdict,
                findings: invalid + unchecked,
                profile: .notHeard,
                runs: records,
                consensusResponse: nil,
                isConclusive: false
            )
        }

        var findings: [Finding] = quiet + unchecked
        let response = responseClusters(measurements, assessed: assessed, thresholds: thresholds)
        // A dip inside a driver that could barely be heard is that driver, already reported.
        for cluster in response.dips where cluster.runs >= thresholds.minimumAgreeingRuns
            && !quietRanges.contains(where: { $0.contains(cluster.range.centre) }) {
            if cluster.coreLower >= thresholds.topEndFrequency {
                findings.append(topEndFinding(cluster, compared: compared, runCount: records.count, thresholds: thresholds))
            } else {
                findings.append(deviationFinding(.responseDip, cluster, compared: compared, runCount: records.count, thresholds: thresholds))
            }
        }
        for cluster in response.peaks where cluster.runs >= thresholds.minimumAgreeingRuns {
            findings.append(deviationFinding(.responsePeak, cluster, compared: compared, runCount: records.count, thresholds: thresholds))
        }
        // Nor is distortion read in a driver that could barely be heard: what was there is noise.
        let distortion = distortionClusters(measurements, audible: audible, thresholds: thresholds)
        func inQuietBand(_ cluster: Cluster) -> Bool { quietRanges.contains { $0.contains(cluster.range.centre) } }
        let buzzes = distortion.measured.filter { $0.runs >= thresholds.minimumAgreeingRuns && !inQuietBand($0) }
        // Sound tied to the sweep where it recurs: over a measured buzz it is that buzz's second piece of evidence,
        // so the two never contradict each other; elsewhere it is a possible rattle.
        let tied = sweepTiedClusters(records, valid: Set(measurements.keys), thresholds: thresholds)
        for cluster in buzzes {
            let alsoHeard = tied.first { $0.range.overlaps(cluster.range) }
            findings.append(deviationFinding(
                .distortion, cluster, compared: compared, runCount: records.count, thresholds: thresholds, sweepTied: alsoHeard
            ))
        }
        for cluster in tied where !buzzes.contains(where: { $0.range.overlaps(cluster.range) }) {
            findings.append(rattleFinding(cluster, compared: compared, thresholds: thresholds))
        }
        // Where THD read above the threshold but did not stand clear of the noise, no buzz is claimed; the report
        // says it could not tell, unless a measured buzz is already at the same place (its noisy skirt).
        for cluster in distortion.belowNoise
        where cluster.runs >= thresholds.minimumAgreeingRuns && !inQuietBand(cluster)
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
        let consensus = consensusResponse(Array(measurements.values))
        if let even = evenFinding(
            findings: findings, consensus: consensus, assessed: assessed, distortionRuledOut: clean, compared: compared, thresholds: thresholds
        ) {
            findings.append(even)
        }

        let ordered = invalid + findings.sorted { ($0.frequencyRange?.centre ?? 0) > ($1.frequencyRange?.centre ?? 0) }
        let suspected = ordered.filter(\.kind.isDeviation)
        let uncheckedBands = unchecked.compactMap(\.band)
        return SpeakerReport(
            verdict: DiagnosisText.verdict(
                suspected: suspected,
                unchecked: uncheckedBands,
                checked: DriverBand.allCases.reversed().filter { !uncheckedBands.contains($0) }
            ),
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
                recordingProblem: problem,
                interference: records.first { $0.check.problem == problem && $0.interference != nil }?.interference
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

    /// Where valid runs heard sound tied to the sweep (`RunRecord.sweepTiedSound`), grouped across runs as deviations
    /// are, kept only where at least `minimumAgreeingRuns` runs agree: in one run it is dropped, like any deviation
    /// seen once. An invalid run's observation does not count.
    static func sweepTiedClusters(_ records: [RunRecord], valid: Set<Int>, thresholds: DiagnosisThresholds) -> [Cluster] {
        var regions: [Int: [Region]] = [:]
        for (index, record) in records.enumerated() where valid.contains(index) {
            guard let range = record.sweepTiedSound?.range else { continue }
            regions[index] = [Region(
                range: range, coreLower: range.lower, extreme: 0, extremeFrequency: range.centre,
                touchesLower: false, touchesUpper: false
            )]
        }
        return Cluster.group(regions, toleranceOctaves: thresholds.samePlaceOctaves)
            .filter { $0.runs >= thresholds.minimumAgreeingRuns }
    }

    /// A possible rattle: `inferred`, with the runs it rests on and a confidence statement that names the room or
    /// something near the speaker vibrating. Nothing was measured, so it carries no numbers.
    static func rattleFinding(_ cluster: Cluster, compared: Int, thresholds: DiagnosisThresholds) -> Finding {
        let range = cluster.range
        let basis = Finding.Basis(runsAgreeing: cluster.runs, runsCompared: compared)
        let confidence: Finding.Confidence =
            cluster.runs == compared && cluster.runs >= thresholds.mediumConfidenceRuns ? .medium : .low
        let words = DiagnosisText.rattle(range: range)
        return Finding(
            id: identifier(.rattle, range),
            kind: .rattle,
            frequencyRange: range,
            bands: [DriverBand(frequency: range.centre)],
            tag: .inferred,
            basis: basis,
            confidence: confidence,
            headline: words.headline,
            detail: words.detail,
            sentence: words.sentence,
            tagLine: DiagnosisText.tagLine(tag: .inferred, basis: basis),
            confidenceStatement: DiagnosisText.rattleConfidence(confidence, basis: basis),
            repeatability: DiagnosisText.repeatability(basis),
            listenFrequency: DiagnosisText.rounded(range.centre),
            context: range.widened(octaves: 0.85),
            numbers: nil,
            recordingProblem: nil
        )
    }

    static func deviationFinding(
        _ kind: Finding.Kind,
        _ cluster: Cluster,
        compared: Int,
        runCount: Int,
        thresholds: DiagnosisThresholds,
        sweepTied: Cluster? = nil
    ) -> Finding {
        let range = cluster.range
        let basis = Finding.Basis(runsAgreeing: cluster.runs, runsCompared: compared)
        let confidence: Finding.Confidence =
            cluster.runs == compared && cluster.runs >= thresholds.mediumConfidenceRuns ? .medium : .low
        var words: DiagnosisText.Words
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
        let evidence = sweepTied.map { tied in
            let heard = Finding.Basis(runsAgreeing: tied.runs, runsCompared: compared)
            return Finding.SweepTiedEvidence(
                range: tied.range, runsHeard: tied.runs, runsCompared: compared, statement: DiagnosisText.sweepTiedAlso(heard)
            )
        }
        if let evidence { words.detail += " " + evidence.statement }
        var finding = Finding(
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
        finding.sweepTied = evidence
        return finding
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

    // MARK: Drivers that could not be heard

    /// Where a driver's level is read for `quietBandFindings`: the woofer from `quietBandLowerFrequency` to 300 Hz,
    /// the middle driver from 300 Hz to 3 kHz, the tweeter from 3 kHz to `topEndFrequency`.
    static func levelRange(_ band: DriverBand, thresholds: DiagnosisThresholds) -> FrequencyRange {
        switch band {
        case .woofer: FrequencyRange(lower: thresholds.quietBandLowerFrequency, upper: DriverBand.wooferUpperFrequency)
        case .middle: band.range
        case .tweeter: FrequencyRange(lower: DriverBand.tweeterLowerFrequency, upper: thresholds.topEndFrequency)
        }
    }

    /// Where a driver's response is judged: the woofer from `responseLowerFrequency`, the tweeter up to
    /// `topEndFrequency`, the middle driver over its range.
    static func judgedRange(_ band: DriverBand, thresholds: DiagnosisThresholds) -> FrequencyRange {
        switch band {
        case .woofer: FrequencyRange(lower: thresholds.responseLowerFrequency, upper: DriverBand.wooferUpperFrequency)
        case .middle: band.range
        case .tweeter: FrequencyRange(lower: DriverBand.tweeterLowerFrequency, upper: thresholds.topEndFrequency)
        }
    }

    /// The drivers whose median level over `levelRange` is at least `quietBandDecibels` under the loudest other
    /// driver's, in at least `minimumAgreeingRuns` runs: `measured` (the difference is read from the recordings),
    /// with the cause left open. The level is read whether or not the band is audible over the noise: a driver that
    /// plays nothing leaves a level far under the others, which is the finding.
    static func quietBandFindings(_ measurements: [Int: RunMeasurement], compared: Int, runCount: Int, thresholds: DiagnosisThresholds) -> [Finding] {
        let grid = ResponseGrid.frequencies
        var differences: [DriverBand: [Int: Float]] = [:]
        for (run, measurement) in measurements {
            let normalised = measurement.normalizedResponse
            var levels: [DriverBand: Float] = [:]
            for band in DriverBand.allCases {
                let range = levelRange(band, thresholds: thresholds)
                let values = grid.indices.filter { range.contains(grid[$0]) && measurement.isResponseMeasured(atIndex: $0) }.map { normalised[$0] }
                levels[band] = median(values)
            }
            for band in DriverBand.allCases {
                guard let level = levels[band], let loudest = levels.filter({ $0.key != band }).values.max() else { continue }
                let difference = level - loudest
                if difference <= -thresholds.quietBandDecibels { differences[band, default: [:]][run] = difference }
            }
        }
        return DriverBand.allCases.reversed().compactMap { band in
            guard let perRun = differences[band], perRun.count >= thresholds.minimumAgreeingRuns else { return nil }
            let range = levelRange(band, thresholds: thresholds)
            let difference = median(Array(perRun.values))!
            let basis = Finding.Basis(runsAgreeing: perRun.count, runsCompared: compared)
            let words = DiagnosisText.quietBand(band, range: range, difference: difference)
            return Finding(
                id: identifier(.quietBand, range),
                kind: .quietBand,
                frequencyRange: range,
                bands: [band],
                tag: .measured,
                basis: basis,
                confidence: nil,
                headline: words.headline,
                detail: words.detail,
                sentence: words.sentence,
                tagLine: DiagnosisText.tagLine(tag: .measured, basis: basis),
                confidenceStatement: DiagnosisText.quietBandConfidence(basis: basis),
                repeatability: DiagnosisText.repeatability(basis),
                listenFrequency: DiagnosisText.rounded(range.centre),
                context: range.widened(octaves: 0.85),
                numbers: Finding.Numbers(
                    unit: .decibels,
                    extreme: difference,
                    extremeFrequency: range.centre,
                    perRun: (0..<runCount).map { perRun[$0] },
                    threshold: thresholds.quietBandDecibels
                ),
                recordingProblem: nil
            )
        }
    }

    /// The drivers (other than `excluding`) with points in their `judgedRange` that could not be assessed (too little
    /// signal over the room's noise in some run): `inconclusive`, naming the stretch.
    static func notAssessedFindings(assessed: [Bool], excluding: [DriverBand], compared: Int, thresholds: DiagnosisThresholds) -> [Finding] {
        let grid = ResponseGrid.frequencies
        return DriverBand.allCases.reversed().filter { !excluding.contains($0) }.compactMap { band in
            let range = judgedRange(band, thresholds: thresholds)
            let missing = grid.indices.filter { range.contains(grid[$0]) && !assessed[$0] }
            guard let first = missing.first, let last = missing.last else { return nil }
            let stretch = FrequencyRange(lower: grid[first], upper: grid[last])
            let basis = Finding.Basis(runsAgreeing: compared, runsCompared: compared)
            let words = DiagnosisText.notAssessed(band, range: stretch)
            return Finding(
                id: identifier(.notAssessed, stretch),
                kind: .notAssessed,
                frequencyRange: stretch,
                bands: [band],
                tag: .inconclusive,
                basis: basis,
                confidence: nil,
                headline: words.headline,
                detail: words.detail,
                sentence: words.sentence,
                tagLine: DiagnosisText.tagLine(tag: .inconclusive, basis: basis),
                confidenceStatement: DiagnosisText.notAssessedConfidence,
                repeatability: nil,
                listenFrequency: nil,
                context: nil,
                numbers: nil,
                recordingProblem: nil
            )
        }
    }

    // MARK: Even

    /// The drivers measured as even: every point of a driver's `judgedRange` assessed and within `edgeDecibels`
    /// (`EvenBand.decibels`) of the consensus response's trend, and no deviation or inconclusive finding overlapping
    /// it. A top-end dip cuts the tweeter's range short at the dip's lower edge instead, and the statement names the
    /// stretch it covers. A band between the even band and a deviation (3 to 6 dB off its trend) is simply left out:
    /// it is neither even nor a suspected defect.
    ///
    /// The statement about distortion covers only where a buzz was ruled out in every run (`distortionRuledOut`):
    /// the widest unbroken stretch of such points inside those drivers, no narrower than
    /// `minimumDistortionOctaves`, and it is named in the words. When the woofer is in the statement and distortion
    /// could not be read at its bottom (THD is trusted from 80 Hz with the measurement sweep), the words say it was not
    /// checked there. Nothing at all is said about rattle, which a sweep does not measure.
    static func evenFinding(
        findings: [Finding],
        consensus: [Float],
        assessed: [Bool],
        distortionRuledOut: [Bool],
        compared: Int,
        thresholds: DiagnosisThresholds
    ) -> Finding? {
        let grid = ResponseGrid.frequencies
        let deviation = Trend.deviation(of: consensus, thresholds: thresholds)
        let cut = findings.filter { $0.kind == .topEndDip }.compactMap(\.frequencyRange?.lower).min()
        let blocking = findings.filter { ![.topEndDip, .even, .invalidRecording].contains($0.kind) }.compactMap(\.frequencyRange)
        let unclear = findings.filter { $0.kind == .distortionUnclear }.compactMap(\.frequencyRange)
        var spans: [(band: DriverBand, range: FrequencyRange)] = []
        for band in DriverBand.allCases.reversed() {
            var range = judgedRange(band, thresholds: thresholds)
            if let cut, cut < range.upper {
                guard cut > range.lower else { continue }
                range = FrequencyRange(lower: range.lower, upper: cut)
            }
            let points = grid.indices.filter { range.contains(grid[$0]) && grid[$0] < (cut ?? .infinity) }
            guard let first = points.first, let last = points.last,
                  points.allSatisfy({ assessed[$0] && abs(deviation[$0]) <= thresholds.edgeDecibels }),
                  !blocking.contains(where: { $0.overlaps(range) }) else { continue }
            spans.append((band, FrequencyRange(lower: grid[first], upper: grid[last])))
        }
        guard !spans.isEmpty else { return nil }
        let bands = spans.map(\.band)
        // Adjacent drivers' stretches meet at neighbouring grid points; they are stated as one.
        var response: [FrequencyRange] = []
        for span in spans.map(\.range).sorted(by: { $0.lower < $1.lower }) {
            if let previous = response.last, span.lower <= previous.upper * pow(2, 1.5 / ResponseGrid.pointsPerOctave) {
                response[response.count - 1] = FrequencyRange(lower: previous.lower, upper: max(previous.upper, span.upper))
            } else {
                response.append(span)
            }
        }
        let range = FrequencyRange(lower: response.first!.lower, upper: response.last!.upper)
        var clean: FrequencyRange?
        var start: Int?
        for index in grid.indices {
            let frequency = grid[index]
            let inside = distortionRuledOut[index]
                && spans.contains { $0.range.contains(frequency) }
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
        let wooferSpan = spans.first { $0.band == .woofer }?.range
        let uncheckedBelow: Float? = wooferSpan.flatMap { span in
            clean.flatMap { $0.lower > span.lower * pow(2, 1.5 / ResponseGrid.pointsPerOctave) ? $0.lower : nil }
        }
        let words = DiagnosisText.even(
            bands: bands,
            response: response,
            distortionBelow: thresholds.distortionPercent,
            over: clean,
            uncheckedBelow: uncheckedBelow
        )
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
