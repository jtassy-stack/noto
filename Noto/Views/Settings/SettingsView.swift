import SwiftUI
import SwiftData
import UserNotifications
import FamilyControls

// MARK: - SettingsView (redesigned — phase 5)
//
// Visual grammar:
//   - DM Serif for human fields (screen title, child names)
//   - Inter / system for functional fields (metadata, badges, data)
//   - `.sectionLabelStyle()` for uppercase letterspaced section headers
//   - `.notoCard()` wraps grouped rows, with 1px dividers between rows
//   - Badges: small rounded pill with tinted bg (10% opacity) + colored text
//
// Preserves all existing functionality:
//   - Add / disconnect children
//   - MonLycée IMAP setup (opened as sheet from "Boîte mail" row)
//   - Notification preferences + authorization prompt
//   - Theme toggle
//   - Clear-all-data confirmation
struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(AppearanceManager.self) private var appearance
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var showClearDataConfirmation = false
    @State private var notifAuthStatus: UNAuthorizationStatus = .notDetermined
    @State private var showAddChild = false
    @State private var showIMAPSetup = false
    @State private var showMailDomains = false
    @State private var imapConfigs: [IMAPServerConfig] = []
    @State private var disconnectError: String?
    @State private var showScreenTime = false
    @State private var showConnectionHealthcheck = false
    @State private var showRevisions = false
    @State private var showRevisionSettings = false
    @ObservedObject private var screenTimeManager = ScreenTimeManager.shared

    @AppStorage("notif_homework") private var notifHomework: Bool = true
    @AppStorage("notif_difficulty") private var notifDifficulty: Bool = true
    @AppStorage("notif_carnet") private var notifCarnet: Bool = true
    @AppStorage("notif_grade_threshold") private var gradeThreshold: Double = 10.0
    @AppStorage("notif_absence") private var notifAbsence: Bool = true
    @AppStorage(WeeklyRevisionNotification.enabledKey) private var notifWeeklyRevisions: Bool = true

    private var family: Family? { families.first }
    private var children: [Child] { family?.children ?? [] }

    /// The weekly summary only schedules on a parent-mode device holding
    /// revision data (`WeeklyRevisionNotification.shouldSchedule`). Quizzes are
    /// played in child mode and nothing syncs attempts across devices (V1), so
    /// today this hides the toggle everywhere instead of showing an « on »
    /// switch that never delivers. It reappears once a data path exists.
    @State private var weeklyRevisionsAvailable = false

    private func refreshWeeklyRevisionsAvailability() {
        weeklyRevisionsAvailable = DeviceMode.current == .parent
            && !RevisionReportStore.activeChildNames(children).isEmpty
    }

    private var whitelistCountLabel: String {
        guard !imapConfigs.isEmpty else { return "—" }
        if imapConfigs.allSatisfy(\.isDedicatedSchoolChannel) { return "Désactivé" }
        let count = MailWhitelist.build(from: children).count
        return count == 1 ? "1 entrée" : "\(count) entrées"
    }

    private var mailboxFilterRowLabel: String {
        !imapConfigs.isEmpty && imapConfigs.allSatisfy(\.isDedicatedSchoolChannel)
            ? "Filtrage courrier"
            : "Domaines autorisés"
    }

    @AppStorage("imapMessagesLastSyncDate") private var imapMessagesLastSyncInterval: Double = 0
    @AppStorage("imapActualitesLastSyncDate") private var imapActualitesLastSyncInterval: Double = 0

    private var imapLastSyncDate: Date? {
        let intervals = [imapMessagesLastSyncInterval, imapActualitesLastSyncInterval].filter { $0 > 0 }
        guard let max = intervals.max() else { return nil }
        return Date(timeIntervalSince1970: max)
    }

    /// Relative label for the last IMAP sync ("Il y a 12 min", "Hier", …).
    private var imapLastSyncLabel: String {
        guard let date = imapLastSyncDate else { return "Jamais" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    // MARK: Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                    Text("Réglages")
                        .font(NotoTheme.Typography.screenTitle)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .padding(.top, NotoTheme.Spacing.sm)
                        .padding(.horizontal, NotoTheme.Spacing.xs)

                    childrenSection
                    integrationsSection
                    if !imapConfigs.isEmpty {
                        mailboxSection
                    }
                    notificationsSection
                    revisionsSection
                    screenTimeSection
                    appearanceSection
                    aboutSection
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            // Keep the inline DM Serif "Réglages" header above — use an
            // empty nav title so only the close button appears in the bar.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .confirmationDialog(
                "Effacer toutes les données ?",
                isPresented: $showClearDataConfirmation,
                titleVisibility: .visible
            ) {
                Button("Effacer", role: .destructive) { clearAllData() }
                Button("Annuler", role: .cancel) { }
            } message: {
                Text("Toutes les données scolaires, notes et réglages seront supprimées de cet appareil. Cette action est irréversible.")
            }
            .sheet(isPresented: $showAddChild) {
                AddChildView()
            }
            .sheet(isPresented: $showIMAPSetup, onDismiss: { refreshIMAP() }) {
                MonLyceeIMAPSetupView()
            }
            .sheet(isPresented: $showMailDomains) {
                MailDomainsView()
            }
            .sheet(isPresented: $showConnectionHealthcheck) {
                ConnectionHealthcheckView()
            }
            .sheet(isPresented: $showScreenTime, onDismiss: { screenTimeManager.refresh() }) {
                ScreenTimeView()
            }
            .sheet(isPresented: $showRevisions) {
                RevisionsView()
            }
            .sheet(isPresented: $showRevisionSettings) {
                RevisionSettingsView()
            }
            .onChange(of: notifWeeklyRevisions) { _, _ in
                Task { await RevisionReportStore.syncWeeklyNotification(children: children) }
            }
            .task {
                await refreshAuthStatus()
                refreshWeeklyRevisionsAvailability()
                refreshIMAP()
            }
            // Defence-in-depth: IMAP state also changes via the setup
            // sheet's internal save path. The sheet-onDismiss refresh
            // above handles the happy path; this observer catches any
            // future code path that saves a config without routing
            // through this view.
            .onReceive(NotificationCenter.default.publisher(for: IMAPService.configDidChangeNotification)) { _ in
                refreshIMAP()
            }
            .alert("Impossible de déconnecter", isPresented: Binding(get: { disconnectError != nil }, set: { if !$0 { disconnectError = nil } })) {
                Button("OK") { disconnectError = nil }
            } message: {
                Text(disconnectError ?? "")
            }
        }
    }

    // MARK: Sections

    private var childrenSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Enfants")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    if index > 0 { SettingsDivider() }
                    ChildSettingsRow(child: child, onDisconnect: { disconnect(child: $0) })
                }
                if !children.isEmpty { SettingsDivider() }
                AddChildRow(action: { showAddChild = true })
            }
            .notoCard()
        }
    }

    private var integrationsSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Intégrations disponibles")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                IntegrationRow(
                    title: "Boîte mail",
                    subtitle: imapConfigs.isEmpty
                        ? "Filtrer les emails scolaires"
                        : imapConfigs.count == 1
                            ? imapConfigs[0].username
                            : "\(imapConfigs.count) comptes configurés",
                    badge: imapConfigs.isEmpty ? .notConfigured : .connected,
                    action: { showIMAPSetup = true }
                )
                SettingsDivider()
                IntegrationRow(
                    title: "Cantine · Berger-Levrault",
                    subtitle: detectedSubtitle,
                    badge: .available,
                    action: nil
                )
                SettingsDivider()
                IntegrationRow(
                    title: "Périscolaire · Mairie",
                    subtitle: detectedSubtitle,
                    badge: .available,
                    action: nil
                )
                SettingsDivider()
                IntegrationRow(
                    title: "Calendrier scolaire",
                    subtitle: "Zone C · Académie de Paris",
                    badge: .active,
                    action: nil
                )
            }
            .notoCard()
        }
    }

    private var mailboxSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Boîtes mail")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(imapConfigs.enumerated()), id: \.element.id) { index, config in
                    if index > 0 { SettingsDivider() }
                    IMAPAccountRow(
                        config: config,
                        children: children,
                        onAssign: { reassignIMAP(id: config.id, to: $0) },
                        onDisconnect: { disconnectIMAP(id: config.id) }
                    )
                }
                SettingsDivider()
                InfoRow(
                    label: mailboxFilterRowLabel,
                    value: whitelistCountLabel,
                    chevron: true,
                    action: { showMailDomains = true }
                )
                SettingsDivider()
                InfoRow(label: "Dernière synchronisation", value: imapLastSyncLabel)
                SettingsDivider()
                Button { showIMAPSetup = true } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(NotoTheme.Colors.brand)
                        Text("Ajouter une boîte mail")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.brand)
                        Spacer()
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
            .notoCard()

            PrivacyNoticeCard(
                text: "Vos identifiants et emails restent uniquement sur votre iPhone. Aucune donnée ne transite par nos serveurs."
            )
        }
    }

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Notifications")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                ToggleRow(
                    title: "Rappel devoirs",
                    subtitle: "Veille à 8h00",
                    isOn: $notifHomework,
                    disabled: notifAuthStatus == .denied
                )
                SettingsDivider()
                ToggleRow(
                    title: "Alerte difficulté détectée",
                    subtitle: "Quand le ML repère une baisse",
                    isOn: $notifDifficulty,
                    disabled: notifAuthStatus == .denied
                )
                SettingsDivider()
                ToggleRow(
                    title: "Carnet à signer",
                    subtitle: "Quand un mot de liaison arrive",
                    isOn: $notifCarnet,
                    disabled: notifAuthStatus == .denied
                )
                SettingsDivider()
                ToggleRow(
                    title: "Absence non justifiée",
                    subtitle: "Quand une absence est détectée",
                    isOn: $notifAbsence,
                    disabled: notifAuthStatus == .denied
                )
                if weeklyRevisionsAvailable {
                    SettingsDivider()
                    ToggleRow(
                        title: "Bilan hebdo des révisions",
                        subtitle: "Dimanche à 19h00, sur cet appareil en mode parent",
                        isOn: $notifWeeklyRevisions,
                        disabled: notifAuthStatus == .denied
                    )
                }
                SettingsDivider()
                GradeThresholdRow(
                    threshold: $gradeThreshold,
                    disabled: notifAuthStatus == .denied
                )
                SettingsDivider()
                AuthStatusRow(
                    status: notifAuthStatus,
                    onRequest: {
                        Task {
                            _ = await NotificationService.shared.requestAuthorization()
                            await refreshAuthStatus()
                        }
                    },
                    onOpenSettings: {
                        if let url = URL(string: "app-settings:") { openURL(url) }
                    }
                )
            }
            .notoCard()
        }
    }

    /// Révisions (3.7): the parent's view of the quizzes and the reward
    /// rules. In child mode the whole of Réglages is behind the parent PIN.
    private var revisionsSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Révisions")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                InfoRow(label: "Révisions", value: revisionsRowValue, chevron: true,
                        action: { showRevisions = true })
                SettingsDivider()
                InfoRow(label: "Révisions & récompenses", value: "", chevron: true,
                        action: { showRevisionSettings = true })
            }
            .notoCard()
        }
    }

    /// « 3 quiz cette semaine » across the children of this device.
    private var revisionsRowValue: String {
        let count = children.reduce(0) { $0 + RevisionReportStore.summary(for: $1).quizzes7d }
        guard count > 0 else { return "" }
        return count == 1 ? "1 quiz cette semaine" : "\(count) quiz cette semaine"
    }

    private var screenTimeSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Temps d'écran")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                IntegrationRow(
                    title: "Contrôle parental",
                    subtitle: screenTimeStatusLabel,
                    badge: screenTimeBadge,
                    action: { showScreenTime = true }
                )
            }
            .notoCard()
        }
    }

    private var screenTimeStatusLabel: String {
        switch screenTimeManager.authorizationStatus {
        case .approved:    return "Actif"
        case .denied:      return "Accès refusé — toucher pour configurer"
        case .notDetermined: return "Limiter les apps par enfant"
        @unknown default:  return "Configurer"
        }
    }

    private var screenTimeBadge: StatusBadge.Kind {
        switch screenTimeManager.authorizationStatus {
        case .approved:    return .connected
        case .denied:      return .notConfigured
        case .notDetermined: return .available
        @unknown default:  return .available
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Apparence")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                @Bindable var app = appearance
                HStack {
                    Image(systemName: "circle.lefthalf.filled")
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                    Text("Thème")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Spacer()
                    Picker("", selection: $app.preference) {
                        ForEach(AppearanceManager.Preference.allCases, id: \.self) { pref in
                            Text(pref.label).tag(pref)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(NotoTheme.Colors.textSecondary)
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, 14)
            }
            .notoCard()
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("À propos")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                InfoRow(label: "Version", value: appVersion)
                SettingsDivider()
                InfoRow(label: "Diagnostic de connexion", value: "", chevron: true, action: { showConnectionHealthcheck = true })
                SettingsDivider()
                InfoRow(label: "Politique de confidentialité", value: "", chevron: true, action: nil)
                SettingsDivider()
                InfoRow(label: "Conditions d'utilisation", value: "", chevron: true, action: nil)
                SettingsDivider()
                Button(role: .destructive) {
                    showClearDataConfirmation = true
                } label: {
                    HStack {
                        Text("Effacer toutes les données")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.danger)
                        Spacer()
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
            }
            .notoCard()
        }
    }

    // MARK: Derived

    private var detectedSubtitle: String {
        if let school = children.first?.displayEstablishment, !school.isEmpty {
            return "Détecté via \(school)"
        }
        return "Configurer plus tard"
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v ?? "2.0.0"
    }

    // MARK: Helpers

    @MainActor
    private func refreshAuthStatus() async {
        notifAuthStatus = await NotificationService.shared.authorizationStatus()
    }

    private func refreshIMAP() {
        imapConfigs = IMAPService.loadConfigs()
    }

    // MARK: Actions

    private func disconnect(child: Child) {
        // Pronote tokens are per parent account, not per child, so they
        // are only dropped once no Pronote child is left (below).
        if child.schoolType == .ecoledirecte, let accountId = child.edAccountId {
            do {
                try KeychainService.delete(key: "ed_credentials_\(accountId)")
            } catch {
                NSLog("[noto][warn] disconnect(child:) ED Keychain delete failed: \(error.localizedDescription)")
            }
        }
        if child.schoolType == .skolengo, let schoolId = child.skolengoSchoolId {
            do {
                try KeychainService.delete(key: "skolengo_credentials_\(schoolId)")
            } catch {
                NSLog("[noto][warn] disconnect(child:) Skolengo Keychain delete failed: \(error.localizedDescription)")
            }
        }
        // Captured before the delete: a mailbox assigned to this child
        // falls back to "Tous les enfants" (sync/UI also resolve a dangling
        // id that way; this keeps the Keychain blob truthful).
        let childKey = MailboxRouting.childKey(child)
        FamilySyncShareService.revokeOnChildRemoval(child)
        let wasPronote = child.schoolType == .pronote || child.entProvider == .monlycee
        modelContext.delete(child)
        try? modelContext.save()
        if wasPronote, !(family?.children ?? []).contains(where: { $0.schoolType == .pronote || $0.entProvider == .monlycee }) {
            PronoteAccountStore.removeAll()
            PronoteService.shared.disconnect()
        }
        do {
            try IMAPService.reassignOrphans(removedChildID: childKey)
        } catch {
            NSLog("[noto][warn] reassignOrphans failed: \(error.localizedDescription)")
        }
        imapConfigs = IMAPService.loadConfigs()
    }

    private func reassignIMAP(id: UUID, to assignment: MailboxAssignment) {
        do {
            try IMAPService.updateAssignment(id: id, to: assignment)
        } catch {
            NSLog("[noto][warn] reassignIMAP failed: \(error.localizedDescription)")
            disconnectError = "Impossible de modifier ce compte. Vérifiez que votre iPhone est déverrouillé et réessayez."
        }
        imapConfigs = IMAPService.loadConfigs()
    }

    private func disconnectIMAP(id: UUID) {
        do {
            try IMAPService.removeConfig(id: id)
            imapConfigs = IMAPService.loadConfigs()
        } catch {
            NSLog("[noto][warn] disconnectIMAP failed: \(error.localizedDescription)")
            imapConfigs = IMAPService.loadConfigs()
            disconnectError = "Impossible de déconnecter ce compte. Vérifiez que votre iPhone est déverrouillé et réessayez."
        }
    }

    private func clearAllData() {
        if let children = family?.children {
            for child in children {
                FamilySyncShareService.revokeOnChildRemoval(child)
                if child.schoolType == .ecoledirecte, let accountId = child.edAccountId {
                    try? KeychainService.delete(key: "ed_credentials_\(accountId)")
                }
                if child.schoolType == .skolengo, let schoolId = child.skolengoSchoolId {
                    try? KeychainService.delete(key: "skolengo_credentials_\(schoolId)")
                }
            }
        }
        for family in families {
            modelContext.delete(family)
        }
        PronoteAccountStore.removeAll()
        PronoteService.shared.disconnect()
        try? IMAPService.clearAllConfigs()
        MonLyceeNewsStore.clear()
        MonLyceeNewsStore.purgeLegacyDefaults()
        imapConfigs = []
        try? modelContext.save()
    }
}

