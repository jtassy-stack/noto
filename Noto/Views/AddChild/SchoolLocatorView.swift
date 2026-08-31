import SwiftUI
import CoreLocation

/// First step of the "add a child" flow: find the establishment by
/// geolocation (école/collège/lycée), then route straight to the right
/// login screen instead of making the parent guess which of Pronote /
/// Skolengo / an ENT / École Directe their school uses.
///
/// Falls back to the existing static provider list (`ManualProviderListView`,
/// the previous `AddChildView` content) via a link at the bottom, for
/// establishments the directory doesn't know or a location the parent
/// doesn't want to share.
struct SchoolLocatorView: View {
    var onDismissAll: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @StateObject private var locationService = LocationService()

    @State private var selectedKind: SchoolKindFilter = .college
    @State private var communeState: CommuneState = .idle
    @State private var schools: [DirectorySchoolSummary] = []
    @State private var isLoadingSchools = false
    @State private var route: SuggestedConnectionRoute?
    @State private var isResolvingSelection = false
    @State private var selectionError: String?

    // Manual search — always available, not just a fallback for when geo
    // fails: a parent may simply know the school's name, or the geo result
    // may miss it (directory coverage gaps, imprecise location).
    @State private var searchText = ""
    @State private var searchResults: [DirectorySchoolSummary]?
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    private let directoryClient = DirectoryAPIClient()

    enum SchoolKindFilter: String, CaseIterable {
        case ecole = "École"
        case college = "Collège"
        case lycee = "Lycée"

        /// Diacritic/case-insensitive match against celyn's `kind` field,
        /// which mixes accented and unaccented forms ("ecole" vs "collège").
        func matches(_ kind: String?) -> Bool {
            guard let kind else { return false }
            let folded = kind.folding(options: .diacriticInsensitive, locale: .current).lowercased()
            switch self {
            case .ecole: return folded == "ecole"
            case .college: return folded == "college"
            case .lycee: return folded == "lycee"
            }
        }
    }

    enum CommuneState: Equatable {
        case idle
        case resolving
        case resolved(GeoCommuneResolver.Commune)
        case denied
        case error(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Niveau", selection: $selectedKind) {
                    ForEach(SchoolKindFilter.allCases, id: \.self) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.top, NotoTheme.Spacing.sm)
                .onChange(of: selectedKind) { _, _ in
                    Task { await loadSchoolsForCurrentCommune() }
                    onSearchTextChanged()
                }

                searchField

                content

                Divider()

