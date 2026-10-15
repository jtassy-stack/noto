import Foundation
import OSLog
import SwiftData

private let logger = Logger(subsystem: "com.pmf.noto", category: "QuizBankStore")

/// Pure mapping from a celyn bank DTO to `QuizItem` fields, plus the on-device
/// structural checks (celyn `structuralProblems`, core.ts): a malformed item is
/// dropped, never a whole page.
enum QuizBankMapper {
    /// `reviewed` threshold on celyn's `reviewConfidence` (design brief A.3).
    static let reviewedConfidence = 0.9
    /// `QuizItem.sourceRef` for celyn bank items: `celyn/bank/<grade>`.
    static func sourceRef(grade: String) -> String { "celyn/bank/\(grade)" }

    static func isReviewed(_ dto: BankQuizDto) -> Bool {
        dto.reviewMethod != nil && dto.reviewConfidence >= reviewedConfidence
    }

    /// nil when the item fails a structural check: not exactly 4 choices, an
    /// empty or duplicated choice, `answerIndex` outside 0…3, `difficulty`
    /// outside 1…3, an empty question, or a grade other than the one asked.
    static func problem(in dto: BankQuizDto, expectedGrade: String) -> String? {
        if dto.grade != expectedGrade { return "grade \(dto.grade) ≠ \(expectedGrade)" }
        if dto.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "empty question" }
        if dto.choices.count != 4 { return "\(dto.choices.count) choices" }
        let trimmed = dto.choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trimmed.contains(where: \.isEmpty) { return "empty choice" }
        // Same rule as celyn's zod schema (`new Set(trimmed).size === 4`):
        // exact distinctness after trimming. `QuizKey.normalizeName` would
        // collide valid choices (`-3`/`3`, `x²`/`x³`, `Le Nil`/`Nil`).
        if Set(trimmed).count != 4 { return "duplicate choices" }
        if !(0...3).contains(dto.answerIndex) { return "answerIndex \(dto.answerIndex)" }
        if !(1...3).contains(dto.difficulty) { return "difficulty \(dto.difficulty)" }
        return nil
    }

    static func makeItem(from dto: BankQuizDto, fetchedAt: Date) -> QuizItem {
        let item = QuizItem(
            id: dto.id, questionKey: dto.questionKey, kind: dto.kind, question: dto.question,
            choices: dto.choices, answerIndex: dto.answerIndex, domain: dto.domain,
            difficulty: dto.difficulty, source: .celyn, reviewed: false, fetchedAt: fetchedAt
        )
        apply(dto, to: item, fetchedAt: fetchedAt)
        return item
    }

    /// Overwrites every mirrored field. `horizon` / `validUntil` /
    /// `promotedFrom` do not exist on bank items (evergreen programme
    /// questions) and are cleared. celyn's `updatedAt` / `reviewMethod` /
    /// `reviewConfidence` have no `QuizItem` column: they feed the high-water
    /// mark and `reviewed`.
    static func apply(_ dto: BankQuizDto, to item: QuizItem, fetchedAt: Date) {
        item.questionKey = dto.questionKey
        item.kind = dto.kind
        item.question = dto.question
        item.choices = dto.choices
        item.answerIndex = dto.answerIndex
        item.explanation = dto.explanation
        item.domain = dto.domain
        item.difficulty = dto.difficulty
        item.tone = dto.tone
        item.horizon = nil
        item.validUntil = nil
        item.promotedFrom = nil
        item.oeuvreId = dto.oeuvreId
        item.oeuvreTitle = dto.oeuvreTitle
        item.imageUrl = dto.imageUrl
        item.format = .mcq
        item.level = dto.grade
        item.subject = dto.subject
        item.theme = dto.theme
        item.notion = dto.notion
        item.source = .celyn
        item.sourceRef = sourceRef(grade: dto.grade)
        item.reviewed = isReviewed(dto)
        item.fetchedAt = fetchedAt
    }

    /// The later of two celyn ISO-8601 timestamps (nil-safe). Compared as
    /// dates (fractional seconds or not); falls back to string order when a
    /// value does not parse, which matches celyn's fixed `…sss Z` format.
    static func later(_ a: String?, _ b: String?) -> String? {
        guard let a else { return b }
        guard let b else { return a }
        if let da = parseTimestamp(a), let db = parseTimestamp(b) { return db > da ? b : a }
        return b > a ? b : a
    }

    static func parseTimestamp(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    /// Maximum `updatedAt` across a page's items (dropped ones included: they
    /// were seen) and `removed` entries; nil for an empty page.
    static func pageHighWaterMark(_ page: BankResponse) -> String? {
        (page.items.map(\.updatedAt) + page.removed.map(\.updatedAt)).reduce(nil as String?) { later($0, $1) }
    }
}

