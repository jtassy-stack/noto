import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pmf.noto", category: "CultureQuizPool")

/// Culture G quiz for parents and children, fed by every question celyn's
/// « Koi ? » engine generates (Keskonfé, Sirius, Le Club lots).
///
/// - Source: `GET /api/quiz/v2/lot?app=<app>[&date=]` for each app of
///   `QuizAPIClient.cultureLotApps`, today and a backfill window of past lots,
///   accumulated in a local pool (`CultureQuizPoolStore`) so the quiz goes
///   beyond one day's 8 questions and, over time, through the whole Koi output.
///   Requests carry only `app` and a public date, never anything about the
///   family; answers are checked on device and never sent.
/// - Audience: the parent gets every question still valid; the child only the
///   ones `CultureQuizFilter.isAppropriate` keeps (culture / sport / sciences
///   domains, evergreen tones, difficulty for collège, on-device text filter).
/// - Reward: none, like the culture question of the day. No minute, no XP, no
///   `QuizAttempt`: the reward loop stays on programme revision.
enum CultureQuizAudience: Sendable, Equatable, Hashable {
    case parent
    /// `level`: canonical nōto level (`6e` … `Tle`), nil when unknown
    /// (treated as collège, the stricter difficulty cap).
    case child(level: String?)

    var isChild: Bool {
        if case .child = self { return true }
        return false
    }
}

/// One Koi question kept in the local pool, with the lot it came from.
struct CultureQuizEntry: Codable, Sendable, Equatable, Identifiable {
    let quiz: CultureLotQuizDto
    /// keskonfe | sirius | leclub
    let app: String
    /// YYYY-MM-DD (Paris day of the lot).
    let lotDate: String

    var id: UUID { quiz.id }
}

enum CultureQuizFilter {
    /// Domains a child may get: Keskonfé's culture domains plus the news
    /// domains with no adult-only subject matter. Politique, international,
    /// société, économie and santé stay parent-only.
    static let childDomains: Set<String> = DailyCultureQuestionPicker.cultureDomains
        .union(["sport", "sciences_tech", "environnement", "culture"])

    /// Levels where every difficulty is allowed; below (collège, or unknown),
    /// difficulty 3 is left out.
    static let lyceeLevels: Set<String> = ["2nde", "1re", "Tle"]

    /// Days an `actu` question without `validUntil` stays playable after its
    /// lot (contract §2: horizon `jour` = 3 days).
    static let actuDefaultDays = 3

    /// 4 non-empty distinct choices, a question, `answerIndex` in range.
    static func isWellFormed(_ quiz: CultureLotQuizDto) -> Bool {
        let trimmed = quiz.choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return !quiz.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && trimmed.count == 4 && !trimmed.contains(where: \.isEmpty)
            && Set(trimmed.map { $0.lowercased() }).count == 4
            && trimmed.indices.contains(quiz.answerIndex)
    }

    /// Well formed and not out of date on `today` (YYYY-MM-DD): past its
    /// `validUntil`, or an `actu` question without one older than
    /// `actuDefaultDays`.
    static func isPlayable(_ entry: CultureQuizEntry, today: String, calendar: Calendar) -> Bool {
        guard isWellFormed(entry.quiz) else { return false }
        // YYYY-MM-DD strings compare chronologically.
        if let validUntil = entry.quiz.validUntil { return validUntil >= today }
        if entry.quiz.tone == "actu" || entry.quiz.kind == "actu" {
            guard let lotDay = CalendarDay(key: entry.lotDate) else { return false }
            return lotDay.adding(days: actuDefaultDays, calendar: calendar).key >= today
        }
        return true
    }

    /// The parent gets everything; the child only:
    /// 1. a child domain (`childDomains`);
    /// 2. an evergreen question (`tone` histoire / fun / untagged, never
    ///    `actu`: news is dated and written for adults);
    /// 3. difficulty 1-2 in collège (any in lycée);
    /// 4. text that passes `ChildSafeText` (question, choices, explanation, œuvre).
    static func isAppropriate(_ quiz: CultureLotQuizDto, for audience: CultureQuizAudience) -> Bool {
        guard case .child(let level) = audience else { return true }
        guard childDomains.contains(quiz.domain),
              quiz.tone != "actu", quiz.kind != "actu" else { return false }
        let isLycee = level.map { lyceeLevels.contains($0) } ?? false
        if !isLycee && quiz.difficulty > 2 { return false }
        let texts = [quiz.question, quiz.explanation ?? "", quiz.oeuvreTitle ?? ""] + quiz.choices
        return texts.allSatisfy(ChildSafeText.isSafe)
    }
}

