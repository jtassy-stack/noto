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

## Design

- **Figma is the source of truth for all design decisions**: https://www.figma.com/design/NGYQ1pG1IhiVfeRJMhjzpJ
- Active page: "Option B — Sobre" (dark row y=0, light row y=950)
- Every design change in code MUST be reflected in Figma
- Typography: Inter (UI), Space Mono (data/numbers only), Pixelify Sans (logo only)
- Light mode default, dark mode supported (auto via system preference)
- Palette: see `src/constants/theme.ts` — zero orange rule, 1-Up green is brand accent

## Architecture

- **Local-first**: all school data stays on-device (SQLite + SecureStore)
- **@niicojs/pawnote** for Pronote — DO NOT use `pawnote` (bug parent accounts #61)
- **PCN**: direct REST API (POST /auth/login → Conversation + Blog + Timeline)
- **Mon Lycée**: IMAP proxy (server/api/mail.js on Vercel) — only exception to privacy-first
- Screens outside ChildrenContext (Stack modals): pass child data as route params
- PCN session: 10min cache with auto-retry on 401
- Blog images: fetch direct phone→ENT, base64 inline (no proxy)

## Tab Layout (ENT children)

- Accueil → fil d'actualité (timeline)
- Notes → 📝 Blog (favorites ⭐, teacher auto-favorited)
- EDT → 📸 Photos (aggregated from favorited blogs + messages, with source filters)
- Devoirs → (pending: cahier de textes PCN)
- Messages → 📬 messagerie + 🏥 absence button (dry-run in dev)

## External References

- Notion specs: https://www.notion.so/pmfconsulting/331e0fdcdce881899db6c3c5a0b5274d
- Sprint board: https://www.notion.so/pmfconsulting/94812efc2c374cf1b0a42eeb081918f8
- Design brief: https://www.notion.so/pmfconsulting/331e0fdcdce88120b109ff193b9d808d
