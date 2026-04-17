import SwiftUI
import SwiftData
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "HomeView")

struct HomeView: View {
    var onAddChild: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query private var families: [Family]
    @StateObject private var engine: BriefingEngineWrapper = .init()
    @ObservedObject private var pronoteService = PronoteService.shared

    @AppStorage("lastSyncDate") private var lastSyncDateInterval: Double = 0

    @State private var selectedChild: Child?
    @State private var isSyncing = false
    @State private var showNoConnectionAlert = false
    @State private var showSettings = false
    @State private var syncError: String?
    @State private var showAbsence = false
    @State private var celebrationsExpanded = false
    @State private var showPronoteReconnect = false
    @State private var showWellbeingSheet = false
    @State private var wellbeingSignal: WellbeingSignal?

    // Card-tap destinations
    @State private var selectedHomework: Homework?
    @State private var selectedInsightContext: InsightContext?

    private var family: Family? { families.first }
    private var children: [Child] { family?.children ?? [] }
    private var isFamilyMode: Bool { selectedChild == nil }

    // MARK: - Computed helpers for new sections

    private var isSchoolDay: Bool {
        let weekday = Calendar.current.component(.weekday, from: Date.now)
        return weekday >= 2 && weekday <= 6
    }

    private var hasENTChildren: Bool {
        children.contains { $0.schoolType == .ent }
    }

    /// Direct Pronote QR-login children whose bridge is lost and need manual reconnect.
    private var pronoteChildrenNeedingReconnect: [Child] {
        guard pronoteService.bridge == nil && !pronoteService.isReconnecting else { return [] }
        let scope = selectedChild.map { [$0] } ?? children
        return scope.filter { $0.schoolType == .pronote && $0.entProvider == nil }
    }

    private var unreadMessageCount: Int {
        children.flatMap(\.messages).filter { !$0.read && $0.kind == .conversation }.count
    }

    private var urgentHomeworkCount: Int {
        children.flatMap(\.homework).filter { !$0.done && $0.dueDate <= Date.now.addingTimeInterval(86_400) }.count
    }

    private var unsignedCarnetsCount: Int {
        children.flatMap(\.messages).filter { !$0.read && $0.kind == .schoolbook }.count
    }

    private var recentGradesCount: Int {
        let sevenDaysAgo = Date.now.addingTimeInterval(-7 * 86_400)
        return children.flatMap(\.grades).filter { $0.date >= sevenDaysAgo }.count
    }

    private var lastSyncDate: Date? {
        lastSyncDateInterval > 0 ? Date(timeIntervalSince1970: lastSyncDateInterval) : nil
    }

    private var lastSyncLabel: String? {
        guard let date = lastSyncDate else { return nil }
        let seconds = Int(Date.now.timeIntervalSince(date))
        if seconds < 60 { return "Dernière sync: à l'instant" }
        if seconds < 3600 { return "Dernière sync: il y a \(seconds / 60) min" }
        let hours = seconds / 3600
        if hours < 24 { return "Dernière sync: il y a \(hours) h" }
        return "Dernière sync: il y a \(hours / 24) j"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if children.count > 1 {
                    ChildSelectorBar(
                        children: children,
                        selectedChild: $selectedChild,
                        onAddChild: onAddChild
                    )
                }

                ScrollView {
                    LazyVStack(spacing: NotoTheme.Spacing.cardGap) {
                        // MARK: Header — Greeting
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Bonjour \(family?.parentName ?? "")")
                                        .font(NotoTheme.Typography.greeting)
                                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                                    Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR"))).capitalized)
                                        .font(NotoTheme.Typography.metadata)
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                }
                                Spacer()
                                Button { showSettings = true } label: {
                                    Image(systemName: "gearshape")
                                        .font(.system(size: 18))
                                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                                }
                            }
                        }
                        .padding(.bottom, NotoTheme.Spacing.sm)

                        // MARK: Pronote reconnect prompt (keep for functionality)
                        if !pronoteChildrenNeedingReconnect.isEmpty {
                            PronoteReconnectCard(
                                children: pronoteChildrenNeedingReconnect,
                                onReconnect: { showPronoteReconnect = true }
                            )
                        }

