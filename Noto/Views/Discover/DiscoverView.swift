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
    @State private var showFavoritesOnly = false
    @StateObject private var locationService = LocationService()
    @AppStorage("bookmarkedRecoIds") private var bookmarkedIdsRaw: String = "[]"

    private var bookmarkedIds: Set<String> {
        (try? JSONDecoder().decode([String].self, from: Data(bookmarkedIdsRaw.utf8)))
            .map { Set($0) } ?? []
    }

    private func toggleBookmark(_ id: String) {
        var ids = bookmarkedIds
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        bookmarkedIdsRaw = (try? String(data: JSONEncoder().encode(Array(ids)), encoding: .utf8)) ?? "[]"
    }

    private var displayedRecos: [CultureSearchResult] {
        showFavoritesOnly ? recos.filter { bookmarkedIds.contains($0.id) } : recos
    }

    private var isFamilyMode: Bool { selectedChild == nil && children.count > 1 }

    /// Maps Pronote subject codes (uppercase, with suffixes) to clean cultural search terms.
    /// Maps Pronote subject codes to cultural search terms that actually yield relevant content.
    /// STEM subjects need framing as "histoire des sciences" / "biographie" to find cultural matches.
    private static func normalizeSubject(_ raw: String) -> String {
        let s = raw.lowercased()
        // STEM → cultural framing (pure subject names return unrelated books)
        if s.contains("math") { return "histoire des mathématiques logique raisonnement" }
        if s.contains("phys") { return "histoire de la physique découverte scientifique" }
        if s.contains("svt") || s.contains("biolog") { return "nature biodiversité écologie vivant" }
        if s.contains("chimi") { return "chimie découverte scientifique" }
        // Humanities → direct match
        if s.contains("hist") || s.contains("geo") { return "histoire géographie" }
        if s.contains("français") || s.contains("franc") || s.contains("litt") { return "littérature" }
        if s.contains("anglais") { return "culture anglophone" }
        if s.contains("espagnol") { return "culture hispanique" }
        if s.contains("allemand") { return "culture germanophone" }
        if s.contains("philosophi") { return "philosophie" }
        if s.contains("music") { return "musique" }
        if s.contains("art") { return "arts plastiques création" }
        if s.contains("sport") || s.contains("eps") { return "sport" }
        if s.contains("info") || s.contains("nsi") { return "numérique informatique" }
        if s.contains("eco") || s.contains("ses") { return "économie société" }
        return raw
            .replacingOccurrences(of: #"\s*LV[A-Z0-9-]*"#, with: "", options: .regularExpression)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

    /// Clean display label for a subject (shown in UI tags, not used for API search).
    private static func displaySubject(_ raw: String) -> String {
        let s = raw.lowercased()
        if s.contains("math") { return "Mathématiques" }
        if s.contains("phys") { return "Physique-Chimie" }
        if s.contains("svt") || s.contains("biolog") { return "SVT" }
        if s.contains("chimi") { return "Chimie" }
        if s.contains("hist") || s.contains("geo") { return "Histoire-Géo" }
        if s.contains("français") || s.contains("franc") || s.contains("litt") { return "Français" }
        if s.contains("anglais") { return "Anglais" }
        if s.contains("espagnol") { return "Espagnol" }
        if s.contains("allemand") { return "Allemand" }
        if s.contains("philosophi") { return "Philosophie" }
        if s.contains("music") { return "Musique" }
        if s.contains("art") { return "Arts" }
        if s.contains("sport") || s.contains("eps") { return "EPS" }
        if s.contains("info") || s.contains("nsi") { return "Informatique" }
        if s.contains("eco") || s.contains("ses") { return "SES" }
        return raw.prefix(1).uppercased() + raw.dropFirst().lowercased()
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
                    VStack(spacing: 0) {
                        // Favorites filter + family mode header
                        HStack {
                            if isFamilyMode {
                                Label("Toute la famille", systemImage: "person.3")
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            }
                            Spacer()
                            Button {
                                showFavoritesOnly.toggle()
                            } label: {
                                Label(showFavoritesOnly ? "Tous" : "Favoris",
                                      systemImage: showFavoritesOnly ? "heart.fill" : "heart")
                                    .font(NotoTheme.Typography.caption)
                            }
                            .tint(NotoTheme.Colors.brand)
                        }
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, NotoTheme.Spacing.sm)

                        List(displayedRecos) { reco in
                            RecoRow(
                                reco: reco,
                                isBookmarked: bookmarkedIds.contains(reco.id),
                                onBookmark: { toggleBookmark(reco.id) }
                            )
                            .onTapGesture { selectedReco = reco }
                        }
                        .listStyle(.plain)
                    }
                } else {
                    ContentUnavailableView(
                        "Découvrir",
                        systemImage: "safari",
                        description: Text("Des recommandations culturelles adaptées aux cours et centres d'intérêt.")
                    )
                }
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle(isFamilyMode ? "Découvrir · Famille" : selectedChild.map { "Découvrir · \($0.firstName)" } ?? "Découvrir")
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

        // For each child, build topics from BO curriculum themes + recent chapter context
        var allTopics: [String] = []
        var ageMin: Int? = nil
        var ageMax: Int? = nil

        for child in children {
            // Age range from school level
            let age = curriculumService.ageRange(for: child.grade)
            ageMin = min(ageMin ?? age.min, age.min)
            ageMax = max(ageMax ?? age.max, age.max)

            // Pull BO themes per subject studied — now that curriculum.json covers
            // Maths, SVT, Physique-Chimie, Anglais for collège, these are specific
            // and culturally relevant (e.g. "ADN hérédité génétique", "Pythagore Thalès").
            let subjects = Set(child.grades.map(\.subject))
            for subject in subjects {
                let themes = curriculumService.cultureTopics(for: child.grade, subject: subject, maxPerSubject: 2)
                if themes.isEmpty {
                    // Subject not in curriculum yet → use normalized fallback
                    allTopics.append(Self.normalizeSubject(subject))
                } else {
                    allTopics.append(contentsOf: themes)
                }
            }

            // Fallback if no grades at all
            if allTopics.isEmpty {
                allTopics.append(contentsOf: curriculumService.subjects(for: child.grade).prefix(4).map { Self.normalizeSubject($0) })
            }
        }

        var uniqueTopics = Array(Set(allTopics.filter { !$0.isEmpty })).shuffled().prefix(6)
        // Last-resort fallback: if curriculum has no data for these grades, use generic topics
        if uniqueTopics.isEmpty {
            uniqueTopics = ["histoire", "sciences", "littérature", "art", "musique", "découverte"][...].prefix(6)
        }
        // Build API-format grade for curriculum tag filtering.
        // Only pass grade for collège/lycée — the API has no primaire curriculum tags (CM1, CP, etc.)
        let apiGrade: String? = (selectedChild ?? children.first).flatMap { child in
            let level = child.level
            guard level == .college || level == .lycee else { return nil }
            return curriculumService.apiGrade(for: child.grade)
        }
        logger.info("BO topics for \(children.first?.grade ?? "?") (api: \(apiGrade ?? "nil")): \(uniqueTopics.joined(separator: " | "))")

        let geo = locationService.location.map {
            (lat: $0.coordinate.latitude, lng: $0.coordinate.longitude)
        }
        // Reference child for metadata (single child or first in family)
        let refChild = selectedChild ?? children.first

        do {
            var results = try await client.searchThematic(
                query: uniqueTopics.joined(separator: " "),
                types: ["event", "podcast", "oeuvre"],
                grade: apiGrade,
                ageMin: ageMin,
                ageMax: ageMax,
                geo: geo,
                limit: 20
            )
            // Annotate with child name + level only — subject is omitted
            // because the query is a mix of all subjects and we can't reliably
            // attribute each result to one specific course.
            if let child = refChild {
                results = results.map {
                    var r = $0
                    r.linkedChildName = child.firstName
                    r.linkedLevel = child.grade
                    return r
                }
            }
            // Balance types (max 5 per type) and drop low-relevance results
            var seen: [String: Int] = [:]
            recos = results
                .shuffled()
                .filter { $0.score.map { $0 >= 0.3 } ?? true }
                .filter { item in
                    let count = seen[item.type, default: 0]
                    guard count < 5 else { return false }
                    seen[item.type] = count + 1
                    return true
                }
            logger.info("recos: \(recos.count) results (filtered from \(results.count)) for age \(ageMin ?? 0)-\(ageMax ?? 99)")
        } catch {
            logger.error("Culture API error: \(error)")
        }

        isLoading = false
        hasLoaded = true
    }
}

