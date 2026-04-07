import SwiftUI
import SwiftData

struct HomeView: View {
    let selectedChild: Child?

    @Environment(\.modelContext) private var modelContext
    @Query private var families: [Family]
    @StateObject private var engine: BriefingEngineWrapper = .init()

    private var family: Family? { families.first }
    private var children: [Child] { family?.children ?? [] }
    private var isFamilyMode: Bool { selectedChild == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: NotoTheme.Spacing.md) {
                    // Greeting
                    if let name = family?.parentName {
                        GreetingHeader(parentName: name)
                    }

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
                        }
                    }
                }
                .padding(NotoTheme.Spacing.md)
            }
            .navigationTitle(selectedChild?.firstName ?? "nōto.")
            .navigationBarTitleDisplayMode(.large)
            .refreshable {
                await refreshBriefing()
            }
            .task(id: selectedChild?.id) {
                engine.configure(modelContext: modelContext)
                await refreshBriefing()
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
