import SwiftUI

struct CommandSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let children: [Child]
    let onSelect: (Notification.Name) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var suggestions: [CommandSuggestion] {
        let base = baseSuggestions
        guard !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    private var baseSuggestions: [CommandSuggestion] {
        var items: [CommandSuggestion] = []

        for child in children {
            items.append(CommandSuggestion(
                title: "Notes de \(child.firstName)",
                subtitle: "Aller dans l'onglet École",
                notification: .navigateToSchool
            ))
        }

        items.append(CommandSuggestion(
            title: "Carnet à signer",
            subtitle: "Aller dans Messages",
            notification: .navigateToMessages
        ))

        items.append(CommandSuggestion(
            title: "Photos de la sortie",
            subtitle: "Aller dans Messages",
            notification: .navigateToMessages
        ))

        for child in children {
            items.append(CommandSuggestion(
                title: "Sorties pour \(child.firstName)",
                subtitle: "Aller dans Sorties",
                notification: .navigateToDiscover
            ))
        }

        items.append(CommandSuggestion(
            title: "Réglages des alertes",
            subtitle: "Ouvrir les réglages",
            notification: .navigateToSettings
        ))

        return items
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: NotoTheme.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .font(.system(size: 16))

                    TextField("Chercher…", text: $query)
                        .font(NotoTheme.Typography.functional(16, weight: .regular))
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()

                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                                .font(.system(size: 16))
                        }
                    }
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.sm)
                .notoCard()
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.top, NotoTheme.Spacing.md)

                if suggestions.isEmpty {
                    Spacer()
                    Text("Aucun résultat")
                        .font(NotoTheme.Typography.metadata)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                    Spacer()
                } else {
                    List {
                        Section {
                            ForEach(suggestions) { item in
                                Button {
                                    onSelect(item.notification)
                                    dismiss()
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(NotoTheme.Typography.functional(16, weight: .semibold))
                                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                                            Text(item.subtitle)
                                                .font(NotoTheme.Typography.metadata)
                                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                                            .opacity(0.5)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("SAUTER À…")
                                .sectionLabelStyle()
                                .textCase(nil)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                        .font(NotoTheme.Typography.functional(16, weight: .regular))
                        .foregroundStyle(NotoTheme.Colors.brand)
                }
            }
        }
        .onAppear { searchFocused = true }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Model

private struct CommandSuggestion: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let notification: Notification.Name
}
