import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "DailyCultureQuestion")

/// The culture question of the day on the child home (Gamification 3.6).
///
/// - Source: celyn's Keskonfé lot (`QuizAPIClient.cultureLot()`), a public,
///   culture-only, grade-free daily lot. The request carries nothing about
///   the child (only `app=keskonfe`); the answer is checked on device and
///   never sent.
/// - Reward: none. No minute, no XP, no `QuizAttempt`, no effect on the série
///   (decision: it is a curiosity card, the reward loop stays on programme
///   revision, and an unreviewed news-style question must never move the
///   cagnotte).
/// - Offline / 404 / unreadable lot: no card (nil), retried on a later
///   appearance. Cached for the device day once fetched.
struct DailyCultureQuestion: Codable, Sendable, Equatable {
    /// Device-local day the question was cached for (`CalendarDay.key`).
    let dayKey: String
    /// celyn lot date (Paris), the selection seed.
    let lotDate: String
    let quiz: CultureLotQuizDto
    /// The child's choice, nil until answered (feedback survives a relaunch).
    var answeredIndex: Int?

    var isAnswered: Bool { answeredIndex != nil }
    var answeredCorrectly: Bool { answeredIndex == quiz.answerIndex }
}

enum DailyCultureQuestionPicker {
    /// Keskonfé culture domains (celyn `KOI_DOMAINS`, `src/lib/koi/core.ts`).
    /// Anything else (news domains of other apps) is never shown to a child.
    static let cultureDomains: Set<String> = [
        "films", "series", "animes", "livres", "musique", "podcasts", "spectacles", "expos", "jeux",
    ]

    /// One question of `lot`, the same all day and on every device:
    /// 1. playable only: culture domain, 4 non-empty distinct choices,
    ///    `answerIndex` in range, `validUntil` (if any) not before the lot day;
    /// 2. evergreen tones first: `histoire` / `fun` / untagged; a `tone = actu`
    ///    question (dated culture news) only when nothing else is left;
    /// 3. sorted by id, index = SplitMix64(FNV-1a(lot date)) mod count.
    /// Nil when nothing is playable.
    static func pick(from lot: CultureLotResponse) -> CultureLotQuizDto? {
        let playable = lot.quizzes.filter { isPlayable($0, on: lot.date) }
        guard !playable.isEmpty else { return nil }
        let evergreen = playable.filter { $0.tone != "actu" }
        let pool = (evergreen.isEmpty ? playable : evergreen)
            .sorted { $0.id.uuidString < $1.id.uuidString }
        var rng = SplitMix64(seed: fnv1a(lot.date))
        return pool[Int(rng.next() % UInt64(pool.count))]
    }

    static func isPlayable(_ quiz: CultureLotQuizDto, on lotDate: String) -> Bool {
        let trimmed = quiz.choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cultureDomains.contains(quiz.domain),
              !quiz.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              trimmed.count == 4, !trimmed.contains(where: \.isEmpty),
              Set(trimmed.map { $0.lowercased() }).count == 4,
              trimmed.indices.contains(quiz.answerIndex) else { return false }
        // YYYY-MM-DD strings compare chronologically.
        if let validUntil = quiz.validUntil, validUntil < lotDate { return false }
        return true
    }

    /// 64-bit FNV-1a: stable across launches and platforms (unlike
    /// `Hasher`, which is seeded per process).
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return hash
    }
}

/// Day cache of the culture question in `UserDefaults` (non-personal: a
/// public question and the child's choice for it, overwritten every day).
@MainActor
final class DailyCultureQuestionStore {
    static let defaultsKey = "noto_child_culture_question_of_day"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The cached question when it was cached for `now`'s device day.
    func cached(now: Date, calendar: Calendar) -> DailyCultureQuestion? {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode(DailyCultureQuestion.self, from: data),
              stored.dayKey == CalendarDay(now, calendar: calendar).key else { return nil }
        return stored
    }

    func save(_ question: DailyCultureQuestion) {
        guard let data = try? JSONEncoder().encode(question) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Records the first choice only (feedback is immediate, like the quiz).
    /// Returns the updated question, nil when ignored.
    @discardableResult
    func recordAnswer(_ choice: Int, now: Date, calendar: Calendar) -> DailyCultureQuestion? {
        guard var question = cached(now: now, calendar: calendar), !question.isAnswered,
              question.quiz.choices.indices.contains(choice) else { return nil }
        question.answeredIndex = choice
        save(question)
        return question
    }

    /// Today's question: the cache, else one GET of the Keskonfé lot, picked
    /// and cached. Any failure (offline, 404, 401 on a key-less build,
    /// decoding) → nil, nothing cached, so a later appearance retries.
    func questionOfTheDay(client: QuizAPIClient, now: Date, calendar: Calendar) async -> DailyCultureQuestion? {
        if let cached = cached(now: now, calendar: calendar) { return cached }
        do {
            let lot = try await client.cultureLot()
            guard let quiz = DailyCultureQuestionPicker.pick(from: lot) else { return nil }
            let question = DailyCultureQuestion(dayKey: CalendarDay(now, calendar: calendar).key,
                                                lotDate: lot.date, quiz: quiz, answeredIndex: nil)
            save(question)
            return question
        } catch {
            logger.info("Culture question skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Culture question of the day: parent-controlled, OFF by default. It comes
/// from celyn's Keskonfé lot (films, séries, animes, jeux…), a general-audience
/// pool with no age or kid-safe flag, so it is not shown to a child until a
/// parent opts in (3.7 toggle) — or until celyn tags child-safe questions.
enum CultureQuestionSettings {
    static let enabledKey = "noto_culture_question_enabled"

    static func isEnabled(defaults: UserDefaults? = UserDefaults(suiteName: ScreenTimeEventStore.appGroupID)) -> Bool {
        defaults?.bool(forKey: enabledKey) ?? false
    }

    static func setEnabled(_ enabled: Bool,
                           defaults: UserDefaults? = UserDefaults(suiteName: ScreenTimeEventStore.appGroupID)) {
        defaults?.set(enabled, forKey: enabledKey)
    }
}

/// Weekly family challenge (plan §3.6): parent-controlled, OFF by default.
/// Stored in the app group so the parent toggle (3.7) and the child device
/// read the same flag. Nothing in this PR turns it on; when off, nothing is
/// shown and nothing is computed for it.
enum FamilyChallengeSettings {
    static let enabledKey = "noto_family_weekly_challenge_enabled"

    static func isEnabled(defaults: UserDefaults? = UserDefaults(suiteName: ScreenTimeEventStore.appGroupID)) -> Bool {
        defaults?.bool(forKey: enabledKey) ?? false
    }

    static func setEnabled(_ enabled: Bool,
                           defaults: UserDefaults? = UserDefaults(suiteName: ScreenTimeEventStore.appGroupID)) {
        defaults?.set(enabled, forKey: enabledKey)
    }

    /// Goal of the family challenge card: passed quizzes this week.
    static let weeklyGoal = 5
}
