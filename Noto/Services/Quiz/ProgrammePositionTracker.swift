import Foundation

/// Where a child is in the programme, per curriculum subject: the theme(s)
/// being taught now and the themes already seen, inferred from what teachers
/// wrote in the cahier de textes and from homework (Phase 3.8).
///
/// Computed on demand on the device, never persisted, never sent anywhere.
struct ProgrammePosition: Sendable, Equatable {
    enum Confidence: Int, Sendable, Comparable {
        case low, medium, high

        static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }

        /// One level down (stale evidence), floored at `.low`.
        var downgraded: Confidence { Confidence(rawValue: max(0, rawValue - 1)) ?? .low }
    }

    struct Sighting: Sendable, Equatable {
        /// `NotionKey.make(level, curriculumSubject, theme)`.
        let notionKey: String
        /// Curriculum subject name (display).
        let subject: String
        let theme: String
        let firstSeen: Date
        let lastSeen: Date
        let count: Int
        /// Recency-weighted sum of the accepted evidence scores.
        let weight: Double
    }

    struct SubjectPosition: Sendable, Equatable {
        /// Curriculum subject name.
        let subject: String
        /// 1 to 2 themes, weight-desc.
        let current: [Sighting]
        /// The others, lastSeen-desc.
        let covered: [Sighting]
        let confidence: Confidence
        let lastEvidence: Date

        var all: [Sighting] { current + covered }
    }

    /// Key: `SubjectAlias.fold(curriculum subject name)`.
    let subjects: [String: SubjectPosition]
    /// Raw labels that matched no curriculum subject (display + debug).
    let unmatchedSubjects: [String]

    static let empty = ProgrammePosition(subjects: [:], unmatchedSubjects: [])

    /// Every eligible NotionKey (current ∪ covered) of a subject that has a
    /// position; nil = no position for that subject.
    func eligibleKeys(forSubject folded: String) -> Set<String>? {
        subjects[folded].map { Set($0.all.map(\.notionKey)) }
    }

    func position(forSubject name: String) -> SubjectPosition? {
        subjects[SubjectAlias.fold(name)]
    }

    var hasAny: Bool { !subjects.isEmpty }

    /// Subject positions in a stable display order (subject name).
    var orderedSubjects: [SubjectPosition] {
        subjects.values.sorted { $0.subject.localizedStandardCompare($1.subject) == .orderedAscending }
    }
}

/// Pure: snapshots in, value out. No I/O, no model access, deterministic.
enum ProgrammePositionTracker {
    /// Minimum score for one piece of evidence (two keywords), or any theme-name hit (+10).
    static let minScore = 6
    static let halfLifeDays = 14.0
    /// Future-dated homework counts (as "today"), capped at this horizon.
    static let futureHorizonDays = 14
    /// Evidence older than this is ignored (same window as the fetch).
    static let lookbackDays = 42
    /// A subject with no evidence for this long is downgraded one level (holidays).
    static let staleDays = 21
    /// Score of a teacher-tagged Pronote theme matching a curriculum theme.
    static let teacherTagScore = 20
    /// Lesson sources weigh more than homework (direct evidence of teaching).
    static let lessonMultiplier = 1.5
    /// A second theme is "current" too when its weight reaches this share of the top one.
    static let parallelShare = 0.6

    private struct Evidence {
        let label: String
        let date: Date
        let foldedText: String
        let tags: [String]
        let isLesson: Bool
    }

    private struct Accumulator {
        let notionKey: String
        let subject: String
        let theme: String
        let order: Int
        var firstSeen: Date
        var lastSeen: Date
        var count: Int
        var weight: Double
        var strong: Bool

        var sighting: ProgrammePosition.Sighting {
            .init(notionKey: notionKey, subject: subject, theme: theme, firstSeen: firstSeen, lastSeen: lastSeen,
                  count: count, weight: weight)
        }
    }

    private struct SubjectAccumulator {
        var name: String
        var evidenceCount = 0
        var days = Set<Date>()
        var sightings: [String: Accumulator] = [:]
    }

