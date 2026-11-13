import SwiftUI

/// How a finding is known. The app maps its diagnostics type onto this.
public enum ResoniqEvidenceKind: CaseIterable, Sendable {
    /// Read directly from this session's recordings. Solid dot.
    case measured
    /// Concluded from measurements; the basis says what from. Half-filled dot.
    case inferred
    /// Could not be decided; the basis says why. Hollow dot.
    case inconclusive
    /// A rough figure where measurement quality is limited. A `guide`-coloured label, no dot.
    case estimate

    public var title: String {
        switch self {
        case .measured: "Measured"
        case .inferred: "Inferred"
        case .inconclusive: "Inconclusive"
        case .estimate: "Estimate"
        }
    }
}

/// The glyph, the tag's name and, where there is one, what it rests on: "Inferred · 3 of 3 runs".
/// Set it above the finding's headline, as in V3Result.
public struct ResoniqEvidenceTag: View {
    private let kind: ResoniqEvidenceKind
    private let basis: String?
    private let isDeviation: Bool

    @ScaledMetric(relativeTo: .caption) private var glyphSize: CGFloat = Metrics.glyphSize

    /// - Parameters:
    ///   - basis: What the tag rests on ("3 of 3 runs"), or why it is inconclusive.
    ///   - isDeviation: The finding is a suspected defect, so the tag is `signalText` and semibold.
    public init(_ kind: ResoniqEvidenceKind, basis: String? = nil, isDeviation: Bool = false) {
        self.kind = kind
        self.basis = basis
        self.isDeviation = isDeviation
    }

    public var text: String {
        [kind.title, basis].compactMap { $0 }.joined(separator: " · ")
    }

    public var body: some View {
        HStack(spacing: Metrics.gap) {
            if kind != .estimate {
                EvidenceGlyph(kind: kind, color: glyphColor)
                    .frame(width: glyphSize, height: glyphSize)
            }
            Text(text)
                .font(isDeviation ? Metrics.emphasisFont : Metrics.font)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var color: Color {
        if isDeviation { return ResoniqColor.signalText }
        return kind == .estimate ? ResoniqColor.guide : ResoniqColor.muted
    }

    /// A measured dot is `ivory` whatever the label's colour, as in V3Result.
    private var glyphColor: Color {
        if isDeviation { return ResoniqColor.signalText }
        return kind == .measured ? ResoniqColor.ivory : ResoniqColor.muted
    }

    private enum Metrics {
        static let glyphSize: CGFloat = 10
        static let gap: CGFloat = 7
        static let font = ResoniqFont.font(.sansRegular, size: 12, relativeTo: .caption)
        static let emphasisFont = ResoniqFont.font(.sansSemibold, size: 12, relativeTo: .caption)
    }
}

/// The dot of an evidence tag, drawn in a square.
struct EvidenceGlyph: View {
    let kind: ResoniqEvidenceKind
    let color: Color

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let ringWidth = side * 0.15
            let ring = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: ringWidth / 2, dy: ringWidth / 2)
            switch kind {
            case .measured:
                context.fill(Path(ellipseIn: CGRect(x: 0, y: 0, width: side, height: side)), with: .color(color))
            case .inferred:
                context.stroke(Path(ellipseIn: ring), with: .color(color), lineWidth: ringWidth)
                // The right half of the disc, as in the mockup.
                context.drawLayer { layer in
                    layer.clip(to: Path(CGRect(x: side / 2, y: 0, width: side / 2, height: side)))
                    layer.fill(Path(ellipseIn: ring), with: .color(color))
                }
            case .inconclusive:
                context.stroke(Path(ellipseIn: ring), with: .color(color), lineWidth: ringWidth)
            case .estimate:
                break
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Kinds") {
    VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
        ResoniqEvidenceTag(.measured)
        ResoniqEvidenceTag(.inferred, basis: "3 of 3 runs", isDeviation: true)
        ResoniqEvidenceTag(.inferred, basis: "3 of 3 runs")
        ResoniqEvidenceTag(.inconclusive)
        ResoniqEvidenceTag(.estimate, basis: "decay time")
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.panel)
}