                NavigationLink {
                    ManualProviderListView(onDismissAll: onDismissAll ?? { dismiss() })
                } label: {
                    HStack {
                        Text("Je ne trouve pas l'établissement — voir tous les services")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    .padding(NotoTheme.Spacing.md)
                }
                .buttonStyle(.plain)
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("Ajouter un enfant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { (onDismissAll ?? { dismiss() })() }
                }
            }
            .navigationDestination(item: $route) { route in
                destinationView(for: route)
            }
            .task {
                locationService.requestOnce()
            }
            // CLLocation isn't Equatable, so `.onChange` can't observe it
            // directly — Combine's `.onReceive` sidesteps that requirement.
            .onReceive(locationService.$location.compactMap { $0 }) { newLocation in
                guard communeState == .idle || communeState == .resolving else { return }
                Task { await resolveCommune(newLocation.coordinate) }
            }
            .onChange(of: locationService.authStatus) { _, status in
                if status == .denied || status == .restricted {
                    communeState = .denied
                }
            }
        }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            TextField("Rechercher par nom d'établissement…", text: $searchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .onChange(of: searchText) { _, _ in onSearchTextChanged() }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    onSearchTextChanged()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
        }
        .padding(NotoTheme.Spacing.md)
        .background(NotoTheme.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.top, NotoTheme.Spacing.sm)
    }

    private var isSearchActive: Bool {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    private func onSearchTextChanged() {
        searchTask?.cancel()
        guard isSearchActive else {
            searchResults = nil
            isSearching = false
            return
        }
        let query = searchText
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            do {
                let results = try await directoryClient.searchSchools(q: query, limit: 30)
                guard !Task.isCancelled else { return }
                searchResults = results.filter { selectedKind.matches($0.kind) }
            } catch {
                guard !Task.isCancelled else { return }
                searchResults = []
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isSearchActive {
            searchContent
        } else {
            geoContent
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        VStack(spacing: 0) {
            if isSearching {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let searchResults, searchResults.isEmpty {
                emptyHint
            } else if let searchResults {
                resultsList(searchResults)
            }
            if let selectionError {
                Label(selectionError, systemImage: "exclamationmark.triangle")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.danger)
                    .padding(NotoTheme.Spacing.md)
            }
        }
    }

    @ViewBuilder
    private var geoContent: some View {
        switch communeState {
        case .idle, .resolving:
            VStack(spacing: NotoTheme.Spacing.sm) {
                Spacer()
                ProgressView()
                Text("Localisation en cours…")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                Spacer()
            }
        case .denied:
            deniedHint
        case .error(let message):
            errorHint(message)
        case .resolved(let commune):
            VStack(spacing: 0) {
                Text("Établissements près de \(commune.name)")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .padding(.vertical, NotoTheme.Spacing.sm)
                if isLoadingSchools {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if schools.isEmpty {
                    emptyHint
                } else {
                    resultsList(schools)
                }
                if let selectionError {
                    Label(selectionError, systemImage: "exclamationmark.triangle")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.danger)
                        .padding(NotoTheme.Spacing.md)
                }
            }
        }
    }

    private var deniedHint: some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Spacer()
            Image(systemName: "location.slash")
                .font(.system(size: 32))
                .foregroundStyle(NotoTheme.Colors.textSecondary.opacity(0.6))
            Text("Localisation désactivée")
                .font(NotoTheme.Typography.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Text("Activez la localisation dans Réglages, ou utilisez la recherche par nom ci-dessus.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.xl)
            Spacer()
        }
    }

    private func errorHint(_ message: String) -> some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(NotoTheme.Colors.amber)
            Text(message)
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.xl)
            Spacer()
        }
    }

    private var emptyHint: some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Spacer()
            Text(isSearchActive
                ? "Aucun \(selectedKind.rawValue.lowercased()) trouvé pour « \(searchText) »."
                : "Aucun \(selectedKind.rawValue.lowercased()) trouvé à proximité.")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.lg)
            if !isSearchActive {
                Text("Essayez la recherche par nom ci-dessus.")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary.opacity(0.8))
            }
            Spacer()
        }
    }

    private func resultsList(_ schools: [DirectorySchoolSummary]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(schools.enumerated()), id: \.element.id) { index, school in
                    if index > 0 {
                        Divider().padding(.leading, NotoTheme.Spacing.md)
                    }
                    Button {
                        Task { await selectSchool(school) }
                    } label: {
                        schoolRow(school)
                    }
                    .buttonStyle(.plain)
                    .disabled(isResolvingSelection)
                }
            }
            .notoCard()
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.bottom, NotoTheme.Spacing.md)
        }
    }

    private func schoolRow(_ school: DirectorySchoolSummary) -> some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(school.name)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                if let academy = school.academy {
                    Text(academy)
                        .font(NotoTheme.Typography.metadata)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .opacity(0.65)
                }
            }
            Spacer()
            if isResolvingSelection {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .opacity(0.5)
            }
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, 14)
    }

    // MARK: - Location → commune → schools

    private func resolveCommune(_ coordinate: CLLocationCoordinate2D) async {
        communeState = .resolving
        do {
            let commune = try await GeoCommuneResolver.resolve(coordinate: coordinate)
            communeState = .resolved(commune)
            await loadSchoolsForCurrentCommune()
        } catch {
            communeState = .error("Localisation indisponible. Utilisez la recherche par nom ci-dessus.")
        }
    }

    private func loadSchoolsForCurrentCommune() async {
        guard case .resolved(let commune) = communeState else { return }
        isLoadingSchools = true
        defer { isLoadingSchools = false }
        do {
            let results = try await directoryClient.searchSchools(insee: commune.insee, limit: 50)
            schools = results.filter { selectedKind.matches($0.kind) }
        } catch {
            schools = []
        }
    }

    // MARK: - Selection → routing

    private func selectSchool(_ summary: DirectorySchoolSummary) async {
        selectionError = nil
        isResolvingSelection = true
        defer { isResolvingSelection = false }
        do {
            let school = try await directoryClient.fetchSchool(rne: summary.rne)
            route = SuggestedConnectionRoute(
                kind: SuggestedConnectionRoute.suggest(for: school, levelFilter: selectedKind),
                schoolName: school.name
            )
        } catch {
            // Directory lookup failed — fall back to the generic provider
            // list rather than blocking the parent on a network hiccup.
            route = SuggestedConnectionRoute(kind: .unknown, schoolName: summary.name)
        }
    }

    @ViewBuilder
    private func destinationView(for route: SuggestedConnectionRoute) -> some View {
        switch route.kind {
        case .pronote, .unknown:
            PronoteQRLoginView()
        case .ecoleDirecte:
            EcoleDirecteLoginView(onDismissAll: onDismissAll)
        case .ent(let provider):
            ENTLoginView(provider: provider, onDismissAll: onDismissAll)
        case .skolengo:
            SkolengoLoginView(onDismissAll: onDismissAll)
        }
    }
}

