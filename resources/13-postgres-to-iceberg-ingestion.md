# Postgres to Iceberg: The Complete Ingestion Guide

> You have data in Postgres. Your CTO wants it queryable from Trino in the lakehouse. This guide walks the full journey: patterns, JSONB handling, a Spark job skeleton, the Hive Metastore wiring, and how to schedule it.
>
> Production stack: Apache Spark + Iceberg 1.5.2 + MinIO (S3) + Hive Metastore + Trino 467, all on Kubernetes on-prem.

---

## TL;DR

- Three ingestion patterns: full refresh (simplest), incremental append (most common), CDC (advanced).
- Start with full refresh for small tables; move to incremental once a table passes ~10M rows.
- JSONB doesn't exist in Parquet — flatten the top 5–10 hot keys into real columns, keep the rest as a VARCHAR fallback.
- Spark reads Postgres via JDBC, writes Iceberg to MinIO, registers the table in Hive Metastore.
- Schedule with Airflow or a Kubernetes CronJob, then always run compaction and snapshot expiration.

---

## The three ingestion patterns

### Pattern A — Full refresh (start here)

Every night, read the entire Postgres table with Spark JDBC and overwrite the Iceberg table. For full-table refresh of a small dimension table, this is the right shape:

```python
df = spark.read.jdbc(url=PG_URL, table="public.plans", properties=PG_PROPS)
# Truly replace the table contents — every row gone, new rows in.
df.writeTo("iceberg.analytics.plans").using("iceberg").createOrReplace()
```

> **Danger — read this carefully.** In Spark Iceberg, `createOrReplace()` means "**drop the entire table and create it again with these rows.**" It is the correct API for whole-table refresh of a small dimension. It is the **wrong** API any time you only want to replace one day, one tenant, or one partition — using it for partition-scoped overwrite will delete every other partition in the table. For partition-scoped overwrite, use `overwritePartitions()` (see "Idempotency and cleanup" below).

- **When to use:** small dimension tables under ~10M rows where you want a clean rebuild every night.
- **Pros:** simplest possible job. No state to track.
- **Cons:** drops and rebuilds the table — any in-flight readers see an empty/changed table briefly. Heavy load on Postgres. Do not use on fact tables that other jobs append to.

### Pattern B — Incremental append (the common case)

Read only rows changed since the last run, then append to Iceberg.

```python
last_ts = read_watermark()  # e.g. from a small state file in MinIO
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM public.events WHERE updated_at > '{last_ts}') sub",
    properties=PG_PROPS,
)
df.writeTo("iceberg.analytics.events").append()
write_watermark(df.agg({"updated_at": "max"}).collect()[0][0])
```

> **WARNING — append() is NOT idempotent.** If this job restarts (k8s pod rescheduled, CronJob retry, operator re-runs `spark-submit` because it looked stuck), every row in the watermark window is inserted again and your event counts double. A job that failed at step 5 (writing the watermark) will re-read the same window on retry and append those rows a second time. Use `overwritePartitions()` instead for production fact table ingestion — see the idempotent pattern directly below.

**The idempotent alternative — `overwritePartitions()` with a fixed batch window:**

Instead of a mutable watermark, pass the batch date as a job parameter. The job reads exactly one day's worth of rows from Postgres, then atomically replaces that day's partition in Iceberg. Re-running for the same `batch_date` produces exactly the same result — no duplicates, no matter how many times the job runs.

```python
# SAFE: overwrite only yesterday's partition, idempotent on re-run.
# batch_date is passed as a CLI argument, e.g. --batch-date 2026-05-22
batch_date = "2026-05-22"
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE date(occurred_at) = '{batch_date}') t",
    properties=PG_PROPS,
)
df.writeTo("iceberg.analytics.events").overwritePartitions()
```

Why this is safe:
- `overwritePartitions()` is **atomic** — Iceberg's snapshot isolation means readers see either the old partition or the fully-written new one, never a partial state mid-overwrite.
- `overwritePartitions()` is **idempotent** — re-running with the same `batch_date` replaces the same partition with the same rows. Event counts stay correct.
- Only the partitions present in `df` are replaced. Every other day's partition is untouched.

Contrast with `createOrReplace()`: that replaces the **entire table** — every partition, every tenant, every day — in a single operation. Never use `createOrReplace()` on a partitioned production fact table for day-scoped refresh; use `overwritePartitions()`.

- **When to use:** tables over 10M rows, you need same-day freshness.
- **Requires:** an `updated_at` (or `created_at`) timestamp on every source row. Add the column to your Postgres tables if missing — it is the foundation of the whole pipeline.
- **Handling deletes:** hard `DELETE`s in Postgres are *invisible* to incremental loads — the row just stops appearing. Adopt soft deletes: a `deleted_at` column, never `DELETE FROM`.
- **Watermark storage:** a tiny JSON file in MinIO (`s3a://watermarks/events.json`) is fine. Don't over-engineer.

### Late-arriving events — the `overwritePartitions()` data-loss trap

Late-arriving events are the most common silent data-loss scenario in incremental ingestion. The setup that produces the bug looks innocent: you switch your watermark column from `occurred_at` to `updated_at` (because soft-deletes and back-edits in the source bump `updated_at` but not `occurred_at`), keep the Iceberg table partitioned by `day(occurred_at)`, and continue using `overwritePartitions()` because "it's idempotent." Then, three weeks later, you discover the events table is missing tens of thousands of rows for random old days.

> **WARNING — `overwritePartitions()` replaces the ENTIRE partition with whatever rows are in your DataFrame.** Under an `updated_at` watermark, if today's batch pulls only 12 late-arriving rows for `day(occurred_at) = 3 days ago` (because a mobile client just came back online and synced its buffered events), calling `overwritePartitions()` will **wipe ALL prior rows for that day's partition** — potentially thousands of legitimate events written in earlier runs — and leave only those 12 rows. This is silent data loss. No error is raised. The query layer keeps returning numbers; the numbers are just wrong.
>
> Concrete timeline:
> 1. **May 20**: nightly job ingests all of May 20's events. The `day(occurred_at) = '2026-05-20'` partition now contains 8,432 events. Good.
> 2. **May 23**: a mobile app reconnects and POSTs 12 events from May 20 (the `occurred_at` is May 20, but `updated_at` is set to the May 23 receive time). Postgres now has those 12 late rows.
> 3. **May 23 nightly job**: the watermark filter `WHERE updated_at > '2026-05-22 23:59:00'` picks up exactly those 12 late rows. The DataFrame has 12 rows whose `day(occurred_at) = '2026-05-20'`.
> 4. **`overwritePartitions()` runs**: Iceberg sees the DataFrame contains rows for the May 20 partition, **replaces the entire May 20 partition** with the 12 rows it received, and discards the 8,432 rows that were there before.
> 5. **Tuesday morning**: an analyst notices the May 20 funnel report dropped from 8,432 sessions to 12. By then, three more nightly runs have happened with similar bugs.

**Fix options** (pick one — do not skip):

1. **Use MERGE INTO instead of `overwritePartitions()`.** MERGE INTO only modifies rows matched by the join key, leaving unmatched rows intact. The 8,432 existing rows are untouched; the 12 late rows are inserted (or, if any match an existing `event_id`, updated in place). This is the correct shape for any pipeline where late-arriving rows are possible.

   ```python
   df.createOrReplaceTempView("events_delta")
   spark.sql("""
       MERGE INTO iceberg.analytics.events AS t
       USING events_delta AS s
       ON t.event_id = s.event_id
       WHEN MATCHED THEN UPDATE SET *
       WHEN NOT MATCHED THEN INSERT *
   """)
   ```

2. **If you must use `overwritePartitions()`, re-read ALL rows for any affected day partition.** Before writing, expand the DataFrame to cover the full partition — not just the watermark delta. The write must contain every row that should exist in the partition, because `overwritePartitions()` interprets the DataFrame as the new authoritative content of that partition.

   ```python
   # Step 1: identify which day partitions were touched by the watermark delta.
   delta_df = read_postgres_delta(last_ts)  # the 12 late rows
   affected_days = [r.day for r in delta_df.selectExpr(
       "date_trunc('day', occurred_at) AS day"
   ).distinct().collect()]

   # Step 2: re-read every row from Postgres for those days — not just the delta.
   day_filter = " OR ".join(f"date(occurred_at) = '{d}'" for d in affected_days)
   full_partition_df = spark.read.jdbc(
       url=PG_URL,
       table=f"(SELECT * FROM events WHERE {day_filter}) t",
       properties=PG_PROPS,
   )

   # Step 3: overwritePartitions() with the COMPLETE partition contents.
   full_partition_df.writeTo("iceberg.analytics.events").overwritePartitions()
   ```

   Option 1 (MERGE INTO) is strictly safer and is the default recommendation. Option 2 exists for cases where MERGE INTO is too slow on a very large fact table — but it adds a costly extra full-partition Postgres read on every late-arriving day.

