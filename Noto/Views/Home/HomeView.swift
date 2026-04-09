import SwiftUI
import SwiftData

struct HomeView: View {
    let selectedChild: Child?

    @Environment(\.modelContext) private var modelContext
    @Query private var families: [Family]
    @StateObject private var engine: BriefingEngineWrapper = .init()
    @ObservedObject private var pronoteService = PronoteService.shared

    @AppStorage("lastSyncDate") private var lastSyncDateInterval: Double = 0

    @State private var isSyncing = false
    @State private var showNoConnectionAlert = false
    @State private var showSettings = false
    @State private var syncError: String?
    @State private var showAbsence = false

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

    private var unreadMessageCount: Int {
        children.flatMap(\.messages).filter { !$0.read && $0.kind == .conversation }.count
    }

    private var urgentHomeworkCount: Int {
        children.flatMap(\.homework).filter { !$0.done && $0.dueDate <= Date.now.addingTimeInterval(86_400) }.count
    }

    private var unsignedCarnetsCount: Int {
        children.flatMap(\.messages).filter { !$0.read && $0.kind == .schoolbook }.count
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
            ScrollView {
                LazyVStack(spacing: NotoTheme.Spacing.md) {
                    // MARK: Story Rings
                    if !children.isEmpty {
                        StoryRingsRow(children: children)
                    }

                    // MARK: Hero Card
                    if !children.isEmpty {
                        HeroCard(
                            unreadMessageCount: unreadMessageCount,
                            children: children
                        )
                    }

                    // MARK: Morning Action Strip
                    if !children.isEmpty {
                        MorningActionStrip(
                            messageCount: unreadMessageCount,
                            homeworkCount: urgentHomeworkCount,
                            carnetCount: unsignedCarnetsCount
                        )
                    }

                    // MARK: Absence Shortcut
                    if isSchoolDay && hasENTChildren {
                        AbsenceShortcutCard(showAbsence: $showAbsence)
                    }

                    // Auto-reconnect banner
                    if pronoteService.isReconnecting {
                        ReconnectingBanner()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Greeting
                    if let name = family?.parentName {
                        GreetingHeader(parentName: name)
                    }

                    // Global status banner
                    GlobalStatusBanner(children: selectedChild.map { [$0] } ?? children)

                    // Sync status row
                    SyncStatusRow(
                        isSyncing: isSyncing,
                        lastSyncLabel: lastSyncLabel,
                        syncError: syncError
                    )

                    // Briefing text summary
                    if !engine.briefingText.isEmpty {
                        BriefingSummaryView(text: engine.briefingText)
                    }

                    // Cards
                    if engine.isLoading {
                        ProgressView()
                            .padding(.vertical, NotoTheme.Spacing.xl)
                    } else if engine.cards.isEmpty {
                        EmptyBriefingView()
                    } else {
                        ForEach(engine.cards) { card in
                            BriefingCardView(
                                card: card,
                                showChildName: isFamilyMode
                            )
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                }
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: engine.cards)
                .padding(NotoTheme.Spacing.md)
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showAbsence) {
                AbsenceView()
            }
            .refreshable {
                await performFullRefresh()
            }
            .task(id: selectedChild?.id) {
                engine.configure(modelContext: modelContext)
                await refreshBriefing()
            }
            .alert("Reconnexion requise", isPresented: $showNoConnectionAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Aucune session Pronote active. Reconnectez-vous pour synchroniser les données.")
            }
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
            if let bridge = pronoteService.bridge {
                let syncService = PronoteSyncService(modelContext: modelContext)
                for (index, child) in directPronoteChildren.enumerated() {
                    await syncService.sync(child: child, bridge: bridge, childIndex: index)
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
                let syncService = PronoteSyncService(modelContext: modelContext)
                for (index, child) in monlyceeChildren.enumerated() {
                    await syncService.sync(child: child, bridge: bridge, childIndex: index)
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
                try await client.login(email: String(parts[0]), password: String(parts[1]))
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

    private var urgentHomeworkCount: Int {
        let in24h = Date.now.addingTimeInterval(86_400)
        return children.flatMap(\.homework).filter { !$0.done && $0.dueDate <= in24h }.count
    }

    private var recentLowGrades: [Grade] {
        let sevenDaysAgo = Date.now.addingTimeInterval(-7 * 86_400)
        return children.flatMap(\.grades).filter {
            $0.date >= sevenDaysAgo && $0.normalizedValue < 10
        }
    }

    private var alertMessages: [String] {
        var msgs: [String] = []
        if urgentHomeworkCount > 0 {
            msgs.append("\(urgentHomeworkCount) devoir\(urgentHomeworkCount > 1 ? "s" : "") à rendre demain")
        }
        if !recentLowGrades.isEmpty {
            msgs.append("\(recentLowGrades.count) note\(recentLowGrades.count > 1 ? "s" : "") sous 10 cette semaine")
        }
        return msgs
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
            .background(NotoTheme.Colors.success.opacity(0.08))
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
            .background(NotoTheme.Colors.warning.opacity(0.1))
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

    private var hasActivity: Bool {
        let unreadMsgs = child.messages.contains { !$0.read }
        return unreadMsgs
    }

    private var ringColor: Color {
        hasActivity ? NotoTheme.Colors.brand : NotoTheme.Colors.border
    }

    private var ringWidth: CGFloat {
        hasActivity ? 3 : 1.5
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
        Button(action: {}) {
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
                                    .font(NotoTheme.Typography.mono(22, weight: .bold))
                                    .foregroundStyle(NotoTheme.Colors.paper)
                            )
                    }

                    // School type badge
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(schoolBadgeLabel)
                                .font(NotoTheme.Typography.mono(7, weight: .bold))
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

                Text(child.firstName)
                    .font(NotoTheme.Typography.mono(10))
                    .foregroundStyle(NotoTheme.Colors.textPrimary)
                    .lineLimit(1)

                Text(child.grade)
                    .font(NotoTheme.Typography.mono(9))
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
    }
}

// MARK: - Hero Card

private struct HeroCard: View {
    let unreadMessageCount: Int
    let children: [Child]

    private var dateString: String {
        Date.now.formatted(.dateTime.day().month(.wide).locale(Locale(identifier: "fr_FR")))
    }

    private var weekdayString: String {
        Date.now.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "fr_FR"))).capitalized
    }

    var body: some View {
        // TODO: blog photo hero — use school blog photo when available from PCN
        ZStack(alignment: .bottomLeading) {
            // Background
            RoundedRectangle(cornerRadius: NotoTheme.Radius.lg)
                .fill(NotoTheme.Colors.indigo)
                .frame(height: 180)

            // Subtle grid pattern overlay
            GeometryReader { geo in
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
                .frame(width: geo.size.width, height: geo.size.height)
                .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.lg))
            }
            .frame(height: 180)

            if unreadMessageCount > 0 {
                // Message count hero
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: NotoTheme.Spacing.sm) {
                        Text("\(unreadMessageCount)")
                            .font(NotoTheme.Typography.dataLarge)
                            .foregroundStyle(NotoTheme.Colors.brand)
                        Image(systemName: "envelope.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(NotoTheme.Colors.brand)
                    }
                    Text("message\(unreadMessageCount > 1 ? "s" : "") non lu\(unreadMessageCount > 1 ? "s" : "")")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                .padding(NotoTheme.Spacing.md)
            } else {
                // Journée summary hero
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                    Text(weekdayString)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.mist)
                        .textCase(.uppercase)
                    Text(dateString)
                        .font(NotoTheme.Typography.dataLarge)
                        .foregroundStyle(NotoTheme.Colors.paper)
                    Text("Bonne journée")
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                }
                .padding(NotoTheme.Spacing.md)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Morning Action Strip

private struct MorningActionStrip: View {
    let messageCount: Int
    let homeworkCount: Int
    let carnetCount: Int

    var body: some View {
        let chips = buildChips()
        if !chips.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NotoTheme.Spacing.sm) {
                    ForEach(chips, id: \.label) { chip in
                        ActionChip(icon: chip.icon, count: chip.count, label: chip.label, accentColor: chip.accentColor)
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
    }

    private func buildChips() -> [ChipData] {
        var result: [ChipData] = []
        if messageCount > 0 {
            result.append(ChipData(icon: "envelope.fill", count: messageCount, label: "messages", accentColor: NotoTheme.Colors.brand))
        }
        if homeworkCount > 0 {
            result.append(ChipData(icon: "pencil", count: homeworkCount, label: "devoirs", accentColor: NotoTheme.Colors.cobalt))
        }
        if carnetCount > 0 {
            result.append(ChipData(icon: "signature", count: carnetCount, label: "carnet\(carnetCount > 1 ? "s" : "") à signer", accentColor: NotoTheme.Colors.amber))
        }
        return result
    }
}

private struct ActionChip: View {
    let icon: String
    let count: Int
    let label: String
    let accentColor: Color

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(accentColor)
            Text("\(count) \(label)")
                .font(NotoTheme.Typography.mono(12))
                .foregroundStyle(NotoTheme.Colors.textPrimary)
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
                        .font(NotoTheme.Typography.mono(13, weight: .bold))
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
