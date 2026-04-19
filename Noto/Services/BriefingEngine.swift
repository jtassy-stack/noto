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
    private let cultureClient: CultureAPIClient

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        self.curriculumService = CurriculumService()
        self.insightEngine = InsightEngine(modelContext: modelContext)

        self.cultureClient = CultureAPIClient()
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
        if !cultureQuery.topics.isEmpty {
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

        // 5. Device-level screen-time card (once per briefing, not per child)
        let screenTimeAlerts = ScreenTimeEventStore.recentEvents(withinDays: 1)
        if !screenTimeAlerts.isEmpty {
            let count = screenTimeAlerts.count
            let latest = screenTimeAlerts.last!
            newCards.append(BriefingCard(
                type: .screenTime,
                childName: "Appareil",
                title: "Limite temps d'écran dépassée",
                subtitle: count > 1
                    ? "\(count) fois · dernières 24h · limite \(latest.thresholdHours)h"
                    : "Limite \(latest.thresholdHours)h atteinte · dernières 24h",
                priority: count >= 2 ? .urgent : .normal,
                icon: "hourglass.badge.plus"
            ))
        }

        // 6. Generate text summary (build items on MainActor, summarize async)
        let items = TextSummarizer.buildBriefingItems(for: child)
            + TextSummarizer.buildDeviceLevelItems()
        briefingText = await TextSummarizer.summarize(briefingItems: items)

        // 7. Sort cards by priority
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

        // Device-level screen-time card (once per family briefing)
        let screenTimeAlerts = ScreenTimeEventStore.recentEvents(withinDays: 1)
        if !screenTimeAlerts.isEmpty {
            let count = screenTimeAlerts.count
            let latest = screenTimeAlerts.last!
            allCards.append(BriefingCard(
                type: .screenTime,
                childName: "Appareil",
                title: "Limite temps d'écran dépassée",
                subtitle: count > 1
                    ? "\(count) fois · dernières 24h · limite \(latest.thresholdHours)h"
                    : "Limite \(latest.thresholdHours)h atteinte · dernières 24h",
                priority: count >= 2 ? .urgent : .normal,
                icon: "hourglass.badge.plus"
            ))
        }

        // Batch culture-api query for all children
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

        // Generate combined summary
        var allItems: [BriefingItem] = []
        for child in children {
            allItems.append(contentsOf: TextSummarizer.buildBriefingItems(for: child))
        }
        allItems.append(contentsOf: TextSummarizer.buildDeviceLevelItems())
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
                detail: isToday ? "Pour aujourd'hui" : "Pour demain",
                targetID: hw.persistentModelID
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

        // Wellbeing signal — emitted only when multiple factors align,
        // so we never paint the card for a single bad grade week. The
        // copy is framed as observations, not diagnosis.
        if let signal = WellbeingEngine.detect(for: child, now: now) {
            cards.append(BriefingCard(
                type: .wellbeing,
                childName: signal.childName,
                title: signal.title,
                subtitle: signal.subtitle,
                priority: signal.severity == .urgent ? .urgent : .normal,
                icon: "heart.text.square",
                wellbeing: signal
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
                icon: icon,
                targetID: insight.persistentModelID
            ))
        }

        return cards
    }

    private func formatTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(Locale(identifier: "fr_FR")))
    }
}

// MARK: - Briefing Card

struct BriefingCard: Identifiable, Equatable {
    let id = UUID()
    let type: BriefingCardType
    let childName: String
    let title: String
    let subtitle: String
    let priority: BriefingPriority
    let icon: String
    let detail: String?
    /// SwiftData identifier of the underlying item. Populated for
    /// detail-routing types (`.homework`, `.insight`); nil for
    /// tab-routing types (`.cancelled`, `.message`, `.cultureReco`,
    /// `.familyReco`) which jump to a list view instead of a detail.
    let targetID: PersistentIdentifier?
    /// Non-nil only for `.wellbeing` cards. Carries the factor list so
    /// the resource sheet can show exactly what triggered this card
    /// without re-running the detector.
    let wellbeing: WellbeingSignal?

    init(
        type: BriefingCardType,
        childName: String,
        title: String,
        subtitle: String,
        priority: BriefingPriority,
        icon: String,
        detail: String? = nil,
        targetID: PersistentIdentifier? = nil,
        wellbeing: WellbeingSignal? = nil
    ) {
        self.type = type
        self.childName = childName
        self.title = title
        self.subtitle = subtitle
        self.priority = priority
        self.icon = icon
        self.detail = detail
        self.targetID = targetID
        self.wellbeing = wellbeing
    }
}

enum BriefingCardType {
    case cancelled
    case homework
    case message
    case insight
    case cultureReco
    case familyReco
    /// Multi-signal pattern detected by `WellbeingEngine`. Taps open the
    /// `WellbeingResourcesView` sheet; not a link to a SwiftData detail.
    case wellbeing
    case screenTime
}