                        // MARK: Sync status (compact)
                        if isSyncing || syncError != nil {
                            SyncStatusRow(
                                isSyncing: isSyncing,
                                lastSyncLabel: lastSyncLabel,
                                syncError: syncError
                            )
                        }

                        // MARK: Signal Feed — À traiter
                        if engine.isLoading {
                            ProgressView()
                                .padding(.vertical, NotoTheme.Spacing.xl)
                        } else if !engine.cards.isEmpty {
                            Text("À TRAITER")
                                .sectionLabelStyle()

                            ForEach(engine.cards.sorted { $0.priority > $1.priority }) { card in
                                BriefingCardView(
                                    card: card,
                                    showChildName: children.count > 1,
                                    onTap: { handleCardTap(card) }
                                )
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        } else {
                            // All clear — no signals
                            HStack(spacing: NotoTheme.Spacing.sm) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(NotoTheme.Colors.success)
                                    .font(.system(size: 14))
                                Text("Tout va bien")
                                    .font(NotoTheme.Typography.signalTitle)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(NotoTheme.Spacing.md)
                            .notoCard()
                        }

                        // MARK: Timeline — Prochaines 48h
                        let targetChildren = selectedChild.map { [$0] } ?? children
                        if !targetChildren.isEmpty {
                            Text("PROCHAINES 48H")
                                .sectionLabelStyle()

                            TimelineView(children: targetChildren)
                        }

                        // MARK: Discover teaser
                        if let teaser = engine.cards.first(where: { $0.type == .cultureReco }) {
                            Text("DÉCOUVRIR")
                                .sectionLabelStyle()

                            DiscoverBridgeCard(teaser: teaser)
                        }

                        // MARK: Absence Shortcut (keep for ENT)
                        if isSchoolDay && hasENTChildren {
                            AbsenceShortcutCard(showAbsence: $showAbsence)
                        }
                    }
                    .animation(.spring(response: 0.4, dampingFraction: 0.8), value: engine.cards)
                    .padding(NotoTheme.Spacing.md)
                }
            .background(NotoTheme.Colors.background)
            } // VStack (child selector + scroll)
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showAbsence) {
                AbsenceView()
            }
            .sheet(isPresented: $showWellbeingSheet) {
                WellbeingResourcesView(signal: wellbeingSignal)
            }
            .refreshable {
                await performFullRefresh()
            }
            .task(id: selectedChild?.id) {
                engine.configure(modelContext: modelContext)
                await refreshBriefing()
            }
            .onChange(of: children.map(\.id)) { _, childIds in
                if let sel = selectedChild, !childIds.contains(sel.id) {
                    selectedChild = nil
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .triggerFullSync)) { _ in
                guard !isSyncing else { return }
                Task { await performFullRefresh() }
            }
            // Cold-launch initial sync: when PronoteAutoConnect re-establishes
            // the bridge, fire a refresh if direct-Pronote children have no
            // data yet. Race-free alternative to posting a notification from
            // RootView (which could be dropped if HomeView hasn't subscribed).
            .onChange(of: pronoteService.isConnected) { _, connected in
                guard connected, !isSyncing else { return }
                let directPronote = children.filter { $0.schoolType == .pronote && $0.entProvider == nil }
                let hasEmpty = directPronote.contains {
                    $0.grades.isEmpty && $0.homework.isEmpty && $0.schedule.isEmpty
                }
                guard hasEmpty else { return }
                Task { await performFullRefresh() }
            }
            .sheet(isPresented: $showPronoteReconnect, onDismiss: {
                // If reconnect succeeded, trigger a full refresh automatically
                if pronoteService.bridge != nil {
                    Task { await performFullRefresh() }
                }
            }) {
                NavigationStack { PronoteQRLoginView() }
            }
            .alert("Reconnexion requise", isPresented: $showNoConnectionAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Aucune session Pronote active. Reconnectez-vous pour synchroniser les données.")
            }
            .sheet(item: $selectedHomework) { hw in
                HomeworkDetailView(hw: hw)
            }
            .sheet(item: $selectedInsightContext) { ctx in
                TrendDetailSheet(insight: ctx.insight, grades: ctx.grades)
            }
        }
    }

    // MARK: - Card Tap Routing

    /// Routes a briefing-card tap to the appropriate detail sheet or
    /// destination tab. When a detail target can't be resolved (stale
    /// SwiftData ID after a sync race, deleted model), falls back to
    /// the nearest list view rather than silently swallowing the tap.
    private func handleCardTap(_ card: BriefingCard) {
        switch card.type {
        case .homework:
            guard let id = card.targetID else {
                logger.warning("Briefing card tap: homework card missing targetID — falling back to School tab")
                NotificationCenter.default.post(name: .navigateToSchool, object: nil)
                return
            }
            guard let hw = modelContext.model(for: id) as? Homework else {
                logger.warning("Briefing card tap: homework \(String(describing: id)) no longer resolves — falling back to School tab")
                NotificationCenter.default.post(name: .navigateToSchool, object: nil)
                return
            }
            selectedHomework = hw

        case .insight:
            guard let id = card.targetID else {
                logger.warning("Briefing card tap: insight card missing targetID — falling back to School tab")
                NotificationCenter.default.post(name: .navigateToSchool, object: nil)
                return
            }
            guard let insight = modelContext.model(for: id) as? Insight else {
                logger.warning("Briefing card tap: insight \(String(describing: id)) no longer resolves — falling back to School tab")
                NotificationCenter.default.post(name: .navigateToSchool, object: nil)
                return
            }
            guard let child = insight.child else {
                logger.warning("Briefing card tap: insight \(String(describing: id)) has no child back-reference — falling back to School tab")
                NotificationCenter.default.post(name: .navigateToSchool, object: nil)
                return
            }
            selectedInsightContext = InsightContext(insight: insight, from: child)

        case .message:
            NotificationCenter.default.post(name: .navigateToMessages, object: nil)

        case .cultureReco, .familyReco:
            NotificationCenter.default.post(name: .navigateToDiscover, object: nil)

        case .cancelled:
            NotificationCenter.default.post(name: .navigateToSchool, object: nil)

        case .wellbeing:
            if card.wellbeing == nil {
                logger.warning("Briefing card tap: .wellbeing card has nil wellbeing payload — sheet will show without signal context")
            }
            wellbeingSignal = card.wellbeing
            showWellbeingSheet = true
        }
    }

    // MARK: - Refresh Logic

    private func performFullRefresh() async {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }

        var errors: [String] = []
        let targetChildren = selectedChild.map { [$0] } ?? children
        // Children with a direct Pronote bridge connection (QR code login)
        let directPronoteChildren = targetChildren.filter { $0.schoolType == .pronote && $0.entProvider == nil }
        // Children from MonLycée (have entProvider) — sync via logbook
        let monlyceeChildren = targetChildren.filter { $0.entProvider == .monlycee }
        // Pure ENT children (PCN etc)
        let entChildren = targetChildren.filter { $0.schoolType == .ent && $0.entProvider != .monlycee }

        // Direct Pronote sync (QR code login)
        if !directPronoteChildren.isEmpty {
            if pronoteService.bridge == nil && !pronoteService.isReconnecting {
                await PronoteAutoConnect.autoConnect(modelContext: modelContext)
            } else if pronoteService.isReconnecting {
                // RootView already started auto-connect — wait for it rather than spawning a second
                while pronoteService.isReconnecting {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            if let bridge = pronoteService.bridge {
                // Resolve each child to its pawnote-session index via
                // pawnoteID (or firstName fallback) — SwiftData order
                // has no relation to the bridge's internal child list,
                // so enumerated() would silently sync the wrong kid.
                let pawnoteRoster = bridge.getChildren()
                let syncService = PronoteSyncService(modelContext: modelContext)
                for child in directPronoteChildren {
                    guard let idx = ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnoteRoster) else {
                        // Surface the skip as a user-visible error instead of
                        // a silent continue — otherwise the banner reads "tout
                        // va bien" while one kid's dashboard freezes. The
                        // remediation is always to re-run QR login, which
                        // re-backfills pawnoteID via ChildDedupe.
                        logger.warning("Skipping sync for \(child.firstName, privacy: .private): no matching pawnote resource")
                        errors.append("Impossible de synchroniser \(child.firstName) — reconnectez-vous via QR code pour relier cet enfant à Pronote.")
                        continue
                    }
                    await syncService.sync(child: child, bridge: bridge, childIndex: idx)
                }
            } else {
                showNoConnectionAlert = true
            }
        }

        // MonLycée children: try Pronote bridge first, fallback to logbook
        if !monlyceeChildren.isEmpty {
            // If no bridge, attempt auto-reconnect (uses stored Pronote token if available)
            if pronoteService.bridge == nil {
                await PronoteAutoConnect.autoConnect(modelContext: modelContext)
            }
            if let bridge = pronoteService.bridge {
                let pawnoteRoster = bridge.getChildren()
                let syncService = PronoteSyncService(modelContext: modelContext)
                for child in monlyceeChildren {
                    guard let idx = ChildIndexResolver.resolve(child: child, pawnoteChildren: pawnoteRoster) else {
                        logger.warning("Skipping monlycee sync for \(child.firstName, privacy: .private): no matching pawnote resource")
                        errors.append("Impossible de synchroniser \(child.firstName) — reconnectez-vous via QR code pour relier cet enfant à Pronote.")
                        continue
                    }
                    await syncService.sync(child: child, bridge: bridge, childIndex: idx)
                }
            } else {
                // Fallback: sync from stored logbook data
                let syncService = MonLyceeSyncService(modelContext: modelContext)
                for child in monlyceeChildren {
                    syncService.syncFromStoredLogbook(for: child)
                }
            }
        }

        // Pure ENT/PCN sync
        if !entChildren.isEmpty {
            let entErrors = await syncENTChildren(entChildren)
            errors.append(contentsOf: entErrors)
        }

        syncError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        lastSyncDateInterval = Date.now.timeIntervalSince1970
        await refreshBriefing()
    }

    @discardableResult
    private func syncENTChildren(_ entChildren: [Child]) async -> [String] {
        var errors: [String] = []

        // Group children by provider so we login once per provider
        var byProvider: [ENTProvider: [Child]] = [:]
        for child in entChildren {
            let provider = child.entProvider ?? .pcn
            byProvider[provider, default: []].append(child)
        }

        let syncService = ENTSyncService(modelContext: modelContext)

        for (provider, children) in byProvider {
            let key = "ent_credentials_\(provider.rawValue)"
            guard let credsData = try? KeychainService.load(key: key),
                  let creds = String(data: credsData, encoding: .utf8) else {
                errors.append("\(provider.name) : identifiants manquants")
                continue
            }

            let parts = creds.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                errors.append("\(provider.name) : identifiants corrompus")
                continue
            }

            let client = ENTClient(provider: provider)
            do {
                // ENT is a React SPA — must use HeadlessENTAuth (WKWebView), not URLSession POST
                let loginURL = provider.baseURL.appendingPathComponent("auth/login")
                let cookies = try await HeadlessENTAuth.login(
                    loginURL: loginURL,
                    email: String(parts[0]),
                    password: String(parts[1])
                )
                ENTClient.importCookies(cookies)
                // Signal PhotoGridView to retry any pending thumbnail loads — the session
                // is now valid and cookies are in URLSession.shared's cookie storage.
                NotificationCenter.default.post(name: .entSessionReady, object: nil)
            } catch {
                errors.append("\(provider.name) : reconnexion échouée")
                continue
            }

            for child in children {
                do {
                    try await syncService.sync(
                        child: child,
                        client: client,
                        entChildId: child.entChildId ?? child.firstName
                    )
                } catch {
                    errors.append("\(child.firstName) : sync échouée")
                }
            }

            // Pre-warm photo cache in background — auth is valid right now, ideal moment to download.
            // Collect paths here (main actor) before crossing into the detached task.
            let photoPaths = children.flatMap(\.photos).map(\.entPath)
            if !photoPaths.isEmpty {
                let preloadClient = client
                Task.detached(priority: .background) {
                    await ENTPhotoCache.shared.preload(paths: photoPaths, client: preloadClient)
                }
            }
        }

        return errors
    }

    private func refreshBriefing() async {
        if let child = selectedChild {
            await engine.engine?.buildBriefing(for: child)
        } else if !children.isEmpty {
            await engine.engine?.buildFamilyBriefing(children: children)
        }
    }
}