**For pg_partman setups specifically — use the UNION-two-months pattern in the nightly job.** If your Postgres source uses pg_partman, the ongoing nightly job should always read `this month + last month` as a UNION with the watermark filter (see Fix #1 in the pg_partman section below). This catches cross-boundary late arrivals — e.g., events with `occurred_at = April 29` uploaded May 5 — without any extra re-run logic. The pattern is:

```python
# Read this month + last month, filtered by watermark.
# Catches: (1) new events in this month, (2) late arrivals near month boundary.
table=(
    f"(SELECT * FROM events_{this_month} WHERE updated_at > '{last_ts}' "
    f" UNION ALL "
    f" SELECT * FROM events_{last_month} WHERE updated_at > '{last_ts}') t"
)
```

For late arrivals that land in a partition older than last month (mobile device offline for 2+ weeks), a scheduled monthly re-run of the target partition is needed — see the pg_partman late-arrival re-run recipe in the section below.

**Watermark lag buffer recipe.** Even with the right write strategy, the watermark itself needs a small safety margin. **Calibrate the lag buffer to your observed P99 replica lag, doubled as a safety margin — typically 15-30 minutes for most Postgres replica configurations.** A 4-hour buffer (which earlier versions of this guide recommended as a "safe default") is overly conservative and creates 4 hours of unnecessary data delay while re-reading 4 hours of data on every batch run — significant wasted Postgres I/O on large tables. Use:

```python
from datetime import timedelta

# Tune to your observed P99 replica lag (typically 15-30 minutes for healthy replicas).
# Measure your actual lag for a week before picking a number — many production replicas
# are well under 5 minutes P99, in which case 15 minutes is a 3x safety margin.
LAG_BUFFER = timedelta(minutes=15)  # adjust based on your replica's observed P99 lag

new_watermark = max_updated_at - LAG_BUFFER
write_watermark(new_watermark)
```

**How to size the buffer.** Query your monitoring system (or `pg_stat_replication.replay_lag` on the primary) for the past 7 days of replica lag. Take the P99. Double it as a safety factor for transient spikes (network blips, vacuum storms, replica catch-up after a momentary outage). That's your `LAG_BUFFER`. Common results:

| Observed P99 replica lag | Recommended LAG_BUFFER |
|---|---|
| < 5 minutes (healthy replica) | 15 minutes |
| 5-15 minutes | 30 minutes |
| 15-60 minutes (struggling replica) | 2 hours — and fix the replica |
| > 1 hour | The replica is broken; do not paper over it with a giant buffer |

Why the lag at all: rows that arrived in Postgres very close to the watermark boundary may not yet be fully committed or visible to a read replica at the moment the job ran. A lag buffer means the next run re-reads the boundary window and recaptures any rows that were in-flight last time. Combined with MERGE INTO, re-reading the boundary window is safe: matched rows are updated in place, not duplicated.

**Tradeoff: read the watermark delta from PRIMARY vs REPLICA.** For small/medium tables (under ~100 GB), reading the watermark delta directly from the **PRIMARY** eliminates the replica-lag hazard entirely — there is no replay window to worry about because you're reading the authoritative source. The cost is adding one incremental-read query's load to the primary on each run (typically small, since the watermark filter is an index lookup). For large tables, reading from a replica is preferred to offload the analytical read from the primary — but it requires the lag buffer above plus the `pg_last_xact_replay_timestamp()` cap (see the next subsection). Default: PRIMARY for tables under 100 GB or under 10M rows; REPLICA for anything larger.

**Postgres `updated_at` index preflight.** Before switching your watermark column from `created_at` (which is usually the primary-key-correlated insertion column and effectively indexed) to `updated_at`, **verify `updated_at` is indexed in Postgres.** An unindexed watermark column causes a full-table scan on every incremental run — fine for a 100K-row table, catastrophic for a 50M-row table. The check:

```sql
-- Run in Postgres before deploying the watermark change.
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'events'
  AND indexdef LIKE '%updated_at%';
```

If the result is empty, create an index before the next ingestion run:

```sql
-- CONCURRENTLY avoids taking a long write lock on the events table.
CREATE INDEX CONCURRENTLY idx_events_updated_at ON events (updated_at);
```

Skip this preflight and you will discover the missing index when the nightly job runs for 4 hours instead of 4 minutes and the Postgres primary goes into degraded state from a full-table sequential scan.

**Partition spec stays correct under an `updated_at` watermark.** A common follow-up question: "If I'm filtering by `updated_at` to read the delta, should I repartition the Iceberg table by `day(updated_at)` too?" **No.** The watermark column governs which Postgres rows you pull on each run. The partition column governs how analyst queries prune files at read time. Analysts almost always filter by `occurred_at` (funnels are "users who did X in the week of May 1"; cohort analysis is "users who first signed up in March"; time-series dashboards group by event time). So keep `partitioned by day(occurred_at)` — that is still the right partition column for query-pruning. The watermark and partition column serve different purposes and do not need to be the same.

### Reading from pg_partman-partitioned Postgres tables

Many SaaS Postgres deployments use **pg_partman** (a PostgreSQL extension that manages declaratively-partitioned tables, typically time-ranged) to keep large fact tables manageable — `events` becomes a parent table with monthly child partitions `events_2024_01`, `events_2024_02`, ..., `events_2026_05`. From a SQL standpoint, queries against the parent table transparently fan out to the right child partitions. From a **Spark JDBC** standpoint, this transparency comes with surprising costs that you need to know about before deploying ingestion against a partman-managed source.

**Root cause of the JDBC startup hang.** When Spark reads from a pg_partman parent table via JDBC, the pgjdbc driver issues metadata queries against `pg_inherits`, `pg_class`, `pg_attribute`, and `information_schema` to resolve the partition hierarchy — figuring out which child tables exist, what their column lists are, and how they map to the parent. This metadata scan is **O(number of child partitions)**. A table with 24 monthly partitions (2 years of history) can take 30–60 seconds *just for the initial metadata fetch* before any data flows. With 5 years of monthly partitions (60 children), the metadata scan can run several minutes — long enough that Spark's session initialization appears hung and operators kill the job assuming it's broken.

**Fix #1 (highest impact): read specific child partitions, not the parent.** Instead of querying the parent `events` table (which forces metadata resolution across every child), scope the `dbtable` subquery to the specific child partitions you actually need for the current run. For an incremental job, that's typically this month's partition (where new rows land) and last month's partition (for late-arriving rows near a month boundary):

```python
from datetime import date, timedelta

today = date.today()
this_month = today.strftime("%Y_%m")                      # e.g., "2026_05"
last_month_first = (today.replace(day=1) - timedelta(days=1)).replace(day=1)
last_month = last_month_first.strftime("%Y_%m")           # e.g., "2026_04"

# Read only the two relevant child partitions — pgjdbc does NOT scan the full
# partman hierarchy because we're naming concrete child tables.
df = spark.read.jdbc(
    url=PG_URL,
    table=(
        f"(SELECT * FROM events_{this_month} WHERE updated_at > '{last_ts}' "
        f" UNION ALL "
        f" SELECT * FROM events_{last_month} WHERE updated_at > '{last_ts}') t"
    ),
    properties=PG_PROPS,
    column="id",
    lowerBound=min_id,   # derive dynamically — see Fix #4
    upperBound=max_id,
    numPartitions=16,
)
```

The startup time drops from "30+ seconds of unexplained hang" to "essentially instant."

**Fix #2: `pushDownPredicate=true`.** Add `"pushDownPredicate": "true"` to the JDBC properties. This is the canonical Spark JDBC option that guarantees `WHERE` clauses are pushed down to Postgres for **server-side** filtering. Without it, predicate-pushdown behavior depends on the JDBC dialect and driver version — and on some combinations, Spark pulls every row and filters in-memory on the executor, defeating the entire point of having a watermark filter.

```python
PG_PROPS = {
    "user": PG_USER,
    "password": PG_PASS,
    "driver": "org.postgresql.Driver",
    "pushDownPredicate": "true",   # ensure WHERE clauses run on Postgres, not Spark
    "fetchsize": "10000",          # see Fix #6
}
```

**Fix #3: per-child-partition indexes.** Each pg_partman child table needs an index on the watermark column (`updated_at`) **independently**. Adding an index to the parent table does **not** automatically backfill existing child tables — the exact behavior depends on PostgreSQL version (15+ propagates new indexes to future children but not historical ones via default `CREATE INDEX`) and on pg_partman configuration. Check what's actually there:

```sql
-- Run in Postgres. Lists every child partition's index on updated_at, or absence thereof.
SELECT tablename, indexname, indexdef
FROM pg_indexes
WHERE tablename LIKE 'events_%'
  AND indexdef LIKE '%updated_at%'
ORDER BY tablename;
```

If older children are missing the index, add it concurrently per child (so the index build doesn't lock writers):

```sql
CREATE INDEX CONCURRENTLY idx_events_2024_01_updated_at
    ON events_2024_01 (updated_at);

CREATE INDEX CONCURRENTLY idx_events_2024_02_updated_at
    ON events_2024_02 (updated_at);
-- repeat per child, or script it
```

Or use pg_partman's helper to reapply the parent's index set across all children:

```sql
SELECT partman.reapply_indexes('public.events');
```

Skip this step and a Spark job that reads from `events_2024_01 WHERE updated_at > X` does a full sequential scan of the entire 2024-01 child partition, every night, forever.

**Fix #4: derive `lowerBound` / `upperBound` dynamically — do NOT hardcode.** A common copy-paste mistake is to leave `upperBound=1_000_000_000` (or some other big number) in the Spark JDBC reader from the original Pattern B example. With pg_partman this causes catastrophic partition skew: one Spark task gets the slice from `id=937_500_000` to `id=1_000_000_000` (almost all the rows in the child partition, because real IDs cluster in a narrow band), while the other 15 tasks get empty slices and finish instantly. The job runs serial-effectively on one executor. Derive bounds from the actual data:

```python
# Cheap query — both min(id) and max(id) are index lookups on the child's PK.
bounds_row = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT min(id) AS lo, max(id) AS hi FROM events_{this_month}) t",
    properties=PG_PROPS,
).collect()[0]
min_id, max_id = bounds_row.lo, bounds_row.hi
```

Then pass `lowerBound=min_id` and `upperBound=max_id` to the main read.

**Fix #5 (already covered in "How lowerBound / upperBound / numPartitions actually work" above):** even with dynamic bounds, wrong bounds only cause skew — never data loss. Spark folds out-of-range rows into the first or last partition; it never drops them.

**Fix #6: `fetchsize` JDBC parameter.** Add `"fetchsize": "10000"` (or similar) to the JDBC properties. The pgjdbc driver's default fetch size is small — sometimes as low as 10 rows per network roundtrip in certain client configurations — which creates thousands of round-trips on a multi-million-row read. Bumping it to 10,000 typically halves the network time. Numbers between 5,000 and 50,000 are reasonable; go higher only if executor memory allows.

**Summary checklist before deploying ingestion against a pg_partman source:**

1. Scope `dbtable` subqueries to specific child partitions (this month + last month), not the parent.
2. Set `pushDownPredicate=true` in JDBC properties.
3. Verify every child partition has an index on the watermark column; backfill missing ones with `CREATE INDEX CONCURRENTLY` or `partman.reapply_indexes`.
4. Derive `lowerBound` / `upperBound` from `min(id)` / `max(id)` of the child partition you're reading, not hardcoded.
5. Set `fetchsize` to 10,000 or higher in JDBC properties.
- **Reading from a read replica? Check replica lag on the REPLICA, not the primary.** If your ingestion job reads from a Postgres read replica (common for off-loading analytical reads from the primary), you must subtract the current replica lag from your watermark window — otherwise you'll skip rows that the primary has committed but the replica hasn't replayed yet. The lag check uses Postgres's built-in function `pg_last_xact_replay_timestamp()`, which returns the timestamp of the last transaction the replica has replayed.
>
>  **Critical: `pg_last_xact_replay_timestamp()` must be called on the REPLICA connection, not the primary.** On the primary, this function returns `NULL` — it only tracks replay progress on standbys (because the primary doesn't replay WAL, it generates it). A common bug is to issue the lag check via the same connection URL as the rest of the job (often the primary), see `NULL`, and conclude "no lag" — when in reality the replica may be hours behind. Always open a separate connection to the replica explicitly to run this check.
>
>  ```python
>  # Use the REPLICA connection URL for the lag check — NOT the primary URL.
>  # On the primary, pg_last_xact_replay_timestamp() returns NULL.
>  REPLICA_URL = "jdbc:postgresql://pg-replica:5432/app"   # <-- replica, not primary
>  lag_df = spark.read.jdbc(
>      url=REPLICA_URL,
>      table="(SELECT pg_last_xact_replay_timestamp() AS replay_ts) t",
>      properties=PG_PROPS,
>  )
>  replay_ts = lag_df.collect()[0].replay_ts
>  # Cap the watermark window at replay_ts so we never read past what the replica has seen.
>  safe_upper = min(now_utc(), replay_ts)
>  ```
>
>  If your ingestion job's `dbtable` subquery reads from the replica (e.g., `jdbc:postgresql://pg-replica:5432/...`), use the replica URL for the lag check too. If you have multiple replicas behind a load balancer, the lag may differ between them — query each one or pin the ingestion job to a single replica for the duration of the run.

### Detection recipe: already-missed rows after a replica lag incident

If you suspect (or have been alerted) that a replica lag spike caused the last few incremental runs to skip rows, you do **not** need to do a full table reload. Run this three-step detection-and-backfill recipe instead. It compares the max watermark column in Iceberg to the max in Postgres **PRIMARY** (the ground truth, not the lagging replica), then backfills only the missed window using an idempotent MERGE INTO.

```python
# Step 1: Find the gap — compare max(updated_at) in Iceberg vs Postgres PRIMARY.
# Read Iceberg first (cheap — metadata-only scan with proper partitioning).
iceberg_max = spark.sql(
    "SELECT max(updated_at) as ts FROM iceberg.analytics.events"
).collect()[0].ts

# Connect to PRIMARY (not replica) for ground truth — this is the whole point.
# A replica may itself be behind, which would underreport the gap and hide the problem.
pg_max_row = spark.read.jdbc(
    url=PG_PRIMARY_URL,  # PRIMARY, not replica
    table="(SELECT max(updated_at) AS ts FROM events) t",
    properties=PG_PROPS,
).collect()[0].ts

gap_minutes = (pg_max_row - iceberg_max).total_seconds() / 60
print(f"Iceberg is behind by {gap_minutes:.1f} minutes")
# If gap_minutes > expected lag buffer (e.g., 15-30 min), a backfill is needed
# for the window [iceberg_max, pg_max_row].
```

If `gap_minutes` is within your expected `LAG_BUFFER`, no action is needed — the next normal incremental run will pick the gap up. If it's significantly larger (e.g., you ran with `LAG_BUFFER=15min` but the gap is 4 hours), the lag-spike caused some rows to fall outside the next run's watermark window and they will never be picked up by the regular pipeline. Backfill them now.

```python
# Step 2: Backfill the missed window. Read from PRIMARY for the gap window.
missed_df = spark.read.jdbc(
    url=PG_PRIMARY_URL,
    table=(
        f"(SELECT * FROM events "
        f" WHERE updated_at BETWEEN '{iceberg_max}' AND '{pg_max_row}') t"
    ),
    properties=PG_PROPS,
)
```

```python
# Step 3: MERGE INTO — idempotent, safe to re-run.
# MERGE INTO updates existing rows (in case the gap window also contains rows that
# were partially captured) and inserts the truly missed ones. Re-running this step
# multiple times produces the same final state.
missed_df.createOrReplaceTempView("events_backfill")
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_backfill s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

Why each step matters:
- **Step 1 uses PRIMARY for the right-hand side of the comparison.** If you query the replica for `max(updated_at)`, you may underreport the gap because the replica is the thing that's behind. Always compare Iceberg against the primary's authoritative max when diagnosing data freshness.
- **Step 2 reads from PRIMARY.** This is a one-shot backfill, not a recurring load, so the extra primary-side load is acceptable. The whole point of the backfill is that the replica missed these rows — reading the replica again would re-miss them.
- **Step 3 uses MERGE INTO, not `append()`.** If the backfill window overlaps with rows already in Iceberg (very likely — the boundaries are conservative), `append()` would create duplicates. `MERGE INTO` handles overlap idempotently. You can safely re-run step 3 if it fails midway.

After the backfill, advance your watermark to `pg_max_row - LAG_BUFFER` so the next normal incremental run picks up from the same boundary as if no incident had happened.

### Soft-delete sync pattern

Most SaaS Postgres schemas don't run `DELETE FROM users` — they run `UPDATE users SET deleted_at = now() WHERE id = ?`. The row stays in Postgres so the app can show deletion audit trails, support GDPR delete-vs-anonymize choices, and recover from accidental deletes. When you sync these tables to Iceberg, you have to decide where deleted rows are filtered out: in the query layer, in the storage layer, or at ingest time. **You almost certainly want all three, in order of urgency.**

**Layer 1 — Immediate protection: a Trino view that pre-filters deleted rows.** This is the first thing to ship because it can be deployed today with no Spark job change and protects every downstream analyst, dashboard, and BI tool from accidentally seeing soft-deleted rows. The base table still contains the soft-deleted rows; the view hides them.

```sql
-- Run in Trino. Analysts should query the _active view, never the base table.
CREATE OR REPLACE VIEW iceberg.analytics.events_active AS
SELECT * FROM iceberg.analytics.events WHERE deleted_at IS NULL;
```

Grant SELECT on `events_active` to analyst roles and revoke direct access to `iceberg.analytics.events` for those roles (same pattern as the multi-tenant view discipline in resource 05). With this in place, no dashboard or ad-hoc query can accidentally include soft-deleted rows even if the engineer writing the SQL forgets the `WHERE deleted_at IS NULL` filter.

**Layer 2 — Periodic physical cleanup: actually remove the bytes from MinIO.** The view hides deleted rows from queries but does **not** reduce storage. After enough soft-deletes accumulate, you need to physically purge the rows from Iceberg. This is a three-step sequence — **all three steps are required**, in this order:

```sql
-- Step 1: Issue the DELETE against Iceberg. This creates positional delete files
-- (small marker files that say "rows N, M, P in data file X are deleted").
-- The underlying Parquet data files are NOT yet rewritten.
DELETE FROM iceberg.analytics.events
WHERE deleted_at IS NOT NULL;
```

```sql
-- Step 2: Compact + apply the deletes into NEW Parquet files. Spark reads each
-- affected data file, drops the positionally-deleted rows, and writes a new
-- Parquet file without them. A new snapshot points at the new files.
-- IMPORTANT: at this point storage usage on MinIO has GROWN, not shrunk —
-- the OLD Parquet files still exist because the PRIOR snapshot still references them.
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events'
);
```

```sql
-- Step 3: Expire the prior snapshots so the old Parquet files become unreferenced
-- and get physically deleted from MinIO. ONLY after this step does storage drop.
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp() - interval '7' day,
  retain_last => 1
);
```

**Why all three steps are needed:** step 1 hides rows from queries via delete files but writes no new data. Step 2 produces new clean Parquet files but leaves the old ones referenced by the prior snapshot — storage actually grows. Step 3 is the **only** step that removes bytes from MinIO. If you skip step 3, storage never recovers and your "GDPR delete" is not actually a delete on disk (see resource 05's GDPR section for the full audit-trail implications).

Schedule the layer-2 sequence as a weekly Spark job. For GDPR-specific erasures (a specific user invoking their right to be forgotten), run the sequence on demand with `older_than => current_timestamp() - interval '0' day, retain_last => 1` to immediately expire every snapshot that could still contain the user's bytes.

**Layer 3 — Optional: Filter at ingest time.** You can also push the `WHERE deleted_at IS NULL` filter into the JDBC subquery so soft-deleted rows never enter Iceberg in the first place:

```python
# Filter at ingest — soft-deleted rows are not appended to Iceberg.
df = spark.read.jdbc(
    url=PG_URL,
    table=(
        f"(SELECT * FROM events "
        f" WHERE updated_at > '{last_ts}' "
        f"   AND deleted_at IS NULL) t"
    ),
    properties=PG_PROPS,
)
df.writeTo("iceberg.analytics.events").append()
```

> **WARNING — this approach silently leaves zombie rows in Iceberg.** The filter only excludes rows that were already soft-deleted *at the moment the JDBC read ran*. Consider this very common timeline:
>
> 1. **Monday's ingest run**: row `event_id=42` is fresh, `deleted_at IS NULL`. It is read from Postgres and appended to Iceberg with `deleted_at = NULL`.
> 2. **Wednesday in Postgres**: the user soft-deletes `event_id=42` (`UPDATE events SET deleted_at = now() WHERE event_id = 42`).
> 3. **Thursday's incremental ingest**: the row is now excluded by the `AND deleted_at IS NULL` filter — so it is **not** re-read, and the existing Iceberg row is **not** updated. The Iceberg copy still has `deleted_at = NULL` and shows up in `events_active`.
>
> The row is now a zombie: deleted in Postgres, alive in Iceberg, invisible to your "delta since last watermark" logic, never going to get cleaned up automatically. Layer 3 alone is not safe for tables where rows get soft-deleted **after** their first ingest — which describes basically every production table.
>
> **Required mitigation if you use layer 3:** schedule a periodic reconciliation MERGE INTO that re-syncs the `deleted_at` column for all rows visible in Iceberg, e.g., weekly read the full set of `(event_id, deleted_at)` pairs from Postgres for rows with `deleted_at IS NOT NULL` in the last 30 days, then `MERGE INTO iceberg.analytics.events` to update the `deleted_at` column for matching rows. After the MERGE, run the layer-2 cleanup sequence to physically remove them.

**Recommended combination for most SaaS tables:** Layer 1 (always) + Layer 2 (weekly) + skip Layer 3 unless your Postgres table is so large that re-reading soft-deleted rows on every incremental run is a measurable cost. The layer-3 zombie-row problem is harder to detect than it is to avoid.

**Future state — CDC via Debezium.** The clean long-term solution for high-mutation tables is CDC: Debezium captures every `UPDATE ... SET deleted_at` event from the Postgres WAL as a row-change message and pushes it to Kafka. A Spark Structured Streaming job consumes the stream and drives a **hard DELETE** in Iceberg as soon as the Postgres soft-delete commits. This eliminates the zombie-row problem entirely (the soft-delete UPDATE is captured the moment it commits, regardless of incremental watermark windows) and gives you sub-minute delete propagation. Cost: ~3x more moving parts (Debezium connector, Kafka, streaming consumer, exactly-once semantics). Worth it for tables where soft-deletes are frequent (e.g., a `messages` table where users delete sent messages all day); overkill for an `accounts` table where churn is monthly. See Pattern C below for the broader CDC setup.

### Pattern C — CDC (Change Data Capture) — advanced

Debezium reads the Postgres write-ahead log (WAL), publishes row-change events to Kafka, Spark Structured Streaming consumes from Kafka and merges into Iceberg.

- **When to use:** you need < 5 minute freshness, or you must capture hard DELETEs and UPDATEs accurately.
- **Complexity:** ~3x more moving parts (Debezium, Kafka, streaming job, exactly-once semantics). Don't start here.
- **On-prem reality:** Debezium and Kafka both run on Kubernetes; the prod stack supports it, but you own the ops burden.

---

## The JSONB problem

Your Postgres `events` table almost certainly has a `properties JSONB` column. **Parquet has no native JSON type.** You must decide at ingest time how to handle it.

### Option 1: store as VARCHAR

Write the whole JSON blob as a string. Query with Trino's `json_extract_scalar`:

```sql
SELECT json_extract_scalar(properties, '$.device_type'), COUNT(*)
FROM iceberg.analytics.events
GROUP BY 1;
```

- **Pro:** simplest, lossless, schema-flexible.
- **Con:** slow — Trino re-parses the JSON string on every query.

### Option 2: flatten hot fields into real columns (recommended)

In the Spark job, extract the top 5–10 most-queried JSON keys into typed columns. Keep the original blob as `properties_raw VARCHAR` for the long tail.

```python
from pyspark.sql.functions import get_json_object

df = df.withColumn("device_type", get_json_object("properties", "$.device_type")) \
       .withColumn("plan_at_event", get_json_object("properties", "$.plan_at_event")) \
       .withColumn("feature_name", get_json_object("properties", "$.feature_name")) \
       .withColumnRenamed("properties", "properties_raw")
```

- **Pro:** the columns you actually filter and group by become first-class, partition-prunable, columnar-compressed.
- **Con:** if you add a new hot field, you must alter the Iceberg schema (cheap: metadata-only via `ALTER TABLE ADD COLUMN`). Old rows return **NULL** for the new column automatically — no backfill is required unless you specifically need non-NULL values in historical records (in which case, one Spark job reads all old rows and rewrites them with the extracted value).

**Rule of thumb:** flatten anything you `GROUP BY`, `WHERE`, or `JOIN ON`. Leave the rest in `properties_raw`.

**Working with nested arrays:** Use `get_json_object(col, "$.tags[0]")` to extract by index. For checking array membership, `get_json_object(...).contains("enterprise")` is a substring match on the JSON string — it would incorrectly match "enterprise-plus". For exact array containment, use `array_contains` after parsing with `from_json`:

```python
from pyspark.sql.functions import from_json, array_contains
from pyspark.sql.types import ArrayType, StringType

tags_schema = ArrayType(StringType())
df = df.withColumn("tags_array", from_json(get_json_object("properties", "$.tags"), tags_schema)) \
       .withColumn("has_enterprise_tag", array_contains(col("tags_array"), "enterprise"))
```

For simple low-cardinality cases (e.g., extract the first tag), extract by index: `get_json_object("properties", "$.tags[0]")`.

---

## Spark job skeleton (pseudo-code)

This is the shape of a real ingestion job. Not production-ready, but structurally complete.

```python
from pyspark.sql import SparkSession
from pyspark.sql.functions import get_json_object, current_timestamp, row_number
from pyspark.sql.window import Window

spark = (SparkSession.builder
    .config("spark.sql.catalog.iceberg", "org.apache.iceberg.spark.SparkCatalog")
    .config("spark.sql.catalog.iceberg.type", "hive")
    .config("spark.sql.catalog.iceberg.uri", "thrift://hive-metastore:9083")
    .config("spark.sql.catalog.iceberg.warehouse", "s3a://lakehouse/warehouse")
    .config("spark.hadoop.fs.s3a.endpoint", "http://minio:9000")
    .config("spark.hadoop.fs.s3a.path.style.access", "true")
    .getOrCreate())

last_ts = read_watermark("events")

# 1. Read from Postgres with partition pushdown (parallelism)
df = (spark.read.format("jdbc")
    .option("url", "jdbc:postgresql://pg-primary:5432/app")
    .option("dbtable", f"(SELECT * FROM events WHERE updated_at > '{last_ts}') t")
    .option("user", PG_USER).option("password", PG_PASS)
    .option("partitionColumn", "id")
    .option("lowerBound", 0).option("upperBound", 1_000_000_000)
    .option("numPartitions", 16)
    .load())

# 2. Flatten hot JSONB fields
df = (df
    .withColumn("device_type",  get_json_object("properties", "$.device_type"))
    .withColumn("plan_at_event", get_json_object("properties", "$.plan_at_event"))
    .withColumnRenamed("properties", "properties_raw")
    .withColumn("batch_loaded_at", current_timestamp()))

# 3. Deduplicate on event_id (Postgres retries can produce dupes)
w = Window.partitionBy("event_id").orderBy(df.updated_at.desc())
df = df.withColumn("_rn", row_number().over(w)).filter("_rn = 1").drop("_rn")

# 4. Append to Iceberg
df.writeTo("iceberg.analytics.events").append()

# 5. Advance watermark
new_ts = df.agg({"updated_at": "max"}).collect()[0][0]
write_watermark("events", new_ts)
```

Key points:
- `partitionColumn` / `numPartitions` parallelize the JDBC read — without it, one Spark task drags the whole Postgres table through one connection.
- `batch_loaded_at` is your audit column for "when did this row arrive in the lake."
- Dedup is *defensive* — assume Postgres has duplicates from retries.

### How lowerBound / upperBound / numPartitions actually work

This is one of the most misunderstood settings in Spark JDBC. Read this before adjusting the numbers.

**What they do**: `lowerBound`, `upperBound`, and `numPartitions` together determine how Spark splits the `partitionColumn` range into parallel read tasks. Spark divides `[lowerBound, upperBound)` into `numPartitions` equal-width strides and issues one JDBC query per stride.

**What they do NOT do**: they do not filter rows. Every row in the table (or the subquery you pass to `dbtable`) is always returned, regardless of the bounds. Rows with IDs below `lowerBound` are folded into the first partition's query. Rows with IDs above `upperBound` are folded into the last partition's query. No rows are ever dropped.

**The actual risk of wrong bounds — partition skew, not data loss**: if `upperBound` is much lower than the real max ID (e.g., you set `upperBound=1_000_000` but the table has grown to 50M rows), the last partition's query covers a huge range (`id >= 937_500` all the way to infinity). All 49M "out-of-bound" rows land in that one partition. Spark's parallelism collapses: 15 tasks finish quickly and 1 task does almost all the work. The query takes much longer than it should, but all rows still come back.

**Practical guidance**:
- Set `upperBound` to a recent `SELECT MAX(id) FROM events` value, or a slight overestimate.
- Getting it wrong means one partition is slower than the others — not missing data.
- For an incremental job that only reads new rows (via the `dbtable` subquery filter), set `upperBound` to the max ID in that row window, not the max ID in the whole table.

```python
# Good practice: estimate upperBound from a recent COUNT before the job runs.
# Even a stale estimate is fine — wrong bounds cause skew, not data loss.
df = (spark.read.format("jdbc")
    .option("url", "jdbc:postgresql://pg-primary:5432/app")
    .option("dbtable", f"(SELECT * FROM events WHERE updated_at > '{last_ts}') t")
    .option("partitionColumn", "id")
    .option("lowerBound", 0)
    .option("upperBound", 1_000_000_000)  # overestimate is fine — no rows are dropped
    .option("numPartitions", 16)
    .load())
```

---

## Idempotency and cleanup

> **Read this section before your first production run.** It will save you from an outage. Every Spark ingestion job will eventually run twice by accident — a CronJob retry, a backfill that overlapped with the regular run, a manual `spark-submit` that completed after the operator thought it had failed. When that happens, your event counts double. You need three tools, in order of "safest first."

### The three cleanup tools

| Tool | Scope | Risk level | Speed | When to use |
|---|---|---|---|---|
| `CALL iceberg.system.rollback_to_snapshot` | Entire table — back to a prior version | Lowest (ACID, no data lost) | Instant (metadata only) | Just-happened double-load; nothing else has written since |
| `df.writeTo("...").overwritePartitions()` | Only the partitions present in `df` | Low (other partitions untouched) | Fast (rewrites partition files) | Re-running a specific day or tenant after a bad batch |
| `DELETE FROM ... WHERE ...` | Row-level (any predicate) | Medium (writes Iceberg delete files) | Slowest (extra read cost until compaction) | Surgical cleanup when partition scope doesn't fit |
| `createOrReplace()` | **Entire table dropped and recreated** | **Highest — destroys all partitions** | Fast | Only when you genuinely want to rebuild the whole table |

### 1. Iceberg snapshot rollback (your first-resort cleanup)

Every write to an Iceberg table creates a new immutable snapshot. The previous snapshots still exist (until `expire_snapshots` runs). If a bad batch just landed, **roll the table back to the snapshot that existed before it.**

```sql
-- Step 1: find the snapshot that existed BEFORE the bad write.
SELECT snapshot_id, committed_at, operation, summary
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 10;

-- Step 2: roll back to the one just before the bad batch.
CALL iceberg.system.rollback_to_snapshot(
  table       => 'analytics.events',
  snapshot_id => 4823511203987654321
);
```

Why this is the right first move:
- **Zero data rewrite.** Only the table's "current snapshot" pointer moves. The bad files are still there, but no query sees them.
- **Atomic.** Either fully rolled back or not at all. No half-state.
- **Cheap to undo.** If you panicked and rolled back the wrong snapshot, roll forward to the next one.

When rollback won't work:
- Another (correct) write landed between the bad write and the moment you noticed. Rolling back the bad write also rolls back the correct one. In that case, jump to option 2 or 3.
- `expire_snapshots` already ran and removed the pre-bad snapshot. (This is why you keep at least 7 days of snapshots — see resource 17.)

### 2. Partition-scoped overwrite (`overwritePartitions()`)

When you need to re-ingest specific partitions (e.g., yesterday's data after a bug fix), use Spark's `overwritePartitions()`. This **only replaces partitions that appear in `df`** — every other partition in the table is untouched.

```python
# Re-ingest only May 22, 2026, for tenant_id = 'acme'.
fixed_df = read_from_postgres(date='2026-05-22', tenant='acme')

# Replaces ONLY the (day=2026-05-22, tenant_id=acme) partition.
# Every other partition stays exactly as it was.
fixed_df.writeTo("iceberg.analytics.events").overwritePartitions()
```

Compared to the dangerous look-alikes:
- `createOrReplace()` — drops the whole table. DO NOT use for partial replace.
- `overwrite()` (deprecated in newer Iceberg) — used to take an expression; error-prone, avoid.
- `overwritePartitions()` — Iceberg looks at the partition values in `df` and replaces exactly those partitions. **This is what you want for "fix one day" workflows.**

Make sure `df` actually contains only the rows for the partitions you want to replace. If you accidentally include rows from a different partition, that partition will be replaced with whatever `df` happens to contain.

### 3. Row-level DELETE (precision tool, performance cost)

When the bad data is scoped by something that isn't a partition column — for example, "delete every row I loaded after 14:32 yesterday" — use a `DELETE FROM ... WHERE ...`:

```sql
DELETE FROM iceberg.analytics.events
WHERE batch_loaded_at > TIMESTAMP '2026-05-22 14:32:00'
  AND batch_loaded_at < TIMESTAMP '2026-05-22 16:00:00';
```

What this does under the hood (Iceberg format-version 2, the version your table uses):
- Iceberg writes **delete files** — small files that say "ignore these rows in these data files."
- Subsequent queries read data files plus apply the delete files. This adds query overhead until the next compaction merges the deletes in.
- You **must** run `rewrite_data_files` after large DELETEs to fold the deletes into the data and restore full query speed.

When to use DELETE:
- Targeted cleanup that doesn't align with partition boundaries.
- GDPR / customer-erasure requests (delete a specific user's rows).

When not to use DELETE:
- If a snapshot rollback or `overwritePartitions()` can do the job, use those — they don't leave delete-file overhead behind.

### Preventing the double-load in the first place

The cleanup tools above are for when prevention fails. Prevent it by making the job idempotent:

1. **Deterministic batch boundaries.** Use a `[start_ts, end_ts)` window passed in as a job parameter, not "since last watermark." Then re-running for the same window produces the same output.
2. **`overwritePartitions()` over `append()` for backfill jobs.** Append doubles on re-run; overwrite is naturally idempotent for partition-scoped batches.
3. **Job-run dedup ID.** Tag every row with `_ingest_run_id` (a UUID generated once per job run). On re-run for the same window, an `overwritePartitions()` replaces the prior run's rows cleanly.
4. **Monitor row counts pre- and post-load.** Add a check: "Postgres source rows in window = N. Iceberg target rows in window after load = N. If not, alert."

If you remember nothing else: **rollback first, `overwritePartitions()` second, DELETE third, never `createOrReplace()` for partial fixes.**

---

## The Hive Metastore piece

Iceberg needs a *catalog* to track which tables exist and where their metadata lives. In this stack, that's Hive Metastore (HMS) running in the k8s cluster.

**One-time table creation** (run in Spark SQL or Trino):

```sql
CREATE TABLE iceberg.analytics.events (
    event_id        STRING,
    tenant_id       BIGINT,
    user_id         BIGINT,
    event_name      STRING,
    event_ts        TIMESTAMP,
    device_type     STRING,
    plan_at_event   STRING,
    feature_name    STRING,
    properties_raw  STRING,
    updated_at      TIMESTAMP,
    batch_loaded_at TIMESTAMP
)
USING iceberg
PARTITIONED BY (day(event_ts), tenant_id)
TBLPROPERTIES (
    'write.target-file-size-bytes' = '134217728',  -- 128 MB
    'format-version' = '2'
);
```

After creation, Trino and Spark both see the same table because both point at the same HMS. **Do not create tables in two places** — pick Spark or Trino, stay consistent.

---

## Schema evolution: handling new columns added to Postgres

Sooner or later a Postgres engineer adds a column to a source table (`ALTER TABLE events ADD COLUMN ab_variant VARCHAR`) and your Spark ingestion job either silently drops the new column or starts failing in confusing ways at 2 AM. **The correct fix depends on which ingestion pattern you use.** The wrong fix for the wrong pattern is worse than no fix — it looks like it works for one run and silently breaks on the next.

### The branching rule (read this first)

| Ingestion pattern | When Postgres adds a column | Fix |
|---|---|---|
| **Incremental / append** (Pattern B) | `ALTER TABLE iceberg.analytics.events ADD COLUMN ab_variant VARCHAR` in Iceberg, then re-run the job | Old rows return NULL for the new column; new rows have the real value |
| **Full-refresh** (Pattern A, uses `createOrReplace()`) | Update the Spark job's JDBC read / column list to include the new column, then re-run | Table is recreated with the new schema on next run; ALTER TABLE is useless here |
| **CDC** (Pattern C) | Pause the Iceberg-writing consumer, run `ALTER TABLE ... ADD COLUMN` in Iceberg (metadata-only), then resume the consumer. For the Debezium **Iceberg sink connector**, set `schema.evolution=basic` to automate this. | Debezium detects the DDL via WAL relation messages (not schema registry); sink connector applies the column addition |

### For incremental / append jobs

These jobs use `df.writeTo("iceberg.analytics.events").append()`. The Iceberg table is created once and lives across runs. To add a column:

```sql
-- 1. Add the column to the Iceberg table. This is METADATA-ONLY — no Parquet rewrite,
-- runs in milliseconds even on a 10 TB table. Iceberg's schema-evolution guarantee.
ALTER TABLE iceberg.analytics.events ADD COLUMN ab_variant VARCHAR;
```

```python
# 2. Update the Spark job's JDBC read so the new column flows through (most JDBC
#    SELECT * reads pick it up automatically, but explicit column lists must be updated).
df = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT id, tenant_id, user_id, event_name, event_ts, properties, "
          "ab_variant, updated_at FROM events WHERE updated_at > '{last_ts}') t",
    properties=PG_PROPS,
)

