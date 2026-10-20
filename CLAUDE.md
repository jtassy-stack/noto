# nōto. — Project Instructions

## Privacy — ALWAYS TOP OF MIND

- **NEVER transit credentials through a proxy or third-party server**
- **NEVER store credentials on a server** — only in iOS Keychain via `KeychainService`
- **NEVER hard-code API keys in source** — build-time keys (celyn directory + culture-api) live in **Infisical** (org "PMF consulting", EU, project `noto` / slug `noto-ios`, envs `dev` + `prod`). `ci_scripts/write-xcconfig.sh` pulls them into `Config.xcconfig` (gitignored), optionally included by the committed `Config.base.xcconfig` → Info.plist → client. Empty keys on a fresh clone, never a build break. CI fetches them via a GitHub OIDC machine identity (`vars.INFISICAL_IDENTITY_ID`), no GitHub secret. Rotate keys in Infisical only. `gitleaks` runs in CI and as a pre-commit hook (`git config core.hooksPath .githooks`)
- **Photos of children** must go phone ↔ school server ONLY, never through any third party
- **Notifications** are local-first: background fetch + local notification, no push server
- Before implementing any feature, evaluate privacy impact FIRST
- If a feature requires server-side credential storage, flag it and propose alternatives
- RGPD compliance is non-negotiable

## Tone — PARENT-ADDRESSED (vouvoiement), CHILD MODE TUTOIEMENT

- In `DeviceMode.parent`, all text, summaries, and briefings address **parents**, not students
- "Votre enfant a 5 cours aujourd'hui" — never "Tu as 5 cours"
- LLM prompts explicitly instruct: "Tu t'adresses au parent, pas à l'élève"
- Applies to: BriefingEngine, InsightEngine, greeting messages
- **Only exception**: `DeviceMode.child` (child app, quizzes, rewards) addresses the child with tutoiement — "Ta cagnotte : 12 min"

## Scope — COLLÈGE & LYCÉE

- Product scope is **6e → Terminale**. Primary (CP → CM2) gets no question bank, no revision path, no priority connector work
- Roadmap: `docs/PLAN_REVISIONS_KMP_ANDROID.md` (one branch + one PR per phase)

## Screen Time — CLASS LOCK IS ABSOLUTE

- **The class-hours shield (`ClassScheduleShieldService`) is never lifted by earned reward credit.** Minutes earned during a class block go to reserve, never consumed

## Testing

- **LIVE APIs with REAL accounts** — never send messages, create drafts, or modify data
- Tests must be **GET-only** — no POST, PUT, DELETE to live APIs
- Unit tests: mock all API calls, test pure logic (parsing, filtering, formatting)
- If testing POST behavior, mock the URLSession call

## Stack

- **SwiftUI + SwiftData** — iOS 17+ minimum deployment target
- **Swift 6 strict concurrency** — all async code must be actor-isolated or Sendable
- **XcodeGen** — `project.yml` is the source of truth for project structure; `.xcodeproj` is generated
- **pawnote-bridge** — `@niicojs/pawnote` bundled as `pawnote-bundle.js` (763 KB, esbuild), executed via JavaScriptCore (`PawnoteBridge.swift`)
- **Core ML on-device** — `TrendAnalyzer` (linear regression), `InsightEngine`
- **Apple FoundationModels** — iOS 26+ with graceful fallback to rule-based text generation
- **culture-api** — `https://celyn.io`, `x-api-key` header auth, client in `Services/CultureAPI/`; supports `?grade=` filtering with `3eme`-style grade format
- **KeychainService** — all credentials (Pronote refresh token, culture-api token, etc.)
- **CIDetector** — QR code scanning for Pronote login (photo picker → CIDetector, no live camera required)

## Architecture

### SwiftData Models (`Noto/Models/`)
- `Family` — top-level container, one per app install
- `Child` — belongs to Family, has school type (pronote/ent)
- `SchoolData` — grades, schedule entries, homework, messages (attached to Child)
- `Insight` — generated insights per Child
- `CultureReco` — culture-api recommendations per Child
- `Curriculum` — curriculum reference data
- `LessonContent` — cahier de textes lesson contents + homework kept across syncs (local only, never sent anywhere; purged at the school-year start or on a level change)

