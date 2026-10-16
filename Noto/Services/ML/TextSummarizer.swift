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

    /// Not wired, on purpose (plan 3.3). The former draft used a pseudo-API
    /// (`session.registerTool`, `respond(to:tools:)`) that does not exist.
    /// With the real API, tools are passed to `LanguageModelSession(tools:)`
    /// and conform to `Tool`, which is `Sendable` with a `@concurrent
    /// call(arguments:)`: a tool cannot hold the `Child` `@Model` that
    /// `BriefingTools` reads, so every result would have to be snapshotted
    /// up front, at which point tool calling only adds five schemas to a
    /// 4096-token context for nothing. `generateBriefing(for:familyRecos:)`
    /// has no caller today; `summarize(briefingItems:)` below is the live
    /// on-device path and gets the same data as pre-built items.
    @available(iOS 26.0, *)
    private static func foundationModelWithTools(child: Child, familyRecos: [CultureReco]) async -> String? {
        nil
    }

    /// Simpler path: the pre-built items are the whole context, no tool
    /// calling. Parent tone (vouvoiement). Any failure, timeout or output
    /// that breaks the tone returns nil, and the template text is used.
    @available(iOS 26.0, *)
    private static func foundationModelFromItems(items: [BriefingItem]) async -> String? {
        guard !items.isEmpty else { return nil }
        let lines = items.prefix(maxModelItems).map { item in
            "- [\(priorityLabel(item.priority))] \(item.childName) : \(item.summary)"
        }
        let prompt = """
        Éléments du jour :
        \(lines.joined(separator: "\n"))
        Rédige le briefing.
        """
        #if canImport(FoundationModels)
        let text = await AsyncTimeout.run(modelTimeout) {
            await OnDeviceBriefingModel.respond(prompt: prompt)
        }
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isAcceptableBriefing(trimmed) ? trimmed : nil
        #else
        return nil
        #endif
    }

    private static let maxModelItems = 12
    private static let modelTimeout: Duration = .seconds(8)
    static let maxBriefingLength = 700

    private static func priorityLabel(_ priority: BriefingPriority) -> String {
        switch priority {
        case .urgent: "urgent"
        case .positive: "positif"
        case .normal: "normal"
        case .low: "secondaire"
        }
    }

    /// Model output check (pure): non-empty, short, and addressed to the
    /// parent (no tutoiement word, CLAUDE.md tone rule).
    static func isAcceptableBriefing(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maxBriefingLength else { return false }
        let words = Set(SubjectAlias.tokens(text))
        return words.isDisjoint(with: ["tu", "ton", "ta", "tes", "toi", "te"])
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