# 3. Re-run. New rows have the real ab_variant. Old rows return NULL when queried.
df.writeTo("iceberg.analytics.events").append()
```

That's it. Iceberg's schema evolution is **column-name-based** (not position-based like Hive), so adding a column never breaks existing readers. Old Parquet files don't have the column; when queried, Iceberg fills NULL for missing columns.

### For full-refresh jobs using createOrReplace()

These jobs use `df.writeTo("...").createOrReplace()`. **Read this carefully — this is the bug that bites everyone the first time.**

`createOrReplace()` **drops the entire Iceberg table and rebuilds it from the Spark DataFrame schema on every single run.** That means:

- Any column you manually added with `ALTER TABLE iceberg.analytics.plans ADD COLUMN ab_variant VARCHAR` is **gone on the very next run** of the ingestion job. The next `createOrReplace()` wipes the table and recreates it from the DataFrame, and the DataFrame didn't include `ab_variant` because the Spark job's JDBC query didn't select it.
- You will see the column for exactly one run (or until the next nightly run), then it silently disappears. This is exactly the kind of bug that wastes a day to diagnose.

The correct fix is to update the Spark job, not the table:

```python
# WRONG for full-refresh: don't bother with ALTER TABLE — the next createOrReplace
# will throw it away.
#
# RIGHT: update the Spark job's JDBC read so the new column is in the DataFrame.
df = spark.read.jdbc(
    url=PG_URL,
    # Include the new column in the SELECT list (or use SELECT *).
    table="(SELECT plan_id, name, price_cents, ab_variant FROM public.plans) t",
    properties=PG_PROPS,
)

