import ResoniqDesign
import ResoniqShare
import ResoniqStore
import SwiftData
import SwiftUI

/// Settings (no mockup; built from design/DESIGN_SYSTEM.md): what is kept on this iPhone and how to delete it, whether
/// a kept test keeps its recordings (no mockup either: the same panel, rows and outlined button as "Your data"), how the
/// test sound and the microphone should be understood, the intro, and the app's version and licences. In a build with a
/// share URL, the Recordings panel also holds "Share recordings for research" (no mockup either: the same toggle, lines
/// and outlined button), whose consent is `ShareConsentSheet`.
///
/// Reads the store from the environment (`\.resoniqStore`) and its counts live with `@Query`.
struct SettingsScreen: View {
    var onClose: () -> Void
    /// Where "Show the intro again" writes.
    var introGate = IntroGate()
    /// Opens scrolled to the Recordings panel (debug screens, for screenshots of sharing).
    var startsAtRecordings = false

    @Environment(\.resoniqStore) private var store
    /// Sharing, in a build that has it.
    @Environment(\.shareModel) private var share
    @Query private var rooms: [Room]
    @Query private var systems: [SoundSystem]
    @Query private var tests: [SpeakerTest]
    @Query private var measurements: [SeatMeasurement]

    @State private var confirming: Deletion?
    @State private var failed = false
    @State private var introScheduled = false
    @State private var showsLicences = false
    @State private var showsTestSound = false
    /// "Keep recordings" (`RecordingPreference`), off by default.
    @AppStorage(RecordingPreference.key) private var keepsRecordings = false
    /// Bytes the kept recordings take; read when the screen opens and after a delete.
    @State private var recordingsSize: Int64 = 0
    @State private var showsConsent = false
    /// Turning sharing on turned "Keep recordings" on: said once, under the toggle.
    @State private var keepTurnedOn = false
    @State private var sharedDeleted = false
    @State private var shareDeleteFailed = false

    private static let recordingsID = "recordings"

    private enum Deletion: Identifiable {
        case results
        case everything
        case recordings
        case shared
        var id: Self { self }
    }

