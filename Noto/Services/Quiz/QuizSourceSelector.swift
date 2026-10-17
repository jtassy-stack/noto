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

    /// Homework slot (due within the 72 h window), the only kind 3.3 may
    /// fill with an on-device generated question.
    var isHomework: Bool {
        switch origin {
        case .homeworkTomorrow, .homeworkToday, .homeworkLater: true
        case .dueNotion, .programme: false
        }
    }
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
///
/// Programme material (3.8): for a subject with a `ProgrammePosition`, only
/// themes already seen in the cahier de textes / homework (current first,
/// then covered) — never a theme not taught yet. A subject without a
/// position falls back to the official calendar (`PeriodRank`: the current
/// period and every earlier one).
enum QuizSourceSelector {
    /// Homework window: today, tomorrow and the day after (< start of day + 3).
    static let homeworkWindowDays = 3

    static func plan(context: ChildRevisionContext, homework: [HomeworkSnapshot], masteries: [MasterySnapshot],
                     curriculum: some CurriculumLookup, now: Date, calendar: Calendar,
                     maxSlots: Int = 5, currentPeriod: String?,
                     position: ProgrammePosition = .empty) -> QuizPlan {
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

        // 6. Programme fill: weak subjects first, new material only (no
        //    NotionMastery yet). Round-robin across subjects so one subject
        //    cannot fill the quiz.
        //    - Subject with a position: its seen themes only (current by
        //      weight, then covered by lastSeen), period ignored. Covered
        //      themes already played come back through step 5.
        //    - Subject without one: `PeriodRank` (current + earlier periods,
        //      "Année" / undated always), curriculum order.
        let known = Set(masteries.map(\.notionKey)).union(slots.compactMap(\.notionKey))
        let weakRank = weakSubjectRank(context.weakSubjects)
        var queues: [(queue: [ProgrammeEntry], confident: Bool)] = []
        for subject in orderedUnique(programme.map(\.subject)) {
            let entries = programme.filter { $0.subject == subject && !known.contains($0.key) }
            let queue: [ProgrammeEntry]
            let subjectPosition = position.subjects[SubjectAlias.fold(subject)]
            if let subjectPosition {
                let rank = Dictionary(subjectPosition.all.map(\.notionKey).enumerated().map { ($1, $0) },
                                      uniquingKeysWith: { first, _ in first })
                queue = entries
                    .filter { rank[$0.key] != nil }
                    .sorted { rank[$0.key]! < rank[$1.key]! }
            } else {
                queue = entries.filter { PeriodRank.isEligible($0.theme.period, current: currentPeriod) }
            }
            if !queue.isEmpty {
                queues.append((queue, (subjectPosition?.confidence ?? .low) >= .medium))
            }
        }
        // Weak rank, then subjects with a position of at least medium
        // confidence, then curriculum order (kept instead of the subject name
        // so an empty position plans exactly like before 3.8).
        queues = queues.enumerated()
            .sorted { a, b in
                let (wa, wb) = (weakRank(a.element.queue[0].subject), weakRank(b.element.queue[0].subject))
                if wa != wb { return wa < wb }
                if a.element.confident != b.element.confident { return a.element.confident }
                return a.offset < b.offset
            }
            .map(\.element)
        var depth = 0
        while slots.count < maxSlots, queues.contains(where: { $0.queue.count > depth }) {
            for (queue, _) in queues where queue.count > depth && slots.count < maxSlots {
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

    /// Shared predicate "may a quiz ask about (subject, theme)?" for the
    /// programme part (also `QuizSession`'s top-up). `subject` is a bank or
    /// connector label, resolved through `CurriculumLookup.subjectThemes`.
    /// - The owning subject has a position: only its seen themes (`current ∪
    ///   covered`); a nil theme is refused (it cannot be shown to be seen).
    /// - No position: `PeriodRank.isEligible(theme.period, currentPeriod)`.
    /// - Label or theme unknown to the curriculum: accepted only when no
    ///   matching subject has a position.
    static func programmeEligibility(level rawLevel: String, position: ProgrammePosition, currentPeriod: String?,
                                     curriculum: some CurriculumLookup, specialties: [String])
        -> (_ subject: String, _ theme: String?) -> Bool {
        let level = CurriculumService.canonicalLevel(rawLevel)
        var cache: [String: [(name: String, themes: [CurriculumTheme])]] = [:]
        let lookup = curriculum
        return { subject, theme in
            let candidates: [(name: String, themes: [CurriculumTheme])]
            if let cached = cache[subject] {
                candidates = cached
            } else {
                candidates = lookup.subjectThemes(for: level, subject: subject, specialties: specialties)
                cache[subject] = candidates
            }
            let positioned = candidates.filter { position.subjects[SubjectAlias.fold($0.name)] != nil }
            guard let theme, !theme.isEmpty else { return positioned.isEmpty }
            let foldedTheme = SubjectAlias.fold(theme)
            for candidate in candidates {
                guard let owned = candidate.themes.first(where: { SubjectAlias.fold($0.theme) == foldedTheme })
                else { continue }
                if let keys = position.eligibleKeys(forSubject: SubjectAlias.fold(candidate.name)) {
                    if keys.contains(NotionKey.make(level: level, subject: candidate.name, theme: owned.theme)) {
                        return true
                    }
                } else if PeriodRank.isEligible(owned.period, current: currentPeriod) {
                    return true
                }
            }
            // Theme found nowhere eligible; unknown themes pass only without a position.
            let known = candidates.contains { c in c.themes.contains { SubjectAlias.fold($0.theme) == foldedTheme } }
            return !known && positioned.isEmpty
        }
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
