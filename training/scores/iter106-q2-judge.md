# Judge — Iter 106 Q2

**Topic**: Postgres-to-Iceberg ingestion
**Score**: 4.5 / 5 (Tech 4.0, Clarity 5.0, Practical 4.5, Completeness 4.5)

## Verdict
A strong, highly actionable answer that correctly identifies replica lag without a LAG_BUFFER as the most likely cause, with three well-chosen secondary failure modes and a complete backfill recovery recipe. One concrete factual bug (`partman.reapply_indexes()` is presented as a callable SQL function — it is actually a Python helper script, `reapply_indexes.py`, not a SQL-callable procedure) and one minor mischaracterization of `pushDownPredicate` (default is already `true`, so absence does not break pushdown) keep this from a perfect score. The customer-specific selectivity hint in the question ("missing for certain customers") is not explicitly addressed.

## What was verified correct (via WebSearch)
- `pg_stat_replication.replay_lag` — verified as an interval-typed column in the `pg_stat_replication` view, queried on the primary, used exactly as described.
- Replica-lag-without-buffer is a documented and well-known cause of silent row loss in watermark-based incremental JDBC loads.
- `overwritePartitions()` in dynamic mode does replace the entire partition with whatever rows the writer holds for that partition — the "12 rows replacing 8,432" data-loss scenario is technically correct and is exactly why Iceberg docs recommend MERGE INTO over INSERT OVERWRITE for late-arriving rows.
- MERGE INTO on a unique key (`event_id`) is the correct idempotent alternative and matches Apache Iceberg's official recommendation.
- LAG_BUFFER + watermark-back-off + MERGE INTO is a standard pattern and the recommended fix for the described symptom.
- `CREATE INDEX CONCURRENTLY` on pg_partman child tables is correct PostgreSQL syntax.
- The backfill recipe (read PRIMARY → MERGE INTO → reset watermark with LAG_BUFFER) is idempotent and correct.

## Errors or gaps
- **HIGH (factual bug)**: `SELECT partman.reapply_indexes('public.events');` does NOT exist as a SQL-callable function in pg_partman. `reapply_indexes` is a Python script (`reapply_indexes.py`) shipped in pg_partman's `bin/` directory, run from the shell with connection arguments, not a SQL function. An engineer who copy-pastes this will get `ERROR: function partman.reapply_indexes(unknown) does not exist`. The teacher should either replace this with the correct shell-invocation pattern or remove the suggestion and keep only the manual `CREATE INDEX CONCURRENTLY` loop.
- **MEDIUM (mischaracterization)**: "Ensure `pushDownPredicate=true` in your JDBC props so WHERE clauses execute on Postgres (not after pulling all rows to Spark)." Per Spark JDBC docs, `pushDownPredicate` defaults to `true`. Absence does not cause Spark to fetch all rows and filter in memory. The actual hazards (cast-incompatible predicates, certain non-translatable expressions) are different. Recommending the engineer set it explicitly is harmless, but the stated reason ("critical — WHERE runs on Postgres") is inaccurate.
- **MEDIUM (loose causal chain)**: "Without [an `updated_at` index], Spark JDBC does a full sequential scan ... [which] can cause the driver to time out or skip rows." Missing indexes cause slow scans and timeouts, not skipped rows; Postgres does not silently drop rows from a seq scan. Wording should be "time out" only, or be reframed as "queries time out and the partition is silently dropped by Spark retry / fail-on-task logic, depending on job config" with caveats.
- **MEDIUM (question-specific gap)**: The question explicitly notes "events from the same time window are missing for certain customers." The answer does not address why the loss would be customer-correlated. Plausible explanations worth surfacing: a per-customer connection/router pinning to one replica that lags more, customer-specific filters in the JDBC subquery, or pg_partman child-table partition pruning settings (`enable_partition_pruning`, `constraint_exclusion`) that interact poorly with a customer column. A 2-3 day intermittent gap is also unusual for replica lag (which is normally seconds-to-minutes) — worth a sentence that a 2-3 day replica lag indicates a serious replication incident, not normal jitter.
- **LOW (omission)**: No mention of `timestamptz` vs `timestamp` mismatch between Postgres and Spark/Iceberg, which is another common cause of watermark drift (UTC offset gets dropped).
- **LOW (omission)**: No mention of `pushDownPredicate` interacting with the partitionColumn/lowerBound/upperBound mode (when JDBC partitioning is used, pushdown happens differently).

## Resource fix recommendations
- **HIGH** — In `resources/13-postgres-to-iceberg-ingestion.md` (and any other resource that references it), correct or remove the `SELECT partman.reapply_indexes(...)` example. The correct usage is the shell script: `python3 reapply_indexes.py -p public.events -c "host=... user=..."` (with appropriate args), or simply recommend the manual `CREATE INDEX CONCURRENTLY` loop across `information_schema` / `pg_partman.show_partitions()` and skip the script entirely. This is the kind of "looks plausible, fails on run" bug that erodes trust in the responder.
- **MEDIUM** — In the same resource, correct the `pushDownPredicate` guidance: state the default is `true`, explain when it actually fails to push down (cast mismatches, non-translatable expressions, complex types), and recommend explicit setting only for documentation clarity, not as a fix.
- **MEDIUM** — Add a short section on "diagnosing customer-correlated missing rows" covering: replica routing/pinning per customer, per-tenant query rewrites, and partition pruning gotchas with pg_partman. The judge has seen the question "missing for certain customers" before; the responder should learn to address the selectivity hint, not just the generic "rows missing" pattern.
- **LOW** — Add a one-line note that 2-3 day replica lag is a major incident (replica likely broken or far behind, not a normal jitter pattern), and that LAG_BUFFER is sized for normal jitter (minutes), not for "replica was down for 2 days" recovery — which needs the backfill recipe.

## Updated topic state
- Postgres-to-Iceberg ingestion: 91 questions / running avg (4.485 × 90 + 4.5) / 91 = (403.65 + 4.5) / 91 = 408.15 / 91 ≈ **4.485** across 91 questions. PASSED.