// MARK: - IMAP Account Row

private struct IMAPAccountRow: View {
    let config: IMAPServerConfig
    let children: [Child]
    let onAssign: (MailboxAssignment) -> Void
    let onDisconnect: () -> Void

    /// The assignment as the sync applies it (dangling child → Tous).
    private var effectiveAssignment: MailboxAssignment {
        config.assignment.resolved(childIDs: children.map(MailboxRouting.childKey))
    }

    private var assignmentLabel: String {
        MailboxRouting.label(
            for: config.assignment,
            children: children.map { (id: MailboxRouting.childKey($0), firstName: $0.firstName) }
        )
    }

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(config.providerDisplayName)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(config.username)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer()
            Menu {
                ForEach(MailboxAssignmentOption.options(for: children), id: \.assignment) { option in
                    Button {
                        onAssign(option.assignment)
                    } label: {
                        if option.assignment == effectiveAssignment {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(assignmentLabel)
                        .font(NotoTheme.Typography.caption)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(NotoTheme.Colors.cobalt)
                .padding(.horizontal, NotoTheme.Spacing.sm)
                .padding(.vertical, 4)
                .background(NotoTheme.Colors.cobalt.opacity(0.1))
                .clipShape(Capsule())
            }
            .accessibilityLabel("Ces mails concernent : \(assignmentLabel)")
            Button(role: .destructive, action: onDisconnect) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(NotoTheme.Colors.textSecondary.opacity(0.5))
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 14)
    }
}

// MARK: - Shared row building blocks

/// 1px horizontal divider used between rows inside a `.notoCard()` group.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(NotoTheme.Colors.border)
            .frame(height: 0.5)
            .padding(.leading, NotoTheme.Spacing.md)
    }
}

