# Phase 05 CONTEXT.md — English word "deferred" in prose

<domain>
- Scheduling platform for deferred job execution
- Background task queue with priority levels
</domain>

<decisions>
- D-01: Webhook retry logic with exponential backoff; fields deferred to v2
- D-02: Priority queue implementation deferred to late 2026 pending capacity
- D-03: Use Redis Streams as the primary queue backend
</decisions>

<specifics>
- Job states: pending, running, completed, failed, deferred
- Retry limit: 5 attempts with 15-minute max backoff
- Indefinitely deferred. Architecture supports pluggable backends
</specifics>

<code_context>
- `src/queue/` — Queue abstraction layer
- `src/workers/` — Worker pool management
</code_context>

<canonical_refs>
- `docs/queue-design.md` — Queue architecture decisions
</canonical_refs>

<deferred>
- Add dead-letter queue for failed jobs after retry exhaustion
</deferred>