/// Transient payload for `.sheet(item:)` presentation of a trend
/// detail. `Insight` doesn't store its source series, so we bundle
/// the matching grades here; the UUID is regenerated per tap so
/// SwiftUI re-presents the sheet after dismissal.
struct InsightContext: Identifiable {
    let id = UUID()
    let insight: Insight
    let grades: [Grade]

    init(insight: Insight, from child: Child) {
        self.insight = insight
        self.grades = child.grades.filter { $0.subject == insight.subject }
    }
}

/// Wrapper to bridge @MainActor BriefingEngine into SwiftUI's @StateObject.
@MainActor
final class BriefingEngineWrapper: ObservableObject {
    var engine: BriefingEngine?

    @Published var briefingText: String = ""
    @Published var cards: [BriefingCard] = []
    @Published var isLoading: Bool = false

    func configure(modelContext: ModelContext) {
        guard engine == nil else { return }
        let e = BriefingEngine(modelContext: modelContext)
        engine = e

        // Forward published properties
        e.$briefingText.assign(to: &$briefingText)
        e.$cards.assign(to: &$cards)
        e.$isLoading.assign(to: &$isLoading)
    }
}

// MARK: - Subviews

private struct SyncStatusRow: View {
    let isSyncing: Bool
    let lastSyncLabel: String?
    var syncError: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: NotoTheme.Spacing.xs) {
            HStack(spacing: NotoTheme.Spacing.xs) {
                if isSyncing {
                    ProgressView()
                        .scaleEffect(0.75)
                    Text("Synchronisation...")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                } else if let label = lastSyncLabel {
                    Image(systemName: syncError != nil ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(syncError != nil ? NotoTheme.Colors.warning : NotoTheme.Colors.textSecondary)
                    Text(label)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
            if let error = syncError {
                Text(error)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(.easeInOut(duration: 0.2), value: isSyncing)
    }
}

private struct GreetingHeader: View {
    let parentName: String

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            NotoLogo()
            Text(greeting)
                .font(NotoTheme.Typography.largeTitle)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Text(dateString)
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let period = hour < 12 ? "Bonjour" : hour < 18 ? "Bon après-midi" : "Bonsoir"
        return "\(period) \(parentName)"
    }

    private var dateString: String {
        Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "fr_FR")))
    }
}