/// Status badge — small tinted pill with colored text (10% opacity bg).
private struct StatusBadge: View {
    enum Kind {
        case connected
        case notConfigured
        case available
        case active

        var label: String {
            switch self {
            case .connected: "Connecté"
            case .notConfigured: "Non configuré"
            case .available: "Disponible"
            case .active: "Actif"
            }
        }

        var color: Color {
            switch self {
            case .connected, .active: NotoTheme.Colors.success
            case .notConfigured: NotoTheme.Colors.textSecondary
            case .available: NotoTheme.Colors.info
            }
        }
    }

    let kind: Kind

    var body: some View {
        Text(kind.label)
            .font(NotoTheme.Typography.functional(11, weight: .medium))
            .foregroundStyle(kind.color)
            .padding(.horizontal, NotoTheme.Spacing.sm)
            .padding(.vertical, 3)
            .background(kind.color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
    }
}

// MARK: - Child row

private struct ChildSettingsRow: View {
    @Environment(\.modelContext) private var modelContext
    let child: Child
    let onDisconnect: (Child) -> Void
    @State private var showDisconnectConfirm = false
    @State private var showSchoolPicker = false
    @State private var showFamilyLink = false
    @State private var showClassPicker = false

    /// Family sync (phase 9.2): parent devices only, behind the build flag.
    private var familyLinkAvailable: Bool {
        FamilySyncLink.isEnabled() && DeviceMode.current == .parent
    }

