# Phase 3 design brief: Révisions module (iOS), built on celyn

Root: `/Users/julientassy/dev-projects/PMF/noto/.claude/worktrees/noto-plan-cec3d3`. Celyn paths are relative to `/Users/julientassy/dev-projects/celyn/culture-api`.

Two places where this brief overrides the plan (`docs/PLAN_REVISIONS_KMP_ANDROID.md` §3.1 and §3.2 bis), with the reasons:
- **No `NotoSchemaV2.swift`.** The new models are appended to `NotoSchemaV1`. Reason in A.2.
- **The plan's Scapin example is wrong.** It puts « Les Fourberies de Scapin » in 5e. Celyn's data has it in **4eme**-français, theme « Molière et le théâtre classique » (`src/jobs/seed-curriculum.ts:362-366`). Tests and fixtures must follow `curriculum.json` and celyn, not the plan's wording.

---

## A) Sub-phase 3.1: models and pure logic

### A.1 Files

```
Noto/Models/QuizItem.swift
Noto/Models/QuizAttempt.swift
Noto/Models/NotionMastery.swift
Noto/Models/NotoSchemaV1.swift              // edited: append 3 types (no V2)
Noto/Models/Child.swift                     // edited: 2 cascade to-many relationships
Noto/Models/PreviewData.swift               // edited: add the new types to the ad-hoc Schema (L14-17)
Noto/Services/Quiz/QuizSnapshots.swift      // Sendable value types fed to the pure services
Noto/Services/Quiz/RewardPolicy.swift       // pure
Noto/Services/Quiz/SpacedRepetition.swift   // pure
Noto/Services/Quiz/QuizSourceSelector.swift // pure
Noto/Services/Quiz/ExamKeywordDetector.swift// pure, used by RewardPolicy + selector
NotoTests/Services/Quiz/RewardPolicyTests.swift
NotoTests/Services/Quiz/SpacedRepetitionTests.swift
NotoTests/Services/Quiz/QuizSourceSelectorTests.swift
NotoTests/Services/Quiz/ExamKeywordDetectorTests.swift
NotoTests/Models/QuizModelPersistenceTests.swift
```

After adding the files, run `xcodegen generate`. `project.yml` picks up folders, so check that `Noto/Services/Quiz` and `NotoTests/Services/Quiz` are included.

### A.2 Adding the models to the SwiftData schema safely

- **Container today.** `Noto/App/NotoApp.swift:9-22` builds `Schema(versionedSchema: NotoSchemaV1.self)` with no migration plan, and calls `fatalError` if that fails. SwiftData therefore runs an automatic lightweight migration, and adding new entities is one of the cases it handles.
- **Precedent.** Commit `6faa070a` appended `MeetingNote` and `ExtractedItem` to `NotoSchemaV1.models` in place and shipped.
- **Why not V2.** The doc comment in `NotoSchemaV1.swift:8-18` warns that adding a `SchemaMigrationPlan` before V1 is frozen as nested copies makes launch fail with "unknown model version".

Rules:
1. Append `QuizItem.self, QuizAttempt.self, NotionMastery.self` to `NotoSchemaV1.models`. Leave `versionIdentifier` at `1.0.0`. Add no plan.
2. Also add `SchoolPhoto.self`. It is missing today and only works because SwiftData reaches it through `Child.photos`. Listing it is harmless and needed before any future freeze.
3. On `Child` (`Child.swift:62-73`), add relationships in the existing style:
   ```swift
   @Relationship(deleteRule: .cascade, inverse: \QuizAttempt.child) var quizAttempts: [QuizAttempt] = []
   @Relationship(deleteRule: .cascade, inverse: \NotionMastery.child) var notionMasteries: [NotionMastery] = []
   ```
   A new to-many relationship on an existing entity is lightweight-compatible. Give both an inline default.
4. `QuizItem` has **no** child link. Bank and celyn items are shared and non-personal. `.homework` / `.generated` items are derived from a child's homework: before 3.3 writes any, they need a `Child` owner with cascade delete, or must stay out of `QuizItem` (C.4 item 15).
5. Never rename or retype an existing attribute.
6. **`ScheduleEntry.isTest`.** Adding `var isTest: Bool = false` to `ScheduleEntry` is lightweight-safe: it is an additive field with a default, the same pattern as `Child.specialties`. The homework report says it "needs V2"; that is wrong. Wiring it means copying `PronoteLesson.isTest` (`PronoteTypes.swift:69`, `PawnoteBridge.swift:279`) in `PronoteSyncService.syncSchedule` (L119). This is optional for 3.1 and needs Julien's go-ahead (C.4). If done, `ExamKeywordDetector` gets a second, stronger signal.
7. **Persistence test.** `QuizModelPersistenceTests` builds `ModelConfiguration(isStoredInMemoryOnly: true)` with `Schema(NotoSchemaV1.models)`, inserts one of each new model, fetches them back, and checks that deleting a `Child` cascades. This is the same pattern as `ChildSyncStateTests.swift:15-17`.

### A.3 `@Model` types

Enums are `String, Codable` and use discriminators, following `ExtractedItemKind`.

