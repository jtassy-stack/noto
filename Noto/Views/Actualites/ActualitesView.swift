import SwiftUI
import SwiftData
import SafariServices

// MARK: - Feed Filter

private enum FeedFilter: String, CaseIterable {
    case tous     = "Tous"
    case messages = "Messages"
    case carnets  = "Carnets"
    case photos   = "Photos"
}

/// Whose messages are shown: everyone, one child, or the parent lane.
private enum AudienceFilter: Hashable {
    case all
    case child(PersistentIdentifier)
    case parent
}

// MARK: - Navigation Destination

private enum FeedDestination: Hashable {
    case conversation(Message)
    case schoolbook(child: Child, msg: Message)

    func hash(into hasher: inout Hasher) {
        switch self {
        case .conversation(let msg):
            hasher.combine(0)
            hasher.combine(msg.persistentModelID)
        case .schoolbook(_, let msg):
            hasher.combine(1)
            hasher.combine(msg.persistentModelID)
        }
    }

    static func == (lhs: FeedDestination, rhs: FeedDestination) -> Bool {
        switch (lhs, rhs) {
        case (.conversation(let a), .conversation(let b)):
            return a.persistentModelID == b.persistentModelID
        case (.schoolbook(_, let a), .schoolbook(_, let b)):
            return a.persistentModelID == b.persistentModelID
        default:
            return false
        }
    }
}

// MARK: - ActualitesView

struct ActualitesView: View {
    @Query private var families: [Family]
    @Environment(\.modelContext) private var modelContext

    @State private var activeFilter: FeedFilter = .tous
    @State private var audience: AudienceFilter = .all
    @State private var isRefreshing = false
    /// Stored in UserDefaults so the 60-second cooldown survives tab
    /// recreation, background/foreground cycles, and memory-pressure
    /// eviction.  A raw TimeInterval (0 == never synced) avoids a
    /// Date? round-trip through UserDefaults.
    @AppStorage("imapActualitesLastSyncDate") private var lastSyncDateInterval: Double = 0
    @State private var path: [FeedDestination] = []
    @State private var showMonLyceeSetup = false
    @State private var imapConfigured = false
    @State private var syncError: String?

    // Stable child-index → color mapping
    private static let avatarColors: [Color] = [
        NotoTheme.Colors.brand,
        NotoTheme.Colors.cobalt,
        NotoTheme.Colors.amber,
        Color(hex: 0xE05C5C),
        Color(hex: 0xA855F7),
    ]

    private var children: [Child] {
        families.first?.children ?? []
    }

    private typealias FeedItem = (child: Child?, msg: Message)

    private func avatarColor(for child: Child?) -> Color {
        guard let child else { return NotoTheme.Colors.textSecondary }
        let idx = children.firstIndex(where: { $0.persistentModelID == child.persistentModelID }) ?? 0
        return Self.avatarColors[idx % Self.avatarColors.count]
    }

    // MARK: - Filtered items

    /// `child == nil` marks parent-lane mail (`Family.messages`, IMAP
    /// accounts assigned to "Parent"), shown with a "Parent" tag.
    private var allItems: [FeedItem] {
        let childItems: [FeedItem] = children.flatMap { child in
            child.messages.map { (child: Optional(child), msg: $0) }
        }
        let parentItems: [FeedItem] = (families.first?.messages ?? []).map { (child: nil, msg: $0) }
        return (childItems + parentItems).sorted { $0.msg.date > $1.msg.date }
    }

    private var hasParentLane: Bool { !(families.first?.messages ?? []).isEmpty }

    /// The audience pills only make sense with two lanes or more.
    private var showsAudienceFilter: Bool { children.count + (hasParentLane ? 1 : 0) > 1 }

    private var scopedItems: [FeedItem] {
        switch audience {
        case .all:
            return allItems
        case .child(let id):
            return allItems.filter { $0.child?.persistentModelID == id }
        case .parent:
            return allItems.filter { $0.child == nil }
        }
    }

