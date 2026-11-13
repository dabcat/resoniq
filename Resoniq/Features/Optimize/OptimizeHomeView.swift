import ResoniqDesign
import ResoniqDiagnostics
import ResoniqRoom
import ResoniqStore
import SwiftData
import SwiftUI

/// A plan and the sentence that says what it shows.
struct OptimizePlan: Equatable {
    var content: RoomPlanContent
    /// For VoiceOver: the layout in words, and the suggestion when there is one.
    var summary: String
}

/// The situations the Optimize home can be in, each with exactly what it shows. `OptimizeHomeState.make` (in
/// `RoomDisplay.swift`) picks one from what the store holds.
enum OptimizeHomeState: Equatable {
    /// No room yet. There is no mockup for it: the tracker with nothing done and one sentence on what scanning gives.
    case noRoom(tracker: RoomDisplay.Tracker)
    /// A room with a layout and no measurement made in it.
    case notMeasured(tracker: RoomDisplay.Tracker, headline: String, plan: OptimizePlan)
    /// Measured, with a suggestion (the mockup). `basis` says so when the suggestion rests on the room's shape alone.
    case suggestion(tracker: RoomDisplay.Tracker, headline: String, basis: String?, plan: OptimizePlan)
    /// Measured, and the Kit has nothing to suggest: what it says is the headline, with any further sentences.
    case nothingToSuggest(tracker: RoomDisplay.Tracker, headline: String, notes: [String], plan: OptimizePlan)
    /// The speaker was moved; waiting for the second measurement.
    case moved(tracker: RoomDisplay.Tracker, headline: String, plan: OptimizePlan)
    /// Measured again and compared: the headline is the comparison's verdict, and "See before and after" opens it.
    case verified(tracker: RoomDisplay.Tracker, headline: String, plan: OptimizePlan)
}

/// Optimize home (design/screens/V3Optimize.dc.html): the tracker, the suggestion as the headline, the room plan
/// with the measured spots, the problem area and the dashed suggested outline, the legend, "Edit layout", and the
/// ways forward. The switcher is flipped here because the room is the subject.
///
/// The view takes a plain state and closures. It decides nothing: the headline, the plan and the legend's entries
/// come with the state. A suggestion is always drawn dashed and labelled "Suggested, not yet tested" (fill and dash
/// as well as colour); improvement is claimed only on the Before and after screen, from a second measurement.
///
/// States without a mockup (no room yet, a room not measured, nothing to suggest, moved, verified) follow
/// design/DESIGN_SYSTEM.md: the same frame, the same plan and the same buttons.
struct OptimizeHomeView: View {
    var context: ListeningContext = .placeholder
    let state: OptimizeHomeState
    let onScan: () -> Void
    let onManualEntry: () -> Void
    let onEditLayout: () -> Void
    let onMeasure: () -> Void
    let onGuideInAR: () -> Void
    let onMoveMyself: () -> Void
    let onShowVerification: () -> Void
    let onRescan: () -> Void

    init(
        context: ListeningContext = .placeholder,
        state: OptimizeHomeState,
        onScan: @escaping () -> Void,
        onManualEntry: @escaping () -> Void,
        onEditLayout: @escaping () -> Void,
        onMeasure: @escaping () -> Void,
        onGuideInAR: @escaping () -> Void,
        onMoveMyself: @escaping () -> Void,
        onShowVerification: @escaping () -> Void,
        onRescan: @escaping () -> Void
    ) {
        self.context = context
        self.state = state
        self.onScan = onScan
        self.onManualEntry = onManualEntry
        self.onEditLayout = onEditLayout
        self.onMeasure = onMeasure
        self.onGuideInAR = onGuideInAR
        self.onMoveMyself = onMoveMyself
        self.onShowVerification = onShowVerification
        self.onRescan = onRescan
    }

    /// What one state shows, so the body reads straight through.
    private struct Page {
        var tracker: RoomDisplay.Tracker
        var headline: String
        var basis: String?
        var plan: OptimizePlan?
        var notes: [String] = []
        var legend: Legend = .none
        var animatesSuggestion = false
        var primary: (title: String, action: () -> Void)
        var link: (title: String, action: () -> Void)?
    }