    private var systemName: String {
        switch child.schoolType {
        case .pronote: "Pronote"
        case .ent: child.entProvider?.name ?? "ENT"
        case .ecoledirecte: "École Directe"
        case .skolengo: "Skolengo"
        }
    }

    private var isLinkedToDirectory: Bool { child.rneCode != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            classCTA
            if !isLinkedToDirectory {
                linkCTA
            }
            if familyLinkAvailable {
                familyLinkCTA
            }
        }
        .sheet(isPresented: $showSchoolPicker) {
            DirectorySchoolPickerView { summary in
                child.rneCode = summary.rne
                do {
                    try modelContext.save()
                    // Warm the directory cache eagerly so the FIRST sync
                    // after linking already uses the authoritative
                    // mailDomains. Failure here is fine — the next sync
                    // will fall back to the regular cache path.
                    Task {
                        try? await DirectorySchoolCache.refresh(rne: summary.rne)
                    }
                } catch {
                    // Without this log the parent would see the CTA disappear and
                    // assume the link landed, only for it to vanish on next launch.
                    NSLog("[noto][warn] saving rneCode for \(child.firstName) failed: \(error.localizedDescription)")
                    // Roll back the in-memory change so the UI reflects reality.
                    child.rneCode = nil
                }
            }
        }
    }

