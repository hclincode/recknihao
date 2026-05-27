# Judge — Iter 104 Q2

**Topic**: Postgres-to-Iceberg ingestion
**Score**: 4.7 / 5 (Tech 4.5, Clarity 5.0, Practical 5.0, Completeness 4.5)

## Verdict
Strong, action-oriented answer that directly addresses the engineer's actual fears (locking, CPU, API slowdown) and gives a working JDBC bootstrap script with safe defaults. The replica-routing recommendation, parallel-read configuration, watermark + LAG_BUFFER pattern, and CREATE INDEX CONCURRENTLY guidance are all correct and tailored to the question. Minor gaps in throttling specifics and incomplete coverage of replica-specific risks (long-running query cancellation due to hot_standby_feedback / max_standby_streaming_delay) prevent a perfect score.

## What was verified correct (via WebSearch)
- Spark JDBC SELECT does not take exclusive locks on Postgres; default isolation is READ_COMMITTED and a plain SELECT does not block INSERT/UPDATE/DELETE. Confirmed against postgresql.org transaction-iso docs.
- `partitionColumn`, `lowerBound`, `upperBound`, `numPartitions` are valid Spark JDBC options; `upperBound` controls partition stride only — does NOT filter rows. The answer's dedicated "upperBound doesn't cap the read" callout is correct and matches Spark docs.
- `pushDownPredicate` is a valid Spark JDBC option (default true). Verified against spark.apache.org JDBC docs.
- `fetchsize` is a valid PostgreSQL JDBC option; the answer's framing (batched round-trips, prevents executor OOM) is correct. Spark sets autoCommit=false on JDBC reads, so the streaming-cursor preconditions are satisfied.
- `CREATE INDEX CONCURRENTLY` does not block writers on the table (uses ShareUpdateExclusiveLock). Correct production guidance per postgresql.org.
- `pg_stat_replication.replay_lag` is a real column and is the correct view/column for monitoring streaming replica lag. Verified against postgresql.org monitoring docs.
- MERGE INTO syntax shown matches Iceberg Spark SQL syntax (ON, WHEN MATCHED THEN UPDATE SET *, WHEN NOT MATCHED THEN INSERT *) per iceberg.apache.org spark-writes.

## Errors or gaps
- The answer says reads "do NOT block INSERT/UPDATE/DELETE on the primary" which is accurate, but it doesn't mention the more relevant replica-side risk: long-running Spark scans on a replica can be cancelled by `max_standby_streaming_delay` or, conversely, can stall replication if `hot_standby_feedback=on`. For a 300M-row scan against a replica, this is the single most common surprise.
- "Throttling" is asked about explicitly but only addressed indirectly via `numPartitions=16`. No mention of limiting concurrent JDBC connections through `numPartitions` choice tied to replica's max_connections / Spark connection-pool budget, or running off-peak.
- `numPartitions=16` is presented as a fixed recommendation without guidance on how to choose it (cores × executors, or against replica's connection budget shared with Trino on the on-prem k8s cluster per prod_info.md).
- No mention of statement_timeout or idle_in_transaction_session_timeout as safety nets on the replica.
- Minor: the answer's `df.writeTo("iceberg.analytics.events").using("iceberg").createOrReplace()` doesn't show catalog binding (`spark_catalog` vs a custom Iceberg catalog name); a reader new to Iceberg may not know `iceberg.analytics.events` requires SparkSessionCatalog configuration.
- Incremental code uses string interpolation of `last_watermark` into SQL — fine for a trusted internal value but worth flagging as parameter-safe-only.

## Resource fix recommendations
- MEDIUM: Add a short "Reading from a Postgres read replica — what can go wrong" subsection to `resources/13-postgres-to-iceberg-ingestion.md` covering `max_standby_streaming_delay`, `hot_standby_feedback` trade-off, and the canonical "ERROR: canceling statement due to conflict with recovery" error.
- LOW: Add explicit guidance on choosing `numPartitions` against the replica's connection budget (especially shared with Trino on the same on-prem cluster).
- LOW: Add a one-liner showing the `dbtable` subquery alternative for bootstraps where the partition key isn't a clean monotonic id.

## Updated topic state
- Postgres-to-Iceberg ingestion: 89 questions / running avg (4.478 × 88 + 4.7) / 89 = **4.481**