/// Incremental, offline-first sync of celyn's programme bank into SwiftData
/// (`QuizItem`, `source: .celyn`) for one level.
///
/// - Keyed by celyn `id` (upsert: update in place or insert).
/// - Per-grade high-water mark (`updatedSince`, raw celyn string) and
///   last-success stamp in `UserDefaults`; at most one sync per grade per
///   `minInterval` (12 h) unless `force`.
/// - Each page is saved before the mark advances, so a failure on page N
///   keeps pages 1…N-1 and resumes there next time. A failure never deletes
///   local items and never stamps `lastSync` (the next attempt retries).
/// - Items celyn no longer serves (reported past the threshold, excluded)
///   come back in the page's `removed` list on an incremental sync and are
///   deleted by `id` in the same save as the page's upserts (unknown ids are
///   ignored). `QuizAttempt` keeps `itemIDs` / `questionKeys` as plain values
///   and `NotionMastery` is keyed by notion, so history survives a removal;
///   no relationship points at `QuizItem`.
/// - The loop runs while `nextUpdatedSince` is non-null, whatever the page
///   size (a non-final page may be short: removals share it). The mark
///   advances to the cursor, or on the last page to the maximum `updatedAt`
///   of its items and removals, never backwards.
///
/// - Offline fallback (plan §3.2 « banque embarquée »): `seedBundledIfNeeded`
///   inserts the bundled snapshot (`Resources/questions/<grade>.json`, same
///   ids / questionKeys as the server) when the level has no celyn item yet
///   and celyn has never served a row for it (no high-water mark).
///   It never touches the high-water mark or `lastSync`, so the next network
///   sync still fetches everything and upserts the same rows. Seeded rows keep
///   `sourceRef` = `celyn/bundle/<grade>` until the server serves them again.
///   A sync that starts without a mark sets a per-grade "full sync pending"
///   flag; the first run that drains the feed while it is set (the same run,
///   or a later one resuming after a failure or the page cap) deletes the
///   seeded rows never served (excluded since the snapshot: a full feed
///   carries no `removed` list) and clears the flag.
///
/// Main-actor bound like `FullSyncService`: it owns a main `ModelContext`;
/// only the network await leaves the actor (the client is `Sendable`).
@MainActor
final class QuizBankStore {
    enum Outcome: Equatable {
        /// Pages fetched and applied; `upserted` counts valid items written,
        /// `removed` the local items deleted from `removed` lists.
        case synced(upserted: Int, dropped: Int, removed: Int = 0)
        /// Last successful sync is younger than `minInterval`.
        case throttled
        /// Level outside 6e → Tle (primary, unknown): never hits the server.
        case unsupportedLevel(String)
    }

    static let minInterval: TimeInterval = 12 * 60 * 60
    static let pageLimit = 200
    /// Safety cap: 200 × 50 = 10 000 items per sync.
    static let maxPages = 50

    private let modelContext: ModelContext
    private let client: QuizAPIClient
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date