private struct BriefingSummaryView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(NotoTheme.Typography.body)
            .foregroundStyle(NotoTheme.Colors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(NotoTheme.Spacing.md)
            .notoCard()
    }
}

private struct ReconnectingBanner: View {
    var body: some View {
        HStack(spacing: NotoTheme.Spacing.xs) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Reconnexion automatique…")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NotoTheme.Spacing.sm)
        .background(NotoTheme.Colors.surfaceSecondary)
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
    }
}

private struct GlobalStatusBanner: View {
    let children: [Child]

    private var alertMessages: [String] {
        AlertMessageBuilder.messages(for: children)
    }

    var body: some View {
        if alertMessages.isEmpty {
            HStack(spacing: NotoTheme.Spacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(NotoTheme.Colors.success)
                    .font(.system(size: 13))
                Text("Tout va bien")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.sm)
            .background(NotoTheme.Colors.success.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
        } else {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                ForEach(alertMessages, id: \.self) { msg in
                    HStack(spacing: NotoTheme.Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(NotoTheme.Colors.warning)
                            .font(.system(size: 12))
                        Text(msg)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.sm)
            .background(NotoTheme.Colors.warning.opacity(0.18))
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
        }
    }
}

private struct EmptyBriefingView: View {
    var body: some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "sun.max")
                .font(.system(size: 40))
                .foregroundStyle(NotoTheme.Colors.brand)
            Text("Rien de particulier aujourd'hui")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NotoTheme.Spacing.xl)
    }
}

