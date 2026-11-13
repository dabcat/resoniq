import CoreGraphics
import Testing
@testable import ResoniqDesign

@Suite struct IconTests {
    /// The paths are copied from the mockups' SVG; a typo in a coordinate shows up as a path outside its view box.
    @Test(arguments: ResoniqIcon.allCases)
    func `icon is drawn inside its view box`(icon: ResoniqIcon) {
        let box = CGRect(x: 0, y: 0, width: icon.viewBox, height: icon.viewBox)
        #expect(!icon.layers.isEmpty)
        for layer in icon.layers {
            #expect(!layer.path.isEmpty)
            #expect(box.contains(layer.path.boundingRect))
        }
    }
}
