# Phase 23 CONTEXT.md — HTML comment containing tag name (sideline-adjacent pattern)

<domain>
- Sideline coaching analytics platform
- Real-time play suggestion engine
</domain>

<decisions>
- D-01: Suggestion engine runs on local GPU, no network dependency during games
<!-- <deferred> -->
- D-02: Audio alerts for high-confidence suggestions (confidence > 0.85)
</decisions>

<specifics>
- Play types: zone offense, man offense, press break, delay
- Suggestion model updated weekly with new game data
</specifics>

<code_context>
- `src/engine/` — Suggestion inference engine
- `src/audio/` — Alert playback module
</code_context>

<canonical_refs>
- `docs/play-types.md` — Play type taxonomy
</canonical_refs>

<deferred>
- Implement coach preference learning from accepted/rejected suggestions
</deferred>
