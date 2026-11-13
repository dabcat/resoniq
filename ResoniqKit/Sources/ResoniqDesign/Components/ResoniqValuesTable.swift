import SwiftUI

/// A list of measured numbers, one per row, in mono, with a hairline between rows (V3MDetail): what it is
/// ("41 Hz"), its value ("+9.2 dB"), a word for it ("peak"), and how it is known, as an evidence tag.
///
/// Each row is one VoiceOver element that reads as a sentence: "41 Hz, +9.2 dB, peak. Measured." At the largest
/// Dynamic Type sizes a row stacks its parts instead of setting them in columns.
public struct ResoniqValuesTable: View {
    public struct Row: Sendable, Identifiable {
        public let id: String
        public let label: String
        public let value: String
        public let word: String
        public let evidence: ResoniqEvidenceKind
        public let isDeviation: Bool
        /// What VoiceOver says for the label and the value, when the written form reads badly ("minus 11.4
        /// decibels" for "−11.4 dB"). Without it the written text is read.
        public let spokenLabel: String?
        public let spokenValue: String?

        /// - Parameters:
        ///   - isDeviation: The row is an out-of-range finding, so its label is `signalText`.
        public init(
            _ label: String,
            value: String,
            word: String,
            evidence: ResoniqEvidenceKind,
            isDeviation: Bool = false,
            spokenLabel: String? = nil,
            spokenValue: String? = nil
        ) {
            self.id = "\(label)|\(value)|\(word)"
            self.label = label
            self.value = value
            self.word = word
            self.evidence = evidence
            self.isDeviation = isDeviation
            self.spokenLabel = spokenLabel
            self.spokenValue = spokenValue
        }

        /// "41 Hz, +9.2 dB, peak. Measured."
        public var sentence: String {
            "\(spokenLabel ?? label), \(spokenValue ?? value), \(word). \(evidence.title)."
        }
    }

    private let rows: [Row]

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .footnote) private var labelWidth: CGFloat = Metrics.labelWidth
    @ScaledMetric(relativeTo: .footnote) private var valueWidth: CGFloat = Metrics.valueWidth

    public init(rows: [Row]) {
        self.rows = rows
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                VStack(spacing: 0) {
                    if index > 0 {
                        Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline)
                    }
                    rowView(row)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func rowView(_ row: Row) -> some View {
        let label = Text(row.label)
            .font(Metrics.font)
            .foregroundStyle(row.isDeviation ? ResoniqColor.signalText : ResoniqColor.ivory)
        let value = Text(row.value).font(Metrics.font).foregroundStyle(ResoniqColor.ivory)
        let word = Text(row.word).font(Metrics.font).foregroundStyle(ResoniqColor.muted)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
                    label
                    value
                    word
                    ResoniqEvidenceTag(row.evidence)
                }
                .padding(.vertical, ResoniqSpace.s3)
            } else {
                HStack(spacing: Metrics.gap) {
                    label.frame(width: labelWidth, alignment: .leading)
                    value.frame(width: valueWidth, alignment: .leading)
                    word.frame(maxWidth: .infinity, alignment: .leading)
                    ResoniqEvidenceTag(row.evidence)
                }
                .padding(.vertical, ResoniqSpace.s2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.minHeight, alignment: .leading)
        .lineLimit(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.sentence)
    }

    private enum Metrics {
        static let minHeight: CGFloat = 42
        static let gap: CGFloat = 10
        static let labelWidth: CGFloat = 58
        static let valueWidth: CGFloat = 78
        static let font = ResoniqFont.font(.monoRegular, size: 13, relativeTo: .footnote)
    }
}

#Preview("Numbers") {
    ResoniqValuesTable(rows: [
        .init("41 Hz", value: "+9.2 dB", word: "peak", evidence: .measured, isDeviation: true, spokenValue: "plus 9.2 decibels"),
        .init("61 Hz", value: "\u{2212}11.4 dB", word: "dip", evidence: .measured, isDeviation: true, spokenValue: "minus 11.4 decibels"),
        .init("L / R", value: "\u{00B1}1.2 dB", word: "match", evidence: .measured, spokenLabel: "Left against right", spokenValue: "within 1.2 decibels"),
        .init("1 kHz", value: "0.4 %", word: "distortion", evidence: .measured),
        .init("< 80 Hz", value: "\u{2248} 0.6 s", word: "decay", evidence: .estimate),
        .init("Seat", value: "?", word: "unclear", evidence: .inconclusive),
        .init("Room", value: "5 m", word: "inferred", evidence: .inferred),
    ])
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
