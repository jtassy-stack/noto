import SwiftUI
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "Discover")

struct DiscoverView: View {
    let selectedChild: Child?

    @Query private var families: [Family]
    @State private var recos: [CultureSearchResult] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var selectedReco: CultureSearchResult? = nil
    @StateObject private var locationService = LocationService()

    /// Maps Pronote subject codes (uppercase, with suffixes) to clean cultural search terms.
    private static func normalizeSubject(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("math") { return "mathématiques" }
        if s.contains("phys") { return "physique chimie" }
        if s.contains("svt") || s.contains("biolog") { return "sciences naturelles" }
        if s.contains("hist") || s.contains("geo") { return "histoire géographie" }
        if s.contains("français") || s.contains("franc") || s.contains("litt") { return "littérature" }
        if s.contains("anglais") { return "anglais" }
        if s.contains("espagnol") { return "espagnol" }
        if s.contains("allemand") { return "allemand" }
        if s.contains("philosophi") { return "philosophie" }
        if s.contains("music") { return "musique" }
        if s.contains("art") { return "arts" }
        if s.contains("sport") || s.contains("eps") { return "sport" }
        if s.contains("info") || s.contains("nsi") { return "informatique" }
        if s.contains("eco") || s.contains("ses") { return "économie société" }
        // Fallback: lowercase, strip suffixes like "LVA-SI", "LV1", "LV2"
        return raw
            .replacingOccurrences(of: #"\s*LV[A-Z0-9-]*"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

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
                    ContentUnavailableView(
                        "Pas de recommandations",
                        systemImage: "safari",
                        description: Text("Les recommandations culturelles apparaîtront quand des données scolaires sont disponibles.")
                    )
                } else if !recos.isEmpty {
                    List(recos) { reco in
                        RecoRow(reco: reco)
                            .onTapGesture { selectedReco = reco }
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
                locationService.requestOnce()
                await loadRecos()
            }
            .onChange(of: children.count) { _, count in
                guard count > 0, recos.isEmpty, !isLoading else { return }
                Task { await loadRecos() }
            }
            .refreshable {
                await loadRecos()
            }
            .sheet(item: $selectedReco) { reco in
                RecoDetailView(reco: reco)
            }
        }
    }

    private func loadRecos() async {
        isLoading = true
        let client = CultureAPIClient()
        let curriculumService = CurriculumService()
        await curriculumService.load()
        let matcher = CurriculumMatcher(curriculumService: curriculumService)

        // Build query from children's school context
        logger.info("loadRecos: children=\(children.count)")
        var allTopics: [String] = []
        for child in children {
            logger.info("child \(child.firstName): grades=\(child.grades.count) schedule=\(child.schedule.count)")
            let chapters = child.schedule.compactMap { entry -> ChapterContext? in
                guard let chapter = entry.chapter else { return nil }
                return ChapterContext(subject: entry.subject, text: chapter)
            }
            // Normalize Pronote subject codes to cultural search terms
            let subjects = Set(child.grades.map { Self.normalizeSubject($0.subject) })
            logger.info("subjects: \(subjects.joined(separator: ", "))")
            allTopics.append(contentsOf: subjects)

            let query = matcher.buildCultureQuery(
                level: child.grade,
                recentChapters: chapters,
                difficulties: child.insights.filter { $0.type == .difficulty }.map {
                    DifficultyContext(subject: $0.subject, trend: -1)
                }
            )
            allTopics.append(contentsOf: query.topics)
        }

        let uniqueTopics = Array(Set(allTopics.filter { !$0.isEmpty })).prefix(5)
        logger.info("uniqueTopics: \(uniqueTopics.joined(separator: ", "))")
        guard !uniqueTopics.isEmpty else {
            isLoading = false
            hasLoaded = true
            return
        }

        let geo = locationService.location.map {
            (lat: $0.coordinate.latitude, lng: $0.coordinate.longitude)
        }
        do {
            recos = try await client.searchThematic(
                query: uniqueTopics.joined(separator: " "),
                geo: geo,
                limit: 10
            )
        } catch {
            logger.error("Culture API error: \(error)")
        }
        logger.info("recos count: \(recos.count)")

        isLoading = false
        hasLoaded = true
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
