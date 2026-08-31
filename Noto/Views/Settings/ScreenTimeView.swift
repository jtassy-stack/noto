import SwiftUI
import SwiftData
import FamilyControls
import ManagedSettings
import DeviceActivity

struct ScreenTimeView: View {
    @ObservedObject private var manager = ScreenTimeManager.shared
    @Query private var families: [Family]
    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var restrictionsApplied = false
    @State private var monitoringEnabled = false
    @State private var monitoringError: Error? = nil
    @State private var thresholdHours: Int = ScreenTimeEventStore.loadThreshold()
    @State private var linkedChildID: String? = ScreenTimeEventStore.loadLinkedChildID()
    @State private var classLockEnabled = ScreenTimeEventStore.isClassLockEnabled()
    @State private var classLockError: Error? = nil
    @State private var classLockLastSync: Date? = ScreenTimeEventStore.loadClassLockLastSync()
    @State private var isSyncingClassLock = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var children: [Child] { families.first?.children ?? [] }
    /// Unambiguous with a single child even if no link was explicitly set,
    /// same rule as BriefingEngine's screen-time attribution.
    private var linkedChild: Child? {
        if children.count == 1 { return children.first }
        return children.first(where: { "\($0.id)" == linkedChildID })
    }

    // Self-reported checklist items (parent marks as done manually)
    @AppStorage("st_checklist_passcode") private var passcodeConfigured = false
    @AppStorage("st_checklist_downtime") private var downtimeConfigured = false
    @AppStorage("st_checklist_applimits") private var appLimitsConfigured = false
    @AppStorage("st_checklist_content") private var contentRestrictionsConfigured = false

    private let store = ManagedSettingsStore()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                    Text("Temps d'écran")
                        .font(NotoTheme.Typography.screenTitle)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .padding(.top, NotoTheme.Spacing.sm)
                        .padding(.horizontal, NotoTheme.Spacing.xs)

                    switch manager.authorizationStatus {
                    case .notDetermined:
                        notDeterminedSection
                    case .approved:
                        approvedSection
                    case .denied:
                        deniedSection
                    @unknown default:
                        notDeterminedSection
                    }

                    checklistSection