    init(
        modelContext: ModelContext,
        client: QuizAPIClient = QuizAPIClient(),
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.modelContext = modelContext
        self.client = client
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Keys

    static func updatedSinceKey(grade: String) -> String { "quiz.bank.updatedSince.\(grade)" }
    static func lastSyncKey(grade: String) -> String { "quiz.bank.lastSync.\(grade)" }
    /// Set when a sync starts with no high-water mark; cleared once a drained
    /// run has pruned the seeded rows celyn did not serve. Survives a full
    /// sync interrupted mid-feed, so the resumed (incremental) run prunes.
    static func fullSyncPendingKey(grade: String) -> String { "quiz.bank.fullSyncPending.\(grade)" }

    func highWaterMark(grade: String) -> String? {
        defaults.string(forKey: Self.updatedSinceKey(grade: grade))
    }

    func lastSync(grade: String) -> Date? {
        defaults.object(forKey: Self.lastSyncKey(grade: grade)) as? Date
    }

    // MARK: - Sync

    /// Sync for a child's stored grade label (`"3ème"`, `"Terminale"`…).
    @discardableResult
    func sync(child: Child, force: Bool = false) async throws -> Outcome {
        try await sync(level: child.grade, force: force)
    }

    /// Sync one level. `level` is canonicalised through
    /// `CurriculumService.canonicalLevel`. Throws the client's `QuizAPIError`
    /// (or a SwiftData save error) after keeping whatever pages were saved.
    @discardableResult
    func sync(level: String, force: Bool = false) async throws -> Outcome {
        let grade = CurriculumService.canonicalLevel(level)
        guard CurriculumService.revisionLevels.contains(grade) else {
            return .unsupportedLevel(grade)
        }
        // One sync per grade at a time: a second caller (automatic + forced
        // refresh, two siblings in the same grade) joins the run in flight
        // instead of fetching from the same cursor and applying an older page
        // over a newer one (or re-inserting an item the other run removed).
        if let running = inFlight[grade] {
            return try await running.value
        }
        let task = Task { @MainActor in try await self.runSync(grade: grade, force: force) }
        inFlight[grade] = task
        defer { inFlight[grade] = nil }
        return try await task.value
    }

    /// Per-grade in-flight sync (see `sync(level:force:)`).
    private var inFlight: [String: Task<Outcome, any Error>] = [:]

    private func runSync(grade: String, force: Bool) async throws -> Outcome {
        if !force, let last = lastSync(grade: grade), now().timeIntervalSince(last) < Self.minInterval {
            return .throttled
        }

        var cursor = highWaterMark(grade: grade)
        if cursor == nil {
            defaults.set(true, forKey: Self.fullSyncPendingKey(grade: grade))
        }
        var upserted = 0
        var dropped = 0
        var removed = 0
        var reachedEnd = false
        for _ in 0..<Self.maxPages {
            let page = try await client.bank(grade: grade, limit: Self.pageLimit, updatedSince: cursor)
            let result = try apply(page, grade: grade)
            upserted += result.upserted
            dropped += result.dropped
            removed += result.removed

            // Advance only after the page is saved, and never backwards.
            // `nextUpdatedSince` is the last row's `updatedAt` while rows
            // follow; on the last page it is null and the page's own maximum
            // (items and removals) is the mark.
            let previous = cursor
            let candidate = page.nextUpdatedSince ?? QuizBankMapper.pageHighWaterMark(page)
            if let candidate, QuizBankMapper.later(previous, candidate) == candidate, candidate != previous {
                cursor = candidate
                // Compare against the stored mark, not only the local cursor:
                // two syncs of one grade can interleave at the network await,
                // and a slower run must not write an older mark over a newer one.
                let stored = highWaterMark(grade: grade)
                if QuizBankMapper.later(stored, candidate) == candidate, candidate != stored {
                    defaults.set(candidate, forKey: Self.updatedSinceKey(grade: grade))
                }
            }
            // Only a null cursor ends the feed (a short page may be non-final).
            // A server repeating the same cursor would otherwise loop.
            guard page.nextUpdatedSince != nil, cursor != previous else {
                reachedEnd = true
                break
            }
        }

        // Stamp the throttle only when the feed was drained. A run cut by
        // `maxPages` with rows still pending must not block the next call
        // for 12 h: it resumes from the saved mark instead.
        guard reachedEnd else {
            logger.info("Bank sync \(grade, privacy: .public): page cap reached, continuing next call")
            return .synced(upserted: upserted, dropped: dropped, removed: removed)
        }
        // The full feed is now drained, possibly across several runs: every
        // row it served was re-stamped `celyn/bank/…`. An empty full feed
        // (celyn misconfigured / bank wiped: no bank row at all) leaves the
        // offline snapshot alone rather than emptying the child's quiz.
        if defaults.bool(forKey: Self.fullSyncPendingKey(grade: grade)), try hasBankItems(grade: grade) {
            removed += try pruneUnservedBundled(grade: grade)
            defaults.removeObject(forKey: Self.fullSyncPendingKey(grade: grade))
        }
        defaults.set(now(), forKey: Self.lastSyncKey(grade: grade))
        logger.info("Bank sync \(grade, privacy: .public): \(upserted) upserted, \(dropped) dropped, \(removed) removed")
        return .synced(upserted: upserted, dropped: dropped, removed: removed)
    }

    // MARK: - Bundled offline bank

    /// Seeds this level from the bundled snapshot when it has no celyn item
    /// yet (first launch offline, celyn down, empty key on a fresh clone).
    /// Returns the number of items inserted (0 when skipped).
    @discardableResult
    func seedBundledIfNeeded(level: String) throws -> Int {
        try Self.seedBundledIfNeeded(level: level, in: modelContext, defaults: defaults, now: now())
    }

    /// Static form for callers that only hold a `ModelContext`
    /// (`QuizSession.draw`): no network client is built.
    ///
    /// - Skips levels outside 6e → Tle, levels without a bundled file, any
    ///   level that already has a `.celyn` item (synced or seeded): the
    ///   server copy always wins and is never overwritten by the snapshot,
    ///   and any level celyn has already served (a high-water mark is
    ///   stored): a level emptied by server `removed` lists must stay empty,
    ///   not be resurrected from the snapshot past the mark.
    /// - Same DTO, mapper and structural checks as a network page; items keep
    ///   celyn's ids / questionKeys, so the next sync upserts the same rows.
    /// - Never writes the high-water mark nor `lastSync`: the next network
    ///   sync is a full one.
    /// - Synchronous on the main actor (no await), so it cannot interleave
    ///   with a page apply of `sync(level:)`.
    @discardableResult
    static func seedBundledIfNeeded(
        level: String, in modelContext: ModelContext, bundle: Bundle = .main,
        defaults: UserDefaults = .standard, now: Date = Date()
    ) throws -> Int {
        let grade = CurriculumService.canonicalLevel(level)
        guard CurriculumService.revisionLevels.contains(grade) else { return 0 }
        guard defaults.string(forKey: updatedSinceKey(grade: grade)) == nil else { return 0 }
        guard try !hasCelynItems(grade: grade, in: modelContext) else { return 0 }
        guard let file = try BundledQuizBank.load(grade: grade, bundle: bundle) else { return 0 }
        guard file.grade == grade else {
            logger.warning("Bundled bank \(grade, privacy: .public) declares grade \(file.grade, privacy: .public): skipped")
            return 0
        }
        let result = try applyPage(file.asPage, grade: grade, in: modelContext, fetchedAt: now,
                                   sourceRef: BundledQuizBank.sourceRef(grade: grade))
        logger.info("Seeded bundled bank \(grade, privacy: .public): \(result.upserted) items, \(result.dropped) dropped")
        return result.upserted
    }

    /// Whether `grade` already holds a celyn item. `source` is filtered in
    /// memory: enum comparisons in `#Predicate` are unreliable in SwiftData.
    static func hasCelynItems(grade: String, in modelContext: ModelContext) throws -> Bool {
        let wanted: String? = grade
        let descriptor = FetchDescriptor<QuizItem>(predicate: #Predicate { $0.level == wanted })
        return try modelContext.fetch(descriptor).contains { $0.source == .celyn }
    }

    /// Whether `grade` holds a row celyn served (`celyn/bank/<grade>`).
    private func hasBankItems(grade: String) throws -> Bool {
        let wanted: String? = grade
        let ref: String? = QuizBankMapper.sourceRef(grade: grade)
        var descriptor = FetchDescriptor<QuizItem>(predicate: #Predicate { $0.level == wanted && $0.sourceRef == ref })
        descriptor.fetchLimit = 1
        return try !modelContext.fetch(descriptor).isEmpty
    }

    /// After the full feed is drained (`fullSyncPendingKey` set): deletes the seeded rows celyn did not serve
    /// (excluded since the snapshot was taken). A full feed carries no
    /// `removed` list, and every served row was re-stamped `celyn/bank/…` by
    /// `QuizBankMapper.apply`, so whatever still reads `celyn/bundle/…` is gone
    /// server-side.
    private func pruneUnservedBundled(grade: String) throws -> Int {
        let wanted: String? = grade
        let ref: String? = BundledQuizBank.sourceRef(grade: grade)
        let descriptor = FetchDescriptor<QuizItem>(predicate: #Predicate { $0.level == wanted && $0.sourceRef == ref })
        let stale = try modelContext.fetch(descriptor).filter { $0.source == .celyn }
        guard !stale.isEmpty else { return 0 }
        for item in stale { modelContext.delete(item) }
        try modelContext.save()
        return stale.count
    }

    // MARK: - Apply a page

    /// Upserts the page's valid items and deletes the local items listed in
    /// `removed` (plus any stale local copy of a dropped item), in ONE save.
    private func apply(_ page: BankResponse, grade: String) throws -> (upserted: Int, dropped: Int, removed: Int) {
        try Self.applyPage(page, grade: grade, in: modelContext, fetchedAt: now())
    }

    /// Body of `apply`, static so the bundled seed (reachable from
    /// `QuizSession.draw`, which only has a `ModelContext`) shares the exact
    /// upsert / drop / single-save path without building a network client.
    @discardableResult
    static func applyPage(
        _ page: BankResponse, grade: String, in modelContext: ModelContext, fetchedAt: Date,
        sourceRef: String? = nil
    ) throws -> (upserted: Int, dropped: Int, removed: Int) {
        var upserted = 0
        var dropped = 0
        var removed = 0
        var inserted: [QuizItem] = []
        for dto in page.items {
            if let problem = QuizBankMapper.problem(in: dto, expectedGrade: grade) {
                logger.warning("Dropped bank item \(dto.id.uuidString, privacy: .public): \(problem, privacy: .public)")
                dropped += 1
                // celyn changed this row and the mark moves past its new
                // `updatedAt`: a local copy synced earlier would stay stale
                // for good. Delete it (this grade's celyn items only).
                if let existing = try fetchItem(id: dto.id, in: modelContext), existing.source == .celyn, existing.level == grade {
                    modelContext.delete(existing)
                    inserted.removeAll { $0 === existing }
                    removed += 1
                }
                continue
            }
            if let existing = try fetchItem(id: dto.id, in: modelContext) {
                QuizBankMapper.apply(dto, to: existing, fetchedAt: fetchedAt)
                if let sourceRef { existing.sourceRef = sourceRef }
            } else {
                let item = QuizBankMapper.makeItem(from: dto, fetchedAt: fetchedAt)
                if let sourceRef { item.sourceRef = sourceRef }
                modelContext.insert(item)
                inserted.append(item)
            }
            upserted += 1
        }

        // Removals after upserts: a row is either servable or removed at a
        // given `updatedAt`, so the two lists never overlap in practice; if
        // they did, the removal wins. Unknown ids (never synced, already
        // deleted) are ignored; only celyn bank items are ever deleted.
        for entry in page.removed {
            guard let existing = try fetchItem(id: entry.id, in: modelContext), existing.source == .celyn else { continue }
            modelContext.delete(existing)
            inserted.removeAll { $0 === existing }
            removed += 1
        }

        do {
            try modelContext.save()
        } catch {
            // The main context is shared: `rollback()` would also discard other
            // features' unsaved edits (attempts, mastery, settings). Undo only
            // this page's inserts. In-place updates and deletions stay pending:
            // they are valid celyn data, and the page is re-fetched next time
            // since the high-water mark did not advance.
            for item in inserted { modelContext.delete(item) }
            throw error
        }
        return (upserted, dropped, removed)
    }

    private static func fetchItem(id: UUID, in modelContext: ModelContext) throws -> QuizItem? {
        var descriptor = FetchDescriptor<QuizItem>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

// MARK: - Bundled offline bank

/// The programme bank snapshot shipped in the app (`Noto/Resources/questions/
/// <grade>.json`): `{version, lastUpdated, source, grade, items}` where `items`
/// are exactly celyn `BankQuizDto` rows (`GET /api/quiz/v2/bank` snapshot).
/// Only questions: nothing about a child is in it or derived from it.
enum BundledQuizBank {
    static let subdirectory = "questions"

    /// `QuizItem.sourceRef` of a seeded row until the server serves it again.
    static func sourceRef(grade: String) -> String { "celyn/bundle/\(grade)" }

    struct File: Decodable, Sendable {
        let version: String
        let lastUpdated: String?
        let source: String?
        let grade: String
        let items: [BankQuizDto]

        /// The snapshot as a final bank page (no removals, no cursor).
        var asPage: BankResponse {
            BankResponse(app: QuizAPIClient.app, grade: grade, count: items.count, items: items,
                         removed: [], nextUpdatedSince: nil)
        }
    }

    /// XcodeGen adds `Resources/questions` as a group, so the files usually
    /// land flat at the bundle root; a folder reference would keep the
    /// subdirectory. Both are tried (same pattern as `ENTRegistry`).
    static func url(grade: String, bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: grade, withExtension: "json", subdirectory: subdirectory)
            ?? bundle.url(forResource: grade, withExtension: "json")
    }

    /// nil when no file ships for `grade` (canonical level); throws when the
    /// file exists but does not decode.
    static func load(grade: String, bundle: Bundle = .main) throws -> File? {
        guard let url = url(grade: grade, bundle: bundle) else { return nil }
        return try decode(Data(contentsOf: url))
    }

    static func decode(_ data: Data) throws -> File {
        try JSONDecoder().decode(File.self, from: data)
    }
}
