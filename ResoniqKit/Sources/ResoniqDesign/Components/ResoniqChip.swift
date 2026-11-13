import SwiftUI

/// A pill label. `.action` is the outlined button of V3OLayout ("Add subwoofer", "Add a seat", "Fix a wall");
/// `.detected` is the label of a thing found in the camera view (V3OScan "Window", "Door", "Sofa"), on an `ink`
/// pill so it reads over an image; `.measurement` is the `guide` pill that carries a measured length ("4.20 m").
///
/// Only `.action` takes a touch, with a 44 pt target and the press scale of the system. The other two are read
/// as plain text.
public struct ResoniqChip: View {
    public enum Style: Sendable {
        case action
        case detected
        case measurement
    }

    private let title: String
    private let style: Style
    private let action: (() -> Void)?

    public init(_ title: String, style: Style = .action, action: (() -> Void)? = nil) {
        self.title = title
        self.style = style
        self.action = action
    }

    public var body: some View {
        switch style {
        case .action:
            Button { action?() } label: {
                Text(title)
                    .font(Metrics.actionFont)
                    .foregroundStyle(ResoniqColor.ivory)
                    // Wraps at large type sizes rather than losing its end.
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Metrics.actionPadding)
                    .padding(.vertical, ResoniqSpace.s1)
                    .frame(minHeight: ResoniqSize.touchMin)
                    .overlay(Capsule().strokeBorder(ResoniqColor.line, lineWidth: Metrics.actionOutline))
                    .contentShape(Capsule())
            }
            .buttonStyle(ChipPressStyle())
        case .detected:
            Text(title)
                .font(Metrics.detectedFont)
                .foregroundStyle(ResoniqColor.ivory)
                .lineLimit(1)
                .padding(.horizontal, Metrics.overlayPadding)
                .frame(minHeight: Metrics.detectedHeight)
                .background(Capsule().fill(ResoniqColor.ink))
        case .measurement:
            Text(title)
                .font(Metrics.measurementFont)
                .foregroundStyle(ResoniqColor.ink)
                .lineLimit(1)
                .padding(.horizontal, Metrics.overlayPadding)
                .frame(minHeight: Metrics.measurementHeight)
                .background(Capsule().fill(ResoniqColor.guide))
        }
    }

    private enum Metrics {
        static let actionFont = ResoniqFont.font(.sansMedium, size: 14, relativeTo: .callout)
        static let actionPadding: CGFloat = 14
        static let actionOutline: CGFloat = 1.5
        static let detectedFont = ResoniqFont.font(.sansMedium, size: 12, relativeTo: .caption)
        static let detectedHeight: CGFloat = 24
        static let measurementFont = ResoniqFont.font(.monoMedium, size: 13, relativeTo: .caption)
        static let measurementHeight: CGFloat = 26
        static let overlayPadding: CGFloat = 10
    }
}

private struct ChipPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? ResoniqMotion.pressedScale : 1)
            .animation(reduceMotion ? nil : ResoniqMotion.press, value: configuration.isPressed)
    }
}

#if DEBUG
#Preview("Chips") {
    VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
        HStack(spacing: ResoniqSpace.s2) {
            ResoniqChip("Add subwoofer") {}
            ResoniqChip("Add a seat") {}
            ResoniqChip("Fix a wall") {}
        }
        HStack(spacing: ResoniqSpace.s2) {
            ResoniqChip("Window", style: .detected)
            ResoniqChip("Door", style: .detected)
            ResoniqChip("Sofa", style: .detected)
            ResoniqChip("4.20 m", style: .measurement)
        }
        .padding(ResoniqSpace.s3)
        .background(ResoniqColor.panelRaised)
    }
    .padding(ResoniqSpace.screenInset)
    .background(ResoniqColor.ink)
}
#endif
