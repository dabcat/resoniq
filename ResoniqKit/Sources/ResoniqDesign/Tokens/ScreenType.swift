import SwiftUI

/// Type used by the result screens (V3Result, V3Finding, V3Diagnose) that the role list in `Typography.swift`
/// does not have: the 15 pt label weights, the 14 pt link and body size, the 16 pt row title and the 17 pt speaker
/// name. Each is a bundled face at the mockup's size, scaling with Dynamic Type like the role it sits beside.
public extension ResoniqFont {
    /// 15 pt medium: a finding's title beside the portrait, the value in "Kept in".
    static let bodyMedium = font(.sansMedium, size: 15, relativeTo: .body)
    /// 15 pt semibold: the title of a suspected defect.
    static let bodySemibold = font(.sansSemibold, size: 15, relativeTo: .body)
    /// 14 pt regular: links and the short paragraphs of V3Finding.
    static let bodySmall = font(.sansRegular, size: 14, relativeTo: .callout)
    /// 16 pt semibold: the title of a row that offers a next step.
    static let rowTitle = font(.sansSemibold, size: 16, relativeTo: .body)
    /// 17 pt semibold: a speaker's name under its portrait.
    static let speakerName = font(.sansSemibold, size: 17, relativeTo: .headline)
    /// 13 pt semibold: the status line under a speaker's name when it is a deviation.
    static let captionSemibold = font(.sansSemibold, size: 13, relativeTo: .caption)
    /// 15 pt mono medium: a measured number in a list.
    static let figure = font(.monoMedium, size: 15, relativeTo: .body)
}

/// The two title sizes the result screens set with the display tracking.
public enum ResoniqTitleSize: Sendable {
    /// 34 pt: V3Finding.
    case large
    /// 30 pt: V3Result.
    case medium
    /// 28 pt: V3Measure's verdict.
    case compact

    var font: Font {
        switch self {
        case .large: ResoniqFont.title1
        case .medium: ResoniqFont.title2
        case .compact: ResoniqFont.font(.sansSemibold, size: 28, relativeTo: .title)
        }
    }

    var points: CGFloat {
        switch self {
        case .large: 34
        case .medium: 30
        case .compact: 28
        }
    }
}

public extension View {
    /// A screen headline: semibold with the title tracking of the tokens (-0.03 em).
    func resoniqTitle(_ size: ResoniqTitleSize) -> some View {
        font(size.font)
            .tracking(size.points * ResoniqFont.Tracking.title)
            .foregroundStyle(ResoniqColor.ivory)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An underlined 14 pt link with a 44 pt hit area: "Rename", "Don't keep", "Hear it yourself".
public struct ResoniqInlineLinkStyle: ButtonStyle {
    public enum Tone: Sendable {
        /// "Rename".
        case primary
        /// "Don't keep".
        case quiet
        /// "Hear it yourself": the colour of a deviation's text.
        case deviation
    }

    private let tone: Tone

    public init(_ tone: Tone = .primary) {
        self.tone = tone
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ResoniqFont.bodySmall)
            .underline()
            .foregroundStyle(color(pressed: configuration.isPressed))
            .frame(minHeight: ResoniqSize.touchMin)
            .contentShape(Rectangle())
    }

    private func color(pressed: Bool) -> Color {
        if pressed { return ResoniqColor.muted }
        switch tone {
        case .primary: return ResoniqColor.ivory
        case .quiet: return ResoniqColor.muted
        case .deviation: return ResoniqColor.signalText
        }
    }
}

#Preview("Links and titles") {
    VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
        Text("Sounds healthy, except the woofer may be buzzing.").resoniqTitle(.medium)
        Text("A buzz around 90 Hz.").resoniqTitle(.large)
        HStack {
            Button("Rename") {}.buttonStyle(ResoniqInlineLinkStyle())
            Button("Don't keep") {}.buttonStyle(ResoniqInlineLinkStyle(.quiet))
            Button("Hear it yourself") {}.buttonStyle(ResoniqInlineLinkStyle(.deviation))
        }
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
