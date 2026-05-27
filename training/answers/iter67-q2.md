# Iter67 Q2 — Answer

**Question**: We run a nightly incremental load from Postgres into Iceberg. It works by tracking the last run's timestamp and only pulling rows where updated_at is newer than that watermark. It's been working fine for months, but we just did a big data migration on the Postgres side where someone backfilled and corrected records — and they set updated_at to the original dates from years ago, not to today. Now our incremental job ran and didn't pick up any of those corrected rows, because their updated_at is older than our watermark. We basically have stale or wrong data sitting in Iceberg now. What's the right way to handle this? Do we have to do a full reload every time something like this happens, or is there a smarter pattern so this kind of backdated update doesn't silently fall through?

---

## Answer

You've hit a structural limitation of timestamp-based watermarking — not a bug in your pipeline. The pattern works by trusting that `updated_at` reflects when a row actually changed, and a data migration that backdates those timestamps breaks that trust silently. Here's how to fix the immediate problem and make the pipeline more resilient going forward.

### Why the watermark failed silently

Your incremental job runs `WHERE updated_at > last_watermark`. The backfilled rows have `updated_at` set to years-old dates — so they're older than your watermark, the query filter skips them, and nothing in the pipeline errors. From the pipeline's perspective the job succeeded. This is the fundamental weakness of `updated_at`-based watermarking: the column is application-controlled, and any process that writes a historical timestamp without setting `updated_at = now()` becomes invisible to the incremental load.

### Immediate fix: repair the stale data in Iceberg

You have two options depending on whether you know the affected date range.

**Option A: Targeted backfill for a known date range**

If the migration team knows which records were corrected (e.g., "rows with `created_at` between March 15–22"), re-read that exact range from Postgres and merge into Iceberg:

```python
# One-shot backfill — run once via spark-submit, then discard
backfill_df = spark.read.jdbc(
    url=PG_URL,
    table="""(
        SELECT * FROM events
        WHERE date(created_at) BETWEEN '2026-03-15' AND '2026-03-22'
    ) t""",
    properties=PG_PROPS,
)

backfill_df.createOrReplaceTempView("events_backfill")

spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_backfill AS s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

Use `MERGE INTO` rather than `overwritePartitions()`. If you overwrite entire day partitions with only the backfill data, you'll wipe out rows that arrived via normal incremental runs after the partition date. MERGE safely updates stale rows and leaves legitimate rows intact.

**Option B: Full table reload (if the affected range is unknown)**

If the migration team is still finding records to correct, or you don't trust the date range:

```python
full_df = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT * FROM events) t",
    properties=PG_PROPS,
)

full_df.createOrReplaceTempView("events_full")

spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_full AS s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")

# Reset the watermark to the actual max updated_at after the reload
new_watermark = full_df.agg({"updated_at": "max"}).collect()[0][0]
write_watermark("events", new_watermark)
```

After either repair, spot-check in Trino:

```sql
SELECT event_id, updated_at, corrected_field
FROM iceberg.analytics.events
WHERE event_id IN ('known-corrected-id-1', 'known-corrected-id-2');
```

### Preventing this from happening again: three patterns

#### Pattern A: Lookback window (recommended starting point)

Instead of always reading from exactly `last_watermark`, re-read a window of overlap — say, 4 hours behind the watermark — on every run:

```python
from datetime import timedelta

last_ts = read_watermark("events")
lookback_ts = last_ts - timedelta(hours=4)

df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE updated_at > '{lookback_ts}') t",
    properties=PG_PROPS,
)

df.createOrReplaceTempView("events_delta")
spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_delta AS s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")

# Advance watermark conservatively (keep 2-hour overlap for the next run)
new_ts = df.agg({"updated_at": "max"}).collect()[0][0]
safe_watermark = new_ts - timedelta(hours=2)
write_watermark("events", safe_watermark)
```

**What this catches**: Any backdated update that lands within 4 hours of when it was actually written. For operational corrections and most migrations, this is sufficient.

**What this misses**: Updates backdated more than 4 hours (like your years-ago scenario). For those, you still need a manual backfill or Pattern C below.

**Cost**: Re-reads 4 hours of Postgres data every night — trivial for tables with indexes on `updated_at`. Use MERGE INTO so re-reading the overlap window produces no duplicates.

**Calibrating the window**: Set it longer than your observed replica lag (if reading from a replica) plus your typical migration correction window. For most teams, 4–24 hours covers the common cases.

#### Pattern B: Use `xmin` instead of `updated_at`

Postgres's `xmin` system column records the transaction ID of the last write to a row. Unlike `updated_at`, it's **set by Postgres at the transaction level** — no application can backdate it. A migration that updates a row will always bump `xmin`, even if `updated_at` is set to a historical value.

```python
last_xmin = read_watermark("events")  # store xmin as a large integer

