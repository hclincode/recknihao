# Answer to Q2: Iceberg STRUCT Type vs Flat Columns for Stable-Schema JSONB (Iter 325)

Yes, Iceberg **STRUCT** is a real, first-class type for storing nested structured data, and it's a strong choice when you control a stable schema like your eight-field metadata object. Here's the full trade-off analysis.

## What Iceberg STRUCT Type Is

A **STRUCT** is Iceberg's native type for storing **nested rows** — a container holding multiple named typed fields. In Parquet (the file format underlying Iceberg), a STRUCT is stored as **separate physical columns per field** within the nested structure, enabling per-field columnar compression and filtering.

When you define a column as:
```sql
metadata STRUCT<account_tier VARCHAR, region VARCHAR, feature_flags VARCHAR,
                contract_start TIMESTAMP(6), contract_end TIMESTAMP(6),
                seat_count INTEGER, billing_cycle VARCHAR, support_tier VARCHAR>
```

Iceberg and Parquet do NOT store this as a single opaque JSON blob. Each field is physically laid out as a separate column chunk with individual min/max statistics and compression.

## The Three Approaches: Trade-offs

### 1. Individual Flat Columns (eight separate top-level columns)

**Pros:**
- Maximum query flexibility — each field has top-level file-skipping (min/max statistics per field)
- Simplest for Trino — `SELECT account_tier, region FROM ...` with no special syntax
- Optimal compression — low-cardinality fields like `account_tier` and `billing_cycle` dictionary-encode to near-zero bytes in Parquet

**Cons:**
- Schema bloat — your table grows by 8 columns, cluttering `SELECT *` and schema views
- Denormalization — the eight fields appear as independent top-level columns rather than a logical unit
- Schema evolution burden — adding a ninth field requires a separate `ALTER TABLE ADD COLUMN` per field

**Query example (Trino 467):**
```sql
SELECT event_id, account_tier, seat_count
FROM events
WHERE event_date = DATE '2026-05-27' AND account_tier = 'enterprise'
GROUP BY event_id, account_tier, seat_count;
```

### 2. STRUCT Type (nested, single column)

**Pros:**
- **Semantic clarity** — the eight fields are logically grouped as a single `metadata` object
- **Minimal schema footprint** — one column instead of eight top-level columns
- **Per-field compression within the struct** — Parquet stores each field separately inside the STRUCT encoding; `account_tier` still benefits from dictionary encoding
- **Per-field min/max statistics** — Iceberg collects min/max per field inside the STRUCT; predicates like `WHERE metadata.account_tier = 'enterprise'` can trigger file-skipping on Trino 467
- **Clean evolution** — adding a ninth metadata field extends the STRUCT schema once rather than adding another top-level column

**Cons:**
- **Query syntax overhead** — requires dot notation: `metadata.account_tier` instead of bare `account_tier`
- **Trino 467 nested predicate pushdown is slightly more conservative** — the optimizer is cautious about nested predicates; in practice skipping works but may be less aggressive than flat columns (see "Query performance" below)

**Query example (Trino 467):**
```sql
SELECT event_id, metadata.account_tier, metadata.seat_count
FROM events
WHERE event_date = DATE '2026-05-27'
  AND metadata.account_tier = 'enterprise'
GROUP BY event_id, metadata.account_tier, metadata.seat_count;
```

**Trino STRUCT access syntax:**
```sql
-- Dot notation (standard, preferred)
SELECT metadata.account_tier FROM events;

-- Bracket notation (also supported)
SELECT metadata['account_tier'] FROM events;

-- Cast to JSON for serialization
SELECT CAST(metadata AS JSON) FROM events;
```

### 3. VARCHAR JSON String (no typing, raw fallback)

**Pros:**
- Zero schema commitment — producer can add fields without touching the Iceberg schema
- Simplest at write time — pass raw JSONB as VARCHAR, no transformation

**Cons:**
- **No per-field statistics** — `WHERE json_extract_scalar(metadata_raw, '$.account_tier') = 'enterprise'` scans every file in the partition with no file-skipping
- **Row-by-row JSON parsing** — every query accessing a field deserializes JSON per row, 2–5x slower than STRUCT or flat columns
- **No column-level compression on individual fields** — the entire JSON string is treated as one opaque blob; repeated values like `account_tier` across 1M rows can't be dictionary-compressed at the field level

**Query example (Trino 467):**
```sql
SELECT
  event_id,
  json_extract_scalar(metadata_raw, '$.account_tier') AS account_tier,
  json_extract_scalar(metadata_raw, '$.seat_count') AS seat_count
FROM events
WHERE event_date = DATE '2026-05-27'
  AND json_extract_scalar(metadata_raw, '$.account_tier') = 'enterprise'
GROUP BY 1, 2, 3;
```

## Comparison Table

| Aspect | Flat Columns | STRUCT | JSON String |
|---|---|---|---|
| Per-field file-skipping | Yes, fully | Yes, with caveats | No |
| Schema footprint | High (8 columns visible) | Low (1 column) | Very low (1 column) |
| Per-field compression | Maximum | Good (per-field within struct) | Poor (whole JSON as blob) |
| Query syntax | `column` | `struct.field` | `json_extract_scalar(...)` |
| Query latency (file-skipping) | Best | Good | Worst |
| Row-scan latency | Fast (no JSON parsing) | Fast (no JSON parsing) | Slow (row-by-row JSON parse) |
| Schema evolution cost | High (one ADD COLUMN per field) | Low (extend STRUCT schema once) | Zero (no schema change needed) |