    /// Grade the quizzes and the parcours use (6e → Tle), or nil when no
    /// sync could read the class name (MonLycée without a Pronote session).
    private var revisionLevel: String? {
        let level = CurriculumService.canonicalLevel(child.grade)
        return CurriculumService.revisionLevels.contains(level) ? level : nil
    }

    private static func classLabel(_ grade: String) -> String {
        switch grade {
        case "2nde": "Seconde"
        case "1re": "Première"
        case "Tle": "Terminale"
        default: grade
        }
    }

    /// Lets the parent set the class when the sync left it empty: without a
    /// level the child app has no quiz and no parcours. A later sync that
    /// reads a class name still wins (`GradeInference.refreshedGrade`).
    private var classCTA: some View {
        Button {
            showClassPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: revisionLevel == nil ? "exclamationmark.circle" : "graduationcap")
                    .font(.system(size: 11))
                Text(revisionLevel.map { "Classe : \(Self.classLabel($0))" }
                     ?? "Classe inconnue : choisir la classe de \(child.firstName) pour ses quiz")
                    .font(NotoTheme.Typography.caption)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.5)
            }
            .foregroundStyle(revisionLevel == nil ? NotoTheme.Colors.warning : NotoTheme.Colors.textSecondary)
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
        .confirmationDialog("Classe de \(child.firstName)", isPresented: $showClassPicker, titleVisibility: .visible) {
            ForEach(CurriculumService.revisionLevels, id: \.self) { grade in
                Button(Self.classLabel(grade)) { setClass(grade) }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les quiz et le parcours suivent cette classe. Une synchro qui lit la classe à l'école la remplace.")
        }
    }

    private func setClass(_ grade: String) {
        guard let choice = GradeInference.manualChoice(grade) else { return }
        let previous = (child.grade, child.level)
        child.grade = choice.grade
        child.level = choice.level
        do {
            try modelContext.save()
        } catch {
            NSLog("[noto][warn] saving class for \(child.firstName) failed: \(error.localizedDescription)")
            child.grade = previous.0
            child.level = previous.1
        }
    }

    private var familyLinkCTA: some View {
        Button {
            showFamilyLink = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 11))
                Text(child.familySyncLinkedAt == nil
                     ? "Relier le téléphone de \(child.firstName)"
                     : "Téléphone de \(child.firstName) relié")
                    .font(NotoTheme.Typography.caption)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.5)
            }
            .foregroundStyle(NotoTheme.Colors.info)
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showFamilyLink) {
            FamilyLinkView(child: child)
        }
    }

    private var linkCTA: some View {
        Button {
            showSchoolPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(.system(size: 11))
                Text("Lier à l'annuaire officiel pour un filtrage mail plus précis")
                    .font(NotoTheme.Typography.caption)
                    .multilineTextAlignment(.leading)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .opacity(0.5)
            }
            .foregroundStyle(NotoTheme.Colors.info)
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.bottom, 12)
        }
        .buttonStyle(.plain)
    }

    private var mainRow: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            // Avatar
            ZStack {
                Circle().fill(NotoTheme.Colors.brand)
                Text(String(child.firstName.prefix(1)).uppercased())
                    .font(NotoTheme.Typography.childName)
                    .foregroundStyle(.white)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(child.firstName)
                    .font(NotoTheme.Typography.childName)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text("\(child.displayEstablishment) · \(systemName)")
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.65)
                    .lineLimit(1)
            }

            Spacer()

            // Connected indicator
            Circle()
                .fill(NotoTheme.Colors.success)
                .frame(width: 8, height: 8)

            Button {
                showDisconnectConfirm = true
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.5)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
        .confirmationDialog(
            "Déconnecter \(child.firstName) ?",
            isPresented: $showDisconnectConfirm,
            titleVisibility: .visible
        ) {
            Button("Déconnecter", role: .destructive) { onDisconnect(child) }
            Button("Annuler", role: .cancel) { }
        } message: {
            Text("Les données scolaires de cet enfant seront supprimées de l'appareil.")
        }
    }
}