/// On-device text filter for the child quiz, on top of the checks celyn runs
/// at generation (`isSensitiveText`: obituaries, victims, disasters,
/// violence). Conservative on purpose: losing a fine question is cheap,
/// showing a child an unsuitable one is not. Matches whole words on a
/// lowercased, accent-folded text (« Érotique » → « erotique »).
enum ChildSafeText {
    static let patterns: [String] = [
        // Sexual content.
        "sexe?s?", "sexuel\\p{L}*", "porno\\p{L}*", "erotique?s?", "prostitu\\p{L}*", "viols?", "violee?s?",
        "incestes?", "pedophil\\p{L}*", "pedocrimin\\p{L}*", "strip-?tease\\p{L}*", "libertin\\p{L}*",
        // Drugs and alcohol.
        "drogue?s?", "cocaine", "heroinomanes?", "cannabis", "haschi?ch", "ecstasy", "mdma", "lsd",
        "overdoses?", "dealers?", "stupefiants?", "alcool\\p{L}*",
        // Self-harm.
        "suicid\\p{L}*", "automutilations?", "scarifications?",
        // Violence, crime, death.
        "meurtr\\p{L}*", "assassin\\p{L}*", "tueur\\p{L}*", "tueuse?s?", "massacres?", "attentats?",
        "terroris\\p{L}*", "tortur\\p{L}*", "egorg\\p{L}*", "decapit\\p{L}*", "cadavres?", "genocides?",
        "serial killer\\p{L}*",
        // Horror.
        "horreur", "epouvante", "gore", "slashers?",
    ]

    nonisolated(unsafe) private static let regex: NSRegularExpression = {
        let alternation = patterns.joined(separator: "|")
        // Whole words: no letter or digit on either side.
        let pattern = "(?<![\\p{L}\\p{N}])(?:\(alternation))(?![\\p{L}\\p{N}])"
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "fr_FR"))
    }

    static func isSafe(_ text: String) -> Bool {
        let folded = fold(text)
        return regex.firstMatch(in: folded, range: NSRange(folded.startIndex..., in: folded)) == nil
    }
}

// MARK: - Draw

enum CultureQuizDraw {
    /// Questions per culture G session.
    static let questionCount = 10

    /// Up to `count` questions for `audience`: playable and appropriate,
    /// never two with the same text, questions not yet `seen` first, apps
    /// interleaved (Keskonfé, Sirius, Le Club…) so one session mixes œuvres,
    /// culture G and sport. Once every question was seen, seen ones refill.
    static func draw<G: RandomNumberGenerator>(
        from pool: [CultureQuizEntry],
        audience: CultureQuizAudience,
        seen: Set<UUID>,
        today: String,
        calendar: Calendar,
        count: Int = questionCount,
        using rng: inout G
    ) -> [CultureLotQuizDto] {
        var texts = Set<String>()
        let eligible = pool
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .filter { CultureQuizFilter.isPlayable($0, today: today, calendar: calendar)
                && CultureQuizFilter.isAppropriate($0.quiz, for: audience) }
            .filter { texts.insert(ChildSafeText.fold($0.quiz.question)).inserted }

        let fresh = eligible.filter { !seen.contains($0.id) }
        let stale = eligible.filter { seen.contains($0.id) }
        var picked = interleaved(fresh, using: &rng)
        if picked.count < count {
            picked += interleaved(stale, using: &rng)
        }
        return Array(picked.prefix(count)).map(\.quiz)
    }

    /// Shuffles each app's questions, then takes them round-robin across
    /// apps in a shuffled app order.
    private static func interleaved<G: RandomNumberGenerator>(
        _ entries: [CultureQuizEntry], using rng: inout G
    ) -> [CultureQuizEntry] {
        let byApp = Dictionary(grouping: entries, by: \.app).mapValues { $0.shuffled(using: &rng) }
        let apps = byApp.keys.sorted().shuffled(using: &rng)
        var result: [CultureQuizEntry] = []
        var round = 0
        while result.count < entries.count {
            for app in apps {
                if let list = byApp[app], round < list.count { result.append(list[round]) }
            }
            round += 1
        }
        return result
    }
}

// MARK: - Seen questions

/// Ids of the culture questions already played, per audience, so successive
/// sessions walk through the whole pool before repeating. Non-personal
/// (public question ids), capped, in `UserDefaults`.
@MainActor
final class CultureQuizSeenStore {
    static let maxCount = 3000

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(for audience: CultureQuizAudience) -> String {
        audience.isChild ? "noto_culture_quiz_seen_child" : "noto_culture_quiz_seen_parent"
    }

    func seen(for audience: CultureQuizAudience) -> Set<UUID> {
        Set(orderedIDs(for: audience).compactMap(UUID.init(uuidString:)))
    }

    func markSeen(_ ids: [UUID], for audience: CultureQuizAudience) {
        var ordered = orderedIDs(for: audience)
        let added = ids.map(\.uuidString).filter { !ordered.contains($0) }
        ordered.append(contentsOf: added)
        if ordered.count > Self.maxCount { ordered.removeFirst(ordered.count - Self.maxCount) }
        defaults.set(ordered, forKey: Self.key(for: audience))
    }

    private func orderedIDs(for audience: CultureQuizAudience) -> [String] {
        defaults.stringArray(forKey: Self.key(for: audience)) ?? []
    }
}

// MARK: - Local pool

