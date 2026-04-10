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
    @State private var loadError: String? = nil
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
                } else if let error = loadError, recos.isEmpty {
                    ContentUnavailableView(
                        "Impossible de charger",
                        systemImage: "wifi.exclamationmark",
                        description: Text(error)
                    )
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
        loadError = nil
        let client = CultureAPIClient()
        let curriculumService = CurriculumService()
        await curriculumService.load()

        let geo = locationService.location.map {
            (lat: $0.coordinate.latitude, lng: $0.coordinate.longitude)
        }

        // Fetch recommendations per child, then interleave for balanced family view
        var perChildResults: [[CultureSearchResult]] = []

        for child in children {
            let age = curriculumService.ageRange(for: child.grade)

            var topics: [String] = []
            let subjects = Set(child.grades.map(\.subject))
            for subject in subjects {
                let themes = curriculumService.cultureTopics(for: child.grade, subject: subject, maxPerSubject: 2)
                if themes.isEmpty {
                    topics.append(Self.normalizeSubject(subject))
                } else {
                    topics.append(contentsOf: themes)
                }
            }
            if topics.isEmpty {
                topics.append(contentsOf: curriculumService.subjects(for: child.grade).prefix(4).map { Self.normalizeSubject($0) })
            }
            var uniqueTopics = Array(Set(topics.filter { !$0.isEmpty })).shuffled().prefix(6)
            if uniqueTopics.isEmpty {
                uniqueTopics = ["histoire", "sciences", "littérature", "art", "musique", "découverte"][...].prefix(6)
            }

            let apiGrade: String? = {
                guard child.level != .maternelle else { return nil }
                return curriculumService.apiGrade(for: child.grade)
            }()
            logger.info("BO topics for \(child.firstName) / \(child.grade) (api: \(apiGrade ?? "nil")): \(uniqueTopics.joined(separator: " | "))")

            do {
                var results = try await client.searchThematic(
                    query: uniqueTopics.joined(separator: " "),
                    types: ["event", "podcast", "oeuvre"],
                    grade: apiGrade,
                    ageMin: age.min,
                    ageMax: age.max,
                    geo: geo,
                    limit: children.count > 1 ? 12 : 20
                )
                // Annotate each result with the child it was fetched for
                results = results.map {
                    var r = $0
                    r.linkedChildName = child.firstName
                    r.linkedLevel = child.grade
                    return r
                }
                perChildResults.append(results.filter { $0.score.map { $0 >= 0.3 } ?? true })
            } catch {
                logger.error("Culture API error for \(child.firstName): \(error)")
                if loadError == nil {
                    loadError = "Impossible de charger les recommandations pour \(child.firstName). Vérifiez votre connexion et tirez pour réessayer."
                }
            }
        }

        // Round-robin interleave: [A0, B0, C0, A1, B1, C1, ...]
        var merged: [CultureSearchResult] = []
        let maxLen = perChildResults.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for childRecos in perChildResults where i < childRecos.count {
                merged.append(childRecos[i])
            }
        }

        // Cap at 5 per type across the full merged list
        var seen: [String: Int] = [:]
        recos = merged.filter { item in
            let count = seen[item.type, default: 0]
            guard count < 5 else { return false }
            seen[item.type] = count + 1
            return true
        }
        logger.info("recos: \(recos.count) results merged from \(children.count) child(ren)")

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
            // Row 1: type icon + typeLabel + source badge + bookmark
            HStack {
                Image(systemName: iconName)
                    .foregroundStyle(NotoTheme.Colors.brand)
                Text(typeLabel)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                if let source = reco.source, !source.isEmpty {
                    Text(source)
                        .font(NotoTheme.Typography.dataSmall)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(NotoTheme.Colors.surfaceElevated)
                        .clipShape(Capsule())
                }
                Spacer()
                Button {
                    onBookmark()
                } label: {
                    Image(systemName: isBookmarked ? "heart.fill" : "heart")
                        .foregroundStyle(isBookmarked ? NotoTheme.Colors.brand : NotoTheme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
            }

            // Row 2: title
            Text(reco.title)
                .font(NotoTheme.Typography.headline)

            // Row 3: curriculum tags + "Pour <child>" fused inline
            let gradeTags: [String] = {
                guard let level = reco.linkedLevel else { return Array(reco.curriculumTags.prefix(3)) }
                let normalized = level.hasSuffix("e") ? String(level.dropLast()) + "eme" : level
                let filtered = reco.curriculumTags.filter { $0.hasPrefix(normalized) }
                return Array((filtered.isEmpty ? reco.curriculumTags : filtered).prefix(3))
            }()
            if !gradeTags.isEmpty || reco.linkedChildName != nil {
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
                    if let child = reco.linkedChildName {
                        Text("Pour \(child)")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(NotoTheme.Colors.textSecondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }

            // Row 4: Podcast: show name + station
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

            // Row 5: description
            if let desc = reco.description, !desc.isEmpty {
                Text(desc)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .lineLimit(reco.type == "podcast" ? 2 : 3)
            }

            // Row 6: Podcast published date
            if reco.type == "podcast", let published = reco.publishedAt {
                Text(formatShortDate(published))
                    .font(NotoTheme.Typography.caption)
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

#Preview("Découvrir") {
    DiscoverView(selectedChild: nil)
        .withPreviewData()
}
