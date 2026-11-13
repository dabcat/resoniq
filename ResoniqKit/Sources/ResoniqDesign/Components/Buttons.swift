import SwiftUI

private extension View {
    /// Touch feedback shared by every button style: scale to 0.97 with the press spring.
    func resoniqPressFeedback(_ isPressed: Bool) -> some View {
        scaleEffect(isPressed ? ResoniqMotion.pressedScale : 1)
            .animation(ResoniqMotion.press, value: isPressed)
    }
}

/// The one primary action on a screen: `lime` pill, `ink` label.
public struct ResoniqPrimaryButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ResoniqFont.button)
            .foregroundStyle(ResoniqColor.onAction)
            .frame(maxWidth: .infinity, minHeight: ResoniqSize.buttonHeight)
            .background(ResoniqColor.action, in: Capsule())
            .contentShape(Capsule())
            .resoniqPressFeedback(configuration.isPressed)
    }
}

/// A second action: `panel` pill with an `ivory` label, or an outlined pill for a passive state
/// ("Waiting for quiet, then I continue").
public struct ResoniqSecondaryButtonStyle: ButtonStyle {
    public enum Kind: Sendable {
        case filled
        case outlined
    }

    private let kind: Kind

    public init(_ kind: Kind = .filled) {
        self.kind = kind
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ResoniqFont.button)
            .foregroundStyle(ResoniqColor.ivory)
            .frame(maxWidth: .infinity, minHeight: ResoniqSize.buttonHeight)
            .background {
                switch kind {
                case .filled:
                    Capsule().fill(ResoniqColor.panel)
                case .outlined:
                    Capsule().strokeBorder(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline)
                }
            }
            .contentShape(Capsule())
            .resoniqPressFeedback(configuration.isPressed)
    }
}

/// The quieter alternative under a primary button: `muted`, underlined, 44 pt hit area.
public struct ResoniqTextLinkStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ResoniqFont.body)
            .underline()
            .foregroundStyle(configuration.isPressed ? ResoniqColor.ivory : ResoniqColor.muted)
            .frame(minHeight: ResoniqSize.touchMin)
            .contentShape(Rectangle())
    }
}

/// A 44 pt circle holding one icon. Label the button for VoiceOver where it is used.
public struct ResoniqIconButtonStyle: ButtonStyle {
    public enum Surface: Sendable {
        /// On the app background.
        case panel
        /// Over a camera image.
        case overCamera
    }

    private let surface: Surface

    public init(on surface: Surface = .panel) {
        self.surface = surface
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ResoniqColor.ivory)
            .frame(width: ResoniqSize.iconButton, height: ResoniqSize.iconButton)
            .background(surface == .panel ? ResoniqColor.panel : ResoniqColor.ink, in: Circle())
            .contentShape(Circle())
            .resoniqPressFeedback(configuration.isPressed)
    }
}
