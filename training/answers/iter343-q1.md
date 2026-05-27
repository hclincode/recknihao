# Answer to Q1: MERGE_CARDINALITY_VIOLATION — What It Is and How to Fix It (Iter 343)

`MERGE_CARDINALITY_VIOLATION` means your **source data has multiple rows matching the same target row**. It is not a schema problem or a bug in Spark itself — it's Iceberg telling you that your source delta contains duplicate primary keys.

## What the error means

Your MERGE INTO has an ON clause like `ON t.event_id = s.event_id`. When Iceberg executes the merge, it tries to match each source row to exactly one target row. If your source delta contains two rows with the same `event_id`, Iceberg finds 2 source rows pointing at 1 target row — a cardinality mismatch. It throws the error immediately at runtime and writes nothing. The full error message is:

```
MERGE_CARDINALITY_VIOLATION: Cannot perform Merge as multiple source rows matched a single target row
```

Grep your logs for `MERGE_CARDINALITY_VIOLATION` or `multiple source rows matched` — not "parse error."

## Why full refresh works but MERGE doesn't

Full refresh writes all rows fresh — no matching, no cardinality check. MERGE has the uniqueness constraint because it needs to know which single target row to update. When you switched to incremental MERGE, you exposed a duplicate-PK problem in your source delta that full refresh silently tolerated.

## Most common causes (in order of likelihood)

**1. Overlap-window incremental reads (most common)**
Your incremental query reads `WHERE updated_at > last_checkpoint - LAG_BUFFER`. This intentionally re-reads a small window for late-arriving rows. If the same row was updated near the boundary, it appears in both the current batch and the previous batch's overlap — sending two copies of the same primary key into your source delta.

**2. Multiple CDC events for one row**
If you're reading from a change-data-capture stream, Postgres emits a separate event for every UPDATE to a row. If the same row was updated twice within a single micro-batch window, both events land in your source delta with the same primary key.

**3. Actual duplicates in Postgres source**
Rare, but possible if the source table lacks a primary key constraint.

## The fix: source-side dedup before MERGE

Deduplicate your source delta to keep only the latest row per primary key, then run MERGE:

```python
from pyspark.sql import functions as F
from pyspark.sql.window import Window

# Keep only the most recent row per event_id
latest_per_pk = Window.partitionBy("event_id").orderBy(F.col("updated_at").desc())
deduped = (
    source_delta
    .withColumn("_rn", F.row_number().over(latest_per_pk))
    .filter(F.col("_rn") == 1)
    .drop("_rn")
)
deduped.createOrReplaceTempView("events_delta")

# MERGE with deduplicated source
spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_delta AS s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

`partitionBy("event_id")` groups all rows with the same primary key. `orderBy(updated_at DESC)` ranks newest first. `row_number() == 1` keeps one row per key — the most recent. If your tiebreaker is a CDC log sequence number (LSN) or Kafka offset rather than `updated_at`, order by that instead for more reliable deduplication.

## Diagnosing which cause applies

Check your job logs for the duplicated event_id:
- **Same event_id, different `updated_at`** → overlap-window issue; the lag buffer caused a re-read
- **Same event_id, same `updated_at`, different other values** → CDC duplicate (two UPDATE events in one batch)
- **Completely identical rows** → actual Postgres duplicate

In all three cases, the dedup recipe above fixes it by keeping only one copy per primary key before the MERGE runs.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
