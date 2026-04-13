# Phase 04 CONTEXT.md — Backtick collision fixture (original forgefinder 22.1 pattern)

<domain>
- Fact-checking platform with confidence scoring
- Research citation management
</domain>

<decisions>
- D-01: Use line-anchored sed to extract sections from CONTEXT.md
- D-02: See `<deferred>` below for follow-ups on the extraction approach
- D-03: Keep the 6 standard tags as the vocabulary for now
</decisions>

<specifics>
- Confidence scores range from 0.0 to 1.0
- Citations stored with source URL and access date
- D-15: Existing CONTEXT.md `<code_context>` table is the starting point for indexing
</specifics>

<code_context>
- `src/citations/` — Citation CRUD and validation
- `src/scoring/` — Confidence calculation engine
</code_context>

<canonical_refs>
- `docs/scoring-spec.md` — Confidence framework specification
</canonical_refs>

<deferred>
- Wire up cross-reference validation between citations
</deferred>