// MARK: - Add child row

private struct AddChildRow: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: NotoTheme.Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 18))
                Text("Ajouter un enfant")
                    .font(NotoTheme.Typography.body)
                Spacer()
            }
            .foregroundStyle(NotoTheme.Colors.info)
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Integration row

private struct IntegrationRow: View {
    let title: String
    let subtitle: String
    let badge: StatusBadge.Kind
    let action: (() -> Void)?

    private var rowBody: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(NotoTheme.Typography.metadata)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .opacity(0.65)
                        .lineLimit(1)
                }
            }
            Spacer()
            StatusBadge(kind: badge)
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.5)
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let action {
            Button(action: action) { rowBody }
                .buttonStyle(.plain)
        } else {
            rowBody
        }
    }
}

// MARK: - Generic info row (label + value on right)

private struct InfoRow: View {
    let label: String
    let value: String
    var chevron: Bool = false
    var action: (() -> Void)? = nil

    private var rowBody: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            Text(label)
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Spacer()
            if !value.isEmpty {
                Text(value)
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.5)
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }

    var body: some View {
        if let action {
            Button(action: action) { rowBody }
                .buttonStyle(.plain)
        } else {
            rowBody
        }
    }
}

// MARK: - Toggle row

private struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let disabled: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(subtitle)
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.65)
            }
        }
        .tint(NotoTheme.Colors.brand)
        .disabled(disabled)
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
    }
}