// MARK: - Routing

/// Which login screen a celyn establishment maps to. Best-effort in two
/// senses: (1) a school having a known ENT doesn't guarantee it's the
/// family's only or preferred connection (many schools run Pronote
/// alongside a regional ENT) — this picks the most likely single starting
/// point, and the parent can always back out to `ManualProviderListView`;
/// (2) celyn's per-school `ent` link is populated for only a small
/// fraction of establishments (confirmed empirically — e.g. Collège
/// Camille Sée, Paris 15e, has `ent: null` despite Paris collèges
/// universally running PCN) — so this falls back to an académie/région
/// heuristic when the direct link is missing, rather than defaulting
/// every unlinked school to the same guess.
struct SuggestedConnectionRoute: Identifiable, Hashable {
    enum Kind {
        case pronote
        case ecoleDirecte
        case ent(ENTProvider)
        case skolengo
        case unknown
    }

    let id = UUID()
    let kind: Kind
    let schoolName: String

    // `Kind` doesn't need to be Hashable for navigation purposes — the
    // UUID alone is a unique-enough identity for `navigationDestination(item:)`.
    static func == (lhs: SuggestedConnectionRoute, rhs: SuggestedConnectionRoute) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// ids from `Noto/Resources/directory/ents.json` that are Skolengo/Kosmos
    /// deployments — kept in sync manually since the registry doesn't carry
    /// a "backing platform" field (see the Skolengo connector's implementation notes).
    private static let skolengoRegistryIds: Set<String> = [
        "kdecole", "sn5962", "arsene76",
        "ent-occitanie", "ent-aura", "ent-bfc", "ent-grandest",
        "ent-corse", "ent-savoie", "ent-hautesavoie", "ent-loire", "ent-isere",
    ]

    /// Région names (as celyn returns them — accenting is inconsistent,
    /// e.g. "Ile-de-France" unaccented vs "Auvergne-Rhône-Alpes" accented,
    /// hence the diacritic-folded comparison) covered by Skolengo.
    private static let skolengoRegionNames: Set<String> = [
        "occitanie", "auvergne-rhone-alpes", "bourgogne-franche-comte", "grand est", "corse",
    ]

    static func suggest(for school: DirectorySchool, levelFilter: SchoolLocatorView.SchoolKindFilter) -> Kind {
        if let entId = school.ent?.id {
            switch entId {
            case "pcn": return .ent(.pcn)
            case "monlycee": return .ent(.monlycee)
            case "ecoledirecte": return .ecoleDirecte
            case "pronote": return .pronote
            default:
                return skolengoRegistryIds.contains(entId) ? .skolengo : .unknown
            }
        }

        // No direct ENT link — infer from académie/région, since that's
        // the common case, not the exception.
        let region = (school.commune?.region ?? "").folding(options: .diacriticInsensitive, locale: .current).lowercased()
        let academy = school.academy ?? ""

        if levelFilter == .lycee, region.contains("ile-de-france") {
            return .ent(.monlycee)
        }
        if levelFilter != .lycee, academy == "Paris" {
            // Paris Classe Numérique covers écoles/collèges within the
            // city proper — Paris lycées are handled by the IdF-wide
            // MonLycée case above.
            return .ent(.pcn)
        }
        if skolengoRegionNames.contains(where: { region.contains($0) }) {
            return .skolengo
        }
        // Pronote is near-universal for collège/lycée regardless of which
        // ENT sits alongside it — a defensible default at those levels.
        // Not for écoles: primary schools typically don't run Pronote, so
        // guessing it there is more likely wrong than useful; route to the
        // manual list instead.
        if levelFilter != .ecole {
            return .pronote
        }
        return .unknown
    }
}
