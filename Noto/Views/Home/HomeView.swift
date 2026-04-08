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

    private var family: Family? { families.first }
    private var children: [Child] { family?.children ?? [] }
    private var isFamilyMode: Bool { selectedChild == nil }

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
                        lastSyncLabel: lastSyncLabel
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
        defer { isSyncing = false }

        let targetChildren = selectedChild.map { [$0] } ?? children
        let pronoteChildren = targetChildren.filter { $0.schoolType == .pronote }
        let entChildren = targetChildren.filter { $0.schoolType == .ent }

        // Pronote sync
        if !pronoteChildren.isEmpty {
            if let bridge = pronoteService.bridge {
                let syncService = PronoteSyncService(modelContext: modelContext)
                for (index, child) in pronoteChildren.enumerated() {
                    await syncService.sync(child: child, bridge: bridge, childIndex: index)
                }
            } else if entChildren.isEmpty {
                // Only show alert if there are no ENT children to sync either
                showNoConnectionAlert = true
            }
        }

        // ENT/PCN sync
        if !entChildren.isEmpty {
            await syncENTChildren(entChildren)
        }

        lastSyncDateInterval = Date.now.timeIntervalSince1970
        await refreshBriefing()
    }

    private func syncENTChildren(_ entChildren: [Child]) async {
        // Group children by provider so we login once per provider
        var byProvider: [ENTProvider: [Child]] = [:]
        for child in entChildren {
            let provider = child.entProvider.flatMap { ENTProvider(rawValue: $0) } ?? .pcn
            byProvider[provider, default: []].append(child)
        }

        let syncService = ENTSyncService(modelContext: modelContext)

        for (provider, children) in byProvider {
            // Re-login from Keychain
            let key = "ent_credentials_\(provider.rawValue)"
            let fallbackKey = "ent_credentials"
            guard let credsData = (try? KeychainService.load(key: key)) ?? (try? KeychainService.load(key: fallbackKey)),
                  let creds = String(data: credsData, encoding: .utf8) else {
                NSLog("[noto] No ENT credentials for \(provider.name)")
                continue
            }

            let parts = creds.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let client = ENTClient(provider: provider)
            do {
                try await client.login(email: String(parts[0]), password: String(parts[1]))
            } catch {
                NSLog("[noto] ENT re-login failed for \(provider.name): \(error)")
                continue
            }

            for child in children {
                do {
                    try await syncService.sync(
                        child: child,
                        client: client,
                        entChildId: child.entChildId ?? child.firstName
                    )
                    NSLog("[noto] ENT sync complete for \(child.firstName) (\(provider.name))")
                } catch {
                    NSLog("[noto] ENT sync failed for \(child.firstName): \(error)")
                }
            }
        }
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

    var body: some View {
        HStack(spacing: NotoTheme.Spacing.xs) {
            if isSyncing {
                ProgressView()
                    .scaleEffect(0.75)
                Text("Synchronisation...")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            } else if let label = lastSyncLabel {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
                Text(label)
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
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