                    PrivacyNoticeCard(
                        text: "Les restrictions Temps d'écran sont gérées entièrement sur cet appareil. Aucune donnée n'est transmise à nos serveurs."
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
        }
        .onAppear {
            manager.refresh()
            monitoringEnabled = ScreenTimeMonitorService.shared.isMonitoring
            selection = ScreenTimeEventStore.loadWatchedSelection()
            restrictionsApplied = !selection.applications.isEmpty || !selection.categories.isEmpty
        }
#if !targetEnvironment(simulator)
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: selection) { updateWatchedSelection() }
#endif
        .alert("Impossible d'activer la surveillance", isPresented: Binding(
            get: { monitoringError != nil },
            set: { if !$0 { monitoringError = nil } }
        )) {
            Button("OK") { monitoringError = nil }
        } message: {
            Text(monitoringError?.localizedDescription ?? "")
        }
    }

    // MARK: - State Sections

    private var notDeterminedSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Autorisation requise")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
                HStack(spacing: NotoTheme.Spacing.md) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 28))
                        .foregroundStyle(NotoTheme.Colors.brand)
                        .frame(width: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gérer le temps d'écran")
                            .font(NotoTheme.Typography.signalTitle)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Text("Définissez des limites d'utilisation par application pour votre enfant, directement depuis nōto.")
                            .font(NotoTheme.Typography.metadata)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.top, NotoTheme.Spacing.md)

                SettingsDivider()

                Button {
                    Task { await manager.requestAuthorization() }
                } label: {
                    HStack {
                        Text("Activer le contrôle")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.brand)
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
            }
            .notoCard()
        }
    }

    private var approvedSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Restrictions actives")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                // Status row
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(NotoTheme.Colors.success)
                    Text("Autorisation accordée")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, 14)

                if children.count > 1 {
                    SettingsDivider()
                    childLinkRow
                }

                SettingsDivider()

                // App selection
                #if targetEnvironment(simulator)
                HStack {
                    Image(systemName: "apps.iphone")
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                    Text("Sélection d'apps")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Spacer()
                    Text("Non disponible simulateur")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, 14)
                #else
                Button {
                    showPicker = true
                } label: {
                    HStack {
                        Image(systemName: "apps.iphone")
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Applications à restreindre")
                                .font(NotoTheme.Typography.body)
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                            Text(appSelectionLabel)
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
                #endif

                if restrictionsApplied {
                    SettingsDivider()
                    Button(role: .destructive) {
                        clearRestrictions()
                    } label: {
                        HStack {
                            Text("Retirer toutes les restrictions")
                                .font(NotoTheme.Typography.body)
                                .foregroundStyle(NotoTheme.Colors.danger)
                            Spacer()
                        }
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.plain)
                }
            }
            .notoCard()

            // Monitoring / alerting section
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
                Text("Alertes nōto")
                    .sectionLabelStyle()
                    .padding(.horizontal, NotoTheme.Spacing.xs)

                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Surveiller l'utilisation")
                                .font(NotoTheme.Typography.body)
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                            Text("Alerte dans le briefing si la limite est dépassée")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                        Spacer()
                        Toggle("", isOn: $monitoringEnabled)
                            .labelsHidden()
                            .tint(NotoTheme.Colors.brand)
                            .onChange(of: monitoringEnabled) { _, enabled in
                                if enabled {
                                    do {
                                        try ScreenTimeMonitorService.shared.startMonitoring(selection: selection, thresholdHours: thresholdHours)
                                    } catch {
                                        monitoringEnabled = false
                                        monitoringError = error
                                    }
                                } else {
                                    ScreenTimeMonitorService.shared.stopMonitoring()
                                }
                            }
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, 14)

                    if monitoringEnabled {
                        SettingsDivider()
                        HStack {
                            Text("Budget journalier")
                                .font(NotoTheme.Typography.body)
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                            Spacer()
                            Stepper("\(thresholdHours)h", value: $thresholdHours, in: 1...8)
                                .fixedSize()
                                .onChange(of: thresholdHours) { oldValue, h in
                                    do {
                                        try ScreenTimeMonitorService.shared.startMonitoring(selection: selection, thresholdHours: h)
                                    } catch {
                                        thresholdHours = oldValue
                                        monitoringEnabled = false
                                        monitoringError = error
                                    }
                                }
                        }
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, 14)

                        Text("Les apps sélectionnées restent utilisables jusqu'à ce budget cumulé — la restriction s'applique alors automatiquement, sans que vous ayez à intervenir.")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .padding(.horizontal, NotoTheme.Spacing.md)
                            .padding(.bottom, 12)
                    }
                }
                .notoCard()
            }

            classLockSection
        }
    }

    /// Opt-in near-total lockdown during class hours, driven by the synced
    /// timetable — separate from the graduated app-limit shield above (own
    /// named ManagedSettingsStore, see ClassScheduleShieldService).
    private var classLockSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Verrouillage pendant les cours")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bloquer le téléphone pendant les cours")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Text("Basé sur l'emploi du temps synchronisé — bloque quasiment tout, sauf appels et messages.")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    Spacer()
                    Toggle("", isOn: $classLockEnabled)
                        .labelsHidden()
                        .tint(NotoTheme.Colors.brand)
                        .disabled(linkedChild == nil)
                        .onChange(of: classLockEnabled) { _, enabled in
                            ScreenTimeEventStore.setClassLockEnabled(enabled)
                            if enabled {
                                syncClassLock()
                            } else {
                                ClassScheduleShieldService.disable()
                                classLockLastSync = nil
                            }
                        }
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, 14)

                if linkedChild == nil {
                    SettingsDivider()
                    Text("Indiquez d'abord à quel enfant appartient cet appareil ci-dessus.")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, 10)
                }

                if classLockEnabled {
                    SettingsDivider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Emploi du temps")
                                .font(NotoTheme.Typography.body)
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                            Text(classLockSyncLabel)
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                        Spacer()
                        if isSyncingClassLock {
                            ProgressView()
                        } else {
                            Button("Actualiser") { syncClassLock() }
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(NotoTheme.Colors.brand)
                        }
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, 14)

                    SettingsDivider()
                    Text("Limites connues : l'emploi du temps n'est actualisé que lorsque l'app est ouverte — pensez à l'ouvrir régulièrement. La levée du blocage en fin de cours peut être retardée de quelques minutes.")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, 10)
                }

                if let classLockError {
                    SettingsDivider()
                    Label(classLockError.localizedDescription, systemImage: "exclamationmark.triangle")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.danger)
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, 10)
                }
            }
            .notoCard()
        }
    }

    private var classLockSyncLabel: String {
        guard let classLockLastSync else { return "Jamais synchronisé" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .full
        return "Synchronisé \(formatter.localizedString(for: classLockLastSync, relativeTo: .now))"
    }

    private func syncClassLock() {
        guard let child = linkedChild else { return }
        isSyncingClassLock = true
        classLockError = nil
        do {
            try ClassScheduleShieldService.sync(schedule: child.schedule)
            classLockLastSync = ScreenTimeEventStore.loadClassLockLastSync()
        } catch {
            classLockError = error
            classLockEnabled = false
            ScreenTimeEventStore.setClassLockEnabled(false)
        }
        isSyncingClassLock = false
    }

    /// Which `Child` this physical device belongs to — needed once a family
    /// has more than one child, since Screen Time authorization is inherently
    /// per-device, not per-child (see `ScreenTimeEventStore.storeLinkedChildID`).
    private var childLinkRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cet appareil appartient à")
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text("Pour attribuer les alertes au bon enfant")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer()
            Picker("", selection: Binding(
                get: { linkedChildID },
                set: { newValue in
                    linkedChildID = newValue
                    ScreenTimeEventStore.storeLinkedChildID(newValue)
                }
            )) {
                Text("Non défini").tag(String?.none)
                ForEach(children) { child in
                    Text(child.firstName).tag(String?.some("\(child.id)"))
                }
            }
            .labelsHidden()
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 14)
    }

    private var deniedSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Accès refusé")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                HStack(spacing: NotoTheme.Spacing.md) {
                    Image(systemName: "xmark.shield.fill")
                        .foregroundStyle(NotoTheme.Colors.danger)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Autorisation refusée")
                            .font(NotoTheme.Typography.signalTitle)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Text("Autorisez l'accès dans Réglages > Confidentialité > Temps d'écran.")
                            .font(NotoTheme.Typography.metadata)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, 14)

                SettingsDivider()

                Button {
                    if let url = URL(string: "app-settings:") {
                        openURL(url)
                    }
                } label: {
                    HStack {
                        Text("Ouvrir les réglages")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.brand)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14))
                            .foregroundStyle(NotoTheme.Colors.brand)
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
            .notoCard()
        }
    }

    // MARK: - Checklist

    private var checklistSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            HStack {
                Text("Configuration recommandée")
                    .sectionLabelStyle()
                Spacer()
                Text("\(checklistProgress)/\(checklistTotal)")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(checklistComplete ? NotoTheme.Colors.success : NotoTheme.Colors.textSecondary)
            }
            .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                // 1 — FamilyControls authorization (auto-detected)
                ChecklistRow(
                    icon: "lock.shield",
                    title: "Contrôle parental nōto",
                    description: "Autorisez nōto à gérer les limites d'applications",
                    done: manager.isAuthorized,
                    auto: true,
                    action: manager.isAuthorized ? nil : {
                        Task { await manager.requestAuthorization() }
                    }
                )

                SettingsDivider()

                // 2 — Screen Time passcode (self-reported)
                ChecklistRow(
                    icon: "lock.rotation",
                    title: "Code Temps d'écran",
                    description: "Empêche votre enfant de désactiver les limites\nRéglages → Temps d'écran → Utiliser le code",
                    done: passcodeConfigured,
                    auto: false,
                    onToggle: { passcodeConfigured = $0 },
                    settingsPath: "Réglages → Temps d'écran → Utiliser le code"
                )

                SettingsDivider()

                // 3 — Downtime (self-reported)
                ChecklistRow(
                    icon: "moon.stars",
                    title: "Temps d'arrêt",
                    description: "Bloquez les écrans la nuit et pendant les devoirs",
                    done: downtimeConfigured,
                    auto: false,
                    onToggle: { downtimeConfigured = $0 },
                    settingsPath: "Réglages → Temps d'écran → Temps d'arrêt"
                )

                SettingsDivider()

                // 4 — App limits (self-reported)
                ChecklistRow(
                    icon: "timer",
                    title: "Limites d'applications",
                    description: "Limitez les réseaux sociaux, jeux et divertissement",
                    done: appLimitsConfigured,
                    auto: false,
                    onToggle: { appLimitsConfigured = $0 },
                    settingsPath: "Réglages → Temps d'écran → Limites des apps"
                )

                SettingsDivider()

                // 5 — Content restrictions (self-reported)
                ChecklistRow(
                    icon: "hand.raised",
                    title: "Restrictions de contenu",
                    description: "Bloquez les contenus 18+ et les achats non autorisés",
                    done: contentRestrictionsConfigured,
                    auto: false,
                    onToggle: { contentRestrictionsConfigured = $0 },
                    settingsPath: "Réglages → Temps d'écran → Contenu et confidentialité"
                )

                SettingsDivider()

                // 6 — nōto monitoring (auto-detected)
                ChecklistRow(
                    icon: "bell.badge",
                    title: "Alertes nōto",
                    description: "Recevez une alerte dans le briefing si la limite est dépassée",
                    done: monitoringEnabled,
                    auto: true,
                    action: monitoringEnabled ? nil : {
                        do {
                            try ScreenTimeMonitorService.shared.startMonitoring(selection: selection, thresholdHours: thresholdHours)
                            monitoringEnabled = true
                        } catch {
                            monitoringError = error
                        }
                    }
                )
            }
            .notoCard()
        }
    }

    private var checklistProgress: Int {
        [
            manager.isAuthorized,
            passcodeConfigured,
            downtimeConfigured,
            appLimitsConfigured,
            contentRestrictionsConfigured,
            monitoringEnabled
        ].filter { $0 }.count
    }

    private var checklistTotal: Int { 6 }
    private var checklistComplete: Bool { checklistProgress == checklistTotal }

    // MARK: - Helpers

    private var appSelectionLabel: String {
        let appCount = selection.applications.count
        let categoryCount = selection.categories.count
        if appCount == 0 && categoryCount == 0 { return "Aucune sélection" }
        var parts: [String] = []
        if appCount > 0 { parts.append("\(appCount) app\(appCount > 1 ? "s" : "")") }
        if categoryCount > 0 { parts.append("\(categoryCount) catégorie\(categoryCount > 1 ? "s" : "")") }
        return parts.joined(separator: " · ")
    }

    /// Persists the newly picked apps/categories and, if monitoring is
    /// already on, restarts it against the new selection. Does NOT shield
    /// anything directly — selecting an app only starts the clock on its
    /// daily budget; the `NotoDeviceActivity` extension applies the actual
    /// shield once that budget is spent (see `DeviceActivityMonitorExtension`).
    private func updateWatchedSelection() {
        restrictionsApplied = !selection.applications.isEmpty || !selection.categories.isEmpty
        if monitoringEnabled {
            do {
                try ScreenTimeMonitorService.shared.startMonitoring(selection: selection, thresholdHours: thresholdHours)
            } catch {
                monitoringError = error
            }
        } else {
            ScreenTimeEventStore.storeWatchedSelection(selection)
        }
    }

    /// Clears the watched selection AND any shield already in effect (the
    /// budget may have already been spent today) — otherwise a parent
    /// removing a restriction mid-day would see it silently stay applied
    /// until the next 00:00 reset.
    private func clearRestrictions() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        ScreenTimeMonitorService.shared.stopMonitoring()
        ScreenTimeEventStore.storeWatchedSelection(FamilyActivitySelection())
        selection = FamilyActivitySelection()
        monitoringEnabled = false
        restrictionsApplied = false
    }
}

