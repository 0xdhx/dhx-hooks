# No deferred tag — all items under ## Deferred header are resolved

<domain>
- Analytics pipeline
- Batch processing of event streams
</domain>

<decisions>
- D-01: Use Kafka for event ingestion
- D-02: Aggregate to hourly buckets in S3
</decisions>

<specifics>
- Event schema versioned via Avro registry
- Backfill window: 30 days max
</specifics>

## Deferred

- ~~**Real-time dashboard** -- stream aggregates to frontend~~ [assessed: deferred to v3, see DASH-10]
- ~~**Schema migration tooling** -- automate Avro schema upgrades~~ [assessed: handled by platform team via PLAT-44]
