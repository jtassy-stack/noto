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
    @State private var isRefreshing = false
    @State private var lastSyncDate: Date? = nil
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

    private func avatarColor(for child: Child) -> Color {
        let idx = children.firstIndex(where: { $0.persistentModelID == child.persistentModelID }) ?? 0
        return Self.avatarColors[idx % Self.avatarColors.count]
    }

    // MARK: - Filtered items

    private var allItems: [(child: Child, msg: Message)] {
        children.flatMap { child in
            child.messages.map { (child: child, msg: $0) }
        }.sorted { $0.msg.date > $1.msg.date }
    }

    private var filteredItems: [(child: Child, msg: Message)] {
        switch activeFilter {
        case .tous:
            return allItems
        case .messages:
            return allItems.filter { $0.msg.kind == .conversation }
        case .carnets:
            return allItems.filter { $0.msg.kind == .schoolbook }
        case .photos:
            return []
        }
    }

    // MARK: - Date grouping

    private var groupedItems: [(header: String, items: [(child: Child, msg: Message)])] {
        var groups: [(header: String, items: [(child: Child, msg: Message)])] = []
        var current: (header: String, items: [(child: Child, msg: Message)])?

        for item in filteredItems {
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

    @MainActor
    private func syncAll() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastSyncDate = .now
        }
        for child in children {
            switch child.schoolType {
            case .ent:
                let provider = child.entProvider ?? .pcn
                let client = ENTClient(provider: provider)
                let service = ENTSyncService(modelContext: modelContext)
                guard let entChildId = child.entChildId else {
                    syncError = "\(child.firstName) : profil ENT incomplet (pas d'ID enfant)."
                    continue
                }
                do {
                    // Re-authenticate each sync — ENT session cookies don't survive app restarts
                    let credKey = "ent_credentials_\(provider.rawValue)"
                    guard let credData = try? KeychainService.load(key: credKey),
                          let credStr = String(data: credData, encoding: .utf8) else {
                        syncError = "\(child.firstName) : identifiants ENT manquants. Reconnectez-vous dans Réglages."
                        continue
                    }
                    let parts = credStr.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else {
                        syncError = "\(child.firstName) : identifiants ENT corrompus."
                        continue
                    }
                    let loginURL = provider.baseURL.appendingPathComponent("auth/login")
                    let cookies = try await HeadlessENTAuth.login(
                        loginURL: loginURL,
                        email: String(parts[0]),
                        password: String(parts[1])
                    )
                    ENTClient.importCookies(cookies)
                    NSLog("[noto] ENT re-auth OK for %@ (%d cookies)", child.firstName, cookies.count)
                    try await service.sync(child: child, client: client, entChildId: entChildId)
                    let photoCount = child.photos.count
                    NSLog("[noto] ENT sync OK for %@ — %d photos total", child.firstName, photoCount)
                    if photoCount == 0 {
                        syncError = "\(child.firstName) : aucune photo partagée trouvée sur l'ENT."
                    }
                } catch ENTError.sessionExpired, ENTError.badCredentials {
                    NSLog("[noto][error] ENT bad credentials for %@", child.firstName)
                    syncError = "Identifiants PCN incorrects pour \(child.firstName). Reconnectez-vous dans Réglages."
                } catch {
                    NSLog("[noto][error] ENT sync error for %@: %@", child.firstName, error.localizedDescription)
                    syncError = "Sync ENT \(child.firstName) : \(error.localizedDescription)"
                }
            case .pronote:
                // IMAP sync applies to all children sharing the family mailbox
                let service = IMAPSyncService(modelContext: modelContext)
                do {
                    try await service.sync(for: child)
                } catch {
                    NSLog("[noto][error] IMAP sync failed for %@: %@", child.firstName, error.localizedDescription)
                    syncError = "Erreur de synchronisation des messages."
                }
            }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                // Filter chips
                FilterChipsBar(activeFilter: $activeFilter)

                Divider()
                    .background(NotoTheme.Colors.border)

                // MonLycée setup prompt — visible when IMAP not configured
                if !imapConfigured {
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
                        lastSyncDate: lastSyncDate
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
                Task { await syncAll() }
            }
        }
    }

    // MARK: - Sub-views

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
        List {
            ForEach(groupedItems, id: \.header) { group in
                Section {
                    ForEach(group.items, id: \.msg.persistentModelID) { item in
                        FeedItemRow(
                            msg: item.msg,
                            child: item.child,
                            avatarColor: avatarColor(for: item.child)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            path.append(
                                item.msg.kind == .schoolbook
                                    ? .schoolbook(child: item.child, msg: item.msg)
                                    : .conversation(item.msg)
                            )
                        }
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
                    Text(group.header)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await syncAll() }
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
    let child: Child
    let avatarColor: Color

    /// Strip HTML tags for body preview.
    private var bodyPreview: String {
        msg.body
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var relativeTimestamp: String {
        let cal = Calendar.current
        if cal.isDateInToday(msg.date) {
            return msg.date.formatted(.dateTime.hour().minute())
        }
        if cal.isDateInYesterday(msg.date) {
            return "Hier"
        }
        return msg.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR")))
    }

    var body: some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.md) {
            // Child avatar circle
            ZStack {
                Circle()
                    .fill(avatarColor.opacity(0.2))
                    .frame(width: 36, height: 36)
                Text(String(child.firstName.prefix(1)).uppercased())
                    .font(NotoTheme.Typography.functional(14, weight: .bold))
                    .foregroundStyle(avatarColor)
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
                    ChildTag(name: child.firstName, color: avatarColor)

                    // Source badge
                    SourceBadge(source: msg.source)

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

    private var label: String {
        switch source {
        case .ent: return "ENT"
        case .imap: return "IMAP"
        case .pronote: return "Pronote"
        }
    }

    private var color: Color {
        switch source {
        case .ent: return NotoTheme.Colors.ent
        case .imap: return NotoTheme.Colors.pronote
        case .pronote: return NotoTheme.Colors.pronote
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
        msg.body
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                    Text(bodyText)
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
