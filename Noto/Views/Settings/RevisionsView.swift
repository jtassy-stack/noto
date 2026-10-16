import SwiftUI
import SwiftData

/// Écran « Révisions » (plan §3.7), parent tone (vouvoiement): per child,
/// quizzes done (7 / 30 days), notions maîtrisées vs fragiles (Leitner
/// boxes), minutes earned vs used, série, last quiz, then the weekly summary
/// with at most one adjustment suggestion (`RevisionSuggestion`).
///
/// Everything is computed live from the local SwiftData store when the
/// screen opens (this is also where the Sunday notification sends the
/// parent). V1: the data exists only on the device where the child plays,
/// so on a child-mode phone this screen is read behind the parent PIN
/// (Réglages is gated by `ParentGateView`).
struct RevisionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]
    @State private var config = RewardConfigStore.load()
    @State private var appliedSuggestion: RevisionSuggestion?

    private var children: [Child] { families.first?.children ?? [] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                    Text("Révisions")
                        .font(NotoTheme.Typography.screenTitle)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .padding(.top, NotoTheme.Spacing.sm)
                        .padding(.horizontal, NotoTheme.Spacing.xs)

                    if children.isEmpty {
                        emptyCard("Ajoutez d'abord un enfant dans les réglages.")
                    } else {
                        ForEach(children) { child in
                            childSection(child, summary: RevisionReportStore.summary(for: child))
                        }
                    }

                    PrivacyNoticeCard(
                        text: "Les résultats des quiz restent sur cet appareil. Ils ne sont visibles que sur "
                            + "l'appareil où votre enfant révise (derrière le code parent en mode enfant)."
                    )
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .onAppear { config = RewardConfigStore.load() }
        }
    }

    // MARK: - Per child

    @ViewBuilder
    private func childSection(_ child: Child, summary s: RevisionSummary) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text(child.firstName)
                .font(NotoTheme.Typography.childName)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
                .padding(.horizontal, NotoTheme.Spacing.xs)

            if s.lastQuizDate == nil {
                emptyCard("Votre enfant n'a pas encore fait de quiz de révision sur cet appareil.")
            } else {
                VStack(spacing: 0) {
                    RevisionStatRow(label: "Quiz faits (7 jours)", value: "\(s.quizzes7d) · \(s.passed7d) réussis")
                    SettingsDivider()
                    RevisionStatRow(label: "Quiz faits (30 jours)", value: "\(s.quizzes30d)")
                    SettingsDivider()
                    RevisionStatRow(label: "Série", value: Self.streakLabel(s.streakDays))
                    SettingsDivider()
                    RevisionStatRow(label: "Dernier quiz", value: Self.lastQuizLabel(s.lastQuizDate))
                }
                .notoCard()

                VStack(spacing: 0) {
                    RevisionStatRow(label: "Minutes gagnées (7 jours)", value: "\(s.minutesEarned7d) min")
                    SettingsDivider()
                    RevisionStatRow(label: "Minutes utilisées (7 jours)",
                                    value: s.minutesUsed7d.map { "\($0) min" } ?? "—")
                    if s.minutesUsed7d == nil {
                        Text("Le suivi des minutes utilisées arrivera avec le déblocage des apps (prochaine version).")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, NotoTheme.Spacing.md)
                            .padding(.bottom, 12)
                    }
                }
                .notoCard()

                notionsCard(s, child: child)
                weeklyCard(s)
            }
        }
    }

    private func notionsCard(_ s: RevisionSummary, child: Child) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            RevisionStatRow(label: "Notions maîtrisées", value: "\(s.masteredCount)")
            SettingsDivider()
            RevisionStatRow(label: "En cours", value: "\(s.inProgressCount)")
            SettingsDivider()
            RevisionStatRow(label: "Fragiles", value: "\(s.fragileCount)")
            if !s.fragileNotionKeys.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(s.fragileNotionKeys.prefix(5)), id: \.self) { key in
                        Label(RevisionNotionLabel.label(for: key, programs: CurriculumService.bundledPrograms),
                              systemImage: "circle.dashed")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    Text("Ces notions reviendront en priorité dans ses prochains quiz.")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.bottom, 12)
            }
        }
        .notoCard()
    }

    private func weeklyCard(_ s: RevisionSummary) -> some View {
        let suggestion = RevisionSuggestion.suggest(summary: s, config: config)
        return VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Bilan de la semaine")
                .font(NotoTheme.Typography.signalTitle)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Text(s.weeklySentence)
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let suggestion {
                Label(suggestion.text, systemImage: "lightbulb")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if appliedSuggestion == suggestion {
                    Text("Réglage appliqué.")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.success)
                } else {
                    Button("Appliquer ce réglage") {
                        let updated = suggestion.applied(to: config)
                        RewardConfigStore.save(updated)
                        appliedSuggestion = suggestion
                        config = updated
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NotoTheme.Colors.brand)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NotoTheme.Spacing.md)
        .notoCard()
    }

    private func emptyCard(_ text: String) -> some View {
        Text(text)
            .font(NotoTheme.Typography.body)
            .foregroundStyle(NotoTheme.Colors.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NotoTheme.Spacing.md)
            .notoCard()
    }

    // MARK: - Copy

    static func streakLabel(_ days: Int) -> String {
        switch days {
        case 0: return "—"
        case 1: return "1 jour"
        default: return "\(days) jours"
        }
    }

    static func lastQuizLabel(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Label on the left, value on the right.
struct RevisionStatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            Text(label)
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Spacer()
            Text(value)
                .font(NotoTheme.Typography.metadata)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}
