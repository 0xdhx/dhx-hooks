# Phase 15 CONTEXT.md — Non-standard section ordering (sigil phase 15/16 pattern)

<domain>
- Sigil research workflow automation
- Knowledge graph construction from literature
</domain>

<code_context>
- `src/knowledge/` — Knowledge graph builder
- `src/extraction/` — Entity extraction pipeline
</code_context>

<specifics>
- Entity types: Author, Paper, Concept, Method, Dataset
- Relation types: cites, uses, introduces, extends
</specifics>

<decisions>
- D-01: Use spaCy for NER in initial extraction pass
- D-02: Manual review queue for low-confidence extractions
</decisions>

<deferred>
- Integrate Wikidata for concept canonicalization
</deferred>

<canonical_refs>
- `docs/graph-schema.md` — Knowledge graph schema
- `docs/entity-types.md` — Entity and relation type catalog
</canonical_refs>