# createOrReplace rebuilds the Iceberg table from THIS DataFrame's schema.
# The table will now have ab_variant because the DataFrame has ab_variant.
df.writeTo("iceberg.analytics.plans").using("iceberg").createOrReplace()
```

The mental model: with `createOrReplace()`, the **Spark job's DataFrame schema IS the table schema**. The Iceberg table has no independent existence between runs — it's redefined every time. So schema changes must happen in the Spark code, not in Iceberg DDL.

### Prevention: pre-flight schema-diff check

Don't wait for the 2 AM alert. Add a schema-diff check at job startup that compares Postgres `information_schema.columns` to the Iceberg table's schema, and **alerts** instead of failing blindly:

```python
def preflight_schema_check(spark, pg_table, iceberg_table):
    # 1. Fetch Postgres column list.
    pg_cols = spark.read.jdbc(
        url=PG_URL,
        table=f"(SELECT column_name, data_type FROM information_schema.columns "
              f"WHERE table_schema='public' AND table_name='{pg_table}') t",
        properties=PG_PROPS,
    ).collect()
    pg_col_names = {row.column_name for row in pg_cols}

    # 2. Fetch Iceberg column list. Use DESCRIBE TABLE — it works in both Spark SQL
    #    and Trino, and is the supported way to introspect an Iceberg table's columns.
    #    (Do NOT use a `$schema` pseudo-table — it is not a standard Iceberg metadata
    #    table in Trino; `$snapshots`, `$files`, `$partitions`, and `$history` are.)
    iceberg_cols = spark.sql(
        f"DESCRIBE TABLE iceberg.analytics.{iceberg_table}"
    ).collect()
    # DESCRIBE TABLE returns col_name, data_type, comment — take col_name and skip
    # the trailing partition-info rows that start with `#` or empty col_name.
    iceberg_col_names = {
        row.col_name for row in iceberg_cols
        if row.col_name and not row.col_name.startswith("#")
    }
    # From Trino, the equivalent introspection is:
    #   DESCRIBE iceberg.analytics.events
    #   -- or --
    #   SHOW COLUMNS FROM iceberg.analytics.events

    # 3. Diff.
    new_in_postgres = pg_col_names - iceberg_col_names
    removed_from_postgres = iceberg_col_names - pg_col_names

    if new_in_postgres or removed_from_postgres:
        alert_slack(
            f"Schema drift on {pg_table}: "
            f"new in Postgres={new_in_postgres}, "
            f"removed from Postgres={removed_from_postgres}. "
            f"Decide ALTER TABLE (incremental) or update Spark job (full-refresh)."
        )
        # For incremental jobs: optionally auto-ALTER and continue.
        # For full-refresh jobs: fail loudly — code change required.
        if INGESTION_MODE == "full_refresh":
            raise SchemaDriftError(
                "Full-refresh job needs code update; refusing to silently lose data."
            )
