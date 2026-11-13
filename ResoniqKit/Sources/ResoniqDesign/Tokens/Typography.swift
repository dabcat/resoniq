import CoreText
import SwiftUI

/// Type roles from design/tokens.json, set in the two bundled families (both SIL OFL).
///
/// The static faces are bundled instead of the variable font, and a role names its face by PostScript name,
/// so a weight never depends on how the system matches a family name to a face.
public enum ResoniqFont {
    public enum Face: String, CaseIterable, Sendable {
        case sansRegular = "InstrumentSans-Regular"
        case sansMedium = "InstrumentSans-Medium"
        case sansSemibold = "InstrumentSans-SemiBold"
        case sansBold = "InstrumentSans-Bold"
        case monoRegular = "IBMPlexMono-Regular"
        case monoMedium = "IBMPlexMono-Medium"

        /// Also the name of the font file in the module's resources.
        public var postScriptName: String { rawValue }

        public var family: String {
            switch self {
            case .sansRegular, .sansMedium, .sansSemibold, .sansBold: "Instrument Sans"
            case .monoRegular, .monoMedium: "IBM Plex Mono"
            }
        }
    }

    /// A bundled face that scales with Dynamic Type like `style` does.
    public static func font(_ face: Face, size: CGFloat, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(face.postScriptName, size: size, relativeTo: style)
    }

    public static let display = font(.sansSemibold, size: 36, relativeTo: .largeTitle)
    public static let title1 = font(.sansSemibold, size: 34, relativeTo: .largeTitle)
    public static let title2 = font(.sansSemibold, size: 30, relativeTo: .title)
    public static let title3 = font(.sansSemibold, size: 26, relativeTo: .title2)
    public static let headline = font(.sansSemibold, size: 21, relativeTo: .title3)
    public static let button = font(.sansSemibold, size: 18, relativeTo: .headline)
    public static let bodyLarge = font(.sansRegular, size: 16, relativeTo: .body)
    public static let body = font(.sansRegular, size: 15, relativeTo: .body)
    public static let caption = font(.sansRegular, size: 13, relativeTo: .caption)
    public static let tab = font(.sansMedium, size: 12, relativeTo: .caption2)
    public static let tabSelected = font(.sansBold, size: 12, relativeTo: .caption2)
    public static let capsLabel = font(.monoRegular, size: capsLabelSize, relativeTo: .caption2)
    public static let readoutLarge = font(.monoMedium, size: 46, relativeTo: .largeTitle)
    public static let readoutMedium = font(.monoMedium, size: 34, relativeTo: .title)
    public static let axis = font(.monoRegular, size: 11, relativeTo: .caption2)

    static let capsLabelSize: CGFloat = 11

    /// Tracking in em, as the tokens give it; multiply by the point size.
    public enum Tracking {
        public static let title: CGFloat = -0.03
        public static let readout: CGFloat = -0.05
        public static let capsLabel: CGFloat = 0.08
    }

    // MARK: Registration

    static var resourceBundle: Bundle { .module }

    /// Makes the bundled faces available to this process. Call once at launch, before the first view;
    /// calling again is free. Returns the faces that could not be registered (none, in a correct build).
    @discardableResult
    public static func registerBundledFonts() -> [Face] {
        unregisteredFaces
    }

    /// A static is initialised once, atomically, so registration is safe from any thread.
    private static let unregisteredFaces: [Face] = Face.allCases.filter { !register($0) }

    private static func register(_ face: Face) -> Bool {
        guard let url = resourceBundle.url(forResource: face.postScriptName, withExtension: "ttf") else {
            return false
        }
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return true }
        guard let error = error?.takeRetainedValue() else { return false }
        return CFErrorGetCode(error) == CTFontManagerError.alreadyRegistered.rawValue
    }
}

/// Panel and field label: mono, uppercase, wide tracking, `muted`.
public struct ResoniqCapsLabel: ViewModifier {
    public init() {}

    public func body(content: Content) -> some View {
        content
            .font(ResoniqFont.capsLabel)
            .tracking(ResoniqFont.capsLabelSize * ResoniqFont.Tracking.capsLabel)
            .textCase(.uppercase)
            .foregroundStyle(ResoniqColor.muted)
    }
}

public extension View {
    func resoniqCapsLabel() -> some View { modifier(ResoniqCapsLabel()) }
}
