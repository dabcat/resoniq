#if DEBUG
import ResoniqDesign
import ResoniqDiagnostics
import ResoniqStore
import SwiftUI

/// The Result, Finding and Diagnose home screens with fixture data, for looking at them in the simulator.
/// The launch argument `-screen <name>` shows one; the names are listed in `names`. Debug builds only.
enum ResultsDebugScreens {
    static let names = [
        "result", "result-healthy", "result-inconclusive", "result-quiet-woofer", "result-not-assessed",
        "finding", "home", "home-empty", "home-single",
    ]

    /// The screen for `name`, or nil when the name is not one of `names`.
    @MainActor
    static func view(named name: String) -> AnyView? {
        switch name {
        case "result":
            AnyView(result(DiagnoseFixtures.buzzing, primary: "Now the right speaker", keptIn: Self.keptIn))
        case "result-healthy":
            AnyView(result(DiagnoseFixtures.healthy, primary: "Now the right speaker", keptIn: Self.keptIn))
        case "result-inconclusive":
            AnyView(result(DiagnoseFixtures.inconclusive, primary: "Try the left speaker again", keptIn: nil))
        case "result-quiet-woofer":
            AnyView(result(DiagnoseFixtures.quietWoofer, primary: "Now the right speaker", keptIn: Self.keptIn))
        case "result-not-assessed":
            AnyView(result(DiagnoseFixtures.notAssessed, primary: "Now the right speaker", keptIn: Self.keptIn))
        case "finding":
            AnyView(
                FindingScreen(
                    finding: DiagnoseFixtures.buzz, report: DiagnoseFixtures.buzzing, speaker: .left,
                    tone: SilentTonePlayer(), onClose: {}, onShowNumbers: {}
                )
            )
        case "home":
            AnyView(Home(summaries: [
                SpeakerSummary(position: .left, name: "Left", report: DiagnoseFixtures.buzzing),
                .notHeard(.right, name: "Right"),
            ], primaryTitle: "Listen to the right speaker"))
        case "home-empty":
            AnyView(Home(summaries: [
                .notHeard(.left, name: "Left"),
                .notHeard(.right, name: "Right"),
            ], primaryTitle: "Listen to the left speaker"))
        case "home-single":
            AnyView(Home(summaries: [
                SpeakerSummary(position: .single, name: "Soundbar", report: DiagnoseFixtures.healthy),
            ], primaryTitle: "Listen to the soundbar again"))
        default:
            nil
        }
    }

    private static let keptIn = KeptIn(room: "My room", system: "My speakers")

    private static func result(_ report: SpeakerReport, primary: String, keptIn: KeptIn?) -> some View {
        ResultScreen(
            report: report, speaker: .left, keptIn: keptIn, primaryTitle: primary,
            onPrimary: {}, onOpenFinding: { _ in }, onRename: {}, onDontKeep: {}, onClose: {}
        )
    }

    /// The home screen in the app's frame, with the tab bar, as it appears inside `RootView`.
    private struct Home: View {
        let summaries: [SpeakerSummary]
        let primaryTitle: String
        @State private var tab = AppTab.diagnose

        var body: some View {
            VStack(spacing: 0) {
                if summaries.count == 2 {
                    DiagnoseHomeView(
                        left: summaries[0], right: summaries[1], primaryTitle: primaryTitle,
                        onPrimary: {}, onOpenSpeaker: { _ in }, onQuickCheck: {}, onSettings: {}
                    )
                } else {
                    DiagnoseHomeView(
                        single: summaries[0], primaryTitle: primaryTitle,
                        onPrimary: {}, onOpenSpeaker: { _ in }, onQuickCheck: {}, onSettings: {}
                    )
                }
                ResoniqTabBar(AppTab.allCases.map(\.item), selection: $tab)
            }
            .background(ResoniqColor.ink)
        }
    }
}
#endif
