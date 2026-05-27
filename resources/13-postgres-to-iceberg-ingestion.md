# Postgres to Iceberg: The Complete Ingestion Guide

> You have data in Postgres. Your CTO wants it queryable from Trino in the lakehouse. This guide walks the full journey: patterns, JSONB handling, a Spark job skeleton, the Hive Metastore wiring, and how to schedule it.
>
> Production stack: Apache Spark + Iceberg 1.5.2 + MinIO (S3) + Hive Metastore + Trino 467, all on Kubernetes on-prem.

---

## TL;DR

- Three ingestion patterns: full refresh (simplest), incremental append (most common), CDC (advanced).
- Start with full refresh for small tables; move to incremental once a table passes ~10M rows.
- Parquet has a JSON logical type annotation but stores it as opaque binary with no per-key columnar stats — flatten the top 5–10 hot keys into real columns, keep the rest as a VARCHAR fallback.
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

#### Eliminating the rebuild-window downtime: staging table + view swap

When `createOrReplace()`'s brief table-not-found window is unacceptable (BI tools showing errors, dashboards going blank for 30 seconds), use the **staging table + view swap** pattern:

1. Load the new snapshot into `product_catalog_staging` (a separate Iceberg table).
2. Validate row counts / schema.
3. Atomically swing a Trino view (`product_catalog_view`) from the old table to the new with `CREATE OR REPLACE VIEW`.
4. Optionally `ALTER TABLE ... RENAME` the prior table aside as a rollback option (`product_catalog_yesterday`).

The view swap is a single metadata commit in Trino. Readers see either the old definition or the new one — never an empty/missing table.

> **Important — the view-swap pattern only eliminates downtime for consumers that query the view, not the underlying base table directly.** Before deploying this pattern:
> - Audit all dashboard connections, BI tools, and downstream pipeline jobs.
> - Confirm every consumer uses the view name (e.g., `product_catalog_view`), not the raw table name (`product_catalog` or `product_catalog_staging`).
> - Any consumer pointing at the base table will continue reading stale data after the view swap, with no error — the failure is silent. A Looker dashboard pinned at `iceberg.analytics.product_catalog` will keep showing yesterday's numbers forever and no exception is raised.
>
> Practical audit: grep your BI tool's saved-query catalog, your dbt models, your Airflow SQL, and your application code for the raw table name. Every hit needs to be repointed at the view before the cutover.

#### Alternative: `overwritePartitions()` for partitioned tables

If the target Iceberg table is already partitioned by a useful key (e.g., `day(event_date)` for time-series data, or `tenant_id` for per-tenant rebuilds), **`overwritePartitions()` is a simpler atomic alternative to the staging-table + view-swap pattern.** When a full partition is rewritten via `overwritePartitions()`, Iceberg commits it as a single atomic snapshot — readers see either the old partition or the fully-written new one, never a partial state. No staging table, no view, no rename dance.

```python
# Atomic overwrite of a single date partition — no staging table needed.
# Readers see either the old May 24 partition or the fully-written new one.
df_for_date = df.filter(col("event_date") == "2026-05-24")
df_for_date.writeTo("iceberg.analytics.events").overwritePartitions()
```

**When `overwritePartitions()` is the right call:**
- The reload is partition-scoped (overwriting one day, one tenant, or one month — not the entire table).
- The table is already partitioned by that key.
- You don't need an explicit "keep yesterday's snapshot aside for rollback" handle — Iceberg's snapshot history already provides rollback via `rollback_to_snapshot` for ~7 days.

**When you still need the staging table + view swap pattern:**
- The table is **unpartitioned** (no partition key to scope the overwrite to).
- The reload **spans many partitions at once** (e.g., a full historical rebuild touching every day from 2020 onward — at that scale you want a fresh staging table and a single view swap, not hundreds of `overwritePartitions()` calls).
- You need an **explicit named rollback option** that survives `expire_snapshots` (the renamed `product_catalog_yesterday` table can be kept indefinitely; Iceberg snapshots get expired on the maintenance schedule).
- The full reload must be **validated end-to-end** (row counts, business rule checks) before any reader sees it. With staging + view swap, validation runs against the staging table; readers see nothing until the view swap commits. With `overwritePartitions()`, the new partition is live the moment the write commits.

### Pattern B — Incremental append (the common case)

Read only rows changed since the last run, then append to Iceberg.

```python
last_ts = read_watermark()  # e.g. from a small state file in MinIO
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM public.events WHERE updated_at > '{last_ts}') sub",
    properties=PG_PROPS,
)
# IMPORTANT: persist() before consuming df twice (once for the write, once for
# the watermark calculation below). Without persist(), Spark's lazy evaluation
# re-triggers the JDBC read a second time when df.agg(...) runs — doubling the
# Postgres read load and the wall-clock cost of every incremental run. On a
# 400M-row table this is the difference between one 12-minute pull and two of
# them back-to-back. Use MEMORY_AND_DISK so a large delta can spill rather
# than fail with OOM.
df.persist()
df.writeTo("iceberg.analytics.events").append()
write_watermark(df.agg({"updated_at": "max"}).collect()[0][0])
df.unpersist()  # free the cached blocks once both consumers are done
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

### Choosing the watermark column: `updated_at` vs `created_at` vs `xmin`

The single most consequential decision in the whole incremental pipeline. Pick wrong and you'll silently miss data — usually for weeks before someone notices a number is off. Each option has a specific failure mode you need to plan for.

| Watermark column | Catches inserts | Catches updates | Catches hard deletes | Index-friendly | Primary failure mode |
|---|---|---|---|---|---|
| `created_at` | Yes | **NO** | No | Usually yes (often correlated with PK) | **Updates to existing rows are never re-synced.** Iceberg copy goes stale silently. |
| `updated_at` | Yes | Yes (if the app maintains it) | No | Only if you add the index (see preflight) | Backdated `updated_at` values (migrations, backfills) silently skipped. Late-arriving rows trip up `overwritePartitions()`. |
| `xmin` (Postgres system column) | Yes | Yes | No | **No** — system columns aren't indexable; needs paired time bound | Wraps at ~4B transactions; values aren't comparable across replicas or restores. |

**The default choice for almost every SaaS pipeline: `updated_at`.** It catches both inserts and updates, which is what an analytical replica actually needs. The application or ORM should set `updated_at = now()` on every INSERT and every UPDATE — most Rails/Django/Laravel apps do this automatically; for raw-SQL apps, add a trigger so a misbehaving service can't silently break the pipeline:

```sql
-- Postgres: keep updated_at fresh on every UPDATE without trusting app code.
CREATE OR REPLACE FUNCTION touch_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER events_touch_updated_at
BEFORE INSERT OR UPDATE ON events
FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
```

Without the trigger, a single service that runs `UPDATE events SET status='processed' WHERE ...` without touching `updated_at` makes those rows invisible to your watermark forever.

**When to choose `created_at` instead.** Only when the source rows are **immutable after insert** — true event streams (`page_views`, `auth_attempts`, `webhook_deliveries`, `audit_log`). For these tables the row never changes; only new rows ever appear; `created_at` is the most index-friendly choice (it's monotonically increasing and usually highly correlated with the primary key, so range scans are sequential I/O on the heap).

**When to choose `xmin`.** Only after you've hit the backdated-`updated_at` problem in production and the Pattern A/C reconciliation safety-net (covered below) has become operationally painful. `xmin` is set by Postgres at commit time and cannot be backdated by application code — that immunity is its appeal. The cost is the wraparound risk and the lack of an index. See the "xmin as a backdating-immune watermark" subsection below for the full setup.

**Decision tree:**

1. **Is the table append-only (rows never change after insert)?** → Use `created_at`. Cheapest, simplest, no failure modes that matter for an immutable table.
2. **Does the table see UPDATEs and the app reliably maintains `updated_at`?** → Use `updated_at`. Run the Postgres index preflight (below), use MERGE INTO (not `overwritePartitions()`) for the write, add a lag buffer of ~2x your replica P99 lag.
3. **Does the table see UPDATEs and you've been burned by stale-row reconciliation?** → Use `updated_at` + scheduled weekly Pattern A/C reconciliation (below). If that's still painful, escalate to `xmin` + paired time bound.
4. **Do you need sub-minute freshness or accurate hard-DELETE propagation?** → None of the watermark options can do this. Move to Pattern C (CDC via Debezium) — it streams the Postgres WAL directly and captures every INSERT/UPDATE/DELETE the moment it commits.

**The trap to avoid: using `created_at` on a table that gets UPDATEs.** This is the most common new-pipeline mistake. The job runs green forever. New rows show up correctly. Updates to existing rows (status changes, soft-deletes, score recalculations) never make it to Iceberg. Dashboards show wrong numbers for weeks. The fix is to switch to `updated_at` — and you also need a one-shot full-table reconciliation (Pattern A below) to repair all the rows that drifted during the `created_at` era. Better: don't pick `created_at` unless you can prove the source rows are truly immutable.

**Switching from `created_at` to `updated_at` mid-pipeline — checklist:**

1. Run the Postgres index preflight: `SELECT indexname FROM pg_indexes WHERE tablename='events' AND indexdef LIKE '%updated_at%'`. Add `CREATE INDEX CONCURRENTLY` if missing.
2. Switch the Spark job's `WHERE` clause from `created_at > '{last_ts}'` to `updated_at > '{last_ts}'`.
3. Switch the write API from `.append()` to MERGE INTO so updates to existing rows update the corresponding Iceberg rows in place, instead of double-inserting them.
4. Reset the watermark to `'1970-01-01'` for one run to backfill every UPDATE that happened during the `created_at` era. This is expensive but one-time; it's the cost of fixing the original bad choice.
5. Re-cut the watermark to the current `max(updated_at)` after the backfill completes; resume normal incremental cadence.

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

**Fix #2: `pushDownPredicate` (default is already `true` — set explicitly only for documentation clarity).** A common myth in older Spark JDBC tutorials is that you must set `"pushDownPredicate": "true"` to prevent Spark from fetching all rows and filtering them in-memory on the executor. **This is wrong.** `pushDownPredicate` **defaults to `true`** in Spark JDBC's DataSourceV1 and V2 connectors — predicate pushdown is enabled out of the box. Setting it explicitly does not change default behavior; it's only worth including as a documentation hint that "yes, we know about this property and we want it enabled."

The real reasons a `WHERE` clause might fail to push down to Postgres (causing Spark to pull more rows than expected) are:

- **Cast-incompatible predicates.** Comparing a Postgres `numeric` column to a Spark/Java `Double` literal forces a type coercion that the JDBC dialect may decline to translate into a server-side comparison. The predicate runs in Spark instead.
- **Non-translatable expressions.** User-defined functions, Spark-specific operators (`rlike`, certain `array_contains` shapes), or complex `CASE WHEN` predicates may not have a documented translation to Postgres SQL — the JDBC dialect skips translation rather than guessing, and the filter falls back to executor-side.
- **Complex JOIN predicates inside the subquery.** A `dbtable` subquery with cross-table conditions can produce predicate fragments that the Spark planner cannot guarantee preserve semantics if pushed down.

**How to diagnose pushdown failures.** Run `df.explain(True)` in Spark and look at the **`PushedFilters`** field of the JDBC scan. If your watermark filter (`updated_at > '...'`) appears in `PushedFilters`, pushdown worked. If it's absent or shows up under `PostScanFilters` instead, the filter is running in Spark — investigate the cast/expression cause. Compare with Postgres `EXPLAIN` on the same query to confirm what's actually executing on the source.

If you see unexpectedly high row counts in Spark executor logs versus what Postgres `EXPLAIN` would predict for the same `WHERE` clause, a cast mismatch is the most likely culprit — explicitly cast both sides of the predicate to the same Postgres type and re-check the `explain`.

```python
PG_PROPS = {
    "user": PG_USER,
    "password": PG_PASS,
    "driver": "org.postgresql.Driver",
    "pushDownPredicate": "true",   # documentation-clarity only — this IS the default
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

Or use pg_partman's `reapply_indexes.py` **shell script** to apply the parent's index set across all children in one command. Note: this is a **Python script**, NOT a SQL function — it is invoked from the shell, not from psql:

```bash
# Shell invocation — runs from a host that has Python + pg_partman's bin/ scripts available.
python3 /path/to/pg_partman/bin/reapply_indexes.py \
    -p public.events \
    -c "host=pg-primary dbname=app user=admin" \
    -i
```

> **WARNING — `partman.reapply_indexes()` is NOT a SQL function. Do not run it in psql.** This is a common copy-paste trap. Earlier versions of this guide (and many third-party blog posts) show `SELECT partman.reapply_indexes('public.events')` as if it were a SQL-callable procedure. **It is not.** pg_partman ships `reapply_indexes` only as a Python script in its `bin/` directory; there is no equivalent SQL function or stored procedure. Running it in psql produces an immediate error:
>
> ```
> ERROR: function partman.reapply_indexes(unknown) does not exist
> LINE 1: SELECT partman.reapply_indexes('public.events');
>                ^
> HINT: No function matches the given name and argument types.
> ```
>
> The two correct alternatives are:
>
> 1. **The `reapply_indexes.py` shell script shown above** — the canonical pg_partman path when you have access to the partman installation's `bin/` directory.
>
> 2. **A manual `CREATE INDEX CONCURRENTLY` loop generated from `information_schema.tables`** — the SQL-only fallback when the shell script isn't available:
>
>    ```sql
>    -- Step 1: generate the DDL for every child partition that's missing the index.
>    -- This SELECT returns one row per child needing the index — copy the `ddl` column
>    -- contents into a separate psql session and execute each statement individually.
>    SELECT format(
>      'CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_%I_updated_at ON %I (updated_at);',
>      tablename, tablename
>    ) AS ddl
>    FROM information_schema.tables
>    WHERE table_schema = 'public'
>      AND tablename LIKE 'events_p%'             -- pg_partman child naming pattern
>      AND tablename NOT IN (
>        SELECT tablename FROM pg_indexes
>        WHERE indexdef LIKE '%updated_at%'
>      );
>
>    -- Step 2: execute each generated `CREATE INDEX CONCURRENTLY` statement in its
>    -- own transaction. CONCURRENTLY cannot run inside a transaction block, so do NOT
>    -- wrap them in BEGIN/COMMIT and do NOT run them inside a single `DO $$ ... $$` block.
>    ```

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

**Fix #6: `fetchsize` JDBC parameter.** Add `"fetchsize": "10000"` (or similar) to the JDBC properties. The pgjdbc driver's default fetch size is **0 (fetch all rows at once into memory)**. On a 500M-row table, fetching all rows into a single in-memory buffer before Spark can process them causes executor heap exhaustion. Setting `fetchsize=10000` tells pgjdbc to stream 10,000 rows per round-trip instead, keeping memory use bounded. Numbers between 5,000 and 50,000 are reasonable; go higher only if executor memory allows. Bumping from the default to 10,000 typically halves memory pressure and significantly improves throughput.

> **CRITICAL — pgjdbc silently ignores `fetchSize` when the connection is in `autoCommit=true` mode (which is pgjdbc's default).** This is the most common copy-paste trap when the same JDBC snippet is reused outside Spark. Per the [pgjdbc cursor-fetch docs](https://jdbc.postgresql.org/documentation/query/#getting-results-based-on-a-cursor), server-side cursors (the mechanism that makes `fetchSize` actually stream rows in batches) require the connection to be in `autoCommit=false` mode. If the connection is in `autoCommit=true`, pgjdbc throws the `fetchSize` value away without warning and fetches **all rows at once** — exactly the behavior `fetchSize` was supposed to prevent. **Spark's JDBC reader is safe**: it explicitly sets `autoCommit=false` on every read connection before issuing the query, so `"fetchsize": "10000"` in `PG_PROPS` works as documented when used through `spark.read.jdbc(...)`. **The same snippet is silently broken if pasted into:**
> - A plain JDBC script using the default `Connection` (autoCommit=true unless you explicitly call `conn.setAutoCommit(false)`).
> - A connection-pool client (HikariCP, DBCP, etc.) where the pool's default is autoCommit=true.
> - A psycopg2 / SQLAlchemy / generic Python JDBC bridge that doesn't toggle autoCommit before the query.
>
> No exception is raised; the query "works," memory blows up on the first large result set, and engineers waste hours wondering why `fetchSize` "didn't take effect." If you're reusing this JDBC properties block outside Spark, explicitly call `conn.setAutoCommit(false)` (or the pool/client's equivalent) before issuing the SELECT, and keep the read inside an open transaction — cursor-based fetch requires the transaction to remain open for the cursor's lifetime. Inside Spark this is handled automatically; outside Spark it is your responsibility.

**Summary checklist before deploying ingestion against a pg_partman source:**

1. Scope `dbtable` subqueries to specific child partitions (this month + last month), not the parent.
2. `pushDownPredicate` defaults to `true` in JDBC properties (set it explicitly only for documentation clarity; the default IS pushdown-enabled). Diagnose actual pushdown failures via `df.explain(True)` + the `PushedFilters` field — see Fix #2 above.
3. Verify every child partition has an index on the watermark column; backfill missing ones with `CREATE INDEX CONCURRENTLY` (looped via the `information_schema.tables` DDL-generator pattern shown above), or with pg_partman's `reapply_indexes.py` **shell script** (NOT a SQL function — see the warning above).
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
>  # See the timestamptz handling note below — use datetime.utcnow() for the comparison.
>  safe_upper = min(datetime.utcnow(), replay_ts)
>  ```
>
>  **`timestamptz` handling note.** `pg_last_xact_replay_timestamp()` returns `timestamp with time zone` (`timestamptz`) on the Postgres side. When the value is read through JDBC + Spark and collected into Python, the JDBC driver typically converts it to a **UTC-naive `datetime`** object (not a tz-aware one). This matters for the `min(..., replay_ts)` comparison: use `datetime.utcnow()` (UTC-naive, matches the converted `replay_ts`) — NOT `datetime.now()`, which returns local time and will compare incorrectly if your Spark driver runs in a non-UTC timezone (you'd get a result that's hours off from real wall-clock UTC). If you need tz-aware comparisons end-to-end, explicitly attach UTC to both sides: `replay_ts.replace(tzinfo=timezone.utc)` and `datetime.now(timezone.utc)`. The safe default is UTC-naive everywhere — match what the JDBC driver hands you.
>
>  If your ingestion job's `dbtable` subquery reads from the replica (e.g., `jdbc:postgresql://pg-replica:5432/...`), use the replica URL for the lag check too. If you have multiple replicas behind a load balancer, the lag may differ between them — query each one or pin the ingestion job to a single replica for the duration of the run.

### Reading from a Postgres read replica — what can go wrong

Pointing Spark at a read replica for a large initial bootstrap (e.g., the 300M-row first load of a fact table) is the **standard** pattern — it offloads the heavy analytical read from the primary so the production app keeps serving traffic. The problem is that a streaming read replica has two safety mechanisms that can silently break long-running Spark scans, and engineers usually do not learn about either one until their bootstrap fails 90 minutes in with a cryptic error. The two mechanisms are `max_standby_streaming_delay` and `hot_standby_feedback`; understanding them up front saves a multi-hour debugging session.

**The #1 production surprise: `ERROR: canceling statement due to conflict with recovery`.** This is the canonical error message you will see in Spark executor logs when a long-running JDBC read on a Postgres replica is killed by the replica itself. The chain of events:

1. Spark opens a JDBC connection to the replica and starts streaming rows from `events` for a 300M-row bootstrap. The fetch takes ~90 minutes wall-clock.
2. During that 90 minutes, the primary runs a `VACUUM` (or `ALTER TABLE`, or any operation that updates the visibility map) on `events`. The resulting WAL record arrives at the replica. (VACUUM is the canonical cause; any conflicting WAL-apply — exclusive lock, btree page cleanup, index page deletion, even a routine HOT-chain prune — can also trigger this. VACUUM is what most engineers see first because it runs continuously in the background, but the failure mode is "any WAL record that needs a lock conflicting with the long-running read," not specifically VACUUM.)
3. The WAL apply on the replica needs to grab a lock that conflicts with Spark's open read transaction. Postgres pauses WAL apply, waiting for Spark to finish.
4. After **`max_standby_streaming_delay`** (Postgres default: **30 seconds**), the replica gives up waiting, cancels Spark's query, and resumes WAL apply. Spark sees:
   ```
   ERROR: canceling statement due to conflict with recovery
   DETAIL: User query might have needed to see row versions that must be removed.
   ```
5. The Spark task fails. The bootstrap dies. The Iceberg target is partially populated.

This **does not happen against the primary** — only against replicas — because only replicas apply WAL. Engineers who tested the bootstrap script against a small dev replica (with no concurrent primary write activity) never trip the error; it only shows up under production load.

**The mitigation: `hot_standby_feedback`.** Setting `hot_standby_feedback = on` on the replica tells the replica to send "I have a long-running query that needs these row versions" feedback to the primary. The primary then holds off VACUUM and similar cleanup operations on those row versions, preventing the WAL-conflict cancellation entirely. This option has been available since **Postgres 9.1** (do not let anyone tell you it requires Postgres 12 or later — it was added in 9.1 and has worked the same way ever since). With `hot_standby_feedback = on`:

- Long Spark scans on the replica run to completion without `canceling statement` errors.
- The replica continues to apply WAL normally; no replication lag from the feedback itself.

**The trade-off: primary table bloat.** `hot_standby_feedback = on` causes the **primary** to retain WAL segments and dead tuples for longer (because the primary is now obligated to keep the row versions the replica is still reading). On a write-heavy primary, this can cause:
- Increased table bloat (dead tuples accumulating in heap files faster than VACUUM can reclaim them).
- Increased WAL volume (slot retention holds WAL segments until the replica reports completion).
- Possible disk-pressure incidents on the primary if a long-running replica query (Spark bootstrap) runs for many hours.

The trade-off is **stability of long Spark reads vs primary bloat**. For a one-shot bootstrap that takes ~90 minutes, the bloat impact is usually tolerable; for a recurring nightly job that takes 4 hours, the cumulative bloat on the primary can become a real ops problem.

**Recommended mitigation strategy — flip `hot_standby_feedback` ON for the bootstrap, then back OFF afterward.** This gets you the safety during the long-running read without paying the ongoing bloat cost:

```sql
-- ON THE REPLICA, before starting the bootstrap.
-- Requires superuser (or membership in pg_read_all_settings + a config reload mechanism).
-- The ALTER SYSTEM writes the change to postgresql.auto.conf; pg_reload_conf()
-- makes it take effect without restarting Postgres.
ALTER SYSTEM SET hot_standby_feedback = on;
SELECT pg_reload_conf();

-- Verify the change took effect (the setting should now be 'on'):
SHOW hot_standby_feedback;
```

```bash
# Run the Spark bootstrap job now. It will not be cancelled by max_standby_streaming_delay
# because the replica is signaling the primary to hold off on conflicting cleanup.
spark-submit --master k8s://... bootstrap-events.py
```

```sql
-- AFTER the bootstrap completes, revert hot_standby_feedback to its prior value
-- (typically off) so the primary stops retaining WAL/dead tuples on the replica's behalf.
ALTER SYSTEM SET hot_standby_feedback = off;
SELECT pg_reload_conf();
```

**Alternative: bump `max_standby_streaming_delay` to unlimited for the bootstrap window.** If you cannot get `hot_standby_feedback` changed (e.g., the DBA team owns it and the change ticket takes 3 days), the second-best mitigation is to extend `max_standby_streaming_delay` on the replica so the replica patiently waits for Spark instead of cancelling it. Setting it to `-1` means "wait forever":

```sql
-- ON THE REPLICA, before bootstrap. -1 = wait indefinitely for queries to finish
-- before applying conflicting WAL. The downside is that replication lag will
-- spike (the replica falls further behind the primary while it waits for Spark).
ALTER SYSTEM SET max_standby_streaming_delay = -1;
SELECT pg_reload_conf();

-- Run the bootstrap...

-- After bootstrap, revert to the prior value (typically 30s).
ALTER SYSTEM SET max_standby_streaming_delay = '30s';
SELECT pg_reload_conf();
```

**Which mitigation is preferable?** Prefer `hot_standby_feedback = on` over `max_standby_streaming_delay = -1`. With `hot_standby_feedback`, the replica keeps up with WAL apply (no lag); the cost lands on the primary as deferred cleanup. With `max_standby_streaming_delay = -1`, the replica accumulates replication lag for the entire duration of the bootstrap, and **any other reader on that replica sees stale data the whole time**. The lag-cost path is usually worse than the bloat-cost path because it affects every consumer of the replica.

**Quick decision table:**

| Scenario | Recommended setting | Why |
|---|---|---|
| One-shot bootstrap (~hours), replica is dedicated to analytics | `hot_standby_feedback = on` during the run, then revert | Primary bloat is bounded; replica stays current for other readers |
| Bootstrap on a replica shared with prod reads | `hot_standby_feedback = on` during the run, then revert | Same reasoning; lag spike on a shared replica is worse than primary bloat |
| Nightly recurring 4-hour read | `hot_standby_feedback = on` PERMANENTLY, plus monitor primary bloat weekly | Flipping it every night is operationally fragile; accept the bloat cost and monitor |
| Replica with no DBA access; cannot change settings | Run the bootstrap against PRIMARY instead | Eat the primary-side I/O cost; do not point Spark at a replica you cannot tune |
| Replica config locked, primary too loaded to use | Break the bootstrap into smaller transactional units (e.g., per-day partition reads) so each individual JDBC scan finishes within `max_standby_streaming_delay` | Last-resort workaround; significantly slower than a single large read |

**Add `statement_timeout` and `idle_in_transaction_session_timeout` as safety nets too.** Even with the right mitigations above, a Spark job that hangs (e.g., the executor JVM stalled on GC, the driver lost contact with executors) can hold a transaction open on the replica indefinitely — blocking VACUUM on the primary forever if `hot_standby_feedback = on`. Set per-connection timeouts on the JDBC properties:

```python
PG_PROPS = {
    "user": PG_USER,
    "password": PG_PASS,
    "driver": "org.postgresql.Driver",
    "pushDownPredicate": "true",
    "fetchsize": "10000",
    # Belt-and-suspenders: kill any single JDBC statement that runs past 4 hours.
    # Tune to slightly longer than your worst-case expected query.
    "options": "-c statement_timeout=14400000 -c idle_in_transaction_session_timeout=900000",
}
```

The `statement_timeout` (14400000 ms = 4 hours) caps how long a single query can run; `idle_in_transaction_session_timeout` (900000 ms = 15 min) kills sessions that sit idle with an open transaction. Both protect the replica + primary from a wedged Spark client even when ops mitigations are in place.

**Verification: monitor for the error class in production.** After your first bootstrap, grep Spark executor logs for the canonical strings:
- `canceling statement due to conflict with recovery` — `max_standby_streaming_delay` fired; mitigation needed.
- `terminating connection due to administrator command` — `statement_timeout` or DBA killed the session.
- `terminating connection due to idle-in-transaction timeout` — `idle_in_transaction_session_timeout` fired.

If you see any of these in production after deploying the mitigations, the values are too aggressive — investigate before re-running.

### Choosing `numPartitions` — sizing against the replica connection budget

`numPartitions` is the Spark JDBC option that controls **how many parallel JDBC connections** Spark opens to Postgres for a single read. Earlier sections show `numPartitions=16` as a starting value, but **16 is not a universal answer** — picking it correctly requires balancing Spark executor parallelism against the source Postgres replica's `max_connections` budget (which is shared with Trino, your application, and monitoring tools on the same on-prem cluster). Pick too low: the read serializes on a single Spark task and the bootstrap takes 10x as long as needed. Pick too high: Spark consumes every available Postgres connection and **other services on the cluster start failing with "remaining connection slots are reserved for non-replication superuser connections"**.

**Rule of thumb:** `numPartitions` = number of Spark executor cores available for this job, **capped at** the replica's `max_connections` minus connections already used by other services (Trino, application reads, monitoring, replication).

**Concrete sizing procedure for the on-prem stack** (where Trino, Spark, and the production app all share one Postgres replica):

1. **Find the replica's `max_connections`:**
   ```sql
   -- On the replica
   SHOW max_connections;   -- typical values: 100, 200, 500
   ```

2. **Measure current connection usage during peak load.** Use `pg_stat_activity` to see what's actually connected right now. Filter out idle-on-client connections so you're counting real backend work:
   ```sql
   -- Run during peak Trino load (e.g., when the daily dashboard refresh hits).
   -- wait_event_type != 'Client' excludes connections that are sitting idle
   -- waiting for the next query from the client — those don't count against
   -- the backend's compute budget the way active queries do, but they DO
   -- count against max_connections. So look at BOTH numbers.
   SELECT count(*) AS active_backends
   FROM pg_stat_activity
   WHERE wait_event_type IS DISTINCT FROM 'Client';

   SELECT count(*) AS total_connections, application_name
   FROM pg_stat_activity
   GROUP BY application_name
   ORDER BY count(*) DESC;
   ```

3. **Reserve baseline connection budgets for each service** so Spark cannot starve the cluster. Typical reservations:
   - Trino: at least 10 connections (each Trino worker holds a pool to the source; one Trino cluster can easily use 20-30 connections during heavy query load).
   - Application reads: at least 5 connections (the prod app must continue serving traffic during the bootstrap).
   - Monitoring (Datadog, Prometheus exporters, etc.): 2-3 connections.
   - Postgres internal overhead (autovacuum workers, WAL sender): 5-10 connections.

4. **Compute the Spark budget:** Spark budget = `max_connections` - sum of reservations.

**Worked example for a typical on-prem cluster:**

```
max_connections                          = 100
- Trino baseline (peak)                  = 20
- Application reads                      = 10
- Monitoring                             =  3
- Postgres internal (autovacuum, WAL)    =  7
- Safety headroom                        = 10  (always leave 10% slack for unexpected spikes)
                                          ----
Spark budget                             = 50

numPartitions = min(executor_cores, Spark budget) = min(60_cores, 50) = 50
```

So on this cluster, `numPartitions=50` is the maximum safe value during peak hours. If your Spark job has only 16 executor cores available, then `numPartitions=16` is the right value — Spark cannot use more parallelism than it has cores. If your job has 100 cores, you must still cap at the connection budget (50 in this example) regardless.

> **Reservations vs Postgres-internal connection budgets — what the table above abstracts away.** The worked example reserves "5-10 connections" for "Postgres internal overhead (autovacuum workers, WAL sender)", but in reality these are **separate budgets** that don't all come from the same `max_connections` pool:
> - **Autovacuum workers** are bounded by `autovacuum_max_workers` (default `3`) and have their own dedicated worker slots — they do NOT come from the general `max_connections` pool the way client backends do. Bumping `numPartitions` from 49 to 50 does not "steal" autovacuum's slots.
> - **`superuser_reserved_connections`** (default `3`) is a separate floor that Postgres reserves for superuser connections so a DBA can always log in even when the cluster is at the connection cap. These slots are subtracted from `max_connections` before regular client backends can claim a slot. On a `max_connections = 100` cluster, regular clients (Spark, Trino, app) actually share only `100 - 3 = 97` slots.
> - **WAL senders** (one per active replication slot / streaming replica) come from `max_wal_senders` (default `10`), again separate from `max_connections`.
>
> The table above uses **rough practical reservations** because in production what you actually need to know is "how many slots can my Spark job consume without breaking other services" — and the safest answer is to measure rather than compute from defaults. For precise budgeting on a cluster where the connection budget is tight, run this query to see actual Postgres-internal connection usage during peak load and subtract the result from `max_connections` instead of the "5-10" guess:
>
> ```sql
> -- Shows how many of the currently-allocated backends are Postgres-internal
> -- (autovacuum, WAL sender, walreceiver, logical replication launcher, etc.)
> -- vs how many are regular client backends (Spark/Trino/app connections).
> SELECT backend_type, count(*)
> FROM pg_stat_activity
> WHERE backend_type IS DISTINCT FROM 'client backend'
> GROUP BY backend_type
> ORDER BY count(*) DESC;
>
> -- Total non-client-backend usage (the actual "internal overhead" number to subtract):
> SELECT count(*) AS postgres_internal_connections
> FROM pg_stat_activity
> WHERE backend_type IS DISTINCT FROM 'client backend';
> ```
>
> Use the measured value to refine the worked example: if `postgres_internal_connections = 12` under your real workload (not the "5-10" estimate), update the Spark budget calculation accordingly. The "10% safety headroom" line in the example absorbs small mis-estimates, but on a `max_connections = 100` cluster a 5-connection under-estimate is the difference between a clean bootstrap and a `FATAL: remaining connection slots are reserved` failure mid-run.

> **When `max_connections` cannot be raised — use PgBouncer as a connection multiplexer.** If your replica's `max_connections` is fixed (e.g., the parameter is set in `postgresql.conf` by your DBA team and a restart is required to change it, or you're on a managed Postgres tier where bumping it requires an upgrade), consider routing Spark's JDBC reads through **PgBouncer** in **transaction-mode pooling**. PgBouncer is a lightweight Postgres connection pooler that sits between Spark and the replica: Spark's executors open as many "logical" connections as `numPartitions` says, but PgBouncer multiplexes those onto a much smaller pool of actual Postgres connections to the replica. In transaction-mode, a Postgres connection is leased to a Spark client only for the duration of a single transaction, then returned to the pool — so 50 Spark executors can share, say, 10 actual Postgres connections as long as their queries are individually short.
>
> The practical effect: PgBouncer **decouples `numPartitions` from the raw `max_connections` budget**. You can run `numPartitions=50` against a replica whose `max_connections=20` because only 10-15 of those Postgres-side connections are actually in use at any one moment. The trade-offs:
> - **Transaction-mode incompatibility with prepared statements and session state.** Server-side prepared statements, `SET LOCAL`, advisory locks, and any feature that relies on session state across transactions break in transaction-mode pooling because the next transaction may land on a different physical connection. The Spark JDBC driver typically does not use server-side prepared statements for simple `SELECT ... WHERE id BETWEEN ?` queries, but verify before deploying.
> - **One more failure point.** PgBouncer is another pod to operate, monitor, and patch. For one-shot bootstraps the value is questionable; for recurring nightly jobs it pays off quickly.
> - **Connection-establishment latency hides.** PgBouncer keeps connections warm, so Spark executors don't pay the ~5-20ms per-connection setup cost on every parallel task launch.
>
> On the on-prem stack described in `prod_info.md`, PgBouncer typically runs as a separate Deployment in the same Kubernetes namespace as the Postgres replica it fronts, with Spark's JDBC URL pointing at the PgBouncer service (`jdbc:postgresql://pgbouncer-svc:6432/app?...`) instead of the replica directly. The replica still has `max_connections = 100`, but only PgBouncer's pool size (say, 30) ever consumes those slots — leaving comfortable headroom for Trino, the app, and Postgres internals regardless of what `numPartitions` value Spark is using.

**For tables where the JDBC read is the bottleneck and you have spare executor capacity:** wait for an off-peak window (Trino's nightly maintenance window, application low-traffic hours) and re-measure step 2's `pg_stat_activity` count. The Spark budget at 3am may be 80 connections instead of 50, and you can run a much higher `numPartitions` for the duration of the off-peak job.

**Common mistakes to avoid:**

- **Setting `numPartitions=200` "to be safe."** This typically exceeds `max_connections` and triggers `FATAL: remaining connection slots are reserved...` errors on Spark side AND on Trino side (Trino fails to acquire its normal connection pool because Spark grabbed them all). The bootstrap fails AND production analytics fail simultaneously.
- **Setting `numPartitions=1` "to be conservative."** With one partition, the entire 300M-row read runs in a single Spark task on a single executor. The bootstrap that should take 90 minutes takes 12 hours. You're paying 8x the wall-clock time to "be safe" while the connection budget would have allowed 50x parallelism.
- **Not measuring Trino's actual usage.** Engineers assume "Trino uses ~5 connections" because that's what a quiet cluster looks like. Under peak query load, a single Trino cluster can spike to 30-50 connections (one per concurrent query, plus pool overhead). Measure during real peak load, not at 2pm on a quiet day.
- **Forgetting to coordinate with the DBA.** If your bootstrap will consume 50 connections for 90 minutes during business hours, the DBA team needs to know — both so they can pre-emptively bump `max_connections` if needed, and so that any other emergency operation (manual VACUUM, ad-hoc analytics) doesn't collide with the read.

**For `dbtable` subqueries without a clean monotonic id (non-numeric primary keys, composite keys, or text identifiers):** Spark JDBC's `partitionColumn / lowerBound / upperBound / numPartitions` requires a numeric column for partition stride math. If your table's primary key is a UUID or composite, you have two alternatives:

```python
# Alternative A: hash-bucket partitioning with a synthetic numeric column.
# Spark splits the read on a deterministic hash of the natural key.
df = spark.read.jdbc(
    url=PG_URL,
    table=(
        "(SELECT *, ('x' || substr(md5(account_uuid::text), 1, 8))::bit(32)::int AS hash_part "
        " FROM accounts) t"
    ),
    properties=PG_PROPS,
    column="hash_part",
    lowerBound=-2_147_483_648,
    upperBound=2_147_483_647,
    numPartitions=50,
)

# Alternative B: manual partition predicates via the `predicates` parameter.
# You hand Spark a list of WHERE clauses; one task runs per predicate.
# Useful when the natural partitioning is range-based (e.g., per-month).
predicates = [
    "created_at >= '2024-01-01' AND created_at < '2024-02-01'",
    "created_at >= '2024-02-01' AND created_at < '2024-03-01'",
    # ... one entry per month
]
df = spark.read.jdbc(
    url=PG_URL,
    table="accounts",
    properties=PG_PROPS,
    predicates=predicates,
)
```

Pattern A is simpler when you have any column you can hash (even a composite). Pattern B gives precise control when your data has natural range-based partitioning. Both consume one JDBC connection per partition — so the same `numPartitions` budget rules above apply.

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

### Diagnosing customer-correlated missing rows

A particularly confusing symptom in multi-tenant SaaS ingestion: "events are missing for **certain customers** but not others." This pattern is almost never random — it points at one of four specific causes, each with its own diagnostic and fix. Walk this checklist before assuming a generic replica-lag incident.

**1. Per-customer replica routing.** If your application uses a load balancer or read-replica router that pins different customers' connections to different Postgres replicas (e.g., a hash of `tenant_id` selects one of three replicas), and one of those replicas had a replication hiccup, **only the customers routed to that replica lose rows**. The other customers' incremental loads succeed because their replicas were healthy. Diagnose by checking which Postgres replica each affected customer's queries hit during the incident window — if all the missing-data customers share a single replica, you've found the cause.

```sql
-- On each replica, check current and recent replay lag.
-- If one replica reports significantly higher lag than the others, the customers
-- routed to it are the ones whose ingestion silently missed rows.
SELECT inet_server_addr() AS replica_host,
       pg_last_xact_replay_timestamp() AS last_replay,
       EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp())) AS lag_seconds
FROM pg_stat_replication;
```

Fix: backfill the affected customers using the detection recipe above, reading from PRIMARY (which is consistent across all customers regardless of replica routing). After the backfill, audit your replica-routing layer's health checks — if a replica is so far behind that it silently misses rows, it should be removed from the routing pool, not still serving traffic.

**2. Customer-specific query filters in the JDBC subquery.** If your ingestion job loads per-customer increments (e.g., one Spark task per customer with `WHERE customer_id = '...'`), a bug in the customer-list generation logic silently omits specific customers from the batch. The customers that ARE in the list load correctly; the ones missing from the list never get processed at all — no error, just no data.

Diagnose by logging the **exact set of customer IDs** the ingestion job processes on each run, then diff that set against the source-of-truth customer table:

```sql
-- On Postgres PRIMARY: list every customer that has had recent activity.
SELECT DISTINCT customer_id FROM events WHERE updated_at > now() - interval '1 day';

-- Compare against the customer IDs your Spark job logged for the same window.
-- Any customer in the Postgres set but missing from the Spark job's processed list
-- is the silent skip — fix the customer-list query in your job.
```

A common shape of this bug is a missing `OR status IS NULL` clause when filtering active customers (newly-onboarded customers may have NULL status briefly), or a stale cached list that doesn't include customers added since the cache was populated.

**3. pg_partman constraint exclusion misconfigured.** pg_partman relies on **constraint exclusion** to direct queries against the parent table to the right child partition — Postgres reads the child table's CHECK constraints and skips children whose constraints prove they can't contain any matching rows. If the server-level settings `constraint_exclusion` or `enable_partition_pruning` are disabled, queries against the parent fan out to **all 36 children** instead of being pruned to the relevant one. Some children may then time out (especially for customers whose data lives in older, larger child partitions), and depending on your Spark job's retry config, the timeout may translate to a silently-dropped task instead of a job failure.

Verify the settings on the **replica** the ingestion job reads from:

```sql
-- Check both settings on the replica. Both must be 'on' (or 'partition') for
-- pg_partman to prune children correctly.
SHOW constraint_exclusion;        -- expected: 'partition' or 'on'
SHOW enable_partition_pruning;    -- expected: 'on'

-- If either is 'off', enable it (requires reload, not restart):
-- (Do this on each replica AND the primary, then pg_reload_conf().)
ALTER SYSTEM SET constraint_exclusion = 'partition';
ALTER SYSTEM SET enable_partition_pruning = on;
SELECT pg_reload_conf();
```

Customers whose data is concentrated in a single large child partition (e.g., a customer who onboarded 18 months ago and has all their history in `events_p2024_11`) are disproportionately affected by missing constraint exclusion, because their queries are the ones most likely to time out scanning unrelated children.

**4. Missing or stale per-child indexes on certain partitions.** A variant of cause 3: even with constraint exclusion working, if some older child partitions are missing the `updated_at` index (see Fix #3 in the pg_partman section above), queries against those children do full sequential scans and may time out — and the customers whose history lives in those particular child partitions appear customer-correlated in the missing-data pattern. Run the per-child-index audit query from Fix #3 to identify which children are missing indexes, and backfill them with `CREATE INDEX CONCURRENTLY` per child.

**5. Replica lag of 2-3 days is a major incident — not the case for LAG_BUFFER.** A common misuse of the `LAG_BUFFER` mechanism: someone notices the Iceberg copy is 2-3 days behind, increases `LAG_BUFFER` from 15 minutes to 3 days, and ships it. **This is wrong.** `LAG_BUFFER` is calibrated for **normal jitter** — replication latency that bounces between seconds and a few minutes due to network blips, vacuum storms, or momentary replica catch-up. A 2-3 day lag means the replica was **actually broken, restarting, or experiencing continuous replication failures during that window** — that's a P1 infrastructure incident, not a watermark-tuning problem. Setting a 3-day `LAG_BUFFER` "to be safe" creates 3 days of unnecessary data delay on every healthy run and re-reads 3 days of data on every batch (massive wasted Postgres I/O), while doing nothing to fix the underlying broken replica. The correct recovery is the **backfill recipe** in the previous subsection (compare Iceberg max against PRIMARY, MERGE INTO the gap), followed by a root-cause investigation of why the replica fell behind by days in the first place. Do **not** paper over an incident with a giant LAG_BUFFER.

### Backdated `updated_at` and the watermark-monotonicity hole

The `updated_at > last_watermark` pattern silently fails whenever the source application **decreases** `updated_at` on existing rows. Common real-world triggers:

- A data migration runs `UPDATE users SET updated_at = '2019-01-01' WHERE ...` to mark certain rows as legacy.
- A backfill script copies historical rows from an archive and writes the *original* `updated_at` rather than `now()`.
- An ORM with a buggy hook computes `updated_at` from a content field instead of wall-clock time.

In every case, the new `updated_at` is **less than** the current watermark, so the next incremental run's `WHERE updated_at > last_ts` filter never sees those rows. The Iceberg copy is permanently stale. No error fires.

**The fix has two parts: a one-shot repair for the rows you already missed, and a recurring safety net to catch the next occurrence.**

#### One-shot repair (already-missed rows from a known event)

If you know the date range that was touched (e.g., the migration script ran on a specific day and modified rows with `tenant_id IN (...)`), do a targeted MERGE INTO from Postgres ground truth:

```python
# Re-read the affected rows from Postgres PRIMARY and MERGE INTO Iceberg.
# This is idempotent — safe to re-run.
affected = spark.read.jdbc(
    url=PG_PRIMARY_URL,
    table=(
        "(SELECT * FROM users "
        " WHERE tenant_id IN (12, 47, 103) "
        "    OR (updated_at < '2020-01-01' AND created_at > '2023-01-01')) t"
    ),
    properties=PG_PROPS,
)
affected.createOrReplaceTempView("users_repair")
spark.sql("""
    MERGE INTO iceberg.analytics.dim_users t
    USING users_repair s
    ON t.user_id = s.user_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

**Do NOT use `overwritePartitions()`** for this repair — the dim_users table is rarely partitioned, and even if it is, `overwritePartitions()` replaces the entire partition with whatever's in the DataFrame, wiping legitimate rows that weren't in the repair query.

#### Recurring safety net — periodic reconciliation done correctly

Schedule a weekly (or daily, for high-mutation tables) reconciliation job that diffs Postgres against Iceberg and re-merges any drift. This is the single most important safety net for any pipeline that relies on `updated_at` as its sole watermark.

> **CRITICAL — do NOT filter the reconciliation by `pg.updated_at > iceberg.updated_at`.** This is the exact bug the backdated-update scenario exposes. A `>` comparison only catches **forward drift** (Postgres newer than Iceberg). When a migration sets `updated_at` to a years-ago date that is **less than** what Iceberg already has, the filter silently misses the very rows you most need to repair. Use one of the three correct patterns below.

**Correct pattern A — full MERGE INTO from a Postgres snapshot (simplest, for tables under ~50M rows).** Read every row from Postgres, MERGE into Iceberg. The MERGE updates rows whose content has changed regardless of which direction the `updated_at` moved — there is no filtered re-read, so there is no asymmetric comparison to get wrong.

```python
snapshot = spark.read.jdbc(
    url=PG_PRIMARY_URL,
    table="public.users",
    properties=PG_PROPS,
)
snapshot.createOrReplaceTempView("users_snapshot")
spark.sql("""
    MERGE INTO iceberg.analytics.dim_users t
    USING users_snapshot s
    ON t.user_id = s.user_id
    WHEN MATCHED AND (
        t.email      != s.email      OR
        t.plan       != s.plan       OR
        t.updated_at != s.updated_at        -- '!=' catches both forward AND backward drift
    ) THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

The key correctness property: the `WHEN MATCHED AND ...` clause uses `!=`, not `>`. Any difference in `updated_at` (forward OR backward) qualifies for the update. Add equivalent `!=` checks for every column whose drift you care about, OR compare a content hash (see Pattern C).

**Correct pattern B — primary-key set diff (catches missing/extra rows).** If your concern is rows that exist in Postgres but not Iceberg (or vice versa), compare primary-key sets directly. This is cheap because it scans only one column per side.

```python
pg_ids = spark.read.jdbc(
    url=PG_PRIMARY_URL,
    table="(SELECT user_id FROM users) t",
    properties=PG_PROPS,
).select("user_id")

ib_ids = spark.sql("SELECT user_id FROM iceberg.analytics.dim_users")

missing_in_iceberg = pg_ids.subtract(ib_ids)        # need to insert
extra_in_iceberg   = ib_ids.subtract(pg_ids)        # need to investigate (hard-deletes?)
```

Then re-read the rows whose `user_id` is in `missing_in_iceberg` from Postgres and INSERT into Iceberg, and decide whether `extra_in_iceberg` rows should be DELETE'd (depends on whether your source uses hard or soft deletes — see the Soft-delete sync pattern below).

> **Alternative: Trino `EXCEPT` for the same reconciliation, no Spark required.** Trino 467 supports the standard SQL `EXCEPT` set operator and the production stack includes a **PostgreSQL connector** for Trino — so you can run the entire reconciliation as a single Trino query, federating Postgres and Iceberg in the same SELECT. This is often the simplest operational form: no Spark job to schedule, no `spark.read.jdbc()` config, results stream straight to your terminal or a Slack alert. Example: find primary keys present in Postgres but missing from Iceberg (assumes a `postgres` catalog has been registered in Trino pointing at the source database):
>
> ```sql
> -- Run in Trino. Returns user_id values that exist in Postgres but NOT in Iceberg.
> SELECT user_id FROM postgres.public.users
> EXCEPT
> SELECT user_id FROM iceberg.analytics.dim_users;
>
> -- Reverse direction: rows in Iceberg but not in Postgres (potential hard-deletes
> -- or zombie rows that need cleanup).
> SELECT user_id FROM iceberg.analytics.dim_users
> EXCEPT
> SELECT user_id FROM postgres.public.users;
> ```
>
> **When to prefer Trino `EXCEPT` over Spark `subtract()`:** ad-hoc investigations, weekly heartbeat checks driven from a SQL dashboard, or any reconciliation small enough that a single Trino coordinator can hold both key sets in memory (typically tables under ~500M rows on the production cluster). **When to stick with Spark `subtract()`:** truly massive key sets where Trino's single-coordinator memory is a constraint, or when the same job will then re-read the missing rows from Postgres and `MERGE INTO` Iceberg in one Spark session (saves the round trip).

**Correct pattern C — content hash for drift detection (most precise, highest cost).** Compute a hash of the column values on both sides and compare. Any drift — including backdated `updated_at` — produces a hash mismatch.

```python
pg_hashes = spark.read.jdbc(
    url=PG_PRIMARY_URL,
    table=(
        "(SELECT user_id, "
        " md5(concat_ws('|', email, plan, updated_at::text)) AS h "
        " FROM users) t"
    ),
    properties=PG_PROPS,
)

ib_hashes = spark.sql("""
    SELECT user_id,
           md5(concat_ws('|', email, plan, cast(updated_at AS string))) AS h
    FROM iceberg.analytics.dim_users
""")

drifted = (
    pg_hashes.alias("p")
    .join(ib_hashes.alias("i"), "user_id", "left")
    .filter("i.h IS NULL OR p.h != i.h")
    .select("user_id")
)
# Re-read the drifted rows from Postgres and MERGE INTO Iceberg.
```

Pattern C is the gold standard — it catches every form of drift, including subtle ones like a NULL→empty-string change that timestamp comparisons cannot see. Cost: a per-row hash computation on both sides. Acceptable for weekly jobs on tables up to ~500M rows; for larger tables, run it monthly or sample-based.

**Picking between the three:**

| Pattern | Catches forward drift | Catches backward drift | Catches missing rows | Cost | Recommended for |
|---|---|---|---|---|---|
| A — full snapshot MERGE with `!=` | Yes | Yes | Yes (NOT MATCHED INSERT) | Medium (full Postgres read) | Tables < 50M rows |
| B — PK set diff | No (content drift not detected) | No (content drift not detected) | Yes | Lowest (one-column scan) | Cheap heartbeat — pair with A or C |
| C — content hash | Yes | Yes | Yes (left join NULL) | Highest (hash per row) | Tables 50M–500M rows where A is too expensive |

The **wrong** pattern that the production codebase often contains:

```python
# DO NOT USE — silently misses backdated updates.
# pg.pg_updated_at > COALESCE(ib.ib_updated_at, CAST('1970-01-01' AS TIMESTAMP))
```

If you find this filter in an existing reconciliation job, replace it with `!=` (Pattern A) or a hash comparison (Pattern C) before the next backdated migration hits production.

### Hard deletes are invisible to `updated_at`

> **WARNING — `WHERE updated_at > last_watermark` cannot detect a row that was physically DELETEd from Postgres.** A `DELETE` changes no columns on the deleted row — the row simply ceases to exist. There is no `updated_at = now()` event to trip your watermark filter. The stale copy already in Iceberg stays there indefinitely, silently. No error fires; row counts in Iceberg drift higher than Postgres week over week. This bites every team running an `updated_at`-based pipeline against a source where users can delete accounts, support agents can hard-delete records, or GDPR erasure requests must be honored.

**Three options for handling deletes, in order of recommendation:**

1. **Soft deletes (best for new systems).** Enforce `deleted_at TIMESTAMP` (or `status = 'deleted'`) on every mutable source table in Postgres. Replace every `DELETE FROM users WHERE id = ?` in your app code with `UPDATE users SET deleted_at = now(), updated_at = now() WHERE id = ?`. Now the soft-delete is a regular UPDATE: `updated_at` advances, the incremental load picks it up on the next run, and consumers filter out deleted rows in Iceberg via a `WHERE deleted_at IS NULL` view (see the **Soft-delete sync pattern** section above for the full Layer 1 / Layer 2 / Layer 3 recipe). Cost: a one-time audit of app code to find and convert every hard-DELETE call site.

2. **Debezium CDC (best when CDC infra already exists).** Debezium's PostgresConnector reads the WAL and emits `op = 'd'` events for every DELETE, with the primary key in the `before` field. A Spark Structured Streaming consumer applies these as `WHEN MATCHED AND s.op = 'd' THEN DELETE` in a MERGE INTO (see the **Pattern C — CDC** section below for the full MERGE shape). This gives full fidelity — hard deletes, soft deletes, and UPDATEs all propagate to Iceberg within seconds of commit. Cost: ~3x more moving parts (Debezium + Kafka + streaming consumer + exactly-once semantics). Only worth standing up if your org already operates Kafka, or if hard-DELETE fidelity is a hard product requirement (regulated industries, GDPR-strict SaaS).

3. **Periodic full-rekey reconciliation (acceptable when deletes are rare).** Once a week (or month), run the **primary-key set diff** described in Correct Pattern B above: `SELECT id FROM postgres_table` vs `SELECT id FROM iceberg_table`, compute `iceberg_ids.subtract(postgres_ids)`, and DELETE the orphaned keys from Iceberg. Cost: one full-key-set scan of both sides — cheap for tables under a few hundred million rows. Good fit for `accounts`, `tenants`, `subscriptions` tables where hard-deletes are infrequent and a week of staleness on deleted rows is tolerable. Poor fit for `messages` or `events` tables with constant deletion churn.

**Recommendation for most SaaS teams: option 1 (soft deletes).** It is the cheapest to operate (no extra infrastructure), eliminates the blind spot entirely, and composes naturally with the rest of the `updated_at` pipeline. Reserve option 2 for cases where Debezium is already running for other reasons. Use option 3 as a safety-net reconciliation even on soft-delete systems — it also catches rows that were hard-deleted in Postgres before your team finished migrating away from DELETE calls.

### xmin as a backdating-immune watermark

The `xmin` system column on every Postgres row holds the transaction ID that last wrote the row. Critically, **`xmin` is set by the database engine at commit time** — application code cannot backdate it. Using `xmin` as the watermark eliminates the entire backdated-`updated_at` failure mode.

```python
last_xmin = read_xmin_watermark()
df = spark.read.jdbc(
    url=PG_URL,
    table=(
        f"(SELECT *, xmin::text::bigint AS row_xmin "
        f" FROM users "
        f" WHERE xmin::text::bigint > {last_xmin}) t"          # naive comparison — see warning below
    ),
    properties=PG_PROPS,
)
```

**Tradeoffs to know before adopting xmin:**

- **xmin is local to one physical Postgres instance.** Don't rely on `xmin` values being comparable across replicas, logical-replication targets, or after a dump/restore migration. The transaction ID space is local to the cluster's WAL history. (Note: `pg_upgrade` preserves next-XID and epoch — it does not reset xmin on existing tuples — but a physical replica created via base-backup will have the same xmin space as the primary, while a logical-replication subscriber will have entirely different xmin values.) Pin the ingestion job to one specific instance (typically PRIMARY) for the watermark.
- **xmin wraps at ~4 billion transactions.** On a busy database this can happen within a year or two. **Naive `xmin > last_xmin` comparison is incorrect across the wrap point** — at wraparound, the new xmin starts from a small number again and would appear `< last_xmin`, causing the ingestion job to skip every row written after the wrap until the new xmin catches up to the old value. Most teams never hit wraparound, but if your pipeline has run for years against a high-write database, the correct comparison uses modular arithmetic via Postgres's built-in `age()`:

  ```sql
  -- Correct wraparound-safe comparison: rows whose xmin is "younger" than the watermark.
  -- age(xmin) returns the modular distance from the current transaction ID,
  -- handling the 32-bit wraparound correctly.
  WHERE age(xmin) < age('{last_xmin}'::xid)
  ```

  Or use `txid_current()` / `txid_snapshot_xmax()` (64-bit transaction IDs with an epoch counter, so no wraparound within any realistic pipeline lifetime). Plain `>` on the raw 32-bit xmin is fine for short-lived pipelines but **not** for pipelines expected to outlive a wraparound.

- **No index on `xmin`.** Filtering by `xmin` cannot use an index (it's a system column). On large tables this forces a full sequential scan per run. Mitigation: pair xmin with a coarse time bound (`WHERE updated_at > now() - interval '7 days' AND xmin::text::bigint > {last_xmin}`) so the planner can index-scan the time bound first and only check xmin on the surviving rows.

**Recommendation.** Start with `updated_at` watermark plus the Pattern A safety-net reconciliation (above). Upgrade to xmin only if backdating events are recurring and the operational overhead of the reconciliation has become painful.

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

> **Common misconception — the soft-delete pattern does NOT produce fewer Iceberg delete-file markers than the hard-DELETE pattern.** A widely repeated but incorrect framing says "soft-delete UPDATEs in Postgres → fewer position delete files in Iceberg than hard DELETEs." This is wrong. In Iceberg MoR, an **UPDATE is internally implemented as a delete-of-the-old-row plus an insert-of-the-new-row** — every UPDATE produces a position delete marker for the old row plus a new data row. A soft-delete UPDATE (`UPDATE ... SET deleted_at = now()`) is therefore **not** cheaper at the Iceberg storage layer than a hard DELETE — both go through MoR and both produce position delete files at roughly equivalent volume. **The real benefit of the soft-delete pattern is timing control**, not marker volume: the soft-delete UPDATEs accumulate in the Iceberg table during the day, and the layer-2 cleanup sequence (`DELETE WHERE deleted_at IS NOT NULL` + `rewrite_data_files` + `expire_snapshots`) runs once during a maintenance window when nobody is reading the table. You batch the delete-file write into a single predictable job rather than amortizing it across every CDC mini-batch. The hard-DELETE-via-Debezium path, by contrast, splatters delete-file writes across every minute of the day, every time a user clicks "delete account" — same total marker volume, much worse temporal distribution. Recommend the soft-delete pattern for timing-control reasons, not for marker-volume reasons.

**Future state — CDC via Debezium.** The clean long-term solution for high-mutation tables is CDC: Debezium captures every `UPDATE ... SET deleted_at` event from the Postgres WAL as a row-change message and pushes it to Kafka. A Spark Structured Streaming job consumes the stream and drives a **hard DELETE** in Iceberg as soon as the Postgres soft-delete commits. This eliminates the zombie-row problem entirely (the soft-delete UPDATE is captured the moment it commits, regardless of incremental watermark windows) and gives you sub-minute delete propagation. Cost: ~3x more moving parts (Debezium connector, Kafka, streaming consumer, exactly-once semantics). Worth it for tables where soft-deletes are frequent (e.g., a `messages` table where users delete sent messages all day); overkill for an `accounts` table where churn is monthly. See Pattern C below for the broader CDC setup.

### Pattern C — CDC (Change Data Capture) — advanced

Debezium reads the Postgres write-ahead log (WAL), publishes row-change events to Kafka, Spark Structured Streaming consumes from Kafka and merges into Iceberg.

- **When to use:** you need < 5 minute freshness, or you must capture hard DELETEs and UPDATEs accurately.
- **Complexity:** ~3x more moving parts (Debezium, Kafka, streaming job, exactly-once semantics). Don't start here.
- **On-prem reality:** Debezium and Kafka both run on Kubernetes; the prod stack supports it, but you own the ops burden.

> **CALLOUT — REPLICATION SLOT WAL BLOAT IS THE #1 DEBEZIUM PRODUCTION INCIDENT. READ THIS BEFORE YOU START.**
>
> The single most common way a CDC pipeline takes the Postgres primary offline is the **replication-slot-fills-the-disk** failure mode. Every Debezium production deployment will eventually hit some version of it; teams that have not pre-built monitoring and the recovery runbook will hit it as a P0 page that takes the application database down. The mechanism in three sentences:
>
> 1. Debezium uses a Postgres logical replication slot as a bookmark — Postgres retains every WAL segment from the slot's `confirmed_flush_lsn` forward until Debezium reads and acknowledges it.
> 2. If Debezium falls behind (consumer crash, network split, Iceberg sink hung, Kafka unavailable, Spark job dead), the slot's confirmed position stops advancing, and Postgres holds WAL **forever, or until the disk fills up**.
> 3. When the Postgres data disk fills, **Postgres goes read-only or crashes**. Your application database is now down — caused by your analytics CDC pipeline, not by anything the application did wrong.
>
> **Why this happens more often than it should:** Debezium's failure modes are subtle (the connector can be "running" in Kafka Connect status while silently stuck on a poison message), nobody notices the slot is growing until disk hits 80%, and the recovery path (drop slot, recreate, re-bootstrap from a backfill) is not in most teams' runbooks the first time they need it.
>
> **The three non-negotiable mitigations — wire ALL THREE before turning on Debezium in production:**
>
> 1. **Monitor `pg_replication_slots.confirmed_flush_lsn` lag** (`pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)` — bytes_behind). Page on warn at 50 GB behind, page critical at 150 GB or 80% of safe capacity, whichever is smaller. Also page on `active = false` for >5 minutes. See "Monitoring replication slot lag" further down for the exact queries.
> 2. **Set `max_slot_wal_keep_size` in `postgresql.conf`** (Postgres 13+). This is the database's self-defense: if any slot falls more than this amount behind, Postgres **auto-invalidates the slot** to free WAL, rather than letting the disk fill. Typical setting: `50GB`. The CDC pipeline dies (recoverable via the `wal_status = 'lost'` recovery procedure), but the application database stays up. ALWAYS prefer "CDC dies, app stays up" over "app dies, CDC was fine until it wasn't."
> 3. **Have the slot-invalidation recovery runbook ready BEFORE you need it** — the four-step procedure (drop the invalid slot → recreate at current LSN → restart Debezium with `snapshot.mode: never` → backfill the gap via MERGE INTO from Postgres PRIMARY). Walk through it once on a staging environment so the on-call engineer has muscle memory; don't read it for the first time at 3 AM. See "Recovering from `wal_status = 'lost'`" further down for the full runbook.
>
> **Also wire `heartbeat.interval.ms` on the Debezium connector** to keep the slot advancing on quiet tables — without it, a slot that monitors only low-traffic tables can lag indefinitely and trigger `max_slot_wal_keep_size` even when nothing is wrong. See "Debezium heartbeat events" further down.
>
> If you remember nothing else from this CDC section, remember: **`max_slot_wal_keep_size` is the difference between "CDC outage" and "application database outage."** Configure it on day one.

#### Before you start: Postgres prerequisites for Debezium

Engineers routinely hit six Postgres-side prerequisites before they can write a single line of CDC consumer code. Debezium will not start (or will start and silently emit zero events) until all of them are in place. The six are: (1) `postgresql.conf` settings, (2) a publication, (3) `REPLICA IDENTITY FULL` on tables you need full before-images for, (4) a logical replication slot, (5) a role with the `REPLICATION` attribute, and (6) a `pg_hba.conf` entry permitting replication connections. Run all of these on the **Postgres primary** — logical replication does not work from a read replica.

1. **Set `wal_level = logical` plus `max_wal_senders` and `max_replication_slots` in `postgresql.conf`.** The default `replica` value of `wal_level` writes enough WAL for streaming replication but not for logical decoding — Debezium's PostgresConnector requires `logical`. Debezium's official setup docs list two companion settings alongside `wal_level` as required. Both default to 10 in Postgres 14+, but hardened or locked-down clusters sometimes set them to 0 — which silently breaks logical replication.

   ```
   # postgresql.conf
   wal_level = logical              # required for Debezium / logical decoding
   max_wal_senders = 10             # default 10 in PG14+; raise if you run multiple replication consumers
   max_replication_slots = 10       # must be >= number of active slots; 0 disables replication entirely
   ```

   **All three settings require a Postgres restart** — schedule the downtime; there is no hot-reload for these parameters. Verify after restart:

   ```sql
   SHOW wal_level;              -- must say 'logical'
   SHOW max_wal_senders;        -- must be >= number of replication consumers (Debezium counts as 1)
   SHOW max_replication_slots;  -- must be >= number of active slots
   ```

2. **Create a publication for the tables you want to stream.** A publication is the Postgres-side declaration of "which tables' changes should be sent over logical replication." Debezium consumes from a publication, not from "all tables" by default.
   ```sql
   CREATE PUBLICATION debezium_pub FOR TABLE events, users, orders;
   ```
   Only listed tables emit change events; everything else is invisible to Debezium. To add tables later: `ALTER PUBLICATION debezium_pub ADD TABLE new_table;`.

3. **Set `REPLICA IDENTITY FULL` on tables you want UPDATE/DELETE fidelity on.** By default Postgres tables have `REPLICA IDENTITY DEFAULT`, which means the WAL only records the **primary key** in the before-image of an UPDATE or DELETE. If your downstream Spark MERGE INTO needs to filter on non-PK columns (e.g., `WHEN MATCHED AND s.tenant_id = 'acme'`), the before-image will be missing those columns and the filter cannot evaluate. Bump it to `FULL`:
   ```sql
   ALTER TABLE events REPLICA IDENTITY FULL;
   ```
   `FULL` records every column's old value in the before-image. The cost is WAL volume (~2x for UPDATE-heavy tables), which is acceptable for most SaaS workloads but worth measuring on your largest tables.

4. **Create a logical replication slot.** A slot is Postgres's bookmark for "where in the WAL has this consumer read up to?" Without a slot, Postgres will discard WAL segments before Debezium reads them and you'll see "requested WAL segment has already been removed" errors.
   ```sql
   SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
   ```
   The `pgoutput` plugin is the built-in Postgres logical decoding output plugin (use it; the older `wal2json` plugin is no longer recommended). The slot name (`debezium_slot`) must match the `slot.name` property in your Debezium connector config.

   > **You usually do NOT need to pre-create the slot manually — Debezium does it for you.** On first connection, the PostgresConnector automatically issues `CREATE_REPLICATION_SLOT` over the streaming-replication protocol using the name you set in the `slot.name` connector property. **Pre-creating the slot with the SQL function above can cause conflicts** if the name already exists when Debezium tries to create it — the connector either errors at startup ("replication slot already exists") or attaches to your pre-created slot (depending on connector version and exact race), and the latter can silently break the snapshot-export consistency the connector would otherwise have arranged for itself.
   >
   > **Only pre-create a slot manually in one specific scenario:** you want the slot to start accumulating WAL changes **before** Debezium first connects — for example, to avoid missing events during the initial setup window between "application starts writing" and "connector is finally ready." This is the canonical **slot-first → Spark JDBC bootstrap → Debezium handoff** pattern documented later in this resource. If you pre-create for this reason, the slot name passed to `pg_create_logical_replication_slot(...)` MUST match the `slot.name` configured in the Debezium connector, and you MUST set `snapshot.mode: no_data` on the connector so it does not try to take its own snapshot on top of the existing slot.
   >
   > For the normal "I just want Debezium streaming, no Spark bootstrap" case: skip this step entirely. Configure `slot.name` in the connector and let Debezium create it.

5. **Grant the Debezium user the right permissions.** The user needs SELECT to read tables and the `REPLICATION` **role attribute** (NOT a database-level GRANT) to consume from the slot. `REPLICATION` is a property of the role itself, set at `CREATE ROLE` time or via `ALTER ROLE` — there is no `GRANT REPLICATION ON DATABASE ...` syntax in PostgreSQL (that statement will fail with a syntax error if you try it).
   ```sql
   -- Preferred: set REPLICATION at role creation.
   CREATE ROLE debezium_user WITH REPLICATION LOGIN PASSWORD 'strong_password';

   -- Or, for an existing role, add the attribute via ALTER ROLE.
   ALTER ROLE debezium_user WITH REPLICATION;

   -- Then grant the table-level SELECT privileges Debezium needs to read each table.
   GRANT SELECT ON ALL TABLES IN SCHEMA public TO debezium_user;
   ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO debezium_user;
   ```
   Also grant `USAGE` on the schema if you've restricted it. On a fresh Postgres install where `public` is open, the SELECT grant plus the `REPLICATION` attribute are usually sufficient.

   **Verify the role attribute is set:**
   ```sql
   SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'debezium_user';
   -- rolreplication must be 't' (true). If 'f', re-run ALTER ROLE ... WITH REPLICATION.
   ```

6. **Add a `pg_hba.conf` entry that allows replication connections from the Debezium host.** This is the #1 setup failure mode and the failure message is unfortunately cryptic: Debezium logs `FATAL: no pg_hba.conf entry for replication connection from host "X.Y.Z.W"`. The `pg_hba.conf` rules for **regular** SQL connections do not cover replication connections — replication is a separate connection class that requires its own line. Add this near the top of `pg_hba.conf` (above any deny-all line):

   ```
   # TYPE  DATABASE        USER             ADDRESS              METHOD
   host    replication     debezium_user    <connector_ip>/32    scram-sha-256
   ```

   Notes:
   - The literal token `replication` (lowercased) in the DATABASE column means "this rule applies to replication connections," not to a database named "replication." Do not change it to the actual database name (`app`) — that rule would not match a replication connection at all.
   - Replace `<connector_ip>/32` with the IP (or CIDR range) of the Kubernetes pod / node running the Debezium connector. On Kubernetes you may need a wider CIDR (e.g., the pod-network CIDR) because pod IPs rotate.
   - `scram-sha-256` is the recommended auth method on modern Postgres. Older clusters may still use `md5`; do not invent a new method here, match what the rest of `pg_hba.conf` uses.

   **Reload `pg_hba.conf` after editing — no restart needed:**

   ```sql
   -- Tell Postgres to re-read pg_hba.conf without restarting.
   SELECT pg_reload_conf();
   ```

   Or from the shell: `sudo systemctl reload postgresql` (systemd-managed installs). Skip this reload step and the new rule sits on disk but is not active; Debezium continues to fail with the same "no pg_hba.conf entry" error and you'll spend an hour debugging the wrong thing.

Verify the full setup before starting Debezium:
```sql
SHOW wal_level;                                                     -- must say 'logical'
SHOW max_wal_senders;                                               -- must be >= 1
SHOW max_replication_slots;                                         -- must be >= 1
SELECT rolname, rolreplication FROM pg_roles
  WHERE rolname = 'debezium_user';                                  -- rolreplication = t
SELECT * FROM pg_publication WHERE pubname = 'debezium_pub';        -- one row
SELECT * FROM pg_replication_slots WHERE slot_name = 'debezium_slot'; -- one row, active=f initially
```
If any of these return empty or unexpected results, Debezium will fail to start with a confusing error — fix the prerequisite before debugging the connector config. The two most common failure modes by far are (a) `pg_hba.conf` missing the `replication` rule, and (b) the role lacking the `REPLICATION` attribute.

#### Postgres DDL playbook for CDC pipelines

This subsection is the canonical reference for what Postgres DDL actually does to a running CDC pipeline. **Most engineers carry an incorrect mental model here** — the most common wrong belief is that `ADD COLUMN ... NOT NULL` on a populated table triggers a "table rewrite" that blocks the WAL or stalls Debezium. None of that is true. Read this section before designing or debugging any pipeline that has to survive Postgres schema changes.

##### 1. What `ADD COLUMN ... NOT NULL` (no default) actually does on a populated table

**This is the most-misunderstood Postgres DDL.** The correct behavior:

> `ALTER TABLE events ADD COLUMN new_col VARCHAR NOT NULL` on a **populated** table **errors immediately** with:
>
> ```
> ERROR: column "new_col" of relation "events" contains null values
> ```
>
> Postgres cannot add a `NOT NULL` column with no default to a table that already has rows — there is no value to put in existing rows, so the statement fails. There is **no "table rewrite path"** for this DDL. The statement is rejected before any lock is taken on the data, before the WAL gets a relation message, before Debezium sees anything. The table is unchanged, the column does not exist, and the pipeline keeps running normally.
>
> If someone tells you "I added a NOT NULL column and it worked," one of three things is true: (a) the table was empty, (b) they actually used `ADD COLUMN ... NOT NULL DEFAULT '<value>'` (a different DDL — see section 2), or (c) they used the safe online pattern in section 3. There is no fourth case where a populated table accepts a bare `NOT NULL` ADD.

The practical consequence: if you are debugging a "the pipeline broke after a NOT NULL column was added" incident, your **first diagnostic step** is to confirm the column exists in Postgres at all:

```sql
SELECT column_name, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'events' AND column_name = 'new_col';
```

If the query returns zero rows, the ALTER errored out and the engineer's pager incident is about a different problem entirely (probably the application code that *referenced* the new column failing because the column does not exist in the database).

##### 2. Which DDLs DO require a table rewrite (and what that means for Debezium)

> The only `ADD COLUMN` cases that trigger a full table rewrite in Postgres are those with a **volatile default** — i.e., a default expression whose value cannot be precomputed at DDL time:
>
> - `ADD COLUMN id UUID DEFAULT gen_random_uuid()` — every row needs a unique UUID computed
> - `ADD COLUMN created_at TIMESTAMPTZ DEFAULT clock_timestamp()` — every row needs the timestamp at that row's rewrite moment
> - `ADD COLUMN nonce TEXT DEFAULT random()::text` — every row needs a fresh random value
>
> **Non-volatile defaults are metadata-only since Postgres 11:**
>
> - `ADD COLUMN status TEXT DEFAULT 'pending'` — metadata-only (constant default)
> - `ADD COLUMN priority INT DEFAULT 0` — metadata-only
> - `ADD COLUMN created_at TIMESTAMPTZ DEFAULT now()` — **metadata-only** (the `now()` value is captured once at DDL time and applied as the default for old rows via a "missing value" pointer, not recomputed per row)
>
> **When a rewrite DOES happen (volatile default case):**
> - Postgres acquires `AccessExclusiveLock` on the table — this blocks application **reads and writes** to that table for the rewrite duration. (For a 100M row table, the rewrite can take tens of minutes.)
> - **The WAL continues to flow during and after the rewrite.** Logical decoding via `pgoutput` is NOT blocked. The replication slot does NOT stall. The WAL sender does NOT pause.
> - The rewritten table arrives in the WAL as a series of INSERTs for the new file pages. Debezium sees a RELATION message describing the new column layout on the next DML it processes, and emits events with the new column from that point.
>
> The misconception this corrects: an `AccessExclusiveLock` blocks **application** I/O on the table; it does NOT block the WAL sender or Debezium's logical decoding. These are independent subsystems. A long table rewrite causes an **application outage** on that table, not a CDC outage.

##### 3. The safe online schema change pattern for NOT NULL columns

The correct way to add a `NOT NULL` column to a live, populated table without errors or downtime — three steps:

```sql
-- Step 1: Add the column as NULLABLE (instant in PG 11+ if no default
-- or non-volatile default — metadata-only, microseconds).
ALTER TABLE events ADD COLUMN new_col VARCHAR;

-- Step 2: Backfill existing rows IN BATCHES.
-- Do NOT run one big UPDATE on 100M rows — it takes an ExclusiveLock,
-- creates massive WAL volume, and explodes the replication slot.
-- The ctid pagination pattern updates 10k rows at a time, committing
-- between batches and letting autovacuum keep up.
UPDATE events SET new_col = 'default_value'
WHERE new_col IS NULL AND ctid IN (
  SELECT ctid FROM events WHERE new_col IS NULL LIMIT 10000
);
-- Repeat the above statement in a loop until it reports 0 rows updated.
-- Each batch is its own transaction; the replication slot drains between batches.

-- Step 3: Add the NOT NULL constraint via the two-step NOT VALID pattern
-- (PG 12+). This avoids the full-table scan lock that a naive
-- ALTER TABLE ... ALTER COLUMN ... SET NOT NULL would acquire.
ALTER TABLE events
  ADD CONSTRAINT events_new_col_nn CHECK (new_col IS NOT NULL) NOT VALID;
-- NOT VALID adds the constraint as "will be checked on future writes" without
-- scanning existing rows — instant, takes only a brief AccessExclusiveLock for
-- the catalog update.

ALTER TABLE events VALIDATE CONSTRAINT events_new_col_nn;
-- VALIDATE acquires ShareUpdateExclusiveLock (NOT AccessExclusiveLock) — readers
-- and writers continue normally; only other DDL on the table is blocked.
-- The validate scan reads every row to confirm none are NULL, but does not lock them.
```

**What Debezium sees during this three-step sequence:**

- Step 1 (`ADD COLUMN ... VARCHAR`) — Debezium sees a RELATION message on the next DML and learns the new column layout. New change events include `new_col` (initially NULL for old rows that haven't been updated).
- Step 2 (batched UPDATEs) — Debezium emits an `op='u'` event for each updated row, with the new `new_col` value populated. Your Spark consumer's MERGE INTO applies these as ordinary updates. The Iceberg table will need the column added too (see section 5 below).
- Step 3 (`ADD CONSTRAINT`, `VALIDATE`) — Pure constraint operations, no data DML. Debezium does not emit row events. The Iceberg table is unaffected (Iceberg has no equivalent to Postgres CHECK constraints in this form, so there is nothing to mirror).

After step 3, the Postgres table has the NOT NULL guarantee, every row has a non-NULL value, and the CDC pipeline has been propagating the changes the whole time. **No connector restart needed.**

##### 4. Which schema changes Debezium handles transparently (no pipeline pause)

Debezium reads schema changes via **WAL RELATION messages** — every DML change on a table that had a DDL change first includes an updated RELATION message describing the new column layout. Debezium updates its in-memory schema via `schema.refresh.mode = columns_diff` (the default), which compares the cached schema against the RELATION message and adopts the new layout silently.

Schema changes Debezium handles without any pipeline intervention:

| DDL | Debezium behavior |
|---|---|
| `ADD COLUMN ... NULL` (no default) | New RELATION message on next DML; column appears in events with NULL where appropriate. |
| `ADD COLUMN ... DEFAULT '<constant>'` (PG 11+, metadata-only) | Same as above — Debezium picks up the new column from the next RELATION message. |
| `ADD COLUMN ... DEFAULT now()` | Same — `now()` resolves at DDL time, so it's metadata-only and behaves identically. |
| Column type widening (`varchar(100)` → `varchar(200)`, `int` → `bigint`) | RELATION message carries the new type; Debezium's in-memory schema updates; events use the new type from that point. |
| Dropping a column | RELATION message no longer lists the column; new events omit it. Old events already in Kafka still have the column (Kafka is immutable). |

These changes appear in Kafka events within seconds of the **first DML** after the DDL — not at DDL time itself. The reason: Postgres pgoutput emits the RELATION message inline with the next change event for the table, not as a standalone DDL notification.

> **`schema.refresh.mode` quick reference.** The default value is `columns_diff` — Debezium compares the in-memory schema to the incoming RELATION message and adopts new column layouts automatically. The alternative `columns_diff_exclude_unchanged_toast` is a niche tuning for tables with large TOAST-able columns; do not change this setting unless you have a specific reason. The third value, `legacy`, predates the `columns_diff` mode and is not recommended.

##### 5. The pause-ALTER-resume sequence (for Iceberg schema synchronization)

Even when Debezium handles schema changes transparently on its side, your **Iceberg target table** still needs to be updated before the new column arrives in Kafka events — otherwise the Spark consumer's MERGE INTO will throw an `AnalysisException` (see section 6 below) or, if the consumer was configured for silent drop, the column gets discarded and you have the silent-NULL bug described later in this resource.

**The correct sequence (in order):**

**Step 1 — Pause the Spark Structured Streaming consumer** (not the Debezium connector):

```bash
# Scale the Spark consumer deployment to zero replicas.
# Debezium continues running and continues buffering events into Kafka.
# Kafka holds the events until the consumer comes back (subject to your
# topic retention — default 7 days, plenty of headroom for a 5-minute ALTER).
kubectl scale deployment spark-events-consumer --replicas=0

# Or delete the pod and the Deployment will not recreate it if you've
# already scaled to zero:
kubectl delete pod -l app=spark-events-consumer
```

**Step 2 — Update the Iceberg table schema** (metadata-only, instant):

```sql
-- Trino 467 or Spark SQL — syntax is identical for ADD COLUMN.
-- Completes in milliseconds. No data rewrite. Safe to run anytime.
ALTER TABLE iceberg.analytics.events ADD COLUMN new_col VARCHAR;

-- Note: Iceberg always adds columns as NULLABLE, regardless of how the
-- column was declared on the Postgres side. See section 7 below.
```

**Step 3 — Resume the consumer:**

```bash
kubectl scale deployment spark-events-consumer --replicas=1

# Or apply the original deployment manifest if you deleted the pod:
kubectl apply -f spark-events-consumer-deployment.yaml
```

The consumer resumes from its last committed Kafka offset (stored in the Spark streaming checkpoint), reads the buffered events including the new column, and the MERGE INTO writes them to the now-evolved Iceberg table.

**Why this order matters.** Without `write.spark.accept-any-schema=true` on the Iceberg table AND `mergeSchema=true` on the writer, the consumer's MERGE INTO throws an `AnalysisException` when the source DataFrame has a column not in the target table. **The MERGE does NOT silently drop the column** in the default configuration — it errors and the streaming batch fails. The pause gives you the window to add the column before the first event with the new column arrives.

**If you have both auto-evolution options enabled on the writer**, the pause is optional — Iceberg will auto-evolve the target schema on the first event with the new column. But silent auto-evolution can mask mistakes (a typo in a column name produces a permanent stray column in the production Iceberg table), so **explicit `ALTER TABLE` is safer in production**.

**Total pipeline downtime for the pause-ALTER-resume sequence:** typically under 60 seconds. The bottleneck is the consumer pod startup time (the Iceberg ALTER itself is milliseconds). Debezium continues operating throughout — no Kafka events are lost as long as the topic retention window is longer than the pause.

##### 6. MERGE INTO schema-mismatch behavior in Iceberg 1.5.2 Spark

The exact behavior matters because the wrong mental model leads to incorrect remediation:

- **Default (no special config):** If the source CDC stream has a column not present in the target Iceberg table, Spark's MERGE INTO throws `AnalysisException: Unable to find the column of the target table from the INSERT columns` (paraphrased — exact message varies slightly by Spark version). The error is **visible**, not silent — the streaming batch fails, the offset does not commit, and the next batch re-attempts the same window of events with the same error until the schema is fixed.
- **With `write.spark.accept-any-schema=true` table property AND `.option("mergeSchema", "true")` writer option:** MERGE INTO auto-evolves the target schema to include the new column. New columns from the source are added to the Iceberg table automatically as part of the same commit.
- **Both options are REQUIRED for auto-evolution.** Either alone is insufficient (the writer option without the table property gets rejected at Spark's pre-validation step; the table property without the writer option produces an accepting-but-not-evolving writer).
- **For production CDC pipelines, prefer explicit `ALTER TABLE ADD COLUMN`** (controlled, auditable, leaves a trail in your DDL history) **over auto-evolution** (can mask mistakes, ties schema changes to whatever the most recent Spark batch happened to send).

##### 7. Iceberg `ADD COLUMN` nullability note

New columns added to Iceberg tables via `ALTER TABLE ... ADD COLUMN` are always **nullable** in Iceberg 1.5.2, regardless of the Postgres-side constraint. This is by design — it is **not** a bug or a missing feature. The reason: historical rows in older Parquet data files genuinely have no value for the new column, so claiming the column is NOT NULL would be a lie about the existing data. Iceberg's invariant — every column's nullability assertion must hold for every row in every file — is preserved by always adding new columns as nullable.

Practical consequence: even if your Postgres column is declared `NOT NULL` with a default, the corresponding Iceberg column will be nullable, and old Iceberg rows (written before the column was added) will return NULL for it. New rows written by the CDC consumer will populate the column from the Debezium event payload.

If you require non-NULL semantics on the Iceberg side — e.g., a downstream Trino view enforces `WHERE new_col IS NOT NULL` — you have two options:
1. Run a one-off backfill Spark job that computes a default for historical rows and writes them back. The column remains nullable in the Iceberg schema, but every row now has a value.
2. Leave historical rows as NULL and document the cutover date in your data dictionary so consumers know which date range to filter from.

There is no `ALTER TABLE ... ALTER COLUMN ... SET NOT NULL` equivalent in Iceberg 1.5.2 that retroactively rejects NULL values.

##### 8. Connector restart anti-pattern

**Do NOT restart the Debezium connector after a schema change.** A restart is unnecessary and can trigger bad outcomes depending on offset state:

1. **`snapshot.mode=initial` (the default):** On a routine restart of a healthy connector whose offsets are present in `connect-offsets`, the connector simply resumes streaming from the saved offset — **it does NOT re-snapshot**. `snapshot.mode=initial` only triggers a full table re-snapshot when NO offsets exist (first start, deleted offsets, renamed connector). However, if offsets were accidentally lost or the connector was renamed, a restart at `snapshot.mode=initial` would trigger a full re-snapshot — every row arrives as `op='r'`, generating massive Kafka volume and duplicate-event handling load on the consumer.
2. **`snapshot.mode=no_data`:** the connector resumes from its last committed LSN offset. This is correct for restarts with existing offsets, but re-reads any events between the last flush and the restart, producing duplicates that your MERGE INTO has to dedupe.

Neither outcome is necessary to handle a schema change. The Debezium connector has already been correctly emitting the new column in events since the first post-DDL DML — restarting it does not "refresh" anything that needs refreshing.

**The correct response to a schema-change-related error is:**

1. Check if the Iceberg target table is missing the new column. If yes:
   ```sql
   ALTER TABLE iceberg.analytics.events ADD COLUMN new_col VARCHAR;
   ```
2. Check if the consumer needs `write.spark.accept-any-schema=true` plus `mergeSchema=true` (only relevant if you've chosen the auto-evolution path). For production with explicit ALTER as in step 1, this is usually not needed.
3. Resume the **consumer** (not the connector) from where it left off — the Spark streaming checkpoint already knows the offset.

The Debezium connector itself does not need to be touched. Treat the connector as a stable upstream and do all schema-change remediation on the **consumer + Iceberg** side.

#### Deploying Debezium on Kubernetes: two approaches

Debezium is a Kafka Connect plugin — to run it you need a Kafka Connect cluster (a JVM worker process that hosts connector tasks) with the Debezium PostgreSQL connector JAR on its plugin path, plus a running Kafka cluster for it to publish change events into. On the on-prem Kubernetes production stack you have two reasonable deployment paths. **For production, use approach B (Strimzi).** Approach A is shown first because it makes the moving parts obvious, but it is operationally inferior.

##### Approach A — Raw Kafka Connect Deployment (educational only)

The bare-metal version: package the Debezium plugin into a Kafka Connect container image and run it as a regular Kubernetes Deployment. After the pod is healthy, you POST a JSON connector configuration to the Connect REST API (`/connectors`) to actually start streaming changes.

```yaml
# Raw Kafka Connect Deployment — shown for understanding only.
# In production, prefer the Strimzi CRDs (Approach B) below.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: debezium-connect
spec:
  replicas: 1
  selector:
    matchLabels: { app: debezium-connect }
  template:
    metadata:
      labels: { app: debezium-connect }
    spec:
      containers:
        - name: connect
          image: your-registry/debezium-connect:2.5.4.Final
          ports:
            - containerPort: 8083  # Kafka Connect REST API
          env:
            - name: BOOTSTRAP_SERVERS
              value: "kafka-bootstrap:9092"
            - name: GROUP_ID
              value: "debezium-connect-cluster"
            - name: CONFIG_STORAGE_TOPIC
              value: "_debezium_connect_configs"
            - name: OFFSET_STORAGE_TOPIC
              value: "_debezium_connect_offsets"
            - name: STATUS_STORAGE_TOPIC
              value: "_debezium_connect_status"
            # Mount Postgres credentials from a Kubernetes Secret as a file,
            # then reference via Kafka Connect's FileConfigProvider in the
            # connector config (see Secret injection note below).
            - name: CONNECT_CONFIG_PROVIDERS
              value: "file"
            - name: CONNECT_CONFIG_PROVIDERS_FILE_CLASS
              value: "org.apache.kafka.common.config.provider.FileConfigProvider"
          volumeMounts:
            - name: pg-creds
              mountPath: /opt/kafka/config
              readOnly: true
      volumes:
        - name: pg-creds
          secret:
            secretName: debezium-postgres-credentials
```

Once the pod is healthy, register the connector by POSTing JSON to its REST API. **This is the configuration that actually tells Debezium which database and tables to capture.** Important: in Debezium 2.0+, the property is `topic.prefix` — the old `database.server.name` was renamed and the two names must NOT both appear (the connector will refuse to start).

```json
POST http://debezium-connect:8083/connectors
Content-Type: application/json

{
  "name": "postgres-debezium-connector",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgres-primary-service",
    "database.port": "5432",
    "database.user": "debezium_user",
    "database.password": "${file:/opt/kafka/config/database.properties:database.password}",
    "database.dbname": "app",
    "topic.prefix": "app-db",
    "plugin.name": "pgoutput",
    "slot.name": "debezium_slot",
    "publication.name": "debezium_pub",
    "table.include.list": "public.events,public.users,public.orders",
    "snapshot.mode": "no_data"
  }
}
```

> **`snapshot.mode` value note (Debezium 2.x).** The example above uses `no_data` — the current preferred value when you do **not** want an initial snapshot (start streaming from the current WAL position and skip the per-row SELECT bootstrap). The older value `never` is **deprecated in Debezium 2.x** but still works as an alias for `no_data`; if you copy from an older tutorial that uses `"snapshot.mode": "never"` the connector will accept it and log a deprecation warning. Update new configs to `no_data`. See the dedicated **"Picking `snapshot.mode` for the PostgresConnector"** subsection below for the full comparison of all snapshot modes and when to use each.

> **Debezium 2.x rename — `database.server.name` is gone.** In Debezium 2.0+, `database.server.name` was renamed to `topic.prefix`. The two property names must NEVER coexist in a single connector config; if both are present the connector errors out at startup. If you are copy-pasting a config from a pre-2.0 tutorial, replace every occurrence of `database.server.name` with `topic.prefix`. The semantics are the same: this value becomes the prefix of every Kafka topic the connector publishes to (e.g., events for `public.events` land on topic `app-db.public.events`).

> **Secret injection — do NOT hardcode `database.password`.** The plaintext password shown in many tutorials must never live in the connector JSON in a real deployment — connector configs are stored in the `_debezium_connect_configs` Kafka topic in plaintext, visible to anyone with topic read access. Instead:
>
> - Store the password in a Kubernetes Secret (`kubectl create secret generic debezium-postgres-credentials --from-literal=database.password=...`).
> - Mount the secret as a file on the Connect pod (see `volumeMounts` above — the secret is rendered into `/opt/kafka/config/database.properties`).
> - Reference the file from the connector config using Kafka Connect's built-in **FileConfigProvider**: `"database.password": "${file:/opt/kafka/config/database.properties:database.password}"`. Kafka Connect resolves the placeholder at runtime so the topic never sees the plaintext password.
> - The `CONNECT_CONFIG_PROVIDERS=file` and `CONNECT_CONFIG_PROVIDERS_FILE_CLASS=org.apache.kafka.common.config.provider.FileConfigProvider` env vars above are what register the FileConfigProvider with the worker. Without them, the `${file:...}` syntax is treated as a literal string and Debezium tries to authenticate with `${file:...}` as the password — confusing failure mode.

**Why approach A is not the production recommendation:** you own every operational detail. Rolling restarts when a connector config changes are manual. Scaling the Connect cluster means editing replica counts and praying the new pod joins the cluster cleanly. Connector lifecycle (create / pause / restart / delete) is REST-only — there is no Kubernetes-native way to see "which connectors are deployed in this cluster" in `kubectl get`. Health checks, plugin version upgrades, and config drift all become custom scripting.

##### Approach B — Strimzi (the Kubernetes-native production choice)

**Strimzi is the standard Kafka operator for Kubernetes.** It runs in the cluster as a controller, watches a set of Custom Resource Definitions (CRDs), and reconciles Kafka, Kafka Connect, and connector resources for you — exactly the way you'd manage Deployments or StatefulSets through `kubectl`. For Debezium on Kubernetes, Strimzi is the right tool because:

- **Declarative connector management.** Connectors are defined as `KafkaConnector` CRDs in Git and applied via `kubectl apply`. No `curl` POST against the Connect REST API. `kubectl get kafkaconnectors` lists every connector in the cluster.
- **Operator handles the boring stuff.** Rolling restarts on config changes, replica scaling, plugin builds, health checks, image upgrades — all reconciled by the Strimzi cluster operator without writing custom scripts.
- **Native Kubernetes secrets integration.** Strimzi's `externalConfiguration.env` injects Kubernetes Secrets into the Connect worker pods as env vars or files, with no manual volume mount wiring on every connector.

The two CRDs you write:

```yaml
# KafkaConnect CRD — describes the Connect cluster (worker pods + plugin set).
# Strimzi builds the container image with the Debezium plugin at apply time.
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnect
metadata:
  name: debezium-connect
  annotations:
    # This annotation is REQUIRED to make KafkaConnector CRDs (below) actually
    # take effect against this Connect cluster. Without it, Strimzi ignores them.
    strimzi.io/use-connector-resources: "true"
spec:
  replicas: 1
  bootstrapServers: kafka-bootstrap:9092
  config:
    group.id: debezium-connect-cluster
    offset.storage.topic: _debezium_connect_offsets
    config.storage.topic: _debezium_connect_configs
    status.storage.topic: _debezium_connect_status
    # Production replication-factor settings for Connect internal topics.
    # = 3 (NOT >= 2) is the on-prem Strimzi production baseline — matches Strimzi's
    # default for cluster-internal topics and tolerates one broker outage with the
    # other two still able to maintain in-sync replicas (ISR >= 2 with min.insync.replicas=2).
    # Setting these to 2 means a single broker outage drops you to one replica and
    # the topic becomes unavailable on the next election event; use 3.
    offset.storage.replication.factor: 3
    config.storage.replication.factor: 3
    status.storage.replication.factor: 3
    # Register FileConfigProvider so KafkaConnector configs can reference secrets
    # injected by externalConfiguration below.
    config.providers: file
    config.providers.file.class: org.apache.kafka.common.config.provider.FileConfigProvider
  build:
    # Strimzi builds a Connect image containing the Debezium plugin and pushes
    # it to your registry — no need to maintain a custom Dockerfile.
    output:
      type: docker
      image: your-registry/debezium-connect:latest
    plugins:
      - name: debezium-postgres
        artifacts:
          - type: zip
            url: https://repo1.maven.org/maven2/io/debezium/debezium-connector-postgres/2.5.4.Final/debezium-connector-postgres-2.5.4.Final-plugin.zip
  externalConfiguration:
    # Inject the debezium-postgres-credentials Secret as env vars on every
    # Connect worker pod. Referenced by the KafkaConnector below.
    env:
      - name: PG_PASSWORD
        valueFrom:
          secretKeyRef:
            name: debezium-postgres-credentials
            key: database.password
```

```yaml
# KafkaConnector CRD — describes ONE connector instance running in the cluster
# named by the label below. Replaces the REST POST from Approach A.
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnector
metadata:
  name: postgres-debezium-connector
  labels:
    # Must match the KafkaConnect cluster's metadata.name.
    strimzi.io/cluster: debezium-connect
spec:
  class: io.debezium.connector.postgresql.PostgresConnector
  config:
    database.hostname: postgres-primary-service
    database.port: "5432"
    database.user: debezium_user
    # Reference the env var injected by externalConfiguration above.
    # Strimzi resolves ${secrets:...} at worker startup; the password
    # never appears in plaintext in the CRD or in the Connect config topic.
    database.password: "${env:PG_PASSWORD}"
    database.dbname: app
    # Debezium 2.x — use topic.prefix, NOT database.server.name.
    topic.prefix: app-db
    plugin.name: pgoutput
    slot.name: debezium_slot
    publication.name: debezium_pub
    table.include.list: "public.events,public.users,public.orders"
    # snapshot.mode: no_data is the Debezium 2.x preferred value (formerly `never`).
    # `never` still works as a deprecated alias. See the snapshot.mode subsection
    # below for the full mode comparison.
    snapshot.mode: no_data
```

After `kubectl apply -f` for both files, Strimzi:
1. Builds the Connect image with the Debezium plugin (one-time per image-tag change).
2. Rolls out the Connect Deployment.
3. Sees the `KafkaConnector` CRD and registers the connector with the Connect REST API on your behalf.
4. Surfaces connector status in `kubectl get kafkaconnectors` (`READY`, error messages, restart counts).

**Day-2 operations under Strimzi:**

- **Edit the connector config:** `kubectl edit kafkaconnector postgres-debezium-connector` — Strimzi applies the change to the Connect REST API and the connector restarts.
- **Pause / resume:** `spec.state: paused` in the KafkaConnector. Useful when you need to ALTER the Iceberg target schema (see "For CDC jobs (Pattern C)" earlier in this resource for the pause/ALTER/resume sequence).
- **Restart a stuck connector:** `kubectl annotate kafkaconnector postgres-debezium-connector strimzi.io/restart=true`.
- **List all connectors:** `kubectl get kafkaconnectors -A`.

**Sanity check after apply:**

```bash
# Connect cluster ready?
kubectl get kafkaconnect debezium-connect
# READY column must be True.

# Connector running and consuming?
kubectl get kafkaconnector postgres-debezium-connector
# READY=True means Strimzi successfully registered the connector with Connect
# AND Connect reports it as RUNNING. A READY=False with a TASKS_MAX message
# usually means the Postgres prerequisites (slot, publication, pg_hba.conf)
# are not yet in place — go back to the prerequisites section above.
```

If the connector fails to start, the failure messages bubble up into the KafkaConnector resource's `status.conditions` — `kubectl describe kafkaconnector postgres-debezium-connector` is the first place to look, not the Connect pod logs.

#### Picking `snapshot.mode` for the PostgresConnector

`snapshot.mode` controls **what Debezium does the very first time it connects to a Postgres database** — does it bootstrap the Iceberg target by SELECT-ing every existing row, does it skip that bootstrap and start streaming only from the current WAL position, or some variant in between? The choice has data-correctness consequences, and the Debezium 2.x value list has shifted from earlier versions — using a stale value name from an old tutorial is a common foot-gun.

**The Debezium 2.x value list (PostgresConnector).** The currently supported `snapshot.mode` values are:

| Value | What Debezium does on first start | When to use |
|---|---|---|
| `initial` (**default**) | Takes an initial snapshot of every row in every `table.include.list` table (each row emitted as `op='r'`), then switches to streaming live WAL changes. | The default and right answer for a brand-new pipeline where the Iceberg target is empty. Pre-existing rows get bootstrapped automatically. |
| `initial_only` | Takes the initial snapshot, then **stops** without ever starting WAL streaming. | One-shot Postgres-to-Iceberg backfill jobs where you only want the snapshot and will not stream live changes afterward. Rare in CDC pipelines; common in migration tooling. |
| `always` | Takes a fresh snapshot **on every connector start** — every restart re-SELECTs every row and re-emits them as `op='r'`. | Tiny dimension tables where you want the snapshot to act as a "rebuild from source of truth" on every restart. Avoid for any non-trivial table — re-reads the entire source on every pod restart. |
| `no_data` (formerly `schema_only`) | Skips the per-row snapshot entirely. Reads the table schemas (so the connector knows column types) but emits **zero** `op='r'` events. Streaming starts from the current WAL position. | Use when the Iceberg target was **already bootstrapped by a separate job** (e.g., a one-shot Spark JDBC `createOrReplace()` ran first) and you want Debezium to pick up only changes that happen from "now" forward. |
| `when_needed` | Behaves like `initial` if the connector has no stored offset, but if the stored offset is too old (the WAL it points at has been recycled) it does a fresh snapshot instead of failing. | Long-running pipelines where you'd rather absorb the cost of an unexpected re-snapshot than have the connector fail and stop streaming. Trades correctness-of-old-state for availability. |
| `configuration_based` | Lets you set each snapshot decision (data, schema, stream, on-error) via separate properties — for advanced custom flows. | Rare. Skip unless you have a documented need. |
| `custom` | Plugs in a user-supplied Java class implementing the `Snapshotter` SPI. | Rare. Only if you're writing custom Debezium extensions. |

> **`recovery` is NOT a valid `snapshot.mode` for the Debezium PostgreSQL connector.** The `recovery` mode exists **only** on the MySQL, MariaDB, and SQL Server connectors — those connectors maintain a Kafka schema-history topic and `recovery` re-reads it. PostgreSQL has no schema-history topic (logical decoding sends relation messages inline with the WAL stream), so `recovery` is not defined for it. **Setting `"snapshot.mode": "recovery"` on a PostgresConnector causes an immediate Kafka Connect REST API validation error at connector registration.** If you copied a `recovery` value from a MySQL tutorial or a generic Debezium blog post, replace it with `never` (or its 2.x alias `no_data`) for the Postgres connector. The correct recovery procedure for a lost Postgres slot or lost Kafka Connect offsets is documented in the "Why did Debezium re-snapshot on restart?" subsection further down — it uses `snapshot.mode: never` (not `recovery`) after recreating the slot.
>
> **Quick reference — `snapshot.mode` value support by connector:**
>
> | Mode | PostgreSQL | MySQL / MariaDB | SQL Server |
> |---|---|---|---|
> | `initial`, `initial_only`, `always`, `no_data` (`never`), `when_needed`, `configuration_based`, `custom` | Supported | Supported | Supported |
> | `recovery`, `schema_only_recovery` | **NOT supported** (REST API validation error) | Supported (re-reads schema-history topic) | Supported |

> **`never` is OFFICIALLY DEPRECATED in Debezium 2.x; the current preferred value is `no_data`.** This is not "less preferred" or "older style" — `never` is formally deprecated in the Debezium 2.x release notes and the PostgresConnector emits a deprecation warning at startup whenever it sees `snapshot.mode=never`. The connector still accepts the value as an alias for `no_data` for backward compatibility, but **the alias is scheduled for removal in a future major version** — code that hard-codes `never` will eventually stop working. Older docs, tutorials, and Stack Overflow posts (pre-Debezium 2.0) commonly show `"snapshot.mode": "never"`. **For all new configs, use `no_data`.** If you find `never` in an existing config, treat it as tech debt: update it to `no_data` at the next config change opportunity.

> **Restart behavior — what each `snapshot.mode` value does on connector restart (NOT just first start).** The table above describes first-start behavior; engineers most often get into trouble by confusing it with restart behavior. The two are different. Match your operational scenario to the right column:
>
> - **`initial` (default) — first start:** Debezium takes a full snapshot of every row in every `table.include.list` table (emitted as `op='r'` events) and then switches to WAL streaming. "First start" means: **no committed offsets exist in `_debezium_connect_offsets`** (the Kafka Connect offset topic) for this connector's `(group.id, connector name)` key.
> - **`initial` (default) — subsequent restarts:** Debezium **resumes from the last stored offset** in `_debezium_connect_offsets`. **It does NOT re-snapshot.** A routine pod restart, a config edit that triggers a Strimzi-managed rolling restart, a Kafka broker leader election that briefly disconnects the connector — none of these trigger a re-snapshot. The only way `initial` re-snapshots on a "restart" is if the offsets were lost (offset topic deleted/recreated, connector renamed, `group.id` changed) so the connector behaves as if it's a first start.
> - **`never` / `no_data` — first start:** Debezium **skips the initial snapshot entirely** and starts reading the WAL from the slot's current position. Use this ONLY when you've already loaded the historical data via a separate process (a Spark JDBC bootstrap job, or a previous run of a different tool). If you set `no_data` on a brand-new pipeline without a separate initial load, you will silently miss every row that existed in Postgres before the connector started — no error, just missing history in Iceberg.
> - **`never` / `no_data` — subsequent restarts:** Same as `initial` on subsequent restarts — resumes from the last stored offset. (The mode only affects the first-start path.)
> - **`always` — first start AND every restart:** Debezium **takes a full snapshot every time the connector starts** (including routine restarts), re-emitting every row as `op='r'`. This produces duplicate INSERTs for rows already in your Iceberg target on every restart — the downstream idempotent MERGE INTO absorbs them as no-ops, but the Kafka volume and per-row processing cost is enormous on any non-trivial table. **`always` is rarely the right choice.** Use only for testing, for tiny dimension tables you explicitly want to rebuild from source-of-truth on every restart, or for forced re-ingestion. Never use it on a high-row-count fact table — every Strimzi rolling restart will replay millions of rows through Kafka.
>
> **The key takeaway:** the default `initial` does NOT re-snapshot on routine restarts. If you are seeing a re-snapshot after a restart you didn't expect, the cause is almost always offset loss (item 1-4 in the "Why did Debezium re-snapshot on restart?" subsection below), not the `snapshot.mode` value itself. Diagnose the offset-loss cause before changing `snapshot.mode`.

**Defaults and selection guidance:**

- **For a brand-new pipeline with an empty Iceberg target → leave `snapshot.mode` unset (gets the default `initial`).** Let Debezium do the snapshot. You then handle `op='r'` events in your MERGE INTO as insert-if-not-exists (see the "Debezium PostgresConnector `op` field values" subsection further down). This is the simplest correct path.
- **For a pipeline where you already pre-loaded the Iceberg target via a separate Spark JDBC job → use `no_data`.** The bootstrap is already done; you only want Debezium to capture deltas from now forward. **The canonical slot-first handoff sequence is the only safe order** — see the **"Canonical Spark bootstrap → Debezium CDC handoff (slot-first)"** subsection immediately below for the full procedure. Do NOT pause application writes; do NOT bootstrap first and then create the slot — both shapes lose committed rows.

#### Debezium with Postgres declarative partitioned tables (`PARTITION BY RANGE`)

**Different from pg_partman.** The Postgres-side caveats discussed earlier in this resource (under "Reading from pg_partman-partitioned Postgres tables") apply to **Spark JDBC** reads, where pgjdbc walks `pg_inherits` to resolve the partition hierarchy. The Debezium CDC path is a separate stream of gotchas: Debezium reads the WAL, not JDBC, so the pg_partman child-index and `numPartitions` advice does not transfer. Even if you have already read that section, **read this section before pointing Debezium at any Postgres table created with `CREATE TABLE ... PARTITION BY RANGE (...)`** (or `LIST` / `HASH`) — the default Debezium behavior on declarative partitioned tables is **not** what most engineers expect, and a "table.include.list" config that names only the parent table will silently route events to per-leaf-partition Kafka topics, breaking every downstream MERGE INTO that assumes a single topic per parent.

The setup we are talking about: a Postgres table created like

```sql
CREATE TABLE events (
  event_id   BIGINT,
  tenant_id  VARCHAR,
  occurred_at TIMESTAMP,
  payload    JSONB
) PARTITION BY RANGE (occurred_at);

-- Each month is a separate child (leaf) partition.
CREATE TABLE events_2025_05 PARTITION OF events
  FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');
CREATE TABLE events_2025_06 PARTITION OF events
  FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');
-- ... one per month, going forward
```

This is **PostgreSQL native declarative partitioning** (available since PG 10). Applications INSERT into the parent table (`INSERT INTO events VALUES (...)`) and Postgres routes each row to the appropriate child partition transparently. The child tables (`events_2025_05`, `events_2025_06`, ...) are the actual physical storage; the parent is a routing layer.

##### Default Debezium behavior — what you actually get if you do nothing special

This is the critical part the official docs gloss over and where most teams get it wrong:

1. **Publication on the parent auto-includes all child partitions** (PostgreSQL 13+). When you create `CREATE PUBLICATION debezium_pub FOR TABLE events` on the parent, Postgres automatically includes every existing and future child partition. This is correct and matches the PostgreSQL `CREATE PUBLICATION` docs: *"When a partitioned table is added to a publication, all of its existing and future partitions are implicitly considered to be part of the publication."* So far, so intuitive.

2. **BUT Debezium routes change events to per-leaf-partition Kafka topics, NOT a single parent topic.** Per the Debezium PostgreSQL connector documentation: *"the default behavior is that change event records are routed to a different topic for each partition."* So if `topic.prefix = "app-db"` and you insert a row into the parent `events` table that lands in the May 2025 child partition, the Kafka event lands on topic `app-db.public.events_2025_05` — NOT on `app-db.public.events`. Every month you get a new child partition and a new Kafka topic. Engineers expecting a single `app-db.public.events` topic are looking for a topic that does not exist.

3. **`source.table` in the Debezium envelope is the leaf partition name, NOT the parent.** Inside each event payload, the `source.table` field that Debezium emits identifies which Postgres table the change came from. By default this is the **leaf partition** (`source.table = 'events_2025_05'`), NOT the parent (`source.table = 'events'`). Any downstream MERGE INTO logic that branches on `source.table = 'events'` will silently never match — every event reports the leaf table identity.

4. **`table.include.list: "public.events"` (parent only) is NOT sufficient by default.** A common misconception: "I'll just put the parent in `table.include.list` and rely on the publication to do its job." But because Debezium operates on the per-leaf identity reported in the WAL relation messages, leaf-level events do not match a parent-only include list — they arrive under leaf-table identity and may be filtered out, or may be allowed through under per-child topic names you did not configure for downstream. **Either way, this config does not give you "all change events on one parent topic" — the behavior you almost certainly want.**

##### The fix: `publish.via.partition.root=true`

Debezium exposes a single connector property — `publish.via.partition.root` — that flips every default in step 1-4 above to do what you actually want:

```yaml
config:
  publish.via.partition.root: "true"           # KEY PROPERTY for partitioned tables
  table.include.list: "public.events"          # parent only — now works correctly
  publication.name: "debezium_pub"
  publication.autocreate.mode: "filtered"
```

What this property does, mechanically:

- It causes Debezium to **create the publication with `WITH (publish_via_partition_root = true)`** (a PostgreSQL publication option introduced in PG 13). This tells Postgres logical decoding to attribute changes on any child partition to the **parent** table's identity in the WAL stream — the child changes still happen physically on the child files, but the WAL relation messages report the parent's OID.
- Debezium then routes all leaf changes to a **single topic** named for the parent (e.g., `app-db.public.events`).
- The `source.table` field becomes `'events'` (the parent name) for every event, regardless of which child partition the row was physically written to.
- `table.include.list: "public.events"` (parent only) now works correctly — events arrive with parent-table identity, match the include list, and flow to the single parent topic.

> **CRITICAL GOTCHA — `publish.via.partition.root` is ONLY applied at publication CREATION time.** This is the single most painful surprise on this property. The setting is read by Debezium when it creates the publication on the Postgres side (via `publication.autocreate.mode: "filtered"`, for example). **If the publication already exists** (created by an earlier connector run without the flag, or created manually via `CREATE PUBLICATION debezium_pub FOR TABLE events;`), Debezium **does not** re-evaluate or alter the publication's `publish_via_partition_root` setting. The connector silently continues with the existing publication's behavior, which is per-leaf routing.
>
> The symptom is confusing: you add `publish.via.partition.root: "true"` to your connector config, restart the connector, and nothing changes — events still flow to `app-db.public.events_2025_05`, not `app-db.public.events`. The connector logs no warning that the setting was ignored. Engineers spend hours debugging the connector config when the actual problem is the **pre-existing publication on the Postgres side**.
>
> **Fix:** drop the publication and recreate it (Debezium will recreate on next start with the flag honored):
>
> ```sql
> -- On the Postgres primary, as a superuser or the publication owner:
> DROP PUBLICATION debezium_pub;
> -- Then either let Debezium auto-create on next start (publication.autocreate.mode: "filtered")
> -- or create it manually with the flag:
> CREATE PUBLICATION debezium_pub FOR TABLE events
>   WITH (publish_via_partition_root = true);
> ```
>
> After the DROP + recreate, restart the Debezium connector. Now the connector picks up the new publication's setting and per-leaf events start arriving on the parent-named topic with `source.table = 'events'`. Drop + recreate is not destructive to ingestion correctness — Debezium re-creates the slot's bookmark and continues from the next WAL position; you do not lose committed events as long as the slot itself is preserved.

##### `table.include.list` rules — the two valid shapes

The connector property `table.include.list` interacts with `publish.via.partition.root` in a non-obvious way. There are two valid shapes, and one common-but-wrong shape:

| `publish.via.partition.root` | Correct `table.include.list` | Result |
|---|---|---|
| `true` | `public.events` (parent only) | All leaf changes flow under parent identity to one topic. Simple, recommended for most cases. |
| `false` (default) | `public.events.*` (regex covering parent + all children) OR enumerate each child: `public.events,public.events_2025_05,public.events_2025_06,...` | Events arrive on per-leaf topics; apply the **ByLogicalTableRouter SMT** to consolidate them at Kafka if you want a single downstream topic. |

The common-but-wrong shape: `publish.via.partition.root` left at the default `false`, with `table.include.list: "public.events"` (parent only). With this combination, leaf events arrive with leaf-table identity (`source.table = 'events_2025_05'`), do not match the parent-only include filter, and either silently never appear OR appear on the unexpected per-child topic name — depending on the connector version and the exact publication state. The pipeline appears "running" (the connector is healthy, the slot is consuming WAL) but the downstream Iceberg MERGE INTO sees no events. Diagnosing this without knowing about `publish.via.partition.root` typically takes hours.

##### Decision table — pick the shape based on your downstream consumer

| Goal | Connector setting | Kafka topic shape | `source.table` value |
|---|---|---|---|
| **One topic, parent-named, simple MERGE INTO** | `publish.via.partition.root=true` + `table.include.list=public.events` | All leaf inserts → `app-db.public.events` (single topic) | `'events'` (parent) — uniform across all rows |
| **Per-leaf topics (parallel consumers per month)** | leave default (`publish.via.partition.root=false`) + `table.include.list=public.events.*` (regex) | Topics `app-db.public.events_2025_05`, `app-db.public.events_2025_06`, ... | `'events_2025_05'` (leaf) — varies per row |
| **Per-leaf at WAL, consolidate at Kafka** | leave default + `table.include.list=public.events.*` + apply **ByLogicalTableRouter SMT** | Per-leaf topics rewritten to a single consolidated topic at the Connect SMT layer | `source.table` is remapped by the SMT (to the parent name) — set the SMT's `topic.replacement` accordingly |

**Recommendation for most SaaS teams: row 1 (`publish.via.partition.root=true` + parent-only include list).** It gives you the simplest downstream contract — one Kafka topic per logical table, one MERGE INTO branch per table, no SMT to configure, no per-leaf topic to add to your consumer's subscription list when a new month rolls over. Reserve row 2 (per-leaf topics) only when you have a specific reason to parallelize consumers per child partition — and even then, prefer the SMT-consolidation form (row 3) so your application code still sees one logical topic per table.

##### Verification SQL — confirm the publication is in the mode you think it's in

After making any change, verify the publication's actual state on the Postgres side rather than trusting the connector config:

```sql
-- Check if the publication was created with publish_via_partition_root.
-- pubviaroot is a boolean column on pg_publication (the system catalog).
SELECT pubname, pubviaroot
FROM pg_publication
WHERE pubname = 'debezium_pub';
-- pubviaroot = true  → single-topic, parent-identity behavior (the publish.via.partition.root=true mode)
-- pubviaroot = false → per-leaf topic behavior (the DEFAULT — what you get if you did nothing special)
```

> **Note: `pg_publication_tables` does NOT show `pubviaroot`.** A common mistake is to check `pg_publication_tables` and conclude the publication is configured correctly because the parent table is listed. `pg_publication_tables` enumerates the tables a publication includes (which is fine — the parent is there, the children are implicitly included), but it does NOT expose the `publish_via_partition_root` flag. **Always check `pg_publication.pubviaroot` directly**, not `pg_publication_tables`. The flag is a property of the publication itself, not of any individual table membership.

##### PostgreSQL version requirement

**Parent-table publication support is PostgreSQL 13+ only.** On PG 11 and 12, the publication's "include all children when the parent is added" behavior does not exist — `CREATE PUBLICATION debezium_pub FOR TABLE events` on a partitioned parent does NOT auto-include the child partitions. You must enumerate every child partition individually:

```sql
-- PG 11/12 form — required because parent-table inclusion is PG 13+ only.
-- This is operationally painful because every new month requires
-- ALTER PUBLICATION ... ADD TABLE for the new child.
CREATE PUBLICATION debezium_pub FOR TABLE
  events_2024_01, events_2024_02, ..., events_2025_05, events_2025_06;
```

On PG 11/12, `publish.via.partition.root=true` is **not supported at the Postgres level** — the underlying `publish_via_partition_root` publication option does not exist until PG 13. If your Postgres version is below 13, you are stuck with per-leaf topic behavior and must use the **ByLogicalTableRouter SMT** at Kafka Connect to consolidate downstream — or upgrade Postgres. For new deployments on the production stack, **PG 13+ is a hard requirement for any Debezium-on-partitioned-tables CDC use case.**

##### Snapshot behavior — `snapshot.mode: no_data` is strongly preferred

When the parent has many child partitions (e.g., 36 months of history × 1 partition per month = 36 children), the default `snapshot.mode: initial` would **snapshot each leaf partition individually**, taking a sequential `SELECT *` against every child table and emitting `op='r'` events for every row. On a large fact table with years of partitioned history, this is a huge amount of work and acquires per-child read locks that can interfere with normal operations.

**For declarative-partitioned tables, strongly prefer `snapshot.mode: no_data`** — skip the per-row snapshot entirely and start streaming from the current WAL position. Bootstrap the Iceberg target via a separate Spark JDBC job (using the pg_partman-style "read specific child partitions" pattern from earlier in this resource for parallelism), then hand off to Debezium with the slot-first sequence in the "Canonical Spark bootstrap → Debezium CDC handoff" section immediately below. The standalone bootstrap can be parallelized per-child via Spark; Debezium's per-child snapshot cannot.

##### Sample connector config snippet

A complete config for the recommended pattern (single parent topic, parent-named identity, no SMT needed):

```yaml
# Strimzi KafkaConnector spec — equivalent JSON for raw Kafka Connect REST API.
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaConnector
metadata:
  name: postgres-events-partitioned-connector
  namespace: kafka
  labels:
    strimzi.io/cluster: debezium-connect
spec:
  class: io.debezium.connector.postgresql.PostgresConnector
  tasksMax: 1
  config:
    connector.class: "io.debezium.connector.postgresql.PostgresConnector"
    database.hostname: "postgres-primary-service"
    database.port: "5432"
    database.user: "debezium_user"
    database.password: "${secrets:kafka/debezium-postgres-credentials:database.password}"
    database.dbname: "app"
    topic.prefix: "app-db"
    plugin.name: "pgoutput"
    slot.name: "debezium_slot"
    publication.name: "debezium_pub"
    publication.autocreate.mode: "filtered"
    publish.via.partition.root: "true"           # KEY PROPERTY — routes all leaf changes to parent topic
    table.include.list: "public.events"           # parent only — works because of publish.via.partition.root
    snapshot.mode: "no_data"                      # strongly preferred for many-leaf tables
```

After applying this config the first time (and dropping any pre-existing publication that lacked the flag, per the gotcha above), verify with the `pubviaroot` SQL check, then verify the Kafka topic shape with `kafka-topics.sh --list` — you should see `app-db.public.events` (the parent) and NO `app-db.public.events_2025_05`-style per-leaf topics.

##### Cross-link to the rest of this guide

- **`table.include.list` regex syntax**: Java regex, not POSIX. `public.events.*` matches every table whose name starts with `public.events` — including the parent. If you want children only, use a more specific pattern like `public\.events_\d{4}_\d{2}`.
- **MERGE INTO consumer**: see the "MERGE INTO with composite key + LSN idempotency guard" section. With `publish.via.partition.root=true`, the consumer's MERGE branches on `source.table = 'events'` (parent name) — uniform regardless of which child partition the row physically lived in.
- **Bootstrap → CDC handoff**: see "Canonical Spark bootstrap → Debezium CDC handoff (slot-first)" immediately below for the snapshot-skip handoff sequence that complements `snapshot.mode: no_data`.

##### Canonical Spark bootstrap → Debezium CDC handoff (slot-first)

A common (and wrong) handoff shape engineers reach for: "pause application writes, run the Spark JDBC bootstrap, then start Debezium." This either causes a real production outage (pausing writes is unacceptable for a SaaS app) or silently loses rows (writes resume between bootstrap finish and Debezium start). **The correct shape requires no application pause** and relies on Postgres exporting a consistent snapshot at slot creation. The three steps, in this order:

**Step 1 — Create the replication slot FIRST.** The slot starts retaining WAL the instant it's created and exports a consistent snapshot name that any session can use for a transactionally-consistent point-in-time read.

```sql
-- On the Postgres PRIMARY (not a replica — replication slots live on the primary).
SELECT * FROM pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
-- Returns: slot_name | lsn
-- Note the returned LSN — this is the slot's `consistent_point`. Every WAL change
-- committed at or after this LSN will be captured by the slot and delivered to
-- Debezium when it connects.
```

If you want transactional consistency between Spark's snapshot and Debezium's first streamed change, use the **2-arg `pg_create_logical_replication_slot` form inside an explicit `REPEATABLE READ` transaction**, then export the snapshot via `pg_export_snapshot()`. The exported snapshot name is what other sessions attach to with `SET TRANSACTION SNAPSHOT`.

```sql
BEGIN;
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
-- Use the 2-arg form. The surrounding REPEATABLE READ transaction is what makes
-- pg_export_snapshot() return a usable snapshot name for cross-session consistency.
SELECT * FROM pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
SELECT pg_export_snapshot();  -- returns the snapshot name, e.g., '00000003-0000001B-1'
-- KEEP THIS TRANSACTION OPEN until Spark has SET TRANSACTION SNAPSHOT'd to it.
-- COMMIT only after Spark has finished reading.
COMMIT;
```

> **CRITICAL — do NOT use the 4-arg `pg_create_logical_replication_slot('debezium_slot', 'pgoutput', false, true)` form to get snapshot consistency.** The 4-arg SQL function signature is `(slot_name, plugin, temporary, two_phase)`. The 4th argument enables **two-phase commit decoding** (for prepared transactions / 2PC) — it does **NOT** export a snapshot. AI-generated answers and older tutorials sometimes claim the 4th arg "exports a snapshot" — this is wrong and will silently NOT give you the cross-session consistency you wanted. The correct shape for cross-session snapshot consistency is the 2-arg form **inside a `REPEATABLE READ` transaction** + `pg_export_snapshot()`, exactly as shown above.
>
> **Where does "snapshot export at slot creation" actually exist?** In Postgres's **streaming-replication wire protocol** (not the SQL function): the `CREATE_REPLICATION_SLOT slot_name LOGICAL pgoutput EXPORT_SNAPSHOT` command, issued over a **replication-protocol** libpq connection (the one Debezium itself uses internally), returns a snapshot name as part of its response. This protocol command is **not available from psql / Spark JDBC / Trino**, because those clients open ordinary SQL connections — not replication-protocol connections. Debezium consumes that protocol-level snapshot internally when it does an `initial` snapshot. **For the slot-first → Spark JDBC bootstrap pattern documented in this section, you cannot reach that protocol command from Spark — use the 2-arg SQL form inside a `REPEATABLE READ` transaction + `pg_export_snapshot()` instead. This is the only correct path.**
>
> **Quick reference — which form to use from which client:**
>
> | Client | Connection type | Slot-creation form for cross-session snapshot |
> |---|---|---|
> | psql, Spark JDBC, Trino, any ordinary SQL client | Regular SQL connection | 2-arg `pg_create_logical_replication_slot(slot, plugin)` inside `BEGIN; SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;` + `pg_export_snapshot()` |
> | Debezium connector (internal) | Streaming-replication protocol (libpq) | Protocol command `CREATE_REPLICATION_SLOT ... LOGICAL pgoutput EXPORT_SNAPSHOT` (Debezium handles this for you when `snapshot.mode=initial`) |

**Step 2 — Bootstrap with Spark JDBC.** Optionally use the slot's exported snapshot name so Spark reads exactly the database state at the slot's creation LSN. No application pause needed — production writes continue normally; they land in the WAL and will be replayed by Debezium once it connects in step 3.

```python
# Query the actual MAX(id) FIRST — do NOT hardcode a large estimate. See the
# upperBound warning callout immediately below for why this matters.
max_id = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT COALESCE(MAX(id), 0) AS max_id FROM public.events) AS t",
    properties=PG_PROPS,
).collect()[0]["max_id"]

# Option A (simpler): just read from a replica or primary as usual. The MERGE-based
# CDC consumer's idempotency absorbs any overlap between bootstrap rows and CDC
# events that may have been committed during the bootstrap window.
df = spark.read.jdbc(
    url=PG_URL, table="public.events",
    properties={**PG_PROPS, "fetchsize": "10000"},
    numPartitions=16, partitionColumn="id", lowerBound=1, upperBound=max_id
)
# IMPORTANT: backfill op='r' on every bootstrap row so the downstream MERGE handles
# bootstrap and CDC events uniformly via the same WHEN MATCHED / WHEN NOT MATCHED
# branches. See the "Bootstrap-row `op` convention" callout further down.
df = df.withColumn("op", lit("r")).withColumn("source_lsn", lit(None).cast("long"))
df.writeTo("iceberg.analytics.events").append()

# Option B (transactionally consistent): pass the slot's exported snapshot name as
# a JDBC session-init SQL fragment so every Spark executor's connection sees the
# exact same point-in-time view (LSN = slot's consistent_point).
PG_PROPS_SNAP = {
    **PG_PROPS,
    "fetchsize": "10000",
    # pgjdbc honors this as a per-connection session init.
    "sessionInitSql": (
        "BEGIN; SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; "
        "SET TRANSACTION SNAPSHOT '00000003-0000001B-1';"
    ),
}
df = spark.read.jdbc(url=PG_URL, table="public.events", properties=PG_PROPS_SNAP, ...)
```

> **WARNING — always query `SELECT MAX(id) FROM events` first; do NOT use a large estimate as `upperBound`.** A common mistake is to hardcode `upperBound=1_000_000_000` (or `800_000_000_000` — 1000× too high) "just to be safe." This **silently collapses Spark JDBC parallelism**: the planner divides the `[lowerBound, upperBound)` range into `numPartitions` equal-width strides, then issues one JDBC query per stride. If your real `MAX(id)` is 800 million but you set `upperBound=1_000_000_000`, the 16 strides are 62.5M wide each — fine. But if you set `upperBound=800_000_000_000` (a billion times too high), the 16 strides are 50B wide each, and **every real row falls inside the first stride** (`id < 50_000_000_000`). One executor reads all 800M rows; the other 15 executors read empty ranges and finish instantly. The job that should have taken 30 minutes takes hours, and there is no error to alert you — just unexplained slowness.
>
> **The right pattern is:** (1) query the actual max id from Postgres before launching the Spark job (the `(SELECT COALESCE(MAX(id), 0) AS max_id FROM public.events) AS t` subquery shown in the Step 2 code above is the recommended shape — wrapping in a subquery is required by Spark's `dbtable` syntax), (2) pass that value as `upperBound`, (3) leave `numPartitions` at 16-32 for an 800M-row table. A small over-estimate is fine — Spark folds out-of-range rows into the last partition, never drops them; a 1000× over-estimate is what collapses parallelism. See the "How lowerBound / upperBound / numPartitions actually work" subsection later in this file for the full mechanics.

**Step 3 — Start Debezium with `snapshot.mode: no_data`.** Debezium opens the slot you created in step 1 and begins streaming WAL changes from the slot's `consistent_point`. Every commit since slot creation is captured; nothing is lost.

```yaml
# Strimzi KafkaConnector or REST POST payload
config:
  slot.name: debezium_slot         # MUST match the slot created in step 1
  snapshot.mode: no_data           # skip per-row snapshot — slot is the source of truth
  publication.autocreate.mode: filtered
  # ...rest of standard config...
```

**Why this order is safe — and why the reverse order silently loses data:**

| Order | What happens |
|---|---|
| Slot → Spark → Debezium (CORRECT) | Slot retains every WAL change from creation onward. Spark reads a consistent snapshot of pre-existing rows. Debezium streams every change committed since slot creation. Any commit during the bootstrap window arrives via CDC, gets MERGEd idempotently, and the row converges to its post-commit state. |
| Spark → Debezium (WRONG) | Spark reads pre-existing rows. Between Spark's last read and Debezium's slot creation, application commits land in the WAL — but no slot is retaining them. When Debezium creates its slot, the slot starts retaining WAL **from that moment forward**. **Every commit during the gap window is permanently lost** — Spark never read them, Debezium never sees them, no error is raised. The data simply isn't in Iceberg. |
| Pause writes → Spark → Debezium (UNNECESSARY OUTAGE) | Pausing application writes for the bootstrap duration (often hours) is a production outage. There is no correctness benefit over the slot-first pattern — the slot-first pattern already gives you exact-once capture without downtime. |

> **WARNING — creating the slot AFTER the Spark bootstrap is the canonical data-loss bug.** This is the most common AI-generated wrong shape for the handoff. Debezium starts capturing WAL only from the moment the slot is created; Spark already finished reading. Rows committed between bootstrap end and slot creation are **never** in either side's view — gone forever, with no error to alert you.

> **The MERGE INTO consumer's idempotency is what makes this safe.** Because the canonical CDC MERGE pattern (`WHEN MATCHED AND s.op = 'd' THEN DELETE / WHEN MATCHED AND s.op IN ('u','c','r') THEN UPDATE / WHEN NOT MATCHED AND s.op IN ('c','r','u') THEN INSERT`) handles every operation type idempotently, it absorbs any overlap between bootstrap rows and CDC events:
> - A row Spark already bootstrapped, then Debezium re-emits as `op='c'` for a commit that happened during the bootstrap window → `WHEN MATCHED THEN UPDATE` overwrites with the latest state. No duplicate.
> - A row deleted in Postgres during the bootstrap window that Spark read before the delete → `op='d'` event from Debezium deletes the bootstrapped row. Correct.
> - A row inserted in Postgres after the slot's consistent_point but before Spark's read → Spark reads it AND Debezium emits a `op='c'` for it. `WHEN MATCHED THEN UPDATE` re-applies the same column values — idempotent no-op. No duplicate.

##### Bootstrap-row `op` convention

When you bootstrap an Iceberg table via Spark JDBC (any of the patterns above), **always backfill an `op` column on the written rows** — set it to `'r'` (read / snapshot) to match Debezium's convention for snapshot rows, or `'c'` (create) if you want to treat them like inserts. This lets the same downstream MERGE INTO logic handle both bootstrap rows and live CDC events uniformly — no special-case branches.

```python
from pyspark.sql.functions import lit

df = spark.read.jdbc(url=PG_URL, table="public.events", properties=PG_PROPS, ...)
df = (
    df
    .withColumn("op", lit("r"))                       # convention: 'r' = snapshot
    .withColumn("source_lsn", lit(None).cast("long")) # bootstrap rows have no WAL LSN
    .withColumn("source_ts_ms", lit(None).cast("long"))
)
df.writeTo("iceberg.analytics.events").append()
```

**Why this matters:** if your Iceberg table has an `op` column populated by Debezium for CDC events but NULL for bootstrap rows, downstream consumers that filter on `op` (audit pipelines, change-feed dashboards, "rows that were ever updated" queries) silently break for the historical window. Backfilling `op='r'` keeps the column semantically meaningful across the entire table history. The convention also pays off if you ever need to re-run the bootstrap as a corrective measure — the re-bootstrap rows still merge cleanly through the same `op`-aware MERGE pattern without special handling.

##### Verifying the bootstrap → CDC handoff

After the handoff completes, verify the slot is healthy and Iceberg is converging to Postgres state. Do NOT rely on `COUNT(*) + MAX(updated_at)` alone — both can match while individual rows differ.

**1. Per-day row-count diff between Postgres and Iceberg for the bootstrap window.** This catches gaps that a single `COUNT(*)` would miss (a missing day balanced by a duplicated day on either side).

```sql
-- Run in Trino with the Postgres connector registered. Compare per-day counts.
WITH pg_counts AS (
    SELECT date_trunc('day', created_at) AS d, count(*) AS pg_n
    FROM postgres.public.events
    WHERE created_at >= TIMESTAMP '2026-04-01'
      AND created_at <  TIMESTAMP '2026-05-01'
    GROUP BY 1
),
ice_counts AS (
    SELECT date_trunc('day', created_at) AS d, count(*) AS ice_n
    FROM iceberg.analytics.events
    WHERE created_at >= TIMESTAMP '2026-04-01'
      AND created_at <  TIMESTAMP '2026-05-01'
    GROUP BY 1
)
SELECT
    coalesce(p.d, i.d) AS day,
    coalesce(p.pg_n, 0) AS pg_n,
    coalesce(i.ice_n, 0) AS ice_n,
    coalesce(i.ice_n, 0) - coalesce(p.pg_n, 0) AS delta
FROM pg_counts p
FULL OUTER JOIN ice_counts i ON p.d = i.d
WHERE coalesce(p.pg_n, 0) != coalesce(i.ice_n, 0)
ORDER BY day;
```

Any non-zero `delta` is a real gap — investigate before declaring the handoff complete. A small positive delta on the boundary days is normal (CDC has caught up faster than the moment you ran the check); a negative delta or any mid-window mismatch is a bug.

**2. Monitor `pg_replication_slots.confirmed_flush_lsn` lag.** This is the operational health signal for the slot. If `confirmed_flush_lsn` stops advancing while `pg_current_wal_lsn()` keeps growing, Debezium is not consuming — either the consumer is down, Kafka is backed up, or the Iceberg sink is wedged. Alert on this:

```sql
SELECT
    slot_name,
    confirmed_flush_lsn,
    pg_current_wal_lsn() AS current_wal_lsn,
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes,
    active
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

Recommended alert thresholds: `active = false` → page immediately; `lag_bytes > 1 GiB` → warn; `lag_bytes > 10 GiB` → page (you are minutes away from filling the Postgres WAL disk).

> **`ts_ms` confusion — use `source.ts_ms` for lag measurement, NOT the envelope-level `ts_ms`.** The Debezium event envelope contains two `ts_ms` fields with different semantics:
>
> - **`payload.source.ts_ms`** (accessed as `envelope.source.ts_ms` in your Spark DataFrame): the timestamp (in milliseconds) when **Postgres committed the transaction** to the WAL. This is the correct field for measuring CDC lag — the difference between `current_timestamp` and `source.ts_ms` tells you how stale the event is (how long ago the source database committed this change).
>
> - **`payload.ts_ms`** (the top-level `ts_ms` in the Kafka message envelope, accessed as `envelope.ts_ms`): the timestamp when the **Kafka Connect connector processed and published the event** (JVM clock on the Connect worker). This is NOT the Postgres commit time. It is later than `source.ts_ms` by the Debezium-to-Kafka processing delay. Using `envelope.ts_ms` for lag measurement underestimates the true end-to-end CDC lag because it hides the time the event spent queued in Debezium before being published.
>
> **For measuring how stale data is in your Iceberg table**, always use `source.ts_ms`:
>
> ```python
> from pyspark.sql.functions import current_timestamp, col, from_json
> from pyspark.sql.types import StructType, StructField, LongType
>
> envelope_schema = StructType([
>     StructField("source", StructType([
>         StructField("ts_ms", LongType())   # Postgres commit timestamp
>     ])),
>     # ... other fields
> ])
>
> df = spark.readStream.format("kafka").load() \
>     .select(from_json(col("value").cast("string"), envelope_schema).alias("envelope"))
>
> # Correct: measures time since Postgres committed (true CDC lag)
> lag_seconds = current_timestamp().cast("long") - col("envelope.source.ts_ms") / 1000
>
> # WRONG: measures time since Debezium published to Kafka (hides WAL-read lag)
> # lag_seconds = current_timestamp().cast("long") - col("envelope.ts_ms") / 1000
> ```

> **EXPECTED — during the Spark bootstrap phase of the slot-first handoff, the replication slot will appear inactive (`active = false`) and `lag_bytes` will grow** as Postgres accumulates unreplicated WAL between slot creation (Step 1) and Debezium startup (Step 3). This is expected — Debezium has not connected to the slot yet, so there is nothing to flush. **Once Debezium starts in Step 3, `active` becomes `true` and `confirmed_flush_lsn` begins advancing**, and `lag_bytes` shrinks as Debezium catches up to the current WAL. Alert thresholds should account for the expected bootstrap window: either temporarily silence the slot-inactive alert for the duration of the bootstrap, or set the `active = false` page condition to fire only after the slot has been inactive for **longer than your bootstrap budget** (e.g., 4 hours for an 800M-row table at typical Spark JDBC throughput). The growing `lag_bytes` during bootstrap is also expected and not a sign of consumer failure — it just means the WAL is accumulating faster than it's being drained because nothing is draining it yet. Make sure `max_slot_wal_keep_size` is large enough to comfortably exceed the WAL volume your application generates during the worst-case bootstrap window, or the slot will be invalidated mid-bootstrap.

**3. Monitor Debezium offset storage — `connect-offsets`, NOT `__consumer_offsets`.** When investigating connector lag or re-snapshot issues, look at the right Kafka topic. Debezium is a Kafka Connect **source** connector — it stores its own offsets (the last WAL LSN it flushed) in the Connect source-connector offset topic, **not** in `__consumer_offsets`:

- **`_debezium_connect_offsets`** — the Strimzi default for the source-connector offset topic (`offset.storage.topic`). This is where Debezium's per-connector WAL bookmark lives. Loss of this topic causes Debezium to re-snapshot on the next restart. Verify it exists with `kafka-topics.sh --describe --topic _debezium_connect_offsets`.
- **`__consumer_offsets`** — the Kafka broker's built-in consumer-group offset topic for regular Kafka consumer groups (e.g., your Spark Structured Streaming job). **This has nothing to do with Debezium's source offsets.** Deleting or resetting a Kafka consumer group in `__consumer_offsets` has zero effect on Debezium's WAL position.

When a connector appears to re-snapshot unexpectedly, check `_debezium_connect_offsets` for your connector's offset key before touching `snapshot.mode`.

**4. Optional: sampled row-hash comparison.** For tables where column-level drift matters, sample a few hundred primary keys per day and compare a column-content hash between Postgres and Iceberg. See the existing reconciliation patterns earlier in this resource (Pattern C — full content hash) for the SHA-256-of-concatenated-columns approach.
- **For an existing PostgresConnector whose Kafka Connect offsets were lost → use `no_data` (or its alias `never`) one-time, after a `confirmed_flush_lsn` gap check.** (PostgreSQL does **not** support `snapshot.mode: recovery` — that mode is MySQL/MariaDB/SQL Server only and the Kafka Connect REST API will reject it on a PostgresConnector.) The correct Postgres recovery shape is: (1) confirm the replication slot is still intact and its `confirmed_flush_lsn` matches what Iceberg actually persisted (see the data-loss warning below), (2) restart the connector with `snapshot.mode: no_data` so it skips the per-row snapshot and resumes from the slot's current WAL position, (3) if there is a gap between the slot position and Iceberg's last persisted LSN, run a targeted MERGE INTO backfill from Postgres PRIMARY to fill it (see the "Detection recipe: already-missed rows after a replica lag incident" section earlier for the backfill shape). After recovery completes, revert `snapshot.mode` back to its normal value (typically unset → default `initial`) for the next legitimate cold start.

##### Debezium 2.x incremental snapshot via signal table — the preferred path when a connector is already running

The slot-first → Spark JDBC → Debezium-with-`no_data` pattern documented above is the right shape for **initial connector setup** — when no PostgresConnector exists yet and you are bootstrapping the very first table into a fresh pipeline. It is **not** the right shape when you already have a healthy, running connector and you simply need to **add a new large table** (or re-snapshot an existing one). For that scenario, Debezium 2.x's **incremental snapshot via signal table** is the preferred path: it lets Debezium itself manage the snapshot with full transactional consistency, without stopping the connector, without a separate Spark JDBC job, and without manual LSN tracking.

**Prerequisites — set these in the connector config and in Postgres:**

1. **Configure the signal table on the connector.** Add the following to your KafkaConnector / connector config:

   ```yaml
   config:
     signal.data.collection: public.debezium_signal
     # Optional but recommended for production: also enable the Kafka signal channel
     # so on-call can submit signals via a Kafka message in addition to a SQL insert.
     signal.enabled.channels: source,kafka
   ```

2. **Create the signal table in Postgres** (the connector does NOT create it for you):

   ```sql
   -- Run on the Postgres PRIMARY as a privileged user.
   CREATE TABLE public.debezium_signal (
     id    VARCHAR(42) PRIMARY KEY,
     type  VARCHAR(32) NOT NULL,
     data  VARCHAR(2048)
   );

   -- Include the signal table in the same publication Debezium reads from,
   -- otherwise the connector cannot see the INSERTs you submit:
   ALTER PUBLICATION debezium_pub ADD TABLE public.debezium_signal;

   -- The Debezium user needs INSERT on it to submit signals via SQL
   -- (in addition to the existing SELECT grant Debezium uses for reading change events):
   GRANT INSERT ON public.debezium_signal TO debezium_user;
   ```

**Triggering an incremental snapshot — INSERT a signal row:**

```sql
-- On the Postgres PRIMARY: insert a signal row to ask Debezium to snapshot public.events.
-- Debezium picks up the signal from the WAL stream (since the signal table is in the
-- publication) and begins chunked snapshot reads interleaved with the live WAL stream.
INSERT INTO public.debezium_signal (id, type, data)
VALUES (
  gen_random_uuid()::text,
  'execute-snapshot',
  '{"data-collections": ["public.events"], "type": "incremental"}'
);
```

That single INSERT is the entire trigger. **Debezium handles consistency internally using its watermarking protocol** ("open chunk" → "snapshot chunk read" → "close chunk" markers in the WAL stream) — there is no separate Spark JDBC job to coordinate, no `pg_export_snapshot()` to share between sessions, no manual LSN tracking, no application pause. Live CDC events for the table continue flowing throughout; the snapshot rows arrive as `op='r'` events interleaved with regular `op='c'/'u'/'d'` events for the same table, and the MERGE INTO consumer's idempotency handles any overlap exactly as it does in the slot-first pattern. To re-snapshot multiple tables in one signal, list them all in `"data-collections"`.

**Slot-first vs signal-table — which one when:**

| Situation | Use | Why |
|---|---|---|
| **No PostgresConnector running yet** — first-time pipeline bootstrap for the very first table | Slot-first → Spark JDBC → Debezium with `snapshot.mode: no_data` | There is no running connector to submit a signal to. The slot-first pattern is the only correct shape for first-time setup. Spark JDBC parallelizes the initial read of a multi-TB table faster than Debezium's single-threaded snapshot would. |
| **PostgresConnector already running healthily** — adding a new large table to the existing pipeline, or re-snapshotting one corrupt table | **Signal-table incremental snapshot** | No connector restart needed. No separate Spark job. No `pg_export_snapshot()` to coordinate. Debezium handles consistency via the watermarking protocol. Live CDC events keep flowing for all other tables (and for the snapshotted table itself) throughout. |
| Detected a gap via reconciliation (sampled-row-hash mismatch) on one table | Signal-table incremental snapshot scoped to that table | Lower operational risk than restarting the connector or rebuilding the slot — just re-read the affected table while the rest of the pipeline keeps running. |
| The slot was lost (`wal_status = 'lost'`) and you must recover | Drop slot → recreate → restart connector with `snapshot.mode: never` → targeted MERGE INTO backfill from Postgres PRIMARY for the gap window | See the dedicated "Recovering from `wal_status = 'lost'`" subsection above. Signal-table snapshots cannot help here — they require an already-running connector reading from a healthy slot. |

> **The signal-table approach completely sidesteps the Spark JDBC `upperBound` parallelism trap and the slot-first ordering gotchas.** If you already have a healthy connector, prefer this. The slot-first pattern documented above is the right answer only when there is no connector yet — i.e., on day-one pipeline setup, or after a slot-loss recovery where you intentionally tore everything down. For everything else, prefer the signal-table incremental snapshot.

> See debezium.io's `incremental snapshots` documentation for advanced options: `additional-conditions` (filter the snapshot to a subset of rows), `surrogate-key` (for tables without a numeric PK), and stop-snapshot (`stop-snapshot` signal type) to abort a long-running snapshot mid-flight.

> **DATA-LOSS WARNING — verify `confirmed_flush_lsn` before flipping to `no_data` (or `never`) after a mid-stream offset loss.** A tempting "fix" after a Kafka Connect offset loss is: restart the connector with `snapshot.mode=no_data` so it just picks up at the current WAL position without re-snapshotting the entire table. **This silently skips events** if offsets were lost while events were still being committed and replicated. The window of events between "last offset Iceberg actually persisted" and "current WAL position Debezium will resume from" is gone — no error, no warning, just missing rows in Iceberg.
>
> **Required check before flipping to `no_data` after an offset loss:**
>
> 1. Query the replication slot's `confirmed_flush_lsn` on the Postgres primary:
>    ```sql
>    SELECT slot_name, confirmed_flush_lsn, restart_lsn
>    FROM pg_replication_slots
>    WHERE slot_name = 'debezium_slot';
>    ```
> 2. Query the last successfully processed LSN in your downstream Iceberg table. If your CDC consumer writes the source LSN into a column (recommended — add a `source_lsn` column to your Iceberg events table, populated from Debezium's `source.lsn` field), the check is:
>    ```sql
>    -- In Trino, against Iceberg.
>    SELECT max(source_lsn) FROM iceberg.analytics.events;
>    ```
> 3. **Confirm `confirmed_flush_lsn` ≈ `max(source_lsn)` in Iceberg.** If they match (within a small replication-and-write-latency window), it is safe to restart with `snapshot.mode: no_data` (or its alias `never`) — Debezium will resume CDC streaming from the slot's current WAL position. If `confirmed_flush_lsn` is significantly **ahead** of the Iceberg max, you have a gap — the WAL has advanced past what Iceberg actually persisted. **Do not use `no_data` in this case;** instead, run a targeted MERGE INTO backfill from Postgres PRIMARY for the gap range (see the "Detection recipe: already-missed rows after a replica lag incident" section earlier for the backfill shape) and only then restart Debezium with `snapshot.mode: no_data` to resume normal streaming. **(Reminder: `snapshot.mode: recovery` is NOT valid on the PostgresConnector — that mode exists only on MySQL/MariaDB/SQL Server. Use `no_data`/`never` for Postgres in all the same scenarios where MySQL would use `recovery`.)**
>
> If your CDC consumer does not currently persist `source_lsn`, add the column **before** you ever need this recovery procedure. Without it, you cannot tell whether `no_data` will skip events; you can only guess. (Storing `source_lsn` adds ~8 bytes per row to Iceberg — negligible.)

##### Why did Debezium re-snapshot on restart? — diagnostic checklist

A frequent and alarming surprise: you restart the connector for what should be a no-op (config tweak, pod reschedule, image upgrade), and Debezium starts re-SELECT-ing every row in every monitored table again. The Iceberg sink suddenly sees a flood of `op='r'` events for rows it already has, the table churns, and on-call wakes up wondering whether they're about to silently duplicate the entire fact table.

> **Connect offset topic name — `_debezium_connect_offsets` (Strimzi) vs `connect-offsets` (vanilla) vs `__consumer_offsets` (a DIFFERENT topic).** This is one of the most common naming confusions in Connect troubleshooting and engineers regularly chase the wrong topic for hours during an incident. Three distinct topic names show up in any Kafka cluster running Connect, and only one of them is the Debezium source-offset bookmark:
>
> - **`_debezium_connect_offsets`** — the Connect **source-connector** offset topic on the **production Strimzi stack** (this is the value set in the Strimzi `KafkaConnect` CRD's `config.offset.storage.topic` shown earlier). This is the topic that holds Debezium's per-connector WAL position bookmarks. **This is the topic you check during a re-snapshot incident.**
> - **`connect-offsets`** — the Connect source-connector offset topic on **vanilla Apache Kafka Connect** (the default value when `offset.storage.topic` is unset). If you copied a config or runbook from generic Apache Kafka Connect documentation, it will reference this name; on the production Strimzi stack the real topic name is `_debezium_connect_offsets`, not `connect-offsets`. Confirm what your actual cluster uses, do not assume the default.
> - **`__consumer_offsets`** — the **Kafka broker's** built-in consumer-group offset topic. It tracks consumer-group `offset commits` for ALL consumer groups in the cluster (regular Kafka consumers, not Connect source connectors). **It has NOTHING to do with Kafka Connect source-connector offsets**, despite the name similarity. Looking at `__consumer_offsets` during a Debezium re-snapshot incident is looking at the wrong topic entirely; Debezium's source offsets are NOT stored there.
>
> Confirm the topic name on your cluster before debugging further:
>
> ```bash
> # Should list _debezium_connect_offsets on the Strimzi stack.
> # If you see connect-offsets here, the Connect cluster is using the vanilla default,
> # and the Strimzi config in this guide does NOT apply as-is — update accordingly.
> kafka-topics.sh --list --bootstrap-server kafka:9092 | grep -E '(debezium|connect-offsets)'
>
> # __consumer_offsets ALWAYS exists on any Kafka cluster — this is the Kafka broker's
> # internal topic for regular consumer-group commits. Seeing it here is normal and
> # has no bearing on the Debezium re-snapshot investigation.
> kafka-topics.sh --list --bootstrap-server kafka:9092 | grep __consumer_offsets
> ```

> **At-least-once + `offset.flush.interval.ms` — the structural reason "a few duplicates of recent rows" happen after every Debezium restart.** Kafka Connect does NOT commit source offsets on every event. It commits them periodically, on a timer controlled by **`offset.flush.interval.ms`** — **default 60000 (60 seconds)** in Kafka Connect 2.x/3.x. Every event Debezium processes between the last successful offset flush and a crash/restart will be **re-delivered** on the next start; this is Debezium's documented **at-least-once delivery guarantee** ([debezium.io FAQ](https://debezium.io/documentation/faq/#what_happens_when_an_application_stops_or_crashes)). The duplicate window is bounded by the flush interval, not by anything else.
>
> Concrete numbers for the default `offset.flush.interval.ms = 60000`:
> - A connector that crashes 30 seconds after its last offset commit re-delivers ~30 seconds of events on restart.
> - At a steady-state ingest rate of 100 events/sec, that is ~3,000 duplicate events.
> - At 10 events/sec, ~300 duplicates.
> - At 1 event/sec on a quiet table, just a few — which matches the "a few duplicate copies of recent rows" symptom that triggers the most diagnostic confusion.
>
> **Lowering `offset.flush.interval.ms`** (e.g., to `10000` = 10s) **reduces the duplicate window proportionally** — a 10-second flush interval caps the duplicate window at 10 seconds of events. The tradeoff is higher Kafka write I/O (offset commit to the offset topic every 10s instead of every 60s) and slightly more CPU on the Connect worker. Set it to `10000` on tables where the dashboard surface is highly sensitive to duplicates between the flush and a crash; leave it at the default `60000` on tables where the downstream MERGE INTO absorbs them transparently.
>
> **The structural fix is always the same: idempotent consumer.** At-least-once cannot be eliminated — it is a property of any system that flushes offsets on a timer rather than per-event. What absorbs it is the consumer-side **MERGE INTO with per-key LSN dedup** pattern documented above (`Window.partitionBy(PK).orderBy(source_lsn.desc()) → row_number() == 1`, then `MERGE INTO ... ON t.id = s.id WHEN MATCHED AND s.source_lsn > t.source_lsn THEN UPDATE SET *`). Built correctly, the duplicate window from any restart — whether it is the default 60-second flush window or the tightened 10-second window — is **absorbed in the MERGE step as a no-op**: matched rows that have a strictly greater target LSN are skipped, and matched rows with an equal source LSN UPDATE with identical column values (idempotent). The flush-interval knob shrinks the duplicate volume; the idempotent consumer makes the duplicates harmless either way.

> **Symptoms vs root causes — pick the right diagnosis BEFORE you touch `snapshot.mode`.** Engineers reach for `snapshot.mode=no_data` whenever they see ANY duplicates after a restart. That is the right answer for one specific symptom pattern and the wrong answer for two others. Match your actual symptom to the right column below before changing config:
>
> | Symptom | Most likely root cause | How to confirm | Fix |
> |---|---|---|---|
> | A few duplicate copies of **recent** rows, small `updated_at` drift (microseconds to seconds) | **At-least-once redelivery during the `offset.flush.interval.ms` window** (or an app-level Postgres retry) | Check `offset.flush.interval.ms` (default 60000) on the Connect worker config; check app logs for retry around the same wall-clock moment as the original commit; check whether the duplicates cluster in time near a recent connector restart, pod reschedule, or Kafka broker leader election | **Idempotent MERGE INTO with per-key LSN dedup** (the canonical pattern shown above). Optionally lower `offset.flush.interval.ms` to `10000` to shrink the duplicate window. Do NOT set `snapshot.mode: no_data` — that is the wrong fix for this symptom and will silently break a future legitimate cold start. |
> | **Every** row in the table is duplicated, **all carrying `op='r'`** | **Re-snapshot on restart** — `snapshot.mode` is at the default `initial` and Debezium has lost its offset bookmark | Check whether `_debezium_connect_offsets` was deleted/recreated recently (`kafka-topics.sh --describe --topic _debezium_connect_offsets`); check whether the connector `name` or `group.id` changed against git history. If either is yes, this is the cause. | **Fix the underlying offset-loss cause** (restore the offset topic, revert the `group.id` or connector `name`). Do **NOT mask with `snapshot.mode=no_data`** — that hides the bug and the same surprise will recur on the next restart. After fixing the root cause, the next restart will resume from the existing offsets and the re-snapshot stops happening. |
> | A few duplicates AND **every row in a single table is re-emitted** | **Incremental snapshot triggered via the `debezium_signal` table** — someone (or some scheduled job) explicitly asked Debezium to re-snapshot one specific table while CDC kept running on the others | `SELECT * FROM debezium_signal WHERE type = 'execute-snapshot' ORDER BY id DESC LIMIT 10` — recent `execute-snapshot` rows for the affected table identify when and by whom the signal was sent | **Expected behavior — no fix needed**; the MERGE INTO consumer absorbs the re-emitted rows idempotently (matched rows UPDATE to the same column values; LSN guard skips older versions). If the incremental snapshot was unintentional (someone ran it by mistake), audit who/what wrote the signal row and add operational controls. |
>
> **The point of the table:** the SQL fix (idempotent MERGE) is the same for all three symptoms — the Iceberg side absorbs them — but the **config-side response is different**. Symptom 1 needs no `snapshot.mode` change; symptom 2 needs the offset-loss bug fixed (not masked); symptom 3 needs no change at all. Walking the table is what stops engineers from running `snapshot.mode: no_data` against a symptom-1 incident and then being mystified six months later when their fresh-environment bootstrap doesn't load any history.

> **Where do the millisecond `updated_at` drifts come from? — three causes, none of them "Debezium's fault."** When you compare a duplicate row's `updated_at` from two close-together Debezium events, the values often differ by a few milliseconds (sometimes microseconds, sometimes hundreds of ms). This is one of the most confusing symptoms because it looks like Debezium is somehow corrupting timestamps. **It is not.** The drift is explained by one of three Postgres-side causes — and **none of them are related to `snapshot.mode` vs WAL streaming**:
>
> - **(a) Postgres-level application retry committing the same logical event twice with two slightly different `now()` values.** The app called `INSERT ... VALUES (..., now())`, the network blipped before the response arrived, the app's HTTP client retried, and the second `INSERT` committed with a fresh `now()` — a few hundred ms later than the first. **Both** rows are real `INSERT`s in Postgres; both have real WAL records; Debezium correctly emits one `op='c'` event for each. The drift is the gap between the two `now()` calls. The fix is application-side idempotency keys (a deterministic unique key on the insert that lets the DB reject the second one), not anything in the CDC pipeline.
> - **(b) The app uses `now()` in a Postgres trigger that re-fires on each UPDATE.** A row is INSERTed at `T0` with `updated_at = T0`; an UPDATE at `T1` fires the `BEFORE UPDATE` trigger which sets `updated_at = now() = T1`. Debezium correctly emits one `op='c'` and one `op='u'`. If your MERGE INTO is keyed on `(id, updated_at)` (a bad composite-key choice), the two events look like two distinct rows because `updated_at` differs. The fix is to key the MERGE on the primary key alone (`ON t.id = s.id`), with the LSN-comparison `WHEN MATCHED AND s.source_lsn > t.source_lsn` clause handling ordering — never include `updated_at` in the merge join key.
> - **(c) Engineer is comparing Debezium's `source.ts_ms` (millisecond precision) to Postgres `updated_at` (microsecond precision) and seeing rounding artifacts.** Debezium's `source.ts_ms` field is the commit timestamp recorded by the database server, exposed at **millisecond precision** (Postgres's WAL records this metadata in ms). The `updated_at` column inside the row payload is whatever precision Postgres stores (typically `timestamptz` at microsecond precision). Comparing `source.ts_ms = 1716545537482` to `after.updated_at = '2026-05-24 14:32:17.482913'` shows a ~913 microsecond difference — but that is not "drift," it is the resolution gap between the two fields. Always compare like-to-like: `source.ts_ms` to `source.ts_ms` for ordering, or `after.updated_at` to `after.updated_at` for app-level timestamps.
>
> **The key point:** none of these drift causes have anything to do with whether Debezium snapshotted vs streamed from WAL. Snapshot mode emits `op='r'` events whose payloads contain the **same** column values that an `op='u'` would for the same row — including `updated_at`. So if you see millisecond drift between two duplicates, you are looking at one of (a), (b), or (c) — not at a snapshot-vs-WAL difference, and not at evidence that `snapshot.mode: no_data` would have prevented the drift. Diagnose against the three causes above; do not change `snapshot.mode` based on millisecond timestamp drift in the duplicates.

**Before you change `snapshot.mode`, diagnose the root cause.** Re-snapshotting on restart is almost never the right thing for Debezium to be doing — it usually means something else is broken. Masking the symptom by setting `snapshot.mode=no_data` "to make it stop" hides the underlying bug and the same surprise will recur. Walk this checklist:

1. **Was the Kafka Connect offset topic (`_debezium_connect_offsets` / `offset.storage.topic`) deleted or recreated?** If the offset topic was wiped (manual `kafka-topics --delete`, namespace teardown and rebuild, Strimzi `KafkaTopic` deletion, retention misconfig that aged offsets out), Debezium loses its bookmark and on next start it behaves as if it's the first run — meaning it executes whatever `snapshot.mode` says, including the default `initial`. Check the topic's existence and age:
   ```bash
   kubectl exec -it <kafka-pod> -- kafka-topics.sh --bootstrap-server localhost:9092 \
       --describe --topic _debezium_connect_offsets
   ```
   If the topic was recreated within the last few hours and your connector started snapshotting around the same time, that's your culprit.

2. **Was the Kafka Connect cluster rebuilt with a new `group.id`?** Offsets are keyed by the `group.id` of the Connect cluster (the `GROUP_ID` env var in approach A, or `config.group.id` in the Strimzi `KafkaConnect` CRD). If the new Connect deployment uses a different `group.id` than the prior one, it cannot read the old offsets — even though the offset topic itself still exists. Check the current value vs the old value in git history. This is a common mistake when re-deploying after a namespace rename or a "let's start clean" cluster rebuild.

3. **Is `offset.storage.topic` misconfigured — pointing at a different topic per environment, or accidentally identical between dev and prod?** If your dev and staging Connect clusters share the same `offset.storage.topic`, a dev restart can corrupt prod offsets. Conversely, if a prod deployment was reconfigured to point at a new topic name (intentionally or via a typo), the connector sees an empty topic and re-snapshots. Verify the topic name in the current connector config matches what the topic actually is named in the Kafka cluster.

4. **Did the connector `name` change?** Offsets are keyed by **(group.id, connector name)** in Kafka. Renaming the connector — say from `postgres-debezium-connector` to `pg-events-cdc` — produces a different offset key, so the new name reads no offsets and starts fresh. This bites teams that "clean up" naming conventions on an existing connector. The fix is to either keep the old name or migrate offsets manually (which is painful — usually it's easier to accept the resnap or set `snapshot.mode: no_data` one-time for the rename event specifically, after the `confirmed_flush_lsn` gap check below). **(Do NOT set `snapshot.mode: recovery` here — that mode is rejected by the PostgresConnector at registration; it only exists on the MySQL/MariaDB/SQL Server connectors.)**

5. **Always diagnose root cause before changing `snapshot.mode`.** If you set `snapshot.mode=no_data` to silence a re-snapshot you didn't understand, you have not fixed anything — you have only ensured that the next legitimate cold start (new table added to `table.include.list`, fresh environment bootstrap) will silently fail to ingest historical data. **Find which of items 1–4 actually happened, fix it (restore the offset topic, revert the group.id, fix the topic name, restore the connector name), and then leave `snapshot.mode` at its correct value for normal operation.**

If after diagnosis you confirm the offsets are truly gone and the replication slot is intact, use **`snapshot.mode: no_data`** (or its alias `never`) one-time on the PostgresConnector to resume streaming from the slot's current WAL position — see the data-loss warning above for the `confirmed_flush_lsn` check before flipping. (Reminder one more time: `snapshot.mode: recovery` does NOT exist on the PostgresConnector — it is MySQL/MariaDB/SQL Server only. Any tutorial that recommends `recovery` for Postgres offset loss is wrong; the equivalent Postgres value is `no_data`.)

#### Monitoring replication slot lag

Once Debezium is running, the most operationally dangerous failure mode is a **stuck or disconnected slot**. When Debezium can't consume from the slot (consumer crashed, network split, Iceberg sink hung), Postgres keeps every WAL segment the slot still needs — **forever, or until disk fills up and the database goes read-only.** This is the single most common way to take a Postgres primary offline via CDC. Alerting on slot lag is not optional.

```sql
-- Check if Debezium is actively consuming:
SELECT slot_name, active, confirmed_flush_lsn, restart_lsn
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
-- active = false means Debezium is disconnected and WAL is accumulating
```

```sql
-- The right monitoring query for slot-invalidation pressure (Postgres 13+):
SELECT
    slot_name,
    active,
    wal_status,
    safe_wal_size,                                                          -- PG 13+
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)        AS bytes_behind_restart,
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS bytes_behind_consumer,
    inactive_since,                                                          -- PG 17+ (NOT 14 — added in Postgres 17)
    invalidation_reason                                                       -- PG 16+
FROM pg_replication_slots
WHERE slot_name = 'debezium_slot';
```

**Read the columns in this order — each one tells you something different:**

- **`safe_wal_size` (PG 13+) — the direct headroom metric.** This is Postgres telling you, in bytes, "how much more WAL can be written before this slot is at risk of being marked `lost`." It is the value to alert on — no manual subtraction needed. Two caveats:
  - **`safe_wal_size IS NULL`** means either (a) the slot has already been invalidated (`wal_status = 'lost'` — check `invalidation_reason`), or (b) `max_slot_wal_keep_size = -1` (the default — no cap), in which case there is no enforced ceiling and the slot can grow unbounded until disk fills. If you have `max_slot_wal_keep_size = -1`, `safe_wal_size` will always be NULL and you must alert on `bytes_behind_restart` against your free-disk capacity directly.
  - **`safe_wal_size` can go negative** when the slot has crossed the `max_slot_wal_keep_size` line but Postgres has not yet recycled the WAL — meaning invalidation is imminent on the next checkpoint. Treat any negative value as critical.

- **`bytes_behind_restart` — use this for slot survival headroom (NOT `confirmed_flush_lsn`).** Slot invalidation is driven by the slot's `restart_lsn` — the oldest WAL position the slot still needs to be able to resume from — NOT by `confirmed_flush_lsn` (the consumer-acknowledged position). The two LSNs are normally close, but during **long-running transactions** they diverge: `confirmed_flush_lsn` keeps advancing for committed transactions, while `restart_lsn` is pinned to the oldest in-progress transaction's start LSN (because if Debezium restarts, it must re-read the WAL from there to reconstruct that uncommitted transaction). If you measure slot pressure with `confirmed_flush_lsn`, you will underestimate it — sometimes by tens of GB if a long-running transaction is open — and the slot can be invalidated even while your `bytes_behind_consumer` metric looks fine. **Always compute slot survival headroom from `restart_lsn`.**

- **`bytes_behind_consumer` — use this for consumer/Debezium lag.** This is the right metric for "is Debezium keeping up?" — the gap between the latest committed WAL and what the consumer has acknowledged. It is the correct lag metric for SLO/latency dashboards, but it is the **wrong** metric for slot-invalidation alerting.

- **`inactive_since` (PG 17+) — when the slot became inactive.** Directly tells you the timestamp at which the slot transitioned from `active = true` to `active = false`. Far more useful than maintaining your own "first observed inactive" timestamp in the metrics layer — Postgres has already tracked it for you. Alert on `inactive_since < now() - interval '5 minutes'` for a slot-inactive page. **Version note: this column was added in Postgres 17 (not 14 — a common mis-citation). On PG 13–16, you must compute "first observed inactive" yourself in your metrics pipeline by latching the timestamp the first time you see `active = false` for a given slot.** Postgres 14 added `conflicting`; Postgres 16 added `invalidation_reason`; Postgres 17 added `inactive_since`.

- **`invalidation_reason` (PG 16+) — post-mortem for a lost slot.** When a slot is invalidated, this column tells you **why**, with values including:
  - `wal_removed` — slot fell behind `max_slot_wal_keep_size` (the common case — covered by the recovery procedure below).
  - `rows_removed` — a logical slot fell behind `hot_standby_feedback`-related row visibility limits.
  - `wal_level_insufficient` — `wal_level` was downgraded from `logical` (rare but devastating; recheck your `postgresql.conf` and any Patroni/RDS parameter group changes).

  Capture this column in your incident response runbook — it changes the fix. `wal_removed` means "raise `max_slot_wal_keep_size` or fix the consumer"; `wal_level_insufficient` means "someone changed `wal_level` and you must fix that before recreating the slot or the new slot will also fail."

**Alert thresholds** (adjust based on your WAL generation rate and free disk):
- **Warning: `safe_wal_size < 50 GB`** (or `bytes_behind_restart > 50 GB` if `safe_wal_size` is NULL because `max_slot_wal_keep_size = -1`) — investigate within the hour.
- **Critical: `safe_wal_size < 10 GB` or `safe_wal_size < 0`** — page on-call; slot invalidation is imminent.
- **Critical: `wal_status IN ('unreserved', 'lost')`** — page on-call; the slot is already at risk or already invalidated.
- **Critical: `inactive_since < now() - interval '5 minutes'`** — page on-call; Debezium is disconnected and WAL is piling up with no consumer. (Requires Postgres 17+; on older versions, alert on `active = false` persisting for 5 minutes via a latched timestamp in your metrics pipeline.)

**Two Postgres safety nets to know about:**

- **`max_slot_wal_keep_size` (Postgres 13+)** — a backstop cap. If a slot falls behind by more than this limit, Postgres **auto-invalidates** the slot rather than letting WAL fill the disk. Set it to e.g. `50GB` as a "the database stays up even if Debezium dies" guarantee. The invalidated slot must be recreated manually (and Debezium will need an initial snapshot again for that table), so this is a "lose CDC but keep the database alive" tradeoff — usually the right one.

  ```
  # postgresql.conf
  max_slot_wal_keep_size = 50GB   # auto-invalidate slots that exceed this lag
  ```

- **`wal_status` column in `pg_replication_slots` (Postgres 13+)** — exposes the slot's health:
  - `reserved` — healthy, Postgres is holding the WAL the slot needs.
  - `extended` — the slot is using more WAL than `max_wal_size` would normally retain, but still safe.
  - `unreserved` — the slot is at risk of invalidation; immediate WAL it needs may be gone soon.
  - `lost` — the slot has been **invalidated**. The slot row still exists but Debezium cannot resume from it — the WAL it needed has been deleted. See the dedicated **"Recovering from `wal_status = 'lost'`"** subsection just below for the full step-by-step procedure (drop slot → recreate → restart connector with `snapshot.mode: never` → run targeted MERGE INTO backfill from Postgres PRIMARY for the lost window).

##### Recovering from `wal_status = 'lost'` — full procedure for the PostgresConnector

When `pg_replication_slots.wal_status = 'lost'`, the slot row still exists in Postgres but is unusable — Postgres has already deleted the WAL segments the slot was pointing at (typically because `max_slot_wal_keep_size` was exceeded after a connector outage). Debezium cannot resume from a `lost` slot; restarting the connector against it returns "requested WAL segment X has already been removed." There is a specific, four-step recovery procedure for the PostgresConnector:

1. **Drop the invalid slot in Postgres.** The slot row exists but is useless; remove it so the next step can recreate it cleanly.
   ```sql
   -- Run on the Postgres primary.
   SELECT pg_drop_replication_slot('debezium_slot');
   ```

2. **Recreate the slot at the current WAL position.** The new slot starts fresh at `pg_current_wal_lsn()` — it has no history of the pre-invalidation window.
   ```sql
   SELECT pg_create_logical_replication_slot('debezium_slot', 'pgoutput');
   ```

3. **Restart the connector with `snapshot.mode: never`** (or its 2.x preferred alias `no_data`) one-time. This tells Debezium to skip the per-row snapshot and resume CDC streaming from the new slot's current WAL position — no re-reading of every existing row, no risk of duplicate inserts for rows already in Iceberg.
   ```yaml
   # In your KafkaConnector CRD or POSTed connector config:
   snapshot.mode: never           # 2.x alias of no_data — both are accepted
   # Do NOT use: snapshot.mode: recovery
   # `recovery` is REJECTED by the PostgresConnector at registration —
   # it is a MySQL/MariaDB/SQL Server only mode (those connectors maintain
   # a Kafka schema-history topic; PostgreSQL does not).
   ```
   After the connector restart succeeds and is `RUNNING` in the Kafka Connect status, revert `snapshot.mode` back to its normal value (typically unset → default `initial`) for the next legitimate cold start, so a future fresh-environment bootstrap still does the full initial snapshot it expects to.

4. **Run a targeted MERGE INTO backfill from Postgres PRIMARY to fill the pre-invalidation window.** The new slot starts at `now()` — every change committed between the slot's invalidation and step 3 is lost forever from Debezium's perspective. Backfill that window from Postgres PRIMARY (the ground truth, not a replica) using the detection-and-backfill recipe documented earlier in this file ("Detection recipe: already-missed rows after a replica lag incident"). The shape is the same: query `max(updated_at)` from Iceberg, query `max(updated_at)` from Postgres PRIMARY, MERGE INTO the gap range using `event_id` (or PK) as the join key. The MERGE INTO is idempotent, so it is safe to re-run if it fails midway.

> **Why `snapshot.mode: never` (not `initial`, not `recovery`) for step 3?**
> - `initial` would re-snapshot **every existing row** in every monitored table — billions of redundant reads for a multi-TB table, and every row arrives as an `op='r'` event that your MERGE INTO needs to be idempotent against. Operationally painful and unnecessary if your Iceberg target already contains the pre-invalidation rows.
> - `recovery` is **not a valid value on the PostgresConnector** (Kafka Connect REST API will reject the connector config with a validation error). The mode exists only for MySQL, MariaDB, and SQL Server connectors that maintain a schema-history topic; PostgreSQL has no equivalent topic to recover from.
> - `never` (alias `no_data`) is the correct choice: skip the snapshot, start streaming from the new slot's position, and rely on the explicit step-4 backfill to fill the gap. This is the canonical Postgres recovery shape and the one engineers should remember.

> **Preflight check before the next outage: `max_slot_wal_keep_size`.** The `wal_status = 'lost'` event was triggered by Postgres's `max_slot_wal_keep_size` setting — once the slot fell behind by more than this limit, Postgres invalidated it to protect the primary's disk. After completing the recovery procedure, audit your `max_slot_wal_keep_size` value (typical: `50GB`) against your worst-case acceptable downtime: at your WAL generation rate of `X MB/min`, a `50GB` budget tolerates approximately `50,000 / X` minutes of consumer downtime. If your worst-case CDC outage budget is greater than that, either raise `max_slot_wal_keep_size`, accept that long outages will require a backfill, or add monitoring that pages on-call before the slot crosses 80% of the limit.

  ```sql
  -- Add wal_status + safe_wal_size to the lag query for a fuller picture (Postgres 13+):
  -- Use restart_lsn (NOT confirmed_flush_lsn) for slot-survival headroom — see
  -- "Monitoring replication slot lag" above for why these two LSNs diverge.
  SELECT slot_name, active, wal_status, safe_wal_size,
         pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)         AS bytes_behind_restart,
         pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS bytes_behind_consumer
  FROM pg_replication_slots
  WHERE slot_name = 'debezium_slot';
  ```

Wire the two queries above into your monitoring system (Prometheus + `postgres_exporter`, Datadog's Postgres integration, or a 30-second Kubernetes CronJob that pushes the values to your metrics backend). The cost of the check is negligible — `pg_replication_slots` is a system catalog view, not a WAL scan.

#### Debezium heartbeat events — keeping the slot alive on idle tables

**The problem.** A replication slot tracks which WAL position Debezium has confirmed processing (the slot's `confirmed_flush_lsn`). Postgres retains every WAL segment from `confirmed_flush_lsn` forward until the slot's confirmed position advances. On **low-traffic tables** — e.g., a `permissions` table that rarely changes, a `plans` dimension updated weekly, a `feature_flags` table touched once a month — the slot can lag behind **indefinitely** because there's simply no new data flowing through it. `confirmed_flush_lsn` never advances, so Postgres holds WAL for those quiet periods even though the pipeline is healthy. The bytes-behind metric from the previous subsection ticks upward; your slot-lag alert eventually fires; on-call wakes up to investigate; everything is actually fine, the table just had nothing happen on it. False pages on a quiet weekend are a real way for teams to lose confidence in their CDC monitoring.

The same scenario can also, in the worst case, cause real harm: if `bytes_behind` crosses `max_slot_wal_keep_size` because of pure idleness, Postgres will **auto-invalidate the slot** (see the prior subsection) and Debezium loses its position — even though nothing was actually wrong with the consumer.

> **Why this is much worse than it looks in a multi-database Postgres cluster — WAL is cluster-wide, not per-database.** In a Postgres cluster that hosts multiple databases (e.g., a single RDS/Aurora/Cloud SQL instance running `app_prod`, `app_staging`, `analytics_warehouse`, and `internal_tools` databases side by side), **the WAL is a single shared stream at the cluster level — not per-database.** Every commit on every database in the cluster writes to the same `pg_wal/` directory and advances the cluster's `pg_current_wal_lsn()`. A replication slot, even one bound to a single low-traffic database via the slot's `database` field, **pins WAL retention at the cluster level**: it holds back every WAL segment from its `confirmed_flush_lsn` forward, regardless of which database in the cluster produced the entries in those segments. The practical consequence: when a high-traffic database (your production app generating thousands of TPS) produces many WAL segments per minute, those segments **accumulate against the replication slot on the low-traffic database** (a staging or analytics DB with no writes of its own) — because the slot's `confirmed_flush_lsn` on the quiet database never advances, but the cluster-wide `pg_current_wal_lsn()` is racing forward driven by the noisy neighbor. The `bytes_behind` reported for the quiet slot is **mostly WAL from the noisy database**, not from the database the slot actually monitors. This is why **heartbeats are mandatory, not optional, on every replication slot in a multi-database cluster** — without a heartbeat, the quiet slot's `confirmed_flush_lsn` will fall behind cluster-wide WAL production within hours and trip `max_slot_wal_keep_size` even though the monitored database itself is doing nothing. A useful mental model: the slot does NOT care which database wrote the WAL — it only cares about its own `confirmed_flush_lsn` position relative to the **cluster's** current WAL position. Heartbeating the slot forces that position forward.

**The solution: heartbeat events.** Debezium can write a "heartbeat" row to a dedicated table in Postgres at a configurable interval. The heartbeat is just an `INSERT` (or `INSERT ... ON CONFLICT DO NOTHING`) into a small table you create for this purpose. That INSERT generates a tiny change event in the WAL — which gives Debezium something to read, decode, and confirm, which **advances `confirmed_flush_lsn` even when every monitored table is quiet.** Postgres can then release the older WAL segments. Slot lag stays near zero; alerts stop firing falsely; `max_slot_wal_keep_size` is never approached by accident.

**Configuration in the Debezium connector.** Add these two properties to your connector config (the `KafkaConnector` CRD under Strimzi, or the JSON POSTed to the Connect REST API under the raw deployment):

```json
{
  "heartbeat.interval.ms": "30000",
  "heartbeat.action.query": "INSERT INTO public.debezium_heartbeat (id, heartbeat_at) VALUES (1, now()) ON CONFLICT (id) DO UPDATE SET heartbeat_at = now()"
}
```

- **`heartbeat.interval.ms`**: how often (in milliseconds) Debezium writes a heartbeat. **Default is `0` (disabled).** Recommend `30000` (30 seconds) for production — frequent enough to keep `confirmed_flush_lsn` advancing well within any reasonable slot-lag alert window, infrequent enough that the heartbeat table stays small and write overhead is negligible.
- **`heartbeat.action.query`**: the exact SQL Debezium runs against the Postgres database at each heartbeat tick. The row change produced by this SQL flows through the WAL just like any other change event, and Debezium's processing of it is what advances the slot. **Use the `INSERT ... ON CONFLICT (id) DO UPDATE` form against a fixed `id = 1` row** so the heartbeat table holds exactly one row forever — see Setup below for the table-side `CHECK (id = 1)` constraint that enforces this.

> **DO NOT use `INSERT ... ON CONFLICT DO NOTHING` against a `SERIAL PRIMARY KEY` column.** Earlier versions of this guide showed that pattern; it is wrong. A `SERIAL` column generates a fresh `id` value on every INSERT, so there is **never** a conflict — `ON CONFLICT DO NOTHING` always falls through and a new row is inserted every 30 seconds. The heartbeat table then grows unboundedly (one row per heartbeat = ~2,880 rows/day = ~1M rows/year per source database), eventually slowing down the heartbeat itself, the WAL decoder, and any maintenance that scans the table. The fix is the **fixed-row UPDATE** pattern shown above and the matching `CHECK (id = 1)` schema below — together they guarantee the heartbeat table contains exactly one row at all times.

**Setup required: create the heartbeat table before enabling heartbeats.** Debezium runs the `heartbeat.action.query` verbatim — if the target table doesn't exist or the user can't write to it, the heartbeat fails silently and you're back to the original problem. Run this on the Postgres primary:

```sql
-- Fixed-row design: id is always 1, so the ON CONFLICT (id) DO UPDATE in
-- heartbeat.action.query collapses every heartbeat into the same single row.
-- The CHECK constraint ensures no other id can ever be inserted, even by
-- mistake — keeping the table at exactly one row forever.
CREATE TABLE IF NOT EXISTS public.debezium_heartbeat (
  id INTEGER PRIMARY KEY DEFAULT 1,
  heartbeat_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT single_row CHECK (id = 1)
);

-- Grant access to the role Debezium connects as. No sequence to grant on —
-- INTEGER PRIMARY KEY (not SERIAL) has no underlying sequence object.
GRANT SELECT, INSERT, UPDATE ON public.debezium_heartbeat TO debezium_user;
```

Also add the heartbeat table to the publication (required if you're using `pgoutput`, which is the recommended plugin from the prerequisites section above):

```sql
ALTER PUBLICATION debezium_pub ADD TABLE public.debezium_heartbeat;
```

If you skip the publication step, the heartbeat INSERT will commit successfully in Postgres but won't be visible to the logical decoder — so it won't actually advance the slot. The slot lag will keep growing as if heartbeats were disabled.

> **CRITICAL — `publication.autocreate.mode=filtered` will silently EXCLUDE the heartbeat table from the auto-created publication.** This is one of the highest-frequency "I configured heartbeats but the slot is still lagging" bugs. The `publication.autocreate.mode` Debezium connector property controls how Debezium creates the Postgres publication on its first startup. The valid values per the Debezium Postgres connector docs are:
>
> - **`all_tables`** — Debezium runs `CREATE PUBLICATION debezium_pub FOR ALL TABLES`. The publication covers every table in the database, including the heartbeat table — so heartbeats work without any extra config.
> - **`filtered`** — Debezium runs `CREATE PUBLICATION debezium_pub FOR TABLE <list>`, where `<list>` is **derived from `table.include.list`** (intersected with `schema.include.list` if set, and minus anything in `table.exclude.list` / `schema.exclude.list`). **Tables not in `table.include.list` are NOT in the auto-created publication** — the heartbeat table is silently excluded.
> - **`disabled`** — Debezium does not create or modify any publication; you must `CREATE PUBLICATION` yourself before starting the connector.
>
> **Which mode is the default depends on the Debezium version and how you configure the connector.** Newer Debezium versions (Debezium 2.x and later) default to `all_tables`, but **production deployments commonly override this to `filtered`** because operators want least-privilege publications that only carry the tables actually being ingested. If your team has standardized on `filtered` (a very reasonable security choice), the heartbeat table will be missing from the publication unless you explicitly handle it. The failure mode is silent: the heartbeat INSERT commits, Postgres logs the change in the WAL, but `pgoutput` filters the event out (it is not in the publication), so the WAL position the Debezium consumer "sees" never advances past the heartbeat. The slot lag continues to grow exactly as it did before you enabled heartbeats. Engineers commonly add a heartbeat, watch the lag keep climbing, and conclude "heartbeats don't work in our environment" — when the real issue is the publication's table list.
>
> **Two correct solutions — pick one:**
>
> **1. Add the heartbeat table to `table.include.list` in the connector config.** This is the simplest fix and works automatically with `publication.autocreate.mode=filtered`. The heartbeat table becomes part of the publication via the standard auto-create path.
>
> ```yaml
> # Debezium connector config (Strimzi KafkaConnector or Connect REST JSON):
> table.include.list: "public.events,public.users,public.orders,public.debezium_heartbeat"
> publication.autocreate.mode: "filtered"
> heartbeat.interval.ms: "30000"
> heartbeat.action.query: "INSERT INTO public.debezium_heartbeat (id, heartbeat_at) VALUES (1, now()) ON CONFLICT (id) DO UPDATE SET heartbeat_at = now()"
> ```
>
> You'll then want to filter the resulting `app-db.public.debezium_heartbeat` Kafka topic out of your Spark consumer (see "Add a heartbeat topic filter in your Kafka consumer" below).
>
> **2. Use `publication.autocreate.mode=disabled` and manage the publication manually.** This is the right answer when your security team requires that database publications be reviewed and approved by a DBA (i.e., the connector should NOT have `CREATE PUBLICATION` privilege). You then create and maintain the publication yourself:
>
> ```sql
> -- Run as a DBA on the Postgres primary, once at setup:
> CREATE PUBLICATION debezium_pub FOR TABLE
>   public.events,
>   public.users,
>   public.orders,
>   public.debezium_heartbeat;
>
> -- Adding a new table later (e.g., onboarding a new domain table to CDC):
> ALTER PUBLICATION debezium_pub ADD TABLE public.new_domain_table;
> ```
>
> ```yaml
> # Debezium connector config:
> publication.name: "debezium_pub"
> publication.autocreate.mode: "disabled"
> ```
>
> The heartbeat table is in the publication because **you** put it there; the connector never touches publication membership.
>
> **Verification query — run this after any publication change to confirm the heartbeat table is included:**
>
> ```sql
> SELECT pubname, schemaname, tablename
> FROM pg_publication_tables
> WHERE pubname = 'debezium_pub'
>   AND tablename = 'debezium_heartbeat';
> ```
>
> If this query returns zero rows, the heartbeat table is NOT in the publication and slot lag will continue growing despite `heartbeat.interval.ms` being set. Re-run the `ALTER PUBLICATION ... ADD TABLE` (or add the heartbeat table to `table.include.list` and restart the connector so the auto-create path picks it up).

**Add a heartbeat topic filter in your Kafka consumer.** Heartbeats are a maintenance signal for the replication slot, not real business data. Once they're flowing through Kafka, your Spark Structured Streaming consumer should drop them before they reach the MERGE INTO logic — otherwise you'll get spurious "inserts" into an Iceberg table that you don't care about every 30 seconds, plus extra topic-routing complexity in the consumer.

```python
# In your Spark Structured Streaming consumer, filter out the heartbeat topic.
# The topic name follows the pattern: <topic.prefix>.<schema>.<table>
# With topic.prefix=app-db, the heartbeat topic is app-db.public.debezium_heartbeat.
df = df.filter(~col("topic").like("%.debezium_heartbeat"))
```

If your consumer subscribes to specific topics by name rather than a wildcard, simply don't include the heartbeat topic in the subscribe list. If you use a regex subscription (e.g., `subscribePattern = "app-db\\.public\\..*"`), the filter above is the cleanest way to exclude it.

**When to enable heartbeats: almost always for production CDC.** Enable heartbeats for any pipeline that includes tables which may go hours or longer without changes. A practical rule: **if any table in your publication averages less than one DML event per hour, enable heartbeats.** Examples of tables that almost always need this: `permissions`, `roles`, `plans`, `feature_flags`, `tenants`, `subscriptions` (in a low-churn B2B SaaS), `pricing_tiers`, weekly-updated dimensions. Even on busy publications where you'd expect constant traffic, weekend and overnight lulls can still produce multi-hour quiet windows — so the safe default is "enable heartbeats on every production CDC pipeline." The overhead is one tiny INSERT every 30 seconds; the protection is no false slot-lag alerts and no accidental slot invalidation on quiet tables.

#### Post-catch-up compaction — required after every CDC outage

After a CDC outage and catch-up replay, the historical partitions written during replay will have many small Parquet files (one file per MERGE commit, potentially hundreds for a 6-hour catch-up). These small files slow down subsequent queries on those date ranges — Trino has to open and read every file's footer to plan a scan, and a partition with 500 tiny Parquet files costs ~500x the planning overhead of one well-sized file.

After the catch-up completes and the pipeline is stable, run a partition-scoped compaction over the affected date range. Do **not** wait for the normal weekly compaction window — query latency on those partitions stays degraded until the compaction runs.

```sql
-- Compact the historical date range affected by the catch-up (Spark):
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  where   => 'occurred_at >= DATE ''2026-05-22'' AND occurred_at < DATE ''2026-05-23''',
  options => map('target-file-size-bytes', '268435456', 'min-input-files', '5')
);
```

Or using Trino for the affected partition range:

```sql
ALTER TABLE analytics.events EXECUTE optimize(file_size_threshold => '128MB')
WHERE occurred_at >= DATE '2026-05-22' AND occurred_at < DATE '2026-05-23';
```

Scope the `where` clause / `WHERE` predicate to **only** the date range that was actively written during the catch-up — there is no benefit to re-compacting partitions that were already well-sized. After the rewrite commits, follow with `expire_snapshots` on the normal schedule so the pre-compaction small files actually leave MinIO (the rewrite produces new files; the small ones stay referenced by prior snapshots until expiration runs).

> **What Trino `EXECUTE optimize` does and does NOT do.** Trino `ALTER TABLE ... EXECUTE optimize` rewrites data files to the target file size under the **current** partition spec. It is appropriate for the post-catch-up small-file consolidation scenario above (lots of small data files written by many small MERGE commits during the replay; no delete-file accumulation involved). It does **NOT** apply pending position delete files — for delete file accumulation from a CDC pipeline (the bulk-DELETE-after-Debezium scenario in the next section), use Spark `rewrite_position_delete_files` (targeted, fast) or Spark `rewrite_data_files` with `options => map('delete-file-threshold', '1')` (full). Trino OPTIMIZE is appropriate for small-file consolidation after bulk appends, not for clearing accumulated delete files from a CDC pipeline.

> **`createOrReplace()` is NOT safe for repeated bootstrap runs.** A common pattern in CDC bootstrap scripts is to seed the Iceberg table from a Postgres snapshot before pointing the streaming consumer at the Kafka topic — engineers reach for `df.writeTo("iceberg.analytics.events").using("iceberg").createOrReplace()` because it sounds idempotent. **It is not** — `createOrReplace()` drops and recreates the table, wiping every row written since the initial bootstrap (including any rows the streaming consumer has already merged in from Kafka). Re-running the bootstrap script after the streaming consumer is live will erase live data and reset the Iceberg snapshot history. Use `writeTo("iceberg.analytics.events").append()` with a row-count check that asserts the target table is empty before appending, or use `MERGE INTO ... WHEN NOT MATCHED THEN INSERT` if duplicates from re-runs are a concern. See the "Pattern A — Full refresh" callout near the top of this guide for the broader `createOrReplace()` warning.

#### Debezium PostgresConnector `op` field values — get these right

Every Debezium change event has a top-level `op` field that names what kind of change it represents. **The values are connector-specific** — and the most common pitfall is to assume `INSERT` is `'i'` because that's what some other Debezium connectors (e.g., Cassandra) use. **The PostgreSQL connector does NOT use `'i'`.** Memorize this table or your MERGE INTO logic will silently drop every insert.

| `op` value | Meaning | When Debezium emits it |
|---|---|---|
| `'c'` | **create (INSERT)** — NOT `'i'`, common confusion with other connectors | Every `INSERT` committed in Postgres after Debezium starts streaming the WAL |
| `'u'` | update (UPDATE) | Every `UPDATE` committed in Postgres |
| `'d'` | delete (DELETE) | Every `DELETE` committed in Postgres (the `before` field has the deleted row; `after` is null) |
| `'r'` | **read (initial snapshot)** | During `snapshot.mode=initial`, Debezium does an initial SELECT of every existing row and emits each one as `op='r'`. Pre-existing rows look like reads, not inserts. |
| `'t'` | truncate | `TRUNCATE TABLE` (if `truncate.handling.mode=include`) |

**`snapshot.mode=initial` matters for your MERGE INTO.** When Debezium first connects to a Postgres table, it does an initial snapshot of every existing row and emits all of them as `op='r'` events into Kafka **before** any live `op='c'` / `op='u'` / `op='d'` events arrive. If your consumer's MERGE INTO only handles `'c'` and `'u'`, every single pre-existing row gets dropped. **Treat `'r'` like `'c'`: insert-if-not-exists.**

**Correct MERGE INTO pattern for a CDC consumer reading PostgresConnector events:**

```python
# events_delta: DataFrame from the Kafka micro-batch, with columns:
#   event_id (primary key), op (one of 'c','u','d','r','t'), <other event columns>
events_delta.createOrReplaceTempView("events_delta")

spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_delta s
    ON t.event_id = s.event_id
    -- Deletes from Postgres become deletes in Iceberg. MUST be a separate branch —
    -- collapsing into `WHEN MATCHED AND s.op IN ('u', 'd') THEN UPDATE SET *` would
    -- silently null out every column of the deleted row (Debezium 'd' events have a
    -- null `after` image — see the CRITICAL BUG callout below this code block).
    WHEN MATCHED AND s.op = 'd' THEN DELETE
    -- Updates, re-snapshot reads against an already-present row, and inserts that
    -- arrive after a same-PK delete all overwrite the existing row's columns.
    WHEN MATCHED AND s.op IN ('u', 'c', 'r') THEN UPDATE SET *
    -- Inserts, initial-snapshot reads, and (defensively) updates against a row
    -- that's missing from Iceberg all land as inserts.
    WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT *
""")
```

**Common mistakes this avoids:**
- **`s.op IN ('i', 'u')` — WRONG.** PostgresConnector emits `'c'`, not `'i'`. The filter matches nothing and every insert is silently dropped. The correct expression is `s.op IN ('c', 'u')`.
- **Omitting `'r'` from the `WHEN NOT MATCHED` branch.** If the consumer starts against a newly-created Debezium connector, the initial snapshot of every existing row arrives as `op='r'`. A clause that says `WHEN NOT MATCHED AND s.op = 'c' THEN INSERT *` will drop the entire snapshot and the Iceberg table will be empty until the next live `INSERT` happens in Postgres.
- **Treating `'t'` (truncate) as a no-op.** If your application ever runs `TRUNCATE TABLE events` in Postgres, Debezium will emit a `'t'` event. Decide explicitly whether your CDC consumer truncates Iceberg too (usually yes, for symmetry) or ignores the event (and logs a warning so an operator notices).

> **CRITICAL BUG — `WHEN MATCHED AND s.op IN ('u', 'd') THEN UPDATE SET *` silently corrupts deleted rows.** A very common AI-generated MERGE pattern collapses the UPDATE and DELETE branches into one to "save lines":
> ```sql
> -- WRONG — silently nulls out every deleted row.
> WHEN MATCHED AND s.op IN ('u', 'd') THEN UPDATE SET *
> WHEN NOT MATCHED AND s.op IN ('c', 'r') THEN INSERT *
> ```
> Debezium DELETE events have a **null (or empty) `after` image** — the deleted row's column values are only present in `before`, not `after`. `UPDATE SET *` copies the source row's columns into the target, which for an `op='d'` row means copying nulls into every non-PK column of the Iceberg row. **The row is not deleted — it stays in Iceberg with every business column wiped to NULL.** Downstream dashboards show ghost rows with PK only and no data; downstream `WHERE deleted_at IS NULL` filters still match these rows because `deleted_at` is now NULL too. There is no error, no warning — just silently nulled rows that look like a different production bug.
>
> **The correct three-branch pattern (DELETE / UPDATE / INSERT) is what the example above uses.** Memorize the shape:
> ```sql
> WHEN MATCHED AND s.op = 'd' THEN DELETE
> WHEN MATCHED AND s.op IN ('u', 'c', 'r') THEN UPDATE SET *
> WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT *
> ```
> Note: the matched-UPDATE branch may include `'c'` and `'r'` defensively — a same-PK insert-after-delete or a re-snapshot that re-emits an already-present row should overwrite the existing row's columns, not be silently ignored. The not-matched-INSERT branch may include `'u'` defensively — if your initial snapshot was incomplete (rare, but happens with `no_data` after a manual JDBC bootstrap), an `op='u'` for a row that was never inserted into Iceberg should still land as an insert rather than be dropped.

> **Glossary — terms used in this MERGE INTO section and the CDC/recovery callouts around it.** Skim once; come back when a term shows up in a callout below and you want a one-line refresher without re-reading the surrounding section.
>
> - **LSN (Log Sequence Number)** — Postgres's WAL (Write-Ahead Log) position, a strictly-increasing 64-bit integer. Debezium captures it into each change event's `source.lsn` field. **Higher LSN = later event** in Postgres's commit order. The per-key LSN dedup pattern (`MERGE INTO ... WHEN MATCHED AND s.source_lsn > t.source_lsn THEN UPDATE`) uses this monotonicity to make late-arriving duplicates idempotent.
> - **`op='r'`** — Debezium **snapshot read** event. Same row data as a live `op='c'` insert, but emitted while Debezium is reading the existing rows of a table during its initial snapshot (or an incremental snapshot via the signal table) — it did NOT come from a WAL change. Treat `op='r'` as an insert (when the row is missing in Iceberg) or as an idempotent overwrite (when the row is already present), exactly as the three-branch MERGE above does.
> - **`expire_snapshots`** — Iceberg maintenance operation that permanently deletes old snapshot metadata. After it runs, `rollback_to_snapshot` to any expired snapshot is no longer possible. Relevant here because the "undo the DELETE via rollback" recovery option in the cutover guidance is only valid until `expire_snapshots` next runs (typically every 7 days on this stack).
> - **`_debezium_connect_offsets`** — Strimzi's default name for the Kafka Connect **source-offset topic**. Stores, per Debezium connector, where it last confirmed reading in the Postgres WAL (the LSN it most recently flushed). **Loss of this topic causes Debezium to re-snapshot the source database from scratch** on the next connector restart — the worst-case recovery scenario, which is why this topic is configured with `replication.factor = 3` on the production stack. Distinct from `__consumer_offsets` (Kafka broker's consumer-group offset topic — unrelated).

> **REPLICA IDENTITY FULL reminder for the DELETE branch with a non-PK filter.** The three-branch MERGE above uses `WHEN MATCHED AND s.op = 'd' THEN DELETE` — a simple PK-only DELETE that works under the default `REPLICA IDENTITY DEFAULT` (which only emits the PK in the `before` image of a DELETE event). **The moment you tighten the DELETE branch with a non-PK predicate**, e.g.:
>
> ```sql
> -- Conditional DELETE — only delete the matched row if the deleted-row's tenant_id was 'acme'.
> WHEN MATCHED AND s.op = 'd' AND s.tenant_id = 'acme' THEN DELETE
> ```
>
> ...the `s.tenant_id` value in the predicate **comes from the Debezium `before` image** (because for `op='d'`, the `after` field is null — the deleted row's column values are only in `before`). Under the default `REPLICA IDENTITY DEFAULT`, **`before` only contains the primary key columns** — `tenant_id` is NULL, the predicate `s.tenant_id = 'acme'` evaluates to NULL (not true), the DELETE branch silently does not fire, and the row stays in Iceberg with no error. The MERGE looks like it succeeded; the cross-tenant scoped delete you wanted was a no-op.
>
> The fix is to set `REPLICA IDENTITY FULL` on the source Postgres table BEFORE deploying any DELETE branch that filters on non-PK columns:
>
> ```sql
> -- Run on the Postgres primary. Doubles the WAL volume for UPDATE-heavy tables
> -- (the before image now carries every column, not just the PK), but makes the
> -- full before-image available to Debezium for every UPDATE and DELETE.
> ALTER TABLE events REPLICA IDENTITY FULL;
> ```
>
> See the Postgres prerequisites section above for the full discussion of `REPLICA IDENTITY` modes and the WAL-volume tradeoff. The rule of thumb: PK-only DELETE works with the default `REPLICA IDENTITY DEFAULT`; any DELETE branch that touches a non-PK column requires `REPLICA IDENTITY FULL`. If your CDC MERGE just does `WHEN MATCHED AND s.op = 'd' THEN DELETE` (no filter), the default is sufficient.

> **Deduplicate the staging batch to one row per key before MERGE.** Debezium can emit multiple change events for the same primary key within a single Spark micro-batch — three rapid UPDATEs to `event_id = 42` in a row, or an UPDATE followed by a DELETE, all land in the same `events_delta` DataFrame. **Spark's `MERGE INTO` does not define which source row "wins" when multiple source rows match the same target row** — it raises `MERGE_CARDINALITY_VIOLATION` (Spark 3.4+) or, on older Spark, applies them in nondeterministic order. Always dedupe to the latest event per key before the MERGE:
> ```python
> from pyspark.sql.window import Window
> from pyspark.sql.functions import col, row_number
>
> # Keep only the latest event per primary key in this micro-batch.
> # Order by source_lsn DESC (or by source_ts_ms DESC if you don't persist LSN).
> w = Window.partitionBy("event_id").orderBy(col("source_lsn").desc())
> events_dedup = (
>     events_delta
>     .withColumn("_rn", row_number().over(w))
>     .filter(col("_rn") == 1)
>     .drop("_rn")
> )
> events_dedup.createOrReplaceTempView("events_delta")
> ```
> Without this dedup, the MERGE result is nondeterministic on retry: replay the same micro-batch and a different source row may "win," producing a different final Iceberg row. This breaks the idempotency property that makes MERGE INTO safe to re-run.

> **The `before` field requires `REPLICA IDENTITY FULL` to be fully populated.** The `before` field in Debezium UPDATE events is only fully populated if the Postgres table has `REPLICA IDENTITY FULL` set (`ALTER TABLE events REPLICA IDENTITY FULL`). Without it, the `before` image only contains the primary key columns (the default `REPLICA IDENTITY DEFAULT`). For `WHEN MATCHED` logic that uses `before` field values (e.g., change detection like "only apply if the old `status` was `pending`," or audit-trail capture of the prior column values), you need FULL replica identity. For simple upsert patterns (just apply the `after` image — the MERGE INTO above falls into this category), the default is sufficient. See the Postgres prerequisites section above for the `ALTER TABLE ... REPLICA IDENTITY FULL` syntax and the WAL-volume cost (~2x for UPDATE-heavy tables).

> **TOMBSTONE EVENTS — the second message you forgot to filter.** When Debezium's PostgresConnector emits a delete (`op='d'`), it actually publishes **two Kafka messages** for that single Postgres DELETE: (1) the regular change event with `op='d'` and the deleted row in `before`, and (2) immediately after, a **tombstone event** — a message with the **same key** as (1) but a **null value (null payload)**. The tombstone exists so Kafka's **log compaction** can eventually drop the entire history of that key from the topic — log compaction treats a null-value message as "delete this key from the compacted log."
>
> **Why this matters for your Spark Structured Streaming consumer.** If you do not filter tombstones out before your MERGE INTO logic, the null-payload message reaches the `events_delta` DataFrame as a row with every field null, including `op` and `event_id`. Depending on how your `from_json` parses it, you may get a NullPointerException, a `NOT MATCHED` clause that fires with all-null source columns and inserts garbage, or silently dropped rows. Always filter tombstones at the Kafka-read stage:
>
> ```python
> # Filter tombstones: Kafka records where the value is null are tombstone follow-ups.
> # Drop them before parsing the Debezium envelope.
> raw_stream = (
>     spark.readStream.format("kafka")
>          .option("subscribe", "postgres.public.events")
>          .load()
>          .filter(col("value").isNotNull())   # drop tombstones
> )
> ```
>
> Tombstones can also be disabled at the source via `tombstones.on.delete=false` in the Debezium connector config — but the default is `true`, and disabling them breaks Kafka log compaction's ability to garbage-collect deleted keys. **Default recommendation: keep tombstones on at the source and filter them in the consumer.**

#### Iceberg delete write modes — choose one for your CDC table

When CDC replays Postgres `DELETE` (and `UPDATE`) events as `DELETE FROM` / `MERGE INTO` against Iceberg, the table's **delete write mode** determines what actually lands on MinIO. Iceberg supports two modes, controlled by the table property `write.delete.mode`:

| Mode | Property value | What `DELETE` does | Write speed | Read speed | When to choose |
|---|---|---|---|---|---|
| **Merge-on-Read (MoR)** | `write.delete.mode = 'merge-on-read'` | Writes small **positional or equality delete files** that mark rows to ignore. The original Parquet data files are untouched. | Fast (only the small delete file is written) | Slower as delete files accumulate — every read merges deletes at query time | High-delete-rate CDC streams; tables with frequent UPDATEs/DELETEs where you can run periodic compaction |
| **Copy-on-Write (CoW)** | `write.delete.mode = 'copy-on-write'` | Rewrites every affected Parquet data file without the deleted rows, producing a brand new file. No delete files are created. | Slower (full file rewrite on every DELETE) | Fast — no delete files for the reader to merge | Tables with infrequent deletes where read performance matters most; OLAP-style fact tables that are mostly append-only |

> **CRITICAL — Iceberg 1.5.2 default write mode is Copy-on-Write (CoW) for ALL three operations.** Verified from the Iceberg 1.5.2 source (`TableProperties.java`):
>
> ```
> DELETE_MODE_DEFAULT = COPY_ON_WRITE
> UPDATE_MODE_DEFAULT = COPY_ON_WRITE
> MERGE_MODE_DEFAULT  = COPY_ON_WRITE
> ```
>
> The library defaults are `write.delete.mode = copy-on-write`, `write.update.mode = copy-on-write`, and `write.merge.mode = copy-on-write`. **Merge-on-Read must be EXPLICITLY configured** at table creation or via `ALTER TABLE ... SET TBLPROPERTIES`. Older blog posts and AI-generated content frequently get this backwards — do not trust any claim that "MoR is the Iceberg default" without checking the source. Check what your table is actually using with `SHOW CREATE TABLE iceberg.analytics.events` (Spark) or query `iceberg.analytics."events$properties"` (Trino) and look for all three properties; if a property is absent, the table is using the CoW default for that operation.
>
> **If a CDC table has accumulated position delete files** (`content = 1` rows in `$files` — see the diagnostic section below), that means MoR was **explicitly enabled** at some point — either the table was created with `write.delete.mode = 'merge-on-read'` set in TBLPROPERTIES, or a `ALTER TABLE ... SET TBLPROPERTIES` flipped one or more of the three modes. Delete files can also arrive from a Spark `MERGE INTO` that ran while `write.merge.mode = 'merge-on-read'` was set. **Do not assume MoR is the default and that delete files just "appeared on their own"** — investigate the table's actual TBLPROPERTIES history.

> **Three SEPARATE properties control write behavior — setting one does NOT affect the others.**
>
> - `write.delete.mode` — controls how `DELETE FROM` statements are written
> - `write.update.mode` — controls how `UPDATE` statements are written
> - `write.merge.mode` — controls how `MERGE INTO` statements are written
>
> A table whose CDC consumer applies `UPDATE ... SET converted = true` (e.g., marking session records as "converted") is governed by `write.update.mode`, NOT `write.delete.mode`. Setting only `write.delete.mode = 'merge-on-read'` on such a table has zero effect on the UPDATE path — UPDATEs continue to run under the CoW default, rewriting full Parquet files per UPDATE batch. For a CDC pipeline that mixes INSERTs, UPDATEs, DELETEs, and MERGE INTOs, set **all three** properties to the same value to get consistent write behavior:
>
> ```sql
> ALTER TABLE iceberg.analytics.events SET TBLPROPERTIES (
>   'write.delete.mode' = 'merge-on-read',
>   'write.update.mode' = 'merge-on-read',
>   'write.merge.mode'  = 'merge-on-read'
> );
> ```
>
> For most CDC pipelines, set all three to the same value to avoid surprising behavior (e.g., DELETEs writing tiny delete-file markers but UPDATEs silently rewriting whole files in CoW mode, doubling the writer's wall-clock time without any visible config change).

**Set the mode at table creation:**

```sql
CREATE TABLE iceberg.analytics.events (...)
USING iceberg
PARTITIONED BY (day(event_ts))
TBLPROPERTIES (
    'format-version' = '2',
    'write.delete.mode' = 'merge-on-read',   -- or 'copy-on-write'
    'write.update.mode' = 'merge-on-read',
    'write.merge.mode' = 'merge-on-read'
);
```

**Or change it on an existing table** (affects new DELETEs only — does not rewrite history):

```sql
ALTER TABLE iceberg.analytics.events SET TBLPROPERTIES (
    'write.delete.mode' = 'copy-on-write'
);
```

**Practical guidance for CDC pipelines:**

- **Explicitly opt-in to MoR for CDC fact tables.** The Iceberg 1.5.2 library default is CoW for all three modes — MoR is NOT the default and must be set explicitly. The whole point of CDC is to apply many small change events with sub-minute latency — CoW's per-DELETE / per-UPDATE / per-MERGE full-file-rewrite cost would dominate the streaming job's throughput. For a CDC fact table, set all three TBLPROPERTIES (`write.delete.mode`, `write.update.mode`, `write.merge.mode`) to `merge-on-read` at table creation. Then schedule periodic `rewrite_data_files` (e.g., hourly) to fold the accumulated delete files back into the data files and restore read performance. This is the standard MoR maintenance loop.
- **Choose CoW for low-mutation dimension tables.** If a table sees only a handful of DELETEs per day but is read constantly by dashboards, CoW pays the write cost once and gives every reader fast scans afterwards — no compaction job required.
- **Two flavors of delete file under MoR.** *Positional delete files* list `(file_path, row_position)` pairs — exact pointers to deleted rows; produced by `DELETE FROM` with row-level predicates. *Equality delete files* store column-value tuples (e.g., `event_id = 123`) — produced by streaming/CDC writers that don't know the row's physical position. Both are merged in at read time. Engine-by-engine support varies (Spark and Trino both read both flavors as of recent versions); for CDC, equality deletes are the common case because Debezium emits change events keyed by primary key, not by file position.
- **Whichever mode you pick, the 3-step physical-removal sequence still applies for GDPR.** MoR's delete files don't physically remove bytes from MinIO; CoW's file rewrites leave the old files referenced by prior snapshots. Both modes require `rewrite_data_files` (MoR: applies deletes; CoW: small-file consolidation) followed by `expire_snapshots` to free MinIO storage. See the GDPR section in resource 05 for the full sequence.

**When to flip a CDC table from MoR back to CoW.** The Iceberg 1.5.2 library default is CoW; MoR is the right *explicit choice* for most CDC pipelines (set it at table creation as shown above). But for some workloads it's worth switching the explicitly-MoR table back to CoW with `write.delete.mode = 'copy-on-write'` (along with `write.update.mode` and `write.merge.mode`) when **all** of the following are true: (1) the table has a **predictable bulk-delete pattern** (e.g., a nightly retention job that deletes everything older than 90 days; a monthly tenant cleanup; a once-a-week GDPR sweep), (2) the bulk DELETE happens in a maintenance window where extra writer wall-clock is acceptable, (3) the table is **read-heavy** between the bulk-delete jobs — dashboards and BI tools scan it constantly and benefit from never having to merge delete files at read time. In this profile, CoW pushes the rewrite cost into the writer's already-scheduled maintenance window, fully eliminates delete-file accumulation (no `rewrite_data_files`/`rewrite_position_delete_files` maintenance loop needed for delete cleanup), and gives readers consistently fast scans. The tradeoff you accept: each bulk DELETE rewrites every affected Parquet file (slower writer; more bytes written per DELETE event). Do **not** flip to CoW for streaming CDC tables with thousands of small row-level DELETEs per minute — that workload generates a flood of full-file rewrites and crushes the streaming consumer's throughput.

#### Diagnosing position-delete-file accumulation (the bulk-DELETE-after-Debezium slowdown)

**The symptom.** A Trino query against an Iceberg table that used to return in 2 seconds now takes 30+ seconds. The slowdown started suddenly — usually after a bulk `DELETE FROM postgres_table WHERE ...` ran upstream, which Debezium turned into one `op='d'` per affected row, which your Spark Structured Streaming consumer applied as one row-level DELETE per event against the MoR Iceberg table. Each Iceberg DELETE wrote a **position delete file**; tens or hundreds of thousands of small delete files now have to be read and merged with the data files for every query.

**The diagnostic.** Iceberg's `$files` metadata table exposes one row per file currently referenced by the live snapshot, including delete files. The column that distinguishes data files from delete files is **`content`** — an integer enum with the following values:

- `0` = `DATA` (regular Parquet data file)
- `1` = `POSITION_DELETES` (position delete file — `(file_path, row_position)` pairs marking rows to skip at read time)
- `2` = `EQUALITY_DELETES` (equality delete file — column-value tuples like `event_id = 123` marking rows to skip at read time)

> **Common AI-generated SQL bug — `WHERE file_type = 'POSITION_DELETE'` does NOT work.** The `$files` metadata table on Trino's Iceberg connector does **not** have a `file_type` column, and the value is not the string `'POSITION_DELETE'`. The correct column name is `content` and the value is the integer `1`. Copy-pasting `WHERE file_type = 'POSITION_DELETE'` returns `Column 'file_type' cannot be resolved` in Trino 467 and breaks immediately. Always use `WHERE content = 1` for position deletes (or `content = 2` for equality deletes).

Run this in Trino as the diagnostic query when you suspect delete-file accumulation:

```sql
-- Count position-delete files per partition for the affected table.
-- Replace 'analytics.events' with your table name.
SELECT
    partition,
    COUNT(*) AS position_delete_file_count,
    SUM(record_count) AS total_deleted_row_markers,
    SUM(file_size_in_bytes) AS total_delete_bytes
FROM iceberg.analytics."events$files"
WHERE content = 1                                       -- 0=DATA, 1=POSITION_DELETES, 2=EQUALITY_DELETES
GROUP BY partition
ORDER BY position_delete_file_count DESC
LIMIT 20;

-- Quick total across all partitions:
SELECT COUNT(*) AS position_delete_file_count
FROM iceberg.analytics."events$files"
WHERE content = 1;
```

**Reading the result.** If `position_delete_file_count` is in the low hundreds across the whole table, that is normal MoR steady-state — query overhead is small. If it is in the tens of thousands (or millions, after a large bulk-DELETE through CDC), the table is in pathological MoR territory and queries will be slow until you compact. The number-of-delete-files-per-partition column is also useful: a single hot partition with 50,000 position delete files often signals one runaway DELETE batch that hit only that partition.

**The fix — compaction recipe for bulk-delete accumulation (Spark).** Two procedures matter; pick based on whether your delete-file flood is hurting reads enough to justify rewriting the data files too:

**Option A — `rewrite_data_files` with `delete-file-threshold` (folds deletes back into data files).** The right tool when delete-file accumulation has reached the point where you want to physically apply the deletes and produce new clean data files. By default, `rewrite_data_files` looks at **data-file size** for compaction candidates; it does **not** trigger a rewrite based solely on accumulated delete files. The `delete-file-threshold` option fixes this — it tells the procedure "if a data file has at least N delete files referencing it, rewrite it even if its size is already fine."

```sql
-- Spark SQL. Compacts data files that have 1+ associated delete files, applies
-- the deletes in memory, and writes new clean Parquet data files. After this
-- commits, the position delete files are no longer referenced (they will be
-- cleaned up by the next expire_snapshots / remove_orphan_files run).
CALL iceberg.system.rewrite_data_files(
    table   => 'analytics.events',
    where   => 'occurred_at >= DATE ''2026-05-01''',   -- scope to affected partitions
    options => map(
        'delete-file-threshold', '1',                  -- any data file with 1+ delete files is a rewrite candidate
        'target-file-size-bytes', '268435456'          -- 256 MB target
    )
);
```

**Without `delete-file-threshold` in the options map, the procedure may run as a no-op** for tables whose data files are already well-sized — it sees correctly-sized data files and concludes there is nothing to compact, even though hundreds of position delete files are sitting alongside them dragging down read performance. Always pass `delete-file-threshold => '1'` when the goal is delete-file cleanup, not small-file consolidation. Setting it higher (e.g., `'5'`) compacts only the worst-affected data files and leaves lightly-touched ones alone — useful when you want to amortize the rewrite cost over multiple maintenance windows.

**Option B — `rewrite_position_delete_files` (compacts ONLY position-delete files, no data-file rewrite).** A more targeted alternative when the **data files themselves are fine** but you have many small position delete files that need consolidating. This procedure merges multiple small position delete files into fewer, larger ones — without touching the underlying data files at all. Cheaper (no data-file I/O) and faster (only delete-file I/O), but does NOT physically remove the deleted rows from the data files — they remain marked-as-deleted via the consolidated delete files. The query-time merge cost goes down (fewer delete files to open per read), but the read still does a merge.

```sql
-- Spark SQL. Compacts only position delete files; data files untouched.
-- Use when delete files are many-and-small but data files are well-sized.
-- In Iceberg 1.5.2 the only required argument is `table =>`. The procedure
-- internally selects which delete files to compact based on its own heuristics.
CALL iceberg.system.rewrite_position_delete_files(
    table => 'analytics.events'
);
```

> **CRITICAL — `rewrite_position_delete_files` does NOT accept `delete-file-threshold`.** A common AI-generated mistake is to copy the `options => map('delete-file-threshold', '1', ...)` map from `rewrite_data_files` into a `rewrite_position_delete_files` call. **This is wrong.** `delete-file-threshold` is an option of `RewriteDataFiles` only — it controls when `rewrite_data_files` decides a data file is worth rewriting based on how many delete files reference it. `rewrite_position_delete_files` operates on the delete files themselves (not data files), so the option has no meaning there. Per the Iceberg 1.5.2 `RewritePositionDeleteFiles` Javadoc, the procedure's only documented options are `PARTIAL_PROGRESS_ENABLED`, `PARTIAL_PROGRESS_MAX_COMMITS`, `MAX_CONCURRENT_FILE_GROUP_REWRITES`, and `REWRITE_JOB_ORDER` — none of which are needed for the common compaction case. Passing `delete-file-threshold` to this procedure will either be silently ignored or rejected at runtime. **The correct invocation for the everyday delete-file compaction case is `CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.events')` — just `table =>`, nothing else.**
>
> The correct two forms for delete-file compaction in Iceberg 1.5.2:
>
> ```python
> # Form A: targeted position delete file compaction (NO options).
> # Use when data files are already well-sized (>=128MB avg) but you have
> # tens of thousands of position delete files dragging read latency.
> spark.sql("""
>     CALL iceberg.system.rewrite_position_delete_files(
>         table => 'analytics.events'
>     )
> """)
>
> # Form B: full data file rewrite that ALSO applies pending delete files.
> # This is where `delete-file-threshold` belongs — it is a RewriteDataFiles
> # option, not a RewritePositionDeleteFiles option.
> spark.sql("""
>     CALL iceberg.system.rewrite_data_files(
>         table   => 'analytics.events',
>         options => map(
>             'delete-file-threshold',  '1',
>             'target-file-size-bytes', '268435456'
>         )
>     )
> """)
> ```

**Compaction procedure selection — decision table.** Pick the procedure based on what kind of file pathology you have, not by reflex:

| Situation | Use this | Notes |
|---|---|---|
| 40k+ position delete files, data files are well-sized (≥128MB avg) | `rewrite_position_delete_files` (Spark) | Fastest; targets only delete files; no data file rewrite. Just `table =>`, no options needed. |
| Both position delete files AND small/fragmented data files | `rewrite_data_files` with `options => map('delete-file-threshold', '1')` (Spark) | Heavier; fixes both problems in one pass. The `delete-file-threshold` option ensures even well-sized data files get rewritten if they have associated delete files. |
| Small data files only, no delete file accumulation | Trino `ALTER TABLE ... EXECUTE optimize` or Spark `rewrite_data_files` without `delete-file-threshold` | Does NOT help if delete files are the problem. Pure small-file consolidation only. |
| Quick ad-hoc fix from a Trino session for small-file fragmentation | Trino `ALTER TABLE ... EXECUTE optimize(file_size_threshold => '128MB')` | Only for small-file consolidation, not delete files. Cannot clear accumulated delete files from a CDC pipeline. |

**Operational pattern.** For high-mutation CDC tables, schedule both procedures on a recurring cadence (every 4-6 hours during business hours, hourly during incident windows): run `rewrite_position_delete_files` first as the cheap maintenance loop (just `table =>`, no options), and `rewrite_data_files` weekly with `options => map('delete-file-threshold', '1')` to physically apply accumulated deletes. Always follow with `expire_snapshots` so the old delete files actually leave MinIO. See resource 17 for the full Iceberg maintenance schedule.

> **Trino `ALTER TABLE ... EXECUTE optimize` does NOT apply pending position delete files.** Trino 467's `EXECUTE optimize` rewrites data files to the target file size under the current partition spec. **It does NOT apply pending position delete files** — small data files get re-bin-packed, but the position delete files sitting alongside them are not consumed and are not consolidated. For delete file accumulation from a Debezium CDC pipeline (the scenario in this section — 40k+ delete files after a bulk DELETE), use Spark `rewrite_position_delete_files` (targeted, fast, just `table =>`) or Spark `rewrite_data_files` with `options => map('delete-file-threshold', '1')` (full, rewrites data files AND consumes the deletes). Trino `EXECUTE optimize` is appropriate for **small-file consolidation after bulk appends** (e.g., the post-catch-up compaction recipe earlier in this section), not for clearing accumulated delete files from a CDC pipeline. This is the same limitation called out in resource 05's GDPR runbook (Trino issue trinodb/trino #25279): Trino's OPTIMIZE cannot apply MoR position-delete files at all. Production maintenance jobs that target delete-file accumulation MUST use Spark.

#### Merging multiple source databases into one Iceberg table

A common multi-region SaaS pattern: you run **separate Postgres databases per region** (e.g., `postgres-us`, `postgres-eu`, `postgres-apac`) for latency and data-residency reasons, but you want a **single unified `iceberg.analytics.events` table** that analysts can query across all regions. Debezium + Spark Structured Streaming + Iceberg supports this pattern well, but there is one specific failure mode you must design around from day one: the **primary-key collision problem**.

##### The PK collision problem

Each Postgres database has its own auto-incrementing `events.id` sequence. The first event in `postgres-us` has `id = 1`. The first event in `postgres-eu` also has `id = 1`. They are **different events** in different databases, but they have **identical primary keys**.

If you MERGE both CDC streams into a single Iceberg table using `ON t.id = s.id`, the second insert wins — the `postgres-eu` row with `id = 1` overwrites the `postgres-us` row with `id = 1`. Your "unified" table silently loses half the events from one region, with no error raised.

This is the canonical multi-source CDC bug. The solution is a **composite primary key**: stamp every row with its source region and use the pair `(id, source_region)` as the merge key.

##### Table design — add a `source_region` column

When you create the unified Iceberg table, add a `source_region` column (or `source_db` — pick a name that fits your naming convention) and partition by it alongside the time partition:

```sql
-- Trino DDL. The source_region column is mandatory for any multi-source CDC table.
CREATE TABLE iceberg.analytics.events (
    id              BIGINT,
    source_region   VARCHAR,             -- 'us', 'eu', 'apac' — never NULL
    tenant_id       VARCHAR,
    occurred_at     TIMESTAMP(6),
    event_type      VARCHAR,
    payload         VARCHAR,
    source_lsn      BIGINT,              -- Debezium WAL position; see "idempotency guard" below
    ingested_at     TIMESTAMP(6)
)
WITH (
    partitioning = ARRAY['day(occurred_at)', 'source_region'],
    format = 'PARQUET'
);
```

Partitioning by `source_region` is a free win — most cross-region queries either filter to one region (per-region dashboards) or aggregate across all regions (cross-region rollups). The `source_region` partition lets the per-region queries prune the other regions' files entirely.

##### Debezium configuration — one connector per source, with distinct `topic.prefix`

Run one Debezium PostgresConnector per source database. The critical config field is **`topic.prefix`** — it determines the Kafka topic name (`{prefix}.{schema}.{table}`) and must be **unique per source**. The convention is to use the source region as the prefix so the region is parseable from the topic name later.

```json
// Connector for postgres-us (US region)
{
  "name": "postgres-us-events",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgres-us.internal",
    "database.dbname": "app",
    "topic.prefix": "us",
    "slot.name": "debezium_slot_us",
    "publication.name": "debezium_pub",
    "table.include.list": "public.events"
  }
}

// Connector for postgres-eu (EU region) — SAME schema, DIFFERENT topic.prefix
{
  "name": "postgres-eu-events",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "postgres-eu.internal",
    "database.dbname": "app",
    "topic.prefix": "eu",
    "slot.name": "debezium_slot_eu",
    "publication.name": "debezium_pub",
    "table.include.list": "public.events"
  }
}
```

After both connectors are running, Kafka has two topics:
- `us.public.events` — every row change from postgres-us.
- `eu.public.events` — every row change from postgres-eu.

##### Spark Structured Streaming — subscribe to both topics, parse region from topic name

A single Spark Structured Streaming job consumes both topics with a comma-separated `subscribe` value. The Kafka source exposes a built-in `topic` column on every micro-batch row — split it on `.` to recover the source region.

> **Critical — Debezium temporal encoding depends on `time.precision.mode`.** Before you write the Spark `StructType` schema for the Debezium envelope, check the Debezium connector's `time.precision.mode` setting. The encoding of `TIMESTAMP` / `TIMESTAMPTZ` columns in the Kafka message changes depending on this mode, and getting the Spark `StructField` type wrong silently produces NULLs or wrong values on every event.
>
> | `time.precision.mode` | Encoding for `TIMESTAMP WITH TIME ZONE` (Postgres `TIMESTAMPTZ`) | Encoding for `TIMESTAMP WITHOUT TIME ZONE` | Spark `StructField` type for the raw Kafka field |
> |---|---|---|---|
> | `adaptive_time_microseconds` (Debezium default) | Epoch **microseconds** since 1970-01-01 UTC, encoded as `int64` (the `io.debezium.time.MicroTimestamp` / `io.debezium.time.ZonedTimestamp` semantic types — `ZonedTimestamp` is actually an ISO-8601 string for `TIMESTAMPTZ`, while `MicroTimestamp` is `int64` microseconds for `TIMESTAMP`) | Epoch microseconds (`int64`) | `LongType()` for `MicroTimestamp` (then cast to `TimestampType` dividing by 1e6); `StringType()` for `ZonedTimestamp` (then parse with `to_timestamp`) |
> | `connect` | Epoch **milliseconds** (Kafka Connect's `org.apache.kafka.connect.data.Timestamp` logical type) | Epoch milliseconds (`int64`) | `LongType()` (then cast to `TimestampType` dividing by 1e3); arrives directly as a Connect Timestamp logical type in Avro mode |
> | `adaptive` (legacy, deprecated) | Mix of resolutions depending on the Postgres declared precision — millis for `TIMESTAMP(0..3)`, micros for `TIMESTAMP(4..6)`, nanos for `TIME(...)` | Same | Variable — **avoid this mode**, the heterogeneity makes a single Spark schema impossible to write correctly. Migrate to `adaptive_time_microseconds` or `connect`. |
>
> **Don't hardcode the assumption that timestamps are always microseconds** — that's only true under the (very common) default. If your team flipped the connector to `connect` mode for Kafka Connect compatibility, every `LongType` field would need to be divided by 1000 instead of 1,000,000 when cast to `TimestampType`. Check the connector config (`kubectl get kafkaconnector <name> -o yaml | grep time.precision`) before writing the Spark schema, and document the mode in a comment alongside the `StructType` definition so the next engineer doesn't have to re-derive it. **The default is `adaptive_time_microseconds`** ([Debezium PostgreSQL connector — temporal types](https://debezium.io/documentation/reference/stable/connectors/postgresql.html#postgresql-temporal-types)) — the recipe below assumes the default; adjust the unit conversions if your connector is set to `connect` or the legacy `adaptive` mode.

```python
from pyspark.sql.functions import col, split, from_json, lit
from pyspark.sql.types import StructType, StructField, StringType, LongType, TimestampType

# Subscribe to BOTH region topics with a single comma-separated string.
# Spark Structured Streaming will fan out to both topics and union the events.
events_stream = (
    spark.readStream
         .format("kafka")
         .option("kafka.bootstrap.servers", KAFKA_BOOTSTRAP)
         .option("subscribe", "us.public.events,eu.public.events")
         .option("startingOffsets", "latest")
         .load()
)

# `topic` is a built-in column on the Kafka source. For 'us.public.events' it returns
# the string 'us.public.events' — split on '.' and take element [0] to get 'us'.
# This is how we recover source_region from the Kafka stream itself, without trusting
# any field inside the Debezium payload.
events_with_region = (
    events_stream
        .withColumn("source_region", split(col("topic"), "\\.").getItem(0))
        # ... then parse the Debezium JSON value as usual ...
        .withColumn("debezium_event", from_json(col("value").cast("string"), debezium_envelope_schema))
        .select(
            col("debezium_event.after.id").alias("id"),
            col("source_region"),
            col("debezium_event.after.tenant_id").alias("tenant_id"),
            col("debezium_event.after.occurred_at").alias("occurred_at"),
            col("debezium_event.after.event_type").alias("event_type"),
            col("debezium_event.after.payload").alias("payload"),
            col("debezium_event.source.lsn").alias("source_lsn"),       # per-source WAL position
            col("debezium_event.op").alias("op"),
        )
)
```

##### MERGE INTO with composite key + LSN idempotency guard

The merge into Iceberg uses the **composite key** `(t.id = s.id AND t.source_region = s.source_region)`. The `source_region` join condition is what prevents the `id=1` collision. Additionally, gate the `WHEN MATCHED` UPDATE on `s.source_lsn > t.source_lsn` — this is the idempotency guard that prevents an out-of-order retry (Kafka redelivery, micro-batch replay after a restart) from clobbering newer state with older state.

```python
def write_micro_batch(batch_df, batch_id):
    batch_df.createOrReplaceTempView("events_cdc_delta")
    spark.sql("""
        MERGE INTO iceberg.analytics.events t
        USING events_cdc_delta s
        ON t.id = s.id
           AND t.source_region = s.source_region              -- COMPOSITE KEY: critical
        WHEN MATCHED AND s.op = 'd' THEN DELETE
        WHEN MATCHED AND s.source_lsn > t.source_lsn THEN     -- IDEMPOTENCY GUARD
            UPDATE SET *
        WHEN NOT MATCHED AND s.op != 'd' THEN
            INSERT *
    """)

(events_with_region.writeStream
    .foreachBatch(write_micro_batch)
    .option("checkpointLocation", "s3a://lakehouse/checkpoints/events_cdc/")
    .trigger(processingTime="60 seconds")
    .start()
)
```

> **Trigger interval — Iceberg recommends a minimum 60-second trigger for streaming writes.** This is a **recommendation, not a hard requirement** — Iceberg 1.5.2 will accept any `processingTime` value Spark passes it, including sub-second triggers. But sub-minute triggers create many small Parquet files without proportional throughput benefit and significantly increase compaction overhead: a 10-second trigger produces 6x more data files per partition than a 60-second trigger for the same row volume, and `rewrite_data_files` then has to do 6x more work to merge them back to ~128 MB chunks. The 60-second baseline is what the Iceberg streaming-writes guidance documents, and it is the right starting point for a CDC pipeline. Tune lower (e.g., 30 seconds) only if your product surface has a documented sub-minute freshness SLA and you've sized the compaction job to keep up; tune higher (e.g., 2-5 minutes) if minute-level freshness is acceptable — every doubling of the trigger interval roughly halves your small-file rate.

**Why both conditions matter:**

| Condition | What it protects against |
|---|---|
| `t.id = s.id AND t.source_region = s.source_region` | PK collision across sources. Without the `source_region` match, postgres-eu's `id=1` would overwrite postgres-us's `id=1`. |
| `WHEN MATCHED AND s.source_lsn > t.source_lsn THEN UPDATE` | Out-of-order delivery within a single source. If Kafka redelivers an older change event after a newer one has already been applied (rebalance, restart, micro-batch replay), this guard ensures the older event is skipped — the Iceberg row stays at the newer state. Without this guard, retries silently corrupt the latest state. |

##### Critical caveat — LSN is per-source, not globally comparable

`source.lsn` (Postgres WAL position) is **monotonically increasing within a single replication slot** — within `postgres-us`, every newer event has a strictly greater `lsn` than every older event. **That is the only ordering guarantee.** Across sources, LSN values are not comparable:

- `postgres-us` and `postgres-eu` are independent Postgres clusters with independent WAL histories. Their LSN spaces are unrelated.
- The fact that `postgres-eu` emits `lsn = 12345` while `postgres-us` emits `lsn = 67890` tells you **nothing** about which event happened first in wall-clock time.
- The `s.source_lsn > t.source_lsn` guard in the MERGE INTO above is **correct because the composite key `(id, source_region)` already isolates the comparison to within a single source.** Two rows that match on `(id, source_region)` are necessarily from the same Postgres database, so their LSNs come from the same WAL and ARE comparable.

**Do NOT** add a query-level filter like `WHERE source_lsn > X` across all regions — it would silently mix US and EU events that happened to have similar LSN numbers. For cross-source ordering, use `occurred_at` (a real timestamp) or `ingested_at` (the timestamp the Spark consumer wrote the row), never LSN.

##### Data residency and GDPR — which direction triggers transfer rules

A unified cross-region Iceberg table physically lives on **one** MinIO cluster, which lives in **one** location. That location determines whether you have triggered a cross-border data transfer that GDPR (or any other regional data-protection regime) governs.

> **GDPR Chapter V applies to *EU personal data exported to a non-EU location*, not the other way around.** Specifically:
>
> - **Ingesting EU-sourced CDC into a US-located MinIO cluster IS the controlled transfer.** You are moving EU personal data outside the EU; under GDPR Chapter V you need a lawful transfer basis — Standard Contractual Clauses (SCCs), an adequacy decision (e.g., the EU-US Data Privacy Framework), or another approved mechanism. This is not optional and is enforceable by EU supervisory authorities.
> - **Ingesting US-sourced CDC into an EU-located MinIO cluster is generally NOT restricted by GDPR.** GDPR doesn't restrict importing data into the EU — only exporting EU personal data out of it. (Local US-side regulations like state privacy laws may still apply on the source side, but those are separate from GDPR Chapter V.)
> - **Same-region ingest** (EU-sourced CDC into an EU-located MinIO cluster, US-sourced into US-located) does not trigger cross-border transfer rules at all. This is the simplest legal posture and the reason many SaaS deployments run one MinIO cluster per region rather than a single unified cluster.

**Practical implication for the unified-table design above.** If your unified Iceberg cluster is in the US and you want to ingest EU CDC into it, you need a documented transfer basis on file BEFORE the EU connector starts streaming. The Debezium connector's `topic.prefix = "eu"` is the operational marker that EU rows are landing on US storage — your compliance team should be aware of it. Alternatively, run two MinIO clusters (one per region) with parallel Iceberg tables, then federate at query time via Trino's multi-catalog connector. The federation approach keeps each region's data physically resident in its own jurisdiction at the cost of slower cross-region joins.

---

## The JSONB problem

Your Postgres `events` table almost certainly has a `properties JSONB` column. **Parquet does define a JSON logical type annotation (binary annotated as JSON, UTF-8 encoded), but it stores JSON as an opaque binary/string — there is no per-field columnar storage or statistics for nested JSON keys. Trino's Iceberg connector reads JSON-annotated columns as plain strings at query time.** You must decide at ingest time how to handle it.

### Option 1: store as VARCHAR

Write the whole JSON blob as a string. Query with Trino's `json_extract_scalar`:

```sql
SELECT json_extract_scalar(properties, '$.device_type'), COUNT(*)
FROM iceberg.analytics.events
GROUP BY 1;
```

`JSON_VALUE(col, '$.key' RETURNING varchar NULL ON EMPTY NULL ON ERROR)` is the **SQL/JSON standard** form (Trino 467 supports it) with explicit NULL handling — useful when you want strict error control. Unlike `json_extract_scalar` (which silently returns NULL for both missing keys and malformed JSON, conflating the two), `JSON_VALUE` lets you spell out exactly what should happen on a missing key vs. a parse error:

```sql
-- Explicit NULL on missing key AND on parse error — same end behavior as
-- json_extract_scalar, but the intent is in the SQL itself.
SELECT JSON_VALUE(properties, '$.device_type' RETURNING varchar NULL ON EMPTY NULL ON ERROR) AS device_type
FROM iceberg.analytics.events;

-- Raise on a malformed JSON value instead of silently returning NULL — surfaces
-- corruption you would otherwise miss with json_extract_scalar.
SELECT JSON_VALUE(properties, '$.device_type' RETURNING varchar NULL ON EMPTY ERROR ON ERROR) AS device_type
FROM iceberg.analytics.events;
```

Prefer `JSON_VALUE` when you care about distinguishing "key absent" from "JSON corrupt"; stick with `json_extract_scalar` for ad-hoc, error-tolerant lookups.

> **Gotcha — `json_extract_scalar` always returns VARCHAR.** Comparisons against numbers or booleans need an explicit `CAST` — e.g., `CAST(json_extract_scalar(properties, '$.price') AS DECIMAL) > 100` or `CAST(json_extract_scalar(properties, '$.is_premium') AS BOOLEAN) = true`. Without the cast, the comparison is a string comparison: `'100' > '99'` evaluates to **false** (lexicographic ordering), and `'true' = true` is a type-mismatch error. `JSON_VALUE` accepts a `RETURNING` clause for the same purpose — `JSON_VALUE(properties, '$.price' RETURNING DECIMAL)` typecasts in one step.

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

> **Shortcut for stable-schema JSONB: `schema_of_json` + `from_json` for full struct promotion in one pass.** When the JSON schema is **known and stable** (you control the producer, the key set rarely changes, every row has the same shape), you do NOT have to extract keys one-by-one with `get_json_object`. Spark's `from_json` parses the entire JSON blob into a typed `STRUCT` in a single call, and `schema_of_json` derives the schema automatically from a sample row. The result is a typed struct column you can address with normal dot notation (`properties.device_type`, `properties.plan_at_event`) — and Iceberg stores it as a nested struct with full columnar storage and per-sub-field statistics.
>
> ```python
> from pyspark.sql.functions import schema_of_json, from_json, lit
>
> # Step 1: derive the schema from a representative sample of the JSON.
> # In practice, pick a known-good row from production or hand-write a sample
> # that covers every expected key. schema_of_json infers types from the values.
> sample_json = '{"device_type": "ios", "plan_at_event": "pro", "feature_name": "search", "tags": ["beta", "v2"], "metadata": {"region": "us-east"}}'
> json_schema = spark.sql(f"SELECT schema_of_json('{sample_json}')").collect()[0][0]
> # json_schema is now a DDL-style schema string like:
> # 'STRUCT<device_type:STRING, plan_at_event:STRING, feature_name:STRING,
> #         tags:ARRAY<STRING>, metadata:STRUCT<region:STRING>>'
>
> # Step 2: parse the entire JSON blob into a typed struct column in one call.
> df = df.withColumn("properties_struct", from_json("properties", json_schema)) \
>        .withColumnRenamed("properties", "properties_raw")
>
> # Step 3 (optional): hoist sub-fields to top level if you want flat columns.
> df = df.withColumn("device_type",   df["properties_struct.device_type"]) \
>        .withColumn("plan_at_event", df["properties_struct.plan_at_event"])
> ```
>
> **When this is the right tool:**
> - You control the JSON producer (your own app emitting events you control) — so the schema doesn't drift behind your back.
> - The key set is fully enumerated and stable across releases.
> - You want all the fields promoted, not just a curated hot subset.
>
> **When to stick with per-key `get_json_object`:**
> - The JSON shape is unstable (different rows have different keys, or producers add keys without coordination).
> - You only want to promote 5–10 hot keys out of dozens — keeping the long tail in `properties_raw` is cheaper than nesting it into a struct that mostly stays unused.
> - Producers occasionally emit malformed JSON — `from_json` returns NULL for the entire row's struct on a parse error (you lose every promoted key for that row), while `get_json_object` fails only the specific key and the rest still extract. Per-key extraction degrades more gracefully under partial corruption.
>
> **Important caveat: `schema_of_json` only sees the sample you give it.** Keys not present in the sample are NOT in the inferred schema, and any row that contains those extra keys has them silently dropped when `from_json` parses against the schema. Always either (a) generate the sample from a query like `SELECT properties FROM events ORDER BY id DESC LIMIT 1000` and union the field sets, or (b) hand-write a schema string that explicitly covers every key you expect — do not rely on a single random row producing a complete schema. For production, pin the schema in code (don't re-derive every job run) so a producer-side change that adds a key fails CI rather than silently dropping data.

> **COALESCE fallback pattern — querying during a partial backfill.** When you promote a JSONB key into a typed column (`device_type VARCHAR`), historical rows have `NULL` in the new column until the MERGE INTO backfill runs. The backfill takes hours to days on a multi-billion-row table; during that window, queries against the new column return NULL for old rows and the real value for new rows — half-right answers that are worse than either extreme. **The transitional query pattern is COALESCE**: read the typed column first, fall back to extracting from `properties_raw` for any row where the typed column is still NULL.
>
> ```sql
> -- Transitional query: uses the promoted column when available, falls back
> -- to JSON extraction for rows that haven't been backfilled yet.
> SELECT
>   COALESCE(device_type, JSON_EXTRACT_SCALAR(properties_raw, '$.device_type')) AS device_type,
>   COUNT(*) AS event_count
> FROM iceberg.analytics.events
> WHERE event_ts >= DATE '2026-05-01'
> GROUP BY 1;
> ```
>
> Three things to know about this pattern:
>
> 1. **It is strictly a TRANSITIONAL query** — keep it in your dashboard / dbt model only until the backfill is complete and verified. Once `still_null` (the verification query from the backfill recipe) returns zero, switch back to reading `device_type` directly. The fallback path is slower (no file skipping on the JSON extract — see the "FILE SKIPPING" callout above), so leaving it in production permanently is a forever-on tax on every query.
> 2. **It loses the file-skipping benefit on rows that fall through to the COALESCE second arm.** Trino can still prune row-groups based on `device_type`'s min/max for the promoted-side fast path, but rows where the typed column is NULL fall through to the JSON extract, which forces a row-by-row evaluation. During the backfill window, query latency is somewhere between "fully promoted" and "fully raw JSON" — closer to the promoted side as the backfill catches up.
> 3. **It is also useful for "new column, no backfill" scenarios.** Sometimes the right call is to add a column going forward and **not** backfill the history (storage cost, compute cost, or the historical data simply doesn't matter for the downstream use case). In that case, COALESCE is the permanent query shape — but be explicit about the decision in your ADR / dbt model docs so the next engineer doesn't strip the fallback thinking "oh, this should be cleaned up."
>
> The same COALESCE pattern works in dbt-trino models (using `JSON_EXTRACT_SCALAR`, not `get_json_object` — see the dbt section later in this file) and in any consumer that needs to be correct across the partial-backfill window. Wrap it in a CTE if multiple columns need the fallback:
>
> ```sql
> WITH promoted AS (
>   SELECT
>     event_id,
>     event_ts,
>     COALESCE(device_type,   JSON_EXTRACT_SCALAR(properties_raw, '$.device_type'))   AS device_type,
>     COALESCE(plan_at_event, JSON_EXTRACT_SCALAR(properties_raw, '$.plan_at_event')) AS plan_at_event,
>     COALESCE(feature_name,  JSON_EXTRACT_SCALAR(properties_raw, '$.feature_name'))  AS feature_name
>   FROM iceberg.analytics.events
>   WHERE event_ts >= DATE '2026-05-01'
> )
> SELECT device_type, plan_at_event, COUNT(*) FROM promoted GROUP BY 1, 2;
> ```

> **The dominant reason to flatten hot keys is FILE SKIPPING, not CPU savings.** A predicate like `WHERE json_extract_scalar(properties_raw, '$.plan_tier') = 'enterprise'` does **NOT push down** to Parquet row-group statistics — Trino cannot see inside the opaque JSON string at planning time, so it reads **every file** in the table (or every file in the matched partitions) and evaluates the `json_extract_scalar(...)` function row-by-row after reading. The CPU cost of re-parsing the JSON is real but secondary; the dominant cost is the I/O of reading files that don't contain a single matching row.
>
> Flattening the field into a real column (`plan_tier VARCHAR`) enables Trino's Parquet reader to use **min/max row-group statistics and dictionary filtering** — the planner sees `plan_tier = 'enterprise'`, compares against each row-group's recorded min/max (e.g., a row-group whose `plan_tier` min/max is `'free'..'free'` is pruned instantly), and only reads the row-groups that could possibly contain matching rows. For a low-cardinality field like `plan_tier` with strong dictionary compression, this typically converts a **full table scan into a pruned scan that reads 1–5% of the original bytes**.
>
> Practical impact: a dashboard query that takes 45 seconds against the raw-JSON column (full scan) typically drops to 1–3 seconds against the flattened column (pruned scan). The flattening cost is paid once at ingest; the file-skipping benefit applies to every query forever.

**Working with nested arrays:** Use `get_json_object(col, "$.tags[0]")` to extract by index. For checking array membership, `get_json_object(...).contains("enterprise")` is a substring match on the JSON string — it would incorrectly match "enterprise-plus". For exact array containment, use `array_contains` after parsing with `from_json`:

```python
from pyspark.sql.functions import from_json, array_contains
from pyspark.sql.types import ArrayType, StringType

tags_schema = ArrayType(StringType())
df = df.withColumn("tags_array", from_json(get_json_object("properties", "$.tags"), tags_schema)) \
       .withColumn("has_enterprise_tag", array_contains(col("tags_array"), "enterprise"))
```

For simple low-cardinality cases (e.g., extract the first tag), extract by index: `get_json_object("properties", "$.tags[0]")`.

### What happens when a new JSONB key is added in Postgres

A common, reasonable question: "If the app starts writing a new key like `properties->>'ab_variant'` into the JSONB column, does anything in my ingestion pipeline break?" The answer depends on which layer you're asking about — and conflating these two is the foundation of a lot of incident debugging that goes the wrong way.

| Layer | Does it break when a new JSONB key appears? | Why |
|---|---|---|
| **Pipeline level (Debezium + Iceberg + Spark)** | **No — the pipeline does not break.** | Iceberg stores the full JSON blob as a `VARCHAR` (the schema-on-read model from Option 2). A new key inside that blob is just more characters in the string; the Iceberg schema has no opinion on the JSON's internal shape. Spark, Debezium, and Iceberg all see exactly one column (`properties_raw VARCHAR`) and that column's type is unchanged. New rows land silently, ingestion runs green, nothing alerts. |
| **Downstream consumer level (Trino queries, dbt models, dashboards)** | **Possibly — depends on what the consumer assumed.** | A Trino query that calls `json_extract_scalar(properties_raw, '$.ab_variant')` against a key that didn't exist before will simply return NULL on the historical rows and the real value on new rows — that's fine. The break case is when an existing key changes **shape or type**: `$.tags` used to be a string like `"enterprise"` and now arrives as an array `["enterprise", "beta"]`, or `$.score` was an integer and now arrives as a quoted string `"42"`. The downstream `json_extract_scalar(..., '$.tags')` returns the literal text representation of whatever's there now — `'["enterprise","beta"]'` instead of `'enterprise'` — and any `GROUP BY` or `WHERE` clause that assumed the old shape produces unexpected results. No exception fires; numbers just go subtly wrong. |

**"Nothing breaks" applies to the pipeline, not necessarily to consumers who assumed a fixed JSON structure.** When an analyst reports that a dashboard "started returning weird numbers last Tuesday," and your Spark job logs are all green, the most likely culprit is a JSONB shape change on the source side — not a pipeline failure. Mitigation: own the JSON contract end-to-end. Every key that downstream queries depend on should be (a) flattened into a typed column at ingest (where a type mismatch becomes a Spark cast error you can catch in CI), or (b) covered by a Trino test query that asserts the expected shape on the latest snapshot.

> **Decision table — when STRUCT, MAP, or flatten+VARCHAR is the right shape.** The choice between Iceberg `STRUCT`, `MAP<VARCHAR,VARCHAR>`, and the recommended flatten + raw VARCHAR pattern depends on how stable the JSON shape is and whether per-tenant key sets are heterogeneous. None of these is universally wrong — they fit different source-side shapes.
>
> | JSON shape on the source side | Recommended Iceberg shape | Why |
> |---|---|---|
> | **Stable, known field set** (every row has the same JSON keys; the set rarely changes) | `STRUCT<field1 TYPE, field2 TYPE, ...>` | Iceberg handles `STRUCT` schema evolution natively — add a new field with `ALTER TABLE ADD COLUMN parent.child TYPE` (metadata-only, no rewrite). Typed sub-fields preserve numeric/boolean types and get full columnar storage and per-field statistics. Best when you control both producer and consumer and the schema is genuinely stable. |
> | **Mostly-stable schema with hot query keys** (the typical SaaS event payload — a few keys are queried constantly, the long tail is occasional) | **Flatten hot keys into real columns + raw fallback `VARCHAR`** (Option 2 above — primary recommendation) | The hot keys get min/max statistics, dictionary compression, and partition-prunable predicates; the long tail stays available via `json_extract_scalar(properties_raw, ...)` without forcing a schema migration every time a new key appears. This is the default pattern for SaaS event tables. |
> | **Truly dynamic per-tenant settings** (every tenant has a different key set, e.g., custom-field configurations, white-label settings) | `MAP<VARCHAR,VARCHAR>` | When the key set is genuinely unbounded and per-tenant heterogeneous, `MAP` is the right model — it represents the dynamic structure without requiring an Iceberg DDL change every time a tenant adds a custom field. Accept the tradeoffs: per-key extraction is `element_at(map_col, 'key')` (no per-key stats), and nested values must be stringified. Use when the alternative (a wide STRUCT or a constantly-evolving flat schema) is operationally worse. |
>
> **Tradeoffs to know before picking STRUCT or MAP over flatten+VARCHAR:**
>
> - **`STRUCT`** preserves types and supports schema evolution via `ALTER TABLE ADD COLUMN parent.child TYPE`. The downside: every shape drift on the source side (a key renamed, a key dropped) requires a coordinated DDL + ingest-job change, and unexpected new keys arriving without DDL are dropped silently. Best when producer and consumer are operated by the same team and shape changes go through a review process.
> - **`MAP<VARCHAR,VARCHAR>`** absorbs any string-valued key but loses type information (a numeric `$.score` becomes the string `"42"`), cannot represent nested arrays or sub-objects without further encoding, and turns every per-key extraction into an `element_at(properties_map, 'device_type')` call — same query cost as `json_extract_scalar` against a VARCHAR. Per-key min/max statistics do not exist for MAP entries, so file skipping on a MAP lookup is limited.
> - **Flatten + raw VARCHAR** is the only pattern where the hot keys get per-column min/max statistics and dictionary filtering (the file-skipping property described in the callout above). For SaaS event tables with a clear hot-key set and an unbounded long tail, this is usually the right answer.

**No Debezium connector setting auto-expands JSONB into typed struct fields.** Engineers sometimes look for a `debezium.jsonb.expand-to-struct=true` or equivalent option — it does not exist. There is no Debezium PostgresConnector configuration that takes a JSONB column on the source side and emits one column-per-JSON-key on the Kafka message side. **This is by design**: JSONB has no schema, so typed expansion is not possible without user-defined transformation logic (which keys to extract, what types they should be, what to do when a key is missing or has the wrong type). Debezium emits the full JSONB value as a single `STRING` field in the change event payload; turning it into typed columns is the consumer's job — exactly the `get_json_object(...)` flattening pass shown in Option 2 above. The same applies on the Iceberg sink side: neither `debezium-server-iceberg` nor a custom Spark Structured Streaming consumer auto-expands the JSON blob; both write it as VARCHAR and leave key extraction to downstream queries or transformation jobs.

> **Debezium JSONB serialization details.** Debezium serializes Postgres `JSONB` columns via the **`io.debezium.data.Json`** semantic type — the change-event payload carries the JSON value as a UTF-8 string with a Kafka Connect schema marker `{ "type": "string", "name": "io.debezium.data.Json" }`. The consumer (a Spark Structured Streaming job reading from Kafka, or the `debezium-server-iceberg` sink) sees a plain JSON **string** in the `after`/`before` payload — no converter SMT (single message transform) is required to handle JSONB in the standard Spark consumer pattern. Just read the field as a `STRING` from the Kafka value and pass it to `get_json_object(...)` or write it through to Iceberg as VARCHAR.

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
- **Compute `upperBound` dynamically from a `SELECT MAX(id) FROM events` query at job start** — do NOT hardcode a value like `999_999_999` or `1_000_000_000`. A hardcoded value goes stale the day after you ship it: as the source table grows, the real `MAX(id)` keeps climbing, and your stride boundaries stop matching the data distribution. Every row past your hardcoded upper bound piles into the last partition; the rest of your strides get whatever the original (now-cold) distribution implied. The job still completes correctly — it just runs at single-executor speed for most of its wall clock.
- Getting it wrong means one partition is slower than the others — not missing data. Spark folds out-of-range rows into the first/last partition; rows are never dropped.
- For an incremental job that only reads new rows (via the `dbtable` subquery filter), compute `upperBound` from `MAX(id)` of the new-row window, not the max ID in the whole table.

**The right pattern: query MAX(id) into a Python variable first, then plug it in.** Spark gives you a clean two-line way to do this — `spark.sql(...).collect()[0][0]` pulls the value into Python where you can pass it as the `upperBound` option. Run this immediately before launching the parallel read, so the bound reflects the **current** table state:

```python
# Step A: pull the actual MAX(id) into Python at job start.
# For full-table reads, query the base table directly:
max_id = spark.sql(
    "SELECT MAX(id) FROM jdbc_pg.public.events"
).collect()[0][0]

# For incremental reads (only new rows), query the same window the dbtable will read:
# max_id = spark.sql(
#     f"SELECT MAX(id) FROM jdbc_pg.public.events WHERE updated_at > '{last_ts}'"
# ).collect()[0][0]

# Defensive: if the table (or window) is empty, MAX(id) is NULL. Bail or default.
if max_id is None:
    print("No rows to read; skipping JDBC parallel-read.")
    return
min_id = spark.sql(
    "SELECT MIN(id) FROM jdbc_pg.public.events"
).collect()[0][0] or 0

# Step B: pass the freshly-computed bound to the parallel JDBC read.
df = (spark.read.format("jdbc")
    .option("url", "jdbc:postgresql://pg-primary:5432/app")
    .option("dbtable", f"(SELECT * FROM events WHERE updated_at > '{last_ts}') t")
    .option("partitionColumn", "id")
    .option("lowerBound", min_id)
    .option("upperBound", max_id)
    .option("numPartitions", 16)
    .load())
```

> **Why `collect()[0][0]` and not just `.first()[0]`?** Either works. `collect()` returns a list of `Row` objects; `[0][0]` grabs the first column of the first (and only) row. `.first()[0]` is equivalent for single-row aggregates and slightly more idiomatic. Use whichever your team prefers — the key point is that you're materializing the value into a regular Python variable so it can be passed to `.option("upperBound", ...)`.

> **Why this matters more than it sounds.** A hardcoded `upperBound` is the single most common Spark JDBC performance bug on this stack. It doesn't surface as an error, doesn't show up in Spark UI as a misconfiguration, and doesn't trigger any alert. It just makes your job slow — and then slower every week, as the gap between the hardcoded value and the real `MAX(id)` widens. Six months in, the job that used to take 30 minutes is taking 4 hours, and nobody remembers why. Computing `MAX(id)` dynamically (one extra metadata round-trip to Postgres at job start, milliseconds in cost) eliminates this entire failure mode. Make it part of the template you copy when starting any new JDBC ingestion job.

> **What if querying `MAX(id)` is itself slow?** For tables with a B-tree index on `id` (which is the default for `bigserial` / `serial` primary keys), `SELECT MAX(id)` is an index-only lookup that completes in milliseconds even on 100M-row tables. If it's slow, you're almost certainly missing the index — fix the index, don't fall back to hardcoding. For pg_partman partitioned tables, run the `MAX(id)` against the specific child partition you're about to read (e.g., `SELECT MAX(id) FROM events_p2026_05`), not the parent — see the pg_partman section earlier in this resource for why the parent query plan is the wrong shape.

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
| **CDC** (Pattern C) | Depends on which sink you use — see the two deployment modes below. For a custom Spark Structured Streaming consumer, pause the consumer, run `ALTER TABLE ... ADD COLUMN` in Iceberg (metadata-only), then resume. For **debezium-server-iceberg** (the standalone sink), `debezium.sink.iceberg.allow-field-addition` **defaults to `true`** — the sink auto-ALTERs by default; you only need to act if you have explicitly set it to `false`. | Debezium detects the DDL via WAL relation messages (not schema registry), and only after the next DML on the table. The auto-ALTER property only applies to the debezium-server-iceberg sink — it does NOT exist as a Spark config. |

> **DEBEZIUM CDC — what happens automatically vs. what you must do manually.** This is the single most-asked question on the CDC schema-drift path; the full mechanics live in the Pattern C "Pause-ALTER-resume sequence" subsection (search for §5 in the CDC section), but the headline behavior:
>
> **What Debezium does automatically (no operator action required):**
> - **Detects the new Postgres column via the WAL.** When a `ALTER TABLE events ADD COLUMN referrer_source VARCHAR` runs in Postgres, the next DML on the `events` table produces a **WAL RELATION message** that includes the new column. Debezium reads RELATION messages and updates its in-memory schema via `schema.refresh.mode=columns_diff` (the default).
> - **Includes the new column in subsequent change events.** Every row-change event published to Kafka from that point forward includes `referrer_source` in the `after` payload (and in `before` if the column is included under `REPLICA IDENTITY FULL`).
> - You do **NOT** need to restart the Debezium connector. You do **NOT** need to update the Kafka Connect config. You do **NOT** need to update `table.include.list`. The schema drift is detected and propagated by the WAL itself.
>
> **What does NOT happen automatically (you MUST do this manually):**
> - **The downstream Iceberg table does NOT auto-evolve.** Debezium publishes the new column to Kafka, but your Spark Structured Streaming consumer's MERGE INTO will throw `AnalysisException: Cannot resolve column 'referrer_source'` on the very first event that carries the new field, because the Iceberg target table does not yet have a column of that name. The streaming batch fails, the offset does not commit, and the consumer re-attempts the same batch with the same error in a loop until you fix the schema.
>
> **The correct procedure for adding a new column to a CDC-fed Iceberg table:**
> 1. **Add the column to Iceberg FIRST** — before, during, or shortly after the Postgres DDL (order is not strict because the new column won't appear in any Kafka event until the next DML hits the row in Postgres):
>    ```sql
>    ALTER TABLE iceberg.analytics.events ADD COLUMNS (referrer_source VARCHAR);
>    ```
>    This is metadata-only and completes in milliseconds. All historical rows return NULL for the new column from the next read on. No data rewrite, no backfill.
> 2. **Let Debezium continue streaming.** The connector already includes the new column in change events from the moment Postgres started writing to the column — there is no resync, restart, or reconfigure required on the Debezium side.
> 3. **The Spark consumer's `MERGE INTO ... UPDATE SET *` / `INSERT *` (wildcard form)** will now correctly map the new column from the source DataFrame to the new column in the target table by name. The consumer continues processing without intervention.
> 4. **Verify new rows have non-NULL values for the new column** after some Postgres DML has flowed through the pipeline:
>    ```sql
>    SELECT referrer_source, COUNT(*)
>    FROM iceberg.analytics.events
>    WHERE ingested_at > CURRENT_TIMESTAMP - INTERVAL '1' HOUR
>    GROUP BY referrer_source
>    LIMIT 10;
>    ```
>    If `referrer_source` is NULL for every recent row, either (a) no Postgres DML has touched a row with a non-NULL value for the new column yet (common — backfill Postgres or wait), or (b) the consumer's MERGE statement uses an explicit column list that doesn't include the new column (the CDC equivalent of the pinned-JDBC-projection bug from Pattern B above; switch to `UPDATE SET *` / `INSERT *` to get name-based wildcard mapping).
>
> **Why the order doesn't matter strictly.** A common worry: "What if I run the Postgres ALTER first and Kafka events with the new column arrive before I've added it to Iceberg?" In practice this is fine — Debezium only sees the new column when a row gets INSERTed or UPDATEd after the DDL (because RELATION messages are bound to DML events, not DDL events). On a moderate-write table you have minutes of headroom before the first event with the new column hits the consumer. The streaming consumer will fail loudly on the first such event (no silent NULLs), giving you a clear signal to run the Iceberg ADD COLUMNS and resume. On a low-write table you might have hours of headroom.
>
> **`mergeSchema` does NOT help here.** As covered exhaustively in section 6 below, the `.option("mergeSchema", "true")` writer option is silently ignored by Spark `MERGE INTO` SQL (apache/iceberg#5556). For CDC consumers, manual `ALTER TABLE ADD COLUMNS` is the **only** correct path — there is no auto-evolution shortcut. The `debezium-server-iceberg` standalone sink has its own `debezium.sink.iceberg.allow-field-addition` property which DOES auto-ALTER, but that property only applies if you have replaced your custom Spark consumer with the standalone sink (a fundamentally different deployment).

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

That's it. Iceberg's schema evolution is **column-ID-based** (each column carries a unique numeric field ID assigned at creation; reads match data to schema columns by ID, not by name and not by position), so adding a column never breaks existing readers. Old Parquet files don't have a column chunk for the new field ID; when queried, Iceberg fills NULL for the missing ID. Renaming a column is also safe: only the human-readable name in the schema changes, the field ID stays the same, and old Parquet files keep matching correctly. (This is fundamentally different from plain Parquet outside Iceberg, where the fallback IS name-based — rename a column and old files lose the match. Inside an Iceberg-managed table, you get ID-based matching, which is why renames and drops are metadata-only and free.)

> **Common mistake — do NOT describe Iceberg's schema evolution as "name-based."** That is the mechanism plain Parquet falls back to without Iceberg metadata. Iceberg uses **field IDs**. Field IDs are why ADD/DROP/RENAME are all metadata-only. Said the wrong way: "Iceberg uses name-based matching" → wrong, and it makes the safety guarantees sound coincidental rather than designed.
>
> **ADD COLUMN is always nullable.** You cannot add a NOT NULL column to an Iceberg table in one step — the constraint would be violated by historical rows that will read NULL. To add a NOT NULL column: (1) `ALTER TABLE ... ADD COLUMN col TYPE` (nullable, metadata-only), (2) backfill the column in historical rows with `MERGE INTO` or a Spark rewrite, (3) `ALTER TABLE ... ALTER COLUMN col SET NOT NULL`. Step 3 fails loudly if any row still has NULL — that's the safety gate.
>
> **DROP COLUMN is also metadata-only.** Iceberg's `ALTER TABLE ... DROP COLUMN` is instant and rewrite-free, the same as ADD. The column's bytes remain in old Parquet files on storage, but the field ID is retired from the table schema and readers no longer project that column — so queries simply never see it. The unused bytes only get physically removed if you later run `CALL system.rewrite_data_files(...)` for compaction. Both Trino 467 and Spark behave identically here: they share the same Iceberg metadata layer.

### Schema changes on the Postgres side: what happens when a new column is added

This subsection answers the precise question: "A new column was added in Postgres. The next Spark ingestion run picks it up in the DataFrame. What does Iceberg actually do?" The answer is **not** the intuitive "Iceberg auto-adds it for you." Default Iceberg behavior is **stricter** than most engineers expect, and that strictness is the safety property — it prevents accidental schema drift from corrupting your tables. Read every option below before deciding which path to take in production.

#### 1. The default behavior — `writeTo().append()` FAILS LOUDLY on schema mismatch

By default, calling `df.writeTo("iceberg.analytics.events").append()` with a DataFrame that contains a column **not present** in the existing Iceberg table's schema **fails with an `AnalysisException`**. The append does **NOT** silently auto-add the column and does **NOT** silently drop the extra column. The job stops, no rows are written, and you must take an explicit action before the next run.

This is correct, defensive behavior. Iceberg refuses the write rather than silently mutate the table schema based on whatever the writer happens to send today. Without this guardrail, a buggy Spark job that briefly added a stray test column would silently extend the production table schema, and removing it later becomes a multi-step migration.

**The exact error you will see in Spark logs (verified against Spark 3.5 + Iceberg 1.5.2):**

```
org.apache.spark.sql.AnalysisException: Cannot write to 'iceberg.analytics.events',
too many data columns:
Table columns: 'id', 'tenant_id', 'user_id', 'event_name', 'event_ts', 'properties', 'updated_at'
Data columns:  'id', 'tenant_id', 'user_id', 'event_name', 'event_ts', 'properties', 'updated_at', 'ab_variant'
```

The error is raised by Spark's DataSourceV2 writer **before** Iceberg ever sees the data — it's a pre-validation step. The streaming batch fails, the offset does not commit, and the next batch re-attempts with the same error until the schema is fixed.

**THE DOMINANT REAL-WORLD CAUSE of "silent NULLs, no errors" is NOT a `writeTo().append()` schema-drop.** It is almost always one specific pattern: **a pinned explicit-column-list JDBC SELECT that does not include the new Postgres column.**

| Spark JDBC read shape | DataFrame contents | What Iceberg sees | What lands in the Iceberg table |
|---|---|---|---|
| `SELECT * FROM events` | New Postgres column flows into the DataFrame | DataFrame has an extra column the table doesn't | `append()` FAILS LOUDLY with `AnalysisException: Cannot write to [table], too many data columns` |
| `SELECT id, tenant_id, ..., updated_at FROM events` **(explicit column list, new column NOT listed)** | New Postgres column is **excluded from the DataFrame entirely** | DataFrame schema matches the Iceberg schema — **no mismatch from Iceberg's perspective** | `append()` succeeds. No error. Every row lands with the new Postgres column simply **missing** — it never entered the DataFrame, so it never reached Iceberg. From Iceberg's side, nothing went wrong. |

The two outcomes are opposites and **only the second one ("silent NULLs, no errors") matches the symptom an engineer is actually paging about.** If your reports say "queries return NULL for the new column and no errors fired," it is *not* an `append()` schema-drop bug (that would have erred loudly). It is **the SELECT in your JDBC source that's pinned to an old explicit column list.** Open the Spark job's source code, find the `spark.read.jdbc(... table="(SELECT ... FROM events ...)")` call, and confirm whether the new column is in the projection. In nine cases out of ten, the answer is no — the column was added in Postgres but never added to the SELECT.

This is a Spark/JDBC-side bug, not an Iceberg-side bug. Iceberg never had the opportunity to receive or drop the column; the column was filtered out by the Postgres-side projection before any rows reached Spark.

**Fix order:** (1) add the column to the Iceberg table via `ALTER TABLE ... ADD COLUMNS` (metadata-only), (2) update the Spark job's SELECT to include the new column (or switch to `SELECT *` if the table's column count is bounded), (3) re-run. Always alert from the preflight schema check (above) so the diff is caught at job startup before silent-NULL data accumulates for weeks.

#### 2. Opt-in auto-evolution — the two knobs that must BOTH be set

If you want Iceberg to auto-add new columns during `append()` instead of failing, you must set **two things together**. Setting only one of them does nothing.

##### Required table property for mergeSchema to work

> **This pattern applies to `writeTo(...).append()` consumers ONLY.** If your Spark consumer uses `MERGE INTO` (the standard shape for CDC pipelines that handle updates and deletes), `mergeSchema` is silently ignored — see [apache/iceberg#5556](https://github.com/apache/iceberg/issues/5556). For MERGE INTO consumers, `ALTER TABLE ... ADD COLUMN` is the ONLY way to add new columns; setting `write.spark.accept-any-schema=true` plus `.option("mergeSchema", "true")` does **nothing** for MERGE INTO. If you only use MERGE INTO (most production CDC pipelines), skip the two-knob recipe entirely and treat the manual `ALTER TABLE ADD COLUMN` step as mandatory.
>
> **CRITICAL — `mergeSchema` ALONE is insufficient. You MUST also set the table property `write.spark.accept-any-schema=true`.** This is the single most common copy-paste failure in Iceberg schema-evolution code. Engineers add `.option("mergeSchema", "true")` to their writer call, expect Iceberg to auto-add the new column, and instead get the same `ValidationException: Cannot write incompatible dataset` they were trying to fix. The reason: Spark's DataSourceV2 writer validates the DataFrame schema against the table schema **BEFORE** delegating to Iceberg. Without `write.spark.accept-any-schema=true` set on the table, **Spark rejects the schema mismatch before Iceberg gets a chance to evolve the schema**. The `mergeSchema` writer option is meaningless without the matching table property — they are a paired contract, not independent knobs.
>
> The required SQL:
>
> ```sql
> -- Run ONCE per table — best practice is to set this AT TABLE CREATION TIME
> -- for every incrementally-loaded table, not reactively after a 2 AM page.
> ALTER TABLE iceberg.analytics.subscriptions
> SET TBLPROPERTIES ('write.spark.accept-any-schema'='true');
> ```
>
> **Set this at table creation time, not after the first schema-mismatch incident.** Adding the property reactively after a paging incident means at least one incremental run has already failed and operators have spent debugging time chasing what looked like a code bug. Make it part of your standard `CREATE TABLE` template for every Iceberg table fed by a Spark incremental job. Concrete template — combine the property with the `CREATE TABLE` so the table is born ready for auto-evolution:
>
> ```sql
> CREATE TABLE iceberg.analytics.subscriptions (
>   subscription_id BIGINT,
>   tenant_id       STRING,
>   plan            STRING,
>   created_at      TIMESTAMP,
>   updated_at      TIMESTAMP
> )
> USING iceberg
> PARTITIONED BY (days(created_at), tenant_id)
> TBLPROPERTIES (
>   'write.spark.accept-any-schema' = 'true',
>   'format-version'                = '2'
> );
> ```
>
> The two-knob contract:
>
> | Knob | Where it lives | Required because |
> |---|---|---|
> | `write.spark.accept-any-schema=true` | Iceberg **table property** (set once via `ALTER TABLE ... SET TBLPROPERTIES` or at `CREATE TABLE`) | Tells Spark's V2 writer "do not pre-validate this table's schema against the incoming DataFrame — let Iceberg handle the diff" |
> | `.option("mergeSchema", "true")` | **Writer option** on every `writeTo(...).append()` or `writeTo(...).overwrite(...)` / `.overwritePartitions()` call | Tells Iceberg "for THIS write, if the DataFrame has columns the table doesn't, ADD them as part of the commit" |
>
> Set only one and nothing useful happens: `mergeSchema` alone is rejected at Spark's pre-validation step (the original error); `accept-any-schema` alone produces a writer that accepts the DataFrame but doesn't extend the schema (the new column's values are silently dropped). Both must be set together, every time.
>
> **Scope of the two-knob recipe:** `writeTo().append()`, `writeTo().overwrite(...)`, and `writeTo().overwritePartitions()` all honor the `mergeSchema` option when the table has `write.spark.accept-any-schema=true`. **The recipe does NOT work with Spark `MERGE INTO`** — see the dedicated CRITICAL callout immediately below. Treat MERGE INTO as schema-fixed and always run `ALTER TABLE ... ADD COLUMNS` first.

```python
# Knob 1: a TABLE PROPERTY, set once per table (see callout above).
spark.sql("""
    ALTER TABLE iceberg.analytics.events
    SET TBLPROPERTIES ('write.spark.accept-any-schema' = 'true')
""")

# Knob 2: a WRITER OPTION, set on EVERY write that should auto-evolve.
df.writeTo("iceberg.analytics.events") \
    .option("mergeSchema", "true") \
    .append()
```

With both in place, when `df` contains a column not in the Iceberg table, the writer will add the column to the Iceberg schema as part of the same commit and write the rows.

> **Syntax warning — use `.option("mergeSchema", "true")`, NOT `.mergeSchema(True)`.** The chained form `df.writeTo(...).mergeSchema(True).append()` is **non-idiomatic and not part of the official Iceberg Spark writer API**. It looks plausible (Spark has many fluent builder methods) but it doesn't exist on the `DataFrameWriterV2` builder that `writeTo(...)` returns. Running it produces `AttributeError: 'DataFrameWriterV2' object has no attribute 'mergeSchema'` in some environments, and in others may silently call a passthrough method that doesn't actually enable schema merging — neither outcome is what you want. The **only** correct form is `.option("mergeSchema", "true")` — a string-valued writer option, lowercase boolean string. Same for the table property: `'write.spark.accept-any-schema' = 'true'` is a string literal, not a Python boolean. Both knobs use the string `"true"`, not Python's `True`.

> **CRITICAL — `mergeSchema` does NOT work with Spark `MERGE INTO`.** The `mergeSchema` writer option is only honored on **`writeTo(...).append()`** (the DataFrame v2 write API). It is **NOT supported on Spark `MERGE INTO` SQL statements** ([apache/iceberg#5556](https://github.com/apache/iceberg/issues/5556)). If your pipeline uses `MERGE INTO` — which is the recommended write shape for incremental ingestion with late-arriving rows, CDC consumers, soft-delete sync, and reconciliation jobs (i.e., most production pipelines in this guide) — there is **no auto-evolution shortcut available**. You must **always** add the column to Iceberg manually with `ALTER TABLE iceberg.analytics.events ADD COLUMNS (new_col STRING)` **first**, and only then re-run the `MERGE INTO` job. Setting `write.spark.accept-any-schema=true` on the table does not help either — `MERGE INTO` ignores it. Treat the manual ADD COLUMNS path (section 3 below) as **mandatory**, not optional, for any pipeline that uses `MERGE INTO`.

**Why the production recommendation is to NOT enable this by default.** Auto-evolution is convenient for ad-hoc / development tables, but for production ingestion the default-fail behavior is the safety property. With auto-evolution on, every accidental column change in the Spark job's SELECT, every typo, every transient debug column gets baked into the production Iceberg schema permanently. Cleaning up a stray column requires `ALTER TABLE ... DROP COLUMN` (metadata-only but still a real DDL operation that has to be coordinated with downstream consumers). On the production stack, prefer the **manual ADD COLUMNS path** below.

#### 3. The conservative manual path (recommended for production)

For incremental / append pipelines on the production stack, run the schema change in two ordered steps and keep auto-evolution disabled:

```python
# Step 1: explicitly add the new column to Iceberg first.
# This is metadata-only — completes in milliseconds even on a 10 TB table.
spark.sql("""
    ALTER TABLE iceberg.analytics.events
    ADD COLUMNS (ab_variant STRING)
""")

# Step 2: re-run the Spark sync job normally.
# The DataFrame's new column now matches the Iceberg schema, so append() succeeds.
df.writeTo("iceberg.analytics.events").append()
```

This path makes every schema change a deliberate, auditable action — there is a commit in your DDL history that says "on 2026-05-25, we added `ab_variant` to the events table" — rather than an emergent side effect of whatever the most recent Spark job happened to write. Pair it with the `preflight_schema_check` function above so the diff is detected at job startup, the operator runs the ADD COLUMNS, and then the job re-runs cleanly.

#### 4. Append (incremental) vs `createOrReplace()` (full-refresh) — different rules

The same "new Postgres column" scenario behaves differently depending on which write API you use:

| Write API | What happens when the DataFrame has a new column not in the existing Iceberg schema |
|---|---|
| `writeTo(...).append()` (incremental Pattern B) | **Fails by default** — must either (a) run `ALTER TABLE ... ADD COLUMNS` first, or (b) opt into auto-evolution with `write.spark.accept-any-schema=true` + `.option("mergeSchema", "true")` |
| `writeTo(...).createOrReplace()` (full-refresh Pattern A) | **Succeeds** — the table is dropped and rebuilt from the DataFrame's schema each run; the new column becomes part of the table schema automatically |

**Symmetric warning for `createOrReplace()`**: because the table is rebuilt from the DataFrame schema on every run, a column that exists in Iceberg but is **NOT** in the DataFrame **disappears** on the next run. There is no way to "add a column once" to a `createOrReplace()` target — the Spark job's SELECT is the table schema. (This is the same trap covered in detail in the next subsection.)

#### 5. Historical NULL-fill guarantee for added columns

Once a column has been added to the Iceberg table via `ALTER TABLE ... ADD COLUMNS` (or via auto-evolution), **all existing Parquet files transparently return NULL for that column on query** — no Parquet file rewrite is required, no backfill job needed.

This is one of Iceberg's foundational guarantees: schemas are tracked by **column ID**, and missing columns in old data files are filled with NULL at read time. A 10 TB historical events table can gain a new column in milliseconds (the ALTER is metadata-only) and every old row reads as NULL for that column from day one. You do **not** need to rewrite the historical Parquet files unless you specifically want to backfill non-NULL values into the historical rows (in which case it's a separate one-off Spark job).

This guarantee holds **regardless of how the column was added** — manual `ALTER TABLE ... ADD COLUMNS`, auto-evolution via `mergeSchema=true`, or (in CDC pipelines) a sink's auto-ALTER. Once the column is part of the Iceberg schema, the NULL-fill behavior is automatic.

#### 6. The inverse case — a column was DROPPED from Postgres

The symmetric scenario: an engineer runs `ALTER TABLE events DROP COLUMN legacy_score` on the Postgres source. **Iceberg does NOT auto-drop the column.** The Iceberg schema retains it, every historical Parquet file still contains the column's data, and the column continues to appear in `DESCRIBE TABLE` and in every analyst's `SELECT *`. New rows arriving from Postgres simply have **NULL** for that column going forward (because the Spark JDBC read no longer pulls a value for it). No error fires; the column quietly becomes "all NULLs after date X."

To actually remove the column from Iceberg, run `ALTER TABLE ... DROP COLUMN` explicitly — this is **also metadata-only** (Iceberg tracks columns by ID and just removes the column from the schema; the bytes in old Parquet files remain on MinIO until those files are rewritten via `rewrite_data_files`):

```sql
ALTER TABLE iceberg.analytics.events DROP COLUMN legacy_score;
```

Coordinate with downstream consumers before dropping — any Trino view, dbt model, or dashboard that still references the column will break the next time it runs. The preflight schema-diff check (above) flags this case as `removed_from_postgres` so an operator can decide whether to DROP in Iceberg or leave the column intact for historical querying.

#### What schema evolution does NOT auto-handle

`mergeSchema` + `write.spark.accept-any-schema` automatically handles **adding a new nullable column** (the common case Postgres engineers add every week). It does **not** handle the following four scenarios — each requires explicit, manual intervention, and each causes a different failure mode if you assume auto-evolution covers them.

| Scenario | Why auto-evolution doesn't handle it | What you must do manually |
|---|---|---|
| **Column rename in Postgres** (`ALTER TABLE events RENAME COLUMN ab_variant TO experiment_variant`) | Iceberg sees the rename as a **DROP of the old column + ADD of a new column**. The historical data tied to `ab_variant` becomes orphaned (still on MinIO but unreachable by name), and `experiment_variant` has NULL for all old rows. Column **identity is lost** — Iceberg cannot infer that the rename was semantically the same column. | Run `ALTER TABLE iceberg.analytics.events RENAME COLUMN ab_variant TO experiment_variant` in Iceberg **first** (before the Spark job picks up the new Postgres column name). Iceberg preserves column ID across the rename, so historical data follows the new name. |
| **Type widening beyond Iceberg's allowed rules** (e.g., Postgres `INTEGER` → `VARCHAR`) | Iceberg permits a documented set of **type promotions** (int → long, float → double, decimal precision increase). Everything else — including int → string, timestamp → string, decimal scale changes — fails the write. `mergeSchema` does NOT relax these rules; it only adds columns. | Run a one-off Spark job that reads the table, casts the affected column to the new type, and writes to a new Iceberg table; then swap. There is no in-place ALTER for unsupported type changes. |
| **Column drop in Postgres** (`ALTER TABLE events DROP COLUMN legacy_score`) | Already covered in section 6 above, but worth repeating here: auto-evolution does NOT propagate drops. The Iceberg column persists and silently fills with NULL for new rows. Downstream queries that filter on `legacy_score IS NOT NULL` start returning fewer rows over time with no error. | Explicitly run `ALTER TABLE iceberg.analytics.events DROP COLUMN legacy_score`. Audit and update every Trino view, dbt model, and dashboard that references the column first. |
| **NOT NULL column added without a default in Postgres** (`ALTER TABLE events ADD COLUMN required_field VARCHAR NOT NULL`) | Even with `mergeSchema` enabled, Iceberg can ADD the column to the schema, but **it cannot supply a value for old rows** — old Parquet files have no value for the new column, so reads return NULL. If the column is declared NOT NULL on the Iceberg side and a reader strictly enforces nullability, queries against historical data fail. More commonly: any downstream consumer expecting non-NULL values (Trino views with `WHERE required_field = ...`, dbt models assuming non-NULL) silently breaks. | Add the column as **nullable** in Iceberg (this is the default for `ADD COLUMNS`) regardless of how it's declared in Postgres. Run a one-off backfill Spark job that computes a default value for historical rows. Only after the backfill is verified, optionally migrate the Iceberg column to NOT NULL via a column-spec change (this is a costly rewrite, usually skipped). |

**Quick rule of thumb:** `mergeSchema` is a one-trick tool — it adds nullable columns. Renames, type changes, drops, and NOT-NULL semantics all need either a manual Iceberg `ALTER TABLE` (preferred — metadata-only) or a Spark rewrite job (expensive). Treat any schema change other than "add a new nullable column" as a **deliberate, scheduled migration**, not something a nightly pipeline should figure out on its own.

> **Footnote on MERGE INTO + mergeSchema history.** The `mergeSchema` interaction with `MERGE INTO` has been fragile across Iceberg versions — see [apache/iceberg#5556](https://github.com/apache/iceberg/issues/5556) for the discussion thread. In **Iceberg 1.5.2 (the production stack version)**, schema evolution via `MERGE INTO` works for the common "ADD nullable column" case when the table has `write.spark.accept-any-schema=true`, but several edge cases (renaming a column referenced in the MERGE ON clause, type promotion combined with a schema add in the same commit) have known issues. **The safe production posture is unchanged: do not rely on `MERGE INTO` to evolve schema. Always run `ALTER TABLE ... ADD COLUMNS` manually before the `MERGE INTO` job picks up the new column.** The `mergeSchema` writer option is documented to apply to `writeTo(...).append()` only; reading the Iceberg source in 1.5.2 confirms `MERGE INTO` does not honor the option in the same way (the merge planner builds the target schema from the catalog metadata, not from the source DataFrame). Treat `MERGE INTO` as schema-fixed: if the schema needs to change, run the Iceberg DDL first, then the MERGE.

#### Quick-reference decision table

| Your situation | Recommended action |
|---|---|
| Production incremental pipeline, new column added in Postgres | Run `ALTER TABLE iceberg.analytics.events ADD COLUMNS (new_col STRING)` first, then re-run the Spark job. Keep `write.spark.accept-any-schema` unset. |
| Development / ad-hoc Iceberg table, frequent schema changes acceptable | Enable both `write.spark.accept-any-schema=true` and `.option("mergeSchema", "true")` and let auto-evolution happen. |
| Full-refresh pipeline (`createOrReplace()`), new column added in Postgres | Update the Spark job's SELECT to include the new column. Do NOT run `ALTER TABLE` — the next `createOrReplace()` will rebuild the table from the DataFrame schema anyway. |
| Need to backfill historical rows with non-NULL values for the new column | Run a one-off Spark job that reads all old rows, computes the new column, and writes back via `overwritePartitions()`. The NULL-fill guarantee covers reads, not derived values. |

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

> **Iceberg spec — the complete list of safe type promotions.** The Iceberg spec defines exactly three safe in-place type promotions. If a change you want to make isn't on this list, you must do a multi-step migration (add a new column, backfill, drop the old column, rename) — never assume `ALTER COLUMN ... TYPE` will just work.
>
> | Source type | Target type | Notes |
> |---|---|---|
> | `int` (32-bit) | `long` (64-bit) | The Iceberg type. In Spark / Trino syntax this is `INT` → `BIGINT`. Pure metadata change — no Parquet rewrite. |
> | `float` (32-bit) | `double` (64-bit) | The Iceberg type. In Spark / Trino syntax this is `REAL` / `FLOAT` → `DOUBLE`. Pure metadata change. |
> | `decimal(P, S)` | `decimal(P2, S)` where `P2 > P` | Precision widening only. The scale (number of digits after the decimal point) MUST stay the same — Iceberg rejects scale changes. |
>
> **NOT safe promotions (despite being intuitive — engineers ask about these often):**
> - `DATE` → `TIMESTAMP` — **not in the spec.** You may see articles claim this is "safe with caveats" — it is not a defined Iceberg promotion. Do a column-add + backfill + drop, not an `ALTER COLUMN ... TYPE`.
> - `TIMESTAMP` (precision 3) → `TIMESTAMP` (precision 6) — **not defined.** Iceberg stores timestamps at microsecond precision (precision 6) by default; precision is a query-engine concern (Trino) not an Iceberg storage knob.
> - `VARCHAR(N)` → `VARCHAR(M)` where M > N — Iceberg's `string` type is unbounded, so this is a Trino/Spark concept that doesn't apply. Iceberg already accepts any string length.
> - `STRING` → `BINARY` or vice versa — **not allowed.**
> - Adding scale to a decimal (`decimal(10, 2)` → `decimal(10, 4)`) — **not allowed.** Only precision can widen; scale must be fixed.
>
> Source: [Apache Iceberg Spec — Schema Evolution / Type Promotion](https://iceberg.apache.org/spec/#schema-evolution).

> **Engine-specific `ALTER COLUMN` syntax — Trino 467 vs. Spark SQL.** The Iceberg spec defines what promotions are allowed, but the SQL **syntax** for issuing the change differs by engine. Pasting the wrong form into the wrong client is one of the most common newcomer footguns on this stack — the spec is permissive, but the parser is not.
>
> | Engine | Syntax | Notes |
> |---|---|---|
> | **Trino 467 (query editor / Trino CLI)** | `ALTER TABLE iceberg.analytics.events ALTER COLUMN ab_variant SET DATA TYPE BIGINT;` | Uses the SQL-standard `ALTER COLUMN ... SET DATA TYPE` form. This is the form documented in [Trino's ALTER TABLE reference](https://trino.io/docs/current/sql/alter-table.html). Spark's `CHANGE COLUMN` form is **NOT** recognized by Trino — pasting it produces a `mismatched input 'CHANGE'` parse error. |
> | **Spark SQL (spark-sql, Spark Thrift, or pyspark.sql)** | `ALTER TABLE iceberg.analytics.events ALTER COLUMN ab_variant TYPE BIGINT;` | The Iceberg-documented Spark DDL form per [iceberg.apache.org/docs/latest/spark-ddl](https://iceberg.apache.org/docs/latest/spark-ddl/). Spark also accepts the Hive-compatible `CHANGE COLUMN ab_variant ab_variant BIGINT` (column name repeated twice), but `ALTER COLUMN TYPE` is the canonical Iceberg-Spark syntax. |
>
> **Same Iceberg table, same promotion, same result on disk** — both forms emit the identical metadata-only schema update to the Iceberg catalog (a new column-type assertion against the existing column ID; no Parquet file rewrite). Pick the form that matches the client you're running:
> - Engineers using the Trino query editor or Trino CLI: use `ALTER COLUMN ... SET DATA TYPE`.
> - Engineers running Spark jobs, spark-sql sessions, or Spark notebooks: use `ALTER COLUMN TYPE` (Iceberg-canonical) — Hive-style `CHANGE COLUMN` also works but is not the Iceberg-documented form.
>
> The same engine-specific split applies to **column renames** — Trino is `ALTER TABLE ... RENAME COLUMN old TO new` and Spark is also `ALTER TABLE ... RENAME COLUMN old TO new` (Spark accepts both — fortunately the rename syntax converged) — and to **adding columns** (`ADD COLUMN` is identical in both engines). The divergence is concentrated in the type-change path; that's the one to memorize per-engine.

### For CDC jobs (Pattern C)

**How Debezium actually detects Postgres DDL changes — and what the schema registry has to do with it**

This is a common source of confusion. There are two separate systems involved:

> **Postgres schema tracking: no schema-history topic.** Unlike the MySQL, MariaDB, and SQL Server connectors, the Debezium PostgreSQL connector does **NOT** use a schema-history Kafka topic. Schema changes are tracked via **WAL relation messages** that Postgres emits inline with the next row-level write on a changed table. The relation message for a newly-added column is emitted only after the NEXT DML (INSERT/UPDATE/DELETE) on that table — **NOT** immediately after the `ALTER TABLE`. If your table receives writes infrequently (read-heavy, write-light tables — configuration tables, reference data, slow-churn dimensions), new columns may not appear in Debezium events for minutes to hours after the Postgres ALTER. This is normal Postgres logical-decoding behavior, not a Debezium bug. Force a no-op DML (`UPDATE foo SET id = id WHERE id = any_id`) if you need the schema change to surface immediately for testing or for an urgent backfill.
>
> **Implication for `snapshot.mode: recovery`:** because Postgres has no schema-history topic, the `recovery` snapshot mode (which re-reads that topic on MySQL/MariaDB/SQL Server) does **not exist** on the PostgresConnector — Kafka Connect rejects the config at registration. See the "`recovery` is NOT a valid `snapshot.mode`" callout earlier in this resource for the full breakdown.

**The DDL detection mechanism: WAL relation messages (not the schema registry)**

Postgres does not emit explicit `ALTER TABLE` events in the logical replication stream. The DDL itself is never transmitted in the WAL. Instead, after a DDL change, the next WAL record produced by a **row-level write (INSERT/UPDATE/DELETE)** against that table includes an updated **relation message** — a structural description of the table's current column layout — inline ahead of the DML event. Debezium reads this relation message and learns about the new column. This detection happens automatically with no configuration changes required.

> **Note — DDL timing on idle tables.** Because the updated relation message is only sent *inline with the next DML on that table*, an `ALTER TABLE` against an idle table will not surface in Debezium at commit time. The schema change appears only when the next INSERT/UPDATE/DELETE hits that table. If your table receives no writes for hours after the ALTER, Debezium will appear to ignore the schema change during that entire window — it isn't broken, it just hasn't seen a new relation message yet. For test/staging environments where you want to verify schema evolution end-to-end immediately after an ALTER, run a no-op DML (e.g., `UPDATE events SET updated_at = updated_at WHERE id = ?` against any single row) to force the new relation message into the stream.

Key consequence: Debezium does NOT re-emit historical rows with the new column. It only starts including the new field in events that occur *after* the `ALTER TABLE`. Pre-alter rows in Kafka will have the field absent (not `null` — just absent from the message).

**The schema registry: Kafka payload serialization (unrelated to DDL detection)**

The schema registry (Confluent Schema Registry, Apicurio) stores Avro or Protobuf schemas for the Kafka message payloads. It is used by the Debezium connector to serialize and deserialize messages — not to detect DDL changes on the source database. You can run Debezium without a schema registry (using JSON serialization) and DDL detection still works.

**Schema evolution config: where it lives depends on the sink**

The Postgres **source connector** (Postgres → Kafka) does not have a schema-evolution toggle — it always emits the new field once Postgres surfaces it via a WAL relation message. The auto-ALTER behavior lives on the **sink**, and the property name differs by sink — and matters for whether you have to ALTER the Iceberg table manually.

**There are TWO distinct CDC deployment modes that write Debezium events into Iceberg. Do not conflate them — their schema-evolution stories are different:**

**Mode 1 — debezium-server-iceberg (standalone sink, no Spark in the path).** Debezium events flow Postgres → Kafka → debezium-server-iceberg → Iceberg. The relevant property is `debezium.sink.iceberg.allow-field-addition`. **This property defaults to `true` on the memiiso/debezium-server-iceberg distribution** — out of the box, the sink AUTOMATICALLY propagates new columns from Postgres to Iceberg with no manual `ALTER TABLE ADD COLUMN` step required. The official property description reads: "Allow field addition to target tables. Enables automatic schema evolution, expansion." If you are running with the default config, schema additions just work — Debezium emits the new field once Postgres surfaces it via a WAL relation message, and the sink runs the Iceberg ALTER on your behalf.

```
# In your debezium-server application.properties — this is the DEFAULT, so you
# typically do NOT need to set it. Listed here for completeness.
debezium.sink.iceberg.allow-field-addition=true

# Only set this if you want to OPT OUT of auto-evolution and have the sink
# start rejecting writes that contain new columns:
# debezium.sink.iceberg.allow-field-addition=false
```

See the [debezium-server-iceberg docs](https://github.com/memiiso/debezium-server-iceberg/blob/master/docs/iceberg.md). **This property is meaningful only when you are running debezium-server-iceberg.** If you have explicitly set `allow-field-addition=false` in your config (a hardening choice some teams make to force every schema change through a manual review process), the sink will start rejecting writes that contain new columns — you'd then need to manually `ALTER TABLE ADD COLUMN` in Iceberg before resuming.

**Mode 2 — Spark Structured Streaming as the Iceberg writer.** Debezium events flow Postgres → Kafka → Spark Structured Streaming → Iceberg. **The `debezium.sink.iceberg.allow-field-addition` property does NOT apply here** — it is a debezium-server-iceberg config and Spark does not read it. There is no equivalent auto-ALTER toggle in Spark Structured Streaming; you must run `ALTER TABLE iceberg.analytics.events ADD COLUMN ...` yourself before resuming the consumer, or build that logic into your job (typically: pause on schema-mismatch error, ALTER, resume).

> **Note on `mergeSchema` for Spark consumers.** Spark also supports `option("mergeSchema", "true")` on the DataFrameWriter to allow new columns in the source DataFrame to be automatically added to the Iceberg table at write time (paired with the `write.spark.accept-any-schema=true` table property — see the schema-evolution section above for the full two-knob setup). However, explicitly running `ALTER TABLE ADD COLUMN` first is recommended for production — it makes the schema change visible and auditable before any data flows, and `mergeSchema` does NOT apply to `MERGE INTO` SQL statements (only to `writeTo(...).append()` calls), so most CDC consumers using `MERGE INTO` cannot rely on `mergeSchema` anyway.

> **Common mistake.** Engineers reading the debezium-server-iceberg docs sometimes try to set `debezium.sink.iceberg.allow-field-addition=true` in their Spark conf. Spark will silently ignore it — the property has no meaning to Spark. The "schema evolution works automatically" advice you may have read **only applies to the standalone debezium-server-iceberg sink**, not to Spark consumers.

**Unrelated, do not confuse:** The **Debezium JDBC sink connector** (Kafka → relational DB, *not* Iceberg) uses `schema.evolution=basic` (or `none`). This is a different connector entirely and is not what writes to Iceberg. `schema.evolution=basic` is not recognized by either debezium-server-iceberg or Spark.

**Order of operations — Mode 2 (Spark Structured Streaming consumer, manual ALTER required):**

1. Notice the new column in Postgres (via schema-diff alert from `preflight_schema_check`) or when the consumer errors on an unexpected field.
2. Pause the Iceberg-writing Spark Structured Streaming consumer.
3. Run `ALTER TABLE iceberg.analytics.events ADD COLUMN device_os VARCHAR` in Spark SQL — metadata-only, completes in milliseconds.
4. Resume the consumer — new events with `device_os` now write successfully.
5. Do NOT restart the Debezium source connector — it continued publishing events during the pause. The consumer simply resumes from where it left off in Kafka.

Note: `debezium.sink.iceberg.allow-field-addition` does NOT apply in this mode — it is a debezium-server-iceberg sink property, not a Spark config. Spark will ignore it if you set it.

**Order of operations — Mode 1 (debezium-server-iceberg with default config — `debezium.sink.iceberg.allow-field-addition=true` is the default):**

1. Developer adds column in Postgres.
2. Debezium source connector detects the relation message (on the next DML against that table), emits events with the new field.
3. debezium-server-iceberg sink sees the new field, automatically runs `ALTER TABLE ADD COLUMN` on Iceberg.
4. No manual intervention required.

(If you have explicitly set `allow-field-addition=false`, the sink will instead reject writes containing new columns and you must manually run `ALTER TABLE iceberg.analytics.events ADD COLUMN ...` before resuming — i.e., the same flow as Mode 2 below.)

> **Column type changes (ALTER COLUMN SET DATA TYPE) — not auto-handled by either sink.** The `allow-field-addition` toggle only covers *new columns*. Column **type changes** in Postgres (`ALTER TABLE events ALTER COLUMN score TYPE BIGINT`) are NOT automatically propagated by either the standalone debezium-server-iceberg sink or a Spark Structured Streaming consumer. The sink (or your Spark job) will continue to send the new wider type into a column the Iceberg schema still believes is the old narrower type, and the write will fail with a type-mismatch error. To handle a Postgres column type change safely:
>
> 1. **Pause the consumer** (Strimzi: `spec.state: paused` on the KafkaConnector; Spark Structured Streaming: stop the job).
> 2. **Verify data compatibility** before issuing the Iceberg ALTER. Widening promotions are safe — `INT` → `BIGINT`, `FLOAT` → `DOUBLE`, increasing `VARCHAR(50)` → `VARCHAR(200)`. Narrowing changes are dangerous and may silently truncate or fail — `VARCHAR(50)` → `VARCHAR(10)` truncates every value over 10 chars; `BIGINT` → `INT` overflows on values beyond ~2.1B. Iceberg's spec only allows a small set of "safe" type promotions ([Iceberg type promotion rules](https://iceberg.apache.org/spec/#schema-evolution)); anything outside that set requires a column-rename + backfill pattern, not an in-place ALTER.
> 3. **Run the type-change ALTER manually on the Iceberg table.** Iceberg supports the widening promotions listed in its spec; the operation is metadata-only and completes in milliseconds. **Use the syntax that matches your client:**
>    - From Trino 467 (query editor / Trino CLI): `ALTER TABLE iceberg.analytics.events ALTER COLUMN score SET DATA TYPE BIGINT;`
>    - From Spark SQL: `ALTER TABLE iceberg.analytics.events CHANGE COLUMN score score BIGINT;`
>    Both forms produce the same metadata-only change on the same Iceberg table — see the "Engine-specific `ALTER COLUMN` syntax" callout above for full details. Pasting the Spark form into Trino (or vice versa) is a parse error, not a silent success.
> 4. **Resume the consumer.** New events with the wider type now write successfully.
>
> Always test the full sequence in staging first against a copy of the production table. The failure modes (silent truncation, mid-batch type errors that leave the consumer in a stuck state) are painful to recover from in production.

### Mid-stream schema changes in a running CDC pipeline (new column shows up NULL)

The single most common 2 AM page on a running CDC pipeline isn't a crash — it's a silent NULL. The pipeline keeps running, Debezium logs are clean, no error is raised in Spark, and yet a column that was added to Postgres a few hours ago is **NULL for every row in Iceberg**, including rows you know were inserted *after* the `ALTER TABLE`. This subsection walks the diagnosis and the fix end-to-end.

**Symptom recognition — two distinct failure modes.**

> **Mode 1 (the visible error — default MERGE INTO behavior):** The Spark Structured Streaming consumer logs an `AnalysisException` like "Unable to find the column of the target table from the INSERT columns" on every batch attempt. The streaming offset is **not** advancing — the batch retries the same window indefinitely. Debezium is healthy and continues writing to Kafka; the Spark consumer is stuck. This is the default behavior in Iceberg 1.5.2 when MERGE INTO uses `INSERT *` / `UPDATE SET *` and the source DataFrame has a column the target table doesn't.
>
> **Mode 2 (the silent NULL — narrow set of configurations):** New columns added to Postgres appear as NULL in Iceberg for **ALL** rows — including new rows written after the column was added. Debezium logs no errors and did not crash. The pipeline is still committing batches; offsets are advancing; row counts are growing. Only the new column is empty. This happens when (a) the MERGE statement explicitly lists target columns (omitting the new one), OR (b) an upstream `select(...)` narrows the DataFrame schema, OR (c) the consumer is debezium-server-iceberg with `allow-field-addition=false`.

If the symptom is "the pipeline crashed" or "the Spark job is throwing schema-mismatch errors" (Mode 1), the fix is straightforward: pause the consumer, run `ALTER TABLE ... ADD COLUMN` on Iceberg, resume. If the symptom is the silent NULL (Mode 2), you also need to audit the consumer code to fix the column-narrowing bug, plus run the backfill recipe to recover the lost values. Both modes are covered below.

**Root cause checklist (work through in order).**

**(a) Has any INSERT, UPDATE, or DELETE happened on the Postgres table since the `ADD COLUMN`?**

If not, **Debezium has not yet emitted a WAL relation message for the new schema.** For the PostgreSQL connector, the updated relation message describing the new column layout is only emitted **after the NEXT DML on the table** — not immediately after the DDL. This is different from MySQL/MariaDB/SQL Server, which use a schema-history Kafka topic that updates on DDL itself. Postgres has no such topic; the schema is tracked inline with WAL changes.

Consequence: if the table is read-heavy and write-light, the new column may not appear in Kafka events at all until the next INSERT/UPDATE/DELETE — minutes or hours after the `ALTER TABLE`. The pipeline isn't broken; it just hasn't seen a new relation message yet. Verify with a no-op DML:

```sql
-- Force a relation-message refresh by writing one harmless UPDATE on the changed table.
-- Picks any existing row, sets a column to its own current value — Postgres still writes
-- a WAL record, which carries the updated relation message inline.
UPDATE user_profiles SET user_id = user_id WHERE user_id = (SELECT user_id FROM user_profiles LIMIT 1);
```

After this no-op, the next Kafka event for that table will include the new column. If the new column then shows up in subsequent rows but old post-DDL rows are still NULL (Mode 2 above), the column was silently dropped by the consumer or by an upstream `select(...)` — proceed to (b). If instead the consumer started throwing `AnalysisException` immediately after the no-op DML (Mode 1), the Iceberg target table is missing the column — also proceed to (b).

**(b) Does the Iceberg table have the new columns?**

Run `DESCRIBE iceberg.analytics.user_profiles` in Trino (or `spark.sql("DESCRIBE ...")`). If the new columns are **missing from the Iceberg schema**, the consumer is either erroring out or silently dropping them — the difference is determined by **how the MERGE source DataFrame is constructed**, not by MERGE INTO itself. Read the matrix carefully:

| Consumer write shape | Behavior when DataFrame has columns the Iceberg table does not |
|---|---|
| `writeTo(...).append()` | **Fails by default** with a schema-mismatch `ValidationException`. You'd see this as a Spark error — not a silent NULL. |
| `MERGE INTO` with `INSERT *` / `UPDATE SET *` (column-mismatch path) | **Throws `AnalysisException`** in Iceberg 1.5.2 — the error message is along the lines of "Unable to find the column of the target table from the INSERT columns." The streaming batch fails; offsets do not commit; you see this as a Spark error in the driver log. This is the default and most common case. |
| `MERGE INTO` with `INSERT (col1, col2, ...)` listing only target columns | **Silently drops** any source column not in the explicit INSERT list. No error, no warning — the new column never lands in Iceberg. This is the silent-NULL pattern. |
| `MERGE INTO` with `write.spark.accept-any-schema=true` AND `mergeSchema=true` | **Auto-evolves** the target Iceberg schema — the new column is ADDED to the table as part of the MERGE commit. |

**Critical correction to a common misconception:** MERGE INTO does **not** silently drop columns by default. The default behavior on Iceberg 1.5.2 + Spark is a visible `AnalysisException`. The silent-drop case only happens when (a) the MERGE statement explicitly lists target columns in the INSERT/UPDATE clause (omitting the new column on purpose), or (b) an upstream `select(...)` in the consumer narrows the DataFrame schema before the MERGE. If your symptom is "silent NULL with no error in logs," check the MERGE statement and the upstream select — one of them is dropping the column before MERGE INTO sees it.

If your consumer uses `MERGE INTO` (the standard shape for CDC: handles INSERT/UPDATE/DELETE in one statement) and you see a `AnalysisException` in the Spark driver logs, the new column is the root cause — Debezium is correctly emitting it, but the Iceberg table doesn't have a column for it. The fix is `ALTER TABLE iceberg.analytics.user_profiles ADD COLUMN new_col VARCHAR` (see section "The `ALTER TABLE` fix" below).

**(c) Which CDC deployment mode are you running?** The fix differs by mode — work through the matrix below.

**Mode-specific fix matrix.**

| Mode | Fix | Auto-evolves? |
|---|---|---|
| **debezium-server-iceberg**, `allow-field-addition=true` (the default) | Nothing — sink auto-ALTERs after the first DML on the table | **Yes** |
| **debezium-server-iceberg**, `allow-field-addition=false` (opt-out) | Manual `ALTER TABLE ... ADD COLUMN` in Iceberg, then resume the sink | No |
| **Spark consumer using `writeTo(...).append()`** | Manual `ALTER TABLE ADD COLUMN` **OR** set both `write.spark.accept-any-schema=true` (table property) AND `.option("mergeSchema","true")` (writer option) | Optional |
| **Spark consumer using `MERGE INTO`** (most CDC pipelines) | **Manual `ALTER TABLE ADD COLUMN` is the recommended fix** — without it, MERGE INTO throws `AnalysisException` on the schema mismatch (visible error, batch fails until column is added). The two-knob pattern (`write.spark.accept-any-schema=true` + `mergeSchema=true`) has historically been fragile with MERGE INTO in Iceberg ([apache/iceberg#5556](https://github.com/apache/iceberg/issues/5556)) — production recommendation is explicit ALTER, not auto-evolution. | No (use explicit ALTER) |

**The `ALTER TABLE` fix (applies to all modes that need it).**

```sql
-- Trino (or Spark SQL — syntax is identical for ADD COLUMN). Metadata-only, instant,
-- safe to run while the streaming job is running. No data rewrite, no pause needed.
ALTER TABLE iceberg.analytics.user_profiles ADD COLUMN referral_source VARCHAR;
ALTER TABLE iceberg.analytics.user_profiles ADD COLUMN onboarding_step INTEGER;
ALTER TABLE iceberg.analytics.user_profiles ADD COLUMN gdpr_consent_at TIMESTAMP(6);
-- Note: use TIMESTAMP(6) — NOT bare TIMESTAMP. Iceberg via Trino rejects bare TIMESTAMP
-- because the default precision in Trino is 3 and Iceberg stores timestamps at microsecond
-- precision (6). Use TIMESTAMP(6) explicitly for any Iceberg timestamp column.
-- Old rows automatically return NULL for new columns (no data rewrite). New rows arriving
-- after this DDL will have the real value populated by the consumer.
```

**Do NOT restart the Debezium connector.** Restarting causes it to re-read from its last committed LSN offset — this is not needed for schema changes and may cause duplicate events to be replayed downstream. The fix lives entirely on the **Iceberg side** (the schema). Debezium has been correctly emitting the new column in its events since the first post-DDL DML; the problem was that the consumer's target schema didn't have a place to put those values. Once the Iceberg `ALTER TABLE` is done, the next `MERGE INTO` batch from the existing running consumer will start populating the column for new rows.

**Backfill recipe for post-DDL rows whose new-column values were dropped.** This applies if (a) your consumer was running in a silent-drop configuration (explicit MERGE column list, upstream `select`, or `allow-field-addition=false`), OR (b) you ran the auto-evolution path but only after some events had already passed through with the column missing from the Iceberg target. All the rows that arrived between the Postgres `ADD COLUMN` and your Iceberg `ALTER TABLE` were merged with the column dropped — they are now in Iceberg with NULL for the new columns, and the live CDC stream is past them. If your consumer instead threw `AnalysisException` for the duration of the gap (the default MERGE INTO behavior), no rows were committed during the gap — Kafka still has them, and you only need to add the Iceberg column and resume; the backfill below is not needed. To recover values when the silent-drop path was in effect, do a one-shot read from the Postgres **primary** (not a replica — same reasoning as the lag-spike backfill recipe earlier in this resource: the primary is the ground truth) and MERGE the post-DDL window:

```python
# Read from Postgres PRIMARY only (not a replica)
# Scope to the window AFTER the ADD COLUMN migration — substitute your actual DDL timestamp
backfill_df = spark.read.jdbc(
    url=PG_PRIMARY_URL,
    table="""(
        SELECT user_id, referral_source, onboarding_step, gdpr_consent_at
        FROM user_profiles
        WHERE updated_at >= '2026-05-18'
        -- TODO: replace with the actual timestamp of your Postgres ADD COLUMN migration
        -- (check your migration tool's log or run:
        --   SELECT column_name, is_nullable FROM information_schema.columns
        --   WHERE table_name='user_profiles' AND column_name='referral_source';
        -- to confirm the column exists, then cross-reference the migration log for the timestamp)
    ) t""",
    properties=PG_PROPS,
)
backfill_df.createOrReplaceTempView("backfill")
spark.sql("""
    MERGE INTO iceberg.analytics.user_profiles t
    USING backfill s ON t.user_id = s.user_id
    WHEN MATCHED THEN UPDATE SET
        t.referral_source  = s.referral_source,
        t.onboarding_step  = s.onboarding_step,
        t.gdpr_consent_at  = s.gdpr_consent_at
    -- Intentionally NO WHEN NOT MATCHED INSERT: avoid creating duplicates ahead of
    -- the streaming pipeline. If a row exists in Postgres but not yet in Iceberg, the
    -- live CDC stream will pick it up shortly — let it. The backfill's job is ONLY to
    -- populate the missing-column values on rows that already exist in Iceberg.
""")
```

**Pre-release rows are correctly NULL.** Rows written to Postgres **before** the `ADD COLUMN` have no values for the new columns — NULL is accurate, not a bug. The backfill above is scoped to `updated_at >= <DDL timestamp>` precisely to avoid backfilling synthesized defaults onto historical data. Only backfill **post-DDL** rows that should have had values and silently lost them in the consumer's MERGE.

**Why this happens silently in some configurations.** The silent-NULL bug only manifests under a narrow combination: (1) the MERGE INTO uses an explicit column list in the INSERT/UPDATE clause that omits the new column, OR (2) an upstream `select(...)` in the consumer code narrows the DataFrame schema before MERGE INTO sees it, OR (3) the consumer is debezium-server-iceberg with `allow-field-addition=false` (the opt-out). In the default `MERGE INTO ... INSERT *` / `UPDATE SET *` shape on Iceberg 1.5.2, the schema mismatch is a **loud `AnalysisException`** — the streaming batch fails, the offset doesn't commit, and the symptom is "the consumer keeps retrying the same batch with the same error" rather than silent NULLs.

If you have the silent-NULL symptom (NULL for new column, no error in logs, offsets advancing), audit the consumer code for explicit column lists or upstream selects before assuming the new column is the root cause. The `preflight_schema_check` function described in section 1 of the schema-evolution part of this resource is the right defense regardless: run it against every CDC table on a schedule, and alert when a column exists in Postgres but not in Iceberg — that catches the problem at job startup before any rows are silently dropped or any batches fail.

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

> **Cleanup recipe selection — pick the right tool before writing code.** Four cleanup shapes are documented below and in the "Idempotency and cleanup" section above. Picking the wrong one wastes hours of Spark runtime on a problem that could have been a 30-second metadata-only rollback, or — worse — picks `rollback_to_snapshot` for a too-old snapshot and corrupts good data committed since. Walk this matrix top-to-bottom; the first row whose condition is true is the right recipe for your incident:
>
> | Condition | Recipe | Why |
> |---|---|---|
> | **Bad snapshot still alive** (within `history.expire.max-snapshot-age-ms`, default 5 days; and `expire_snapshots` has not run on the affected snapshots since the bad commit) | `CALL system.rollback_to_snapshot(table => '...', snapshot_id => <pre-bad-snapshot-id>)` (Spark) or `CALL iceberg.system.rollback_to_snapshot(...)` from Trino | **Fastest path** — metadata-only commit, atomic, instantaneous. No data rewrite, no MinIO I/O. Use this whenever the prior snapshot still exists. See Case 3a below for the full procedure. |
> | **Bad snapshot expired** AND the affected partition is **small** (under ~10M rows, or fits comfortably in a single Spark stage) AND a Postgres source-of-truth read is cheap | **Spark only:** `INSERT OVERWRITE` (or `overwritePartitions()` from Spark DataFrame API) from the **deduplicated Postgres source**. `INSERT OVERWRITE` is **Spark SQL syntax — it does NOT exist in Trino 467**. In Trino, the equivalent partition-scoped overwrite is `DELETE FROM iceberg.analytics.events WHERE partition_key = 'value'` followed by `INSERT INTO iceberg.analytics.events SELECT ...` — two statements, not atomic together, so prefer the Spark `INSERT OVERWRITE` (atomic per-partition replacement) for this cleanup recipe. | The OVERWRITE atomically replaces the partition's contents with the clean ground-truth re-read. Simpler than MERGE — no `ON` clause, no LSN comparison, just "this is the correct content for this partition; replace what's there." See Case 3b below for the full procedure. |
> | **Bad snapshot expired** AND the affected partition is **huge** (100M+ rows, multi-hour Postgres re-read is unacceptable) | **Spark `MERGE INTO` with `ROW_NUMBER()` dedup** and an explicit `ON` clause that matches the natural key | The MERGE only touches rows whose key appears in the source delta — no full-partition re-read. Pre-dedup the source via `Window.partitionBy(PK).orderBy(source_lsn.desc()).row_number() == 1` so the source itself contains exactly one row per key. Slower per-affected-row than OVERWRITE, but the I/O scope is bounded by the duplicate set, not by the partition size. |
> | **No Postgres catalog mounted in Trino** (you cannot reference `postgres.public.events` from a Trino session — common when the production Trino cluster's Iceberg catalog is configured but the Postgres connector is not) | Two-step: **Spark JDBC** from Postgres PRIMARY into a **staging Iceberg table** (e.g., `iceberg.staging.events_dedupe_20260525`), then **Spark MERGE INTO** the production table from the staging table | Trino cannot read from Postgres directly without a configured catalog, so the read MUST happen in Spark. The staging table lets the MERGE source live in Iceberg (where both Spark and Trino can read it) and decouples the slow JDBC read from the fast metadata-only MERGE commit. Drop the staging table after the MERGE succeeds. |
>
> **Rule for selecting the recipe:** check whether the bad snapshot is still alive FIRST (`SELECT snapshot_id, committed_at FROM iceberg.analytics."events$snapshots" ORDER BY committed_at DESC LIMIT 20` — if the pre-bad row is present and not older than `history.expire.max-snapshot-age-ms`, use rollback). Only if rollback is unavailable, decide between OVERWRITE and MERGE based on partition size. Only consider the staging-table path if Trino cannot reach Postgres directly. Going straight to MERGE INTO when rollback would have worked is a common reason a 30-second incident becomes a 2-hour incident.

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

## dbt incremental models on Iceberg (dbt-trino adapter)

> **Adapter context for this whole section.** The production stack runs `dbt-trino` against Trino 467 with the Iceberg connector. **Every default and behavior below is dbt-trino-specific.** `dbt-spark` and `dbt-bigquery` have different defaults, different strategies, and different compiled SQL. Do NOT cross-reference dbt-spark blog posts when configuring dbt-trino models — the defaults are not the same.

### The watermark pattern with `is_incremental()`

dbt incremental models use a **watermark filter** on a timestamp column (typically `updated_at`) to detect which rows are new or changed since the last run. The pattern uses the `is_incremental()` Jinja macro:

```sql
{{ config(
    materialized='incremental',
    unique_key='order_id',
    incremental_strategy='merge',
    on_schema_change='append_new_columns'
) }}

SELECT order_id, customer_id, amount, status, updated_at
FROM {{ source('app', 'orders') }}
{% if is_incremental() %}
  WHERE updated_at > (SELECT COALESCE(MAX(updated_at), TIMESTAMP '1970-01-01') FROM {{ this }})
{% endif %}
```

On the **first run**, `is_incremental()` returns `false` and dbt runs the full SELECT to build the target table from scratch. On **subsequent runs**, it returns `true` and the watermark filter limits the scan to rows changed since the prior run's max timestamp.

**This is NOT automatic magic.** It requires the source table to have a timestamp column that the application maintains on every INSERT and UPDATE. If `updated_at` can be backdated by migrations or backfills, the incremental model will silently miss those rows — see the "Backdated `updated_at` and the watermark-monotonicity hole" section earlier in this document for the failure mode and the `xmin`-based fix.

### `incremental_strategy` on dbt-trino — the THREE valid strategies

> **CRITICAL — dbt-trino supports exactly three incremental strategies: `append`, `merge`, `delete+insert`.** A very common AI-generated mistake is to list `insert_overwrite` as a fourth option. **`insert_overwrite` is dbt-spark-only.** Setting `incremental_strategy='insert_overwrite'` on dbt-trino against an Iceberg target produces a compilation error — the adapter explicitly rejects it. If you want partition-level overwrite semantics on dbt-trino, use `delete+insert`, not `insert_overwrite`.

| Strategy | What dbt-trino compiles it to | When to use |
|---|---|---|
| **`append`** (default on dbt-trino) | `INSERT INTO target SELECT ... FROM source` — appends new rows; no dedup, no upsert | Immutable event/log tables where rows never change. **Wrong choice for any table with UPDATEs** — produces duplicates. |
| **`merge`** | `MERGE INTO target USING source ON unique_key WHEN MATCHED THEN UPDATE SET * WHEN NOT MATCHED THEN INSERT *` | Mutable dimension and fact tables (orders, subscriptions, user profiles). **Requires `unique_key`.** |
| **`delete+insert`** | Two-step: `DELETE FROM target WHERE <filter>` then `INSERT INTO target SELECT ...` | Full-partition reloads (e.g., "rebuild today's partition"); when you want explicit two-statement control instead of a single MERGE; also a fallback when MERGE performance is poor on a specific table. |

> **dbt-trino's default strategy is `append`, NOT `merge`.** This is the single most common dbt-trino misconfiguration. Engineers coming from dbt-snowflake or dbt-bigquery (where `merge` is the default on most warehouses) assume the same here. **It is not.** If you omit `incremental_strategy` from your dbt-trino model config, you get `append` semantics — every run inserts the new rows without checking `unique_key`, and any row that gets a second update will appear twice in the target. **Always set `incremental_strategy='merge'` explicitly** on any model where the source rows can change after first insert.

#### The compiled MERGE SQL — what dbt-trino actually generates

When you set `incremental_strategy='merge'` with `unique_key='order_id'`, dbt-trino compiles a MERGE statement that looks like this (simplified):

```sql
MERGE INTO iceberg.analytics.orders AS DBT_INTERNAL_DEST
USING (
    SELECT order_id, customer_id, amount, status, updated_at
    FROM iceberg.analytics.orders__dbt_tmp
) AS DBT_INTERNAL_SOURCE
ON (DBT_INTERNAL_SOURCE.order_id = DBT_INTERNAL_DEST.order_id)
WHEN MATCHED THEN UPDATE SET
    customer_id = DBT_INTERNAL_SOURCE.customer_id,
    amount      = DBT_INTERNAL_SOURCE.amount,
    status      = DBT_INTERNAL_SOURCE.status,
    updated_at  = DBT_INTERNAL_SOURCE.updated_at
WHEN NOT MATCHED THEN INSERT (order_id, customer_id, amount, status, updated_at)
VALUES (DBT_INTERNAL_SOURCE.order_id, DBT_INTERNAL_SOURCE.customer_id, ...);
```

> **CRITICAL — dbt's default MERGE has NO conditional predicate on the matched branch.** A very common AI-generated mistake is to claim dbt compiles `WHEN MATCHED AND s.updated_at > t.updated_at THEN UPDATE SET *`. **It does not.** The default is `WHEN MATCHED THEN UPDATE SET *` with **no condition** — every matched row is overwritten unconditionally, regardless of whether the source's `updated_at` is newer or older than the target's. If a stale row arrives from an out-of-order source, dbt will happily overwrite a fresher target row with the older values.
>
> **To add a target-side predicate, use the `incremental_predicates` config**, not a hand-written WHEN MATCHED filter:
>
> ```sql
> {{ config(
>     materialized='incremental',
>     unique_key='order_id',
>     incremental_strategy='merge',
>     incremental_predicates=[
>         "DBT_INTERNAL_DEST.updated_at < DBT_INTERNAL_SOURCE.updated_at"
>     ]
> ) }}
> ```
>
> `incremental_predicates` adds the listed conditions to the MERGE's `ON` clause (or as additional `AND ...` predicates depending on adapter version), so only target rows that satisfy the predicate participate in the UPDATE. This is the correct way to add "only update if source is newer" semantics, file-pruning hints (e.g., `DBT_INTERNAL_DEST.partition_date >= ...`), or any other target-side filter to a dbt-managed MERGE.

### `on_schema_change` — the FOUR options and the correct default

> **CRITICAL — the dbt default for `on_schema_change` is `ignore`, NOT `fail`.** Another very common AI-generated mistake is to claim `fail` is the default. **It is not.** If you do not set `on_schema_change` explicitly, dbt uses `ignore` semantics: any new column added to the source SELECT is **silently dropped** from the INSERT/UPDATE, never propagates to the target Iceberg table, and never appears in downstream queries. This is silent data loss for newly-added source columns.

| Value | Behavior on a new source column | Behavior on a removed source column |
|---|---|---|
| **`ignore`** (default) | New column is silently dropped from the insert/update. Target schema unchanged. No error. | Column persists in target with NULL for new rows. No error. |
| **`fail`** | dbt run errors out immediately, halting the pipeline. | dbt run errors out immediately. |
| **`append_new_columns`** | dbt issues `ALTER TABLE ... ADD COLUMN` against the Iceberg target, then runs the model. New column propagates and is populated. | Column persists in target with NULL for new rows (does not drop). |
| **`sync_all_columns`** | dbt adds new columns via `ALTER TABLE ... ADD COLUMN`. | dbt removes columns no longer in the model via `ALTER TABLE ... DROP COLUMN`. **Destructive — use with care.** |

**Recommended default for SaaS pipelines on dbt-trino + Iceberg: `on_schema_change='append_new_columns'`.** It auto-propagates new source columns to the target so dashboards see the new field on the next run, and it never drops columns (so a transient schema diff during a migration does not lose data). `sync_all_columns` is too aggressive for most pipelines because an accidental SELECT typo can drop a real column from the Iceberg target. `fail` is correct for contract-enforced models where any schema drift should halt the pipeline. `ignore` (the default) is rarely what you want — explicitly set the config.

### Late-arriving data in dbt incremental models — the correct Jinja syntax

A common pattern is to widen the incremental window so that rows arriving 3-5 days late are still picked up. The correct Jinja syntax uses `modules.datetime.timedelta`, not `macros.timedelta`:

```sql
{% if is_incremental() %}
  -- Widen the lookback window by 4 days to catch late-arriving events.
  WHERE updated_at > (
    SELECT COALESCE(MAX(updated_at), TIMESTAMP '1970-01-01') FROM {{ this }}
  )
  AND occurred_at >= TIMESTAMP '{{ (run_started_at - modules.datetime.timedelta(days=4)).isoformat() }}'
{% endif %}
```

> **CRITICAL — the correct Jinja module path is `modules.datetime.timedelta`, NOT `macros.timedelta`.** `macros` is a dbt namespace for user-defined and package macros — it has no `timedelta` attribute. Writing `{{ run_started_at - macros.timedelta(days=4) }}` fails at compile time with an `'undefined' has no attribute 'timedelta'` error. The correct path is `modules.datetime.timedelta(days=4)` — `modules.datetime` is dbt's pointer to Python's `datetime` module, which exposes `timedelta` directly. See the [dbt modules variable docs](https://docs.getdbt.com/reference/dbt-jinja-functions/modules) for the full list of Python modules dbt makes available in Jinja.

Combine the lookback with `incremental_strategy='merge'` so late-arriving rows that already exist in the target (because an earlier batch already inserted them with a stale value) get updated in place, not double-inserted.

### Rollback semantics — Trino vs Spark syntax

If a dbt run produces bad data and the prior Iceberg snapshot is still live, you can roll the table back. **The Trino syntax differs from Spark.** On the production stack (Trino 467 client + Spark batch jobs both touching the same Iceberg tables), use the right syntax for the engine your session is connected to.

**From Trino 467 (the supported form for dbt-trino post-hooks or operational rollback):**

```sql
-- Trino 467 supports this CALL form with positional arguments:
CALL iceberg.system.rollback_to_snapshot('analytics', 'orders', 4823511203987654321);

-- NOTE: the `ALTER TABLE iceberg.<schema>.<table> EXECUTE rollback_to_snapshot(snapshot_id => ...)`
-- table-procedure form was added in Trino 469 (Jan 2025) and does NOT exist on Trino 467.
-- See resource 17 for the full Trino-vs-Spark rollback syntax reference.
```

**From Spark (e.g., a spark-submit-driven rollback script):**

```sql
-- Spark uses named arguments:
CALL iceberg.system.rollback_to_snapshot(
    table => 'analytics.orders',
    snapshot_id => 4823511203987654321
);
```

> **Do not mix the two syntaxes.** Trino 467's `CALL` requires positional VARCHAR, VARCHAR, BIGINT arguments. Spark's `CALL` requires named arguments. Passing Spark-style named args to Trino's `CALL` (or vice versa) fails with a parse / argument-count error. See resource 17 ("Iceberg table maintenance") for the canonical Trino-vs-Spark rollback syntax cheat sheet.

### Copy-on-Write vs Merge-on-Read for dbt-managed Iceberg tables

When dbt-trino runs `MERGE INTO` on Iceberg, the physical write behavior depends on the table's write mode:

- **Copy-on-Write (CoW) — Iceberg 1.5.2 default.** Every matched row's containing Parquet file is rewritten; old files are orphaned (cleaned up by `remove_orphan_files`). Higher write cost, lower read cost (no delete files to merge at query time). **Best for daily / hourly dbt incremental batches** where the write window is bounded and readers are latency-sensitive.
- **Merge-on-Read (MoR) — must be enabled explicitly.** Updated rows are marked with small position-delete files; the original data files stay intact. Lower write cost, higher read cost (every scan merges data + delete files). **Best for high-frequency micro-batches** (many runs per hour) where the write cost dominates.

For daily / hourly dbt incremental models on this stack, **stick with the CoW default**. Switch to MoR only when the dbt run cadence drops below ~15 minutes and the table's write cost is the documented bottleneck.

### Iceberg-specific concerns for dbt incremental models

**Partition pruning on the incremental filter.** If the Iceberg target is partitioned by `day(updated_at)` and the watermark filter is on `updated_at`, Iceberg automatically prunes partitions — only the affected partition files are read. The dbt model does not need any extra config; pruning happens at the Iceberg layer.

**Small-file accumulation.** Frequent incremental runs (especially with `merge` and CoW) create many small Parquet files as Iceberg rewrites the files containing matched rows. **Schedule nightly compaction** via Trino's `ALTER TABLE ... EXECUTE optimize` or Spark's `CALL iceberg.system.rewrite_data_files`, or query performance degrades over weeks. See resource 17 for the full maintenance schedule.

**Snapshot accumulation.** Every dbt run creates at least one new Iceberg snapshot (the MERGE commit). Without `expire_snapshots` running weekly, the metadata layer balloons and read planning slows down. See resource 17.

### Reference: canonical dbt-trino incremental model on Iceberg

Copy-paste starting point for a mutable orders table:

```sql
{{ config(
    materialized='incremental',
    unique_key='order_id',
    incremental_strategy='merge',          -- REQUIRED — default is 'append' on dbt-trino
    on_schema_change='append_new_columns', -- REQUIRED — default is 'ignore' (silent data loss)
    file_format='iceberg',
    table_type='iceberg',
    partitioned_by=['day(updated_at)']
) }}

SELECT
    order_id,
    customer_id,
    amount,
    status,
    updated_at,
    occurred_at
FROM {{ source('app', 'orders') }}
{% if is_incremental() %}
  -- Watermark filter: only pull rows changed since the prior run.
  WHERE updated_at > (
    SELECT COALESCE(MAX(updated_at), TIMESTAMP '1970-01-01') FROM {{ this }}
  )
  -- Optional: widen lookback by 4 days for late-arriving events.
  -- Note `modules.datetime.timedelta`, NOT `macros.timedelta`.
  AND occurred_at >= TIMESTAMP '{{ (run_started_at - modules.datetime.timedelta(days=4)).isoformat() }}'
{% endif %}
```

**Configuration checklist before deploying any dbt-trino incremental model:**

1. **`incremental_strategy='merge'` (or `'delete+insert'`) is set explicitly** — never rely on the default, which is `append` and produces duplicates on mutable tables.
2. **`unique_key` is set** when using `merge` — without it, the MERGE join key is undefined and the model errors out.
3. **`on_schema_change='append_new_columns'`** (or `'sync_all_columns'` if you accept destructive column drops) — never rely on the default `ignore`, which silently drops new source columns.
4. **The watermark column (`updated_at`) is indexed in Postgres** if your source SELECT pushes the filter down — see "Postgres `updated_at` index preflight" earlier in this document.
5. **Compaction (`rewrite_data_files`) is scheduled** for the target Iceberg table — see resource 17.
6. **`expire_snapshots` is scheduled weekly** — see resource 17.

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