### Services (`Noto/Services/`)
- `PawnoteBridge` — JavaScriptCore wrapper around `pawnote-bundle.js`; exposes async Swift API
- `PronoteSyncService` — orchestrates sync via PawnoteBridge, writes to SwiftData
- `FullSyncService` — runs a full sync for a set of children across every connector; always called through `SyncCoordinator.requestSync` (de-dup + 60 s cooldown on automatic attempts). Launch/foreground initial syncs are triggered from `RootView` (AddChild flows run their own first sync in-sheet); each sync service stamps `Child.lastSyncedAt` on success
- `BriefingEngine` — priority-scored briefing items + LLM context string
- `TrendAnalyzer` — Core ML linear regression on grade history
- `CultureAPIClient` — REST client for `https://celyn.io` with grade-filtered thematic search
- `CurriculumService` — loads bundled `curriculum.json` (subjects carry `track` `tronc_commun`/`specialite` + optional `specialty`), maps grades to API format (`3e` → `3eme`), extracts BO culture topics. Revisions path = `CurriculumService.revisionLevels` (6e → Tle; CP → CM2 kept in the JSON for Discover only). `themes`/`matchKeywords` take the child's `specialties` (`Child.specialties`, empty = unknown → all spécialités eligible), resolve Pronote labels through the `SubjectAlias` table (`HISTOIRE-GEOGRAPHIE` → Histoire + Géographie union, `SC. ECONO.& SOCIALES` → SES…), and match keywords < 4 chars (`adn`, `pib`) on whole words only
- `CurriculumMatcher` — matches homework/chapter text to curriculum keywords for culture-api queries
- `FamilySync/` — phase 9 (family sync, CloudKit shared zone per child, cadrage in `/mnt/project-files/sync-famille/CADRAGE.md`). 9.1 = `FamilySyncRecord` + payloads (`SyncedAttempt`, `SyncedNotion`, `SyncedJoker`, `SyncedDayMinutes` child → parent; `SyncedRules` parent → child), results only (no question keys, no school data), every field in `CKRecord.encryptedValues`. 9.2 = pairing: `FamilySyncLink` (flag `FAMILY_SYNC_ENABLED` in the xcconfig → Info.plist `NotoFamilySyncEnabled`, default NO: `CKContainer(identifier:)` traps without the iCloud entitlement, so no CloudKit call runs while it is off; random zone names `enfant-<uuid>`), `FamilySyncShareService` (parent: zone + zone-wide `CKShare`, title « nōto », invited recipients only, read-write; child: validated `accept`), invitations routed by `NotoAppDelegate`/`NotoSceneDelegate` → `FamilySyncInbox` → confirmation alert in `RootView`, parent screen `Settings/FamilyLinkView`; zone kept on `Child.familySyncZoneName`/`familySyncZoneOwner`/`familySyncLinkedAt`. 9.3 = `FamilySyncEngine` (plain async `CKDatabase` calls, no `CKSyncEngine`, no push: launch + foreground from `RootView` with a 60 s cooldown, `BGAppRefresh` `fr.noto.app.familySync`, closing Réglages › Révisions on the parent): child device (zone with an owner) sends attempts / notions / jokers / day minutes when their fingerprint changed and applies the parent's rules (`FamilySyncRulesApplier` → `RewardConfigStore` + culture / défi toggles, read only in `RevisionSettingsView` while linked); parent device sends its rules and writes the child's records into its own `Child` (`FamilySyncIngest`, matched by id, no question keys); change tokens, sent fingerprints and the child's day minutes in `FamilySyncStateStore` (UserDefaults, per zone); a deleted zone unlinks the child device; `Child.familySyncLastSyncedAt` stamps each sync. 9.4 = sync status in the UI (`FamilySyncLink.syncedText` = this device's last sync, `receivedText` = the child's last upload from `Child.familySyncReceivedAt` (latest CloudKit modification date of the child's records), `noRevisionsText` / `noMinutesText` wait only until the child's phone sent something, `reserveText`; `Child.receivesFamilySync` = parent device with a linked child): Accueil, Écran, Réglages › Révisions, `FamilyLinkView` (« Synchroniser maintenant »), vision enfant; the « sur l'appareil où X fait ses quiz » copy only shows while unlinked. Device test list: `docs/FAMILY_SYNC_DEVICE_CHECKLIST.md`. The app carries the iCloud entitlement, so every `ModelConfiguration` passes `cloudKitDatabase: .none`: SwiftData's default would mirror the whole store (school data included) to iCloud
- `ProgrammePositionTracker` — pure, on-device: from `LessonContent` + homework, infers per subject the current and already-covered programme themes; `QuizSourceSelector` / `QuizSession` only quiz on those (subjects without a position fall back to the current + earlier periods). Fed by `LessonContentStore` (Pronote onglet 89 via the hand-patched `fetchLessonContents` in `pawnote-bundle.js`, École Directe per-day `cahierdetextes/<date>.awp`, every connector's homework)

### View Structure (`Noto/Views/`)
- `RootView` — authentication gate (Keychain check → onboarding or main)
- `OnboardingView` — family setup + first child login
- `MainTabView` — parent tab bar: Accueil · École · Messages · Écran · Découvrir
- `Home/` — `HomeView`: briefing dashboard (À traiter, 48 h), then « Cette semaine » per child (`ParentWeekSection`: synthesis line, 4-week revision heatmap, notions per subject, 8-week average sparkline, weakest notion → `ParentQuizView`, « Ce que X étudie » → Découvrir); figures in `Services/ParentWeekReport.swift`
- `Actualites/` — `ActualitesView` (Messages tab): child / parent pills, week volume per source, « À traiter » (Signer / Justifier / Répondre, keyword rules in `Services/MessageTriage.swift`, unread only) then « Pour information »
- `Ecran/` — `ScreenOverviewView` (Écran tab): quiz bonus of the day vs the cap, last 7 days, class hours the lock covers, barème; opens `RevisionSettingsView` and `ScreenTimeView`. Shows minutes earned, never app usage. Quiz and reward data exist on the device where the child plays, and on the parent's once the child's phone is linked (family sync 9.3, « Synchronisé il y a … » + today's class reserve under the cards); unlinked, the revision and minute cards say where they live
- `School/` — `SchoolView` with sub-tabs: Notes · EDT · Devoirs · Messages
- `Insights/` — `InsightsView`: trends, strengths/weaknesses, weighted averages
- `Discover/` — `DiscoverView`: grade-filtered culture-api recommendations with curriculum tag badges
- `Culture/` — `CultureQuizView`: culture G quiz (10 questions) for the parent (Découvrir) and the child (child home, behind the parent's « Culture générale » toggle), drawn from the celyn culture bank (`GET /api/quiz/v2/bank/culture`: every reviewed « Koi ? » culture G question, synced page by page with the keyset cursor + tombstones, hourly at most) kept on device, with the daily lots of Keskonfé, Sirius, Le Club as fallback when the bank route is unavailable; child pool filtered by `CultureQuizFilter` (domains, no actu, difficulty, `ChildSafeText`); reward-free; logic in `Services/Quiz/CultureQuizPool.swift`
- `AddChild/` — child onboarding flow (QR scan + Keychain storage)
- `Child/` — `DeviceMode.child` app (tutoiement): `ChildHomeView` = 5 tabs — `ChildTodayView` (Aujourd'hui: cagnotte, série, contrôle de demain, journée avec devoirs sous chaque cours et verrou des cours, quiz du jour « après les cours »), `ChildCoursesView` (Mes cours: tous les devoirs à faire par jour, emploi du temps, notes par matière avec moyenne pondérée — notes masquables par le parent via « Afficher les notes » dans Réglages › Révisions, `ChildGradesSettings`, ON par défaut; logique pure dans `Services/ChildCourses.swift`), `ChildReviseView` (Réviser: quiz du jour et sa composition via `QuizSession.plan`, quiz d'une matière, culture sans minutes), `SubjectPathView` (Parcours: une matière à la fois, thème en cours en tête, « Réviser ce thème » sur les thèmes déjà vus), `ChildMeView` (Moi: série du mois, badges, défi famille au total commun, Réglages behind `ParentGateView`); `QuizView`, `QuizResultView` (gains first, score as subtitle, « Tes notions », new badges); a subject / theme quiz = `QuizFocus` passed to `QuizSession`; quiz logic in `Services/Quiz/QuizSession.swift`. Child colours: amber = série only, « à revoir » / en cours = cobalt. « Vision enfant » : `ParentWeekSection` (Accueil parent) opens `ChildHomeView(previewChild:)` — the same child app, read only (no quiz, culture answer, joker or Réglages; reward status neutral, class lock not claimed), under `ChildPreviewBanner` (vouvoiement). Quiz, série and badges stay empty there unless the child's phone is linked (`sync-famille/CADRAGE.md`)

## Pronote Protocol

- Login uses QR code: user photographs QR from Pronote web → `CIDetector` extracts URL → `PawnoteBridge.login(qrUrl:)`
- Refresh token stored in Keychain as `PronoteRefreshToken_<childId>`
- `PawnoteBridge` calls pawnote JS functions via `JSContext`; results are JSON-decoded to Swift types
- Do NOT use the `pawnote` npm package (bug with parent accounts #61) — only `@niicojs/pawnote`
- Grades are always weighted by coefficients and normalized to /20

## Briefing / AI Fallback Chain

1. **Apple FoundationModels** (iOS 26+) — on-device LLM summary
2. **BriefingEngine text generator** — rule-based French natural language (no ML required)
3. **Raw briefing items** — structured list fallback

## XcodeGen Workflow

```bash
# Once per clone — build-time API keys (never committed), pulled from Infisical:
infisical login                    # once per machine
ci_scripts/write-xcconfig.sh       # writes Config.xcconfig from env "dev"

# After editing project.yml:
xcodegen generate

# Build & run:
open Noto.xcodeproj   # then select simulator + Cmd+R
```

Never edit `Noto.xcodeproj` directly — it is regenerated from `project.yml`.

## Simulator Testing (XcodeBuildMCP)

Use XcodeBuildMCP tools for build/run/test. Simulator IDs follow the format:
`com.apple.CoreSimulator.SimDeviceType.iPhone-16` or use `list_sims` to find the exact ID.

Before the first build in a session, call `session_show_defaults` to verify project/scheme/simulator.

## Key Files

| Path | Purpose |
|------|---------|
| `project.yml` | XcodeGen config — source of truth for project structure |
| `Noto/Services/Pronote/PawnoteBridge.swift` | JSCore bridge to pawnote-bundle.js |
| `Noto/Services/Pronote/PronoteSyncService.swift` | Sync orchestration |
| `Noto/Services/BriefingEngine.swift` | Briefing + AI context builder |
| `Noto/Services/ML/TrendAnalyzer.swift` | Core ML grade trend analysis |
| `Noto/Services/CultureAPI/CultureAPIClient.swift` | culture-api REST client |
| `Noto/Lib/KeychainService.swift` | Keychain read/write for all credentials |
| `Resources/pawnote-bundle.js` | esbuild bundle of @niicojs/pawnote (763 KB) |

## External References

- Notion specs: https://www.notion.so/pmfconsulting/331e0fdcdce881899db6c3c5a0b5274d
- Sprint board: https://www.notion.so/pmfconsulting/94812efc2c374cf1b0a42eeb081918f8
- culture-api: https://celyn.io

### culture-api Integration Guide

**Before modifying culture-api integration**, invoke the `/celyn` skill to load the full API reference, endpoint docs, and nōto-specific patterns (curriculum matching, batch recommendations, grade filters).

Integration guide: `https://celyn.io/portal/wiki#api/integration-noto.md`