/// Local pool of Koi questions (public content, no personal data), a JSON
/// file in Application Support. `refresh` adds today's lot of each app and
/// backfills `backfillDays` past lots once, then prunes out-of-date and old
/// questions.
@MainActor
final class CultureQuizPoolStore {
    static let fileName = "culture-quiz-pool.json"
    /// Past lots fetched per app on first use (and kept filled day after day).
    static let backfillDays = 14
    /// Questions older than this are dropped from the pool.
    static let retentionDays = 365
    /// Today's lots are fetched again after this delay (Sirius publishes
    /// editions at 07:00, 12:00 and 20:00).
    static let todayRefreshInterval: TimeInterval = 3 * 3600

    struct Snapshot: Codable, Sendable, Equatable {
        var entries: [CultureQuizEntry] = []
        /// `app|YYYY-MM-DD` of past lots already fetched (or answered 404).
        var fetchedDays: Set<String> = []
        /// Last successful fetch of today's lot, per app.
        var todayFetchedAt: [String: Date] = [:]
    }

    private let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent(Self.fileName)
    }

    func load() -> Snapshot {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return Snapshot() }
        return snapshot
    }

    func save(_ snapshot: Snapshot) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
        } catch {
            logger.error("Culture pool not saved: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetches what is missing (today's lots when stale, past lots never
    /// fetched), merges, prunes, saves, and returns the pool. Sequential GETs;
    /// the first transport, auth or rate-limit error stops the round (what
    /// was fetched is kept, the rest is retried on a later call).
    @discardableResult
    func refresh(client: QuizAPIClient, now: Date, calendar: Calendar) async -> [CultureQuizEntry] {
        var snapshot = load()
        let today = CalendarDay(now, calendar: calendar)

        // Today's lots first (the freshest questions, a playable pool fast),
        // then the past lots never fetched.
        var requests: [(app: String, date: String?)] = QuizAPIClient.cultureLotApps
            .filter { app in
                snapshot.todayFetchedAt[app].map { now.timeIntervalSince($0) >= Self.todayRefreshInterval } ?? true
            }
            .map { (app: $0, date: String?.none) }
        for app in QuizAPIClient.cultureLotApps {
            for offset in 1...Self.backfillDays {
                let day = today.adding(days: -offset, calendar: calendar).key
                if !snapshot.fetchedDays.contains("\(app)|\(day)") { requests.append((app: app, date: day)) }
            }
        }

        for request in requests {
            let outcome = await fetch(client: client, app: request.app, date: request.date)
            if case .stop = outcome { break }
            if case .lot(let lot) = outcome { Self.merge(lot, app: request.app, into: &snapshot) }
            if let date = request.date {
                snapshot.fetchedDays.insert("\(request.app)|\(date)")
            } else {
                snapshot.todayFetchedAt[request.app] = now
            }
        }

        Self.prune(&snapshot, today: today, calendar: calendar)
        save(snapshot)
        return snapshot.entries
    }

    private enum FetchOutcome { case lot(CultureLotResponse), missing, stop }

    private func fetch(client: QuizAPIClient, app: String, date: String?) async -> FetchOutcome {
        do {
            return .lot(try await client.cultureLot(app: app, date: date))
        } catch QuizAPIError.notFound {
            return .missing
        } catch QuizAPIError.decoding, QuizAPIError.badRequest {
            // An unreadable lot will not get better on retry.
            return .missing
        } catch {
            logger.info("Culture pool fetch stopped: \(error.localizedDescription, privacy: .public)")
            return .stop
        }
    }

    /// Adds the lot's quizzes; a known id is replaced (celyn may have
    /// updated it).
    static func merge(_ lot: CultureLotResponse, app: String, into snapshot: inout Snapshot) {
        var index = Dictionary(uniqueKeysWithValues: snapshot.entries.enumerated().map { ($1.id, $0) })
        for quiz in lot.quizzes {
            let entry = CultureQuizEntry(quiz: quiz, app: app, lotDate: lot.date)
            if let position = index[quiz.id] {
                snapshot.entries[position] = CultureQuizEntry(quiz: quiz, app: snapshot.entries[position].app,
                                                              lotDate: snapshot.entries[position].lotDate)
            } else {
                index[quiz.id] = snapshot.entries.count
                snapshot.entries.append(entry)
            }
        }
    }

    /// Drops out-of-date questions, questions past `retentionDays`, and
    /// fetched-day marks outside the backfill window.
    static func prune(_ snapshot: inout Snapshot, today: CalendarDay, calendar: Calendar) {
        let todayKey = today.key
        let oldest = today.adding(days: -retentionDays, calendar: calendar).key
        snapshot.entries.removeAll {
            $0.lotDate < oldest || !CultureQuizFilter.isPlayable($0, today: todayKey, calendar: calendar)
        }
        let window = today.adding(days: -backfillDays, calendar: calendar).key
        snapshot.fetchedDays = snapshot.fetchedDays.filter { key in
            key.split(separator: "|").last.map { String($0) >= window } ?? false
        }
    }
}
