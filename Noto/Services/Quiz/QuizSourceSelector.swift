import Foundation

/// One planned quiz slot: what to ask about, and why.
struct QuizPlanSlot: Sendable, Equatable {
    enum Origin: Sendable, Equatable {
        case homeworkTomorrow, homeworkToday, homeworkLater, dueNotion, programme
    }

    let origin: Origin
    /// Curriculum subject name when resolved, else the raw (Pronote) label.
    let subject: String
    /// Exact `CurriculumTheme.theme`; nil = no theme matched (bank fallback by subject).
    let theme: String?
    let keywords: [String]
    /// `HomeworkSnapshot.dedupKey` for homework slots.
    let homeworkKey: String?
    /// `NotionKey` of the slot's notion, when it has a theme.
    let notionKey: String?
}

struct QuizPlan: Sendable, Equatable {
    let slots: [QuizPlanSlot]
    /// False for levels outside the revisions path (primary school, unknown).
    let isEligible: Bool
}

/// Chooses what the next quiz is about. Pure and fully deterministic for a
/// given input (no randomness: shuffling happens at item draw, seeded).
///
/// Order: homework due within 72 h (tomorrow, then today, then later), then
/// due Leitner notions, then new programme material.
enum QuizSourceSelector {
    /// Homework window: today, tomorrow and the day after (< start of day + 3).
    static let homeworkWindowDays = 3

    static func plan(context: ChildRevisionContext, homework: [HomeworkSnapshot], masteries: [MasterySnapshot],
                     curriculum: some CurriculumLookup, now: Date, calendar: Calendar,
                     maxSlots: Int = 5, currentPeriod: String?) -> QuizPlan {
        // 1. Gate: collège + lycée only.
        let level = CurriculumService.canonicalLevel(context.level)
        guard CurriculumService.revisionLevels.contains(level) else {
            return QuizPlan(slots: [], isEligible: false)
        }

        var slots: [QuizPlanSlot] = []

        // 2–4. Homework due in the window, tomorrow first, deduplicated.
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.quizStartOfDay(addingDays: 1, to: now)
        let windowEnd = calendar.quizStartOfDay(addingDays: homeworkWindowDays, to: now)
        func rank(_ h: HomeworkSnapshot) -> Int {
            if calendar.isDate(h.dueDate, inSameDayAs: tomorrow) { return 0 }
            if calendar.isDate(h.dueDate, inSameDayAs: today) { return 1 }
            return 2
        }
        let inWindow = homework
            .filter { !$0.done && $0.dueDate >= today && $0.dueDate < windowEnd }
            .sorted { a, b in
                let (ra, rb) = (rank(a), rank(b))
                if ra != rb { return ra < rb }
                if a.dueDate != b.dueDate { return a.dueDate < b.dueDate }
                return a.dedupKey < b.dedupKey
            }
        var seenHomework = Set<String>()
        for h in inWindow where seenHomework.insert(h.dedupKey).inserted {
            let origin: QuizPlanSlot.Origin = switch rank(h) {
            case 0: .homeworkTomorrow
            case 1: .homeworkToday
            default: .homeworkLater
            }
            let match = bestMatch(text: h.descriptionText, level: level, subjectLabel: h.subject,
                                  specialties: context.specialties, curriculum: curriculum)
            slots.append(QuizPlanSlot(
                origin: origin,
                subject: match?.subject ?? displaySubject(h.subject),
                theme: match?.theme.theme,
                keywords: match?.theme.keywords ?? [],
                homeworkKey: h.dedupKey,
                notionKey: match.map { NotionKey.make(level: level, subject: $0.subject, theme: $0.theme.theme) }
            ))
        }

        // 5. Due notions, lowest box first, then oldest; skip those homework covers.
        let programme = programmeIndex(level: level, specialties: context.specialties, curriculum: curriculum)
        let covered = Set(slots.compactMap(\.notionKey))
        let due = masteries
            .filter { SpacedRepetition.isDue($0, now: now, calendar: calendar) && !covered.contains($0.notionKey) }
            .sorted { a, b in
                if a.leitnerBox != b.leitnerBox { return a.leitnerBox < b.leitnerBox }
                if a.nextReview != b.nextReview { return a.nextReview < b.nextReview }
                return a.notionKey < b.notionKey
            }
        for m in due {
            let entry = programme.first { $0.key == m.notionKey }
            let parts = m.notionKey.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            slots.append(QuizPlanSlot(
                origin: .dueNotion,
                subject: entry?.subject ?? (parts.count > 1 ? parts[1] : m.notionKey),
                theme: entry?.theme.theme ?? (parts.count > 2 ? parts[2] : nil),
                keywords: entry?.theme.keywords ?? [],
                homeworkKey: nil,
                notionKey: m.notionKey
            ))
        }

        // 6. Programme fill: weak subjects first, themes of the current period
        //    (or the whole year), new material only (no NotionMastery yet).
        //    Round-robin across subjects so one subject cannot fill the quiz.
        let known = Set(masteries.map(\.notionKey)).union(slots.compactMap(\.notionKey))
        let periodOK: (CurriculumTheme) -> Bool = { theme in
            guard let currentPeriod, let period = theme.period else { return true }
            return period == currentPeriod || period == "Année"
        }
        let weakRank = weakSubjectRank(context.weakSubjects)
        var queues: [[ProgrammeEntry]] = []
        for subject in orderedUnique(programme.map(\.subject)) {
            let queue = programme.filter { $0.subject == subject && periodOK($0.theme) && !known.contains($0.key) }
            if !queue.isEmpty { queues.append(queue) }
        }
        queues = queues.enumerated()
            .sorted { a, b in
                let (wa, wb) = (weakRank(a.element[0].subject), weakRank(b.element[0].subject))
                return wa != wb ? wa < wb : a.offset < b.offset
            }
            .map(\.element)
        var depth = 0
        while slots.count < maxSlots, queues.contains(where: { $0.count > depth }) {
            for queue in queues where queue.count > depth && slots.count < maxSlots {
                let entry = queue[depth]
                slots.append(QuizPlanSlot(origin: .programme, subject: entry.subject, theme: entry.theme.theme,
                                          keywords: entry.theme.keywords, homeworkKey: nil, notionKey: entry.key))
            }
            depth += 1
        }

        // 7. Size.
        return QuizPlan(slots: Array(slots.prefix(max(0, maxSlots))), isEligible: true)
    }

