# Answer to Q2: Why Typed Column Filters Are Fast but JSON Filters Scan Everything (Iter 307)

## The Short Answer

**Typed columns have min/max statistics that let Iceberg skip entire Parquet files; JSON-as-string columns don't.** When you filter `WHERE customer_id = 'abc123'`, Iceberg reads a tiny metadata index and skips 99% of files before opening them. When you filter on a value inside a JSON string, there are no useful statistics — Iceberg must open and read every file.

## How Parquet Encodes Typed Columns

In your MinIO Parquet files, every column in every row group stores two types of statistics:

**1. Min/max bounds:** the smallest and largest value seen in that column chunk. For `customer_id`:
```
Row group 1: min='aaa001', max='abc500'  → 'abc123' might be here → read it
Row group 2: min='abc501', max='abd999'  → 'abc123' not in range  → SKIP
Row group 3: min='xyz000', max='zzz999'  → 'abc123' not in range  → SKIP
```
On a large table, most row groups are skipped without opening them.

**2. Dictionary encoding** for low-cardinality columns: if a column has only a few distinct values (e.g., 5 plan types), Parquet replaces string values with integers referencing a tiny lookup table:
```
Dictionary: {0→"free", 1→"pro", 2→"enterprise"}
Stored: [0, 1, 0, 2, 1, ...]  (integers, not strings)
```
This compresses the column by 5–10x and makes equality filters extremely fast.

## Why JSON-as-String Defeats File Skipping

When you store JSON as a raw VARCHAR column:
```sql
json_col VARCHAR  -- e.g., '{"plan":"pro","user":"alice","event":"click"}'
```

Parquet sees it as an opaque string. The min/max it records is the **byte-order range of the whole JSON text**:
```
Row group 1: min='{"a...', max='{"z...'
```

These bounds are useless for queries on JSON contents. A JSON string containing `"plan":"enterprise"` could have any min/max at the byte level — the value `enterprise` might appear in the middle of the string, and Parquet has no way to encode that. So:

- `WHERE json_col LIKE '%enterprise%'` — Iceberg can't skip any row groups; every file opens
- `WHERE json_extract_scalar(json_col, '$.plan') = 'enterprise'` — same problem; Trino must read every row, deserialize JSON, walk the tree, extract the field, and compare

This is why your JSON filter scans "the whole table" — it literally does.

## The Three-Level Skipping Cascade

Your production stack uses this hierarchy:

**Level 1 — Iceberg manifest pruning:** Trino reads a manifest metadata file listing all Parquet files and their per-column min/max. Files whose range excludes the filter are never opened from MinIO. This is the biggest win.

**Level 2 — Row-group pruning:** Within an opened Parquet file, Trino checks each row group's statistics and skips chunks where the filter value is out of range.

**Level 3 — Column projection:** Only the columns you SELECT are decompressed and read from disk — Parquet's columnar layout means unneeded columns stay on disk.

For `customer_id = 'abc123'`: all three levels fire. For `json_col LIKE '%...'`: only Level 3 fires (and even that only helps if you don't SELECT *).

## The Fix: Promote Hot JSON Fields to Typed Top-Level Columns

Extract frequently-queried JSON keys at write time and store them as real typed columns. This is called the "two-tier schema" pattern.

**Before:**
```sql
CREATE TABLE iceberg.analytics.events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  occurred_at TIMESTAMP(6),
  properties  VARCHAR   -- '{"plan":"pro","country":"US","event":"click"}'
);
```

**After (two-tier):**
```sql
CREATE TABLE iceberg.analytics.events (
  event_id    VARCHAR,
  tenant_id   VARCHAR,
  occurred_at TIMESTAMP(6),
  plan_type   VARCHAR,    -- promoted: fast filters, dictionary encoding
  country     VARCHAR,    -- promoted: fast filters
  event_name  VARCHAR,    -- promoted: fast filters
  properties  VARCHAR     -- fallback for rarely-queried fields
)
WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'], format = 'PARQUET');
```

**Write-time extraction in PySpark:**
```python
from pyspark.sql.functions import get_json_object

df = (raw_df
  .withColumn("plan_type",  get_json_object("properties", "$.plan"))
  .withColumn("country",    get_json_object("properties", "$.country"))
  .withColumn("event_name", get_json_object("properties", "$.event"))
)
df.writeTo("iceberg.analytics.events").append()
```

**Query in Trino after promotion:**
```sql
-- Fast: hits dictionary encoding + file skipping
SELECT COUNT(*) FROM iceberg.analytics.events
WHERE plan_type = 'enterprise'
  AND event_date >= CURRENT_DATE - INTERVAL '30' DAY;

-- Still works for infrequent ad-hoc JSON access:
SELECT json_extract_scalar(properties, '$.referrer') AS referrer
FROM iceberg.analytics.events
WHERE plan_type = 'enterprise'    -- fast: prunes files first
  AND event_date >= CURRENT_DATE - INTERVAL '7' DAY;  -- then parses JSON only on that slice
```

## Trino JSON Extraction Functions

For reading JSON fields at query time on unpromoted fields:

```sql
-- Extract a scalar value (string, number):
SELECT json_extract_scalar(properties, '$.plan') AS plan
FROM iceberg.analytics.events
WHERE event_date = CURRENT_DATE;

-- Extract a nested value:
SELECT json_extract_scalar(properties, '$.metadata.source') AS source
FROM iceberg.analytics.events
WHERE event_date = CURRENT_DATE;
```

Note: `json_extract_scalar` returns VARCHAR. Use `CAST(... AS INTEGER)` if the field is numeric.

In PySpark (for ingestion or batch transforms):
```python
from pyspark.sql.functions import get_json_object
df.withColumn("plan", get_json_object("properties", "$.plan"))
```

## Decision Rule: What to Promote vs Keep in JSON

**Promote to top-level column if:**
- The field appears in `WHERE` or `GROUP BY` on production dashboards
- The field is low-cardinality (~10–10,000 distinct values) — dictionary encoding kicks in
- The field is used for multi-tenant filtering (`tenant_id`, `plan_type`, `region`)

**Keep in JSON fallback if:**
- The field is queried rarely (ad-hoc engineer queries only)
- The field is extremely high-cardinality (e.g., per-event trace IDs) — dictionary encoding won't help anyway
- The schema is highly variable per event type and promoting isn't worth the maintenance

## Why This Matters on Your Stack

On MinIO, file I/O is the dominant bottleneck. The gap between "fast" and "reads everything" is not CPU or query planning — it's bytes read from MinIO over the network. The 1-second vs multi-minute difference you observed is exactly:

- `customer_id = 'abc123'` → 50 MB read (one file, row-group pruning fires)
- `json_col LIKE '%value%'` → 50 GB read (all files, no statistics to skip on)

Promoting just your top 5–10 most-filtered JSON keys eliminates this for your production dashboards. The schema change (`ALTER TABLE ADD COLUMN`) is metadata-only in Iceberg — instant, no file rewrites. Then backfill historical rows before pointing dashboards at the new columns (see Iceberg schema evolution: old rows return NULL for newly promoted columns until backfilled).
