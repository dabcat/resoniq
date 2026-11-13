#if DEBUG
import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

/// The Measure result screens with fixture data, for looking at them in the simulator. The launch argument
/// `-screen <name>` shows one; the names are listed in `names`. Debug builds only.
enum MeasureDebugScreens {
    static let names = [
        "measure", "measure-even", "measure-empty", "measure-inconclusive",
        "numbers", "numbers-distortion", "numbers-decay",
    ]

    /// The screen for `name`, or nil when the name is not one of `names`.
    @MainActor
    static func view(named name: String) -> AnyView? {
        switch name {
        case "measure":
            AnyView(Home(report: MeasureFixtures.mockup, date: .now.addingTimeInterval(-3 * 86_400)))
        case "measure-even":
            AnyView(Home(report: MeasureFixtures.even, date: .now))
        case "measure-empty":
            AnyView(Home(report: nil, date: .now))
        case "measure-inconclusive":
            AnyView(Home(report: MeasureFixtures.inconclusive, date: .now))
        case "numbers":
            AnyView(NumbersScreen(report: MeasureFixtures.mockup, date: .now, onClose: {}))
        case "numbers-distortion":
            AnyView(NumbersScreen(report: MeasureFixtures.mockup, date: .now, onClose: {}, segment: .distortion))
        case "numbers-decay":
            AnyView(NumbersScreen(report: MeasureFixtures.mockup, date: .now, onClose: {}, segment: .decay))
        default:
            nil
        }
    }

    /// Measure home in the app's frame, with the tab bar, as it appears inside `RootView`.
    private struct Home: View {
        let report: SeatReport?
        let date: Date
        @State private var tab = AppTab.measure

        var body: some View {
            VStack(spacing: 0) {
                MeasureHomeView(
                    measurement: report.map { MeasureSummary(report: $0, date: date) },
                    primaryTitle: report == nil ? SeatWords.measureTitle : SeatWords.measureAgainTitle,
                    onPrimary: {}, onShowNumbers: {}, onWatchLive: {}, onOpenOptimize: {}
                )
                ResoniqTabBar(AppTab.allCases.map(\.item), selection: $tab)
            }
            .background(ResoniqColor.ink)
        }
    }
}
#endif
