# Judge — Iter 103 Q2

**Topic**: Postgres-to-Iceberg ingestion
**Score**: 4.75 / 5 (Tech 4.5, Clarity 5.0, Practical 5.0, Completeness 4.5)

## Verdict
A strong, well-structured answer that correctly identifies the composite-key pattern as the standard solution for merging multiple CDC sources into one Iceberg table. It walks through the failure mode, the table design, the Debezium config, the Spark consumer wiring, and the data-residency caveat — all four legs the question implicitly asks about. Two minor caveats keep this from being a perfect score: the data-residency framing slightly understates GDPR transfer-restriction rules, and the LSN advice is correct but a touch lossy on operational nuance.

## What was verified correct (via WebSearch)
- `topic.prefix` is the correct (and required) Debezium PostgreSQL connector property; topics follow the `{topic.prefix}.{schema}.{table}` convention. The connector configs `us-prod` / `eu-prod` producing `us-prod.public.events` and `eu-prod.public.events` are accurate (debezium.io).
- Spark Structured Streaming supports `subscribe` with a comma-separated topic list — exact syntax shown matches the Spark Kafka integration guide (spark.apache.org).
- The `topic` column is part of the fixed schema returned by the Kafka source in Spark Structured Streaming, so parsing `source_region` from `col("topic")` is a valid pattern.
- Trino's MERGE INTO supports composite-key joins via `ON ... AND ...` exactly as shown (trino.io MERGE docs). Syntax for the WHEN MATCHED / WHEN NOT MATCHED clauses is correct.
- `source.lsn` is genuinely emitted in Debezium PostgreSQL change events and represents WAL position. The note that LSNs are per-source (so US and EU can collide) is accurate.
- Iceberg partitioning by `(day(event_ts), source_region)` is valid syntax and a sensible choice for per-region pruning.

## Errors or gaps
- **Data residency framing is soft.** The answer says "US data flowing to an EU cluster is typically fine" and "if it's in the US, GDPR may apply." GDPR's Chapter V transfer rules apply to *exporting* EU personal data to a third country regardless of whether the destination is "on-prem"; the answer should be firmer that ingesting EU CDC into a US-located cluster is the controlled transfer that needs an SCC/adequacy basis, not US-to-EU. The query-layer view-based isolation is correctly flagged as "enforcement at query layer only" — that nuance is good.
- **LSN operational advice is thin.** Storing `source_lsn` is fine, but the answer could note that LSN is per-replication-slot and only monotonic within a single source — useful for lag diagnosis, but not for global ordering across the two streams. A one-line caveat would have closed this.
- **No mention of late/out-of-order handling.** When two sources merge into one Iceberg table via micro-batch MERGE, consumers may see EU and US rows arrive in interleaved batches. The answer doesn't discuss ordering within a single (id, source_region) — typically resolved by `WHEN MATCHED AND s.source_lsn > t.source_lsn` to avoid clobbering newer state with older retries. Minor completeness gap.
- **No reference to `prod_info.md` on-prem constraints.** The answer touches on the "single on-prem stack" briefly in the residency section but doesn't tie back to MinIO bucket layout, which could have been a stronger physical-isolation suggestion if two clusters were needed.

## Resource fix recommendations
- **MEDIUM** — Add a short "multi-source CDC merge pattern" section to resources/13 (or wherever Postgres-to-Iceberg ingestion lives) covering: composite key in ON, source_region column convention, Debezium `topic.prefix` per source, Spark `topic` column parsing, and the `WHEN MATCHED AND s.source_lsn > t.source_lsn` idempotency guard.
- **LOW** — Add a brief note in the residency-related resource that GDPR Chapter V transfer rules apply to the *direction* of personal data movement (EU → non-EU is the controlled case) so future answers can be sharper on which direction needs legal safeguards.
- **LOW** — Note that LSN is per-source and not globally comparable across multiple Debezium connectors.

## Updated topic state
- Postgres-to-Iceberg ingestion: 88 questions / running avg 4.478
