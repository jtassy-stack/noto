# nōto. — Project Instructions

## Design

- **Figma is the source of truth for all design decisions**: https://www.figma.com/design/NGYQ1pG1IhiVfeRJMhjzpJ
- Active page: "Option B — Sobre" (dark row y=0, light row y=950)
- Every design change in code (colors, typography, spacing, layout, new screens) MUST be reflected in Figma
- Typography: Inter (UI), Space Mono (data/numbers only), Pixelify Sans (logo only), Instrument Serif (taglines)
- Light mode default, dark mode supported (auto via system preference)
- Palette: see `src/constants/theme.ts` — zero orange rule, 1-Up green is brand accent

## Architecture

- Local-first: all school data stays on-device (SQLite + SecureStore)
- Zero school data on server — RGPD compliant
- Providers: Pronote (Pawnote.js), ÉcoleDirecte, Skolengo
- Child switcher is persistent in tab header (visible on all screens)

## External References

- Notion specs: https://www.notion.so/pmfconsulting/331e0fdcdce881899db6c3c5a0b5274d
- Sprint board: https://www.notion.so/pmfconsulting/94812efc2c374cf1b0a42eeb081918f8
- Design brief: https://www.notion.so/pmfconsulting/331e0fdcdce88120b109ff193b9d808d