```

Iceberg's **metadata table** convention exposes table internals as queryable pseudo-tables you can SELECT from for ops automation. The widely supported ones in Trino are `$snapshots`, `$files`, `$partitions`, `$history`, `$manifests`, and `$properties`. For introspecting **columns**, use `DESCRIBE TABLE iceberg.analytics.events` or `SHOW COLUMNS FROM iceberg.analytics.events` in Trino, or `DESCRIBE TABLE iceberg.analytics.events` in Spark SQL — `$schema` is **not** a standard Iceberg metadata table in Trino.

### Other schema changes (quick reference)

| Postgres change | Iceberg action (incremental) | Iceberg action (full-refresh) |
|---|---|---|
| `ADD COLUMN` | `ALTER TABLE ... ADD COLUMN`, re-run | Update Spark job's column list, re-run |
| `DROP COLUMN` | `ALTER TABLE ... DROP COLUMN` (metadata-only) | Remove from Spark job's column list, re-run |
| `RENAME COLUMN` | `ALTER TABLE ... RENAME COLUMN` (metadata-only, Iceberg tracks by column ID) | Update Spark job's column list, re-run |
| Widen type (`INT` → `BIGINT`) | `ALTER TABLE ... ALTER COLUMN ... TYPE BIGINT` (allowed in Iceberg) | Update Spark job's casts, re-run |
| Narrow type (`BIGINT` → `INT`) | **Not allowed by Iceberg** — would lose data. Create new column, backfill, drop old | Same: not allowed, must be a multi-step migration |
| Change nullability | Not directly supported — write a new column or rebuild | Same |

### For CDC jobs (Pattern C)

**How Debezium actually detects Postgres DDL changes — and what the schema registry has to do with it**

This is a common source of confusion. There are two separate systems involved:

**The DDL detection mechanism: WAL relation messages (not the schema registry)**

Postgres does not emit explicit `ALTER TABLE` events in the logical replication stream. Instead, after a DDL change, the next WAL record that writes to (or reads from) that table includes a **relation message** — a structural description of the table's current column layout. Debezium reads this relation message and learns about the new column. This detection happens automatically with no configuration changes required.

Key consequence: Debezium does NOT re-emit historical rows with the new column. It only starts including the new field in events that occur *after* the `ALTER TABLE`. Pre-alter rows in Kafka will have the field absent (not `null` — just absent from the message).

**The schema registry: Kafka payload serialization (unrelated to DDL detection)**

The schema registry (Confluent Schema Registry, Apicurio) stores Avro or Protobuf schemas for the Kafka message payloads. It is used by the Debezium connector to serialize and deserialize messages — not to detect DDL changes on the source database. You can run Debezium without a schema registry (using JSON serialization) and DDL detection still works.

**`schema.evolution=basic` is a Debezium Iceberg sink connector setting**

The source connector (Postgres → Kafka) does not have a `schema.evolution` option. The `schema.evolution=basic` setting lives on the **Debezium Iceberg sink connector** (which reads from Kafka and writes to Iceberg). When enabled, the sink connector detects new fields in upstream Kafka messages and automatically runs `ALTER TABLE ADD COLUMN` on the Iceberg side. If you are using a custom Spark Structured Streaming consumer instead of the Debezium sink connector, you must run the `ALTER TABLE` manually.

**Order of operations (manually managed consumer):**

1. Notice the new column in Postgres (via schema-diff alert from `preflight_schema_check`) or when the consumer errors on an unexpected field.
2. Pause the Iceberg-writing consumer.
3. Run `ALTER TABLE iceberg.analytics.events ADD COLUMN device_os VARCHAR` in Spark SQL — metadata-only, completes in milliseconds.
4. Resume the consumer — new events with `device_os` now write successfully.
5. Do NOT restart the Debezium source connector — it continued publishing events during the pause. The consumer simply resumes from where it left off in Kafka.

**Order of operations (Debezium Iceberg sink connector with `schema.evolution=basic`):**

1. Developer adds column in Postgres.
2. Debezium source connector detects the relation message, emits events with the new field.
3. Sink connector sees the new field, automatically runs `ALTER TABLE ADD COLUMN` on Iceberg.
4. No manual intervention required.

### The takeaway

When a Postgres engineer pings you "I added a column to `events`, can you make it queryable?" — your **first question** must be "is the ingestion job full-refresh or incremental?" The answer determines whether your fix is ALTER TABLE (incremental) or a code change to the Spark job (full-refresh). Get this wrong and you'll either ship a column that disappears overnight or spend an hour writing ALTER TABLE statements that the next job run will undo.

---

## Handling mutable dimension tables (upsert pattern)

Most guides cover inserting new rows. This section covers what to do when your Postgres table gets UPDATE statements — rows that already exist in Iceberg need to be updated, not just appended.

**When does this apply?** Tables where records change over time:
- `users` — name, email, plan tier, subscription status
- `accounts` / `tenants` — settings, plan, feature flags
- `subscriptions` — renewal date, status, amount

Fact tables (events, clicks, page views, API calls) are almost always append-only and do not need this pattern.

**Why append() creates duplicates**: if a user upgrades from Free to Pro and you run an incremental append, you now have two rows in Iceberg with the same `user_id` — one with `plan=Free`, one with `plan=Pro`. Queries that join on `user_id` return both rows.

---

### Pattern 1 — Full refresh for small dimension tables (under ~10M rows)

The simplest fix: read the entire Postgres table and replace the Iceberg table every night.

```python
users_df = spark.read \
    .format("jdbc") \
    .option("url", "jdbc:postgresql://pg-primary:5432/app") \
    .option("dbtable", "public.users") \
    .option("user", PG_USER).option("password", PG_PASS) \
    .load()

