import CryptoKit
import Foundation

// Sendable value types fed to the pure quiz services (`RewardPolicy`,
// `SpacedRepetition`, `QuizSourceSelector`, `ExamKeywordDetector`).
// `@Model` classes are not Sendable: snapshots are built on `@MainActor`
// from the models, handed to the pure functions, and results are written
// back on `@MainActor`. Never pass a model or a `ModelContext` across actors.

/// One homework row. `dedupKey` is computed once at init because connectors
/// recreate the rows on every sync (no stable row identity).
struct HomeworkSnapshot: Sendable, Equatable {
    let subject: String
    let descriptionText: String
    let dueDate: Date
    let done: Bool
    /// SHA256(fold(subject) + "|" + ymd(startOfDay(dueDate)) + "|" + fold(descriptionText)), hex.
    let dedupKey: String

    init(subject: String, descriptionText: String, dueDate: Date, done: Bool, calendar: Calendar) {
        self.subject = subject
        self.descriptionText = descriptionText
        self.dueDate = dueDate
        self.done = done
        let day = calendar.dateComponents([.year, .month, .day], from: calendar.startOfDay(for: dueDate))
        let ymd = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let raw = SubjectAlias.fold(subject) + "|" + ymd + "|" + SubjectAlias.fold(descriptionText)
        self.dedupKey = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ScheduleSnapshot: Sendable, Equatable {
    let subject: String
    let start: Date
    let end: Date
    let cancelled: Bool
    /// Pronote "devoir surveillé" flag. Not persisted on `ScheduleEntry` yet
    /// (needs Julien's go-ahead, design brief A.2 rule 6), so `false` today.
    let isTest: Bool
}

struct MasterySnapshot: Sendable, Equatable {
    let notionKey: String
    let leitnerBox: Int
    let nextReview: Date
    let streakCorrect: Int
    /// First time the notion reached a mastered box (`SpacedRepetition
    /// .isMastered`), never cleared by a later miss: the « thème maîtrisé »
    /// badge stays earned (3.6). Nil when never mastered, or mastered before
    /// the field existed.
    let masteredAt: Date?
    /// Mirrors `NotionMastery.lastReviewedAt` (parent Révisions screen and
    /// briefing, 3.7). Not carried by `SpacedRepetition.review`, which only
    /// schedules; `NotionMastery.apply` stamps it.
    let lastReviewedAt: Date?

    init(notionKey: String, leitnerBox: Int, nextReview: Date, streakCorrect: Int, masteredAt: Date? = nil,
         lastReviewedAt: Date? = nil) {
        self.notionKey = notionKey
        self.leitnerBox = leitnerBox
        self.nextReview = nextReview
        self.streakCorrect = streakCorrect
        self.masteredAt = masteredAt
        self.lastReviewedAt = lastReviewedAt
    }
}

struct AttemptSnapshot: Sendable, Equatable {
    let date: Date
    let questionKeys: [String]
    let correctCount: Int
    let totalCount: Int
    let durationSec: Int
    /// Base + bonus credited. Ignored for the attempt being scored.
    let minutesEarned: Int
    /// The attempt passed (a `RewardDecision.countsAsSuccess` outcome).
    let passed: Bool
    /// Mirrors `QuizAttempt.bonusApplied`: grants the exam-eve bonus at most
    /// once per day.
    let bonusApplied: Bool
    /// Mirrors `QuizAttempt.bonusMinutes`: the bonus part of `minutesEarned`,
    /// as credited. Keeps the daily cap on base minutes only, whatever the
    /// current `RewardConfig.examEveBonus`.
    let bonusMinutes: Int
    /// Mirrors `QuizAttempt.itemSubjects` / `itemXP` (3.6): subject ("" when
    /// none) and XP of each question, in play order. Empty before 3.6.
    let itemSubjects: [String]
    let itemXP: [Int]
    /// Mirrors `QuizAttempt.denialReason` (nil = credited, or unknown raw
    /// value). For the parent screens (3.7); `RewardPolicy` ignores it.
    let denial: RewardDenial?

    /// XP of the whole attempt (`Gamification`).
    var xpEarned: Int { itemXP.reduce(0) { $0 + max(0, $1) } }

    init(date: Date, questionKeys: [String], correctCount: Int, totalCount: Int,
         durationSec: Int, minutesEarned: Int = 0, passed: Bool = false, bonusApplied: Bool = false,
         bonusMinutes: Int = 0, itemSubjects: [String] = [], itemXP: [Int] = [],
         denial: RewardDenial? = nil) {
        self.date = date
        self.questionKeys = questionKeys
        self.correctCount = correctCount
        self.totalCount = totalCount
        self.durationSec = durationSec
        self.minutesEarned = minutesEarned
        self.passed = passed
        self.bonusApplied = bonusApplied
        self.bonusMinutes = bonusMinutes
        self.itemSubjects = itemSubjects
        self.itemXP = itemXP
        self.denial = denial
    }
}

struct ChildRevisionContext: Sendable, Equatable {
    /// Canonical level ("6e" … "Tle"; anything else is ineligible).
    let level: String
    /// Canonical spécialité names; empty = unknown → every spécialité eligible.
    let specialties: [String]
    /// Subject names or Pronote labels, weakest first.
    let weakSubjects: [String]
}

// MARK: - Calendar days

extension Calendar {
    /// Start of the calendar day `days` after the day of `date` (DST-safe:
    /// calendar arithmetic, never `+ 86 400 s`). Adding whole days to a
    /// start of day cannot fail in the Gregorian calendar, hence the unwrap.
    func quizStartOfDay(addingDays days: Int, to date: Date) -> Date {
        self.date(byAdding: .day, value: days, to: startOfDay(for: date))!
    }
}

// MARK: - Notion key

/// Shared key of a Leitner notion: "<level>|<subject>|<theme or notion>",
/// each part folded (case + diacritics) and trimmed, level canonicalised.
enum NotionKey {
    static func make(level: String, subject: String, theme: String) -> String {
        [CurriculumService.canonicalLevel(level), subject, theme]
            .map { SubjectAlias.fold($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "|")
    }
}

// MARK: - Curriculum lookup

/// What `QuizSourceSelector` needs from the curriculum. Sendable so plans can
/// be computed off the main actor.
protocol CurriculumLookup: Sendable {
    func themes(for level: String, subject: String, specialties: [String]?) -> [CurriculumTheme]
    func subjects(for level: String) -> [String]
    /// Themes grouped by the curriculum subject that owns them, for a
    /// (Pronote) label. The name is the owning subject's, never the alias:
    /// 6e « TECHNOLOGIE » resolves to « Sciences et technologie ».
    func subjectThemes(for level: String, subject: String,
                       specialties: [String]?) -> [(name: String, themes: [CurriculumTheme])]
}

/// Sendable curriculum view over already-decoded programs (`CurriculumProgram`
/// is Sendable). Delegates to a local `CurriculumService` so subject-alias
/// resolution and spécialité filtering stay in one place.
struct CurriculumSnapshot: CurriculumLookup {
    let programs: [CurriculumProgram]

    static var bundled: CurriculumSnapshot { CurriculumSnapshot(programs: CurriculumService.bundledPrograms) }

    func themes(for level: String, subject: String, specialties: [String]?) -> [CurriculumTheme] {
        CurriculumService(programs: programs).themes(for: level, subject: subject, specialties: specialties)
    }

    func subjects(for level: String) -> [String] {
        CurriculumService(programs: programs).subjects(for: level)
    }

    func subjectThemes(for level: String, subject: String,
                       specialties: [String]?) -> [(name: String, themes: [CurriculumTheme])] {
        CurriculumService(programs: programs)
            .matchingSubjects(for: level, subject: subject, specialties: specialties)
            .map { (name: $0.name, themes: $0.themes) }
    }
}

// MARK: - Model → snapshot (main actor)

extension HomeworkSnapshot {
    @MainActor init(_ homework: Homework, calendar: Calendar) {
        self.init(subject: homework.subject, descriptionText: homework.descriptionText,
                  dueDate: homework.dueDate, done: homework.done, calendar: calendar)
    }
}

extension ScheduleSnapshot {
    @MainActor init(_ entry: ScheduleEntry) {
        self.init(subject: entry.subject, start: entry.start, end: entry.end,
                  cancelled: entry.cancelled, isTest: false)
    }
}

extension MasterySnapshot {
    @MainActor init(_ mastery: NotionMastery) {
        self.init(notionKey: mastery.notionKey, leitnerBox: mastery.leitnerBox,
                  nextReview: mastery.nextReview, streakCorrect: mastery.streakCorrect,
                  masteredAt: mastery.masteredAt, lastReviewedAt: mastery.lastReviewedAt)
    }
}

extension AttemptSnapshot {
    /// `passed` is derived from the stored denial: success unless the attempt
    /// was denied for a reason that is not `countsAsSuccess`.
    @MainActor init(_ attempt: QuizAttempt) {
        let denial = attempt.denialReason.flatMap(RewardDenial.init(rawValue:))
        let passed = attempt.totalCount > 0 && (denial?.countsAsSuccess ?? true)
        self.init(date: attempt.date, questionKeys: attempt.questionKeys,
                  correctCount: attempt.correctCount, totalCount: attempt.totalCount,
                  durationSec: attempt.durationSec, minutesEarned: attempt.minutesEarned,
                  passed: passed, bonusApplied: attempt.bonusApplied,
                  bonusMinutes: attempt.bonusMinutes,
                  itemSubjects: attempt.itemSubjects, itemXP: attempt.itemXP, denial: denial)
    }
}

extension NotionMastery {
    /// Write a reviewed snapshot back (main actor, same context as the model).
    @MainActor func apply(_ snapshot: MasterySnapshot, reviewedAt: Date) {
        leitnerBox = snapshot.leitnerBox
        nextReview = snapshot.nextReview
        streakCorrect = snapshot.streakCorrect
        lastReviewedAt = reviewedAt
        // Stamped once, never cleared (a later miss keeps the badge).
        if masteredAt == nil {
            masteredAt = snapshot.masteredAt
                ?? (SpacedRepetition.isMastered(snapshot) ? reviewedAt : nil)
        }
    }
}