```swift
enum QuizSourceKind: String, Codable, Sendable { case celyn, bank, homework, generated }
enum QuizFormat: String, Codable, Sendable { case mcq }   // V1 = MCQ only (celyn contract is 4-choice MCQ)

@Model final class QuizItem {
    // --- celyn KoiQuizV2Dto mirror (1:1, src/lib/koi/read.ts:15-76) ---
    @Attribute(.unique) var id: UUID          // celyn quiz uuid; bank/homework items get a deterministic UUID (v5 of questionKey)
    var questionKey: String                    // celyn core.ts:90-93 algorithm, recomputed on device for bank/homework items
    var kind: String                           // celyn: actu|catalogue|bridge|filmo|fait (+ future "programme"); bank: "programme"
    var question: String
    var choices: [String]                      // exactly 4
    var answerIndex: Int                       // 0...3
    var explanation: String?
    var domain: String                         // celyn domain (culture or future school domain)
    var difficulty: Int                        // 1...3
    var tone: String?                          // actu|histoire|fun
    var horizon: String?                       // jour|semaine|mois
    var validUntil: Date?                      // nil = evergreen
    var promotedFrom: String?
    var oeuvreId: UUID?                        // links to the post-quiz reco (B.5)
    var oeuvreTitle: String?
    var imageUrl: String?
    // --- nōto-only ---
    var format: QuizFormat = QuizFormat.mcq
    var level: String?                         // canonical "6e"…"Tle"
    var subject: String?                       // curriculum subject name
    var theme: String?                         // exact CurriculumTheme.theme string
    var notion: String?                        // finer key for Leitner; defaults to theme when absent
    var source: QuizSourceKind
    var sourceRef: String?                     // celyn: lot date+app ; bank: "<level>/<subject>.json#<idx>" ; homework: dedup hash
    var reviewed: Bool                         // celyn: review_method != nil && confidence >= threshold; bank: JSON `reviewed`
    var fetchedAt: Date
    init(...)  // all non-optionals
}

@Model final class QuizAttempt {
    var id: UUID
    var child: Child?
    var date: Date
    var itemIDs: [UUID]                        // ordered
    var questionKeys: [String]                 // sorted; replay detection (UUID-independent)
    var answers: [Int]                         // chosen index per item, -1 = skipped
    var correctCount: Int
    var totalCount: Int
    var durationSec: Int
    var minutesEarned: Int                     // base + bonus actually credited
    var bonusApplied: Bool
    var bonusMinutes: Int = 0                  // bonus part of minutesEarned, as credited (daily cap counts base only)
    var denialReason: String?                  // RewardDecision.Denial raw value, for parent screen 3.7
    init(...)
}

@Model final class NotionMastery {
    var id: UUID
    var child: Child?
    var notionKey: String                      // "<level>|<subject>|<theme or notion>", folded
    var leitnerBox: Int                        // 1...5
    var nextReview: Date                       // start of day
    var streakCorrect: Int
    var lastReviewedAt: Date?
    init(child: Child?, notionKey: String, now: Date)  // box 1, nextReview = startOfDay(now)
}
```

Why `questionKey` is stored on `QuizAttempt` and not only item IDs: celyn re-dates rows and bank items are regenerated, so the key is the only stable identity. That matches celyn's own dedup (`core.ts:90-93`).

Port `questionKey` to Swift as `QuizKey.make(question:choices:) -> String`, with the same normalisation as `core.ts:90-93`: normalised question cut to 240, `#`, sorted normalised choices, total cut to 500. Pin it with golden test vectors copied from celyn's tests so both sides agree.

### A.4 Value snapshots (`QuizSnapshots.swift`)

All snapshot types are `Sendable` structs, built on `@MainActor` from the models.

```swift
struct HomeworkSnapshot: Sendable, Equatable { let subject: String; let descriptionText: String; let dueDate: Date; let done: Bool
    var dedupKey: String }        // SHA256(fold(subject) + "|" + ymd(startOfDay(dueDate)) + "|" + fold(descriptionText)); rows are recreated each sync
struct ScheduleSnapshot: Sendable { let subject: String; let start: Date; let end: Date; let cancelled: Bool; let isTest: Bool }
struct MasterySnapshot: Sendable { let notionKey: String; let leitnerBox: Int; let nextReview: Date; let streakCorrect: Int }
struct AttemptSnapshot: Sendable { let date: Date; let questionKeys: [String]; let correctCount: Int; let totalCount: Int
    let durationSec: Int; let minutesEarned: Int; let passed: Bool; let bonusApplied: Bool; let bonusMinutes: Int }
struct ChildRevisionContext: Sendable { let level: String /*canonical*/; let specialties: [String]; let weakSubjects: [String] }
```

### A.5 `RewardPolicy` (pure)

```swift
struct RewardConfig: Codable, Sendable, Equatable {
    var tiers: [Int] = [10, 5, 5]          // minutes for the 1st, 2nd, 3rd successful quiz; later = 0
    var passThreshold: Double = 0.8        // 4/5 → correct/total >= 0.8
    var dailyCap: Int = 20                 // applies to base minutes
    var examEveBonus: Int = 5
    var examEveBonusEnabled: Bool = true
    var minDurationSec: Int = 30
    var replayWindow: ReplayWindow = .ever // .sameDay | .ever
    static let `default` = RewardConfig()
}
enum RewardDenial: String, Sendable { case belowThreshold, tooFast, identicalReplay, tiersExhausted, capReached, emptyQuiz }
struct RewardDecision: Sendable, Equatable { let base: Int; let bonus: Int; var total: Int { base + bonus }; let denial: RewardDenial?; let countsAsSuccess: Bool }

enum RewardPolicy {
    static func evaluate(attempt: AttemptSnapshot,           // the attempt being scored (minutesEarned ignored)
                         history: [AttemptSnapshot],         // this child's prior attempts (any days)
                         homeworkTomorrow: [HomeworkSnapshot],
                         scheduleTomorrow: [ScheduleSnapshot],
                         config: RewardConfig,
                         now: Date,
                         calendar: Calendar) -> RewardDecision
}
```

