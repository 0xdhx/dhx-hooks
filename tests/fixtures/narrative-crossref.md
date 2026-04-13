# Phase 06 CONTEXT.md — Narrative cross-reference to Deferred Ideas section

<domain>
- Sports analytics dashboard
- NCAA college basketball statistics
</domain>

<decisions>
- D-01: Use materialized views for season aggregate queries
- D-02: See the Deferred Ideas section — rewriting existing tests takes priority
- D-03: See the Deferred Ideas section below before finalizing caching strategy
</decisions>

<specifics>
- Season types: regular, conference tournament, NCAA tournament
- Team efficiency calculated per 100 possessions
</specifics>

<code_context>
- `src/teams/` — Team profile and roster endpoints
- `src/seasons/` — Season data ingestion
</code_context>

<canonical_refs>
- `docs/stats-glossary.md` — Statistical definitions
</canonical_refs>

<deferred>
- Implement player-level efficiency breakdown
</deferred>
