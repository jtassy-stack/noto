import SwiftUI
import SwiftData
import UserNotifications

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Query private var families: [Family]

    @State private var showClearDataConfirmation = false
    @State private var notifAuthStatus: UNAuthorizationStatus = .notDetermined

    @AppStorage("notif_homework") private var notifHomework: Bool = true
    @AppStorage("notif_difficulty") private var notifDifficulty: Bool = true

    private var family: Family? { families.first }

    var body: some View {
        NavigationStack {
            List {
                // MARK: Connexions
                Section("Connexions") {
                    if let children = family?.children, \!children.isEmpty {
                        ForEach(children) { child in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(child.firstName)
                                        .font(NotoTheme.Typography.headline)
                                    Text("\(child.establishment) · \(child.grade)")
                                        .font(NotoTheme.Typography.caption)
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                }
                                Spacer()
                                Button("Déconnecter") {
                                    disconnect(child: child)
                                }
                                .foregroundStyle(.red)
                                .font(NotoTheme.Typography.caption)
                            }
                        }
                    } else {
                        Text("Aucun compte connecté")
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }

                // MARK: Notifications
                Section("Notifications") {
                    Toggle(isOn: $notifHomework) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rappel devoirs")
                                .font(NotoTheme.Typography.headline)
                            Text("Veille à 8h00")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                    }
                    .disabled(notifAuthStatus == .denied)

                    Toggle(isOn: $notifDifficulty) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Alerte difficulté détectée")
                                .font(NotoTheme.Typography.headline)
                            Text("Quand le ML repère une baisse")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                    }
                    .disabled(notifAuthStatus == .denied)

                    // Statut d'autorisation
                    HStack {
                        switch notifAuthStatus {
                        case .authorized, .provisional, .ephemeral:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(NotoTheme.Colors.success)
                            Text("Notifications autorisées")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        case .denied:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(NotoTheme.Colors.danger)
                            Text("Désactivées dans Réglages iOS")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                            Spacer()
                            Button("Ouvrir Réglages") {
                                if let url = URL(string: "app-settings:") {
                                    openURL(url)
                                }
                            }
                            .font(NotoTheme.Typography.caption)
                        case .notDetermined:
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                            Text("Autorisation non demandée")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                            Spacer()
                            Button("Autoriser") {
                                Task {
                                    _ = await NotificationService.shared.requestAuthorization()
                                    await refreshAuthStatus()
                                }
                            }
                            .font(NotoTheme.Typography.caption)
                        @unknown default:
                            EmptyView()
                        }
                    }
                }

                // MARK: Données
                Section("Données") {
                    Button(role: .destructive) {
                        showClearDataConfirmation = true
                    } label: {
                        Text("Effacer toutes les données")
                    }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.large)
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
            .task {
                await refreshAuthStatus()
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func refreshAuthStatus() async {
        notifAuthStatus = await NotificationService.shared.authorizationStatus()
    }

    // MARK: - Actions

    private func disconnect(child: Child) {
        // Remove Pronote credentials from Keychain
        KeychainService.delete(key: "PronoteRefreshToken_\(child.id)")
        // Delete child from SwiftData
        modelContext.delete(child)
        try? modelContext.save()
    }

    private func clearAllData() {
        // Delete all families (cascade deletes children and related data)
        for family in families {
            modelContext.delete(family)
        }
        // Clear all Keychain entries
        if let children = family?.children {
            for child in children {
                KeychainService.delete(key: "PronoteRefreshToken_\(child.id)")
            }
        }
        try? modelContext.save()
    }
}