// MARK: - Story Rings

private struct StoryRingsRow: View {
    let children: [Child]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NotoTheme.Spacing.lg) {
                ForEach(children) { child in
                    ChildStoryRing(child: child)
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.xs)
        }
    }
}

private struct ChildStoryRing: View {
    let child: Child

    @State private var isPressed = false
    @State private var showDetail = false

    private var ringColor: Color {
        child.hasAlert ? NotoTheme.Colors.brand : NotoTheme.Colors.border
    }

    private var ringWidth: CGFloat {
        child.hasAlert ? 3 : 1.5
    }

    private var schoolBadgeColor: Color {
        switch child.schoolType {
        case .ent: return NotoTheme.Colors.cobalt
        case .pronote: return NotoTheme.Colors.pronote
        }
    }

    private var schoolBadgeLabel: String {
        switch child.schoolType {
        case .ent: return child.entProvider?.rawValue.uppercased() ?? "ENT"
        case .pronote: return "PRO"
        }
    }

    var body: some View {
        Button(action: { showDetail = true }) {
            VStack(spacing: NotoTheme.Spacing.xs) {
                ZStack {
                    // Ring border
                    Circle()
                        .stroke(ringColor, lineWidth: ringWidth)
                        .frame(width: 60, height: 60)

                    // Avatar or initial
                    if let avatarData = child.avatar,
                       let uiImage = UIImage(data: avatarData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 54, height: 54)
                            .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(NotoTheme.Colors.indigo)
                            .frame(width: 54, height: 54)
                            .overlay(
                                Text(String(child.firstName.prefix(1)).uppercased())
                                    .font(NotoTheme.Typography.functional(22, weight: .bold))
                                    .foregroundStyle(NotoTheme.Colors.paper)
                            )
                    }

                    // School type badge
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(schoolBadgeLabel)
                                .font(NotoTheme.Typography.functional(7, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(schoolBadgeColor)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .offset(x: 4, y: 4)
                        }
                    }
                    .frame(width: 60, height: 60)
                }
                // Alert dot mirrors Child.hasAlert — keep in sync with ChildSelectorBar.
                .overlay(alignment: .topTrailing) {
                    if child.hasAlert {
                        Circle()
                            .fill(NotoTheme.Colors.danger)
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(NotoTheme.Colors.background, lineWidth: 2)
                            )
                            .offset(x: 2, y: -2)
                    }
                }

                Text(child.firstName)
                    .font(NotoTheme.Typography.functional(10))
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .lineLimit(1)

                Text(child.grade)
                    .font(NotoTheme.Typography.functional(9))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed ? 0.92 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .sheet(isPresented: $showDetail) {
            ChildQuickView(child: child)
        }
    }
}

