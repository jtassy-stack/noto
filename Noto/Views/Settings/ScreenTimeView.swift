import SwiftUI
import FamilyControls
import ManagedSettings

struct ScreenTimeView: View {
    @StateObject private var manager = ScreenTimeManager.shared
    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var restrictionsApplied = false
    @Environment(\.dismiss) private var dismiss

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
        .onAppear { manager.refresh() }
#if !targetEnvironment(simulator)
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        .onChange(of: selection) { applyRestrictions() }
#endif
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
        }
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
                        UIApplication.shared.open(url)
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

    private func applyRestrictions() {
        let appTokens = Set(selection.applications.compactMap(\.token))
        if appTokens.isEmpty {
            store.shield.applications = nil
        } else {
            store.shield.applications = appTokens
        }
        let catTokens = Set(selection.categories.compactMap(\.token))
        if catTokens.isEmpty {
            store.shield.applicationCategories = nil
        } else {
            let policy: ShieldSettings.ActivityCategoryPolicy = .specific(catTokens, except: Set<ApplicationToken>())
            store.shield.applicationCategories = policy
        }
        restrictionsApplied = !selection.applications.isEmpty || !selection.categories.isEmpty
    }

    private func clearRestrictions() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        selection = FamilyActivitySelection()
        restrictionsApplied = false
    }
}
