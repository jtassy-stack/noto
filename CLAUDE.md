# nōto. — Project Instructions

## Privacy — ALWAYS TOP OF MIND

- **NEVER transit credentials through a proxy or third-party server**
- **NEVER store credentials on a server** — only encrypted on device (SecureStore)
- **Photos of children** must go phone ↔ school server ONLY, never through Vercel/AWS/any third party
- **Notifications** must be local-first: background fetch + local notification, no push server
- **IMAP proxy** is the ONE exception (stateless, per-request, no storage) — migrate to direct fetch if possible
- Before implementing any feature, evaluate privacy impact FIRST
- If a feature requires server-side credential storage, flag it and propose alternatives
- RGPD compliance is non-negotiable

## Tone — PARENT-ADDRESSED

- All text, summaries, and briefings address **parents**, not students
- "Votre enfant a 5 cours aujourd'hui" — never "Tu as 5 cours"
- LLM prompts explicitly instruct: "Tu t'adresses au parent, pas à l'élève"
- This applies to: briefing engine, text generator, insights, greeting messages

## Design

- **Figma is the source of truth for all design decisions**: https://www.figma.com/design/NGYQ1pG1IhiVfeRJMhjzpJ
- Active page: "Production" (previously "Option B — Sobre")
- Every design change in code MUST be reflected in Figma
- Typography: Inter (UI), Space Mono (data/numbers only), Pixelify Sans (logo only)
- Light mode default, dark mode supported (auto via system preference)
- Palette: see `src/constants/theme.ts` — zero orange rule, 1-Up green is brand accent

## Testing

- **LIVE APIs with REAL accounts** — never send messages, create drafts, or modify data
- Tests must be **GET-only** — no POST, PUT, DELETE to live APIs
- Unit tests: mock all API calls, test pure logic (parsing, filtering, formatting)
- Absence feature: MUST stay in **dry-run mode** during dev
- If testing POST behavior, mock the fetch call

## Architecture

- **Local-first**: all school data stays on-device (SQLite + SecureStore)
- **@niicojs/pawnote** for Pronote — DO NOT use `pawnote` (bug parent accounts #61)
- **PCN**: direct REST API (POST /auth/login → Conversation + Blog + Timeline + Schoolbook)
- **Mon Lycée**: IMAP proxy (server/api/mail.js on Vercel) — only exception to privacy-first
- **SQLite client**: async mutex (initPromise) prevents race condition crashes
- **child_settings** table: extensible key-value per child (message_source, etc.)
- Screens outside ChildrenContext (Stack modals): pass child data as route params
- PCN session: 10min cache with auto-retry on 401
- Blog images: fetch direct phone→ENT, base64 inline (no proxy)

## Briefing System (src/lib/briefing/)

- **engine.ts**: `buildBriefing()` (Pronote) + `buildEntBriefing()` (ENT) — priority-scored items + LLM context
- **text-generator.ts**: French natural language summaries from structured data (no ML required)
- **insights.ts**: `extractTextInsights()` (trends, strengths/weaknesses) + `extractStats()` (weighted /20 averages)
- **Fallback chain**: Apple FoundationModels (iOS 26+) → text-generator → raw briefing items
- **On-device ML module**: `modules/on-device-ml/` — Expo native module, Swift FoundationModels, Kotlin no-op
- Grades are always weighted by coefficients and normalized to /20

## Tab Layout

### Pronote children
- Accueil → briefing dashboard (period picker: Jour/Semaine/Semestre, AI summary, stats, insights)
- Notes → grades with weighted averages (/20 with coefficients)
- EDT → schedule (cancelled classes with strikethrough + red "Annulé" badge)
- Devoirs → homework list
- Messages → Pronote discussions OR IMAP (configurable via message_source setting)

### ENT children (PCN)
- Accueil → ENT briefing (schoolbook words, messages, blog)
- Notes → Blog (favorites, teacher auto-favorited)
- EDT → Photos (aggregated from favorited blogs + messages)
- Carnet → split view: schoolbook words (top) + documents (bottom), with download/view
- Messages → PCN Conversation

### Message source preference
- Per-child setting: "pronote" | "ent" | "both"
- Set at first login or in Settings (gear icon in tab bar)
- Stored in child_settings table

## Key API Endpoints (PCN/ENT)

- Schoolbook: `/schoolbook/list/0/{entChildId}` (NOT `/schoolbook/list` alone)
- Schoolbook word detail: `/schoolbook/word/{wordId}`
- Documents in schoolbook: extracted from HTML (`/workspace/document/` links)
- Timeline: `/timeline/lastNotifications` with pagination

## External References

- Notion specs: https://www.notion.so/pmfconsulting/331e0fdcdce881899db6c3c5a0b5274d
- Sprint board: https://www.notion.so/pmfconsulting/94812efc2c374cf1b0a42eeb081918f8
- Design brief: https://www.notion.so/pmfconsulting/331e0fdcdce88120b109ff193b9d808d
- TestFlight: v0.1.0 (build 7) — latest includes UX redesign + parent-addressed tone
