import SwiftUI
import SwiftData

/// Sheet presenting the mail whitelist: auto-detected entries (school
/// domain + teachers from Pronote) + manual entries (editable).
struct MailDomainsView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var families: [Family]

    @State private var manualEntries: [MailWhitelistEntry] = []
    @State private var showAddPrompt = false
    @State private var newPattern: String = ""
    @State private var addError: String?

    private var children: [Child] { families.first?.children ?? [] }

    private var autoEntries: [MailWhitelistEntry] {
        MailWhitelist.build(from: children).filter { $0.source != .manual }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
                    if !autoEntries.isEmpty {
                        autoSection
                    }
                    manualSection
                    explainer
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("Domaines autorisés")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        newPattern = ""
                        addError = nil
                        showAddPrompt = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Ajouter un domaine", isPresented: $showAddPrompt) {
                TextField("ecole.fr ou prof@ecole.fr", text: $newPattern)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Ajouter", action: addManualEntry)
                Button("Annuler", role: .cancel) { }
            } message: {
                Text(addError ?? "Saisissez un domaine complet (ex. monlycee.net) ou une adresse e-mail exacte.")
            }
            .task {
                manualEntries = MailWhitelist.loadManual()
            }
        }
    }

    // MARK: - Sections

    private var autoSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Détectés automatiquement")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                ForEach(Array(autoEntries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Divider().padding(.leading, NotoTheme.Spacing.md)
                    }
                    entryRow(entry, canDelete: false)
                }
            }
            .notoCard()
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Ajoutés manuellement")
                .sectionLabelStyle()
                .padding(.horizontal, NotoTheme.Spacing.xs)

            VStack(spacing: 0) {
                if manualEntries.isEmpty {
                    HStack {
                        Text("Aucune entrée manuelle")
                            .font(NotoTheme.Typography.body)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, 14)
                } else {
                    ForEach(Array(manualEntries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                        Divider().padding(.leading, NotoTheme.Spacing.md)
                    }
                        entryRow(entry, canDelete: true)
                    }
                }
            }
            .notoCard()
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                Text("Seuls les mails envoyés par ces adresses ou domaines sont synchronisés. Vos autres mails (perso, newsletters, factures) restent dans votre boîte mail et ne sont jamais lus par nōto.")
                    .font(NotoTheme.Typography.metadata)
            }
            .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .padding(NotoTheme.Spacing.md)
        .background(NotoTheme.Colors.signalColor(.positive).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
    }

    // MARK: - Row

    @ViewBuilder
    private func entryRow(_ entry: MailWhitelistEntry, canDelete: Bool) -> some View {
        HStack(spacing: NotoTheme.Spacing.sm) {
            Image(systemName: entry.isDomainPattern ? "globe" : "person.crop.circle")
                .font(.system(size: 14))
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.pattern)
                    .font(NotoTheme.Typography.signalTitle)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(sourceLabel(entry.source))
                    .font(NotoTheme.Typography.metadata)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.65)
            }

            Spacer()

            if canDelete {
                Button(role: .destructive) {
                    remove(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 14))
                        .foregroundStyle(NotoTheme.Colors.danger)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 12)
    }

    private func sourceLabel(_ source: MailWhitelistEntry.Source) -> String {
        switch source {
        case .schoolDomain:       "Domaine de l'école"
        case .teacherFromPronote: "Enseignant Pronote"
        case .manual:             "Ajouté par vous"
        }
    }

    // MARK: - Actions

    private func addManualEntry() {
        do {
            try MailWhitelist.addManual(newPattern)
            manualEntries = MailWhitelist.loadManual()
            addError = nil
        } catch {
            addError = error.localizedDescription
            // Re-prompt with the error visible — alert closed, so reopen
            showAddPrompt = true
        }
    }

    private func remove(_ entry: MailWhitelistEntry) {
        do {
            try MailWhitelist.removeManual(id: entry.id)
            manualEntries = MailWhitelist.loadManual()
        } catch {
            addError = "Impossible de supprimer : \(error.localizedDescription)"
            showAddPrompt = true
        }
    }
}
