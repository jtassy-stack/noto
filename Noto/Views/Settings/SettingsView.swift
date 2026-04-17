import SwiftUI
import SwiftData
import UserNotifications

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
    @State private var imapConfig: IMAPServerConfig?

    @AppStorage("notif_homework") private var notifHomework: Bool = true
    @AppStorage("notif_difficulty") private var notifDifficulty: Bool = true
    @AppStorage("notif_carnet") private var notifCarnet: Bool = true
    @AppStorage("notif_grade_threshold") private var gradeThreshold: Double = 10.0
    @AppStorage("notif_absence") private var notifAbsence: Bool = true

    private var family: Family? { families.first }
    private var children: [Child] { family?.children ?? [] }

    private var whitelistCountLabel: String {
        // Dedicated channels (monlycée.net) don't apply filtering — the
        // row would show "0 entrées" which implies "nothing is synced"
        // and contradicts what the parent actually sees in the feed.
        if imapConfig?.isDedicatedSchoolChannel == true {
            return "Désactivé"
        }
        let count = MailWhitelist.build(from: children).count
        return count == 1 ? "1 entrée" : "\(count) entrées"
    }

    private var mailboxFilterRowLabel: String {
        imapConfig?.isDedicatedSchoolChannel == true
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

    /// Comma-separated first names of children whose mail is synced via IMAP.
    /// Since the account is global, this is always all configured children.
    private var imapCoveredChildrenLabel: String {
        guard !children.isEmpty else { return "—" }
        return children.map { $0.firstName }.joined(separator: ", ")
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
                    if imapConfig != nil {
                        mailboxSection
                    }
                    notificationsSection
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
            .task {
                await refreshAuthStatus()
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
                    subtitle: imapConfig.map { $0.username } ?? "Filtrer les emails scolaires",
                    badge: imapConfig == nil ? .notConfigured : .connected,
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
            Text("Boîte mail")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                InfoRow(label: "Fournisseur", value: imapConfig?.providerDisplayName ?? "—")
                SettingsDivider()
                InfoRow(label: "Compte", value: imapConfig?.username ?? "—")
                SettingsDivider()
                InfoRow(label: "Enfants couverts", value: imapCoveredChildrenLabel)
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
                Button(role: .destructive) {
                    disconnectIMAP()
                } label: {
                    HStack {
                        Text("Déconnecter la boîte mail")
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
        imapConfig = IMAPService.loadConfig()
    }

    // MARK: Actions

    private func disconnect(child: Child) {
        // Best-effort Keychain cleanup — log on failure so ops can see
        // lingering tokens rather than silently leaving them on device.
        do {
            try KeychainService.delete(key: "PronoteRefreshToken_\(child.id)")
        } catch {
            NSLog("[noto][warn] disconnect(child:) Keychain delete failed: \(error.localizedDescription)")
        }
        modelContext.delete(child)
        try? modelContext.save()
    }

    private func disconnectIMAP() {
        do {
            try IMAPService.clearConfig()
            imapConfig = nil
        } catch {
            NSLog("[noto][warn] disconnectIMAP failed: \(error.localizedDescription)")
            // Re-read state so the UI reflects reality rather than an
            // optimistic clear that didn't actually land.
            imapConfig = IMAPService.loadConfig()
        }
    }

    private func clearAllData() {
        for family in families {
            modelContext.delete(family)
        }
        if let children = family?.children {
            for child in children {
                try? KeychainService.delete(key: "PronoteRefreshToken_\(child.id)")
            }
        }
        try? IMAPService.clearConfig()
        imapConfig = nil
        try? modelContext.save()
    }
}

// MARK: - Shared row building blocks

/// 1px horizontal divider used between rows inside a `.notoCard()` group.
private struct SettingsDivider: View {
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

    private var systemName: String {
        switch child.schoolType {
        case .pronote: "Pronote"
        case .ent: child.entProvider?.name ?? "ENT"
        }
    }

    private var isLinkedToDirectory: Bool { child.rneCode != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
            if !isLinkedToDirectory {
                linkCTA
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
