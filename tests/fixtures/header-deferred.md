# Phase 08 CONTEXT.md — Empty deferred tag + markdown header with bullets (ncaa-statforge phase 08 pattern)

<domain>
- NCAA basketball scraper with stop/cancel/resume support
- Handles partial ingestion gracefully
</domain>

<decisions>
- D-01: Cancel scrape via keyboard interrupt; persist partial results
- D-02: State file tracks last completed game ID for resume
</decisions>

## Deferred Ideas

- Resume from partial state using the state file
- Save partial output to temp file before cancel propagation
- Auto-cancel on timeout after 30 minutes of no new games

## Implementation Notes

Scraper runs per conference, processes 5 games in parallel. State stored in `.scrape-state.json` per conference.

<specifics>
- Scraper runs per conference, processes 5 games in parallel
- State stored in `.scrape-state.json` per conference
</specifics>

<code_context>
- `src/scraper/` — Main scraping loop
- `src/state/` — State file read/write
</code_context>

<canonical_refs>
- `docs/scraper-design.md` — Scraper architecture
</canonical_refs>

<deferred>

</deferred>
