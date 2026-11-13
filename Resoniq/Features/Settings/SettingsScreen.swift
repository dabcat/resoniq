import ResoniqDesign
import ResoniqStore
import SwiftData
import SwiftUI

/// Settings (no mockup; built from design/DESIGN_SYSTEM.md): what is kept on this iPhone and how to delete it, how the
/// test sound and the microphone should be understood, the intro, and the app's version and licences.
///
/// Reads the store from the environment (`\.resoniqStore`) and its counts live with `@Query`.
struct SettingsScreen: View {
    var onClose: () -> Void
    /// Where "Show the intro again" writes.
    var introGate = IntroGate()

    @Environment(\.resoniqStore) private var store
    @Query private var rooms: [Room]
    @Query private var systems: [SoundSystem]
    @Query private var tests: [SpeakerTest]
    @Query private var measurements: [SeatMeasurement]

    @State private var confirming: Deletion?
    @State private var failed = false
    @State private var introScheduled = false
    @State private var showsLicences = false

    private enum Deletion: Identifiable {
        case results
        case everything
        var id: Self { self }
    }

    private var counts: StoreCounts {
        StoreCounts(
            rooms: rooms.count, systems: systems.count, speakerTests: tests.count,
            seatMeasurements: measurements.count, roomScans: rooms.filter { $0.scanFileName != nil }.count
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                header
                dataSection
                measurementSection
                introSection
                aboutSection
            }
            .padding(.horizontal, ResoniqSpace.screenInset)
            .padding(.top, ResoniqSpace.s2)
            .padding(.bottom, ResoniqSpace.s6)
        }
        .scrollIndicators(.hidden)
        .background(ResoniqColor.ink)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            confirming == .everything ? SettingsText.deleteEverythingTitle : SettingsText.deleteResultsTitle,
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { deletion in
            Button(
                deletion == .everything ? SettingsText.deleteEverythingConfirm : SettingsText.deleteResultsConfirm,
                role: .destructive
            ) { delete(deletion) }
            Button(SettingsText.cancel, role: .cancel) {}
        } message: { deletion in
            Text(
                deletion == .everything
                    ? SettingsText.deleteEverythingMessage(counts) : SettingsText.deleteResultsMessage(counts)
            )
        }
        .alert(SettingsText.failureTitle, isPresented: $failed) {
            Button(SettingsText.ok, role: .cancel) {}
        } message: {
            Text(SettingsText.failureMessage)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(SettingsText.title)
                .resoniqTitle(.medium)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button(SettingsText.done, action: onClose)
                .buttonStyle(ResoniqTextLinkStyle())
        }
        .frame(minHeight: ResoniqSize.touchMin)
    }

    // MARK: Your data

    private var dataSection: some View {
        SettingsSection(SettingsText.dataLabel) {
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                Text(SettingsText.dataIntro).bodyText()
                VStack(spacing: 0) {
                    CountRow(label: SettingsText.rooms, value: counts.rooms)
                    CountRow(label: SettingsText.systems, value: counts.systems)
                    CountRow(label: SettingsText.speakerTests, value: counts.speakerTests)
                    CountRow(label: SettingsText.seatMeasurements, value: counts.seatMeasurements)
                    CountRow(label: SettingsText.roomScans, value: counts.roomScans, isLast: true)
                }
                Text(SettingsText.privacy).bodyText(colour: ResoniqColor.muted)
                VStack(spacing: Metrics.buttonGap) {
                    // The same outlined button twice (a filled one is the panel's own colour here and reads as a
                    // heading); the one with nothing to delete is dimmed and the line under the pair says why.
                    Button(SettingsText.deleteResults) { confirming = .results }
                        .buttonStyle(ResoniqSecondaryButtonStyle(.outlined))
                        .disabled(counts.results == 0)
                        .opacity(counts.results == 0 ? Metrics.disabledOpacity : 1)
                    Button(SettingsText.deleteEverything) { confirming = .everything }
                        .buttonStyle(ResoniqSecondaryButtonStyle(.outlined))
                    if counts.results == 0 {
                        Text(SettingsText.noResults).font(ResoniqFont.caption).foregroundStyle(ResoniqColor.muted)
                    }
                }
            }
        }
    }

    private func delete(_ deletion: Deletion) {
        do {
            switch deletion {
            case .results: try store?.deleteAllResults()
            case .everything: try store?.deleteEverything()
            }
        } catch {
            failed = true
        }
    }

    // MARK: Measurement

    private var measurementSection: some View {
        SettingsSection(SettingsText.measurementLabel) {
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                Text(SettingsText.testSound).bodyText()
                Text(SettingsText.microphone).bodyText()
            }
        }
    }

    // MARK: Intro

    private var introSection: some View {
        SettingsSection(SettingsText.introLabel) {
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                Button(SettingsText.showIntro) {
                    introGate.reset()
                    introScheduled = true
                }
                .buttonStyle(ResoniqInlineLinkStyle())
                if introScheduled {
                    Text(SettingsText.introScheduled).bodyText(colour: ResoniqColor.muted)
                }
            }
        }
    }

    // MARK: About

    private var aboutSection: some View {
        SettingsSection(SettingsText.aboutLabel) {
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                Text(SettingsText.appName).font(ResoniqFont.rowTitle).foregroundStyle(ResoniqColor.ivory)
                Text(Self.versionLine).font(ResoniqFont.figure).foregroundStyle(ResoniqColor.muted)
                Button(SettingsText.licences) { showsLicences.toggle() }
                    .buttonStyle(ResoniqInlineLinkStyle())
                    .accessibilityValue(showsLicences ? "Expanded" : "Collapsed")
                if showsLicences {
                    Text(SettingsText.licencesIntro).bodyText(colour: ResoniqColor.muted)
                    ForEach(ResoniqFont.licences()) { licence in
                        VStack(alignment: .leading, spacing: Metrics.labelGap) {
                            Text(licence.family).font(ResoniqFont.bodyMedium).foregroundStyle(ResoniqColor.ivory)
                            Text(licence.copyright).font(ResoniqFont.caption).foregroundStyle(ResoniqColor.muted)
                            Text(licence.text)
                                .font(ResoniqFont.axis)
                                .foregroundStyle(ResoniqColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private static var versionLine: String {
        let info = Bundle.main.infoDictionary
        return SettingsText.version(
            info?["CFBundleShortVersionString"] as? String ?? "0",
            build: info?["CFBundleVersion"] as? String ?? "0"
        )
    }

    private enum Metrics {
        static let sectionGap: CGFloat = 24
        static let rowGap: CGFloat = 12
        static let buttonGap: CGFloat = 8
        static let labelGap: CGFloat = 4
        static let disabledOpacity: Double = 0.4
    }
}

// MARK: - Pieces

/// A caps label above a panel.
private struct SettingsSection<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            Text(label)
                .resoniqCapsLabel()
                .accessibilityAddTraits(.isHeader)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .resoniqPanel()
        }
    }
}

/// A count in the data list: the name on the left, the figure on the right.
private struct CountRow: View {
    let label: String
    let value: Int
    var isLast = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(ResoniqFont.body).foregroundStyle(ResoniqColor.ivory)
            Spacer(minLength: ResoniqSpace.s3)
            Text(value, format: .number).font(ResoniqFont.figure).foregroundStyle(ResoniqColor.ivory)
        }
        .padding(.vertical, ResoniqSpace.s2)
        .overlay(alignment: .bottom) {
            if !isLast { Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline) }
        }
        .accessibilityElement(children: .combine)
    }
}

private extension Text {
    func bodyText(colour: Color = ResoniqColor.ivory) -> some View {
        font(ResoniqFont.body)
            .foregroundStyle(colour)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Settings, empty store") {
    let store = roomsPreviewStore(seeded: false)
    SettingsScreen(onClose: {})
        .environment(\.resoniqStore, store)
        .modelContainer(store.container)
}

#Preview("Settings, rooms and systems") {
    let store = roomsPreviewStore(seeded: true)
    SettingsScreen(onClose: {})
        .environment(\.resoniqStore, store)
        .modelContainer(store.container)
}

#Preview("Settings, largest text") {
    let store = roomsPreviewStore(seeded: true)
    SettingsScreen(onClose: {})
        .environment(\.resoniqStore, store)
        .modelContainer(store.container)
        .dynamicTypeSize(.accessibility2)
}
#endif
