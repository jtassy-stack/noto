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
                    // Greeting
                    if let name = family?.parentName {
                        GreetingHeader(parentName: name)
                    }

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
            .navigationTitle(selectedChild?.firstName ?? "nōto.")
            .navigationBarTitleDisplayMode(.large)
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
        guard let bridge = pronoteService.bridge else {
            showNoConnectionAlert = true
            // Still rebuild briefing from cached data
            await refreshBriefing()
            return
        }

        isSyncing = true
        defer { isSyncing = false }

        let syncService = PronoteSyncService(modelContext: modelContext)
        let targetChildren = selectedChild.map { [$0] } ?? children

        for (index, child) in targetChildren.enumerated() {
            await syncService.sync(child: child, bridge: bridge, childIndex: index)
        }

        lastSyncDateInterval = Date.now.timeIntervalSince1970
        await refreshBriefing()
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
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            Text(greeting)
                .font(NotoTheme.Typography.largeTitle)
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
            .background(NotoTheme.Colors.brand.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.card))
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
