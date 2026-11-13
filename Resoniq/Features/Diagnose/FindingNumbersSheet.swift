import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

/// The measured numbers behind a finding, run by run. A stand-in for the numbers screen of a later phase, so the
/// "Show the numbers" link leads somewhere true: it lists what the Kit measured and recomputes nothing.
struct FindingNumbersSheet: View {
    let finding: Finding
    let report: SpeakerReport

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
                header
                if let numbers = finding.numbers {
                    summary(numbers)
                    runs(numbers)
                    Text(Words.explanation(numbers.unit))
                        .font(ResoniqFont.caption)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(ResoniqSecondaryButtonStyle())
            }
            .padding(ResoniqSpace.screenInset)
        }
        .scrollIndicators(.hidden)
        .background(ResoniqColor.ink)
        .presentationDetents([.medium, .large])
        .presentationBackground(ResoniqColor.ink)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            ResoniqEvidenceTag(finding.evidenceKind, basis: finding.tagBasis, isDeviation: finding.kind.isDeviation)
            Text(finding.headline)
                .font(ResoniqFont.headline)
                .foregroundStyle(ResoniqColor.ivory)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func summary(_ numbers: Finding.Numbers) -> some View {
        VStack(spacing: 0) {
            row(Words.worst, Self.format(numbers.extreme, unit: numbers.unit))
            row(Words.where, DiagnosisText.frequency(numbers.extremeFrequency))
            row(Words.limit, Self.format(numbers.threshold, unit: numbers.unit, signed: false))
        }
        .resoniqPanel()
    }

    private func runs(_ numbers: Finding.Numbers) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(report.runs.enumerated()), id: \.offset) { index, run in
                row(
                    "Run \(index + 1)",
                    value(of: index, run: run, numbers: numbers)
                )
            }
        }
        .resoniqPanel()
    }

    private func value(of index: Int, run: RunRecord, numbers: Finding.Numbers) -> String {
        guard run.check.isValid else { return Words.unusable }
        guard index < numbers.perRun.count, let value = numbers.perRun[index] else { return Words.notFound }
        return Self.format(value, unit: numbers.unit)
    }

    private func row(_ label: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(label).resoniqCapsLabel()
                Spacer(minLength: ResoniqSpace.s2)
                figure(value)
            }
            VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
                Text(label).resoniqCapsLabel()
                figure(value)
            }
        }
        .padding(.vertical, ResoniqSpace.s2)
        .accessibilityElement(children: .combine)
    }

    private func figure(_ value: String) -> some View {
        Text(value)
            .font(ResoniqFont.figure)
            .foregroundStyle(ResoniqColor.ivory)
    }

    /// "21 %" or "-8.5 dB": the Kit's number, written with its unit.
    static func format(_ value: Float, unit: Finding.Numbers.Unit, signed: Bool = true) -> String {
        switch unit {
        case .percent: String(format: "%.1f %%", value)
        case .decibels: String(format: signed ? "%+.1f dB" : "%.1f dB", value)
        }
    }

    enum Words {
        static let worst = "Typical worst point"
        static let `where` = "Where"
        static let limit = "Flagged beyond"
        static let unusable = "Not usable"
        static let notFound = "Not found"

        static func explanation(_ unit: Finding.Numbers.Unit) -> String {
            switch unit {
            case .percent: "How much of the sound is distortion rather than the note, at the worst point of each run."
            case .decibels: "Level against this speaker's own middle notes, at the worst point of each run. The microphone is not calibrated, so only the difference means anything."
            }
        }
    }
}

#if DEBUG
#Preview("Distortion") {
    FindingNumbersSheet(finding: DiagnoseFixtures.buzz, report: DiagnoseFixtures.buzzing)
        .preferredColorScheme(.dark)
}
#endif
