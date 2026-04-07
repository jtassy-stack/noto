import Foundation
import SwiftData

/// Orchestrates the full briefing pipeline:
/// Sync → Insights → Curriculum matching → Culture recos → Summarize
@MainActor
final class BriefingEngine: ObservableObject {
    @Published var briefingText: String = ""
    @Published var cards: [BriefingCard] = []
    @Published var isLoading: Bool = false

    private let modelContext: ModelContext
    private let curriculumService: CurriculumService
    private let insightEngine: InsightEngine
    private let cultureClient: CultureAPIClient?

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.curriculumService = CurriculumService()
        self.insightEngine = InsightEngine(modelContext: modelContext)

        // Load API key from Keychain
        if let keyData = try? KeychainService.load(key: "culture_api_key"),
           let key = String(data: keyData, encoding: .utf8) {
            self.cultureClient = CultureAPIClient(apiKey: key)
        } else {
            self.cultureClient = nil
        }
    }

    /// Build briefing for a specific child.
    func buildBriefing(for child: Child) async {
        isLoading = true
        defer { isLoading = false }

        // 1. Analyze grades → generate insights
        insightEngine.analyze(child: child)

        // 2. Build cards from school data + insights
        var newCards = buildSchoolCards(for: child)

        // 3. Build culture query from curriculum matching
        let chapterContexts = insightEngine.chapterContexts(for: child)
        let difficultyContexts = insightEngine.difficultyContexts(for: child)
        let matcher = CurriculumMatcher(curriculumService: curriculumService)
        let cultureQuery = matcher.buildCultureQuery(
            level: child.grade,
            recentChapters: chapterContexts,
            difficulties: difficultyContexts
        )

        // 4. Query culture-api for recommendations
        if !cultureQuery.topics.isEmpty, let cultureClient = cultureClient {
            let recos = try? await cultureClient.recommendations(
                topics: cultureQuery.topics,
                ageMin: cultureQuery.ageRange.min,
                ageMax: cultureQuery.ageRange.max,
                context: cultureQuery.context,
                limit: 3
            )
            for reco in recos ?? [] {
                let icon = switch reco.type {
                case "podcast": "headphones"
                case "oeuvre": "paintpalette"
                default: "calendar"
                }
                newCards.append(BriefingCard(
                    type: .cultureReco,
                    childName: child.firstName,
                    title: reco.title,
                    subtitle: reco.topics.prefix(3).joined(separator: ", "),
                    priority: cultureQuery.hasDifficultyContext ? .positive : .normal,
                    icon: icon,
                    detail: cultureQuery.hasDifficultyContext ? "Lié à une matière en difficulté" : nil
                ))
            }
        }

        // 5. Generate text summary (build items on MainActor, summarize async)
        let items = TextSummarizer.buildBriefingItems(for: child)
        briefingText = await TextSummarizer.summarize(briefingItems: items)

        // 6. Sort cards by priority
        cards = newCards.sorted { $0.priority > $1.priority }
    }

    /// Build aggregated family briefing.
    func buildFamilyBriefing(children: [Child]) async {
        isLoading = true
        defer { isLoading = false }

        var allCards: [BriefingCard] = []

        for child in children {
            insightEngine.analyze(child: child)
            allCards.append(contentsOf: buildSchoolCards(for: child))
        }

        // Batch culture-api query for all children
        if let cultureClient {
            let matcher = CurriculumMatcher(curriculumService: curriculumService)
            var batchQueries: [BatchQuery] = []
            var childNames: [String] = []

            for child in children {
                let chapters = insightEngine.chapterContexts(for: child)
                let diffs = insightEngine.difficultyContexts(for: child)
                let q = matcher.buildCultureQuery(level: child.grade, recentChapters: chapters, difficulties: diffs)
                guard !q.topics.isEmpty else { continue }
                batchQueries.append(BatchQuery(
                    topics: q.topics,
                    ageMin: q.ageRange.min,
                    ageMax: q.ageRange.max,
                    context: q.context,
                    limit: 3
                ))
                childNames.append(child.firstName)
            }

            if !batchQueries.isEmpty {
                let batchResult = try? await cultureClient.batchRecommendations(queries: batchQueries)

                // Per-child recos
                for (index, recos) in (batchResult?.perQuery ?? []).enumerated() where index < childNames.count {
                    for reco in recos.prefix(2) {
                        allCards.append(BriefingCard(
                            type: .cultureReco,
                            childName: childNames[index],
                            title: reco.title,
                            subtitle: reco.topics.prefix(3).joined(separator: ", "),
                            priority: .normal,
                            icon: reco.type == "podcast" ? "headphones" : "calendar"
                        ))
                    }
                }

                // Shared family recos (match multiple children)
                for shared in batchResult?.shared ?? [] {
                    let names = shared.matchedQueryIndices
                        .compactMap { $0 < childNames.count ? childNames[$0] : nil }
                        .joined(separator: " et ")
                    allCards.append(BriefingCard(
                        type: .familyReco,
                        childName: "Famille",
                        title: shared.result.title,
                        subtitle: "Pour \(names)",
                        priority: .positive,
                        icon: "figure.2.and.child.holdinghands"
                    ))
                }
            }
        }

        // Generate combined summary
        var allItems: [BriefingItem] = []
        for child in children {
            allItems.append(contentsOf: TextSummarizer.buildBriefingItems(for: child))
        }
        briefingText = await TextSummarizer.summarize(briefingItems: allItems)

        cards = allCards.sorted { $0.priority > $1.priority }
    }

    // MARK: - Card Builders

    private func buildSchoolCards(for child: Child) -> [BriefingCard] {
        var cards: [BriefingCard] = []
        let now = Date.now
        let today = Calendar.current.startOfDay(for: now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let twoDays = Calendar.current.date(byAdding: .day, value: 2, to: today)!

        // Cancelled classes today
        let cancelled = child.schedule.filter { $0.cancelled && $0.start >= today && $0.start < tomorrow }
        for c in cancelled {
            cards.append(BriefingCard(
                type: .cancelled,
                childName: child.firstName,
                title: "\(c.subject) annulé",
                subtitle: formatTime(c.start),
                priority: .urgent,
                icon: "xmark.circle"
            ))
        }

        // Urgent homework (due today or tomorrow)
        let urgentHW = child.homework.filter { !$0.done && $0.dueDate >= today && $0.dueDate < twoDays }
        for hw in urgentHW {
            let isToday = Calendar.current.isDateInToday(hw.dueDate)
            cards.append(BriefingCard(
                type: .homework,
                childName: child.firstName,
                title: hw.subject,
                subtitle: String(hw.descriptionText.prefix(80)),
                priority: isToday ? .urgent : .normal,
                icon: "pencil.and.list.clipboard",
                detail: isToday ? "Pour aujourd'hui" : "Pour demain"
            ))
        }

        // Unread messages
        let unread = child.messages.filter { !$0.read }
        if !unread.isEmpty {
            let latest = unread.sorted { $0.date > $1.date }.first!
            cards.append(BriefingCard(
                type: .message,
                childName: child.firstName,
                title: "\(unread.count) message\(unread.count > 1 ? "s" : "") non lu\(unread.count > 1 ? "s" : "")",
                subtitle: "\(latest.sender) — \(latest.subject)",
                priority: unread.count >= 3 ? .urgent : .normal,
                icon: "envelope.badge"
            ))
        }

        // Insights (difficulties, strengths, trends)
        for insight in child.insights {
            let (icon, priority): (String, BriefingPriority) = switch insight.type {
            case .difficulty: ("exclamationmark.triangle", .urgent)
            case .strength: ("star", .positive)
            case .trend: ("chart.line.uptrend.xyaxis", .normal)
            case .alert: ("bell.badge", .urgent)
            }

            cards.append(BriefingCard(
                type: .insight,
                childName: child.firstName,
                title: insight.subject,
                subtitle: insight.value,
                priority: priority,
                icon: icon
            ))
        }

        return cards
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "fr_FR")))
    }
}

// MARK: - Briefing Card

struct BriefingCard: Identifiable {
    let id = UUID()
    let type: BriefingCardType
    let childName: String
    let title: String
    let subtitle: String
    let priority: BriefingPriority
    let icon: String
    var detail: String?
}

enum BriefingCardType {
    case cancelled
    case homework
    case test
    case message
    case insight
    case cultureReco
    case familyReco
}
