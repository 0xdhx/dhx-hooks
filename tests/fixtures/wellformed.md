# Phase 01 CONTEXT.md — Well-formed fixture

<domain>
- Baseball statistics platform
- Covers pitching, batting, and fielding metrics
- Data sourced from Statcast and Retrosheet
</domain>

<decisions>
- D-01: Use PostgreSQL for primary storage
- D-02: REST API with JSON responses
- D-03: Rate-limit public endpoints at 100 req/min
</decisions>

<specifics>
- Pitching metrics include ERA, FIP, xFIP, SIERA
- Batting metrics include wRC+, wOBA, BABIP
- All metrics normalized to 162-game season
</specifics>

<code_context>
- `src/api/` — FastAPI route handlers
- `src/models/` — SQLAlchemy ORM models
- `src/metrics/` — Calculation engine
</code_context>

<canonical_refs>
- `docs/api-spec.md` — OpenAPI 3.0 specification
- `docs/schema.md` — Database schema reference
- `docs/metrics-glossary.md` — Metric definitions
</canonical_refs>

<deferred>
- Implement WAR calculation (complex dependency on defense metrics)
- Add GraphQL endpoint for flexible queries
- Support CSV export for bulk data consumers
</deferred>