# createOrReplace() drops the Iceberg table and recreates it from scratch.
# Acceptable for small dimension tables. Do NOT use for large fact tables.
users_df.writeTo("iceberg.analytics.dim_users").using("iceberg").createOrReplace()
```

- **When to use**: dimension tables under ~10M rows where a full rebuild takes under a few minutes.
- **Limitation**: readers see a brief window with no data during the swap. For nightly jobs on small tables this is usually acceptable.
- **Do not use `createOrReplace()` on fact tables** — it wipes all historical data.

---

### Pattern 2 — Incremental upsert for large tables (MERGE INTO via spark.sql)

For dimension tables that are too large for a full refresh, use SQL MERGE INTO: update existing rows and insert new ones in a single atomic operation.

> **Critical note for Spark 3 + Iceberg 1.5.2 (the production stack)**: use `spark.sql("MERGE INTO ...")`, NOT the DataFrame chained API (`df.writeTo().whenMatched().updateAll().whenNotMatched().insertAll().merge()`). The DataFrame merge builder requires PySpark 4.0+. Calling it on Spark 3 raises `AttributeError`. On the production stack, `spark.sql()` is the only working approach.

```python
# Step 1: load the latest snapshot of the users table from Postgres
users_df = spark.read \
    .format("jdbc") \
    .option("url", "jdbc:postgresql://pg-primary:5432/app") \
    .option("dbtable", "public.users") \
    .option("user", PG_USER).option("password", PG_PASS) \
    .load()

# Step 2: register as a temp view so spark.sql() can reference it
users_df.createOrReplaceTempView("users_updates")

# Step 3: MERGE INTO — updates existing rows, inserts new ones.
# This is the correct syntax for Spark 3 + Iceberg 1.5.2.
spark.sql("""
    MERGE INTO iceberg.analytics.dim_users AS t
    USING users_updates AS s
    ON t.user_id = s.user_id
    WHEN MATCHED THEN UPDATE SET
        t.name       = s.name,
        t.email      = s.email,
        t.plan       = s.plan,
        t.updated_at = s.updated_at
    WHEN NOT MATCHED THEN INSERT *
""")
```

**Requirements**:
- The Iceberg table (`dim_users`) must already exist. Create it once with `CREATE TABLE iceberg.analytics.dim_users (...)` before the first run.
- The match key (`user_id` above) must be unique on the Postgres side.

> **When is `updated_at` required?** For a full-snapshot MERGE INTO — where you read the entire Postgres table and merge it into Iceberg — `updated_at` is **not required**. The MERGE condition (`ON target.user_id = source.user_id`) works with any join key. Only the incremental watermark pattern (Pattern B: `WHERE updated_at > last_checkpoint`) requires `updated_at`. If your source table does not have `updated_at`, use full-snapshot MERGE INTO nightly rather than an incremental load.

> **Iceberg defaults to Copy-on-Write (CoW) for MERGE INTO.** When a MERGE INTO updates a row, Iceberg rewrites the entire Parquet data file that contained that row, producing a new Parquet file with the updated content. **No separate delete files are created** — this is different from how row-level DELETE works. Running `rewrite_data_files` after a MERGE INTO session is still recommended, but for **small-file consolidation** (many individual MERGE runs each produce small rewritten files) — not to apply pending delete files, because there are none in CoW mode.

**What NOT to use for dimension upserts**:
- `overwritePartitions()` — correct for partitioned fact tables (replacing all events for one date), not for dimension tables. A dimension table has no natural time partition; calling `overwritePartitions()` would overwrite whichever partitions happen to be in `df`, silently deleting rows for any users not in the current batch.
- `append()` — creates duplicate rows per `user_id` on every run.

---

### MERGE INTO Idempotency Checklist — if you're seeing duplicate rows

If you ran MERGE INTO and found duplicate rows in Iceberg afterwards, work through these three diagnostic questions **in priority order**. The first question catches the most common cause; only move to the next if you've ruled out the previous.

#### Question 1: Is your ON clause on a unique column?

The wrong `ON` clause is by far the most common cause of MERGE INTO duplicates. The `ON` clause is the join condition that decides "is this source row already in the target?" — if multiple source rows match the same target row (or multiple target rows match one source row), Iceberg either errors or inserts extras depending on the version and write mode. Either way, you end up with bad data.

```python
# WRONG — event_date is shared by thousands of events per day. Many source rows
# match many target rows on the same key. MERGE INTO cannot disambiguate.
# spark.sql("""
#     MERGE INTO iceberg.analytics.events t
#     USING events_delta s
#     ON t.event_date = s.event_date
#     WHEN MATCHED THEN UPDATE SET *
#     WHEN NOT MATCHED THEN INSERT *
# """)

# WRONG — updated_at also is not unique per event. Two events updated in the
# same millisecond produce ambiguous matches.
# spark.sql("""
#     MERGE INTO iceberg.analytics.events t
#     USING events_delta s
#     ON t.updated_at = s.updated_at
#     ...
# """)

# CORRECT — event_id is the Postgres primary key, unique per event.
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_delta s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

**Rule:** the `ON` clause must use the Postgres primary key, or a combination of columns that uniquely identifies one logical row (e.g., `ON t.tenant_id = s.tenant_id AND t.external_id = s.external_id` if your natural key is composite). If you cannot name a unique key with confidence, you cannot safely MERGE — fix the source schema first.

