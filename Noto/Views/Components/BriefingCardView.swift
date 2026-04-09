import SwiftUI

struct BriefingCardView: View {
    let card: BriefingCard
    let showChildName: Bool // false when viewing single child

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            // Icon
            Image(systemName: card.icon)
                .font(.system(size: 20))
                .foregroundStyle(iconColor)
                .frame(width: 36, height: 36)
                .background(iconColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))

            // Content
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                if showChildName {
                    ChildTag(name: card.childName)
                }

                Text(card.title)
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)

                Text(card.subtitle)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .lineLimit(2)

                if let detail = card.detail {
                    Text(detail)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(detailColor)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(NotoTheme.Spacing.md)
        .notoCard()
    }

    private var iconColor: Color {
        switch card.priority {
        case .urgent: NotoTheme.Colors.danger
        case .positive: NotoTheme.Colors.success
        case .normal: NotoTheme.Colors.brand
        case .low: NotoTheme.Colors.textSecondary
        }
    }

    private var detailColor: Color {
        card.priority == .urgent ? NotoTheme.Colors.danger : NotoTheme.Colors.textSecondary
    }
}

#Preview("BriefingCard — Dark", traits: .init()) {
    sampleCards.preferredColorScheme(.dark)
}

#Preview("BriefingCard — Light", traits: .init()) {
    sampleCards.preferredColorScheme(.light)
}

private var sampleCards: some View {
    VStack(spacing: 12) {
        BriefingCardView(card: BriefingCard(
            type: .test, childName: "Léa",
            title: "Contrôle de maths demain",
            subtitle: "Équations du second degré — chapitre 4",
            priority: .urgent, icon: "pencil.and.list.clipboard"
        ), showChildName: true)

        BriefingCardView(card: BriefingCard(
            type: .homework, childName: "Tom",
            title: "Pas de devoirs ce soir",
            subtitle: "Aucun devoir pour ce soir",
            priority: .positive, icon: "checkmark.circle"
        ), showChildName: true)

        BriefingCardView(card: BriefingCard(
            type: .message, childName: "Léa",
            title: "Nouveau message",
            subtitle: "M. Bernard — Résultats du contrôle",
            priority: .normal, icon: "envelope"
        ), showChildName: false)
    }
    .padding()
    .background(NotoTheme.Colors.background)
}