**Rules, evaluated in this order.** The first denial wins.
1. `totalCount == 0` → `.emptyQuiz`.
2. `correctCount / totalCount < passThreshold` → `.belowThreshold`. Use integer comparison: `correct * 5 >= total * 4` for the default, or generally `Double(correct) >= threshold * Double(total) - 1e-9`.
3. `durationSec < minDurationSec` → `.tooFast`. 30 s is the total for the quiz.
4. Identical replay: some `h` in `history`, within `replayWindow`, has `h.passed` and `Set(h.questionKeys) == Set(attempt.questionKeys)` → `.identicalReplay`.
5. Tier lookup. `successesToday` counts history attempts on the same calendar day with `passed && minutesEarned > 0`, so denied attempts never use up a tier slot. `base = tiers[safe: successesToday] ?? 0`. If `base == 0` → `.tiersExhausted`.
6. Cap. `earnedBaseToday = Σ history same day max(0, minutesEarned - bonusMinutes)`, using the stored bonus, never the current `examEveBonus`. `base = min(base, max(0, dailyCap - earnedBaseToday))`. If that gives 0 → `.capReached`.
7. Bonus. Apply only if all of these hold:
   - `examEveBonusEnabled`;
   - no attempt today already has `bonusApplied`;
   - `ExamKeywordDetector.hasExamTomorrow(homework:schedule:now:calendar:)` is true.

   Then `bonus = examEveBonus`. The bonus sits **on top of the cap**, at most once per day. This is a default awaiting Julien's decision: with tiers 10+5+5 the total is exactly the cap of 20, so a bonus inside the cap could never be reached.
8. `countsAsSuccess = denial == nil || denial == .tiersExhausted || denial == .capReached`. A passed quiz still feeds XP and streak (3.6) even when it earns no minutes.

**What RewardPolicy does not do: the class-lock reserve.** It only computes minutes earned. Whether the credit goes to reserve or is consumed is decided in `RewardUnlockService` (3.4), against `ClassScheduleShieldService` blocks. That keeps the invariant in one place, outside the pure layer.

```swift
enum ExamKeywordDetector {
    static let keywords: [Rule] = [.token(["controle", "controles"]), .token(["evaluation", "evaluations"]), .numbered("ds"),
                                   .token(["interro", "interros", "interrogation", "interrogations"]), .phrase("bac blanc"),
                                   .phrase("devoir surveille")]   // last one: suggestion, flag to Julien
    static func matches(_ text: String) -> Bool            // SubjectAlias.tokens; .token = whole token from an explicit set
                                                           // (not "interroger", "contrôler"), skipped after "auto" ("auto-évaluation");
                                                           // .numbered = "ds" or "ds" + digits ("DS2"); contiguous token match for phrases
    static func hasExamTomorrow(homework: [HomeworkSnapshot], schedule: [ScheduleSnapshot], now: Date, calendar: Calendar) -> Bool
        // homework: !done && calendar.isDate(dueDate, inSameDayAs: tomorrow(now)) && matches(descriptionText)
        // schedule: isTest && !cancelled && same-day tomorrow
}
```

Compare calendar days, never `now + 24h`: ENT, MonLycée and École Directe stamp due dates at local midnight (homework report §2). For "tomorrow", use `calendar.date(byAdding: .day, value: 1, to: startOfDay(now))` and `isDate(_:inSameDayAs:)`.

### A.6 `SpacedRepetition` (pure, Leitner with 5 boxes)

```swift
enum SpacedRepetition {
    static let intervalsDays = [1, 2, 4, 8, 16]                 // box 1…5
    enum FailureRule: Sendable { case resetToBoxOne, demoteOne } // default .resetToBoxOne
    static func review(_ m: MasterySnapshot, correct: Bool, now: Date, calendar: Calendar,
                       failure: FailureRule = .resetToBoxOne) -> MasterySnapshot
        // correct: box = min(5, box+1), streak += 1 ; wrong: box = 1 (or max(1, box-1)), streak = 0
        // nextReview = startOfDay(now) + intervalsDays[box-1] days ; input box clamped to 1...5 first
    static func initial(notionKey: String, now: Date, calendar: Calendar) -> MasterySnapshot   // box 1, due today
    static func isDue(_ m: MasterySnapshot, now: Date, calendar: Calendar) -> Bool             // nextReview <= startOfDay(now)
    static func isMastered(_ m: MasterySnapshot) -> Bool                                       // box >= 4 (3.6 badge rule)
    static func notionOutcome(itemsCorrect: [Bool]) -> Bool                                     // notion correct iff all its items in the attempt correct
}
```

Granularity: one `review` call per notion per attempt, not per question. Otherwise a 5-question quiz on one theme would jump the notion 5 boxes in one sitting.

### A.7 `QuizSourceSelector` (pure)

```swift
struct QuizPlanSlot: Sendable, Equatable { enum Origin: Sendable { case homeworkTomorrow, homeworkToday, homeworkLater, dueNotion, programme }
    let origin: Origin; let subject: String; let theme: String?; let keywords: [String]; let homeworkKey: String?; let notionKey: String? }
struct QuizPlan: Sendable, Equatable { let slots: [QuizPlanSlot]; let isEligible: Bool }

protocol CurriculumLookup: Sendable {   // CurriculumService gets a conformance; tests use a stub
    func themes(for level: String, subject: String, specialties: [String]?) -> [CurriculumTheme]
    func subjects(for level: String) -> [String]
    func subjectThemes(for level: String, subject: String, specialties: [String]?) -> [(name: String, themes: [CurriculumTheme])]
        // owning subject name per theme group (6e TECHNOLOGIE → "Sciences et technologie")
}

enum QuizSourceSelector {
    static func plan(context: ChildRevisionContext, homework: [HomeworkSnapshot], masteries: [MasterySnapshot],
                     curriculum: some CurriculumLookup, now: Date, calendar: Calendar,
                     maxSlots: Int = 5, currentPeriod: String?) -> QuizPlan
    static func bestTheme(text: String, level: String, subject: String, specialties: [String],
                          curriculum: some CurriculumLookup) -> (theme: CurriculumTheme, score: Int)?
        // mirrors CurriculumService.matchKeywords scoring (+10 theme-name containment, +3 per keyword, whole-word < 4 chars) but returns the theme
}
```