// MARK: - Child Quick Sheet (B3)

private struct ChildQuickView: View {
    let child: Child
    @Environment(\.dismiss) private var dismiss

    private var recentGrades: [Grade] {
        child.grades.sorted { $0.date > $1.date }.prefix(3).map { $0 }
    }
    private var nextHomework: Homework? {
        child.homework.filter { !$0.done && $0.dueDate >= Calendar.current.startOfDay(for: .now) }
            .sorted { $0.dueDate < $1.dueDate }.first
    }
    private var unsignedCarnets: Int {
        child.messages.filter { $0.kind == .schoolbook && !$0.read }.count
    }

    var body: some View {
        NavigationStack {
            List {
                if !recentGrades.isEmpty {
                    Section("Notes récentes") {
                        ForEach(recentGrades) { grade in
                            HStack {
                                Text(grade.subject)
                                    .font(NotoTheme.Typography.body)
                                Spacer()
                                Text(String(format: "%.1f", grade.value))
                                    .font(NotoTheme.Typography.data)
                                Text("/\(Int(grade.outOf))")
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            }
                        }
                    }
                }
                if let hw = nextHomework {
                    Section("Prochain devoir") {
                        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                            Text(hw.subject).font(NotoTheme.Typography.headline)
                            Text(hw.descriptionText)
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                                .lineLimit(2)
                        }
                    }
                }
                if unsignedCarnets > 0 {
                    Section {
                        Label("\(unsignedCarnets) carnet\(unsignedCarnets > 1 ? "s" : "") à signer", systemImage: "signature")
                            .foregroundStyle(NotoTheme.Colors.amber)
                    }
                }
            }
            .navigationTitle(child.firstName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Hero Card

private struct HeroCard: View {
    let unreadMessageCount: Int
    let urgentHomeworkCount: Int
    let recentGradesCount: Int
    let children: [Child]
    var onTap: (() -> Void)? = nil

    private var dateString: String {
        Date.now.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR")))
    }

    private var weekdayString: String {
        Date.now.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "fr_FR"))).capitalized
    }

