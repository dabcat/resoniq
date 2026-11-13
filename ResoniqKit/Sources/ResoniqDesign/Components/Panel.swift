import SwiftUI

/// Instrument panel: the container for one visualisation or one group of readings.
public struct ResoniqPanel: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .padding(ResoniqSpace.panelPadding)
            .background(ResoniqColor.panel, in: RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ResoniqRadius.panel, style: .continuous)
                    .strokeBorder(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline)
            )
    }
}

public extension View {
    func resoniqPanel() -> some View { modifier(ResoniqPanel()) }
}
