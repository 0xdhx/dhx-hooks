# Phase 16 CONTEXT.md — Custom tags alongside standard tags (sigil pattern)

<domain>
- Research management platform for academic papers
- Citation graph analysis and gap detection
</domain>

<decisions>
- D-01: Store citation relationships as directed graph edges
- D-02: Gap detection runs nightly via cron job
</decisions>

<specifics>
- Papers indexed by DOI and arXiv ID
- Citation depth: up to 3 hops from seed paper
</specifics>

<research_directives>
- Prioritize papers with >100 citations in gap analysis
- Focus on ML/NLP subdomain for initial corpus
- Cross-reference against existing literature review in phase 12
</research_directives>

<code_context>
- `src/papers/` — Paper ingest and deduplication
- `src/graph/` — Citation graph construction
</code_context>

<cbb_title_gaps>
- Missing 2019-2020 tournament bracket data
- Incomplete coach tenure records for mid-major programs
</cbb_title_gaps>

<canonical_refs>
- `docs/graph-schema.md` — Citation graph data model
</canonical_refs>

<deferred>
- Add semantic similarity clustering for related-paper suggestions
</deferred>
