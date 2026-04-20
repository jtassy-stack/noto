import SwiftUI

/// Final onboarding step — recap of what's configured,
/// with a primary CTA to enter the main app.
struct OnboardingSummaryStep: View {
    let child: Child?
    let emailConfigured: Bool
    let onFinish: () -> Void

    private var systemName: String {
        guard let child else { return "—" }
        switch child.schoolType {
        case .pronote: return "Pronote"
        case .ent: return child.entProvider?.name ?? "ENT"
        case .ecoledirecte: return "École Directe"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                // Checkmark + title
                VStack(spacing: NotoTheme.Spacing.md) {
                    ZStack {
                        Circle()
                            .fill(NotoTheme.Colors.success.opacity(0.12))
                            .frame(width: 72, height: 72)
                        Image(systemName: "checkmark")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(NotoTheme.Colors.success)
                    }

                    Text("Tout est prêt")
                        .font(NotoTheme.Typography.screenTitle)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, NotoTheme.Spacing.xl)

                // Summary card
                VStack(spacing: 0) {
                    SummaryRow(
                        label: "Enfant",
                        value: child.map { "\($0.firstName) · \(systemName)" } ?? "—",
                        dot: child != nil ? .success : nil
                    )
                    SummaryDivider()
                    SummaryRow(
                        label: "École",
                        value: child?.displayEstablishment ?? "—",
                        dot: child != nil ? .success : nil
                    )
                    SummaryDivider()
                    SummaryRow(
                        label: "Zone",
                        value: "C · Paris",
                        dot: .success
                    )
                    SummaryDivider()
                    SummaryRow(
                        label: "Email",
                        value: emailConfigured ? "Connecté" : "Non configuré",
                        dot: emailConfigured ? .success : .neutral
                    )
                    SummaryDivider()
                    SummaryRow(
                        label: "Cantine",
                        value: "Disponible · configurer plus tard",
                        dot: nil
                    )
                }
                .notoCard()
                .padding(.horizontal, NotoTheme.Spacing.md)

                Text("Vous pouvez ajouter d'autres enfants et configurer les intégrations dans les réglages.")
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.65)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, NotoTheme.Spacing.lg)

                Spacer(minLength: NotoTheme.Spacing.lg)

                // Footer — step indicator + CTA
                VStack(spacing: NotoTheme.Spacing.md) {
                    StepIndicator(currentStep: 2, totalSteps: 3)

                    Button(action: onFinish) {
                        Text("Commencer à utiliser nōto")
                            .font(NotoTheme.Typography.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, NotoTheme.Spacing.md)
                            .background(NotoTheme.Colors.brand)
                            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
                    }
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.bottom, NotoTheme.Spacing.xl)
            }
        }
        .background(NotoTheme.Colors.background)
    }
}

// MARK: - Row primitives

enum SummaryDotKind {
    case success
    case neutral
}

private struct SummaryRow: View {
    let label: String
    let value: String
    let dot: SummaryDotKind?

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            Text(label)
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Spacer()
            Text(value)
                .font(NotoTheme.Typography.metadata)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
            if let dot {
                Circle()
                    .fill(dot == .success
                          ? NotoTheme.Colors.success
                          : NotoTheme.Colors.textTertiary)
                    .frame(width: 8, height: 8)
            } else {
                Color.clear.frame(width: 8, height: 8)
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 14)
    }
}

private struct SummaryDivider: View {
    var body: some View {
        Rectangle()
            .fill(NotoTheme.Colors.border)
            .frame(height: 0.5)
            .padding(.leading, NotoTheme.Spacing.md)
    }
}

#Preview {
    OnboardingSummaryStep(child: nil, emailConfigured: false, onFinish: {})
}
