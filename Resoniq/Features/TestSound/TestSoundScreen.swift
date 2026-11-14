import ResoniqAudio
import ResoniqDesign
import ResoniqDSP
import ResoniqStore
import SwiftUI
import UniformTypeIdentifiers

/// Which files a screen needs, for where it was opened from.
enum TestSoundContext: Equatable {
    /// A speaker test: one file for each speaker of the selected system (left and right, or both channels for a single
    /// speaker or a soundbar).
    case speaker(choices: [SpeakerPosition])
    /// The seat measurement: its one file.
    case seat(channels: [SpeakerChannel])
    /// Browsing, from Settings: every file.
    case everything

    var kinds: [TestSoundFile.Kind] {
        switch self {
        case .speaker(let choices): choices.map { .speakerTest(DiagnoseFlow.channel(for: $0)) }
        case .seat(let channels): [.seat(channels)]
        case .everything: TestSoundFile.allKinds
        }
    }
}

/// Getting the test sound (no mockup; built from design/DESIGN_SYSTEM.md): what the option is, the files this
/// context needs with a share button each and one for all, three steps, and the two things it cannot do. "I have the
/// file" carries on to listening; without it (`onContinue` nil) the screen only hands the files over, for Settings.
///
/// The files are written to one temporary folder (`TestSoundFolder`) off the main actor when the screen appears, with
/// the Kit's names so AirDrop, Files and "Save to Files" keep the name and the `.wav` type. The folder lives for the
/// whole app session (each file is written once) and is cleared at the next launch, so "I have the file" cannot pull
/// away a file a share sheet is still handing out. The files themselves are `TestSoundFile`'s; nothing about them is
/// decided here.
struct TestSoundScreen: View {
    let context: TestSoundContext
    /// "I have the file"; nil for the browse-only form.
    var onContinue: (() -> Void)?
    var onClose: () -> Void
    /// Writes the files into a folder; a seam for previews of the failed state.
    var writer: @Sendable ([TestSoundFile], URL) async throws -> Void = TestSoundFiles.write

    @State private var preparation = Preparation.preparing
    @State private var attempt = 0

    private enum Preparation: Equatable {
        case preparing
        case ready(Folder)
        case failed
    }

    /// The temporary folder and the files in it, in the order of `context.kinds`.
    private struct Folder: Equatable {
        var url: URL
        var files: [Prepared]
    }

    private struct Prepared: Equatable, Identifiable {
        var file: TestSoundFile
        var url: URL
        var id: TestSoundFile { file }
    }