    static func compute(level rawLevel: String, specialties: [String],
                        lessons: [LessonContentSnapshot], homework: [HomeworkSnapshot],
                        curriculum: some CurriculumLookup, now: Date, calendar: Calendar) -> ProgrammePosition {
        let level = CurriculumService.canonicalLevel(rawLevel)
        guard CurriculumService.revisionLevels.contains(level) else { return .empty }

        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -lookbackDays, to: today) ?? today
        let windowEnd = calendar.date(byAdding: .day, value: futureHorizonDays + 1, to: today) ?? today
        func inWindow(_ date: Date) -> Bool { date >= windowStart && date < windowEnd }

        // 2. Evidence. Homework also stored as a `.homework` row counts once.
        var evidence: [Evidence] = []
        var storedHomeworkKeys = Set<String>()
        for lesson in lessons where inWindow(lesson.date) {
            let body = LessonDedupKey.body(title: lesson.title, text: lesson.text)
            guard !body.isEmpty || !lesson.themes.isEmpty else { continue }
            if lesson.source == .homework {
                storedHomeworkKeys.insert(LessonDedupKey.make(subject: lesson.subject, date: lesson.date,
                                                              text: body, calendar: calendar))
            }
            evidence.append(Evidence(label: lesson.subject, date: lesson.date, foldedText: SubjectAlias.fold(body),
                                     tags: lesson.themes, isLesson: lesson.source.isLesson))
        }
        for h in homework where inWindow(h.dueDate) {
            let body = LessonDedupKey.body(title: "", text: h.descriptionText)
            guard !body.isEmpty else { continue }
            let key = LessonDedupKey.make(subject: h.subject, date: h.dueDate, text: body, calendar: calendar)
            guard !storedHomeworkKeys.contains(key) else { continue }
            storedHomeworkKeys.insert(key)
            evidence.append(Evidence(label: h.subject, date: h.dueDate, foldedText: SubjectAlias.fold(body),
                                     tags: [], isLesson: false))
        }

        // 3–6. Subject, best theme, weight, aggregation.
        var resolved: [String: [(name: String, themes: [CurriculumTheme])]] = [:]
        var unmatched = Set<String>()
        var bySubject: [String: SubjectAccumulator] = [:]