> **TIMESTAMP PRECISION AND COMPOSITE MERGE KEYS — what actually happens end-to-end.**
>
> **Default behavior: microseconds are preserved.** The Iceberg spec mandates microsecond precision and maps to Parquet's `TIMESTAMP_MICROS` logical type. On the production stack (Spark + Iceberg 1.5.2 + Parquet), microseconds flow from Postgres through to Iceberg and are exposed by Trino 467 as `TIMESTAMP(6)` by default. **Precision loss is not an inherent property of Parquet or Iceberg.**
>
> **When precision loss does occur.** Microseconds are lost only when something in the pipeline explicitly downgrades them:
> - `spark.sql.parquet.outputTimestampType=TIMESTAMP_MILLIS` — this Spark config forces millisecond output. Often copied from an old Hive-compatibility template. Your `14:32:17.482913` becomes `14:32:17.482` on disk permanently.
> - An explicit cast to `TIMESTAMP(3)` in the Spark job's select or JDBC query.
> - Client display truncation — some BI tools show only 3 decimal places even when Iceberg stores 6.
>
> **Connection to MERGE INTO:** If `occurred_at` is part of a composite MERGE key (e.g., `ON t.device_id = s.device_id AND t.session_id = s.session_id AND t.occurred_at = s.occurred_at`) and the pipeline was configured with `TIMESTAMP_MILLIS`, two events differing only in microseconds will appear identical after truncation and the MERGE will silently UPDATE instead of INSERT — losing one event. Fix the config first, then re-read from Postgres to restore precision, then verify the MERGE behavior is correct.
>
> **Diagnostic ladder when you see millisecond-only timestamps in Iceberg:**
>
> ```python
> # Step 1 — Check the Spark conf for the culprit.
> spark.conf.get("spark.sql.parquet.outputTimestampType")
> # Expected: TIMESTAMP_MICROS (or not set — defaults to micros for Iceberg)
> # Bad:      TIMESTAMP_MILLIS → root cause; remove or set to TIMESTAMP_MICROS.
> ```
>
> ```sql
> -- Step 2 — Check whether actual data has microseconds (not just the schema).
> -- If occurred_at was written with TIMESTAMP_MILLIS, all microsecond sub-millisecond
> -- digits are zero. The schema always shows TIMESTAMP(6) for Iceberg tables — that alone
> -- is not proof.
> --
> -- Trino-valid diagnostic (Trino's EXTRACT does not support a MICROSECOND field —
> -- supported fields stop at SECOND; use date_diff instead):
> SELECT COUNT(*) AS rows_with_submillisecond_precision
> FROM iceberg.analytics.events
> WHERE date_diff('microsecond',
>                 date_trunc('millisecond', occurred_at),
>                 occurred_at) != 0;
> -- Returns 0 → all timestamps are millisecond-aligned → TIMESTAMP_MILLIS was used.
> -- Returns > 0 → sub-millisecond precision is present → full microsecond precision.
> --
> -- NOTE: EXTRACT(MICROSECOND FROM ...) is NOT valid Trino syntax — Trino's EXTRACT
> -- only supports fields down to SECOND. Pasting that query into Trino returns a parse
> -- error at exactly the moment you're trying to diagnose data loss. Use date_diff above.
> ```
>
> **Important — why `SHOW COLUMNS` is NOT a valid diagnostic here.** The Iceberg table schema *always* reflects microsecond precision (`TIMESTAMP(6)`) regardless of what precision the physical Parquet files were written with. `SHOW COLUMNS` / `DESCRIBE TABLE` shows the **Iceberg logical schema**, not the physical Parquet file precision. An engineer who checks `SHOW COLUMNS` will see `TIMESTAMP(6)` even when `TIMESTAMP_MILLIS` was used at write time and microseconds were truncated to zero on disk. Only querying the actual data (the query above) reveals whether microseconds survived the write — the schema view will lie to you here.
>
> **The fix:** Remove `TIMESTAMP_MILLIS` or set `spark.sql.parquet.outputTimestampType=TIMESTAMP_MICROS`. Re-run the affected ingestion job using `overwritePartitions()` to replace the downgraded files — **but you must re-read from Postgres (the source of truth), not from the existing Iceberg table.** Re-reading from Iceberg and rewriting rewrites millisecond-precision data into new millisecond-precision Parquet files — the microseconds are already gone from those files and cannot be reconstructed from within Iceberg.
>
> **Composite MERGE key risk when precision loss has occurred.** If truncation has happened via the causes above, a natural composite key like `(device_id, session_id, event_type, occurred_at)` stops being unique. Two distinct Postgres events differing only in microseconds appear identical in Iceberg — the MERGE UPDATEs instead of INSERTs, causing silent data loss with no error or warning.
>
> **Diagnostic — run AFTER confirming precision loss has occurred:**
>
> ```sql
> -- Run in Postgres (or against your staging Iceberg copy of raw events).
> -- If this returns any rows, your composite key collides after ms truncation.
> SELECT device_id, session_id, event_type, occurred_at, COUNT(*)
> FROM staging
> GROUP BY device_id, session_id, event_type, occurred_at
> HAVING COUNT(*) > 1;
> ```
>
> **Fallback options when the diagnostic shows collisions** (pick one):
>
> 1. **Include a Postgres sequence or serial column as the ON-clause key.** If the source has `id BIGSERIAL PRIMARY KEY`, use `ON t.id = s.id` — always unique by construction, no hashing needed.
>
> 2. **Add an `event_hash` surrogate column** computed at full microsecond precision in Postgres before export:
>
>    ```sql
>    ALTER TABLE events ADD COLUMN event_hash BYTEA;
>    UPDATE events SET event_hash = digest(
>      device_id || '|' || session_id || '|' || event_type || '|' ||
>      EXTRACT(EPOCH FROM occurred_at)::TEXT,
>      'sha256'
>    );
>    ```
>    Then use `ON t.event_hash = s.event_hash` in the MERGE.
>
> Prefer option 1 (BIGSERIAL) when it exists — it's free. Use option 2 (event_hash) when the source schema is fixed and you can't add a serial column.

#### Question 2: Does your source query produce duplicate keys?

Even with the correct `ON` clause, MERGE INTO inserts duplicates if the **source DataFrame** has duplicate `event_id` values before the merge runs. Common causes: overlapping watermark windows (the delta from Postgres covers a window that overlaps with the prior run), Postgres retries that emit the same logical event twice, or upstream CDC redelivery.

Diagnostic — run this in Trino after a suspected duplicate run:

```sql
-- Count duplicate event_id values in the suspected affected partition.
SELECT event_id, COUNT(*) AS cnt
FROM iceberg.analytics.events
WHERE date(occurred_at) = '2026-05-22'
GROUP BY event_id
HAVING COUNT(*) > 1
LIMIT 20;
```

If this returns rows, duplicates exist and either Question 1 or Question 2 (or both) is the cause. To address Question 2 specifically, add **deduplication before the MERGE** using the `ROW_NUMBER()` window pattern already documented in this resource (see the "Spark job skeleton" section, step 3):

```python
from pyspark.sql import Window
from pyspark.sql.functions import row_number

w = Window.partitionBy("event_id").orderBy(col("updated_at").desc())
events_delta = (
    raw_delta_df
    .withColumn("_rn", row_number().over(w))
    .filter("_rn = 1")
    .drop("_rn")
)
events_delta.createOrReplaceTempView("events_delta")

# Now safe to MERGE — guaranteed unique event_id in the source.
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_delta s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

#### Question 3: How to clean up duplicates already in Iceberg

If duplicates have already landed, you have two cleanup paths depending on whether `expire_snapshots` has already run on the affected snapshots.

**Case 3a — the bad MERGE ran recently (before `expire_snapshots` cleaned the prior snapshot):** roll the table back to the snapshot that existed *before* the bad MERGE.

```python
# Find the pre-error snapshot. Look for the snapshot whose commit time is
# immediately before the bad MERGE's commit time.
spark.sql("""
    SELECT snapshot_id, committed_at, operation, summary
    FROM iceberg.analytics.events.snapshots
    ORDER BY committed_at DESC
    LIMIT 10
""").show(truncate=False)

# Roll back to the snapshot id from BEFORE the bad MERGE.
spark.sql("""
    CALL iceberg.system.rollback_to_snapshot(
        table       => 'analytics.events',
        snapshot_id => 4823511203987654321
    )
""")
```

After rollback, re-run the MERGE **with the corrected `ON` clause and a deduplicated source** (apply the fixes from Questions 1 and 2 first). Rollback is metadata-only, atomic, and fast — and as long as the pre-bad snapshot is still alive, it is the lowest-risk option.

**Case 3b — `expire_snapshots` has already run, so rollback is unavailable:** dedup the affected partition and overwrite it with the Postgres ground truth.

```python
from pyspark.sql import Window
from pyspark.sql.functions import col, row_number

# Step 1: re-read the affected partition from the authoritative source (Postgres).
# Postgres is the source of truth — do not try to dedup the Iceberg copy in-place
# unless you've verified Iceberg holds every logically-correct row.
clean_df = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT * FROM events WHERE date(occurred_at) = '2026-05-22') t",
    properties=PG_PROPS,
)

# Step 2: defensive dedup (in case Postgres itself has retried rows).
w = Window.partitionBy("event_id").orderBy(col("updated_at").desc())
clean_df = (
    clean_df
    .withColumn("_rn", row_number().over(w))
    .filter("_rn = 1")
    .drop("_rn")
)

# Step 3: atomically overwrite the affected partition with the clean ground truth.
# overwritePartitions() replaces ONLY the partitions present in clean_df — every
# other day's partition is untouched. Because clean_df contains every row that
# should exist for May 22 (it's a full re-read, not a delta), this is safe.
clean_df.writeTo("iceberg.analytics.events").overwritePartitions()
```

This pattern is exactly the "fix one day after a bad batch" workflow from the Idempotency and cleanup section above, applied to MERGE-induced duplicates. After the overwrite, re-run the COUNT diagnostic from Question 2 to confirm `cnt` is 1 for every `event_id`.

**Multi-day fallback recipe — when the wrong ON clause ran across multiple days and no usable snapshot exists.** If the bad MERGE INTO affected several partitions (e.g., a backfill job ran for three days with the wrong ON clause) and rollback is unavailable, repeat the single-day recipe across the full affected date range using `partitionOverwriteMode = dynamic` so the write replaces only those days, not the entire table:

```python
# Fallback when no usable snapshot exists:
# Step 1: Re-read the affected partitions from Postgres (authoritative source).
# Step 2: Overwrite only those partitions in Iceberg.
df_clean = spark.read.jdbc(
    pg_url,
    "(SELECT * FROM events WHERE event_date BETWEEN '2024-01-01' AND '2024-01-03') t",
    properties=props,
)
df_clean.write \
    .format("iceberg") \
    .option("write.spark.fanout.enabled", "true") \
    .mode("overwrite") \
    .option("partitionOverwriteMode", "dynamic") \
    .save("iceberg.analytics.events")
