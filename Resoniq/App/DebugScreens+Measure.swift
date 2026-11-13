#if DEBUG
import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

/// The Measure screens with fixture data, for looking at them in the simulator. The launch argument
/// `-screen <name>` shows one; the names are listed in `names`. Debug builds only.
///
/// `sit-and-aim`, `three-spots` (the seat done, the phone on its way to the left spot, one trace in),
/// `three-spots-paused` and `live` (the live spectrum on simulated audio) are fixed states. `measure-flow` is the
/// real Measure tab on an in-memory store with simulated audio, already inside the flow; `-autostart YES` presses
/// "I'm seated, start" a second after Sit and aim appears, and `-simulatedNoise YES` adds a burst of noise that
/// pauses the seat spot.
enum MeasureDebugScreens {
    static let names = [
        "measure", "measure-even", "measure-empty", "measure-inconclusive",
        "compare-pick", "compare", "numbers", "numbers-distortion", "numbers-decay",
        "sit-and-aim", "three-spots", "three-spots-paused", "live", "measure-flow",
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
        case "compare-pick":
            AnyView(
                EarlierMeasurementsScreen(
                    earlier: [
                        KeptSeat(report: MeasureFixtures.mockup, date: .now.addingTimeInterval(-3 * 86_400)),
                        KeptSeat(report: MeasureFixtures.even, date: .now.addingTimeInterval(-12 * 86_400)),
                    ],
                    onPick: { _ in }, onClose: {}
                )
                .preferredColorScheme(.dark)
            )
        case "compare":
            AnyView(CompareHost())
        case "numbers":
            AnyView(NumbersScreen(report: MeasureFixtures.mockup, date: .now, onClose: {}))
        case "numbers-distortion":
            AnyView(NumbersScreen(report: MeasureFixtures.mockup, date: .now, onClose: {}, segment: .distortion))
        case "numbers-decay":
            AnyView(NumbersScreen(report: MeasureFixtures.mockup, date: .now, onClose: {}, segment: .decay))
        case "sit-and-aim":
            AnyView(SitAndAimScreen(room: "Living room", onStart: {}, onBack: {}, onExternal: {}).preferredColorScheme(.dark))
        case "three-spots":
            AnyView(ThreeSpotsScreen(display: .previewMoving, onStop: {}, onSkip: {}).preferredColorScheme(.dark))
        case "three-spots-paused":
            AnyView(SeatPausedScreen(display: .previewPaused, onStop: {}).preferredColorScheme(.dark))
        case "live":
            AnyView(LiveHost())
        case "measure-flow":
            AnyView(MeasureFlowHost())
        default:
            nil
        }
    }

    /// The mockup's room three days ago against an even room today, compared by the Kit.
    private struct CompareHost: View {
        private let earlier = KeptSeat(report: MeasureFixtures.mockup, date: .now.addingTimeInterval(-3 * 86_400))
        private let latest = KeptSeat(report: MeasureFixtures.even, date: .now)

        var body: some View {
            ComparisonScreen(
                comparison: SeatComparison.compare(
                    before: earlier.report, after: latest.report, targeting: earlier.report.extremes
                ),
                earlier: earlier, latest: latest, onClose: {}
            )
            .preferredColorScheme(.dark)
        }
    }

    /// The live spectrum on simulated audio.
    private struct LiveHost: View {
        @State private var model = LiveSpectrumModel(audio: .simulated())

        var body: some View {
            LiveSpectrumScreen(model: model, onClose: {})
                .preferredColorScheme(.dark)
        }
    }

    /// The real Measure tab on an in-memory store and simulated audio, already inside the flow.
    private struct MeasureFlowHost: View {
        @State private var composition = AppComposition.launch(
            inMemory: true, audio: .simulated(noise: UserDefaults.standard.bool(forKey: "simulatedNoise"))
        )
        @State private var tab = AppTab.measure

        var body: some View {
            if let composition {
                VStack(spacing: 0) {
                    MeasureTab()
                    ResoniqTabBar(AppTab.allCases.map(\.item), selection: $tab)
                }
                .background(ResoniqColor.ink)
                .appEnvironment(composition)
                .preferredColorScheme(.dark)
                .task { composition.measure.startMeasurement() }
            } else {
                StoreUnavailableScreen()
            }
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