// MARK: - Grade threshold row

private struct GradeThresholdRow: View {
    @Binding var threshold: Double
    let disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alerte note sous seuil")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Text("Notification quand une note est sous ce seuil")
                        .font(NotoTheme.Typography.metadata)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .opacity(0.65)
                }
                Spacer()
                Text(String(format: "%.0f/20", threshold))
                    .font(NotoTheme.Typography.functional(13, weight: .semibold))
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
            }
            Slider(value: $threshold, in: 4...15, step: 1)
                .tint(NotoTheme.Colors.brand)
        }
        .disabled(disabled)
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
    }
}

// MARK: - Notification auth status row

private struct AuthStatusRow: View {
    let status: UNAuthorizationStatus
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.sm) {
            switch status {
            case .authorized, .provisional, .ephemeral:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(NotoTheme.Colors.success)
                Text("Notifications autorisées")
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                Spacer()
            case .denied:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(NotoTheme.Colors.danger)
                Text("Désactivées dans Réglages iOS")
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                Spacer()
                Button("Ouvrir Réglages", action: onOpenSettings)
                    .font(NotoTheme.Typography.functional(12, weight: .medium))
                    .tint(NotoTheme.Colors.info)
            case .notDetermined:
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                Text("Autorisation non demandée")
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                Spacer()
                Button("Autoriser", action: onRequest)
                    .font(NotoTheme.Typography.functional(12, weight: .medium))
                    .tint(NotoTheme.Colors.info)
            @unknown default:
                EmptyView()
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
    }
}

// MARK: - Privacy notice card

struct PrivacyNoticeCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.sm) {
            Text("🔒")
                .font(.system(size: 14))
            Text(text)
                .font(NotoTheme.Typography.metadata)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, NotoTheme.Spacing.sm + 2)
        .background(NotoTheme.Colors.success.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: NotoTheme.Radius.card,
                bottomLeadingRadius: NotoTheme.Radius.card
            )
            .fill(NotoTheme.Colors.success.opacity(0.5))
            .frame(width: 3)
        }
    }
}

#Preview("Réglages") {
    SettingsView()
        .withPreviewData()
        .environment(AppearanceManager.shared)
}
