import SwiftUI

/// One instruction row: the step's number in `lime` mono, then the text ("01  Phone at ear height, screen facing
/// the ceiling", V3MGuide). Stack several; every row after the first asks for `showsSeparator` to get the hairline
/// above it. VoiceOver reads "Step 1, Phone at ear height".
public struct ResoniqNumberedStep: View {
    private let number: Int
    private let text: String
    private let showsSeparator: Bool

    @ScaledMetric(relativeTo: .caption) private var numberWidth: CGFloat = Metrics.numberWidth

    public init(_ number: Int, _ text: String, showsSeparator: Bool = false) {
        self.number = number
        self.text = text
        self.showsSeparator = showsSeparator
    }

    /// "01", "02": two digits, as the mockup sets them.
    nonisolated static func numeral(_ number: Int) -> String {
        number >= 0 && number < 10 ? "0\(number)" : "\(number)"
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showsSeparator {
                Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline)
            }
            HStack(alignment: .firstTextBaseline, spacing: Metrics.gap) {
                Text(Self.numeral(number))
                    .font(Metrics.numberFont)
                    .foregroundStyle(ResoniqColor.lime)
                    .frame(minWidth: numberWidth, alignment: .leading)
                Text(text)
                    .font(ResoniqFont.body)
                    .foregroundStyle(ResoniqColor.ivory)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, ResoniqSpace.s2)
            .frame(minHeight: Metrics.minHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number), \(text)")
    }

    private enum Metrics {
        static let minHeight: CGFloat = 46
        static let gap: CGFloat = 12
        static let numberWidth: CGFloat = 18
        static let numberFont = ResoniqFont.font(.monoRegular, size: 12, relativeTo: .caption)
    }
}

#Preview("Steps") {
    VStack(spacing: 0) {
        ResoniqNumberedStep(1, "Phone at ear height, screen facing the ceiling")
        ResoniqNumberedStep(2, "Volume where you normally keep it", showsSeparator: true)
        ResoniqNumberedStep(3, "Stay quiet while the tones play", showsSeparator: true)
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
