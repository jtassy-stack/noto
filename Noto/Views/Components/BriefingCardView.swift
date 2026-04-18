import SwiftUI

/// Signal card following the nōto visual grammar:
///   N1 — Child name (DM Serif 16px, brand) → scanned in 0.2s
///   N2 — Signal title (Inter Medium 14px) → read in 0.5s
///   N3 — Context detail (Inter Regular 12px, 65% opacity) → optional
///
/// Card background is tinted by urgency (not a dot) — the parent
/// scans color first, then name, then signal.
struct BriefingCardView: View {
    let card: BriefingCard
    let showChildName: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: NotoTheme.Spacing.cardGap) {
                // Content — N1/N2/N3 hierarchy
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                    // N1 — WHO (serif, brand color, scanned first)
                    if showChildName {
                        Text("Pour \(card.childName)")
                            .font(NotoTheme.Typography.childName)
                            .foregroundStyle(NotoTheme.Colors.brand)
                    }

                    // N2 — WHAT (functional medium, primary)
                    Text(card.title)
                        .font(NotoTheme.Typography.signalTitle)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)

                    // N3 — CONTEXT (functional regular, faded)
                    if !card.subtitle.isEmpty {
                        Text(card.subtitle)
                            .font(NotoTheme.Typography.metadata)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .opacity(0.65)
                            .lineLimit(2)
                    }

                    if let detail = card.detail {
                        Text(detail)
                            .font(NotoTheme.Typography.metadata)
                            .foregroundStyle(detailColor)
                    }
                }

                Spacer(minLength: 0)

                // Chevron
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.5)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .signalCard(signalUrgency)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var signalUrgency: SignalUrgency {
        switch card.priority {
        case .urgent:   .urgent
        case .positive: .positive
        case .normal:   .info
        case .low:      .info
        }
    }

    private var detailColor: Color {
        card.priority == .urgent ? NotoTheme.Colors.danger : NotoTheme.Colors.info
    }
}

#Preview("BriefingCard — Dark") {
    sampleCards.preferredColorScheme(.dark)
}

#Preview("BriefingCard — Light") {
    sampleCards.preferredColorScheme(.light)
}

private var sampleCards: some View {
    VStack(spacing: NotoTheme.Spacing.cardGap) {
        BriefingCardView(card: BriefingCard(
            type: .homework, childName: "Gaston",
            title: "Devoir maths non fait",
            subtitle: "Pour demain · Exercices p.47-48",
            priority: .urgent, icon: "pencil.and.list.clipboard"
        ), showChildName: true, onTap: {})

        BriefingCardView(card: BriefingCard(
            type: .message, childName: "Léa",
            title: "Message non lu de Mme Dupont",
            subtitle: "Réunion parents-profs jeudi 18h",
            priority: .urgent, icon: "envelope"
        ), showChildName: true, onTap: {})

        BriefingCardView(card: BriefingCard(
            type: .insight, childName: "Gaston",
            title: "Note 11/20 en physique",
            subtitle: "Moy. classe 13.2 · Chapitre optique",
            priority: .normal, icon: "chart.bar"
        ), showChildName: true, onTap: {})

        BriefingCardView(card: BriefingCard(
            type: .insight, childName: "Léa",
            title: "Point fort en français",
            subtitle: "16.5/20 · moy. classe 12.8 · ↑ +1.2 pts/sem",
            priority: .positive, icon: "star"
        ), showChildName: true, onTap: {})
    }
    .padding()
    .background(NotoTheme.Colors.background)
}