`bestTheme` exists because `matchKeywords` returns keywords only and no public API exposes the best theme. Factor the scoring out of `CurriculumService` (around L188) into a shared internal function so the two can't drift.

**Rules:**
1. **Gate.** If `CurriculumService.canonicalLevel(level) ∉ CurriculumService.revisionLevels`, return `QuizPlan(slots: [], isEligible: false)`. This is the primary-school exclusion.
2. **Homework window.** Keep `!done && startOfDay(now) <= dueDate < startOfDay(now)+3 days`, deduplicated by `dedupKey`.
3. **Homework order.** Tomorrow first, then today, then later, each sorted by `dueDate`, ties broken by `dedupKey` so the order is deterministic.
4. **Theme per homework item.** Map each to a theme with `bestTheme`, resolving subjects through `CurriculumLookup.subjectThemes` and keeping the owning subject's name, so the slot's notion key equals the programme's. If nothing scores, keep the slot with `theme = nil` (selector origin "homework", bank fallback by subject).
5. **Due notions.** Next, add notions where `isDue`, lowest box first, then oldest `nextReview`. Skip any notion already covered by a homework slot.
6. **Programme fill.** Fill the remaining slots from the programme: the level's subjects, with `weakSubjects` first, then themes where `period == currentPeriod || period == "Année" || period == nil`. Skip themes that already have a `NotionMastery`, to favour new material.
7. **Size.** Truncate to `maxSlots`. The output is fully deterministic for a given input; no randomness lives here. Shuffling happens at item draw, seeded.

### A.8 Test matrix (Swift Testing)

Use `@Suite`, `@Test` and `#expect`, a fixed `Date(timeIntervalSince1970: 1_700_000_000)`, and `Calendar(identifier: .gregorian)` with `TimeZone(identifier: "Europe/Paris")`, following the style of `SyncCooldownPolicyTests`.

| Suite | Cases (each one branch) |
|---|---|
| RewardPolicy | empty quiz; 3/5 below; exactly 4/5 passes; 5/5; 29 s tooFast; exactly 30 s passes; identical replay same day; identical replay previous day with `.ever` denied / `.sameDay` allowed; same keys different order = replay; 4/5 keys overlap ≠ replay; prior *failed* identical attempt does not block; 1st success 10; 2nd 5; 3rd 5; 4th tiersExhausted; denied attempts don't consume a tier; cap partial (custom tiers [15,10] cap 20 → 15 then 5); cap reached → `.capReached`; cap uses the stored `bonusMinutes` when `examEveBonus` changes mid-day; inconsistent prior clamps to 0 base; bonus applied tomorrow-contrôle; bonus not applied when exam is today or in 2 days; bonus only once/day; bonus disabled by config; bonus not given on a denied quiz; bonus via `scheduleTomorrow.isTest`; cancelled test lesson ignored; custom config (tiers, threshold 0.6, minDuration 0); `countsAsSuccess` for each denial |
| ExamKeywordDetector | each keyword in `CurriculumHomeworkFixtures.swift:12-52` (« Contrôle mardi », « Interrogation jeudi », « évaluation de vendredi », « DS vendredi »); uppercase/accents (« CONTRÔLE », « Évaluation »); "ds" not inside "fonds"/"dsl", but "DS2" / "DS n°3" match; "interroger", "contrôler", "auto-évaluation" do not match; "interro" prefix matches "interros"; "bac blanc" phrase vs "bac" alone false; done homework ignored; midnight-stamped due date tomorrow matches; 23:59 today does not |
| SpacedRepetition | correct 1→2 … 4→5; correct at 5 stays 5; wrong resets to 1 (default); wrong `.demoteOne` 3→2 and 1→1; intervals 1/2/4/8/16 exact; out-of-range input box clamped (0, 6); isDue before/at/after; isMastered at 3/4; streak increments/resets; nextReview computed from start of day even at 23:59; notionOutcome all-true/one-false/empty |
| QuizSourceSelector | primary level → ineligible; unknown level "TG2" → ineligible; empty everything → programme only; tomorrow before today before later; done excluded; due in 3 days excluded, in 2 days included; dedup of identical rows; alias "HISTOIRE-GEOGRAPHIE" resolves; 6e "TECHNOLOGIE" slot uses the "Sciences et technologie" notion key, not re-offered as due notion or programme; no theme match → theme nil slot; due notions after homework; notion already covered by homework skipped; weak subject first in programme fill; period filter; maxSlots truncation; specialties empty → all spé eligible; determinism (same input twice → same plan) |
| QuizKey | golden vectors shared with celyn; choice order independence; 500-char truncation |
| Persistence | insert/fetch the 3 models; cascade delete from Child |

To check 100 % branch coverage, use `get_file_coverage` on the three service files in CI review.

### A.9 Swift 6 concurrency notes

- All pure services are `enum`s with `static` functions over `Sendable` structs. They hold no state and need no actor.
- `@Model` classes are not `Sendable`. Snapshots are built on `@MainActor` (the view or a `@MainActor` coordinator), handed to the pure functions, and the results are written back on `@MainActor`. Never pass a `ModelContext` or a model across actors.
- `RewardConfig` is persisted as JSON in the app group: put it in `Shared/RewardLedger.swift` (3.4) so the extension can read it, with the same versioned-envelope pattern as `ScreenTimeEventStore`.
- `Calendar` and `Date` are `Sendable`. Pass them in explicitly for testability; never read `Calendar.current` inside the pure services.
- `CurriculumLookup: Sendable`. `CurriculumService` is a non-Sendable `final class` today. Either give it a conformance as `@unchecked Sendable` after confirming that `programs` is immutable after load, or pass a `CurriculumSnapshot` struct built from `[CurriculumProgram]`, which is already `Sendable`. The second option is preferred.

