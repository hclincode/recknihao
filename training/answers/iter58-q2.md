# Iter58 Q2 — Answer

**Question**: Our events table in Iceberg is already partitioned by date. Every night we want to reload the previous day's partition from Postgres — partly to catch late-arriving events and partly because some rows get corrected after the fact. We just read about the staging-table-swap pattern for zero-downtime reloads, but that seems like a lot of extra plumbing when we only want to replace one day's worth of data, not the whole table. Someone mentioned `overwritePartitions()` can atomically replace just one partition without touching the rest. Is that simpler approach the right call here, or is there a catch we're not seeing?

---

## Answer

Yes, `overwritePartitions()` is simpler and the right call for your use case — *if* you're careful about one critical trap. If the DataFrame contains every row that should exist for that day (a full re-read from Postgres), it's safe and idiomatic. If the DataFrame contains only incremental changes (a few late-arriving rows), you will silently wipe the rest of that day's data with no error raised.

### How `overwritePartitions()` works

When you call `overwritePartitions()` on Iceberg, you're saying: "Replace only the partitions that appear in this DataFrame." Iceberg atomically commits the change as a single snapshot. Any reader will see either the old version of that partition or the new fully-written version — never a partial state in the middle. This atomicity is the whole point: no view swap, no staging table needed.

For a table already partitioned by date (like yours, with `day(event_date)`):

```python
# Atomic overwrite of May 24's partition — no staging table needed.
# Readers see either the old May 24 partition or the fully-written new one.
df_for_date = df.filter(col("event_date") == "2026-05-24")
df_for_date.writeTo("iceberg.analytics.events").overwritePartitions()
```

This is simpler than the staging-table-swap pattern (no extra table to manage), faster (one write, not two), and the idiomatic Iceberg way to do partition-scoped refreshes.

### The critical data-loss trap: incremental delta problem

**`overwritePartitions()` replaces the ENTIRE partition with whatever rows are in your DataFrame.** If the DataFrame contains only the incremental delta (a few rows that arrived late today), Iceberg will atomically replace the entire day's partition with just those rows, discarding thousands of legitimate rows that were there before. No error is raised — the failure is silent.

The concrete timeline of this disaster:

1. **May 20**: nightly job ingests all of May 20's events. The partition now contains 8,432 events.
2. **May 23**: a mobile app reconnects and sends 12 events dated May 20 (`occurred_at = May 20`, `updated_at = May 23`).
3. **May 23 nightly job**: watermark filter `WHERE updated_at > last_watermark` pulls exactly those 12 late rows into the DataFrame.
4. **`overwritePartitions()` runs**: Iceberg replaces the entire May 20 partition with the 12 rows, silently discarding the 8,432 rows that were there before.
5. **Tuesday morning**: analyst notices May 20's funnel dropped from 8,432 to 12.

### How to avoid the trap: re-read the full partition

Before calling `overwritePartitions()`, expand the DataFrame to contain **every row that should exist in that partition** — a full re-read from Postgres, not just the delta:

```python
# Identify which days were touched by late arrivals
delta_df = read_postgres_delta(last_ts)
affected_days = [r.day for r in delta_df.selectExpr(
    "date_trunc('day', occurred_at) AS day"
).distinct().collect()]

# Re-read every row from Postgres for those days (not just the delta)
day_filter = " OR ".join(f"date(occurred_at) = '{d}'" for d in affected_days)
full_partition_df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE {day_filter}) t",
    properties=PG_PROPS,
)

# overwritePartitions() with the COMPLETE partition contents
full_partition_df.writeTo("iceberg.analytics.events").overwritePartitions()
```

Now the partition contains all 8,432 + 12 rows because the DataFrame is a full re-read.

### Alternative: MERGE INTO if late arrivals are frequent

If full-partition re-reads feel expensive, use `MERGE INTO` instead:

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

MERGE INTO only modifies rows matched by the join key, leaving all other rows intact. The 12 late rows are inserted; the 8,432 existing rows are untouched. Trade-off: MERGE INTO writes delete files that slow queries until the next compaction.

### When the staging-table-swap is still needed

Keep staging-table-swap for these cases:
- **The table is unpartitioned** — no partition key to scope the overwrite
- **The reload spans many partitions** (full historical rebuild) — one staging table + one view swap is faster than hundreds of `overwritePartitions()` calls
- **You need end-to-end validation before readers see it** — staging-table-swap lets you validate against the staging table before the view swap commits

For your use case (one day's partition reload every night), none of these apply.

### Idempotency: safe on retry

`overwritePartitions()` is idempotent — if the Kubernetes job restarts for the same `batch_date`, re-running produces exactly the same result:

```python
batch_date = "2026-05-22"  # passed as a CLI argument
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE date(occurred_at) = '{batch_date}') t",
    properties=PG_PROPS,
)
df.writeTo("iceberg.analytics.events").overwritePartitions()
```

Contrast with `append()`: re-running doubles your event counts.

### Why `createOrReplace()` must not be used here

`createOrReplace()` drops and recreates the **entire table**, wiping every other partition — not just the one day you wanted to reload. Never use `createOrReplace()` for partition-scoped refreshes.

### Summary

Use `overwritePartitions()` for your nightly partition reload — simpler, faster, and idiomatic. The critical requirement: re-read the full partition from Postgres (every row for that day), not just the incremental delta. If late arrivals are frequent and full-partition re-reads feel burdensome, switch to `MERGE INTO` instead.