    private enum Legend { case none, measured, measuredAndSuggested }

    private var page: Page {
        switch state {
        case .noRoom(let tracker):
            Page(
                tracker: tracker, headline: OptimizeText.noRoomHeadline, plan: nil,
                primary: (OptimizeText.scanMyRoom, onScan), link: (OptimizeText.enterByHand, onManualEntry))
        case .notMeasured(let tracker, let headline, let plan):
            Page(
                tracker: tracker, headline: headline, plan: plan, primary: (OptimizeText.measureFromSeat, onMeasure))
        case .suggestion(let tracker, let headline, let basis, let plan):
            Page(
                tracker: tracker, headline: headline, basis: basis, plan: plan, legend: .measuredAndSuggested,
                animatesSuggestion: true, primary: (OptimizeText.guideInAR, onGuideInAR),
                link: (OptimizeText.moveMyself, onMoveMyself))
        case .nothingToSuggest(let tracker, let headline, let notes, let plan):
            Page(
                tracker: tracker, headline: headline, plan: plan, notes: notes,
                legend: plan.content.measuredSpots.isEmpty ? .none : .measured,
                primary: (OptimizeText.measureAgain, onMeasure))
        case .moved(let tracker, let headline, let plan):
            Page(
                tracker: tracker, headline: headline, plan: plan, legend: .measured,
                primary: (OptimizeText.measureAgainFromSeat, onMeasure))
        case .verified(let tracker, let headline, let plan):
            Page(
                tracker: tracker, headline: headline, plan: plan, legend: .measured,
                primary: (OptimizeText.showVerification, onShowVerification))
        }
    }

    private var hasRoom: Bool {
        if case .noRoom = state { return false }
        return true
    }