    private var filteredItems: [FeedItem] {
        switch activeFilter {
        case .tous:
            return scopedItems
        case .messages:
            return scopedItems.filter { $0.msg.kind == .conversation }
        case .carnets:
            return scopedItems.filter { $0.msg.kind == .schoolbook }
        case .photos:
            return []
        }
    }

    // MARK: - Triage

    private typealias PendingItem = (item: FeedItem, action: MessageTriage.Action)

    /// Unread messages that ask the parent to sign, justify or reply.
    private var pendingItems: [PendingItem] {
        let now = Date.now
        return filteredItems.compactMap { item -> PendingItem? in
            guard !item.msg.read else { return nil }
            return MessageTriage.action(subject: item.msg.subject,
                                        plainBody: HTMLText.plainText(fromHTML: item.msg.body),
                                        kind: item.msg.kind, read: item.msg.read, date: item.msg.date,
                                        now: now, calendar: .current)
                .map { (item: item, action: $0) }
        }
    }

    private var weekVolume: MessageTriage.WeekVolume {
        MessageTriage.weekVolume(filteredItems.map { (source: $0.msg.source, date: $0.msg.date) },
                                 now: .now, calendar: .current)
    }

    // MARK: - Date grouping

    private func groupedItems(excluding pending: [PendingItem]) -> [(header: String, items: [FeedItem])] {
        let pendingIDs = Set(pending.map(\.item.msg.persistentModelID))
        var groups: [(header: String, items: [FeedItem])] = []
        var current: (header: String, items: [FeedItem])?

        for item in filteredItems where !pendingIDs.contains(item.msg.persistentModelID) {
            let header = sectionHeader(for: item.msg.date)
            if current?.header == header {
                current!.items.append(item)
            } else {
                if let c = current { groups.append(c) }
                current = (header: header, items: [item])
            }
        }
        if let c = current { groups.append(c) }
        return groups
    }

