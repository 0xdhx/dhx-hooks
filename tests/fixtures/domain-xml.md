# Phase 12 CONTEXT.md — Domain XML tags in prose (heat-check / ncaa-statforge pattern)

<domain>
- Baseball Retrosheet XML data processing
- Parses event files containing play-by-play data
</domain>

<decisions>
- D-01: Parse `<play>`, `<v>`, `<hitseason>` records from Retrosheet XML
- D-02: Store `<pchseason>` and `<innsummary>` data in separate tables
- D-03: Ignore `<stats>` root node; extract children directly
</decisions>

<specifics>
- Retrosheet event XML uses `<play>`, `<v>`, `<hitseason>`, `<pchseason>`, `<stats>`, `<innsummary>` tags
- Each `<play>` element has at, b, s, o attributes
- Season aggregates live in `<hitseason>` and `<pchseason>` children of `<v>`
</specifics>

<code_context>
- `src/parsers/retrosheet.py` — Retrosheet XML event file parser
- `src/models/play.py` — Play-by-play ORM model
</code_context>

<canonical_refs>
- `docs/retrosheet-format.md` — Retrosheet XML format reference
</canonical_refs>

<deferred>
- Support multi-season batch imports from Retrosheet archive
</deferred>