---

## B) celyn integration plan

### B.1 Can nōto consume quiz v2 as-is with `app=noto`?

**Mechanically yes, as a contract: no, not today.** The blockers:
1. `noto` is not in `KOI_APPS` (`typologies/index.ts:33`), so `/api/quiz/v2/lot?app=noto` returns 400 (`http.ts:25`).
2. There is no grade dimension.
   - `koi_quizzes` has no grade, subject or curriculum column.
   - The lot's unique key is `(app, lot_date, edition)`, and `edition` is CHECKed to `daily|matin|midi|soir` (`0158:11-12`).
   - `lotHandler` takes no grade parameter.
3. School domains fail the DB CHECK `koi_quizzes_domain_check` (`0149_koi_pool.sql:53-56`) and `LlmQuizSchema.domain`, which only accepts the 9 culture domains (`core.ts:169-182`).
4. The sensitive-word regex (`core.ts:252-316`, used through `isSensitiveText`) rejects `élèves`, `enfants`, `collégiens`, `guerres`, `génocides`, `victimes`, `morts`. That rules out most history and EMC material: WWI, WWII, the Revolution.
5. Policy conflicts:
   - `docs/noto-integration-spec.md:3` and `:259-265` say celyn has no nōto-specific logic and every change must be generic.
   - `docs/quiz-v2-contrat.md:3-4` tells agents to stop and report rather than deviate from the contract.

   So an `app=noto` profile is a **Julien decision**, not something to implement silently.

What already works today with no celyn change: the culture question of the day (3.6). Fetch `GET /api/quiz/v2/lot?app=keskonfe`, filter on device by `difficulty` (1-2 for collège) and `domain`. It has no grade filter, which is acceptable for culture questions as a stopgap.

### B.2 What celyn needs (generic framing, recommended)

Frame the work as a generic **"school" consumer** whose levels are a generic lot dimension, so it serves every consumer and fits the integration spec. The touches below come from the celyn report:

1. **App registration.**
   - Add `"ecole"` (or `"noto"`, Julien decides) to `KOI_APPS`.
   - Add a `PROFILES` entry with a new `LotShape`, domain groups by subject, and `toneQuotas` unset.
   - Add to `LAUNCH_DATES` (`jobs/generate-koi-daily.ts:98`) with a new env var in `config.ts`, following the `LECLUB_QUIZ_LAUNCH_DATE` pattern (`:125`).
2. **Migrations.** Widen `koi_daily_lots_app_check` (pattern `0176_koi_leclub_app.sql:5-6`), `koi_quizzes_domain_check` and `koi_quizzes_source_check` (`0177_koi_quiz_v2.sql:17-19`). Each must be idempotent `DROP CONSTRAINT IF EXISTS` then `ADD`, with no DROP or rename of data (`quiz-v2-contrat.md:67-68`).
3. **School domains.** Add `francais, maths, histoire, geographie, svt, physique_chimie, ses, emc, philosophie, langues` to the TS `QuizDomain` type and the CHECK.
4. **Grade dimension.**
   - Add a nullable `grade text` column on `koi_quizzes` (values = celyn grade tags `6eme…terminale`) and a nullable `curriculum_theme text`.
   - Add an optional `?grade=` param on `GET /api/quiz/v2/lot` that filters the lot's quizzes server-side.
   - Prefer one lot per day per app, filtered at read time, over a lot per grade: it keeps the unique key `(app, lot_date, edition)` untouched.
   - Alternative: a new `GET /api/quiz/v2/bank?app=&grade=&theme=&limit=` that serves pool items rather than a daily lot. This fits revisions better; daily lots fit culture. Decision for Julien. Recommendation: `bank` for programme items, `lot` for the culture question of the day.
5. **"programme" typology.**
   - Add a new `QuizSourceId` `"programme"` in `pipeline.ts:68`, plus `FRESHNESS_DAYS` (an exhaustive record, so this is a compile error until done), `sourceOf()` (`pool.ts:23`), `toneOf()` (`core.ts:158`) and its `toneSql` twin (`pool.ts:125`).
   - Grounding source: celyn's own `seed-curriculum.ts` themes and keywords, plus oeuvres tagged `curriculum_tags`.
   - Use its own LLM schema, `LlmQuizSchema.extend({domain: z.enum(SCHOOL_DOMAINS)})`, like `NoIndexSchema` in `typologies/fun-sport.ts:33`.
   - Template: `fun-sport` (explanation required, `reviewBudget: 25`, `probationUntil = date + 7`).
   - A deterministic sister typology (work↔author, dates, literary prizes from `oeuvre_awards`) should use `groundingProblems` (`core.ts:398-413`) like `award-fame.ts:29`, with no LLM.
6. **Sensitive filter.** Use a separate rule set for school content, `isSensitiveSchoolText`: keep sexual/self-harm/drug terms, but allow `élèves`, `guerres`, `génocides`, `victimes`, `morts` when the grounding source is a curriculum theme. This needs an explicit decision, because it relaxes a safety net.
7. **Prompts.** `prompts.ts:119` and the Jev request (`jev-review.ts:47`) say « quiz culturel ». They need a programme variant; the review thresholds can stay (`REVIEW_THRESHOLD`, `JEV_NOUL_MIN = 0.5`).
8. **Contract tests.** Add a new strict schema and fixture in `contract-v2.ts` and `check-koi-contract`. `LegacyApp` (`contract-legacy.ts:83`) stays untouched.

Until celyn delivers, 3.2's bundled bank is the source. Produce it with `tools/generate-questions/` reusing the same pipeline offline (plan §3.2 bis), and map `reviewed: true` to celyn's `review_method` + `review_confidence ≥ threshold`.

