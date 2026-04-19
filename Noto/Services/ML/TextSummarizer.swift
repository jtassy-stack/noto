import Foundation

/// On-device text summarization for briefings.
/// iOS 26+: Apple FoundationModels with tool calling — the model can pull
/// live school data (schedule, grades, homework) to build a rich briefing.
/// Fallback: template-based generation (no ML).
enum TextSummarizer {

    // MARK: - Public API

    /// Generate a briefing summary from pre-built items (template path).
    static func summarize(briefingItems: [BriefingItem]) async -> String {
        if #available(iOS 26.0, *) {
            if let result = await foundationModelFromItems(items: briefingItems) {
                return result
            }
        }
        return templateSummary(items: briefingItems)
    }

    /// Generate a briefing with tool calling — the model pulls data itself.
    /// This is the preferred path on iOS 26+: richer, more natural output.
    static func generateBriefing(for child: Child, familyRecos: [CultureReco]) async -> String {
        if #available(iOS 26.0, *) {
            if let result = await foundationModelWithTools(child: child, familyRecos: familyRecos) {
                return result
            }
        }

        // Fallback: build items manually, then template
        let items = buildBriefingItems(for: child) + buildDeviceLevelItems()
        return templateSummary(items: items)
    }

    // MARK: - Apple FoundationModels with Tool Calling (iOS 26+)

    @available(iOS 26.0, *)
    private static func foundationModelWithTools(child: Child, familyRecos: [CultureReco]) async -> String? {
        // FoundationModels tool calling flow:
        //
        // 1. Register tools (schedule, grades, homework, messages, culture)
        // 2. Send system prompt instructing parent-addressed French output
        // 3. Model calls tools as needed to gather data
        // 4. Model generates natural language briefing
        //
        // This runs entirely on-device — no data leaves the phone.

        // TODO: Uncomment when FoundationModels SDK is available in Xcode
        //
        // import FoundationModels
        //
        // let session = LanguageModelSession()
        //
        // // Register tools
        // let scheduleTool = session.registerTool(
        //     name: "get_schedule",
        //     description: "Récupère l'emploi du temps du jour pour l'enfant"
        // ) { () -> ScheduleToolResult in
        //     ScheduleTool(child: child).call()
        // }
        //
        // let gradesTool = session.registerTool(
        //     name: "get_grades",
        //     description: "Récupère les notes récentes, tendances, difficultés et points forts"
        // ) { () -> GradesToolResult in
        //     GradesTool(child: child).call()
        // }
        //
        // let homeworkTool = session.registerTool(
        //     name: "get_homework",
        //     description: "Récupère les devoirs à venir"
        // ) { () -> HomeworkToolResult in
        //     HomeworkTool(child: child).call()
        // }
        //
        // let messagesTool = session.registerTool(
        //     name: "get_messages",
        //     description: "Récupère les messages non lus de l'école"
        // ) { () -> MessagesToolResult in
        //     MessagesTool(child: child).call()
        // }
        //
        // let cultureTool = session.registerTool(
        //     name: "get_culture_recommendations",
        //     description: "Récupère les recommandations culturelles liées aux cours et difficultés"
        // ) { () -> CultureRecoToolResult in
        //     CultureRecoTool(child: child, familyRecos: familyRecos).call()
        // }
        //
        // let systemPrompt = """
        // Tu es l'assistant de nōto, une app pour parents.
        // Tu t'adresses au PARENT, pas à l'élève.
        // Tu parles en français, de manière concise et chaleureuse.
        //
        // Génère un briefing du jour pour \(child.firstName) (\(child.grade)).
        // Utilise les outils disponibles pour récupérer les données.
        //
        // Structure ton briefing :
        // 1. Ce qui est urgent ou important (contrôles, messages non lus)
        // 2. L'emploi du temps du jour (cours annulés, changements)
        // 3. Les devoirs à rendre bientôt
        // 4. Les tendances (progrès ou difficultés)
        // 5. Les alertes Temps d'écran si la limite a été dépassée (ex : "La limite de 2h a été atteinte 3 fois cette semaine")
        // 6. Une recommandation culturelle si pertinente
        //
        // Sois bref (3-5 phrases max). Pas de liste à puces, écris en prose naturelle.
        // Si une matière est en difficulté et qu'il y a une reco culturelle liée, mentionne le lien.
        // """
        //
        // do {
        //     let response = try await session.respond(
        //         to: systemPrompt,
        //         tools: [scheduleTool, gradesTool, homeworkTool, messagesTool, cultureTool]
        //     )
        //     return response.content
        // } catch {
        //     return nil
        // }

        return nil
    }

    @available(iOS 26.0, *)
    private static func foundationModelFromItems(items: [BriefingItem]) async -> String? {
        // Simpler path: pass pre-built items as context, no tool calling
        // TODO: Implement with FoundationModels when SDK available
        return nil
    }

    // MARK: - Manual Briefing Item Builder (fallback)

    static func buildBriefingItems(for child: Child) -> [BriefingItem] {
        var items: [BriefingItem] = []
        let now = Date.now
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: now)!

        // Upcoming tests (schedule entries marked as test)
        // TODO: detect tests from schedule when data available

        // Unread messages
        let unread = child.messages.filter { !$0.read }
        if !unread.isEmpty {
            items.append(BriefingItem(
                type: .message,
                childName: child.firstName,
                summary: "\(unread.count) message\(unread.count > 1 ? "s" : "") non lu\(unread.count > 1 ? "s" : "")",
                priority: unread.count >= 3 ? .urgent : .normal,
                date: unread.first?.date
            ))
        }

        // Upcoming homework
        let pendingHW = child.homework.filter { !$0.done && $0.dueDate >= now && $0.dueDate <= tomorrow }
        for hw in pendingHW {
            items.append(BriefingItem(
                type: .homework,
                childName: child.firstName,
                summary: "\(hw.subject) — \(hw.descriptionText.prefix(60))",
                priority: Calendar.current.isDateInToday(hw.dueDate) ? .urgent : .normal,
                date: hw.dueDate
            ))
        }

        // Grade insights
        for insight in child.insights {
            let priority: BriefingPriority = switch insight.type {
            case .difficulty: .urgent
            case .strength: .positive
            case .trend: .normal
            case .alert: .urgent
            }

            items.append(BriefingItem(
                type: .insight,
                childName: child.firstName,
                summary: "\(insight.subject) — \(insight.value)",
                priority: priority,
                date: insight.detectedAt
            ))
        }

        // Cancelled classes today
        let today = Calendar.current.startOfDay(for: now)
        let todayEnd = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let cancelled = child.schedule.filter { $0.cancelled && $0.start >= today && $0.start < todayEnd }
        for c in cancelled {
            items.append(BriefingItem(
                type: .absence,
                childName: child.firstName,
                summary: "\(c.subject) annulé",
                priority: .normal,
                date: c.start
            ))
        }

        return items.sorted { $0.priority > $1.priority }
    }

    static func buildDeviceLevelItems() -> [BriefingItem] {
        let screenAlerts = ScreenTimeEventStore.recentEvents(withinDays: 1)
        guard !screenAlerts.isEmpty else { return [] }
        let count = screenAlerts.count
        let hours = screenAlerts.last?.thresholdHours ?? 2
        return [BriefingItem(
            type: .screenTime,
            childName: "Appareil",
            summary: "Limite temps d'écran \(hours)h dépassée · dernières 24h\(count > 1 ? " (\(count) fois)" : "")",
            priority: count >= 2 ? .urgent : .normal,
            date: screenAlerts.last?.date
        )]
    }

    // MARK: - Template-based fallback

    private static func templateSummary(items: [BriefingItem]) -> String {
        guard !items.isEmpty else {
            return "Rien de particulier à signaler aujourd'hui."
        }

        var parts: [String] = []

        let urgent = items.filter { $0.priority == .urgent }
        let homework = items.filter { $0.type == .homework }
        let grades = items.filter { $0.type == .grade || $0.type == .insight }
        let culture = items.filter { $0.type == .cultureReco }
        let cancelled = items.filter { $0.type == .absence }
        let screenTime = items.filter { $0.type == .screenTime }

        if !urgent.isEmpty {
            parts.append(urgent.map(\.summary).joined(separator: ". "))
        }

        if !cancelled.isEmpty {
            let subjects = cancelled.map(\.summary).joined(separator: ", ")
            parts.append("Cours annulés : \(subjects).")
        }

        if !homework.isEmpty {
            parts.append("\(homework.count) devoir\(homework.count > 1 ? "s" : "") à rendre.")
        }

        if let positive = grades.first(where: { $0.priority == .positive }) {
            parts.append(positive.summary)
        }

        if let difficulty = grades.first(where: { $0.priority == .urgent }) {
            parts.append(difficulty.summary)
        }

        if let st = screenTime.first {
            parts.append(st.summary + ".")
        }

        if let reco = culture.first {
            parts.append("Recommandation : \(reco.summary)")
        }

        return parts.joined(separator: " ")
    }
}

// MARK: - Briefing Item

struct BriefingItem {
    let type: BriefingItemType
    let childName: String
    let summary: String
    let priority: BriefingPriority
    let date: Date?
}

enum BriefingItemType {
    case test
    case homework
    case grade
    case message
    case absence
    case cultureReco
    case insight
    case screenTime
}

enum BriefingPriority: Int, Comparable {
    case urgent = 3
    case positive = 2
    case normal = 1
    case low = 0

    static func < (lhs: BriefingPriority, rhs: BriefingPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
