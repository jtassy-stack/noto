import SwiftUI
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "Discover")

struct DiscoverView: View {
    @State private var selectedChild: Child?

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

    // MARK: - Section splits (LIÉ AUX COURS / SOUTIEN / AGENDA)

    /// Recos tied to a curriculum chapter (courses/homework).
    /// Podcasts and oeuvres are primarily content-based, not time-bound.
    private var recosLieAuxCours: [CultureSearchResult] {
        displayedRecos.filter { $0.type == "podcast" || $0.type == "oeuvre" }
    }

    /// Local/time-bound events (geolocalised).
    private var recosAgenda: [CultureSearchResult] {
        displayedRecos.filter { $0.type == "event" }
    }

    /// Difficulty insights across target children — drive the SOUTIEN section.
    private var wellbeingInsights: [(childName: String, insight: Insight)] {
        var pairs: [(String, Insight)] = []
        for child in children {
            for insight in child.insights where insight.type == .difficulty || insight.type == .alert {
                pairs.append((child.firstName, insight))
            }
        }
        return pairs
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

    // MARK: - Chapter matching (best-effort subject→chapter link)

    private struct ChapterMatch {
        let text: String
        let date: Date
        let isHomework: Bool
    }

    /// Index of recent chapter/homework texts keyed by normalized subject.
    /// Built once per child, used to annotate each search result.
    private static func buildChapterIndex(for child: Child) -> [String: ChapterMatch] {
        let now = Date.now
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        let weekAhead = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        var index: [String: ChapterMatch] = [:]

        // Homework first (higher intent signal for Sophie C.)
        for hw in child.homework where hw.dueDate >= now && hw.dueDate <= weekAhead {
            let key = hw.subject.lowercased()
            if index[key] == nil {
                index[key] = ChapterMatch(text: hw.descriptionText, date: hw.dueDate, isHomework: true)
            }
        }

        // Schedule chapters as fallback
        for entry in child.schedule where entry.start >= weekAgo && entry.start <= weekAhead {
            if let chapter = entry.chapter {
                let key = entry.subject.lowercased()
                if index[key] == nil {
                    index[key] = ChapterMatch(text: chapter, date: entry.start, isHomework: false)
                }
            }
        }

        return index
    }

    /// Finds the best chapter match for a search result by extracting
    /// the subject from its curriculumTags and looking it up in the index.
    private static func bestChapterMatch(
        for result: CultureSearchResult,
        index: [String: ChapterMatch]
    ) -> ChapterMatch? {
        // Try each curriculum tag — format is "3eme-histoire"
        for tag in result.curriculumTags {
            let parts = tag.split(separator: "-", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let subject = String(parts[1]).lowercased()
            // Direct match
            if let match = index[subject] { return match }
            // Fuzzy: check if any index key contains the tag subject
            if let match = index.first(where: { $0.key.contains(subject) })?.value {
                return match
            }
        }
        return nil
    }

    private var allChildren: [Child] {
        families.first?.children ?? []
    }

    private var children: [Child] {
        if let child = selectedChild { return [child] }
        return allChildren
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if allChildren.count > 1 {
                    ChildSelectorBar(
                        children: allChildren,
                        selectedChild: $selectedChild
                    )
                }

                Group {
                    if isLoading {
                        ProgressView("Chargement des recommandations…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = loadError, recos.isEmpty, wellbeingInsights.isEmpty {
                        ContentUnavailableView(
                            "Impossible de charger",
                            systemImage: "wifi.exclamationmark",
                            description: Text(error)
                        )
                    } else if recos.isEmpty && wellbeingInsights.isEmpty && hasLoaded {
                        ContentUnavailableView(
                            "Pas de recommandations",
                            systemImage: "safari",
                            description: Text("Les ressources apparaîtront quand des données scolaires sont disponibles.")
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: NotoTheme.Spacing.cardGap) {
                                // Header subtitle
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ressources liées aux cours de vos enfants")
                                        .font(NotoTheme.Typography.metadata)
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.bottom, NotoTheme.Spacing.xs)

                                // Favorites toggle — right-aligned, compact
                                HStack {
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

                                // SECTION 1 — LIÉ AUX COURS (podcasts + oeuvres)
                                if !recosLieAuxCours.isEmpty {
                                    Text("LIÉ AUX COURS")
                                        .sectionLabelStyle()

                                    ForEach(recosLieAuxCours) { reco in
                                        RecoRow(
                                            reco: reco,
                                            isBookmarked: bookmarkedIds.contains(reco.id),
                                            onBookmark: { toggleBookmark(reco.id) }
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture { selectedReco = reco }
                                    }
                                }

                                // SECTION 2 — SOUTIEN (wellbeing signals)
                                if !wellbeingInsights.isEmpty {
                                    Text("SOUTIEN")
                                        .sectionLabelStyle()

                                    ForEach(Array(wellbeingInsights.enumerated()), id: \.offset) { _, pair in
                                        WellbeingSignalCard(
                                            childName: pair.childName,
                                            insight: pair.insight
                                        )
                                    }
                                }

                                // SECTION 3 — AGENDA (events near home)
                                if !recosAgenda.isEmpty {
                                    Text("AGENDA · PRÈS DE CHEZ VOUS")
                                        .sectionLabelStyle()

                                    ForEach(recosAgenda) { reco in
                                        RecoRow(
                                            reco: reco,
                                            isBookmarked: bookmarkedIds.contains(reco.id),
                                            onBookmark: { toggleBookmark(reco.id) }
                                        )
                                        .contentShape(Rectangle())
                                        .onTapGesture { selectedReco = reco }
                                    }
                                }
                            }
                            .padding(NotoTheme.Spacing.md)
                        }
                    }
                }
                .background(NotoTheme.Colors.background)
            } // VStack (child selector + content)
            .navigationTitle("Accompagner")
            .navigationBarTitleDisplayMode(.large)
            .task(id: selectedChild?.id) {
                locationService.requestOnce()
                await loadRecos()
            }
            .onChange(of: allChildren.map(\.id)) { _, childIds in
                if let sel = selectedChild, !childIds.contains(sel.id) {
                    selectedChild = nil
                }
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

            // Cultural content is usually tagged with broad age bands
            // ("8-14", "en famille"); a 1-year grade window filters out most
            // of it via overlap checks.
            let queryAgeMin = max(3, age.min - 2)
            let queryAgeMax = min(18, age.max + 3)

            do {
                var results = try await client.searchThematic(
                    query: uniqueTopics.joined(separator: " "),
                    types: ["event", "podcast", "oeuvre"],
                    grade: apiGrade,
                    ageMin: queryAgeMin,
                    ageMax: queryAgeMax,
                    geo: geo,
                    limit: children.count > 1 ? 12 : 20
                )
                // Annotate each result with the child + best-matching chapter
                let chapterIndex = Self.buildChapterIndex(for: child)
                results = results.map {
                    var r = $0
                    r.linkedChildName = child.firstName
                    r.linkedLevel = child.grade
                    if let match = Self.bestChapterMatch(for: r, index: chapterIndex) {
                        r.linkedChapterText = match.text
                        r.linkedChapterDate = match.date
                        r.linkedChapterIsHomework = match.isHomework
                    }
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
                    SourceBadge(source: source)
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

            // Row 3: chapter link (preferred) or curriculum tag + "Pour <child>"
            if let chapter = reco.linkedChapterText {
                HStack(spacing: 4) {
                    Text(chapterLabel(text: chapter, date: reco.linkedChapterDate, isHomework: reco.linkedChapterIsHomework))
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.brand)
                        .lineLimit(1)
                    if let child = reco.linkedChildName {
                        Text("·")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                        Text(child)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
            } else {
                let gradeTags = Self.filteredGradeTags(for: reco)
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

    private static let chapterDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.setLocalizedDateFormatFromTemplate("d MMMM")
        return df
    }()

    /// "Lié à : Grèce antique — devoir du 17 avril" or "cours du"
    private func chapterLabel(text: String, date: Date?, isHomework: Bool) -> String {
        let truncated = text.count > 40 ? String(text.prefix(37)) + "…" : text
        guard let date else { return "Lié à : \(truncated)" }
        let source = isHomework ? "devoir du" : "cours du"
        return "Lié à : \(truncated) — \(source) \(Self.chapterDateFormatter.string(from: date))"
    }

    private static func filteredGradeTags(for reco: CultureSearchResult) -> [String] {
        guard let level = reco.linkedLevel else { return Array(reco.curriculumTags.prefix(1)) }
        let normalized = level.hasSuffix("e") ? String(level.dropLast()) + "eme" : level
        let filtered = reco.curriculumTags.filter { $0.hasPrefix(normalized) }
        return Array((filtered.isEmpty ? reco.curriculumTags : filtered).prefix(1))
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

// MARK: - Source Badge

/// Colored monogram badge for editorial sources (ARTE, France Culture,
/// Lumni, etc.). Sophie C. wants these to "jump out in 1 second" —
/// a color-coded initial achieves that without bundling SVG assets.
private struct SourceBadge: View {
    let source: String

    var body: some View {
        let style = resolved
        HStack(spacing: 3) {
            Text(style.monogram)
                .font(.system(size: 10, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(style.color)
                .clipShape(Circle())
            Text(source)
                .font(NotoTheme.Typography.dataSmall)
                .foregroundStyle(style.color)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(style.color.opacity(0.1))
        .clipShape(Capsule())
    }

    private static let sourceStyles: [(pattern: String, monogram: String, color: Color)] = [
        ("arte", "A", Color(red: 0.94, green: 0.45, blue: 0.08)),
        ("france culture", "FC", Color(red: 0.0, green: 0.35, blue: 0.65)),
        ("france inter", "FI", Color(red: 0.0, green: 0.35, blue: 0.65)),
        ("france musique", "FM", Color(red: 0.0, green: 0.35, blue: 0.65)),
        ("radio france", "RF", Color(red: 0.0, green: 0.35, blue: 0.65)),
        ("lumni", "L", Color(red: 0.2, green: 0.6, blue: 0.2)),
        ("bnf", "B", Color(red: 0.55, green: 0.15, blue: 0.15)),
        ("rmn", "R", NotoTheme.Colors.textSecondary),
        ("philharmonie", "P", Color(red: 0.3, green: 0.3, blue: 0.3)),
        ("universcience", "U", NotoTheme.Colors.textSecondary),
    ]

    private var resolved: (monogram: String, color: Color) {
        let key = source.lowercased()
        if let match = Self.sourceStyles.first(where: { key.contains($0.pattern) }) {
            return (match.monogram, match.color)
        }
        let m = source.first.map { String($0).uppercased() } ?? "?"
        return (m, NotoTheme.Colors.textSecondary)
    }
}

#Preview("Découvrir") {
    DiscoverView()
        .withPreviewData()
}
