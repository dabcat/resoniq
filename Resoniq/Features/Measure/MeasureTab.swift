import ResoniqDesign
import ResoniqDiagnostics
import SwiftUI

/// The Measure tab: home, The numbers pushed on its stack, and over it, without the tab bar, the full-screen cover that
/// holds a measurement or the live spectrum. `MeasureCoordinator` decides what is shown; this only lays it out.
struct MeasureTab: View {
    @Environment(MeasureCoordinator.self) private var coordinator
    @Environment(\.switchTab) private var switchTab

    var body: some View {
        @Bindable var coordinator = coordinator
        NavigationStack(path: $coordinator.path) {
            MeasureHomeContainer(
                unsaved: coordinator.unsaved,
                onMeasure: coordinator.startMeasurement,
                onShowNumbers: coordinator.showNumbers,
                onWatchLive: coordinator.watchLive,
                onCompare: coordinator.showEarlier,
                onOpenOptimize: { switchTab(.optimize) }
            )
            .toolbarVisibility(.hidden, for: .navigationBar)
            .navigationDestination(for: MeasureCoordinator.Route.self) { route in
                Group {
                    switch route {
                    case .numbers:
                        if let numbers = coordinator.numbers {
                            NumbersScreen(report: numbers.report, date: numbers.date, onClose: coordinator.closeNumbers)
                        }
                    case .earlier:
                        if let comparing = coordinator.comparing {
                            EarlierMeasurementsScreen(
                                earlier: comparing.earlier, onPick: coordinator.pickEarlier, onClose: coordinator.closeComparison
                            )
                        }
                    case .comparison:
                        if let comparing = coordinator.comparing, let picked = comparing.picked,
                           let comparison = comparing.comparison {
                            ComparisonScreen(
                                comparison: comparison, earlier: picked, latest: comparing.latest,
                                onClose: coordinator.closeComparison
                            )
                        }
                    }
                }
                .toolbarVisibility(.hidden, for: .navigationBar)
            }
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { coordinator.content != nil },
                set: { if !$0 { coordinator.close() } }
            ),
            onDismiss: coordinator.coverDismissed
        ) {
            MeasureCover()
        }
    }
}

// MARK: - The cover

private struct MeasureCover: View {
    @Environment(MeasureCoordinator.self) private var coordinator

    var body: some View {
        Group {
            switch coordinator.content {
            case .measurement(let flow):
                MeasurementRoot(flow: flow)
                    .id(coordinator.contentID)
            case .live(let model):
                LiveSpectrumScreen(model: model, onClose: coordinator.close)
                    .id(coordinator.contentID)
            case nil:
                // The cover is on its way out.
                ResoniqColor.ink.ignoresSafeArea()
            }
        }
        .background(ResoniqColor.ink)
        .preferredColorScheme(.dark)
    }
}

/// A measurement: the flow's screens, and a blank frame while it hands its report to the coordinator, which closes
/// the cover.
private struct MeasurementRoot: View {
    let flow: SeatFlow
    @Environment(MeasureCoordinator.self) private var coordinator

    var body: some View {
        SeatFlowView(flow: flow, room: coordinator.roomName, onClose: coordinator.close) { _ in
            ResoniqColor.ink.ignoresSafeArea()
        }
        .onChange(of: flow.step) { _, step in
            if case .finished(let report) = step { coordinator.measurementFinished(report, from: flow) }
        }
        // VoiceOver starts at the top of each new screen of the flow.
        .onChange(of: flow.step.screen) { old, new in
            if old == .paused, new == .running {
                AccessibilityNotification.Announcement("The room is quiet again. Carrying on.").post()
            } else {
                UIAccessibility.post(notification: .screenChanged, argument: nil)
            }
        }
        #if DEBUG
        .task(id: flow.step.screen) { await autostartIfAsked() }
        #endif
    }

    #if DEBUG
    /// `-autostart YES` presses "I'm seated, start" one second after Sit and aim appears, so an unattended launch runs
    /// a whole measurement to the end.
    private func autostartIfAsked() async {
        guard UserDefaults.standard.bool(forKey: "autostart"), case .guide = flow.step else { return }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, case .guide = flow.step else { return }
        flow.start()
    }
    #endif
}
