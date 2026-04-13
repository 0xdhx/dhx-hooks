# Phase 03 CONTEXT.md — Empty deferred section

<domain>
- Task management API
- Multi-tenant SaaS with per-org data isolation
</domain>

<decisions>
- D-01: JWT authentication with 1-hour access tokens
- D-02: PostgreSQL row-level security for tenant isolation
</decisions>

<specifics>
- Tasks have status: todo, in_progress, done, cancelled
- Due dates stored as UTC timestamps
</specifics>

<code_context>
- `src/auth/` — JWT issue and validation
- `src/tasks/` — CRUD endpoints
</code_context>

<canonical_refs>
- `docs/api.md` — API reference
</canonical_refs>

<deferred>

</deferred>
