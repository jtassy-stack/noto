import SwiftUI
import SwiftData

/// « Mes badges »: earned badges only (`Gamification.badges`). Nothing locked,
/// no « encore N pour… » list: a badge appears once the milestone is real.
/// Child mode, tutoiement.
struct BadgesView: View {
    let child: Child
    var curriculum: CurriculumSnapshot = .bundled

    var body: some View {
        let badges = GamificationStore.badges(for: child, now: Date(), calendar: .current,
                                              curriculum: curriculum)
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
                if badges.isEmpty {
                    ChildEmptyState(systemImage: "rosette",
                                    title: "Tes badges apparaîtront ici",
                                    message: "Fais un quiz pour gagner ton premier badge.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(badges.enumerated()), id: \.element.id) { index, badge in
                            if index > 0 { SettingsDivider() }
                            BadgeRow(badge: badge)
                        }
                    }
                    .notoCard()
                }
            }
            .padding(NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
        .navigationTitle("Mes badges")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct BadgeRow: View {
    let badge: EarnedBadge

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            Image(systemName: BadgeCopy.symbol(for: badge.kind))
                .font(.system(.title2))
                .foregroundStyle(NotoTheme.Colors.warning)
                .frame(minWidth: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(BadgeCopy.title(for: badge.kind))
                    .font(ChildStyle.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(BadgeCopy.detail(for: badge.kind))
                    .font(ChildStyle.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
        .frame(minHeight: ChildStyle.minTapTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(BadgeCopy.title(for: badge.kind)). \(BadgeCopy.detail(for: badge.kind))")
    }
}

/// Badge wording (tutoiement), pure for tests.
enum BadgeCopy {
    static func title(for kind: BadgeKind) -> String {
        switch kind {
        case .firstQuiz: "Premier quiz"
        case .streak(let days): "Série de \(days) jours"
        case .subjectLevel(let subject, let level): "Niveau \(level) en \(subject)"
        case .themeMastered(_, let theme): "Thème maîtrisé : \(theme)"
        }
    }

    static func detail(for kind: BadgeKind) -> String {
        switch kind {
        case .firstQuiz: "Tu as terminé ton tout premier quiz."
        case .streak(let days): "Tu as révisé \(days) jours d'affilée."
        case .subjectLevel(let subject, _): "Tes bonnes réponses en \(subject) t'ont fait monter de niveau."
        case .themeMastered(let subject, _): "\(subject) : tu connais toutes les notions de ce thème."
        }
    }

    static func symbol(for kind: BadgeKind) -> String {
        switch kind {
        case .firstQuiz: "flag.checkered"
        case .streak: "flame.fill"
        case .subjectLevel: "bolt.fill"
        case .themeMastered: "checkmark.seal.fill"
        }
    }
}

#Preview("Mes badges") {
    NavigationStack {
        BadgesView(child: PreviewData.revisionChild)
    }
    .withPreviewData()
}