// MARK: - Reco Row

private struct RecoRow: View {
    let reco: CultureSearchResult
    let isBookmarked: Bool
    let onBookmark: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(NotoTheme.Colors.brand)
                Text(typeLabel)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                Spacer()
                Button {
                    onBookmark()
                } label: {
                    Image(systemName: isBookmarked ? "heart.fill" : "heart")
                        .foregroundStyle(isBookmarked ? NotoTheme.Colors.brand : NotoTheme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }

            Text(reco.title)
                .font(NotoTheme.Typography.headline)

            // Podcast: show name + station above description
            if reco.type == "podcast" {
                HStack(spacing: NotoTheme.Spacing.xs) {
                    if let show = reco.showName {
                        Text(show)
                            .font(NotoTheme.Typography.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                    }
                    if let station = reco.station {
                        Text("·")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                        Text(station)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
                if let episode = reco.episodeTitle, !episode.isEmpty, episode != reco.title {
                    Text(episode)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
            }

            if let desc = reco.description, !desc.isEmpty {
                Text(desc)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .lineLimit(reco.type == "podcast" ? 2 : 3)
            }

            // Podcast: duration / published date
            if reco.type == "podcast", let published = reco.publishedAt {
                Text(formatShortDate(published))
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }

            // Curriculum tags — filtered to this child's grade level only
            let gradeTags: [String] = {
                guard let level = reco.linkedLevel else { return Array(reco.curriculumTags.prefix(3)) }
                let normalized = level.hasSuffix("e") ? String(level.dropLast()) + "eme" : level
                let filtered = reco.curriculumTags.filter { $0.hasPrefix(normalized) }
                return Array((filtered.isEmpty ? reco.curriculumTags : filtered).prefix(3))
            }()
            if !gradeTags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(gradeTags, id: \.self) { tag in
                        Text(Self.formatCurriculumTag(tag))
                            .font(NotoTheme.Typography.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(NotoTheme.Colors.brand.opacity(0.1))
                            .foregroundStyle(NotoTheme.Colors.brand)
                            .clipShape(Capsule())
                    }
                }
            }

            // Child / level context tag
            if let child = reco.linkedChildName, let level = reco.linkedLevel {
                HStack(spacing: 4) {
                    Image(systemName: "person")
                        .font(.system(size: 10))
                    Text("Pour \(child) · \(level)")
                        .font(NotoTheme.Typography.caption)
                }
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
        }
        .padding(.vertical, NotoTheme.Spacing.xs)
    }

    private func formatShortDate(_ isoString: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: isoString) ?? ISO8601DateFormatter().date(from: isoString)
        guard let date else { return isoString }
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateStyle = .medium
        df.timeStyle = .none
        return df.string(from: date)
    }

    private var iconName: String {
        switch reco.type {
        case "podcast": "headphones"
        case "oeuvre": "paintpalette"
        case "event": "calendar"
        default: "star"
        }
    }

    private var typeLabel: String {
        switch reco.type {
        case "podcast": "Podcast"
        case "oeuvre": "Œuvre"
        case "event": "Événement"
        default: reco.type.capitalized
        }
    }

    /// Formats "3eme-histoire" → "Histoire · 3e"
    private static func formatCurriculumTag(_ tag: String) -> String {
        let parts = tag.split(separator: "-", maxSplits: 1)
        guard parts.count == 2 else { return tag }
        let grade = String(parts[0])
            .replacingOccurrences(of: "eme", with: "e")
            .replacingOccurrences(of: "ere", with: "re")
        let subject = String(parts[1]).prefix(1).uppercased() + String(parts[1]).dropFirst()
        return "\(subject) · \(grade)"
    }
}