    var body: some View {
        // TODO: blog photo hero — use school blog photo when available from PCN
        ZStack(alignment: .bottomLeading) {
            // Background with dot grid overlay
            RoundedRectangle(cornerRadius: NotoTheme.Radius.lg)
                .fill(NotoTheme.Colors.indigo)
                .overlay(
                    Canvas { context, size in
                        let step: CGFloat = 24
                        var x: CGFloat = 0
                        while x < size.width {
                            var y: CGFloat = 0
                            while y < size.height {
                                let rect = CGRect(x: x, y: y, width: 1, height: 1)
                                context.fill(Path(rect), with: .color(.white.opacity(0.06)))
                                y += step
                            }
                            x += step
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.lg))
                )
                .frame(height: 180)

            if unreadMessageCount > 0 {
                // Message count — kept informational, not alarming
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                    HStack(spacing: NotoTheme.Spacing.sm) {
                        Image(systemName: "envelope.badge")
                            .font(.system(size: 18))
                            .foregroundStyle(NotoTheme.Colors.brand)
                        Text("\(unreadMessageCount) message\(unreadMessageCount > 1 ? "s" : "") non lu\(unreadMessageCount > 1 ? "s" : "")")
                            .font(NotoTheme.Typography.title)
                            .foregroundStyle(NotoTheme.Colors.paper)
                    }
                    Text("Consultez l'onglet Actualités")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                .padding(NotoTheme.Spacing.md)
            } else {
                // Journée summary hero
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                    Text(weekdayString)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .textCase(.uppercase)
                    Text(dateString)
                        .font(NotoTheme.Typography.title)
                        .foregroundStyle(NotoTheme.Colors.paper)
                    Text("Bonne journée")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                    if urgentHomeworkCount > 0 || recentGradesCount > 0 {
                        HStack(spacing: NotoTheme.Spacing.sm) {
                            if urgentHomeworkCount > 0 {
                                Label("\(urgentHomeworkCount) devoir\(urgentHomeworkCount > 1 ? "s" : "")", systemImage: "pencil")
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            }
                            if recentGradesCount > 0 {
                                Label("\(recentGradesCount) note\(recentGradesCount > 1 ? "s" : "")", systemImage: "chart.bar")
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                            }
                        }
                    }
                }
                .padding(NotoTheme.Spacing.md)
            }
        }
        .frame(height: 180)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

// MARK: - Morning Action Strip

private struct MorningActionStrip: View {
    let messageCount: Int
    let homeworkCount: Int
    let carnetCount: Int
    var onMessagesTap: (() -> Void)? = nil
    var onHomeworkTap: (() -> Void)? = nil
    var onCarnetsTap: (() -> Void)? = nil

    var body: some View {
        let chips = buildChips()
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NotoTheme.Spacing.sm) {
                    ForEach(chips, id: \.label) { chip in
                        ActionChip(icon: chip.icon, count: chip.count, label: chip.label, accentColor: chip.accentColor, onTap: chip.action)
                    }
                }
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.xs)
            }
        }
    }

    private struct ChipData {
        let icon: String
        let count: Int
        let label: String
        let accentColor: Color
        var action: (() -> Void)? = nil
    }

    private func buildChips() -> [ChipData] {
        var result: [ChipData] = []
        if messageCount > 0 {
            result.append(ChipData(icon: "envelope.fill", count: messageCount, label: "messages", accentColor: NotoTheme.Colors.brand, action: onMessagesTap))
        }
        if homeworkCount > 0 {
            result.append(ChipData(icon: "pencil", count: homeworkCount, label: "devoirs", accentColor: NotoTheme.Colors.cobalt, action: onHomeworkTap))
        }
        if carnetCount > 0 {
            result.append(ChipData(icon: "signature", count: carnetCount, label: "carnet\(carnetCount > 1 ? "s" : "") à signer", accentColor: NotoTheme.Colors.amber, action: onCarnetsTap))
        }
        return result
    }
}

