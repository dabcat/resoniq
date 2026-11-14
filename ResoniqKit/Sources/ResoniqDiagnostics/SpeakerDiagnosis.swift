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
    /// How the sound was played; nil when the phone played it (and in every report stored before this existed).
    public internal(set) var source: SoundSource? = nil

    /// "Measured from a test sound played on another device."; nil when the phone played the sound.
    public var sourceNote: String? { DiagnosisText.sourceNote(source) }

    /// "The phone moved while run 2 played. I kept that run, so read its details with a little care."; nil when no
    /// run moved.
    public var phoneMovedNote: String? { phoneMovedRuns.flatMap(DiagnosisText.phoneMovedNote(runs:)) }

    /// The findings that are suspected defects: deviations the other speaker does not share.
    public var suspectedDefects: [Finding] { findings.filter(\.isSuspectedDefect) }
}

/// Turns a test's runs into findings, following the plan's rules of evidence:
///
/// - A deviation found in every valid run at the same place is `inferred`, basis "3 of 3 runs", medium confidence
///   (never high from one microphone position). In fewer runs, but at least `minimumAgreeingRuns`, it is
///   `inferred` with low confidence. In one run it is dropped.
/// - A dip that is deepest above `topEndFrequency` is `inconclusive`: it could be the phone's angle.
/// - A dip or peak the other speaker has too, at the same place and within `leftRightDecibels` of the same size, is
///   still reported (`inferred`), but not as a suspected defect (`Finding.sharedWithOtherSpeaker`): two speakers
///   rarely fail the same way, so the room or the phone's position is the likelier cause, and the words say so.
/// - A buzz is claimed only where THD is a measurement (`DistortionReading.measured`: clear of the noise floor by
///   the DSP's margin). Where THD reads above `distortionPercent` but not clear of the noise, the finding is
///   `inconclusive` ("too noisy to tell"), never a buzz.
/// - A statement that drivers are even is `measured`, and what it says about distortion covers only the stretch
///   where every run ruled a buzz out; it says nothing about rattle, which a sweep does not measure.
/// - Sound tied to the sweep (`RunRecord.sweepTiedSound`, the session's observation) at the same place in at least
///   `minimumAgreeingRuns` valid runs is a possible rattle, `inferred` with the runs as its basis; in one run it is
///   dropped. Over a measured buzz it is not a second finding but the buzz's second piece of evidence
///   (`Finding.sweepTied`). Either way the drivers it overlaps are left out of the even statement.
/// - The level above the tenth harmonic (`RunMeasurement.highOrderDecibels`) measured at or over `highOrderDecibels`
///   at the same place in at least `minimumAgreeingRuns` valid runs is a possible rub or buzz (`highOrderDistortion`),
///   `inferred`, whatever THD read; in one run it is dropped, and a level that did not stand clear of the noise is never
///   a finding. Over a measured buzz or a possible rattle it is not a second finding but that finding's further
///   evidence (`Finding.highOrder`). The even statement says where rub and buzz were ruled out, or that they could not
///   be checked over the room's noise; it never implies they were clean where they could not be read.
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
    ///   - source: How the sound was played (the session's `MeasurementResult.source`, mapped by the app); nil for the
    ///     phone. Kept on the report as `source`, changing nothing else (`SoundSource` says why).
    public static func diagnose(
        runs: [RunAnalysis],
        counterpart: [RunAnalysis]?,
        phoneMovedRuns: [Int] = [],
        source: SoundSource? = nil,
        thresholds: DiagnosisThresholds = .standard
    ) -> SpeakerReport {
        var report = diagnosis(
            records: runs.map(\.record), counterpart: counterpart?.map(\.record), reportsDifferences: true, thresholds: thresholds
        )
        let moved = Array(Set(phoneMovedRuns)).sorted()
        report.phoneMovedRuns = moved.isEmpty ? nil : moved
        report.source = source
        return report
    }

    /// A kept report read again now that the other speaker of the pair has been tested: a dip or peak both speakers
    /// have is no longer a suspected defect, and the verdict says so. For the speaker tested first, whose report was
    /// made with nothing to compare with. Everything is recomputed from the runs the report holds, so nothing else
    /// changes: the report keeps how its sound was played, the runs the phone moved in and what a model added, and it
    /// gains no left/right difference (that is reported once, on the speaker tested second). A report that is not
    /// conclusive, or an `other` that is not, comes back unchanged.
    public static func compared(
        _ report: SpeakerReport,
        with other: SpeakerReport,
        thresholds: DiagnosisThresholds = .standard
    ) -> SpeakerReport {
        guard report.isConclusive, other.isConclusive else { return report }
        let again = diagnosis(
            records: report.runs,
            counterpart: other.runs,
            reportsDifferences: report.findings.contains { $0.kind == .leftRightDifference },
            thresholds: thresholds
        )
        let support = Dictionary(report.findings.compactMap { finding in finding.modelSupport.map { (finding.id, $0) } }) { first, _ in first }
        var updated = SpeakerReport(
            verdict: again.verdict,
            findings: again.findings.map { finding in
                var finding = finding
                finding.modelSupport = support[finding.id]
                return finding
            },
            profile: again.profile,
            runs: again.runs,
            consensusResponse: again.consensusResponse,
            isConclusive: again.isConclusive
        )
        updated.modelFindings = report.modelFindings
        updated.phoneMovedRuns = report.phoneMovedRuns
        updated.source = report.source
        return updated
    }

    /// - Parameter reportsDifferences: Whether a response unlike the counterpart's is a finding here
    ///   (`leftRightDifference`); what the two share is marked either way.
    private static func diagnosis(
        records: [RunRecord],
        counterpart: [RunRecord]?,
        reportsDifferences: Bool,
        thresholds: DiagnosisThresholds
    ) -> SpeakerReport {
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
        let theirs = counterpart.flatMap { counterpartDeviations($0, thresholds: thresholds) }
        // A dip inside a driver that could barely be heard is that driver, already reported.
        for cluster in response.dips where cluster.runs >= thresholds.minimumAgreeingRuns
            && !quietRanges.contains(where: { $0.contains(cluster.range.centre) }) {
            // Where the dip is deepest decides, not where it starts: the same roll-off starts a little under or
            // over the mark from one speaker to the next.
            if cluster.extremeFrequency >= thresholds.topEndFrequency {
                findings.append(topEndFinding(cluster, compared: compared, runCount: records.count, thresholds: thresholds))
            } else {
                findings.append(deviationFinding(
                    .responseDip, cluster, compared: compared, runCount: records.count, thresholds: thresholds,
                    sharedWithOther: isShared(cluster, among: theirs?.dips, thresholds: thresholds)
                ))
            }
        }
        for cluster in response.peaks where cluster.runs >= thresholds.minimumAgreeingRuns {
            findings.append(deviationFinding(
                .responsePeak, cluster, compared: compared, runCount: records.count, thresholds: thresholds,
                sharedWithOther: isShared(cluster, among: theirs?.peaks, thresholds: thresholds)
            ))
        }
        // Nor is distortion read in a driver that could barely be heard: what was there is noise.
        let distortion = distortionClusters(measurements, audible: audible, thresholds: thresholds)
        func inQuietBand(_ cluster: Cluster) -> Bool { quietRanges.contains { $0.contains(cluster.range.centre) } }
        let buzzes = distortion.measured.filter { $0.runs >= thresholds.minimumAgreeingRuns && !inQuietBand($0) }
        // Sound tied to the sweep where it recurs: over a measured buzz it is that buzz's second piece of evidence,
        // so the two never contradict each other; elsewhere it is a possible rattle.
        let tied = sweepTiedClusters(records, valid: Set(measurements.keys), thresholds: thresholds)
        // Energy above the tenth harmonic where it recurs: over a measured buzz or a possible rattle it is that
        // finding's further evidence; elsewhere it is a possible rub or buzz of its own.
        let high = highOrderClusters(measurements, audible: audible, thresholds: thresholds)
            .filter { $0.runs >= thresholds.minimumAgreeingRuns && !inQuietBand($0) }
        func highOrderAt(_ cluster: Cluster) -> Cluster? {
            high.first { $0.range.overlaps(cluster.range, toleranceOctaves: thresholds.samePlaceOctaves) }
        }
        let rattles = tied.filter { cluster in !buzzes.contains(where: { $0.range.overlaps(cluster.range) }) }
        for cluster in buzzes {
            let alsoHeard = tied.first { $0.range.overlaps(cluster.range) }
            findings.append(deviationFinding(
                .distortion, cluster, compared: compared, runCount: records.count, thresholds: thresholds, sweepTied: alsoHeard,
                highOrder: highOrderAt(cluster)
            ))
        }
        for cluster in rattles {
            findings.append(rattleFinding(cluster, compared: compared, thresholds: thresholds, highOrder: highOrderAt(cluster)))
        }
        let clean = distortionRuledOut(measurements, audible: audible, thresholds: thresholds)
        let readings = distortionReadings(measurements, audible: audible)
        for cluster in high where !(buzzes + rattles).contains(where: {
            $0.range.overlaps(cluster.range, toleranceOctaves: thresholds.samePlaceOctaves)
        }) {
            findings.append(deviationFinding(
                .highOrderDistortion, cluster, compared: compared, runCount: records.count, thresholds: thresholds,
                thdUnder: thdStayedUnder(cluster.range, ruledOut: clean, readings: readings, thresholds: thresholds)
            ))
        }
        // Where THD read above the threshold but did not stand clear of the noise, no buzz is claimed; the report
        // says it could not tell, unless a measured buzz is already at the same place (its noisy skirt).
        for cluster in distortion.belowNoise
        where cluster.runs >= thresholds.minimumAgreeingRuns && !inQuietBand(cluster)
            && !buzzes.contains(where: { $0.range.overlaps(cluster.range, toleranceOctaves: thresholds.samePlaceOctaves) }) {
            findings.append(distortionUnclearFinding(cluster, compared: compared, runCount: records.count, thresholds: thresholds))
        }
        if let counterpart, reportsDifferences {
            let explained = findings.filter { $0.kind == .responseDip || $0.kind == .responsePeak }.compactMap(\.frequencyRange)
            findings += leftRightFindings(
                measurements,
                assessed: assessed,
                counterpart: counterpart,
                explained: explained,
                runCount: records.count,
                thresholds: thresholds
            )
        }
        let consensus = consensusResponse(Array(measurements.values))
        let even = evenFinding(
            findings: findings, consensus: consensus, assessed: assessed, distortionRuledOut: clean,
            readings: readings, compared: compared, thresholds: thresholds,
            highOrder: highOrderCoverage(measurements, audible: audible, thresholds: thresholds)
        )
        if let finding = even.finding { findings.append(finding) }

        let ordered = invalid + findings.sorted { ($0.frequencyRange?.centre ?? 0) > ($1.frequencyRange?.centre ?? 0) }
        let suspected = ordered.filter(\.isSuspectedDefect)
        let shared = ordered.filter { $0.sharedWithOtherSpeaker == true }
        let uncheckedBands = unchecked.compactMap(\.band)
        // A driver that a deviation both speakers have reaches into is not called healthy, and not faulted (the even
        // statement leaves it out the same way); one that also holds a suspected defect is named by that.
        let sharedBands = DriverBand.allCases.reversed().filter { band in
            let judged = judgedRange(band, thresholds: thresholds)
            return shared.contains { $0.frequencyRange?.overlaps(judged) == true || $0.bands.contains(band) }
                && !suspected.contains { $0.bands.contains(band) }
        }
        return SpeakerReport(
            verdict: DiagnosisText.verdict(
                suspected: suspected,
                unchecked: uncheckedBands,
                checked: DriverBand.allCases.reversed().filter { !uncheckedBands.contains($0) },
                uncleared: DriverBand.allCases.reversed().filter { even.leftOut.contains($0) || sharedBands.contains($0) },
                shared: shared.count
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

    /// Where the level above the tenth harmonic is measured at or over `highOrderDecibels`, run by run, grouped across
    /// runs. Only a measurement counts (`HighOrderReading.measured`): a level that did not stand clear of the noise is
    /// never a finding, not even an inconclusive one, because a clean speaker in an ordinary room reads its noise
    /// there. Extremes are in dB relative to the tone.
    static func highOrderClusters(_ measurements: [Int: RunMeasurement], audible: [Bool], thresholds: DiagnosisThresholds) -> [Cluster] {
        var measured: [Int: [Region]] = [:]
        for (run, measurement) in measurements {
            let values: [Float?] = ResponseGrid.frequencies.indices.map { index in
                guard audible[index], case .measured(let level) = measurement.highOrder(atIndex: index) else { return nil }
                return level
            }
            measured[run] = RegionFinder.regions(
                in: values,
                span: FrequencyRange(lower: thresholds.distortionLowerFrequency, upper: ResponseGrid.upperFrequency),
                threshold: thresholds.highOrderDecibels,
                edge: thresholds.highOrderDecibels,
                minimumOctaves: thresholds.minimumDistortionOctaves
            )
        }
        return Cluster.group(measured, toleranceOctaves: thresholds.samePlaceOctaves)
    }

    /// For each grid point, whether every valid run rules rub and buzz out there (`ruledOut`: the level above the tenth
    /// harmonic measured under `highOrderDecibels`, or below the noise with the noise's bound under it) and whether any
    /// run read the level there at all (`read`). Both false where the band was not audible.
    static func highOrderCoverage(
        _ measurements: [Int: RunMeasurement],
        audible: [Bool],
        thresholds: DiagnosisThresholds
    ) -> (ruledOut: [Bool], read: [Bool]) {
        let grid = ResponseGrid.frequencies
        let usable = grid.indices.map { audible[$0] && grid[$0] >= thresholds.distortionLowerFrequency }
        let ruledOut = grid.indices.map { index in
            usable[index] && measurements.values.allSatisfy { measurement in
                switch measurement.highOrder(atIndex: index) {
                case .measured(let level): level < thresholds.highOrderDecibels
                case .belowNoise(_, let bound?): bound < thresholds.highOrderDecibels
                case .belowNoise(_, nil), .notRead: false
                }
            }
        }
        let read = grid.indices.map { index in
            usable[index] && measurements.values.contains { $0.highOrder(atIndex: index) != .notRead }
        }
        return (ruledOut, read)
    }

    /// The buzz threshold, when THD stayed under it across `range` in every run: a buzz was ruled out at some point of
    /// it (`distortionRuledOut`) and no run measured THD at or over the threshold anywhere in it. Nil otherwise (THD
    /// not read there, such as under 80 Hz, or read too close to the noise).
    static func thdStayedUnder(
        _ range: FrequencyRange,
        ruledOut: [Bool],
        readings: [[DistortionReading]],
        thresholds: DiagnosisThresholds
    ) -> Float? {
        let points = ResponseGrid.frequencies.indices.filter { range.contains(ResponseGrid.frequencies[$0]) }
        let over = points.contains { index in
            readings.contains { run in
                if case .measured(let percent) = run[index] { return percent >= thresholds.distortionPercent }
                return false
            }
        }
        return points.contains { ruledOut[$0] } && !over ? thresholds.distortionPercent : nil
    }

    /// The other speaker's own dips and peaks, where enough of its runs agree; nil when too few of its runs are valid
    /// to compare with.
    static func counterpartDeviations(_ counterpart: [RunRecord], thresholds: DiagnosisThresholds) -> (dips: [Cluster], peaks: [Cluster])? {
        let others = Dictionary(uniqueKeysWithValues: counterpart.enumerated().compactMap { index, record in record.measurement.map { (index, $0) } })
        guard others.count >= thresholds.minimumValidRuns else { return nil }
        let assessed = assessedPoints(others, audible: audiblePoints(others, thresholds: thresholds))
        let clusters = responseClusters(others, assessed: assessed, thresholds: thresholds)
        return (
            clusters.dips.filter { $0.runs >= thresholds.minimumAgreeingRuns },
            clusters.peaks.filter { $0.runs >= thresholds.minimumAgreeingRuns }
        )
    }

    /// Whether the other speaker has the same deviation: at the same place (`samePlaceOctaves`) and within
    /// `leftRightDecibels` of the same size. A deviation far deeper here than there is still this speaker's.
    static func isShared(_ cluster: Cluster, among theirs: [Cluster]?, thresholds: DiagnosisThresholds) -> Bool {
        guard let theirs else { return false }
        return theirs.contains { other in
            other.range.overlaps(cluster.range, toleranceOctaves: thresholds.samePlaceOctaves)
                && abs(other.extreme - cluster.extreme) <= thresholds.leftRightDecibels
        }
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
    static func rattleFinding(_ cluster: Cluster, compared: Int, thresholds: DiagnosisThresholds, highOrder: Cluster? = nil) -> Finding {
        let range = cluster.range
        let basis = Finding.Basis(runsAgreeing: cluster.runs, runsCompared: compared)
        let confidence: Finding.Confidence =
            cluster.runs == compared && cluster.runs >= thresholds.mediumConfidenceRuns ? .medium : .low
        var words = DiagnosisText.rattle(range: range)
        let evidence = highOrder.map { highOrderEvidence($0, compared: compared) }
        if let evidence { words.detail += " " + evidence.statement }
        var finding = Finding(
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
        finding.highOrder = evidence
        return finding
    }

    /// The level above the tenth harmonic as further evidence of a buzz or a rattle at the same place.
    static func highOrderEvidence(_ cluster: Cluster, compared: Int) -> Finding.HighOrderEvidence {
        let basis = Finding.Basis(runsAgreeing: cluster.runs, runsCompared: compared)
        return Finding.HighOrderEvidence(
            range: cluster.range,
            extreme: cluster.extreme,
            runsMeasured: cluster.runs,
            runsCompared: compared,
            statement: DiagnosisText.highOrderAlso(extreme: cluster.extreme, basis)
        )
    }

    static func deviationFinding(
        _ kind: Finding.Kind,
        _ cluster: Cluster,
        compared: Int,
        runCount: Int,
        thresholds: DiagnosisThresholds,
        sweepTied: Cluster? = nil,
        sharedWithOther: Bool = false,
        highOrder: Cluster? = nil,
        thdUnder: Float? = nil
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
        case .highOrderDistortion:
            words = DiagnosisText.highOrder(range: range, extreme: cluster.extreme, at: cluster.extremeFrequency, thdUnder: thdUnder)
            numbers = Self.numbers(cluster, unit: .toneDecibels, threshold: thresholds.highOrderDecibels, runCount: runCount)
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
        let highOrderEvidence = highOrder.map { Self.highOrderEvidence($0, compared: compared) }
        if let highOrderEvidence { words.detail += " " + highOrderEvidence.statement }
        if sharedWithOther { words.detail += " " + DiagnosisText.sharedWithOther(isPeak: kind == .responsePeak) }
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
            confidenceStatement: sharedWithOther
                ? DiagnosisText.sharedConfidence
                : DiagnosisText.confidenceStatement(kind: kind, confidence: confidence, basis: basis),
            repeatability: DiagnosisText.repeatability(basis),
            listenFrequency: DiagnosisText.rounded(range.centre),
            context: range.widened(octaves: 0.85),
            numbers: numbers,
            recordingProblem: nil
        )
        if sharedWithOther { finding.sharedWithOtherSpeaker = true }
        finding.sweepTied = evidence
        finding.highOrder = highOrderEvidence
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
    /// stretch it covers. A band between the even band and a deviation (3 to 6 dB off its trend) is left out of the
    /// drivers called even: it is neither even nor a suspected defect, and it is never left out silently (below).
    ///
    /// The statement about distortion covers only where a buzz was ruled out in every run (`distortionRuledOut`):
    /// the widest unbroken stretch of such points inside those drivers, no narrower than
    /// `minimumDistortionOctaves`, and it is named in the words. When the woofer is in the statement and distortion
    /// could not be read at its bottom (THD is trusted from 80 Hz with the measurement sweep), the words say it was not
    /// checked there. Nothing at all is said about rattle, which a sweep does not measure.
    ///
    /// **The bass roll-off.** Every speaker rolls off at the bottom of its range. When the response falls steadily below
    /// a knee at or under `rollOffUpperFrequency` (`rollOffKnee`), the woofer is judged from the knee up, and the
    /// statement says so plainly ("Bass rolls off below 70 Hz."), `measured` and not a deviation. Above that knee the
    /// bass is judged as it is: uneven (below), or barely heard (`quietBandFindings`, which reads from the same 100 Hz).
    ///
    /// A driver that is assessed everywhere and overlapped by no finding, but strays more than `edgeDecibels` from the
    /// trend somewhere above the knee (3 to 6 dB), or where at least `minimumAgreeingRuns` runs measured distortion at
    /// or over `distortionPercent` that made no buzz (too narrow to be one), is returned in `leftOut`, so the verdict
    /// does not call it healthy, and the statement says why it is left out: where its response strays, where its
    /// distortion could not be checked, and the distortion that fell short of a buzz. `readings` are each run's
    /// `DistortionReading`s on the grid, `.notRead` where the band was not audible.
    static func evenFinding(
        findings: [Finding],
        consensus: [Float],
        assessed: [Bool],
        distortionRuledOut: [Bool],
        readings: [[DistortionReading]],
        compared: Int,
        thresholds: DiagnosisThresholds,
        highOrder: (ruledOut: [Bool], read: [Bool])? = nil
    ) -> (finding: Finding?, leftOut: [DriverBand]) {
        let grid = ResponseGrid.frequencies
        let deviation = Trend.deviation(of: consensus, thresholds: thresholds)
        let cut = findings.filter { $0.kind == .topEndDip }.compactMap(\.frequencyRange?.lower).min()
        let blocking = findings.filter { ![.topEndDip, .even, .invalidRecording].contains($0.kind) }.compactMap(\.frequencyRange)
        let unclear = findings.filter { $0.kind == .distortionUnclear }.compactMap(\.frequencyRange)
        let knee = rollOffKnee(consensus: consensus, deviation: deviation, assessed: assessed, thresholds: thresholds)
        var rollOffBelow: Float?
        var spans: [(band: DriverBand, range: FrequencyRange)] = []
        var leftOut: [(band: DriverBand, words: String)] = []
        for band in DriverBand.allCases.reversed() {
            var range = judgedRange(band, thresholds: thresholds)
            if let cut, cut < range.upper {
                guard cut > range.lower else { continue }
                range = FrequencyRange(lower: range.lower, upper: cut)
            }
            guard !blocking.contains(where: { $0.overlaps(range) }) else { continue }
            // The woofer is judged from the knee of a natural roll-off up.
            let bottom = band == .woofer ? knee.map { grid[$0] } : nil
            let points = grid.indices.filter {
                range.contains(grid[$0]) && grid[$0] < (cut ?? .infinity) && grid[$0] >= (bottom ?? 0)
            }
            guard let first = points.first, let last = points.last, points.allSatisfy({ assessed[$0] }) else { continue }
            if let bottom { rollOffBelow = bottom }
            let off = points.filter { abs(deviation[$0]) > thresholds.edgeDecibels }
            if let words = leftOutWords(
                band,
                points: points,
                off: off.first.flatMap { lower in off.last.map { FrequencyRange(lower: grid[lower], upper: grid[$0]) } },
                offBy: off.map { abs(deviation[$0]) }.max() ?? 0,
                distortionRuledOut: distortionRuledOut,
                readings: readings,
                thresholds: thresholds
            ) {
                leftOut.append((band, words))
                continue
            }
            spans.append((band, FrequencyRange(lower: grid[first], upper: grid[last])))
        }
        let leftOutBands = leftOut.map(\.band)
        guard !spans.isEmpty else { return (nil, leftOutBands) }
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
        /// The widest unbroken stretch inside the stated drivers where `include` holds, no narrower than
        /// `minimumDistortionOctaves`.
        func widest(_ include: (Int) -> Bool) -> FrequencyRange? {
            var widest: FrequencyRange?
            var start: Int?
            for index in grid.indices {
                let inside = include(index) && spans.contains { $0.range.contains(grid[index]) }
                if inside, start == nil { start = index }
                if let first = start, !inside || index == grid.count - 1 {
                    let last = inside ? index : index - 1
                    let stretch = FrequencyRange(lower: grid[first], upper: grid[last])
                    if stretch.octaves >= thresholds.minimumDistortionOctaves, stretch.octaves > (widest?.octaves ?? -1) {
                        widest = stretch
                    }
                    start = nil
                }
            }
            return widest
        }
        let clean = widest { index in distortionRuledOut[index] && !unclear.contains { $0.contains(grid[index]) } }
        // Rub and buzz: named clean only where every run ruled them out; where they were read but not ruled out, the
        // statement says so; where nothing was read (a record stored before they were kept), it says nothing.
        let highOrderStatement: DiagnosisText.HighOrderStatement? = highOrder.flatMap { coverage in
            if let stretch = widest({ coverage.ruledOut[$0] }) { return .ruledOut(stretch) }
            let anyRead = grid.indices.contains { index in coverage.read[index] && spans.contains { $0.range.contains(grid[index]) } }
            return anyRead ? .notChecked : nil
        }
        let basis = Finding.Basis(runsAgreeing: compared, runsCompared: compared)
        let wooferSpan = spans.first { $0.band == .woofer }?.range
        let uncheckedBelow: Float? = wooferSpan.flatMap { span in
            clean.flatMap { $0.lower > span.lower * pow(2, 1.5 / ResponseGrid.pointsPerOctave) ? $0.lower : nil }
        }
        var words = DiagnosisText.even(
            bands: bands,
            response: response,
            distortionBelow: thresholds.distortionPercent,
            over: clean,
            uncheckedBelow: uncheckedBelow,
            rollOffBelow: rollOffBelow,
            highOrder: highOrderStatement
        )
        for item in leftOut { words.detail += " " + item.words }
        let finding = Finding(
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
        return (finding, leftOutBands)
    }

    /// Each valid run's `DistortionReading` at every grid point, `.notRead` where the band was not audible (as
    /// `distortionClusters` reads them).
    static func distortionReadings(_ measurements: [Int: RunMeasurement], audible: [Bool]) -> [[DistortionReading]] {
        measurements.keys.sorted().map { run in
            let measurement = measurements[run]!
            return ResponseGrid.frequencies.indices.map { audible[$0] ? measurement.distortion(atIndex: $0) : .notRead }
        }
    }

    /// The index of the knee of a natural bass roll-off on `ResponseGrid`, nil when there is none.
    ///
    /// From the bottom of the woofer's judged range (`responseLowerFrequency`) going up, the response must start more
    /// than `edgeDecibels` under its trend and rise steadily (never falling by more than `rollOffToleranceDecibels`
    /// from one point to the next) until it is back within `edgeDecibels`; that point is the knee, and it must lie at
    /// or under `rollOffUpperFrequency`. Every point on the way must be assessed. A dip that comes back lower down is
    /// not a roll-off (the response falls going up), and neither is bass still falling above 100 Hz.
    static func rollOffKnee(consensus: [Float], deviation: [Float], assessed: [Bool], thresholds: DiagnosisThresholds) -> Int? {
        let grid = ResponseGrid.frequencies
        guard let bottom = grid.indices.first(where: { grid[$0] >= thresholds.responseLowerFrequency }),
              assessed[bottom], deviation[bottom] < -thresholds.edgeDecibels else { return nil }
        var index = bottom
        while deviation[index] < -thresholds.edgeDecibels {
            let next = index + 1
            guard next < grid.count, grid[next] <= thresholds.rollOffUpperFrequency, assessed[next],
                  consensus[next] >= consensus[index] - thresholds.rollOffToleranceDecibels else { return nil }
            index = next
        }
        return index
    }

    /// The even statement's words for a driver it leaves out (see `evenFinding`), nil when it is not left out: no
    /// stretch `off` its trend and no distortion short of a buzz. Over `points`, the driver's grid points: where a buzz
    /// was not ruled out, a point where at least `minimumAgreeingRuns` runs measured THD at or over `distortionPercent`
    /// is distortion "short of a buzz" (it made no buzz finding, or the driver would be blocked); any other is a point
    /// where distortion could not be checked (not read, the noise's bound over the threshold, or over it in one run).
    static func leftOutWords(
        _ band: DriverBand,
        points: [Int],
        off: FrequencyRange?,
        offBy: Float,
        distortionRuledOut: [Bool],
        readings: [[DistortionReading]],
        thresholds: DiagnosisThresholds
    ) -> String? {
        let grid = ResponseGrid.frequencies
        // Over the threshold in at least `minimumAgreeingRuns` runs: in one run it is dropped, like any deviation.
        func measuredOver(_ index: Int) -> Float? {
            let over = readings.compactMap { run -> Float? in
                if case .measured(let percent) = run[index], percent >= thresholds.distortionPercent { return percent }
                return nil
            }
            return over.count >= thresholds.minimumAgreeingRuns ? over.max() : nil
        }
        let open = points.filter { !distortionRuledOut[$0] }
        let over = open.compactMap { index in measuredOver(index).map { (index, $0) } }.max { $0.1 < $1.1 }
        guard off != nil || over != nil else { return nil }
        let unchecked = open.filter { measuredOver($0) == nil }
        var below: Float?
        var around: FrequencyRange?
        if let first = unchecked.first, let last = unchecked.last {
            // One unbroken stretch from the driver's bottom: "below" the first point after it.
            if first == points.first, unchecked.count == last - first + 1, last + 1 < grid.count {
                below = grid[last + 1]
            } else {
                around = FrequencyRange(lower: grid[first], upper: grid[last])
            }
        }
        return DiagnosisText.leftOut(
            band,
            off: off,
            offBy: offBy,
            uncheckedDistortion: around,
            belowFrequency: below,
            overPercent: over?.1,
            overFrequency: over.map { grid[$0.0] }
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
