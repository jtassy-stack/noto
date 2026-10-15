import SwiftUI

/// Child-mode text styles. Same registers as `NotoTheme.Typography` (DM Serif
/// for names / titles, system sans for data and actions), but built on text
/// styles so they follow Dynamic Type: `NotoTheme.Typography.functional` uses
/// fixed point sizes.
enum ChildStyle {
    static let greeting = Font.custom("DMSerifDisplay-Regular", size: 28, relativeTo: .title)
    static let title = Font.custom("DMSerifDisplay-Regular", size: 22, relativeTo: .title2)
    static let subject = Font.custom("DMSerifDisplay-Regular", size: 18, relativeTo: .headline)

    static let question = Font.system(.title3, weight: .semibold)
    static let headline = Font.system(.headline)
    static let body = Font.system(.body)
    static let caption = Font.system(.footnote)
    /// Cagnotte / score figures (the scalable counterpart of `dataLarge`).
    static let figure = Font.system(.largeTitle, weight: .semibold)
    /// Section headers (« Révisions », « Aujourd'hui »…): the Dynamic Type
    /// counterpart of `NotoTheme.Typography.sectionLabel`.
    static let sectionLabel = Font.system(.footnote, weight: .medium)

    /// Fill / tint for child actions and progress. `NotoTheme.Colors.brand`
    /// is a fixed slate that disappears on the dark background (~1.5:1), so
    /// dark mode lifts it to slate 0x64748B (≈4.2:1 on the background, white
    /// label ≈4.8:1).
    static let accent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(hex: 0x64748B) : UIColor(hex: 0x2D3748)
    })

    /// Minimum hit target (Apple HIG).
    static let minTapTarget: CGFloat = 44
}

/// Full-width primary action (pattern of `RootView`'s « Ajouter un enfant »),
/// at least 44 pt tall.
struct ChildPrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                } else {
                    Text(title)
                }
            }
            .font(ChildStyle.headline)
            .frame(maxWidth: .infinity, minHeight: ChildStyle.minTapTarget)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(ChildStyle.accent)
    }
}

extension View {
    /// Child-mode section header: scales with Dynamic Type, full
    /// `textSecondary` (no extra opacity) and exposed as a header to the
    /// VoiceOver rotor.
    func childSectionLabel() -> some View {
        self
            .font(ChildStyle.sectionLabel)
            .foregroundStyle(NotoTheme.Colors.textSecondary)
            .textCase(.uppercase)
            .tracking(1.2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Friendly empty state shared by the home, the quiz and the path screens.
struct ChildEmptyState: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(.largeTitle))
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(ChildStyle.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(ChildStyle.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(NotoTheme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .notoCard()
        .accessibilityElement(children: .combine)
    }
}

/// Leitner box as five dots (box 0 = notion not started yet).
struct MasteryDots: View {
    let box: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { index in
                Circle()
                    .fill(index <= box ? NotoTheme.Colors.success : NotoTheme.Colors.border)
                    .frame(width: 8, height: 8)
            }
        }
        .accessibilityHidden(true)
    }
}

extension ProcessInfo {
    /// True inside Xcode canvas previews: no network from previews.
    var isRunningForPreviews: Bool {
        environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }
}
