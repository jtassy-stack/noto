import SwiftUI
import SwiftData

struct DiscoverView: View {
    let selectedChild: Child?

    @Query private var families: [Family]
    @State private var recos: [CultureSearchResult] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var showAPIKeySetup = false

    private var children: [Child] {
        if let child = selectedChild { return [child] }
        return families.first?.children ?? []
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Chargement des recommandations…")
                } else if recos.isEmpty && hasLoaded {
                    if !hasAPIKey {
                        ContentUnavailableView {
                            Label("Configurer Découvrir", systemImage: "key.fill")
                        } description: {
                            Text("Entrez votre clé API culture pour accéder aux recommandations.")
                        } actions: {
                            Button("Configurer") {
                                showAPIKeySetup = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView(
                            "Pas de recommandations",
                            systemImage: "safari",
                            description: Text("Les recommandations culturelles apparaîtront quand des données scolaires sont disponibles.")
                        )
                    }
                } else if !recos.isEmpty {
                    List(recos, id: \.id) { reco in
                        RecoRow(reco: reco)
                    }
                    .listStyle(.plain)
                } else {
                    ContentUnavailableView(
                        "Découvrir",
                        systemImage: "safari",
                        description: Text("Des recommandations culturelles adaptées aux cours et centres d'intérêt.")
                    )
                }
            }
            .navigationTitle("Découvrir")
            .navigationBarTitleDisplayMode(.large)
            .task(id: selectedChild?.id) {
                await loadRecos()
            }
            .refreshable {
                await loadRecos()
            }
            .sheet(isPresented: $showAPIKeySetup) {
                APIKeySetupSheet {
                    await loadRecos()
                }
            }
        }
    }

    private var hasAPIKey: Bool {
        guard let data = try? KeychainService.load(key: "culture_api_key"),
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty else { return false }
        return true
    }

    private func loadRecos() async {
        // Check if we have an API key
        guard let keyData = try? KeychainService.load(key: "culture_api_key"),
              let apiKey = String(data: keyData, encoding: .utf8) else {
            hasLoaded = true
            return
        }

        isLoading = true
        let client = CultureAPIClient(apiKey: apiKey)
        let curriculumService = CurriculumService()
        await curriculumService.load()
        let matcher = CurriculumMatcher(curriculumService: curriculumService)

        // Build query from children's school context
        var allTopics: [String] = []
        for child in children {
            let chapters = child.schedule.compactMap { entry -> ChapterContext? in
                guard let chapter = entry.chapter else { return nil }
                return ChapterContext(subject: entry.subject, text: chapter)
            }
            // Also use subjects as topics
            let subjects = Set(child.grades.map(\.subject))
            for subject in subjects {
                allTopics.append(subject)
            }

            let query = matcher.buildCultureQuery(
                level: child.grade,
                recentChapters: chapters,
                difficulties: child.insights.filter { $0.type == .difficulty }.map {
                    DifficultyContext(subject: $0.subject, trend: -1)
                }
            )
            allTopics.append(contentsOf: query.topics)
        }

        let uniqueTopics = Array(Set(allTopics)).prefix(5)
        guard !uniqueTopics.isEmpty else {
            isLoading = false
            hasLoaded = true
            return
        }

        do {
            recos = try await client.searchThematic(
                query: uniqueTopics.joined(separator: " "),
                limit: 10
            )
        } catch {
            NSLog("[noto] Culture API error: \(error)")
        }

        isLoading = false
        hasLoaded = true
    }
}

// MARK: - API Key Setup Sheet

struct APIKeySetupSheet: View {
    let onSave: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var apiKey: String = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Clé Bearer culture-api", text: $apiKey)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                } header: {
                    Text("Clé API culture")
                } footer: {
                    Text("La clé est stockée de façon sécurisée sur l'appareil et n'est jamais transmise à un serveur tiers.")
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(NotoTheme.Typography.caption)
                    }
                }
            }
            .navigationTitle("Configurer Découvrir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sauvegarder") {
                        Task { await save() }
                    }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
    }

    private func save() async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSaving = true
        do {
            guard let data = trimmed.data(using: .utf8) else { throw KeychainError.saveFailed(0) }
            try KeychainService.save(key: "culture_api_key", data: data)
            dismiss()
            await onSave()
        } catch {
            errorMessage = "Erreur lors de la sauvegarde: \(error.localizedDescription)"
        }
        isSaving = false
    }
}

// MARK: - Reco Row

private struct RecoRow: View {
    let reco: CultureSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(NotoTheme.Colors.brand)
                Text(reco.type.capitalized)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }

            Text(reco.title)
                .font(NotoTheme.Typography.headline)

            if let desc = reco.description, !desc.isEmpty {
                Text(desc)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .lineLimit(3)
            }

            if !reco.topics.isEmpty {
                HStack {
                    ForEach(reco.topics.prefix(3), id: \.self) { topic in
                        Text(topic)
                            .font(NotoTheme.Typography.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(NotoTheme.Colors.brand.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.vertical, NotoTheme.Spacing.xs)
    }

    private var iconName: String {
        switch reco.type {
        case "podcast": "headphones"
        case "oeuvre": "paintpalette"
        case "event": "calendar"
        default: "star"
        }
    }
}