    private var counts: StoreCounts {
        StoreCounts(
            rooms: rooms.count, systems: systems.count, speakerTests: tests.count,
            seatMeasurements: measurements.count, roomScans: rooms.filter { $0.scanFileName != nil }.count,
            recordings: tests.filter { $0.recordingFileName != nil }.count
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    header
                    dataSection
                    recordingsSection.id(Self.recordingsID)
                    measurementSection
                    introSection
                    aboutSection
                }
                .padding(.horizontal, ResoniqSpace.screenInset)
                .padding(.top, ResoniqSpace.s2)
                .padding(.bottom, ResoniqSpace.s6)
            }
            .onAppear {
                if startsAtRecordings { proxy.scrollTo(Self.recordingsID, anchor: .top) }
            }
        }
        .scrollIndicators(.hidden)
        .background(ResoniqColor.ink)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            confirming.map(title) ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { deletion in
            Button(confirmLabel(deletion), role: .destructive) { delete(deletion) }
            Button(SettingsText.cancel, role: .cancel) {}
        } message: { deletion in
            Text(message(deletion))
        }
        .task { recordingsSize = store?.recordingsSize() ?? 0 }
        .fullScreenCover(isPresented: $showsTestSound) {
            TestSoundScreen(context: .everything, onContinue: nil, onClose: { showsTestSound = false })
                .preferredColorScheme(.dark)
        }
        .alert(SettingsText.failureTitle, isPresented: $failed) {
            Button(SettingsText.ok, role: .cancel) {}
        } message: {
            Text(SettingsText.failureMessage)
        }
        .alert(SettingsText.deleteSharedFailedTitle, isPresented: $shareDeleteFailed) {
            Button(SettingsText.ok, role: .cancel) {}
        } message: {
            Text(SettingsText.deleteSharedFailedMessage)
        }
        .sheet(isPresented: $showsConsent) {
            ShareConsentSheet(
                onCancel: { showsConsent = false },
                onConfirm: {
                    keepTurnedOn = !keepsRecordings
                    share?.confirmConsent()
                    showsConsent = false
                }
            )
        }
        // Sharing needs the recordings it sends: "Keep recordings" off turns it off.
        .onChange(of: keepsRecordings) { _, keeps in
            if !keeps, share?.isOn == true { share?.turnOff() }
            if !keeps { keepTurnedOn = false }
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
                Text(SettingsText.privacy(canShare: share != nil)).bodyText(colour: ResoniqColor.muted)
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

    private func title(_ deletion: Deletion) -> String {
        switch deletion {
        case .results: SettingsText.deleteResultsTitle
        case .everything: SettingsText.deleteEverythingTitle
        case .recordings: SettingsText.deleteRecordingsTitle
        case .shared: SettingsText.deleteSharedTitle
        }
    }

    private func confirmLabel(_ deletion: Deletion) -> String {
        switch deletion {
        case .results: SettingsText.deleteResultsConfirm
        case .everything: SettingsText.deleteEverythingConfirm
        case .recordings: SettingsText.deleteRecordingsConfirm
        case .shared: SettingsText.deleteSharedConfirm
        }
    }

    private func message(_ deletion: Deletion) -> String {
        switch deletion {
        case .results: SettingsText.deleteResultsMessage(counts)
        case .everything: SettingsText.deleteEverythingMessage(counts)
        case .recordings: SettingsText.deleteRecordingsMessage(counts)
        case .shared: SettingsText.deleteSharedMessage
        }
    }

    private func delete(_ deletion: Deletion) {
        do {
            switch deletion {
            case .results: try store?.deleteAllResults()
            case .everything: try store?.deleteEverything()
            case .recordings:
                try store?.deleteRecordings()
                share?.recordingsDeleted()
            case .shared:
                deleteShared()
            }
        } catch {
            failed = true
        }
        recordingsSize = store?.recordingsSize() ?? 0
    }

    /// "Delete what I shared": the service is asked; the line under the button says when it is done.
    private func deleteShared() {
        guard let share else { return }
        sharedDeleted = false
        Task {
            if await share.deleteShared() {
                sharedDeleted = true
            } else {
                shareDeleteFailed = true
            }
        }
    }

    // MARK: Recordings

    private var recordingsSection: some View {
        SettingsSection(SettingsText.recordingsLabel) {
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                Toggle(isOn: $keepsRecordings) {
                    Text(SettingsText.keepRecordings).font(ResoniqFont.body).foregroundStyle(ResoniqColor.ivory)
                }
                .tint(ResoniqColor.lime)
                .frame(minHeight: ResoniqSize.touchMin)
                Text(SettingsText.recordingsExplanation(canShare: share != nil)).bodyText(colour: ResoniqColor.muted)
                ValueRow(label: SettingsText.recordingsSpace, value: SettingsText.size(recordingsSize), isLast: true)
                Button(SettingsText.deleteRecordings) { confirming = .recordings }
                    .buttonStyle(ResoniqSecondaryButtonStyle(.outlined))
                    .disabled(!hasRecordings)
                    .opacity(hasRecordings ? 1 : Metrics.disabledOpacity)
                if let share { shareRows(share) }
            }
        }
    }

    // MARK: Sharing

    /// Under the recordings, after a hairline: the toggle (which opens the consent and never turns on by itself), what
    /// it does, the status, the old recordings on request, and "Delete what I shared", which works with sharing off.
    private func shareRows(_ share: ShareModel) -> some View {
        VStack(alignment: .leading, spacing: Metrics.rowGap) {
            Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline)
            Toggle(isOn: Binding(
                get: { share.isOn },
                set: { on in
                    if on {
                        showsConsent = true
                    } else {
                        share.turnOff()
                        keepTurnedOn = false
                    }
                }
            )) {
                Text(SettingsText.shareRecordings).font(ResoniqFont.body).foregroundStyle(ResoniqColor.ivory)
            }
            .tint(ResoniqColor.lime)
            .frame(minHeight: ResoniqSize.touchMin)
            Text(SettingsText.shareExplanation).bodyText(colour: ResoniqColor.muted)
            if keepTurnedOn {
                Text(SettingsText.shareTurnedKeepOn).bodyText()
            }
            if share.isOn || share.status.sent > 0 || share.status.problem != nil {
                Text(SettingsText.shareStatus(share.status, isOn: share.isOn)).bodyText()
            }
            if share.isOn, share.status.notQueued > 0 {
                VStack(alignment: .leading, spacing: Metrics.labelGap) {
                    Button(SettingsText.sendExisting) { share.sendExisting() }
                        .buttonStyle(ResoniqInlineLinkStyle())
                    Text(SettingsText.notQueued(share.status.notQueued)).bodyText(colour: ResoniqColor.muted)
                }
            }
            Button(SettingsText.deleteShared) { confirming = .shared }
                .buttonStyle(ResoniqSecondaryButtonStyle(.outlined))
            if sharedDeleted {
                Text(SettingsText.deleteSharedDone).font(ResoniqFont.caption).foregroundStyle(ResoniqColor.muted)
            }
        }
        .task { await share.refresh() }
    }

    private var hasRecordings: Bool { recordingsSize > 0 || counts.recordings > 0 }

    // MARK: Measurement

    private var measurementSection: some View {
        SettingsSection(SettingsText.measurementLabel) {
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                Text(SettingsText.testSound).bodyText()
                Text(SettingsText.microphone).bodyText()
                // Browse only: every test sound file, to play from another device.
                VStack(alignment: .leading, spacing: Metrics.labelGap) {
                    Button(TestSoundText.settingsRow) { showsTestSound = true }
                        .buttonStyle(ResoniqInlineLinkStyle())
                    Text(TestSoundText.settingsNote).bodyText(colour: ResoniqColor.muted)
                }
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
        ValueRow(label: label, value: value.formatted(.number), isLast: isLast)
    }
}

/// A row of the data lists: the name on the left, a figure on the right, a hairline under all but the last.
private struct ValueRow: View {
    let label: String
    let value: String
    var isLast = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(ResoniqFont.body).foregroundStyle(ResoniqColor.ivory)
            Spacer(minLength: ResoniqSpace.s3)
            Text(value).font(ResoniqFont.figure).foregroundStyle(ResoniqColor.ivory)
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
