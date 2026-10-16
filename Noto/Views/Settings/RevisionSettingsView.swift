import SwiftUI

/// « Révisions & récompenses » (plan §3.7): the parent edits `RewardConfig`
/// (barème, seuil, plafond, bonus veille de contrôle, longueur minimale,
/// quiz rejoués) and the two opt-in child features. Saved to the app group
/// on every change (`RewardConfigStore`); the next quiz reads it.
///
/// Reached from Réglages, so on a child-mode device it sits behind the
/// parent PIN (`ChildHomeView` gates `SettingsView`). Parent tone throughout.
/// Minutes are recorded only; the actual unlock arrives with phase 3.4.
struct RevisionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config = RewardConfigStore.load()
    @State private var cultureQuestion = CultureQuestionSettings.isEnabled()
    @State private var familyChallenge = FamilyChallengeSettings.isEnabled()
    @State private var showResetConfirmation = false

    /// Defaults to restore: the guided setup's profile (barème + plafond) when
    /// one was applied, so « Rétablir » does not contradict « Profil … appliqué »
    /// in Temps d'écran; `RewardConfig.default` otherwise.
    private var resetTarget: RewardConfig {
        if let plan = ScreenTimePlanStore.load() { return plan.profile.applied(to: .default) }
        return .default
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                    Text("Révisions & récompenses")
                        .font(NotoTheme.Typography.screenTitle)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .padding(.top, NotoTheme.Spacing.sm)
                        .padding(.horizontal, NotoTheme.Spacing.xs)

                    Text("Votre enfant gagne des minutes de temps d'écran en réussissant ses quiz de révision. "
                         + "Les minutes sont comptabilisées dès maintenant ; le déblocage des apps arrivera "
                         + "dans une prochaine version. Le verrouillage pendant les cours n'est jamais levé.")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, NotoTheme.Spacing.xs)

                    if DeviceMode.current == .parent {
                        // Quizzes are played on the child-mode device and there is
                        // no cross-device sync: rules edited here do not reach it.
                        PrivacyNoticeCard(
                            text: "Ces règles s'appliquent aux quiz faits sur cet appareil. Pour modifier celles "
                                + "de votre enfant, ouvrez Réglages › Révisions sur son iPhone (code parent)."
                        )
                    }

                    tiersSection
                    rulesSection
                    childFeaturesSection

                    Button {
                        showResetConfirmation = true
                    } label: {
                        Text("Rétablir le barème et les règles par défaut")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.brand)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                    .notoCard()
                    .confirmationDialog("Rétablir le barème et les règles par défaut ?",
                                        isPresented: $showResetConfirmation, titleVisibility: .visible) {
                        Button("Rétablir", role: .destructive) { config = resetTarget }
                        Button("Annuler", role: .cancel) {}
                    } message: {
                        Text("Le barème, le plafond et les règles reprennent leurs valeurs par défaut"
                             + (ScreenTimePlanStore.load().map { " (profil \($0.profile.label))" } ?? "")
                             + ". La question culture et le défi familial ne changent pas.")
                    }
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
            .onChange(of: config) { _, newValue in RewardConfigStore.save(newValue) }
            .onChange(of: cultureQuestion) { _, on in CultureQuestionSettings.setEnabled(on) }
            .onChange(of: familyChallenge) { _, on in FamilyChallengeSettings.setEnabled(on) }
        }
    }

    // MARK: - Barème

    private var tiersSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Barème")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    if index > 0 { SettingsDivider() }
                    RevisionStepperRow(
                        title: Self.tierTitle(index),
                        subtitle: index == 0 ? "Minutes gagnées par quiz réussi, dans l'ordre de la journée" : nil,
                        value: tierBinding(index),
                        range: RewardConfig.tierRange,
                        step: 5,
                        unit: "min"
                    )
                }
                SettingsDivider()
                RevisionStepperRow(
                    title: "Plafond quotidien",
                    subtitle: "Au-delà, les quiz comptent pour la série mais ne rapportent plus de minutes",
                    value: $config.dailyCap,
                    range: RewardConfig.dailyCapRange,
                    step: 5,
                    unit: "min"
                )
            }
            .notoCard()
        }
    }

    static func tierTitle(_ index: Int) -> String {
        index == 0 ? "1er quiz réussi" : "\(index + 1)e quiz réussi"
    }

    private func tierBinding(_ index: Int) -> Binding<Int> {
        Binding(
            get: { config.tiers.indices.contains(index) ? config.tiers[index] : 0 },
            set: { newValue in
                var tiers = config.tiers
                while tiers.count <= index { tiers.append(0) }
                tiers[index] = newValue
                config.tiers = tiers
            }
        )
    }

    // MARK: - Règles

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Règles")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Seuil de réussite")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Text("Bonnes réponses nécessaires pour gagner des minutes")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Picker("Seuil de réussite", selection: $config.passThreshold) {
                        Text("4 sur 5").tag(0.8)
                        Text("3 sur 5").tag(0.6)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(NotoTheme.Colors.textSecondary)
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, 12)

                SettingsDivider()
                RevisionStepperRow(
                    title: "Longueur minimale du quiz",
                    subtitle: "Un quiz plus court compte pour la progression, sans minutes",
                    value: $config.minQuestionCount,
                    range: RewardConfig.minQuestionCountRange,
                    step: 1,
                    unit: "questions"
                )

                SettingsDivider()
                Toggle(isOn: $config.examEveBonusEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bonus veille de contrôle")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Text("+\(config.examEveBonus) min une fois par jour, au-delà du plafond, "
                             + "quand un contrôle est prévu le lendemain")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
                .tint(NotoTheme.Colors.brand)
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, 12)

                if config.examEveBonusEnabled {
                    SettingsDivider()
                    RevisionStepperRow(title: "Montant du bonus", subtitle: nil, value: $config.examEveBonus,
                                       range: 1...RewardConfig.examEveBonusRange.upperBound, step: 1, unit: "min")
                }

                SettingsDivider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quiz identique rejoué")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Text("Un quiz déjà réussi avec les mêmes questions ne rapporte pas de minutes")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Picker("Quiz identique rejoué", selection: $config.replayWindow) {
                        Text("Jamais").tag(ReplayWindow.ever)
                        Text("Le même jour").tag(ReplayWindow.sameDay)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(NotoTheme.Colors.textSecondary)
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, 12)
            }
            .notoCard()
        }
    }

    // MARK: - Child features

    private var childFeaturesSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Sur l'app de votre enfant")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                Toggle(isOn: $cultureQuestion) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Question culture du jour")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Text("Une question de culture générale par jour (films, séries, livres, jeux…). "
                             + "Contenu tout public, non spécifiquement conçu pour les enfants : "
                             + "activez-la si cela vous convient. Ne rapporte ni minutes ni points.")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(NotoTheme.Colors.brand)
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, 12)

                SettingsDivider()
                Toggle(isOn: $familyChallenge) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Défi familial de la semaine")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Text("Affiche un objectif de \(FamilyChallengeSettings.weeklyGoal) quiz réussis par semaine "
                             + "sur l'accueil de votre enfant.")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(NotoTheme.Colors.brand)
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, 12)
            }
            .notoCard()

            PrivacyNoticeCard(
                text: "Ces réglages et les résultats des quiz restent sur cet appareil. La question culture "
                    + "du jour est téléchargée sans aucune information sur votre enfant."
            )
        }
    }
}

/// Title + optional caption + stepper with the value and its unit.
struct RevisionStepperRow: View {
    let title: String
    let subtitle: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Stepper(value: $value, in: range, step: step) {
                Text("\(value) \(unit)")
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .monospacedDigit()
            }
            .fixedSize()
            .accessibilityLabel(title)
            .accessibilityValue("\(value) \(unit)")
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
    }
}

#Preview {
    RevisionSettingsView()
}
