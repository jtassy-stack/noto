import SwiftUI

/// Wellbeing signal card for difficulty-type insights.
/// Uses `.signalCard(.attention)` — tinted amber bg with left accent.
/// Follows N1/N2/N3 visual grammar and offers an actionable link
/// to related resources (future: Charles-derived wellbeing scoring).
struct WellbeingSignalCard: View {
    let childName: String
    let insight: Insight
    var onActionTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            // N1 — WHO (serif, brand)
            Text(childName)
                .font(NotoTheme.Typography.childName)
                .foregroundStyle(NotoTheme.Colors.brand)

            // N2 — WHAT (functional medium)
            Text(signalTitle)
                .font(NotoTheme.Typography.signalTitle)
                .foregroundStyle(NotoTheme.Colors.textPrimary)

            // N3 — CONTEXT (functional regular, faded)
            Text(insight.value)
                .font(NotoTheme.Typography.metadata)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .opacity(0.65)
                .lineLimit(2)

            // Action link (bleu info)
            Button {
                onActionTap?()
            } label: {
                HStack(spacing: 4) {
                    Text("Voir les ressources d'accompagnement")
                        .font(NotoTheme.Typography.functional(13, weight: .medium))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(NotoTheme.Colors.info)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .signalCard(.attention)
    }

    /// Parent-facing title derived from insight type + subject.
    /// Tone is supportive, never alarming — consistent with Charles
    /// language elements ("en difficulté" not "en alerte").
    private var signalTitle: String {
        switch insight.type {
        case .difficulty:
            return "\(insight.subject) en difficulté"
        case .alert:
            return "Besoin d'attention en \(insight.subject)"
        case .trend:
            return "Tendance en \(insight.subject)"
        case .strength:
            return "Point fort en \(insight.subject)"
        }
    }
}