### B.3 Client: `Noto/Services/CultureAPI/QuizAPIClient.swift`

```swift
final class QuizAPIClient: Sendable {                 // mirrors CultureAPIClient.swift:5-26 (ephemeral session, 15 s, bundledAPIKey)
    init(baseURL: URL = URL(string: "https://celyn.io/api")!, apiKey: String = CultureAPIClient.bundledAPIKey, session: URLSession? = nil)
    func lot(app: String, date: String? = nil, grade: String? = nil) async throws -> CelynLotDTO     // GET /quiz/v2/lot
    func bank(app: String, grade: String, theme: String?, limit: Int) async throws -> [CelynQuizDTO] // GET /quiz/v2/bank (if B.2.4 alt)
    func report(quizID: UUID, reason: String?) async throws                                          // POST /quiz/v2/quiz/:id/report — parent-triggered only
}
struct CelynQuizDTO: Decodable, Sendable { id: UUID; domain; difficulty: Int; kind; question; choices: [String]; answerIndex: Int;
    explanation: String?; storyId/oeuvreId/answerOeuvreId: UUID?; oeuvreTitle/imageUrl: String?; genres: [String];
    tone: String; horizon: String?; validUntil: String?; promotedFrom: String?; edition: String?; grade: String?; curriculumTheme: String? }
struct CelynLotDTO: Decodable, Sendable { date: String; number: Int; quizzes: [CelynQuizDTO]; nextEditionAt: String? }
enum QuizMapper { static func item(from dto: CelynQuizDTO, fetchedAt: Date) -> QuizItem? }  // nil if choices.count != 4 || !(0...3 ~= answerIndex)
```

- **Validation.** Decode leniently on iOS (ignore unknown keys), but validate structure in `QuizMapper`. Re-run the four structural checks from `structuralProblems` (`core.ts:189-203`) on device and drop any failure.
- **Errors.**
  - 404 "no lot for this date" means an empty result, not an error.
  - 400 means a configuration error: log it and fall back.
  - 429 means honour `Retry-After` and fall back.
- **Corrections.** Answers arrive in clear (no hide param, `quiz-v2-contrat.md:126-129`). Correction happens on device; results are never POSTed.
- **`report`.**
  - Body: `{reason?}`.
  - Header: `x-device-id`, a **random per-install UUID** stored in the Keychain. Never a child id or a `PersistentIdentifier`.
  - Expose it only from the parent side, or from the child side behind the parent gate.
  - Tests must mock it (CLAUDE.md GET-only rule, `URLProtocol` stub).
- **Tests.** `NotoTests/Services/QuizAPIClientTests.swift` decodes fixtures copied from celyn's `contract-v2.ts` fixture; the mapper gets a 4-choice validation test.

### B.4 Caching and offline

- **Persistence.** Fetched items are persisted as `QuizItem(source: .celyn)`, upserted by `id`, with `questionKey` as the secondary dedup against bank items.
- **Expiry.** Purge items where `validUntil < today`. Keep evergreen items.
- **Fetch policy.** Cache policy is enforced in a small `actor QuizCache`, which also single-flights concurrent fetches.
  - Fetch at most once per `max-age`: respect `Cache-Control` ≤ 300 s and `nextEditionAt`.
  - Practically, fetch once at app foreground per day per grade, plus a `BGAppRefreshTask` (`BGTaskScheduler`; same local-first spirit as notifications).
- **Offline order.** Draw from cached celyn items, then the bundled bank (3.2), then homework-generated items (3.3). A quiz must always be startable with no network.
- **Reports.** Exclusions arrive server-side (report_count ≥ 3 or `excluded_at`). Re-fetches therefore implicitly drop bad items, but cached copies don't. Add a `staleAfter = 7 days` purge so excluded items stop being served.

### B.5 Privacy

- Requests carry only `app`, `date`, the grade tag (from `CurriculumService.apiGrade`) and optionally a theme string. No child name, school, grades, homework text, lat/lng or answers. The `x-api-key` is the app key, not per user.
- **Homework text must never be sent as `q`.** Send the matched `CurriculumTheme.theme` string, which is public programme vocabulary.
- **`PrivacyInfo.xcprivacy`.** `Noto/Resources/PrivacyInfo.xcprivacy` and plan §3 acceptance say « aucun nouveau flux réseau en V1 ». The quiz call is a new endpoint on an already-declared host (celyn.io), carrying no personal data and no tracking. The file must be reviewed, and the acceptance criterion re-worded to "no new host, no personal data". Flag this to Julien.
- RGPD: the bank is non-personal; attempts and mastery stay in SwiftData on device.

### B.6 Book/œuvre recommendations after a quiz

`RevisionRecoService` is built in 3.5/3.7. It takes the quiz's `(level, subject, theme)` and calls:

1. **"À lire / à voir".** `GET /api/oeuvres?type=book|film|play&grade=<apiGrade>&q=<theme words>&limit=5`. The response is camelCase, with `is_curated` forced and a hard grade filter (`oeuvres.ts:164-700`, grade at 245-249). Add `&awarded=true` for a "primé" shelf. `q` is prefix-AND across title and author, so keep only the 2-3 most distinctive theme keywords.
2. **Detail.** `GET /api/oeuvres/:id` for `awards[]`, `isbn` and `_links.placedeslibraires`. Fetch it lazily on tap, because list rows lack awards except with `sort=mentioned`.
3. **More like this.** `GET /api/recommendations/:oeuvreId?category=book&context=educational&view=compact`. It is cached 1 h server-side, and `context` is honoured on this path.
4. **Podcasts.** `GET /api/search/thematic?type=podcast&grade=…&q=…`. Read `episode_title`/`raw_title`; there is no `title`.
5. **Direct link.** When a `QuizItem` carries `oeuvreId` or `answerOeuvreId`, link straight to that work.

