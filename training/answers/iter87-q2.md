# Iter87 Q2 — Answer

**Question**: New Postgres table just launched, essentially empty. Can I skip the full-load step and start CDC/watermark incremental pipeline from "now"? Will Iceberg or CDC tooling get confused?

---

## Answer

**Yes, you can absolutely skip the formal full-load step for a new, nearly-empty table.** The full-load step exists as a backfill convenience for tables with historical data — not as a technical requirement. Iceberg and CDC tooling have no dependency on a pre-existing baseline snapshot.

### What the Incremental Pipeline Actually Needs

When you launch an incremental or CDC pipeline, it needs exactly one thing: **a starting point** — a watermark timestamp or a Postgres WAL log sequence number (LSN). Not a pre-populated Iceberg table.

For a watermark-based pipeline (using `updated_at`), the starting watermark is just a timestamp:

```python
last_ts = "2026-05-25 14:30:00"  # "start from now"
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM new_table WHERE updated_at > '{last_ts}') t",
    properties=PG_PROPS,
)
```

For a CDC pipeline (Debezium), you specify a starting LSN — Debezium reads the Postgres WAL from that position onward.

The Iceberg table can be created empty on the first run:

```sql
CREATE TABLE iceberg.analytics.new_table (...) USING iceberg PARTITIONED BY (day(created_at));
```

Your incremental job fills it in as data arrives. No cold-start problem. Iceberg doesn't know or care that the table was empty — it just appends new rows.

### The One Real Risk: Rows Inserted Before Your Start Point

There is exactly one hazard: **any rows inserted into Postgres before you activate the pipeline will be missed.** They're not in Iceberg, and the incremental pipeline will never pick them up because it only reads rows after its starting watermark.

Handle this based on how many "before" rows actually exist:

**Option 1: Quick bootstrap of the few existing rows (recommended).** If a handful of rows exist already, do a one-time full load in seconds:

```python
# Bootstrap — grab everything that currently exists
bootstrap_df = spark.read.jdbc(url=PG_URL, table="public.new_table", properties=PG_PROPS)
bootstrap_df.writeTo("iceberg.analytics.new_table").createOrReplace()

# Set watermark to max(updated_at) of what we just loaded
max_ts = bootstrap_df.agg({"updated_at": "max"}).collect()[0][0]
write_watermark("new_table", max_ts)
# Now launch incremental pipeline — it picks up from here
```

This takes seconds for a small table. You get the few existing rows plus continuous incremental from there. No gaps.

**Option 2: Start from now, accept the pre-pipeline rows are not synced.** If you're certain the table truly has no meaningful data before your start time, just set the watermark to now and document the gap:

```python
write_watermark("new_table", "2026-05-25 14:30:00")
# First incremental run picks up everything inserted after this timestamp
```

This is only appropriate if:
- You confirm with the application team that no production data existed before your start time.
- No audit or compliance requirement forces you to backfill.
- Your analytics team is aware that data before the start date isn't in the lake.

### Why the Full-Load Step Exists (and Why You Don't Need It Here)

The "full load first, then incremental" pattern exists for **already-populated tables with years of history**. For a 500M-row events table covering 3 years, doing a full JDBC snapshot into Iceberg is faster and cleaner than trying to set a watermark at the beginning of time — the incremental pipeline would take months to catch up row by row.

For a table that was born after your pipeline design, the full-load ceremony is unnecessary. The incremental pipeline builds the Iceberg table from scratch, row by row, as data arrives. That's the whole point of the incremental model.

### The "Will Iceberg Get Confused" Question

No. Iceberg doesn't track the relationship between an Iceberg table and its Postgres source. It just sees rows being appended. There's no concept of "baseline snapshot required before incremental writes." Your MERGE INTO or append writes the same way whether the table was pre-populated or empty.

For Debezium CDC: Debezium doesn't care about the Iceberg table's state at all. It reads the Postgres WAL from your start LSN and emits change events (`c`, `u`, `d`). Your Spark streaming consumer materializes those events into Iceberg. Starting fresh from a given LSN is the normal operating mode — there's nothing special about starting from "now."

### Practical Checklist

1. **Create the Iceberg table** (metadata-only, instant).
2. **Decide**: bootstrap the few existing rows (Option 1) or accept they're not synced (Option 2).
3. **Set your watermark** to the current timestamp or the max from your bootstrap.
4. **Start the incremental pipeline** — it appends rows as they arrive.
5. **Verify** after the first few runs: `SELECT COUNT(*) FROM iceberg.analytics.new_table` should grow as Postgres inserts arrive.

The full-load step is not magic. For a brand-new table, skip it and start incrementally.