    /// Best curriculum theme for a homework / chapter text, scored like
    /// `CurriculumService.matchKeywords` (shared `themeScore`: +10 theme name,
    /// +3 per keyword, whole word under 4 chars). Ties keep curriculum order.
    static func bestTheme(text: String, level: String, subject: String, specialties: [String],
                          curriculum: some CurriculumLookup) -> (theme: CurriculumTheme, score: Int)? {
        bestMatch(text: text, level: level, subjectLabel: subject, specialties: specialties, curriculum: curriculum)
            .map { ($0.theme, $0.score) }
    }

    // MARK: - Helpers

    private struct ProgrammeEntry {
        let subject: String
        let theme: CurriculumTheme
        let key: String
    }

    private struct Match {
        let subject: String
        let theme: CurriculumTheme
        let score: Int
    }

    /// Resolves the label through `CurriculumLookup.subjectThemes` (alias
    /// table, then label matching) and keeps the name of the subject that owns
    /// each theme ("HISTOIRE-GEOGRAPHIE" → Histoire or Géographie; 6e
    /// "TECHNOLOGIE" → Sciences et technologie), so homework slots share their
    /// notion key with the programme.
    private static func bestMatch(text: String, level: String, subjectLabel: String, specialties: [String],
                                  curriculum: some CurriculumLookup) -> Match? {
        let folded = SubjectAlias.fold(text)
        var best: Match?
        for candidate in curriculum.subjectThemes(for: level, subject: subjectLabel, specialties: specialties) {
            for theme in candidate.themes {
                let score = CurriculumService.themeScore(foldedText: folded, theme: theme)
                if score > (best?.score ?? 0) {
                    best = Match(subject: candidate.name, theme: theme, score: score)
                }
            }
        }
        return best
    }

    /// The single canonical name of a label, else the label itself.
    private static func displaySubject(_ label: String) -> String {
        let names = SubjectAlias.canonicalNames(for: label)
        return names.count == 1 ? names[0] : label
    }

    /// Every theme of the level, in curriculum order, with its notion key.
    private static func programmeIndex(level: String, specialties: [String],
                                       curriculum: some CurriculumLookup) -> [ProgrammeEntry] {
        orderedUnique(curriculum.subjects(for: level)).flatMap { subject in
            curriculum.themes(for: level, subject: subject, specialties: specialties).map {
                ProgrammeEntry(subject: subject, theme: $0,
                               key: NotionKey.make(level: level, subject: subject, theme: $0.theme))
            }
        }
    }

    /// Position of a subject in the weak list (labels or canonical names);
    /// `Int.max` for subjects that are not weak.
    private static func weakSubjectRank(_ weakSubjects: [String]) -> (String) -> Int {
        let keys = weakSubjects.map { weak in
            Set([SubjectAlias.compact(weak)] + SubjectAlias.canonicalNames(for: weak).map(SubjectAlias.compact))
        }
        return { subject in
            let compact = SubjectAlias.compact(subject)
            return keys.firstIndex { $0.contains(compact) } ?? Int.max
        }
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
