import ResoniqDesign
import SwiftUI

/// What turning on "Share recordings for research" means, said before it happens (no mockup; built from
/// design/DESIGN_SYSTEM.md with the Rooms sheet's header): Cancel at the top leading corner, as a sheet's bar has it
/// (HIG), the title under it, the sections in plain words, and the one primary button at the foot, which alone turns
/// sharing on. Swiping the sheet away is Cancel.
struct ShareConsentSheet: View {
    var onCancel: () -> Void
    var onConfirm: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.sectionGap) {
                    Text(SettingsText.consentIntro).consentText()
                    section(SettingsText.consentSentLabel, SettingsText.consentSent, SettingsText.consentVoices)
                    section(SettingsText.consentNotSentLabel, SettingsText.consentNotSent)
                    section(SettingsText.consentWhereLabel, SettingsText.consentWhere)
                    section(SettingsText.consentStopLabel, SettingsText.consentStop)
                }
                .padding(.horizontal, ResoniqSpace.screenInset)
                .padding(.bottom, ResoniqSpace.s4)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .background(ResoniqColor.ink)
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(ResoniqColor.ink)
        .presentationCornerRadius(ResoniqRadius.sheet)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(SettingsText.consentCancel, action: onCancel)
                    .buttonStyle(ResoniqTextLinkStyle())
                Spacer()
            }
            Text(SettingsText.consentTitle)
                .resoniqTitle(.small)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .padding(.top, ResoniqSpace.s2)
        .padding(.bottom, ResoniqSpace.s3)
    }

    private func section(_ label: String, _ lines: String...) -> some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s2) {
            Text(label)
                .resoniqCapsLabel()
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Metrics.lineGap) {
                ForEach(lines, id: \.self) { Text($0).consentText() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .resoniqPanel()
        }
    }

    private var footer: some View {
        VStack(spacing: ResoniqSpace.s2) {
            Text(SettingsText.consentKeep)
                .font(ResoniqFont.caption)
                .foregroundStyle(ResoniqColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(SettingsText.consentConfirm, action: onConfirm)
                .buttonStyle(ResoniqPrimaryButtonStyle())
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .padding(.top, ResoniqSpace.s3)
        .padding(.bottom, ResoniqSpace.s3)
        .background(ResoniqColor.ink)
        .overlay(alignment: .top) {
            Rectangle().fill(ResoniqColor.line).frame(height: ResoniqSize.strokeHairline)
        }
    }

    private enum Metrics {
        static let sectionGap = ResoniqSpace.s6
        static let lineGap = ResoniqSpace.s3
    }
}

private extension Text {
    func consentText() -> some View {
        font(ResoniqFont.body)
            .foregroundStyle(ResoniqColor.ivory)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("Consent") {
    Color.black.sheet(isPresented: .constant(true)) {
        ShareConsentSheet(onCancel: {}, onConfirm: {})
    }
}
#endif