**Avoid `POST /api/recommendations`.**
- It ignores `context`, `age_*` and geo.
- It has no `type` field.
- It costs one Mistral embedding call plus one LLM call per request, with no cache.

**Existing `CultureAPIClient.swift` defects to fix in 3.6/3.7.** One cleanup PR, within the same phase branch:
- `parseSearchResult` defaults `type` to `"event"` and never reads `oeuvreType`, so `BriefingEngine` (~L54) shows books with the calendar icon.
- `recommendations` and `batchRecommendations` send `geo` (the server field is `location`, and ignores it anyway) and never send `grade`.
- `events()` reads `events`/`results`, but the server returns `data` (`src/routes/events.ts:632`), so it likely always returns `[]`.
- Podcast titles come out empty.
- `recommendation_reason` and `opinions` are dropped.

Before touching any of this, invoke the `/celyn` skill (CLAUDE.md rule) and read `docs/quiz-v2-contrat.md` in full. The reader did not read it.

---

## C) Roadmap for 3.2 to 3.7

### C.1 Order and dependencies

1. **3.1 Models and pure logic.** No dependencies. Simulator plus unit tests. PR 1.
2. **3.2 Bundled bank.** Depends on 3.1.
   - `Noto/Resources/questions/<niveau>/<matiere>.json` with `version` and `lastUpdated`. Items use the QuizItem shape, with `reviewed: true` required to be served.
   - Initial batch: 6e and 2nde × français, maths, histoire-géo, SVT/physique-chimie, ≥ 15 questions per theme.
   - A consistency test asserts every `theme` exists in `curriculum.json` for that level and subject.
   - `checkForUpdate` with hash/signature verification is shared with `curriculum.json` (`CurriculumService.swift:23-25`).
   - `tools/generate-questions/` is run by Julien; every question is reviewed before commit.
   - The bank is needed as the offline fallback regardless of celyn. PR 2.
3. **celyn-side B.2.** Runs in parallel, in the external repo `jtassy-stack/culture-api`. It blocks only the "programme from celyn" path, not the nōto release. It needs Julien's decisions first (C.4). The `QuizAPIClient` and cache (B.3/B.4) can ship early against `app=keskonfe` for the culture question of the day.
4. **3.5 Child app UI.** Depends on 3.1 and 3.2.
   - `Noto/Views/Child/ChildHomeView` (moved from `Noto/Views/ChildHomeView.swift`), `QuizView`, `QuizResultView`, `SubjectPathView`.
   - Child-mode copy uses tutoiement.
   - Reuse `.notoCard()`, `Typography.dataLarge` for the cagnotte, and the primary button pattern from `RootView.swift:118-128`.
   - Keep Settings behind `ParentGateView`. The gate fails open when no PIN is set (`ChildHomeView.swift:50-56`); keep that, or force PIN setup on child onboarding (it is already the `parentGateSetup` step).
   - Before 3.4 lands, the cagnotte shows earned minutes from `QuizAttempt` and unlocks nothing. Simulator OK. PR 3.
5. **3.4 Reward mechanism.** Depends on 3.1 and 3.5. **Needs a real device**: DeviceActivity and ManagedSettings do not run in the Simulator. Follow `docs/TEST_REWARD.md`. PR 4.
6. **3.6 Gamification.**
   - XP and levels per subject, from `QuizAttempt`.
   - Streak plus 2 jokers per month (stored in the ledger or on a small `@Model`, additive).
   - Badges come from `SpacedRepetition.isMastered` across a theme's notions.
   - Culture question of the day via B.1 `keskonfe` until celyn grade support lands.
   - Weekly family challenge off by default.
   - Plus the `CultureAPIClient` fixes. PR 5.
7. **3.7 Parent app.**
   - Guided `ScreenTimeView` onboarding: age profile, `RewardConfig` editor writing to the app group.
   - Révisions screen behind the PIN.
   - A `BriefingEngine` "Révisions" item in parent tone (vouvoiement), e.g. « Votre enfant a révisé 2 notions aujourd'hui ».
   - Weekly local notification on Sunday evening via `NotificationService`.
   - PR 6.
8. **3.3 Personalised generation (iOS 26).** Last, because it is optional for acceptance.
   - Needs an iOS 26 device with Apple Intelligence.
   - The commented code in `TextSummarizer.swift:37-121` uses a pseudo-API (`session.registerTool`, `respond(to:tools:)`). It must be **rewritten** against the real `Tool` protocol and `@Generable`, not just uncommented. The same applies to `BriefingTools.swift` and `MeetingExtractionService.swift:22-30`.
   - Use `@Generable struct GeneratedQuiz` and reject any answer not found in the homework text or the bank. Fall back silently. No network. PR 7.

### C.2 3.4 design constraints and risks (from the Screen Time report)

- **Dispatch.** The extension dispatches on activity name prefix only (`DeviceActivityMonitorExtension.swift:12-14`).
  - Without changes, a `noto.reward.*` activity would go through the app-limit branch of `eventDidReachThreshold`: it would add a false « Temps d'écran total » event.
  - Worse, its `intervalDidStart` (L50-55) would **lift the app-limit shield**.
  - Fix: add an explicit `hasPrefix("noto.reward.")` branch **first** in all three callbacks. Put the prefix in `Shared/ClassLockConstants.swift`, or in a new `Shared/RewardConstants.swift`.
- **Schedule budget (Apple limit of 20).**
  - Usage today is 1 app-limit schedule plus up to 10 class-lock schedules (Mon-Fri), 11 in total. The theoretical worst case is 15 (classes on all 7 days).
  - Cap simultaneous reward activities at **3**. When a 4th credit arrives, stop the oldest unconsumed activity and merge its remaining minutes into one new activity (threshold = sum).
  - Before `startMonitoring`, assert `DeviceActivityCenter().activities.count < 20` and fall back to merging.