        for e in evidence {
            let candidates: [(name: String, themes: [CurriculumTheme])]
            if let cached = resolved[e.label] {
                candidates = cached
            } else {
                candidates = curriculum.subjectThemes(for: level, subject: e.label, specialties: specialties)
                resolved[e.label] = candidates
            }
            guard !candidates.isEmpty else {
                unmatched.insert(e.label)
                continue
            }

            var best: (name: String, theme: CurriculumTheme, order: Int, score: Int, tagged: Bool)?
            for candidate in candidates {
                for (index, theme) in candidate.themes.enumerated() {
                    let tagged = e.tags.contains { tagMatches($0, theme: theme.theme) }
                    let score = tagged ? teacherTagScore : CurriculumService.themeScore(foldedText: e.foldedText,
                                                                                         theme: theme)
                    if score > (best?.score ?? 0) {
                        best = (candidate.name, theme, index, score, tagged)
                    }
                }
            }
            guard let best, best.score >= minScore || best.score >= 10 else { continue }

            let daysAgo = max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: e.date),
                                                         to: today).day ?? 0)
            var w = Double(best.score) * pow(0.5, Double(daysAgo) / halfLifeDays)
            if e.isLesson { w *= lessonMultiplier }

            let subjectKey = SubjectAlias.fold(best.name)
            let notionKey = NotionKey.make(level: level, subject: best.name, theme: best.theme.theme)
            var subject = bySubject[subjectKey] ?? SubjectAccumulator(name: best.name)
            subject.evidenceCount += 1
            subject.days.insert(calendar.startOfDay(for: e.date))
            if var acc = subject.sightings[notionKey] {
                acc.firstSeen = min(acc.firstSeen, e.date)
                acc.lastSeen = max(acc.lastSeen, e.date)
                acc.count += 1
                acc.weight += w
                acc.strong = acc.strong || e.isLesson || best.tagged
                subject.sightings[notionKey] = acc
            } else {
                subject.sightings[notionKey] = Accumulator(
                    notionKey: notionKey, subject: best.name, theme: best.theme.theme, order: best.order,
                    firstSeen: e.date, lastSeen: e.date, count: 1, weight: w, strong: e.isLesson || best.tagged)
            }
            bySubject[subjectKey] = subject
        }

        // 7–9. Per subject: current / covered, confidence, deterministic order.
        let staleLimit = calendar.date(byAdding: .day, value: -staleDays, to: today) ?? today
        var subjects: [String: ProgrammePosition.SubjectPosition] = [:]
        for (key, subject) in bySubject {
            let byWeight = subject.sightings.values.sorted { a, b in
                if a.weight != b.weight { return a.weight > b.weight }
                if a.order != b.order { return a.order < b.order }
                return a.notionKey < b.notionKey
            }
            guard let top = byWeight.first else { continue }
            var current = [top]
            if byWeight.count > 1, byWeight[1].weight >= parallelShare * top.weight {
                current.append(byWeight[1])
            }
            let currentKeys = Set(current.map(\.notionKey))
            let covered = byWeight
                .filter { !currentKeys.contains($0.notionKey) }
                .sorted { a, b in
                    if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
                    if a.weight != b.weight { return a.weight > b.weight }
                    if a.order != b.order { return a.order < b.order }
                    return a.notionKey < b.notionKey
                }
            let lastEvidence = byWeight.map(\.lastSeen).max() ?? top.lastSeen

            var confidence: ProgrammePosition.Confidence
            if subject.evidenceCount >= 3, subject.days.count >= 2, top.strong {
                confidence = .high
            } else if subject.evidenceCount >= 2 {
                confidence = .medium
            } else {
                confidence = .low
            }
            if lastEvidence < staleLimit { confidence = confidence.downgraded }

            subjects[key] = ProgrammePosition.SubjectPosition(
                subject: subject.name, current: current.map(\.sighting), covered: covered.map(\.sighting),
                confidence: confidence, lastEvidence: lastEvidence)
        }

        return ProgrammePosition(subjects: subjects, unmatchedSubjects: unmatched.sorted())
    }

    /// A teacher tag designates a curriculum theme when the folded strings are
    /// equal, or when the theme name contains the tag as whole words (tag of
    /// at least 4 characters, so « Le » or « XIX » never match).
    static func tagMatches(_ tag: String, theme: String) -> Bool {
        let foldedTag = SubjectAlias.fold(tag).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !foldedTag.isEmpty else { return false }
        if foldedTag == SubjectAlias.fold(theme).trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        guard SubjectAlias.compact(tag).count >= 4 else { return false }
        return CurriculumService.containsSequence(SubjectAlias.tokens(theme), SubjectAlias.tokens(tag))
    }
}

// MARK: - Period rank (fallback when a subject has no position)

/// Curriculum periods as comparable ranks, so a current period admits the
/// themes of earlier periods too (a T1 theme stays revisable in T2).
enum PeriodRank {
    /// "Trimestre 1/2/3" → 1/2/3; "Semestre 1" → 2, "Semestre 2" → 3;
    /// "Année" / nil / anything else → 0 (always eligible).
    static func rank(_ period: String?) -> Int {
        guard let period else { return 0 }
        let tokens = SubjectAlias.tokens(period)
        guard tokens.count == 2, let n = Int(tokens[1]) else { return 0 }
        switch tokens[0] {
        case "trimestre" where (1...3).contains(n): return n
        case "semestre" where n == 1: return 2
        case "semestre" where n == 2: return 3
        default: return 0
        }
    }

    /// Sept–Dec → T1, Jan–Mar → T2, Apr–Aug → T3 (Europe/Paris).
    /// For "Tle": "Semestre 1" until 31 Jan, then "Semestre 2".
    static func currentPeriod(now: Date, level: String, calendar: Calendar) -> String {
        var paris = calendar
        paris.timeZone = TimeZone(identifier: "Europe/Paris") ?? calendar.timeZone
        let month = paris.component(.month, from: now)
        if CurriculumService.canonicalLevel(level) == "Tle" {
            return (month >= 9 || month == 1) ? "Semestre 1" : "Semestre 2"
        }
        switch month {
        case 9...12: return "Trimestre 1"
        case 1...3: return "Trimestre 2"
        default: return "Trimestre 3"
        }
    }

    /// `current == nil` → true; otherwise `rank(theme) == 0 || rank(theme) <= rank(current)`.
    static func isEligible(_ themePeriod: String?, current: String?) -> Bool {
        guard let current else { return true }
        let r = rank(themePeriod)
        return r == 0 || r <= rank(current)
    }
}