private struct ActionChip: View {
    let icon: String
    let count: Int
    let label: String
    let accentColor: Color
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button(action: { onTap?() }) {
            HStack(spacing: NotoTheme.Spacing.xs) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(accentColor)
                Text("\(count) \(label)")
                    .font(NotoTheme.Typography.functional(12))
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                if onTap != nil {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 10))
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.sm)
            .background(NotoTheme.Colors.card)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(accentColor.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Discover Bridge Card (B2)

private struct DiscoverBridgeCard: View {
    let teaser: BriefingCard?

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .navigateToDiscover, object: nil)
        } label: {
            HStack(spacing: NotoTheme.Spacing.sm) {
                Image(systemName: teaser?.icon ?? "safari")
                    .font(.system(size: 20))
                    .foregroundStyle(NotoTheme.Colors.brand)
                VStack(alignment: .leading, spacing: 2) {
                    if let teaser {
                        Text(teaser.title)
                            .font(NotoTheme.Typography.headline)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                            .lineLimit(1)
                        HStack(spacing: NotoTheme.Spacing.xs) {
                            Text(teaser.childName)
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.brand)
                            if !teaser.subtitle.isEmpty {
                                Text("·")
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                                Text(teaser.subtitle)
                                    .font(NotoTheme.Typography.caption)
                                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    } else {
                        Text("Découvrir")
                            .font(NotoTheme.Typography.headline)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                        Text("Recommandations culturelles liées aux cours")
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            .padding(NotoTheme.Spacing.md)
            .notoCard()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Photos Shortcut Card (C2)

private struct PhotosShortcutCard: View {
    let children: [Child]
    @State private var showPhotos = false

    private var recentPhotos: [SchoolPhoto] {
        Array(children.flatMap(\.photos).sorted { $0.date > $1.date }.prefix(3))
    }

    var body: some View {
        let photoCount = children.flatMap(\.photos).count
        Button { showPhotos = true } label: {
            HStack(spacing: NotoTheme.Spacing.sm) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 20))
                    .foregroundStyle(NotoTheme.Colors.cobalt)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dernières photos")
                        .font(NotoTheme.Typography.headline)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Text("\(photoCount) photo\(photoCount > 1 ? "s" : "") partagée\(photoCount > 1 ? "s" : "")")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            .padding(NotoTheme.Spacing.md)
            .notoCard()
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPhotos) {
            NavigationStack {
                PhotoGridView(children: children)
                    .navigationTitle("Photos")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Fermer") { showPhotos = false }
                        }
                    }
            }
        }
    }
}

// MARK: - Absence Shortcut

private struct AbsenceShortcutCard: View {
    @Binding var showAbsence: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            Text("Votre enfant est absent aujourd'hui ?")
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textPrimary)

            Button {
                showAbsence = true
            } label: {
                HStack(spacing: NotoTheme.Spacing.xs) {
                    Text("Signaler une absence")
                        .font(NotoTheme.Typography.functional(13, weight: .bold))
                        .foregroundStyle(NotoTheme.Colors.cobalt)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(NotoTheme.Colors.cobalt)
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NotoTheme.Spacing.md)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: NotoTheme.Radius.md)
                .stroke(NotoTheme.Colors.border, lineWidth: 1)
        )
    }
}

// MARK: - Pronote Reconnect Card

private struct PronoteReconnectCard: View {
    let children: [Child]
    let onReconnect: () -> Void

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18))
                .foregroundStyle(NotoTheme.Colors.amber)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connexion Pronote perdue")
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                Text(children.map(\.firstName).joined(separator: ", ") + " · données non synchronisées")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            Spacer()
            Button("Reconnecter", action: onReconnect)
                .font(NotoTheme.Typography.functional(12, weight: .bold))
                .foregroundStyle(NotoTheme.Colors.shadow)
                .padding(.horizontal, NotoTheme.Spacing.sm)
                .padding(.vertical, 6)
                .background(NotoTheme.Colors.brand)
                .clipShape(Capsule())
        }
        .padding(NotoTheme.Spacing.md)
        .background(NotoTheme.Colors.amber.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: NotoTheme.Radius.md)
                .stroke(NotoTheme.Colors.amber.opacity(0.25), lineWidth: 1)
        )
    }
}

#Preview("Léa — collège") {
    HomeView()
        .withPreviewData()
}