- **Class lock invariant.**
  - `RewardUnlockService.unlock()` must first check whether `now` falls inside `ClassScheduleShieldService.computeBlocks(from: schedule)` (same test as `clearIfOutsideClassHours`, L129-149). If it does, the ledger moves the credit to `reserve` and nothing is unlocked.
  - Reward unlocks only ever touch the **default** `ManagedSettingsStore()`, never `ManagedSettingsStore(named: ClassLockConstants.storeName)`.
  - Add a unit-testable pure `RewardGate.canConsume(now:blocks:) -> Bool` and test it.
  - Releasing the reserve after class: on foreground, and on the class-lock `intervalDidEnd` in the extension, where the extension reads the ledger.
- **Extension cannot read `DeviceMode`.** It lives in `UserDefaults.standard` (`Noto/Lib/DeviceMode.swift`), not in the app group. Anything the extension needs (ledger, reward names, `RewardConfig`) goes in `Shared/RewardLedger.swift` under `group.fr.noto.app.shared`, with a versioned envelope like `ScreenTimeEventStore`. Mirror the mode into the app group if needed.
- **Existing class-lock bugs** (fix or at least track in 3.4, since the invariant depends on them):
  - `ClassScheduleShieldService.sync()` does not persist activity names when it fails mid-loop (L85-114), so it leaks schedules that `disable()` can't stop. Persist after each successful `startMonitoring`.
  - `computeBlocks` groups by weekday only (L49-77). Multi-week `Child.schedule` data merges into over-wide blocks: safe for the lock, wrong for reserve logic. Restrict it to the current ISO week.
  - Nothing re-syncs the class lock after a school sync or in the background. Call it from `FullSyncService` success.
- **Unverified.** `@objc(DeviceActivityMonitorExtension)` has no module, while `NSExtensionPrincipalClass` = `NotoDeviceActivity.DeviceActivityMonitorExtension`. It apparently works today ("proven reliable"); re-verify on device when adding branches.
- **Midnight reset.** On `intervalDidStart` of a daily activity, stop yesterday's `noto.reward.*` names (stored in the ledger) and reset daily credits. Note that only `noto.screentime.daily` gets a midnight start. If app-limit monitoring is off, register a dedicated `noto.reward.daily` (one more schedule, which is why the cap is 3 and not 5).
- **No existing tests touch the Screen Time code.** Add tests for `RewardLedger` (envelope, version mismatch, credit/consume/reserve) and `RewardGate`.

### C.3 Real device versus Simulator

| Part | Where it can be verified |
|---|---|
| 3.1, 3.2, the 3.5 UI, 3.6, the 3.7 UI, `QuizAPIClient` | Simulator plus unit tests |
| 3.4 unlock, re-shield, class-lock interplay, extension callbacks, 20-schedule limit | **Real iPhone only**, with FamilyControls authorization; follow `docs/TEST_REWARD.md` |
| 3.3 FoundationModels | **iOS 26 device** with Apple Intelligence |
| Phase acceptance: full child-mode run on a 6e and a 2nde profile, minutes credited, apps unlocked then re-locked, class lock intact | Real device; then TestFlight via `/asc-ship` |

### C.4 Decisions needed from Julien

1. **Celyn registration.** A nōto-specific `app=noto` (conflicts with `noto-integration-spec.md:3`, `:259-265`) or a generic school app profile. Also whether the contract change goes ahead, given `quiz-v2-contrat.md:3-4` says stop and report.
2. **Grade on celyn.** A `grade`/`curriculum_theme` column with `?grade=` on `/lot`, or a new `/quiz/v2/bank` endpoint (recommended for revisions).
3. **Sensitive-word filter.** A school-content exception (allow `guerres`, `victimes`, `élèves`… for curriculum-grounded items).
4. **Cap versus bonus.** Default proposed here: the +5 sits on top of the 20-minute cap, once per day. Alternative: raise the default cap to 25.
5. **Replay window.** "Identical" defaults to the same `questionKey` set ever (`.ever`); the alternative is the same day only.
6. **Leitner failure rule.** Back to box 1 (default) or down one box.
7. **Extra exam keywords.** Whether to add « devoir surveillé » to the plan's list.
8. **Persisting `ScheduleEntry.isTest`** from Pronote (additive field, lightweight-safe).
9. **V1 is 4-choice MCQ only.** The plan's `short` and `order` formats are deferred, because the celyn contract enforces exactly 4 choices.
10. **Plan correction.** Accept dropping `NotoSchemaV2.swift` in favour of appending to V1.
11. **Acceptance criterion re-worded:** « aucun nouveau flux réseau » becomes "no new host, no personal data". Also review `PrivacyInfo.xcprivacy`.
12. **Child gate.** Keep the fail-open gate when no PIN is set, or require a PIN.
13. **Plan open decision 5** (Claude API generation in the app) stays off in V1. Offline generation only, with `tools/generate-questions/` run by Julien.
14. **Replay after a rushed or failed attempt.** Rule 4 only blocks on a *passed* prior, so a child can rush (`.tooFast`) or fail a set, see the answers, then replay the identical key set slowly and earn the full tier. Option: let a prior `.tooFast` (or any prior that revealed the answers) block too; needs the denial carried on `AttemptSnapshot`.
15. **Homework-derived `QuizItem`s (RGPD).** `.homework` / `.generated` items are built from a child's homework, but `QuizItem` has no `Child` link, so deleting a child would leave them behind. Before 3.3: (a) keep them out of `QuizItem` (transient, or a child-owned `@Model` with cascade), or (b) add an optional `owner: Child?` with a cascade inverse on `Child`, used only for those sources.