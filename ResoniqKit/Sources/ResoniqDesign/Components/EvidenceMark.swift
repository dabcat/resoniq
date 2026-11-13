import SwiftUI

/// The dot of an evidence tag on its own, for a sentence that explains the tag (the confidence statement of
/// V3Finding) and so does not repeat the tag's name. It scales with Dynamic Type like the tag.
public struct ResoniqEvidenceMark: View {
    private let kind: ResoniqEvidenceKind
    private let isDeviation: Bool

    @ScaledMetric(relativeTo: .caption) private var side: CGFloat = 10

    public init(_ kind: ResoniqEvidenceKind, isDeviation: Bool = false) {
        self.kind = kind
        self.isDeviation = isDeviation
    }

    public var body: some View {
        EvidenceGlyph(kind: kind, color: color)
            .frame(width: side, height: side)
            .accessibilityHidden(true)
    }

    private var color: Color {
        if isDeviation { return ResoniqColor.signalText }
        return kind == .measured ? ResoniqColor.ivory : ResoniqColor.muted
    }
}

#Preview("Marks") {
    HStack(spacing: ResoniqSpace.s4) {
        ResoniqEvidenceMark(.measured)
        ResoniqEvidenceMark(.inferred, isDeviation: true)
        ResoniqEvidenceMark(.inconclusive)
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.panel)
}