    var body: some View {
        FlowScaffold {
            HStack {
                Text(TestSoundText.kicker)
                    .resoniqCapsLabel()
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: ResoniqSpace.s2)
                Button(onContinue == nil ? TestSoundText.done : TestSoundText.notNow, action: onClose)
                    .buttonStyle(ResoniqTextLinkStyle())
            }
        } content: {
            VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
                VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
                    Text(TestSoundText.headline)
                        .resoniqTitle(.large)
                        .accessibilityAddTraits(.isHeader)
                    Text(TestSoundText.intro)
                        .font(ResoniqFont.bodyLarge)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .resoniqTitleRise()

                filesSection
                stepsSection
                notes
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            if let onContinue {
                Button(TestSoundText.primary, action: onContinue)
                    .buttonStyle(ResoniqPrimaryButtonStyle())
            }
        }
        .accessibilityAction(.escape, onClose)
        .task(id: attempt) { await prepare() }
    }

    // MARK: Files

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            Text(TestSoundText.filesLabel)
                .resoniqCapsLabel()
                .accessibilityAddTraits(.isHeader)
            Text(TestSoundText.contextLine(context))
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(context.kinds.enumerated()), id: \.offset) { index, kind in
                    if index > 0 {
                        Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline)
                    }
                    fileRow(kind)
                }
            }
            .resoniqPanel()
            shareAllRow
            if preparation == .failed {
                VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
                    Text(TestSoundText.writeFailed)
                        .font(ResoniqFont.body)
                        .foregroundStyle(ResoniqColor.ivory)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(TestSoundText.tryAgain) {
                        preparation = .preparing
                        attempt += 1
                    }
                    .buttonStyle(ResoniqTextLinkStyle())
                }
                .accessibilityElement(children: .contain)
                .onAppear { AccessibilityNotification.Announcement(TestSoundText.writeFailed).post() }
            }
        }
    }

    private func fileRow(_ kind: TestSoundFile.Kind) -> some View {
        let file = TestSoundFile(kind: kind)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: ResoniqSpace.s3) {
                fileWords(file)
                Spacer(minLength: 0)
                shareControl(for: kind)
            }
            VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
                fileWords(file)
                shareControl(for: kind)
            }
        }
        .padding(.vertical, Metrics.rowPadding)
    }

    private func fileWords(_ file: TestSoundFile) -> some View {
        VStack(alignment: .leading, spacing: Metrics.wordsGap) {
            Text(TestSoundText.title(file.kind))
                .font(ResoniqFont.bodyMedium)
                .foregroundStyle(ResoniqColor.ivory)
            Text(file.suggestedFileName)
                .font(ResoniqFont.axis)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text(file.summary)
                .font(ResoniqFont.caption)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func shareControl(for kind: TestSoundFile.Kind) -> some View {
        if case .ready(let folder) = preparation, let prepared = folder.files.first(where: { $0.file.kind == kind }) {
            ShareLink(item: TestSoundTransfer(url: prepared.url), preview: SharePreview(prepared.file.suggestedFileName)) {
                ShareLabel(title: TestSoundText.share)
            }
            .accessibilityLabel(TestSoundText.shareLabel(kind))
        } else if preparation == .preparing {
            ShareLabel(title: TestSoundText.preparing, isDimmed: true)
                .accessibilityLabel(TestSoundText.preparing)
        }
    }

    @ViewBuilder
    private var shareAllRow: some View {
        if case .ready(let folder) = preparation, folder.files.count > 1 {
            ShareLink(items: folder.files.map { TestSoundTransfer(url: $0.url) }) { transfer in
                SharePreview(transfer.url.lastPathComponent)
            } label: {
                ShareLabel(title: TestSoundText.shareAll)
            }
            .accessibilityLabel(TestSoundText.shareAllLabel)
        }
    }

    // MARK: Steps and notes

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
            Text(TestSoundText.stepsLabel)
                .resoniqCapsLabel()
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(TestSoundText.steps.enumerated()), id: \.offset) { index, step in
                    ResoniqNumberedStep(index + 1, step, showsSeparator: index > 0)
                }
            }
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            ForEach(TestSoundText.notes, id: \.self) { note in
                Text(note)
                    .font(ResoniqFont.caption)
                    .foregroundStyle(ResoniqColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Writing and removing the files

    private func prepare() async {
        guard preparation == .preparing || preparation == .failed else { return }
        preparation = .preparing
        let files = context.kinds.map { TestSoundFile(kind: $0) }
        let folder = TestSoundFolder.url
        // Only what this session has not written yet; a file already there is not touched again.
        let missing = files.filter { !TestSoundFolder.hasWritten($0.kind) }
        do {
            try await writer(missing, folder)
        } catch {
            // Remove what this attempt may have left half-written; files written earlier stay.
            for file in missing { try? FileManager.default.removeItem(at: folder.appending(path: file.suggestedFileName)) }
            if !Task.isCancelled { preparation = .failed }
            return
        }
        // Written even if the screen went away meanwhile: the files stay for the session, and the next screen finds them.
        for file in missing { TestSoundFolder.markWritten(file.kind) }
        guard !Task.isCancelled else { return }
        preparation = .ready(Folder(
            url: folder,
            files: files.map { Prepared(file: $0, url: folder.appending(path: $0.suggestedFileName, directoryHint: .notDirectory)) }
        ))
    }

    private enum Metrics {
        static let rowPadding: CGFloat = 10
        static let wordsGap: CGFloat = 2
    }
}

// MARK: - Pieces

/// A share control's face: a quiet outlined pill, at least the touch size.
private struct ShareLabel: View {
    let title: String
    var isDimmed = false

    var body: some View {
        Text(title)
            .font(ResoniqFont.body)
            .foregroundStyle(isDimmed ? ResoniqColor.muted : ResoniqColor.ivory)
            .padding(.horizontal, ResoniqSpace.s4)
            .frame(minHeight: ResoniqSize.touchMin)
            .overlay(Capsule().strokeBorder(ResoniqColor.line, lineWidth: ResoniqSize.strokeHairline))
            .contentShape(Capsule())
    }
}

/// A test sound file on disk, handed to the share sheet as the file itself, so AirDrop, Files and "Save to Files"
/// keep its name and its `.wav` type.
nonisolated struct TestSoundTransfer: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .wav) { transfer in
            SentTransferredFile(transfer.url)
        }
    }
}

/// The one folder the test sound files are exported into: in the temporary directory, the same for the whole app
/// session, each kind of file written once (`hasWritten`). Nothing removes it while the app runs, so a share sheet
/// (AirDrop, "Save to Files") started from any screen can finish; `sweep()` clears it at the next launch.
@MainActor
enum TestSoundFolder {
    static let url = URL.temporaryDirectory.appending(path: "ResoniqTestSound", directoryHint: .isDirectory)

    private static var written: Set<TestSoundFile.Kind> = []

    static func hasWritten(_ kind: TestSoundFile.Kind) -> Bool {
        written.contains(kind) && FileManager.default.fileExists(atPath: path(of: kind))
    }

    static func markWritten(_ kind: TestSoundFile.Kind) {
        written.insert(kind)
    }

    /// At launch: whatever an earlier session left in the folder goes.
    static func sweep() {
        try? FileManager.default.removeItem(at: url)
        written = []
    }

    private static func path(of kind: TestSoundFile.Kind) -> String {
        url.appending(path: TestSoundFile(kind: kind).suggestedFileName, directoryHint: .notDirectory).path
    }
}

/// Writing the files, off the main actor.
enum TestSoundFiles {
    /// Writes each file, under its own name, into `folder` (made if it is not there), the files side by side.
    @concurrent nonisolated static func write(_ files: [TestSoundFile], to folder: URL) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask {
                    try file.write(to: folder.appending(path: file.suggestedFileName, directoryHint: .notDirectory))
                }
            }
            try await group.waitForAll()
        }
    }
}

#if DEBUG
private struct WriteFailed: Error {}

#Preview("Files for a pair") {
    TestSoundScreen(context: .speaker(choices: [.left, .right]), onContinue: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Files for the seat") {
    TestSoundScreen(context: .seat(channels: [.left, .right]), onContinue: {}, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Browsing, every file") {
    TestSoundScreen(context: .everything, onContinue: nil, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Files, a write failed") {
    TestSoundScreen(
        context: .speaker(choices: [.single]), onContinue: {}, onClose: {},
        writer: { _, _ in throw WriteFailed() }
    )
    .preferredColorScheme(.dark)
}

#Preview("Files, large type") {
    TestSoundScreen(context: .speaker(choices: [.left, .right]), onContinue: {}, onClose: {})
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility2)
}
#endif