```

**CRITICAL — read this before running.** This pattern uses `overwritePartitions` semantics — it **replaces the ENTIRE partition** for each day that appears in `df_clean`. The re-read from Postgres **must include ALL rows for those partitions** (every event for Jan 1, Jan 2, and Jan 3 in the example) — not just the duplicated rows you're trying to clean up. If you scope the SELECT too narrowly (e.g., `WHERE event_date BETWEEN ... AND duplicated = true`), the overwrite will **wipe every legitimate row** from those partitions and leave only the few rows your narrow SELECT returned. The whole-partition Postgres re-read is the safety property; do not shortcut it.

`write.spark.fanout.enabled = true` is recommended when the source DataFrame is not pre-sorted by partition key — it lets Spark write multiple partitions concurrently from a single task without requiring an upstream shuffle/sort. For multi-day backfills with a few dozen affected partitions, this is the right setting.

After the multi-day overwrite, re-run the duplicate-COUNT diagnostic across the affected date range to confirm cleanup:

```sql
SELECT date(occurred_at) AS d, event_id, COUNT(*) AS cnt
FROM iceberg.analytics.events
WHERE date(occurred_at) BETWEEN DATE '2024-01-01' AND DATE '2024-01-03'
GROUP BY date(occurred_at), event_id
HAVING COUNT(*) > 1
LIMIT 20;
```

If this returns zero rows for all three days, the cleanup succeeded.

**Why not just `DELETE` the duplicates and leave the originals?** You can — `DELETE FROM iceberg.analytics.events WHERE event_id IN (...)` works — but it writes Iceberg delete files that slow queries until the next compaction, and you must be very careful to delete only the duplicate row(s) and keep one original. The full-partition overwrite from Postgres ground truth is simpler and leaves the table in a clean Copy-on-Write state with no pending delete-file overhead.

---

### Deduplication in Trino if duplicates already exist

If duplicates have already landed in Iceberg (from prior append runs), you cannot use `DISTINCT ON (user_id)` in Trino — that is PostgreSQL-only syntax. Trino 467 does not support it and will return a syntax error.

Use `ROW_NUMBER()` with a window function instead:

```sql
-- Trino: find the most recent row per user, discarding duplicates
SELECT *
FROM (
    SELECT
        *,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC) AS rn
    FROM iceberg.analytics.dim_users
)
WHERE rn = 1;
```

To permanently clean up: run a Spark MERGE INTO (Pattern 2 above) from the current Postgres snapshot into the Iceberg table — it will overwrite duplicates with the single canonical row.

---

### Summary table

| Scenario | Correct tool | Wrong tool |
|---|---|---|
| Small dimension table, full nightly rebuild | `createOrReplace()` | `overwritePartitions()`, `append()` |
| Large dimension table, incremental upsert | `spark.sql("MERGE INTO ...")` | `df.writeTo().whenMatched()...` (PySpark 4.0+ only) |
| Partitioned fact table, one day's batch | `overwritePartitions()` | `createOrReplace()` (wipes entire table) |
| Dedup in Trino | `ROW_NUMBER() OVER (PARTITION BY ...)` | `DISTINCT ON (...)` (PostgreSQL-only, Trino rejects it) |

---

## Scheduling the job

Two reasonable choices on the prod stack:

- **Airflow DAG** (one DAG per source table). Best when you have many tables with dependencies between them.
- **Kubernetes CronJob** (one CronJob per table). Simpler if you only have a handful of tables.

A typical nightly DAG runs at 2 AM (low Postgres traffic) and does:

> **SPARK CATALOG NAME IS `iceberg`, NOT `spark_catalog`.** The production Spark session is configured with `spark.sql.catalog.iceberg=org.apache.iceberg.spark.SparkCatalog`. All `CALL` statements for Iceberg system procedures must use `CALL iceberg.system.*`. Never use `CALL spark_catalog.system.*` — that catalog name does not exist in this environment and produces a "catalog not found" runtime error.

1. `spark-submit` the ingestion job.
2. `CALL iceberg.system.rewrite_data_files('analytics.events')` to compact small files into ~128 MB chunks.
3. `CALL iceberg.system.expire_snapshots('analytics.events', TIMESTAMP '...')` weekly, retaining 7 days of snapshots.

Skip steps 2 and 3 and your table will get slower every week.

---

## Freshness vs. complexity

| Pattern | Freshness | Complexity | Good for |
|---|---|---|---|
| Full refresh | ~24 h | Low | Tables < 10M rows, daily dashboards |
| Incremental append | 1–4 h | Medium | Large tables, same-day dashboards |
| CDC + streaming | < 5 min | High | Real-time product analytics, accurate deletes |

Start with full refresh. Move to incremental when a table outgrows it. Only adopt CDC when a real business requirement demands sub-hour freshness — the operational cost is significant.

---

## Postgres → Trino date/time translation table

Engineers migrating validation queries from Postgres to Trino frequently hit parse errors because the two dialects differ significantly in datetime syntax. Trino follows ANSI SQL more strictly than Postgres does. **Treat Trino SQL as a distinct dialect — do not copy Postgres date queries verbatim.**

| What you want | Postgres | Trino 467 | Notes |
|---|---|---|---|
| Current timestamp | `NOW()` or `CURRENT_TIMESTAMP` | `current_timestamp` or `now()` | Both work in Trino; no parens for `current_timestamp`, parens for `now()` |
| Last 30 days | `NOW() - INTERVAL '30 days'` | `current_timestamp - INTERVAL '30' DAY` | Unit outside the quotes, singular, uppercase |
| Last 7 days | `NOW() - INTERVAL '7 days'` | `current_timestamp - INTERVAL '7' DAY` | Same pattern — `days` plural fails in Trino |
| Unix epoch seconds | `EXTRACT(epoch FROM ts)` | `to_unixtime(ts)` | `EPOCH` is not a valid Trino EXTRACT field — parse error |
| Sub-millisecond precision check | `EXTRACT(MICROSECOND FROM ts) % 1000 != 0` | `date_diff('microsecond', date_trunc('millisecond', ts), ts) != 0` | `MICROSECOND` is not a valid Trino EXTRACT field — parse error; use `date_diff` |
| Interval arithmetic | `ts + INTERVAL '1 hour'` | `ts + INTERVAL '1' HOUR` | Same unit-outside-quotes rule |
| Date diff in days | `date_part('day', ts2 - ts1)` | `date_diff('day', ts1, ts2)` | Trino's `date_diff(unit, ts1, ts2)` returns `ts2 - ts1` in the specified unit |
| Truncate to day | `date_trunc('day', ts)` | `date_trunc('day', ts)` | Same syntax — one of the few that ports directly |
| Truncate to week | `date_trunc('week', ts)` | `date_trunc('week', ts)` | Same |
| Cast to DATE | `ts::DATE` | `CAST(ts AS DATE)` or `date(ts)` | Postgres `::` cast syntax is not valid Trino |
| Add N days | `ts + N * INTERVAL '1 day'` | `date_add('day', N, ts)` | Trino's explicit interval function |

**Trino EXTRACT supported fields**: `YEAR`, `QUARTER`, `MONTH`, `WEEK`, `DAY`, `DAY_OF_MONTH`, `DAY_OF_WEEK` (alias `DOW`), `DAY_OF_YEAR` (alias `DOY`), `YEAR_OF_WEEK` (alias `YOW`), `HOUR`, `MINUTE`, `SECOND`, `TIMEZONE_HOUR`, `TIMEZONE_MINUTE`.

**NOT supported in Trino EXTRACT**: `EPOCH`, `MICROSECOND`, `MILLISECOND`. Pasting these into Trino produces a parse error — use `to_unixtime()` for epoch and `date_diff('microsecond', ...)` for sub-second precision.

### Worked before/after examples

When engineers paste broken SQL and ask for help, the answer must paste back the corrected SQL — not just a list of rules. Here are the two most common failure patterns with exact before/after fixes:

**Pattern 1 — INTERVAL with plural unit copied from Postgres:**

```sql
-- BROKEN in Trino (plural 'days' parse error):
WHERE occurred_at < NOW() - INTERVAL '90 days'

-- FIXED for Trino (unit outside quotes, singular, uppercase):
WHERE occurred_at < current_timestamp - INTERVAL '90' DAY
```

**Pattern 2 — EXTRACT(epoch) to compute elapsed time:**

```sql
-- BROKEN in Trino (EPOCH not a valid EXTRACT field — parse error):
SELECT EXTRACT(epoch FROM NOW()) - EXTRACT(epoch FROM occurred_at) AS seconds_since_event

-- FIXED option A — using to_unixtime() (direct translation):
SELECT to_unixtime(current_timestamp) - to_unixtime(occurred_at) AS seconds_since_event

-- FIXED option B — using date_diff() (preferred idiom for duration questions):
SELECT date_diff('second', occurred_at, current_timestamp) AS seconds_since_event
-- For hours: date_diff('hour', occurred_at, current_timestamp) AS hours_since_event
-- For days:  date_diff('day', occurred_at, current_timestamp) AS days_since_event
```

> **Prefer `date_diff(unit, ts1, ts2)` over `to_unixtime` subtraction** for "how long ago" / "duration between" questions. `date_diff` directly names the unit (hours, days, seconds), avoids the division step, and returns an integer. `to_unixtime` subtraction gives raw seconds as a floating-point number and forces you to divide to reach the desired unit. Both are correct; `date_diff` is more readable and handles DST/timezone boundary crossing more predictably.

**Complete corrected query combining both patterns:**

```sql
-- Find events older than 90 days and compute their age in hours.
SELECT
  event_id,
  occurred_at,
  date_diff('hour', occurred_at, current_timestamp) AS hours_since_event,
  date_diff('day',  occurred_at, current_timestamp) AS days_since_event
FROM iceberg.analytics.events
WHERE occurred_at < current_timestamp - INTERVAL '90' DAY
ORDER BY occurred_at DESC;
```

---

## Key terms

| Term | Plain meaning |
|---|---|
| **JDBC** | The Java database driver Spark uses to read from Postgres |
| **Watermark** | The timestamp of the last row you successfully loaded — drives incremental reads |
| **CDC** | Change Data Capture — streaming row-level changes out of Postgres via the WAL |
| **WAL** | Write-Ahead Log — Postgres's internal change journal, the source for Debezium |
| **Compaction** | Merging many small Parquet files into fewer big ones (~128 MB) |
| **Snapshot expiration** | Deleting old Iceberg snapshots so storage stops growing forever |
| **Catalog** | The metadata service (Hive Metastore here) that tracks which Iceberg tables exist |

---

## Summary

The simplest working pipeline: nightly Spark job → JDBC from Postgres → flatten JSONB → append to Iceberg in MinIO via Hive Metastore → compact → expire snapshots. Get that working end-to-end before you reach for Kafka, Debezium, or streaming. The boring version handles 90% of SaaS analytics workloads.
