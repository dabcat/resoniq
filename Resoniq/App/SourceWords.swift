import ResoniqDesign
import ResoniqDiagnostics
import ResoniqStore
import SwiftUI

/// The words for two measurements that were not taken the same way: one from a test sound file played on another
/// device, the other played by the phone. Both are valid; a reader comparing them should know. The sentence for the
/// device is the Kit's (`DiagnosisText.sourceNote`); the two lines here have no Kit counterpart and are listed in the
/// pull request so they can move there.
enum SourceWords {
    /// "These two were measured in different ways."
    static let differently = "These two were measured in different ways."

    /// What a measurement with no source says about itself: the phone played the sound.
    static let byThisPhone = "Measured with the sound played by this iPhone."

    /// "The left speaker", for the line that says how that speaker was measured.
    static func speaker(_ position: SpeakerPosition) -> String {
        let name = position.speakerInSentence
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// "Earlier: Measured from a test sound played on another device."
    static func line(_ name: String, _ source: SoundSource?) -> String {
        "\(name): \(DiagnosisText.sourceNote(source) ?? byThisPhone)"
    }

    /// The quiet lines to show under two measurements being compared: nothing when they were taken the same way,
    /// otherwise that they differ and how each was taken, in the order given.
    static func lines(
        _ first: (name: String, source: SoundSource?), _ second: (name: String, source: SoundSource?)
    ) -> [String] {
        guard first.source != second.source else { return [] }
        return [differently, line(first.name, first.source), line(second.name, second.source)]
    }
}

/// The lines of `SourceWords` as quiet captions, one under the other; nothing when there are none.
struct SourceCaptions: View {
    let lines: [String]

    var body: some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(ResoniqFont.caption)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}