## Query Performance Implications on Trino 467

**Flat columns (best case):** Predicate on `account_tier` fires file-skipping directly — Trino may scan only 7 out of 2000 files in a partition.

**STRUCT (nearly as good):** Nested predicates push down, but the optimizer is more conservative — may scan ~50 out of 2000 files. Still a ~40x reduction in data read vs no-skipping, but slightly less aggressive than flat columns.

**JSON string (worst case):** No file-skipping, full partition scan, plus row-by-row JSON parsing — the full 2000 files regardless of predicate selectivity.

**Workaround if nested skipping doesn't fire:** Promote one hot filter field to a top-level column for skipping, while keeping the full STRUCT for semantic grouping (hybrid approach):
```sql
CREATE TABLE analytics.events (
  event_id VARCHAR,
  account_tier VARCHAR,                            -- promoted for file-skipping
  metadata STRUCT<account_tier VARCHAR, region VARCHAR, ...>  -- full STRUCT
);
```

## Spark Code: Creating a STRUCT Column

**Option A — Parse JSONB string into a STRUCT with explicit schema (recommended):**
```python
from pyspark.sql.functions import from_json, col
from pyspark.sql.types import StructType, StructField, StringType, TimestampType, IntegerType

metadata_schema = StructType([
    StructField("account_tier",    StringType(),    nullable=True),
    StructField("region",          StringType(),    nullable=True),
    StructField("feature_flags",   StringType(),    nullable=True),
    StructField("contract_start",  TimestampType(), nullable=True),
    StructField("contract_end",    TimestampType(), nullable=True),
    StructField("seat_count",      IntegerType(),   nullable=True),
    StructField("billing_cycle",   StringType(),    nullable=True),
    StructField("support_tier",    StringType(),    nullable=True),
])

df = spark.read.table("postgres.public.accounts") \
    .withColumn("metadata", from_json(col("metadata_json"), metadata_schema)) \
    .drop("metadata_json")

df.writeTo("iceberg.analytics.events").append()
```

**Option B — Build STRUCT from individual columns:**
```python
from pyspark.sql.functions import col, struct

df = spark.read.table("postgres.public.accounts") \
    .withColumn("metadata", struct(
        col("account_tier"),
        col("region"),
        col("feature_flags"),
        col("contract_start"),
        col("contract_end"),
        col("seat_count"),
        col("billing_cycle"),
        col("support_tier"),
    )) \
    .drop("account_tier", "region", "feature_flags", "contract_start",
          "contract_end", "seat_count", "billing_cycle", "support_tier")

df.writeTo("iceberg.analytics.events").append()
```

Always pin the schema in code — do NOT use `schema_of_json` auto-derivation in production. If a producer adds a field, auto-derivation silently drops it; an explicit pinned schema fails early in CI.

## Schema Evolution with STRUCT

Adding a ninth field to the STRUCT is metadata-only, just like adding a top-level column:

```sql
-- Spark SQL: extend the STRUCT schema
ALTER TABLE iceberg.analytics.events
MODIFY COLUMN metadata STRUCT<
  account_tier VARCHAR,
  region VARCHAR,
  feature_flags VARCHAR,
  contract_start TIMESTAMP(6),
  contract_end TIMESTAMP(6),
  seat_count INTEGER,
  billing_cycle VARCHAR,
  support_tier VARCHAR,
  sso_enabled BOOLEAN   -- new field
>;
```

Old rows automatically return NULL for `metadata.sso_enabled` (Iceberg's field-ID-based matching). No data rewrite required.

If you need to backfill historical rows:
```python
from pyspark.sql.functions import col, coalesce, lit

df = spark.read.table("iceberg.analytics.events")
df_updated = df.withColumn(
    "metadata",
    col("metadata").withField("sso_enabled", coalesce(col("metadata.sso_enabled"), lit(False)))
)
df_updated.writeTo("iceberg.analytics.events").overwritePartitions()
```

## When STRUCT Is the Right Choice: Your Case

Your metadata object is the **ideal use case for STRUCT** because:

1. **Stable, enumerated schema** — you defined the eight fields and they don't change at runtime
2. **You own the producer** — you control when fields are added (explicit schema migration, not silent drift)
3. **All fields present in every row** — no sparse/missing-key problem that would favor `VARCHAR JSON`
4. **Low-cardinality fields** — `account_tier`, `billing_cycle`, `region` are good candidates for dictionary encoding within the STRUCT

**Use STRUCT.** You get logical semantic grouping, per-field compression nearly identical to flat columns, file-skipping, and clean schema evolution — all in one column instead of eight scattered across the schema.

**Fall back to flat columns only if:**
- Trino nested predicate skipping consistently isn't firing and you can confirm it in `EXPLAIN` output (use the hybrid approach: promote one hot field to flat, keep the rest in STRUCT)
- Downstream consumers strongly prefer flat columns for dashboard tooling

**Never use JSON string for stable schemas** — you pay 5–10x query latency for zero benefit when you control the producer and the fields are known upfront.
