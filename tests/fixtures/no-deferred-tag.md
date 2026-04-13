# Phase 09 CONTEXT.md — No deferred section tag at all (heat-check 16.1-SESSION-CONTEXT pattern)

<domain>
- Heat check alert system
- Monitors NBA hot-streak patterns
</domain>

<decisions>
- D-01: Alert threshold: 3+ consecutive games above historical average
- D-02: Push notifications via Firebase Cloud Messaging
</decisions>

<specifics>
- Rolling window: last 7 games for hot-streak calculation
- Suppression period: 24 hours after alert fires
</specifics>

## Deferred

- Migrate to WebSocket delivery for real-time alerts
- Add team-level hot-streak detection