    private func sectionHeader(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Aujourd'hui" }
        if cal.isDateInYesterday(date) { return "Hier" }
        // Same week → day name
        let startOfWeek = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now))!
        if date >= startOfWeek {
            return date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "fr_FR"))).capitalized
        }
        // Older → full date
        return date.formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "fr_FR")))
    }

    // MARK: - syncAll

    /// Cooldown between auto-syncs. Prevents `.onAppear` from firing a
    /// 5-15s sync every time the parent switches back to Messages.
    /// Pull-to-refresh bypasses this — it's an explicit user intent.
    private static let autoSyncCooldownSeconds: TimeInterval = 60

    private func shouldAutoSync() -> Bool {
        lastSyncDateInterval == 0 ||
            Date.now.timeIntervalSince1970 - lastSyncDateInterval >= Self.autoSyncCooldownSeconds
    }

    @MainActor
    private func syncAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastSyncDateInterval = Date.now.timeIntervalSince1970
        }

        let entChildren = children.filter { $0.schoolType == .ent }
        let pronoteChildren = children.filter { $0.schoolType == .pronote }

        await syncENTGrouped(entChildren)
        await syncIMAPOnce(for: pronoteChildren)
    }

    /// Group ENT children by provider and authenticate once per provider
    /// rather than once per child — the expensive headless-browser login
    /// dwarfs the per-child fetch, and siblings on the same ENT share
    /// session cookies anyway.
    @MainActor
    private func syncENTGrouped(_ entChildren: [Child]) async {
        guard !entChildren.isEmpty else { return }
        var byProvider: [ENTProvider: [Child]] = [:]
        for child in entChildren {
            byProvider[child.entProvider ?? .pcn, default: []].append(child)
        }

        let service = ENTSyncService(modelContext: modelContext)
        for (provider, kids) in byProvider {
            let credKey = "ent_credentials_\(provider.rawValue)"
            guard let credData = try? KeychainService.load(key: credKey),
                  let credStr = String(data: credData, encoding: .utf8) else {
                syncError = "\(provider.name) : identifiants manquants. Reconnectez-vous dans Réglages."
                continue
            }
            let parts = credStr.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                syncError = "\(provider.name) : identifiants corrompus."
                continue
            }
            do {
                let loginURL = provider.baseURL.appendingPathComponent("auth/login")
                let cookies = try await HeadlessENTAuth.login(
                    loginURL: loginURL,
                    email: String(parts[0]),
                    password: String(parts[1])
                )
                ENTClient.importCookies(cookies)
                NSLog("[noto] ENT re-auth OK for %@ (%d cookies, %d children)", provider.rawValue, cookies.count, kids.count)
            } catch ENTError.sessionExpired, ENTError.badCredentials {
                NSLog("[noto][error] ENT bad credentials for %@", provider.rawValue)
                syncError = "Identifiants \(provider.name) incorrects. Reconnectez-vous dans Réglages."
                continue
            } catch {
                NSLog("[noto][error] ENT auth error for %@: %@", provider.rawValue, error.localizedDescription)
                syncError = "Sync \(provider.name) : \(error.localizedDescription)"
                continue
            }

            let client = ENTClient(provider: provider)
            for child in kids {
                guard let entChildId = child.entChildId else {
                    syncError = "\(child.firstName) : profil ENT incomplet (pas d'ID enfant)."
                    continue
                }
                do {
                    try await service.sync(child: child, client: client, entChildId: entChildId)
                    NSLog("[noto] ENT sync OK for %@ — %d photos total", child.firstName, child.photos.count)
                } catch {
                    NSLog("[noto][error] ENT sync error for %@: %@", child.firstName, error.localizedDescription)
                    syncError = "Sync \(child.firstName) : \(error.localizedDescription)"
                }
            }
        }
    }

    /// Fetch the IMAP inbox ONCE per syncAll and replay it against every
    /// Pronote child that shares the family mailbox. Previous behaviour
    /// opened a fresh connection + LOGIN + FETCH 50 for each child,
    /// adding 2-3s of round-trip per sibling.
    ///
    /// Every configured account is synced (previously only the first one),
    /// each routed by its `MailboxAssignment`: "Tous les enfants" keeps the
    /// historical Pronote-children pool, an explicit child is honoured
    /// whatever its school type, and "Parent" lands in `Family.messages`.
    @MainActor
    private func syncIMAPOnce(for pronoteChildren: [Child]) async {
        let configs = IMAPService.loadConfigs()
        guard !configs.isEmpty, !children.isEmpty else { return }

        // Pre-fetch the directory cache so each per-child whitelist uses
        // the authoritative mailDomains when an RNE is linked. All
        // children: an explicit assignment / the parent lane may need them.
        let directorySchools = await DirectorySchoolCache.schools(for: children)

        let service = IMAPSyncService(modelContext: modelContext)
        let result = await service.syncAccounts(
            configs,
            children: children,
            defaultChildren: pronoteChildren,
            family: families.first,
            directorySchools: directorySchools
        )
        // `emptyWhitelist` ships actionable copy pointing to Settings;
        // others fall through to a generic message.
        if let detail = result.errors.last?.detail {
            syncError = detail.isEmpty ? "Erreur de synchronisation des messages." : detail
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if showsAudienceFilter {
                    AudienceChipsBar(audience: $audience, children: children, hasParentLane: hasParentLane)
                }

                // Filter chips
                FilterChipsBar(activeFilter: $activeFilter)

                Divider()
                    .background(NotoTheme.Colors.border)

                // MonLycée setup prompt — only when no channel delivers
                // monlycee.net mail yet (see `showsMonLyceePrompt`).
                if showsMonLyceePrompt {
                    monLyceePrompt
                }

                // Sync error banner — dismissible
                if let error = syncError {
                    HStack(spacing: NotoTheme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(NotoTheme.Colors.amber)
                        Text(error)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            syncError = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                        }
                    }
                    .padding(NotoTheme.Spacing.sm)
                    .background(NotoTheme.Colors.amber.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.top, NotoTheme.Spacing.xs)
                }

                // Feed
                if activeFilter == .photos {
                    PhotoGridView(
                        children: children,
                        onSync: { await syncAll() },
                        isSyncing: isRefreshing,
                        lastSyncDate: lastSyncDateInterval > 0 ? Date(timeIntervalSince1970: lastSyncDateInterval) : nil
                    )
                } else if filteredItems.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    feedList
                }
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("Messages")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FeedDestination.self) { dest in
                switch dest {
                case .conversation(let msg):
                    FeedMessageDetailView(msg: msg)
                case .schoolbook(let child, let msg):
                    SchoolbookDetailView(child: child, msg: msg)
                }
            }
            .sheet(isPresented: $showMonLyceeSetup, onDismiss: {
                refreshIMAPState()
                Task { await syncAll() }
            }) {
                MonLyceeIMAPSetupView()
            }
            .onAppear {
                refreshIMAPState()
                // Tab re-appear fires every time the user returns to
                // Messages — syncing unconditionally made each visit wait
                // 5-15s on a fresh IMAP fetch + per-child PCN re-auth.
                // Pull-to-refresh (.refreshable) stays unconditional;
                // onAppear only syncs if nothing has refreshed recently.
                if shouldAutoSync() {
                    Task { await syncAll() }
                }
            }
            // Disconnecting or switching the mailbox from Settings
            // happens outside this view's hierarchy and would otherwise
            // leave the "Connecter MonLycée.net" prompt stale until the
            // tab is re-appeared. IMAPService posts the notification
            // after every saveConfig / clearConfig.
            .onReceive(NotificationCenter.default.publisher(for: IMAPService.configDidChangeNotification)) { _ in
                refreshIMAPState()
            }
        }
    }

    // MARK: - Sub-views

    /// The prompt pushes the parent towards the monlycee.net IMAP preset.
    /// A child connected through the MonLycée ENT already receives that
    /// inbox via the SSO channel (`MonLyceeMailService`), so suggesting IMAP
    /// there would only set up a second fetcher for the same mail.
    private var showsMonLyceePrompt: Bool {
        Self.showsMonLyceePrompt(
            imapConfigured: imapConfigured,
            childProviders: children.map(\.entProvider)
        )
    }

    static func showsMonLyceePrompt(imapConfigured: Bool, childProviders: [ENTProvider?]) -> Bool {
        !imapConfigured && !childProviders.contains(.monlycee)
    }

    private func refreshIMAPState() {
        imapConfigured = IMAPService.isConfigured
    }

    private var monLyceePrompt: some View {
        HStack(spacing: NotoTheme.Spacing.sm) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.title2)
                    .foregroundStyle(NotoTheme.Colors.cobalt)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connecter MonLycée.net")
                        .font(NotoTheme.Typography.headline)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                    Text("Pour recevoir les messages dans Actualités")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
            .padding(NotoTheme.Spacing.md)
            .background(NotoTheme.Colors.cobalt.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: NotoTheme.Radius.md)
                    .stroke(NotoTheme.Colors.cobalt.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.top, NotoTheme.Spacing.sm)
            .onTapGesture { showMonLyceeSetup = true }
    }

    private var emptyState: some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(NotoTheme.Colors.textSecondary.opacity(0.5))
            Text("Aucun message pour le moment")
                .font(NotoTheme.Typography.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Button("Synchroniser maintenant") {
                Task { await syncAll() }
            }
            .buttonStyle(.borderedProminent)
            .tint(NotoTheme.Colors.brand)
            .font(NotoTheme.Typography.caption)
        }
        .padding(NotoTheme.Spacing.lg)
    }

    private var feedList: some View {
        let pending = pendingItems
        let groups = groupedItems(excluding: pending)
        let infoCount = groups.reduce(0) { $0 + $1.items.count }
        let volume = weekVolume
        return List {
            Section {
                WeekSummaryRow(volume: volume, pending: pending.count)
            }

            if !pending.isEmpty {
                Section {
                    ForEach(pending, id: \.item.msg.persistentModelID) { entry in
                        PendingItemRow(msg: entry.item.msg, child: entry.item.child, action: entry.action) {
                            open(entry.item)
                        }
                    }
                } header: {
                    Text("À traiter · \(pending.count)")
                        .font(NotoTheme.Typography.caption.weight(.semibold))
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .textCase(nil)
                }
            }

            ForEach(Array(groups.enumerated()), id: \.element.header) { index, group in
                Section {
                    ForEach(group.items, id: \.msg.persistentModelID) { item in
                        FeedItemRow(
                            msg: item.msg,
                            child: item.child,
                            avatarColor: avatarColor(for: item.child)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { open(item) }
                        .swipeActions(edge: .leading) {
                            if !item.msg.read {
                                Button {
                                    item.msg.read = true
                                    do {
                                        try modelContext.save()
                                    } catch {
                                        NSLog("[noto][error] ActualitesView: save failed: %@", error.localizedDescription)
                                        item.msg.read = false
                                    }
                                } label: {
                                    Label("Lu", systemImage: "envelope.open")
                                }
                                .tint(NotoTheme.Colors.brand)
                            }
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                        if index == 0, !pending.isEmpty {
                            Text("Pour information · \(infoCount)")
                                .font(NotoTheme.Typography.caption.weight(.semibold))
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                        }
                        Text(group.header)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await syncAll() }
    }

    private func open(_ item: FeedItem) {
        // Parent-lane rows are always conversations.
        if item.msg.kind == .schoolbook, let child = item.child {
            path.append(.schoolbook(child: child, msg: item.msg))
        } else {
            path.append(.conversation(item.msg))
        }
    }
}

// MARK: - Audience Chips Bar

private struct AudienceChipsBar: View {
    @Binding var audience: AudienceFilter
    let children: [Child]
    let hasParentLane: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NotoTheme.Spacing.sm) {
                AudienceChip(title: "Tous", isActive: audience == .all) { audience = .all }
                ForEach(children) { child in
                    let filter = AudienceFilter.child(child.persistentModelID)
                    AudienceChip(title: child.firstName, isActive: audience == filter) { audience = filter }
                }
                if hasParentLane {
                    AudienceChip(title: MailboxRouting.parentLabel, isActive: audience == .parent) {
                        audience = .parent
                    }
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.top, NotoTheme.Spacing.sm)
        }
        .background(NotoTheme.Colors.background)
    }
}

/// Child / parent pill: filled brand when active, like the Accueil child picker.
private struct AudienceChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NotoTheme.Typography.body.weight(isActive ? .semibold : .medium))
                .foregroundStyle(isActive ? Color.white : NotoTheme.Colors.textPrimary)
                .padding(.horizontal, 14)
                .frame(minHeight: 36)
                .background(isActive ? NotoTheme.Colors.brand : NotoTheme.Colors.surface,
                            in: RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                .overlay(
                    RoundedRectangle(cornerRadius: NotoTheme.Radius.sm)
                        .stroke(isActive ? Color.clear : NotoTheme.Colors.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

// MARK: - Week Summary

private struct WeekSummaryRow: View {
    let volume: MessageTriage.WeekVolume
    let pending: Int

    var body: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Cette semaine")
                    .font(NotoTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                Text(MessageTriage.summaryLine(total: volume.total, pending: pending))
                    .font(NotoTheme.Typography.headline)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
            }
            if !volume.perChannel.isEmpty {
                HStack(spacing: NotoTheme.Spacing.sm) {
                    ForEach(volume.perChannel, id: \.channel) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.channel.label)
                                .font(NotoTheme.Typography.caption)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                            Text("\(entry.count)")
                                .font(NotoTheme.Typography.headline.monospacedDigit())
                                .foregroundStyle(NotoTheme.Colors.textPrimary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, NotoTheme.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NotoTheme.Colors.surfaceSecondary,
                                    in: RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .padding(.vertical, NotoTheme.Spacing.xs)
        .listRowSeparator(.hidden)
    }
}

// MARK: - Pending Row

private struct PendingItemRow: View {
    let msg: Message
    let child: Child?
    let action: MessageTriage.Action
    let onOpen: () -> Void

    private var originLine: String {
        let who = child?.firstName ?? MailboxRouting.parentLabel
        let kind = msg.kind == .schoolbook ? "Carnet de liaison" : SourceBadge.label(msg.source, imapProviderID: msg.imapProvider)
        return "\(who) · \(kind)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: NotoTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(originLine)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: NotoTheme.Spacing.xs)
                    Text(FeedItemRow.relativeTimestamp(msg.date))
                        .font(NotoTheme.Typography.dataSmall)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                Text(msg.subject)
                    .font(NotoTheme.Typography.body.weight(.semibold))
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .lineLimit(2)
            }
            Button(action: onOpen) {
                Text(action.label)
                    .font(NotoTheme.Typography.caption.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 32)
                    .background(NotoTheme.Colors.brand, in: RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .padding(.vertical, NotoTheme.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text(action.label), onOpen)
    }
}

// MARK: - Filter Chips Bar

private struct FilterChipsBar: View {
    @Binding var activeFilter: FeedFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: NotoTheme.Spacing.sm) {
                ForEach(FeedFilter.allCases, id: \.self) { filter in
                    FilterChip(
                        title: filter.rawValue,
                        isActive: activeFilter == filter,
                        action: { activeFilter = filter }
                    )
                }
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.sm)
        }
        .background(NotoTheme.Colors.background)
    }
}

private struct FilterChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(isActive ? NotoTheme.Colors.shadow : NotoTheme.Colors.textSecondary)
                .padding(.horizontal, NotoTheme.Spacing.md)
                .padding(.vertical, NotoTheme.Spacing.sm - 2)
                .background(
                    isActive
                        ? NotoTheme.Colors.brand
                        : Color.clear
                )
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(
                            isActive ? Color.clear : NotoTheme.Colors.border,
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FeedItemRow

private struct FeedItemRow: View {
    let msg: Message
    /// nil → parent-lane mail (IMAP account assigned to "Parent").
    let child: Child?
    let avatarColor: Color

    private var tagName: String { child?.firstName ?? MailboxRouting.parentLabel }

    /// Strip HTML tags for body preview.
    private var bodyPreview: String {
        HTMLText.plainText(fromHTML: msg.body)
    }

    private var relativeTimestamp: String { Self.relativeTimestamp(msg.date) }

    static func relativeTimestamp(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        if cal.isDateInYesterday(date) {
            return "Hier"
        }
        return date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
    }

    var body: some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.md) {
            // Child avatar circle
            ZStack {
                Circle()
                    .fill(avatarColor.opacity(0.2))
                    .frame(width: 36, height: 36)
                if let child {
                    Text(String(child.firstName.prefix(1)).uppercased())
                        .font(NotoTheme.Typography.functional(14, weight: .bold))
                        .foregroundStyle(avatarColor)
                } else {
                    Image(systemName: "person.fill")
                        .font(NotoTheme.Typography.functional(14, weight: .bold))
                        .foregroundStyle(avatarColor)
                        .accessibilityLabel(MailboxRouting.parentLabel)
                }
            }

            // Main content
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                // Top row: sender + timestamp
                HStack(alignment: .firstTextBaseline) {
                    Text(msg.sender)
                        .font(NotoTheme.Typography.functional(13, weight: msg.read ? .regular : .bold))
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Text(relativeTimestamp)
                        .font(NotoTheme.Typography.dataSmall)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }

                // Subject
                Text(msg.subject)
                    .font(NotoTheme.Typography.body)
                    .foregroundStyle(msg.read ? NotoTheme.Colors.textSecondary : NotoTheme.Colors.textPrimary)
                    .fontWeight(.medium)
                    .lineLimit(1)

                // Body preview
                if !bodyPreview.isEmpty {
                    Text(bodyPreview)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .lineLimit(2)
                }

                // Tags row
                HStack(spacing: NotoTheme.Spacing.xs) {
                    // Child name chip
                    ChildTag(name: tagName, color: avatarColor)

                    // Source badge
                    SourceBadge(source: msg.source, imapProviderID: msg.imapProvider)

                    // Schoolbook badges
                    if msg.kind == .schoolbook {
                        BadgeLabel(text: "Carnet", color: NotoTheme.Colors.amber)
                        if !msg.read {
                            BadgeLabel(text: "À signer", color: NotoTheme.Colors.amber)
                        }
                    }

                    Spacer()

                    // Unread dot
                    if !msg.read {
                        Circle()
                            .fill(NotoTheme.Colors.brand)
                            .frame(width: 8, height: 8)
                    }
                }
            }
        }
        .padding(.vertical, NotoTheme.Spacing.sm)
    }
}

// MARK: - Source Badge

private struct SourceBadge: View {
    let source: MessageSource
    /// The providerID stamped on the Message at insert time — nil for
    /// legacy rows that predate the field. The mapping below intentionally
    /// hard-codes monlycée rather than using `IMAPServerConfig`'s
    /// dedicated-channel Set: each provider has its own brand and a
    /// future ENT (e-Lyco, Educ'Horus) would want its own label, not
    /// "MonLycée". Extend this switch when adding one.
    let imapProviderID: String?

    private var label: String { Self.label(source, imapProviderID: imapProviderID) }

    static func label(_ source: MessageSource, imapProviderID: String?) -> String {
        switch source {
        case .ent:      return "ENT"
        case .imap:     return imapProviderID == "monlycee" ? "MonLycée" : "IMAP"
        case .monlycee: return "MonLycée"
        case .pronote:  return "Pronote"
        }
    }

    private var color: Color {
        switch source {
        case .ent:      return NotoTheme.Colors.ent
        case .imap:     return NotoTheme.Colors.pronote
        case .monlycee: return NotoTheme.Colors.pronote
        case .pronote:  return NotoTheme.Colors.pronote
        }
    }

    var body: some View {
        BadgeLabel(text: label, color: color)
    }
}

// MARK: - Badge Label

private struct BadgeLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(NotoTheme.Typography.dataSmall)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

// MARK: - FeedMessageDetailView

struct FeedMessageDetailView: View {
    let msg: Message
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showSafari = false

    private var bodyText: String {
        HTMLText.plainText(fromHTML: msg.body)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NotoTheme.Spacing.md) {
                // Subject
                Text(msg.subject)
                    .font(NotoTheme.Typography.title)
                    .foregroundStyle(NotoTheme.Colors.textPrimary)

                // Sender + date
                HStack {
                    Label(msg.sender, systemImage: "person")
                    Spacer()
                    Text(msg.date.formatted(
                        .dateTime.weekday(.wide).day().month(.wide)
                            .locale(Locale(identifier: "fr_FR"))
                    ))
                }
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)

                Divider()
                    .background(NotoTheme.Colors.border)

                // Body
                if !bodyText.isEmpty {
                    LinkifiedText(bodyText)
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                } else if let link = msg.link, let url = URL(string: link) {
                    Button {
                        showSafari = true
                    } label: {
                        Label("Voir le message", systemImage: "safari")
                            .font(NotoTheme.Typography.body)
                            .frame(maxWidth: .infinity)
                            .padding(NotoTheme.Spacing.md)
                            .background(NotoTheme.Colors.brand.opacity(0.15))
                            .foregroundStyle(NotoTheme.Colors.brand)
                            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.sm))
                    }
                    .sheet(isPresented: $showSafari) {
                        SafariView(url: url)
                            .ignoresSafeArea()
                    }
                } else {
                    Text("Contenu non disponible")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, NotoTheme.Spacing.lg)
                }
            }
            .padding(NotoTheme.Spacing.md)
        }
        .background(NotoTheme.Colors.background)
        .navigationTitle("Message")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !msg.read {
                msg.read = true
                do {
                    try modelContext.save()
                } catch {
                    NSLog("[noto][error] FeedMessageDetailView: save failed: %@", error.localizedDescription)
                    msg.read = false
                }
            }
        }
    }
}

#Preview("Actualités — Dark") {
    ActualitesView().withPreviewData().preferredColorScheme(.dark)
}

#Preview("Actualités — Light") {
    ActualitesView().withPreviewData().preferredColorScheme(.light)
}
