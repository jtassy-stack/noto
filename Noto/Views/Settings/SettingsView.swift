import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var families: [Family]

    @State private var cultureAPIKeyMasked: String? = nil
    @State private var showAPIKeySetup = false
    @State private var showClearDataConfirmation = false

    private var family: Family? { families.first }

    var body: some View {
        NavigationStack {
            List {
                // MARK: Connexions
                Section("Connexions") {
                    if let children = family?.children, !children.isEmpty {
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

                // MARK: Culture API
                Section("Culture API") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Clé API")
                                .font(NotoTheme.Typography.body)
                            if let masked = cultureAPIKeyMasked {
                                Text("••••\(masked)")
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            } else {
                                Text("Non configurée")
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            }
                        }
                        Spacer()
                        Button("Modifier") {
                            showAPIKeySetup = true
                        }
                        .font(NotoTheme.Typography.caption)
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
            .onAppear {
                refreshCultureKeyStatus()
            }
            .sheet(isPresented: $showAPIKeySetup, onDismiss: refreshCultureKeyStatus) {
                APIKeySetupSheet { }
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
        }
    }

    // MARK: - Actions

    private func refreshCultureKeyStatus() {
        guard let data = try? KeychainService.load(key: "culture_api_key"),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else {
            cultureAPIKeyMasked = nil
            return
        }
        cultureAPIKeyMasked = String(key.suffix(4))
    }

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
        KeychainService.delete(key: "culture_api_key")
        try? modelContext.save()
    }
}
