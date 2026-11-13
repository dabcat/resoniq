import CoreText
import Testing
@testable import ResoniqDesign

@Suite struct FontTests {
    @Test func `every bundled face registers`() {
        #expect(ResoniqFont.registerBundledFonts().isEmpty)
    }

    /// Core Text silently substitutes another font for an unknown name, so compare the name it resolved.
    @Test(arguments: ResoniqFont.Face.allCases)
    func `face resolves to its own font after registration`(face: ResoniqFont.Face) {
        ResoniqFont.registerBundledFonts()
        let font = CTFontCreateWithName(face.postScriptName as CFString, 12, nil)
        #expect(CTFontCopyPostScriptName(font) as String == face.postScriptName)
    }

    @Test(arguments: ResoniqFont.Face.allCases)
    func `face belongs to the family the design system names`(face: ResoniqFont.Face) {
        ResoniqFont.registerBundledFonts()
        let font = CTFontCreateWithName(face.postScriptName as CFString, 12, nil)
        #expect(CTFontCopyFamilyName(font) as String == face.family)
    }

    @Test func `both licences ship next to the fonts`() {
        for name in ["InstrumentSans-OFL", "IBMPlexMono-OFL"] {
            #expect(ResoniqFont.resourceBundle.url(forResource: name, withExtension: "txt") != nil)
        }
    }
}
