import SwiftUI

/// Instrument panel: the container for one visualisation or one group of readings.
public struct ResoniqPanel: ViewModifier {
    private let insets: EdgeInsets?

    /// - Parameter insets: Padding when the mockup's differs from `ResoniqSpace.panelPadding` on every side
    ///   (V3Listening's portrait panel is 16 / 12 / 16 / 8).
    public init(insets: EdgeInsets? = nil) {
        self.insets = insets
    }

    public func body(content: Content) -> some View {
        content
            .padding(insets ?? EdgeInsets(top: ResoniqSpace.panelPadding, leading: ResoniqSpace.panelPadding, bottom: ResoniqSpace.panelPadding, trailing: ResoniqSpace.panelPadding))
            .background(ResoniqColor.panel, in: RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous)
                    .strokeBorder(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline)
            )
    }
}

public extension View {
    func resoniqPanel() -> some View { modifier(ResoniqPanel()) }

    /// A panel with its own padding.
    func resoniqPanel(insets: EdgeInsets) -> some View { modifier(ResoniqPanel(insets: insets)) }
}