df = spark.read.jdbc(
    url=PG_URL,
    table=f"""(
        SELECT *, xmin::text::bigint AS xmin_value
        FROM events
        WHERE xmin::text::bigint > {last_xmin}
    ) t""",
    properties=PG_PROPS,
)

df.createOrReplaceTempView("events_delta")
spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_delta AS s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")

new_xmin = df.agg({"xmin_value": "max"}).collect()[0][0]
write_watermark("events", new_xmin)
```

**What this catches**: Every write that Postgres actually committed, regardless of the `updated_at` value set by the application. Your years-ago backfill scenario would have been caught automatically.

**Tradeoff**: `xmin` wraps around at ~4 billion transactions (the 32-bit transaction counter). On a very high-write Postgres instance, this could happen in years — but most teams never hit it. The bigger issue is that `xmin` is not replication-safe across Postgres versions (pg_upgrade can reset it). Use it only on the primary or a stable replica. Also requires reading a Postgres system column, which is non-standard but works fine with JDBC.

#### Pattern C: Periodic full reconciliation

Keep your nightly incremental load unchanged and add a weekly reconciliation job that finds and fixes any mismatches between Postgres and Iceberg:

```python
# Run weekly (e.g., Sunday 3 AM). This is the safety net, not the primary pipeline.

# Compare max(updated_at) per row between Postgres and Iceberg
pg_summary = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT event_id, MAX(updated_at) AS pg_updated_at FROM events GROUP BY event_id) t",
    properties=PG_PROPS,
)

iceberg_summary = spark.sql(
    "SELECT event_id, MAX(updated_at) AS ib_updated_at FROM iceberg.analytics.events GROUP BY event_id"
)

stale = (
    pg_summary.alias("pg")
    .join(iceberg_summary.alias("ib"), on="event_id", how="left_outer")
    .filter("pg.pg_updated_at > COALESCE(ib.ib_updated_at, CAST('1970-01-01' AS TIMESTAMP))")
)

stale_count = stale.count()
if stale_count > 0:
    affected_ids = [r.event_id for r in stale.select("event_id").collect()]
    ids_csv = "', '".join(affected_ids)
    fix_df = spark.read.jdbc(
        url=PG_URL,
        table=f"(SELECT * FROM events WHERE event_id IN ('{ids_csv}')) t",
        properties=PG_PROPS,
    )
    fix_df.createOrReplaceTempView("events_fix")
    spark.sql("""
        MERGE INTO iceberg.analytics.events AS t
        USING events_fix AS s
        ON t.event_id = s.event_id
        WHEN MATCHED THEN UPDATE SET *
        WHEN NOT MATCHED THEN INSERT *
    """)
    print(f"Reconciliation fixed {stale_count} stale rows")
```

**What this catches**: Everything — any drift between Postgres and Iceberg, regardless of how old the backdated timestamp is.

**Cost**: Weekly full table scan of Postgres (expensive for 500M-row tables). Not suitable as your primary ingestion loop; intended as a weekly audit and repair job.

### Comparison

| Pattern | Catches backdates outside window | Cost per run | Complexity |
|---|---|---|---|
| Lookback window (A) | Only within lookback (e.g., 4 hours) | Low | Low — minimal change to existing job |
| xmin-based watermark (B) | Always | Low (same as updated_at) | Medium — watermark type changes to integer |
| Weekly reconciliation (C) | Always | High (weekly full scan) | Medium — separate job |

**Recommendation**: Start with **Pattern A** — add a 4-hour lookback window to your existing job and switch to `MERGE INTO`. This catches operational corrections and most migration scenarios with minimal risk. Add **Pattern C** as a weekly safety net if your business cannot tolerate any risk of drift. Upgrade to **Pattern B** only if backdated updates are a recurring pattern driven by how your application manages data.

### The general rule

Whenever Postgres source data is modified by a process you don't control (external migrations, bulk corrections, vendor ETL), assume `updated_at` cannot be trusted. Either expand your lookback window before that migration runs, or run a targeted backfill after it completes. The pipeline cannot detect what it doesn't query for.