    var body: some View {
        let page = page
        TabHome(context: context, switcherOrder: .systemOverRoom) {
            if hasRoom {
                Button(OptimizeText.rescan, action: onRescan)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        } content: {
            VStack(spacing: ResoniqSpace.panelPadding) {
                ScrollView {
                    VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
                        ResoniqProgressTracker(steps: page.tracker.steps, current: page.tracker.current)
                        Text(page.headline)
                            .resoniqTitle(.small)
                            .accessibilityAddTraits(.isHeader)
                        if let basis = page.basis {
                            Text(basis)
                                .font(ResoniqFont.caption)
                                .foregroundStyle(ResoniqColor.muted)
                        }
                        if let plan = page.plan {
                            planPanel(plan, animates: page.animatesSuggestion)
                            legend(page.legend)
                        }
                        ForEach(page.notes, id: \.self) { note in
                            Text(note)
                                .font(ResoniqFont.body)
                                .foregroundStyle(ResoniqColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)

                VStack(spacing: 0) {
                    Button(page.primary.title, action: page.primary.action)
                        .buttonStyle(ResoniqPrimaryButtonStyle())
                    if let link = page.link {
                        Button(link.title, action: link.action)
                            .buttonStyle(ResoniqTextLinkStyle())
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    /// The plan with "Edit layout" inside it at the bottom right, as in the mockup.
    private func planPanel(_ plan: OptimizePlan, animates: Bool) -> some View {
        RoomPlanView(
            plan.content, isSuggestionAnimating: animates, showsLegend: false, height: Metrics.planHeight,
            accessibilityLabel: plan.summary
        )
        .overlay(alignment: .bottomTrailing) {
            Button(OptimizeText.editLayout, action: onEditLayout)
                .buttonStyle(ResoniqInlineLinkStyle(.quiet))
                .padding(.trailing, ResoniqSpace.s3)
        }
    }

    @ViewBuilder
    private func legend(_ legend: Legend) -> some View {
        switch legend {
        case .none: EmptyView()
        case .measured: RoomPlanLegend(measured: RoomText.legendMeasured, suggested: nil)
        case .measuredAndSuggested: RoomPlanLegend(measured: RoomText.legendMeasured, suggested: RoomText.legendSuggested)
        }
    }

    private enum Metrics {
        /// V3Optimize's plan panel is 322 pt tall.
        static let planHeight: CGFloat = 322
    }
}

// MARK: - From the store

/// The Optimize home for the selected sound system, read from the store: its room's layout, its latest seat
/// measurement, its current optimisation and the tracker's progress. The state is built by `OptimizeHomeState.make`;
/// what the suggestion is comes from the Kit's advisor.
///
/// The closures that start something are the caller's. The two that act on a suggestion get it, so the caller can
/// begin the optimisation from exactly what was shown.
struct OptimizeHomeContainer: View {
    let onScan: () -> Void
    let onManualEntry: () -> Void
    let onEditLayout: () -> Void
    let onMeasure: () -> Void
    let onGuideInAR: (PlacementSuggestion) -> Void
    let onMoveMyself: (PlacementSuggestion) -> Void
    let onShowVerification: () -> Void
    let onRescan: () -> Void

    @Environment(\.resoniqStore) private var store
    @Query private var states: [StoreState]
    @Query(sort: \Room.createdAt) private var rooms: [Room]
    // Not read directly: a new measurement or optimisation redraws the screen.
    @Query private var measurements: [SeatMeasurement]
    @Query private var optimizations: [Optimization]

    private var system: SoundSystem? {
        states.first?.selectedSystem ?? rooms.lazy.compactMap { $0.orderedSystems.first }.first
    }

    var body: some View {
        let system = system
        let context = system.map { ListeningContext(room: $0.room?.name ?? StoreText.defaultRoomName, system: $0.name) }
            ?? ListeningContext(room: StoreText.defaultRoomName, system: StoreText.defaultSystemName)
        let made = OptimizeHomeState.make(input(for: system))
        OptimizeHomeView(
            context: context, state: made.state,
            onScan: onScan, onManualEntry: onManualEntry, onEditLayout: onEditLayout, onMeasure: onMeasure,
            onGuideInAR: { if let suggestion = made.suggestion { onGuideInAR(suggestion) } },
            onMoveMyself: { if let suggestion = made.suggestion { onMoveMyself(suggestion) } },
            onShowVerification: onShowVerification, onRescan: onRescan
        )
    }

    private func input(for system: SoundSystem?) -> OptimizeHomeInput {
        guard let store, let system else { return OptimizeHomeInput(layout: nil, seat: nil, progress: OptimizeProgress()) }
        let progress = store.progress(in: system)
        let layout = system.room.flatMap { (try? store.layout(of: $0)) ?? nil }
        return OptimizeHomeInput(
            layout: layout,
            // A measurement made in another layout is not this room's.
            seat: progress.measured ? store.latestSeatMeasurement(in: system)?.report : nil,
            progress: progress,
            comparison: store.currentOptimization(in: system)?.comparison)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Measured, with a suggestion") {
    OptimizeHomeView(
        state: OptimizeFixtures.homeSuggestion, onScan: {}, onManualEntry: {}, onEditLayout: {}, onMeasure: {},
        onGuideInAR: {}, onMoveMyself: {}, onShowVerification: {}, onRescan: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("No room yet") {
    OptimizeHomeView(
        state: OptimizeFixtures.homeNoRoom, onScan: {}, onManualEntry: {}, onEditLayout: {}, onMeasure: {},
        onGuideInAR: {}, onMoveMyself: {}, onShowVerification: {}, onRescan: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Room, not measured") {
    OptimizeHomeView(
        state: OptimizeFixtures.homeNotMeasured, onScan: {}, onManualEntry: {}, onEditLayout: {}, onMeasure: {},
        onGuideInAR: {}, onMoveMyself: {}, onShowVerification: {}, onRescan: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Nothing to suggest") {
    OptimizeHomeView(
        state: OptimizeFixtures.homeNothing, onScan: {}, onManualEntry: {}, onEditLayout: {}, onMeasure: {},
        onGuideInAR: {}, onMoveMyself: {}, onShowVerification: {}, onRescan: {}
    )
    .preferredColorScheme(.dark)
}

#Preview("Moved, largest text") {
    OptimizeHomeView(
        state: OptimizeFixtures.homeMoved, onScan: {}, onManualEntry: {}, onEditLayout: {}, onMeasure: {},
        onGuideInAR: {}, onMoveMyself: {}, onShowVerification: {}, onRescan: {}
    )
    .environment(\.dynamicTypeSize, .accessibility2)
    .preferredColorScheme(.dark)
}
#endif
