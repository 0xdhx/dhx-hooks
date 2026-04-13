# Mixed deferred header — some resolved, some unresolved (empty deferred tag)

<domain>
- Sprint planning assistant
- Tracks backlog and deferred ideas across milestones
</domain>

<decisions>
- D-01: Deferred items live under ## Deferred Ideas header outside the tag
- D-02: Resolved items carry strikethrough + marker
</decisions>

<deferred>
</deferred>

## Deferred Ideas

- ~~**Already tracked item A** -- auto-assign tickets to sprints~~ [existing: TICKET-01]
- **Unresolved item B** -- needs assessment for sprint tooling
- ~~**Already tracked item C** -- bulk-close resolved items~~ [captured: backlog entry]
- **Unresolved item D** -- new idea for notification batching

## Implementation Notes

Standard sprint workflow applies. Items under Deferred Ideas are reviewed at end of each milestone.
