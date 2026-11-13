import SwiftUI

/// One finding in the before-and-after list of V3OVerify.
///
/// A value row has a label ("Missing note, 61 Hz"), the value before in `muted` mono, an arrow, and the value
/// after in mono. The after value is `lime` only when the caller says it improved, and then it carries a check as
/// well, so colour is never the only cue. The plain row ("Voices and treble", "Unchanged, still even") has a label
/// and a sentence. Each row is one element for VoiceOver with the whole sentence, including "improved".
public struct BeforeAfterRow: View {
    private enum Content {
        case values(before: String, after: String, improved: Bool)
        case plain(detail: String)
    }

    private let label: String
    private let content: Content
    private let showsDivider: Bool

    /// - Parameters:
    ///   - improved: The after value moved toward even. Colours it `lime` and adds the check.
    ///   - showsDivider: The hairline above the row; leave it off for the first row.
    public init(label: String, before: String, after: String, improved: Bool, showsDivider: Bool = true) {
        self.label = label
        self.content = .values(before: before, after: after, improved: improved)
        self.showsDivider = showsDivider
    }

    /// The plain row: "Voices and treble" with "Unchanged, still even".
    public init(label: String, unchanged detail: String, showsDivider: Bool = true) {
        self.label = label
        self.content = .plain(detail: detail)
        self.showsDivider = showsDivider
    }

    /// What VoiceOver says: "Missing note, 61 Hz, from −11 dB to −4 dB, improved".
    nonisolated static func spokenSummary(label: String, before: String, after: String, improved: Bool) -> String {
        "\(label), from \(before) to \(after)\(improved ? ", improved" : "")"
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.gap) { rowContent }
            VStack(alignment: .leading, spacing: Metrics.stackGap) {
                labelView
                HStack(spacing: Metrics.gap) { valuesOrDetail }
            }
            .padding(.vertical, Metrics.stackPadding)
        }
        .frame(minHeight: Metrics.minHeight)
        .overlay(alignment: .top) {
            if showsDivider { Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        switch content {
        case .values(let before, let after, let improved): Self.spokenSummary(label: label, before: before, after: after, improved: improved)
        case .plain(let detail): "\(label), \(detail)"
        }
    }

    private var labelView: some View {
        Text(label)
            .font(Metrics.labelFont)
            .foregroundStyle(ResoniqColor.ivory)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var rowContent: some View {
        labelView
        valuesOrDetail
    }

    @ViewBuilder
    private var valuesOrDetail: some View {
        switch content {
        case .values(let before, let after, let improved):
            Text(before)
                .font(Metrics.beforeFont)
                .foregroundStyle(ResoniqColor.muted)
            ResoniqIconView(.arrowRight)
                .foregroundStyle(ResoniqColor.muted)
            HStack(spacing: Metrics.checkGap) {
                if improved {
                    ResoniqIconView(.check)
                }
                Text(after)
                    .font(Metrics.afterFont)
            }
            .foregroundStyle(improved ? ResoniqColor.improved : ResoniqColor.ivory)
            .frame(minWidth: Metrics.afterWidth, alignment: .trailing)
        case .plain(let detail):
            Text(detail)
                .font(Metrics.detailFont)
                .foregroundStyle(ResoniqColor.muted)
                .multilineTextAlignment(.trailing)
        }
    }

    private enum Metrics {
        static let minHeight: CGFloat = 48
        static let gap: CGFloat = 10
        static let stackGap: CGFloat = 4
        static let stackPadding: CGFloat = 8
        static let checkGap: CGFloat = 4
        static let afterWidth: CGFloat = 52
        static let labelFont = ResoniqFont.bodyMedium
        static let beforeFont = ResoniqFont.font(.monoRegular, size: 13, relativeTo: .caption)
        static let afterFont = ResoniqFont.font(.monoMedium, size: 14, relativeTo: .callout)
        static let detailFont = ResoniqFont.font(.sansRegular, size: 13, relativeTo: .caption)
    }
}

#if DEBUG
#Preview("Before and after") {
    VStack(spacing: 0) {
        BeforeAfterRow(label: "Missing note, 61 Hz", before: "\u{2212}11 dB", after: "\u{2212}4 dB", improved: true, showsDivider: false)
        BeforeAfterRow(label: "Booming note, 41 Hz", before: "+9 dB", after: "+5 dB", improved: true)
        BeforeAfterRow(label: "Midrange, 400 Hz", before: "+1 dB", after: "+2 dB", improved: false)
        BeforeAfterRow(label: "Voices and treble", unchanged: "Unchanged, still even")
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
#endif
