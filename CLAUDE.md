# nōto. — Project Instructions

## Privacy — ALWAYS TOP OF MIND

- **NEVER transit credentials through a proxy or third-party server**
- **NEVER store credentials on a server** — only in iOS Keychain via `KeychainService`
- **Photos of children** must go phone ↔ school server ONLY, never through any third party
- **Notifications** are local-first: background fetch + local notification, no push server
- Before implementing any feature, evaluate privacy impact FIRST
- If a feature requires server-side credential storage, flag it and propose alternatives
- RGPD compliance is non-negotiable

## Tone — PARENT-ADDRESSED

- All text, summaries, and briefings address **parents**, not students
- "Votre enfant a 5 cours aujourd'hui" — never "Tu as 5 cours"
- LLM prompts explicitly instruct: "Tu t'adresses au parent, pas à l'élève"
- Applies to: BriefingEngine, InsightEngine, greeting messages

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

### Services (`Noto/Services/`)
- `PawnoteBridge` — JavaScriptCore wrapper around `pawnote-bundle.js`; exposes async Swift API
- `PronoteSyncService` — orchestrates sync via PawnoteBridge, writes to SwiftData
- `BriefingEngine` — priority-scored briefing items + LLM context string
- `TrendAnalyzer` — Core ML linear regression on grade history
- `CultureAPIClient` — REST client for `https://celyn.io` with grade-filtered thematic search
- `CurriculumService` — loads bundled `curriculum.json`, maps grades to API format (`3e` → `3eme`), extracts BO culture topics
- `CurriculumMatcher` — matches homework/chapter text to curriculum keywords for culture-api queries

### View Structure (`Noto/Views/`)
- `RootView` — authentication gate (Keychain check → onboarding or main)
- `OnboardingView` — family setup + first child login
- `MainTabView` — tab bar (Home / School / Insights / Discover / Settings)
- `Home/` — `HomeView`: briefing dashboard, period picker, AI summary
- `School/` — `SchoolView` with sub-tabs: Notes · EDT · Devoirs · Messages
- `Insights/` — `InsightsView`: trends, strengths/weaknesses, weighted averages
- `Discover/` — `DiscoverView`: grade-filtered culture-api recommendations with curriculum tag badges
- `AddChild/` — child onboarding flow (QR scan + Keychain storage)

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
