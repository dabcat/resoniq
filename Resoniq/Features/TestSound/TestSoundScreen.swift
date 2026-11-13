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
/// The files are written to a temporary folder off the main actor when the screen appears, with the Kit's names so
/// AirDrop, Files and "Save to Files" keep the name and the `.wav` type, and the folder is removed when the screen goes
/// away. The files themselves are `TestSoundFile`'s; nothing about them is decided here.
struct TestSoundScreen: View {
    let context: TestSoundContext
    /// "I have the file"; nil for the browse-only form.
    var onContinue: (() -> Void)?
    var onClose: () -> Void
    /// Writes the files into a folder; a seam for previews of the failed state.
    var writer: @Sendable ([TestSoundFile], URL) async throws -> Void = TestSoundFiles.write

    @State private var preparation = Preparation.preparing
    @State private var attempt = 0
    /// Removes the temporary folder when the screen is gone (not when a share sheet covers it).
    @State private var temporary = TemporaryFolder()

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
        let kinds = context.kinds
        let folder = URL.temporaryDirectory.appending(path: "TestSound-\(UUID().uuidString)", directoryHint: .isDirectory)
        let files = kinds.map { TestSoundFile(kind: $0) }
        do {
            try await writer(files, folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            if !Task.isCancelled { preparation = .failed }
            return
        }
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        temporary.url = folder
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

/// A folder in the temporary directory that is removed when this object goes: held in the screen's state, so the files
/// live exactly as long as the screen does and a share sheet over it cannot pull them away.
nonisolated final class TemporaryFolder: @unchecked Sendable {
    var url: URL? {
        didSet { if let oldValue, oldValue != url { try? FileManager.default.removeItem(at: oldValue) } }
    }

    deinit {
        if let url { try? FileManager.default.removeItem(at: url) }
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