// MARK: - ChecklistRow

private struct ChecklistRow: View {
    let icon: String
    let title: String
    let description: String
    let done: Bool
    /// True = status is computed automatically; False = parent marks manually
    let auto: Bool
    var action: (() -> Void)? = nil
    var onToggle: ((Bool) -> Void)? = nil
    var settingsPath: String? = nil

    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.md) {
            // Status icon
            ZStack {
                Circle()
                    .fill(done ? NotoTheme.Colors.success.opacity(0.12) : NotoTheme.Colors.border)
                    .frame(width: 36, height: 36)
                Image(systemName: done ? "checkmark" : icon)
                    .font(.system(size: 14, weight: done ? .semibold : .regular))
                    .foregroundStyle(done ? NotoTheme.Colors.success : NotoTheme.Colors.textSecondary)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    if auto && done {
                        Text("Auto")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(NotoTheme.Colors.success)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(NotoTheme.Colors.success.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    // Manual toggle for self-reported items
                    if !auto, let onToggle {
                        Toggle("", isOn: Binding(get: { done }, set: { onToggle($0) }))
                            .labelsHidden()
                            .tint(NotoTheme.Colors.brand)
                            .scaleEffect(0.8)
                    }
                }

                Text(description)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // CTA for auto items not yet done
                if auto && !done, let action {
                    Button(action: action) {
                        Text("Configurer")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(NotoTheme.Colors.brand)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }

                // Settings path + open button for manual items not yet done
                if !auto && !done, let path = settingsPath {
                    HStack(spacing: 4) {
                        Text(path)
                            .font(.system(size: 11))
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .opacity(0.7)
                        Spacer()
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                openURL(url)
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text("Ouvrir")
                                    .font(.system(size: 11, weight: .medium))
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(NotoTheme.Colors.brand)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}
