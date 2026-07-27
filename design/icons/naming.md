# Icon naming rules

- Lowercase, hyphenated, named for domain function: `approve.svg`, never
  `check-green.svg`; `agent.svg`, never any vendor or model name.
- App tiles are named exactly after their `applications/` package:
  `contacts.svg` (not `people.svg`), `calendar.svg`, `agents.svg`.
- No patch-history or filler qualifiers (see PLATFORM_SPEC §23).
- Suffix `-glyph` only where a Family 1 name would collide with a Family 2
  tile (`camera-glyph`, `calendar-glyph`, `clock-glyph`).
- Every glyph ships with an accessible name in the icon registry; the build
  fails on a glyph without one.
