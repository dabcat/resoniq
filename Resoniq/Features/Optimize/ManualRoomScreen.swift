import ResoniqDesign
import ResoniqRoom
import SwiftUI

/// Enter the room by hand, for a phone without LiDAR or a scan that did not work. There is no mockup: it follows
/// design/DESIGN_SYSTEM.md (the frame and voice of the other flow screens, large mono readouts as on the Measure
/// screens, the room plan for the preview).
///
/// The width, length and ceiling height are typed with a decimal keypad or stepped by a tenth of a metre. Whether
/// they are usable, and what to say when they are not, is the Kit's (`ManualRoom.issues`, `RoomText.manualIssue`);
/// the screen only shows it. "Use this room" hands over the model with the Kit's first guess at the pair and the
/// seat already placed in it (`LayoutGuess.place(in:)`), all unconfirmed, so the next screen is Confirm layout with
/// `isGuess: true`. That is decided here, once, so the caller never has to.
struct ManualRoomScreen: View {
    private let onDone: (RoomModel) -> Void
    private let onClose: () -> Void

    @State private var width: Double
    @State private var length: Double
    @State private var height: Double

    /// - Parameters:
    ///   - initial: The sizes to start from (the mockups' room by default is not assumed: a first guess for a living
    ///     room, which is a number to correct, not a measurement).
    ///   - onDone: The room, with the pair and the seat guessed in it.
    init(
        initial: ManualRoom? = nil,
        onDone: @escaping (RoomModel) -> Void,
        onClose: @escaping () -> Void
    ) {
        let start = initial ?? ManualRoom(width: Metrics.startWidth, length: Metrics.startLength)
        _width = State(initialValue: start.width)
        _length = State(initialValue: start.length)
        _height = State(initialValue: start.height)
        self.onDone = onDone
        self.onClose = onClose
    }

    private var manual: ManualRoom { ManualRoom(width: width, length: length, height: height) }

    var body: some View {
        let manual = manual
        let issues = manual.issues
        VStack(spacing: ResoniqSpace.s4) {
            ScrollView {
                VStack(alignment: .leading, spacing: ResoniqSpace.s4) {
                    header
                    preview(manual)
                    field(OptimizeText.width, value: $width, issue: .widthOutOfRange, in: issues)
                    field(OptimizeText.length, value: $length, issue: .lengthOutOfRange, in: issues)
                    field(OptimizeText.height, value: $height, issue: .heightOutOfRange, in: issues)
                    Text(OptimizeText.manualHint)
                        .font(ResoniqFont.body)
                        .foregroundStyle(ResoniqColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, ResoniqSpace.screenInset)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            Button(OptimizeText.useThisRoom) {
                if let model = manual.model() { onDone(LayoutGuess.place(in: model)) }
            }
            .buttonStyle(ResoniqPrimaryButtonStyle())
            .disabled(!issues.isEmpty)
            .opacity(issues.isEmpty ? 1 : Metrics.disabledOpacity)
            .padding(.horizontal, ResoniqSpace.screenInset)
        }
        .padding(.top, ResoniqSpace.s3)
        .padding(.bottom, ResoniqSpace.s3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ResoniqColor.ink)
        .accessibilityAction(.escape, onClose)
    }

    // MARK: Header and preview

    private var header: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            HStack {
                Button(action: onClose) { ResoniqIconView(.back) }
                    .buttonStyle(ResoniqIconButtonStyle())
                    .accessibilityLabel(OptimizeText.close)
                Text(OptimizeText.manualCaption)
                    .resoniqCapsLabel()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(OptimizeText.manualHeadline)
                .resoniqTitle(.medium)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The walls at the entered size; nothing while a side is out of range, so a typo does not draw a 40 m room.
    private func preview(_ manual: ManualRoom) -> some View {
        let model = manual.model()
        return RoomPlanView(
            model.map { RoomDisplay.content(of: $0) } ?? RoomPlanContent(),
            showsLegend: false, height: Metrics.previewHeight,
            accessibilityLabel: model.map { RoomDisplay.layoutSummary(of: $0) } ?? OptimizeText.manualPreviewSummary
        )
    }

    // MARK: Fields

    private func field(_ title: String, value: Binding<Double>, issue: ManualRoom.Issue, in issues: [ManualRoom.Issue]) -> some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
            // The title and the controls share a row; under large text the title gets a row of its own.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ResoniqSpace.s3) {
                    fieldTitle(title)
                    controls(title, value: value, issue: issue, in: issues)
                }
                VStack(alignment: .leading, spacing: ResoniqSpace.s1) {
                    fieldTitle(title)
                    HStack(spacing: ResoniqSpace.s3) { controls(title, value: value, issue: issue, in: issues) }
                }
            }
            if issues.contains(issue) {
                // The Kit's sentence, and its mark: a word, not only a colour.
                Text(RoomText.manualIssue(issue))
                    .font(ResoniqFont.caption)
                    .foregroundStyle(ResoniqColor.signalText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(RoomText.manualIssue(issue))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func fieldTitle(_ title: String) -> some View {
        Text(title)
            .font(ResoniqFont.bodyMedium)
            .foregroundStyle(ResoniqColor.ivory)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func controls(_ title: String, value: Binding<Double>, issue: ManualRoom.Issue, in issues: [ManualRoom.Issue]) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
            .keyboardType(.decimalPad)
            .font(ResoniqFont.readoutMedium)
            .foregroundStyle(issues.contains(issue) ? ResoniqColor.signalText : ResoniqColor.ivory)
            .multilineTextAlignment(.trailing)
            .frame(minWidth: Metrics.readoutWidth, maxWidth: Metrics.readoutWidth, minHeight: ResoniqSize.touchMin)
        Text(OptimizeText.metresUnit)
            .font(ResoniqFont.bodyMedium)
            .foregroundStyle(ResoniqColor.muted)
        Stepper(title, value: value, in: Metrics.stepperRange, step: Metrics.step)
            .labelsHidden()
    }

    private enum Metrics {
        /// Where the fields start: a first guess at a living room, to be corrected.
        static let startWidth = 4.0
        static let startLength = 5.0
        static let step = 0.1
        /// Wide enough to type or step to values the Kit then rejects, so its message shows.
        static let stepperRange = 0.0...100.0
        static let previewHeight: CGFloat = 220
        static let readoutWidth: CGFloat = 110
        static let disabledOpacity = 0.4
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Manual room") {
    ManualRoomScreen(onDone: { _ in }, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("A side out of range") {
    ManualRoomScreen(initial: ManualRoom(width: 0.42, length: 5.6), onDone: { _ in }, onClose: {})
        .preferredColorScheme(.dark)
}

#Preview("Largest text") {
    ManualRoomScreen(initial: ManualRoom(width: 4.2, length: 5.6), onDone: { _ in }, onClose: {})
        .environment(\.dynamicTypeSize, .accessibility2)
        .preferredColorScheme(.dark)
}
#endif
