# Answer to Q2: JSONB Column Ingestion into Iceberg (Iter 324)

## The Core Problem

Parquet stores JSON as an opaque string with no per-field indexing or statistics. When you filter `WHERE plan_tier = 'premium'`, Trino must re-parse every row's JSON blob at query time — no file skipping, no column statistics. That's the "dashboard killer" pattern for JSONB stored as-is.

## Option 1: Keep as VARCHAR, Query with JSON Functions (Simplest, Slowest)

```sql
SELECT JSON_VALUE(details, '$.plan_tier' RETURNING varchar NULL ON EMPTY NULL ON ERROR) AS plan_tier,
       COUNT(*) AS count
FROM iceberg.analytics.events
WHERE occurred_at >= DATE '2026-01-01'
GROUP BY 1;
```

Or the simpler form (silently returns NULL for missing keys and malformed JSON):
```sql
SELECT json_extract_scalar(details, '$.plan_tier') AS plan_tier
FROM iceberg.analytics.events;
```

**When it's fine:** Ad-hoc exploration, low query volume, schema flexibility matters more than performance.

**When it fails:** Interactive dashboards with frequent queries over millions of rows — Trino parses the JSON string on every row, every time.

## Option 2: Flatten Hot Fields into Real Columns (Recommended for Dashboards)

In your Spark ingestion job, extract the top fields into typed columns before writing to Iceberg:

```python
from pyspark.sql.functions import get_json_object

df = df.withColumn("plan_tier",     get_json_object("details", "$.plan_tier")) \
       .withColumn("feature_flags", get_json_object("details", "$.feature_flags")) \
       .withColumn("region",        get_json_object("details", "$.region")) \
       .withColumnRenamed("details", "details_raw")
```

Then in Trino:
```sql
SELECT plan_tier, region, COUNT(*)
FROM iceberg.analytics.events
WHERE plan_tier = 'premium' AND region = 'us-west'
GROUP BY 1, 2;
```

**Why this works:** `plan_tier` becomes a real Parquet column with min/max statistics. Trino can skip entire file row-groups that don't contain `'premium'` — often scanning <5% of files for a selective filter. That's the difference between sub-second and 30-second dashboard queries.

## The Decision Rule

**Flatten anything you `GROUP BY`, `WHERE`, or `JOIN ON`. Leave the rest in `details_raw`.**

For your case: `plan_tier`, `feature_flags`, `region` → extract as columns. Everything else in the JSON → keep as `details_raw VARCHAR` for archive/debugging.

## Adding New Fields Later

If customers later need to filter on a field that wasn't in the original extraction:

**Path A — forward-only (recommended):** `ALTER TABLE iceberg.analytics.events ADD COLUMN billing_cycle VARCHAR` (metadata-only, instant), then extract it in your Spark job going forward. Historical rows return NULL for the new column — usually acceptable for analytics.

**Path B — with backfill:** Write a one-time Spark job that reads old rows from Iceberg, extracts the new field, and overwrites them. Use `COALESCE(billing_cycle, json_extract_scalar(details_raw, '$.billing_cycle'))` during the transition window so dashboards keep working while the backfill runs.

## Summary

| Approach | Query performance | Ingest complexity | Schema flexibility |
|---|---|---|---|
| Store as VARCHAR, use JSON_VALUE | Slow (full JSON parse per row) | None — no changes needed | High |
| Flatten hot fields to columns | Fast (column stats + file skipping) | Add get_json_object calls to Spark job | Requires ALTER TABLE for new fields |

For your use case (customer dashboards filtering on `plan_tier`, `region`, `feature_flags`), flatten those fields now. Keep `details_raw` for the rest.
