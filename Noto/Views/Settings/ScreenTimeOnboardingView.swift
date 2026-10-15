import SwiftUI
import FamilyControls

/// Guided Screen Time setup (plan §3.7), parent tone: age profile with
/// repères → apps loisirs → apps toujours permises → budget de base,
/// plafond gagnable and barème → plages nuit / repas → récapitulatif.
///
/// Nothing is written before « Appliquer » on the last step. Applying:
/// - the barème and plafond go to `RewardConfigStore` (other reward rules
///   are kept);
/// - the leisure apps and base budget go through the existing app-limit
///   monitoring (`ScreenTimeMonitorService`), exactly as the manual rows of
///   `ScreenTimeView` do;
/// - the always-allowed apps and the night / meal ranges are stored for
///   phase 3.4 (`ScreenTimeEventStore`, `ScreenTimePlanStore`); the ranges are
///   repères to enter in iOS Temps d'arrêt.
/// The class-hours lock (`ClassScheduleShieldService`) is never touched, and
/// no reward unlock happens here (3.4).
struct ScreenTimeOnboardingView: View {
    let suggestedProfile: ScreenTimeAgeProfile?
    /// Called after « Appliquer », so `ScreenTimeView` reloads its state.
    let onApplied: () -> Void

    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case profile, leisureApps, allowedApps, budget, ranges, summary

