import Foundation

/// The licence of one bundled typeface, for the About section of Settings.
public struct ResoniqFontLicence: Sendable, Equatable, Identifiable {
    public var id: String { family }
    /// "Instrument Sans".
    public let family: String
    /// The copyright line, the first line of the licence file.
    public let copyright: String
    /// The whole licence file.
    public let text: String
}

public extension ResoniqFont {
    /// The licences of the bundled fonts (SIL Open Font License 1.1), read from the files next to the fonts.
    /// A licence file that cannot be read is left out, so a missing file is caught by the design module's test.
    static func licences() -> [ResoniqFontLicence] {
        ["InstrumentSans-OFL", "IBMPlexMono-OFL"].compactMap { name in
            guard let url = resourceBundle.url(forResource: name, withExtension: "txt"),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            let family = name.hasPrefix("Instrument") ? Face.sansRegular.family : Face.monoRegular.family
            let copyright = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return ResoniqFontLicence(family: family, copyright: copyright, text: text)
        }
    }
}
