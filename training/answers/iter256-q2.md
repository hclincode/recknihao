# Iter256 Q2 — Federated INSERT INTO Iceberg from Postgres+Iceberg Join

## Answer

Yes, Trino **absolutely supports** writing to an Iceberg table via INSERT INTO while reading from PostgreSQL and Iceberg in the same statement. This is a core federation pattern called a **cross-catalog write**, and it's exactly what your dashboard caching use case calls for.

### The Short Answer: Your Exact Query Will Work

```sql
INSERT INTO iceberg.analytics.monthly_summaries (account_id, month, event_count, last_updated)
SELECT a.account_id, DATE_TRUNC('month', e.occurred_at) AS month, COUNT(*) AS event_count, NOW() AS last_updated
FROM app_pg.public.accounts a
JOIN iceberg.raw_events.usage_events e ON a.id = e.account_id
WHERE e.occurred_at > DATE '2026-05-26'  -- high-watermark: only new events since last run
GROUP BY a.account_id, DATE_TRUNC('month', e.occurred_at);
```

This single statement reads from both PostgreSQL (`app_pg`) and Iceberg (`iceberg`) catalogs, joins them on Trino's workers, and writes the result as new rows into an existing Iceberg table — all in one atomic operation. No intermediate steps outside Trino needed.

### The Three-Phase Lifecycle: What Actually Happens Inside

**Phase 1: Query Start — HMS (Hive Metastore) Registers Intent**

Before Trino reads even one row from PostgreSQL, it calls Hive Metastore to register the write intent against your target Iceberg table. This sets up the partition metadata, file layout, and target column schema. If HMS is unreachable at this moment, **the INSERT fails immediately** — no rows have been read, no files have been written, nothing to clean up. This is a clean, safe failure.

**Phase 2: SELECT Execution — Parquet Files Are Written, but Invisible**

Trino reads rows from PostgreSQL (with predicate pushdown), reads rows from Iceberg's relevant partitions, joins them on Trino workers, and streams the result rows as Parquet files to object storage.

**The key detail**: These Parquet files are written to storage but **no reader can see them yet**. Iceberg readers consult a manifest list pointed to by a `metadata_location` pointer — that pointer still references the **pre-INSERT snapshot**. Your new files are completely invisible. This is how Iceberg guarantees atomicity: no reader can see a half-loaded table mid-INSERT.

**Phase 3: Commit — HMS Atomically Swaps the Metadata Pointer**

Once the SELECT completes successfully, Trino calls HMS one final time to perform an atomic metadata swap. It updates the table's `metadata_location` pointer to a new metadata file that includes the just-written manifest. **This is the instant new rows become visible.** All concurrent readers see the new snapshot on their next query. The transition is atomic — there is no in-between state.

### Failure Modes and Orphan File Cleanup

**Scenario A: SELECT fails mid-way** (PostgreSQL goes away, Trino worker OOMs, network drops)

The commit at Phase 3 never happens. The metadata pointer stays pointing at the pre-INSERT snapshot. Readers see nothing new — the table is safe. **However**, Parquet files already written to storage remain as **orphan files** — bytes on disk that no manifest references, consuming storage but invisible to queries.

Clean them up with:

```sql
ALTER TABLE iceberg.analytics.monthly_summaries 
EXECUTE remove_orphan_files(retention_threshold => '7d');
```

This removes files older than 7 days (Trino enforces a 7-day minimum retention floor to prevent races with slow concurrent readers).

**Scenario B: HMS dies before commit** — same outcome; pre-INSERT snapshot remains visible, orphan files need cleanup.

**Key guarantee**: No partial commit is possible. Either all new rows are visible (commit succeeded) or zero are. No in-between state.

### Column Type Compatibility Between PostgreSQL and Iceberg

| PostgreSQL source | Compatible Iceberg target |
|---|---|
| `INTEGER`, `BIGINT`, `SMALLINT` | `INTEGER`, `BIGINT` |
| `NUMERIC(p, s)` | `DECIMAL(p, s)` — precision and scale must match exactly |
| `TEXT`, `VARCHAR(n)` | `VARCHAR` (Iceberg VARCHAR has no length limit) |
| `BOOLEAN` | `BOOLEAN` |
| `DATE` | `DATE` |
| `TIMESTAMP` (no TZ) | `TIMESTAMP(6)` |
| `TIMESTAMPTZ` | `TIMESTAMP(6) WITH TIME ZONE` |
| `UUID` | `UUID` |
| `JSONB` | `VARCHAR` only — Iceberg has no native JSON type |
| `BYTEA` | `VARBINARY` |
| PostgreSQL `ENUM` | `VARCHAR` only — you lose the constraint, string value transfers |

**Type mismatches are caught at planning time** (before any data is written). If Trino says "Cannot cast type X to Y," fix with an explicit cast in the SELECT:

```sql
INSERT INTO iceberg.monthly_summaries (my_json_field)
SELECT CAST(jsonb_field AS VARCHAR)
FROM app_pg.public.source_table;
```

### The Incremental Refresh Pattern: Idempotent High-Watermark Ingestion

For your use case — re-running the same query hourly to cache fresh summaries — use a **high-watermark** filter:

```sql
WITH watermark AS (
  SELECT COALESCE(MAX(last_updated), TIMESTAMP '1970-01-01 00:00:00') AS hwm
  FROM iceberg.analytics.monthly_summaries
)
INSERT INTO iceberg.analytics.monthly_summaries (account_id, month, event_count, last_updated)
SELECT a.account_id, 
       DATE_TRUNC('month', e.occurred_at) AS month, 
       COUNT(*) AS event_count, 
       CURRENT_TIMESTAMP AS last_updated
FROM app_pg.public.accounts a
JOIN iceberg.raw_events.usage_events e ON a.id = e.account_id, watermark
WHERE e.occurred_at > watermark.hwm
  AND e.occurred_at <= TIMESTAMP '2026-05-27 12:00:00';  -- pin the upper bound
```

**Why the explicit upper bound matters**: Without it, a re-run after partial failure pulls in even newer rows than the first attempt, drifting the window semantics. Pin the upper bound to a fixed timestamp the caller computes externally, and retry-safety is guaranteed.

### When This Approach is NOT the Right Tool

**1. Very large batches (> 5 million rows per INSERT)**

Trino has no resume-from-failure for federated INSERT. A 30-minute INSERT that fails at minute 25 restarts from zero, with 25 minutes of orphan files to clean. Above ~5M rows, use Spark with checkpointing or a CDC pipeline (Debezium) that has state management and can resume mid-batch.

**2. Source data with UPDATEs or DELETEs**

The high-watermark pattern only catches new rows appended to PostgreSQL. If existing rows are updated or deleted, those changes remain invisible. For mutable source data, either use a full-refresh CTAS nightly, implement Debezium CDC, or use a dbt incremental model with `unique_key` logic.

**3. Strict exactly-once semantics across multiple target tables**

Trino's INSERT is per-table atomic (all-or-nothing for one table), **not** cross-table atomic. If you need "insert into table A and table B both succeed or both roll back," materialize into a staging table first, then have your application perform the swap.

### Summary

Your expensive join query can become a cached Iceberg table refreshed via federated INSERT. Run it once a day or every few hours:

```sql
INSERT INTO iceberg.analytics.dashboard_summary
SELECT <your join query> WHERE <high-watermark filter>;
```

The dashboards then query the summary table directly — a simple scan that returns pre-aggregated rows in milliseconds instead of running the expensive join repeatedly. If the INSERT fails partway through, orphans clean up after 7 days, and re-running the same statement is safe because of the watermark filter.