        var title: String {
            switch self {
            case .profile: return "Âge de votre enfant"
            case .leisureApps: return "Apps de loisirs"
            case .allowedApps: return "Apps toujours permises"
            case .budget: return "Budget et récompenses"
            case .ranges: return "Nuit et repas"
            case .summary: return "Récapitulatif"
            }
        }
    }

    @State private var step: Step = .profile
    @State private var profile: ScreenTimeAgeProfile = .age11to13
    @State private var leisure = ScreenTimeEventStore.loadWatchedSelection()
    @State private var allowed = ScreenTimeEventStore.loadAlwaysAllowedSelection()
    @State private var showLeisurePicker = false
    @State private var showAllowedPicker = false
    @State private var baseHours = ScreenTimeEventStore.loadThreshold()
    @State private var config = RewardConfigStore.load()
    @State private var plan = ScreenTimePlan(profile: .age11to13)
    @State private var startMonitoring = true
    /// Monitoring already running when the setup opened: « Appliquer » then
    /// always restarts it with the new selection and budget, so the summary
    /// says so instead of offering a toggle it would ignore.
    @State private var wasMonitoring = ScreenTimeMonitorService.shared.isMonitoring
    @State private var applyError: String?
    @State private var didPrefill = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Étape \(step.rawValue + 1) sur \(Step.allCases.count)")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                        Text(step.title)
                            .font(NotoTheme.Typography.screenTitle)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                    }
                    .padding(.top, NotoTheme.Spacing.sm)
                    .padding(.horizontal, NotoTheme.Spacing.xs)

                    stepContent

                    if let applyError {
                        Label(applyError, systemImage: "exclamationmark.triangle")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.danger)
                    }

                    navigationButtons
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
            }
        }
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            // Re-entry keeps what was applied (stored plan, reward config,
            // budget); a first run pre-fills from the suggested profile.
            if let stored = ScreenTimePlanStore.load() {
                profile = stored.profile
                plan = stored
            } else {
                select(suggestedProfile ?? .age11to13)
            }
        }
    }

    /// Pre-fills the budget, the barème / plafond and the ranges from the
    /// profile's repères (the parent then adjusts them).
    private func select(_ newProfile: ScreenTimeAgeProfile) {
        profile = newProfile
        baseHours = newProfile.baseBudgetHours
        config = newProfile.applied(to: config)
        plan = ScreenTimePlan(profile: newProfile)
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .profile: profileStep
        case .leisureApps:
            pickerStep(text: "Choisissez les apps et catégories de loisirs (jeux, réseaux sociaux, vidéo…). "
                       + "Elles restent utilisables jusqu'au budget du jour, puis sont bloquées automatiquement.",
                       label: Self.selectionLabel(leisure), isPresented: $showLeisurePicker, selection: $leisure)
        case .allowedApps:
            pickerStep(text: "Choisissez les apps qui doivent rester utilisables quel que soit le budget "
                       + "(apps scolaires, plans, musique…). Elles sont enregistrées dès maintenant et seront "
                       + "prises en compte par le déblocage par les révisions, dans une prochaine version.",
                       label: Self.selectionLabel(allowed), isPresented: $showAllowedPicker, selection: $allowed)
        case .budget: budgetStep
        case .ranges: rangesStep
        case .summary: summaryStep
        }
    }

    private var profileStep: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Ces repères sont des points de départ : vous pourrez tout ajuster aux étapes suivantes.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(ScreenTimeAgeProfile.allCases.enumerated()), id: \.element) { index, candidate in
                    if index > 0 { SettingsDivider() }
                    Button { select(candidate) } label: {
                        HStack(alignment: .top, spacing: NotoTheme.Spacing.md) {
                            Image(systemName: candidate == profile ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(candidate == profile ? NotoTheme.Colors.brand : NotoTheme.Colors.textSecondary)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(candidate.label)
                                        .font(NotoTheme.Typography.body)
                                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                                    Text(candidate.levelsLabel)
                                        .font(NotoTheme.Typography.caption)
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                    if candidate == suggestedProfile {
                                        Text("Suggéré")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(NotoTheme.Colors.success)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(NotoTheme.Colors.success.opacity(0.1))
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(Self.reperesLabel(candidate))
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(candidate == profile ? .isSelected : [])
                }
            }
            .notoCard()
        }
    }

    static func reperesLabel(_ p: ScreenTimeAgeProfile) -> String {
        "Budget de base \(p.baseBudgetHours) h · jusqu'à \(p.earnableCap) min à gagner par jour · "
            + "nuit \(p.night.label)"
    }

    /// One picker per step (each step has its own `.familyActivityPicker`,
    /// never two presentation modifiers on the same node).
    private func pickerStep(text: String, label: String, isPresented: Binding<Bool>,
                            selection: Binding<FamilyActivitySelection>) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text(text)
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                #if targetEnvironment(simulator)
                RevisionStatRow(label: "Sélection d'apps", value: "Non disponible simulateur")
                #else
                Button { isPresented.wrappedValue = true } label: {
                    HStack {
                        Image(systemName: "apps.iphone")
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Choisir les apps")
                                .font(NotoTheme.Typography.body)
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                            Text(label)
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .opacity(0.5)
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .familyActivityPicker(isPresented: isPresented, selection: selection)
                #endif
            }
            .notoCard()
        }
    }

    private var budgetStep: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            VStack(spacing: 0) {
                RevisionStepperRow(title: "Budget de base", subtitle: "Temps quotidien des apps de loisirs, sans quiz",
                                   value: $baseHours, range: 1...8, step: 1, unit: "h")
                SettingsDivider()
                RevisionStepperRow(title: "Plafond gagnable",
                                   subtitle: "Minutes à gagner au plus par jour avec les révisions",
                                   value: $config.dailyCap, range: RewardConfig.dailyCapRange, step: 5, unit: "min")
                ForEach(0..<3, id: \.self) { index in
                    SettingsDivider()
                    RevisionStepperRow(title: RevisionSettingsView.tierTitle(index), subtitle: nil,
                                       value: tierBinding(index), range: RewardConfig.tierRange, step: 5, unit: "min")
                }
            }
            .notoCard()

            Text("Les autres règles (seuil de réussite, bonus veille de contrôle…) se règlent dans "
                 + "Réglages › Révisions & récompenses.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .padding(.horizontal, NotoTheme.Spacing.xs)
        }
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

    private var rangesStep: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Repères à reporter vous-même : ouvrez l'app Réglages › Temps d'écran › Temps d'arrêt "
                 + "sur l'iPhone de votre enfant (avec le Partage familial, cela se règle souvent depuis votre "
                 + "propre iPhone). Quand le déblocage par les révisions arrivera, les minutes gagnées ne seront "
                 + "pas utilisables pendant ces plages.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                rangeRow("Nuit", range: $plan.night)
                ForEach(plan.meals.indices, id: \.self) { index in
                    SettingsDivider()
                    rangeRow(index == 0 ? "Déjeuner" : "Dîner", range: $plan.meals[index])
                }
            }
            .notoCard()
            // No « Ouvrir les Réglages » button: `openSettingsURLString` opens
            // nōto's own settings page, not Temps d'écran.
        }
    }

    private func rangeRow(_ title: String, range: Binding<DailyTimeRange>) -> some View {
        HStack {
            Text(title)
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Spacer()
            DatePicker("Début", selection: Self.timeBinding(range, start: true), displayedComponents: .hourAndMinute)
                .labelsHidden()
            Text("–").foregroundStyle(NotoTheme.Colors.textSecondary)
            DatePicker("Fin", selection: Self.timeBinding(range, start: false), displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    /// Minutes-from-midnight ↔ a `Date` today, for `DatePicker`.
    static func timeBinding(_ range: Binding<DailyTimeRange>, start: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minutes = start ? range.wrappedValue.startMinutes : range.wrappedValue.endMinutes
                let calendar = Calendar.current
                return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0,
                                     of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                if start { range.wrappedValue.startMinutes = minutes } else { range.wrappedValue.endMinutes = minutes }
            }
        )
    }

    private var summaryStep: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            VStack(spacing: 0) {
                RevisionStatRow(label: "Profil", value: profile.label)
                SettingsDivider()
                RevisionStatRow(label: "Apps de loisirs", value: Self.selectionLabel(leisure))
                SettingsDivider()
                RevisionStatRow(label: "Apps toujours permises", value: Self.selectionLabel(allowed))
                SettingsDivider()
                RevisionStatRow(label: "Budget de base", value: "\(baseHours) h")
                SettingsDivider()
                RevisionStatRow(label: "Plafond gagnable", value: "\(config.dailyCap) min")
                SettingsDivider()
                RevisionStatRow(label: "Barème", value: config.tiers.prefix(3).map { "\($0)" }.joined(separator: " / ") + " min")
                SettingsDivider()
                RevisionStatRow(label: "Nuit", value: plan.night.label)
                SettingsDivider()
                RevisionStatRow(label: "Repas", value: plan.meals.map(\.label).joined(separator: ", "))
                if Self.hasApps(leisure) {
                    SettingsDivider()
                    if wasMonitoring {
                        RevisionStatRow(label: "Budget quotidien", value: "Déjà actif, mis à jour")
                    } else {
                        Toggle("Activer le budget quotidien maintenant", isOn: $startMonitoring)
                            .font(NotoTheme.Typography.body)
                            .tint(NotoTheme.Colors.brand)
                            .padding(.horizontal, NotoTheme.Spacing.md)
                            .padding(.vertical, 12)
                    }
                }
            }
            .notoCard()

            Text("Le verrouillage pendant les cours reste inchangé : il n'est jamais levé par les minutes gagnées.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .padding(.horizontal, NotoTheme.Spacing.xs)
        }
    }

    // MARK: - Navigation

    private var navigationButtons: some View {
        HStack {
            if step != .profile {
                Button("Précédent") {
                    if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
                }
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer()
            Button {
                if step == .summary {
                    apply()
                } else if let next = Step(rawValue: step.rawValue + 1) {
                    step = next
                }
            } label: {
                Text(step == .summary ? "Appliquer" : "Suivant")
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, NotoTheme.Spacing.lg)
                    .padding(.vertical, 12)
                    .background(NotoTheme.Colors.brand)
                    .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.lg))
            }
            .buttonStyle(.plain)
        }
    }

    private func apply() {
        applyError = nil
        RewardConfigStore.save(config)
        ScreenTimeEventStore.storeAlwaysAllowedSelection(allowed)
        ScreenTimePlanStore.save(plan)
        let monitor = ScreenTimeMonitorService.shared
        if Self.hasApps(leisure), startMonitoring || monitor.isMonitoring {
            do {
                // Persists the selection and the threshold too.
                try monitor.startMonitoring(selection: leisure, thresholdHours: baseHours)
            } catch {
                ScreenTimeEventStore.storeWatchedSelection(leisure)
                ScreenTimeEventStore.storeThreshold(hours: baseHours)
                applyError = "Le budget n'a pas pu être activé : \(error.localizedDescription)"
                onApplied()
                return
            }
        } else {
            ScreenTimeEventStore.storeWatchedSelection(leisure)
            ScreenTimeEventStore.storeThreshold(hours: baseHours)
        }
        onApplied()
        dismiss()
    }

    // MARK: - Helpers

    static func hasApps(_ selection: FamilyActivitySelection) -> Bool {
        !selection.applications.isEmpty || !selection.categories.isEmpty
    }

    static func selectionLabel(_ selection: FamilyActivitySelection) -> String {
        let apps = selection.applications.count
        let categories = selection.categories.count
        if apps == 0 && categories == 0 { return "Aucune sélection" }
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) app\(apps > 1 ? "s" : "")") }
        if categories > 0 { parts.append("\(categories) catégorie\(categories > 1 ? "s" : "")") }
        return parts.joined(separator: " · ")
    }
}
