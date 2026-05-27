# Iter122 Q1 — Answer

**Question**: We store a `properties` column in our events table as a JSON blob — things like browser type, plan name, feature flags that were active, country code. In Postgres we query into it with `->>` operators and it works fine for small data. Now that we're moving this table to Iceberg, I'm not sure how to handle it. Should I keep it as a JSON string column, or break it out into separate columns? And if I keep it as JSON, can Trino even filter on fields inside it efficiently, or is it going to scan everything?

---

## Answer: JSON vs. Separate Columns for Event Properties in Iceberg + Trino

This is a fundamental schema design decision — and the resources make it clear: **keep JSON as a fallback only; promote hot properties to real columns.**

### The Core Problem

In Postgres, JSON works fine because Postgres is row-oriented. When you query `payload ->> 'plan_name'`, Postgres fetches the row and extracts the key — cheap because you're reading the row anyway.

Trino + Iceberg is columnar. When a query filters on a key buried in JSON, Trino has to:

1. Read the *entire* `properties` column for *every row*, even rows you don't need
2. Parse JSON in memory on every read — no pre-computed dictionary encoding
3. Skip file-level optimization (Iceberg's min/max pruning) — that only works on actual columns
4. Fall back to a full table scan instead of partition/file skipping

From `/resources/09-lakehouse-schema-design.md`:

> "Every query has to read the entire JSON for every row to extract one key. Trino's `json_extract` works, but it forces full scans — no column pruning, no min/max pruning, no dictionary compression on common values. **Always promote queried fields to top-level columns.**"

### The Real Strategy: Two-Tier Approach

**You should absolutely do both:**

1. **Promote your top 5–10 "hot" properties to real columns at ingest time.** These are the ones you filter/group by constantly (plan name, browser type, country code, feature flags that drive dashboards).
2. **Keep the remaining rare/ad-hoc properties as a `MAP<VARCHAR, VARCHAR>` column** for flexibility — you don't want to redefine schema for every new tracking flag.

#### Example schema (Iceberg):

```sql
CREATE TABLE iceberg.analytics.user_events (
  event_id          VARCHAR,
  tenant_id         VARCHAR,
  user_id           VARCHAR,
  event_name        VARCHAR,
  occurred_at       TIMESTAMP(6),
  -- Promoted columns (denormalized)
  plan_name         VARCHAR,              -- was in JSON
  browser_type      VARCHAR,              -- was in JSON
  country_code      VARCHAR,              -- was in JSON
  feature_flags     MAP<VARCHAR, BOOLEAN>, -- was in JSON, still flexible
  -- Fallback for ad-hoc properties
  properties        MAP<VARCHAR, VARCHAR>  -- everything else
)
PARTITIONED BY (day(occurred_at), tenant_id)
```

### Why This Works

**Promoted columns get all the OLAP benefits:**
- Trino reads only `plan_name`, `browser_type`, `country_code` for queries that filter/group on them — no scanning the full row
- Iceberg stores statistics (min/max) per file for each column — queries with `WHERE browser_type = 'Chrome'` can skip files
- Parquet dictionary-encodes low-cardinality values like `plan_name` — they compress to ~1 byte per row
- Queries are simple: `WHERE plan_name = 'enterprise'` instead of `WHERE json_extract(properties, '$.plan_name') = 'enterprise'`

**The MAP fallback handles edge cases:**
- New ad-hoc properties (a feature flag you turned on yesterday) don't require schema updates
- Iceberg's schema evolution means adding a new column is metadata-only — you don't rewrite old files
- Queries can still extract ad-hoc keys when needed: `properties['some_new_flag']`

### Querying Each Tier

**Promoted columns (fast):**

```sql
SELECT COUNT(*)
FROM iceberg.analytics.user_events
WHERE occurred_at >= current_date - INTERVAL '7' DAY
  AND plan_name = 'enterprise'
  AND country_code = 'US'
  AND browser_type = 'Chrome'
GROUP BY browser_type;
```

This scans only 4 columns, skips files outside the 7-day window (partition pruning), and compresses with dictionary encoding.

**Fallback properties (slower, but necessary for rare queries):**

```sql
SELECT COUNT(*)
FROM iceberg.analytics.user_events
WHERE occurred_at >= current_date - INTERVAL '7' DAY
  AND properties['experiment_variant'] = 'treatment_b';
```

Trino reads the full `properties` column and parses JSON per row. It's slower — full scan, no stats pruning — but you're only doing this for ad-hoc or low-frequency queries.

**Hybrid (common pattern):**

```sql
SELECT browser_type, COUNT(*)
FROM iceberg.analytics.user_events
WHERE occurred_at >= current_date - INTERVAL '7' DAY
  AND plan_name = 'enterprise'
  AND properties['debug_mode'] = 'true'  -- rare property, ad-hoc filter
GROUP BY browser_type;
```

The `plan_name` and time window are fast (columnar, partition-pruned). The `debug_mode` property is slower (full scan), but you're applying it *after* the fast filters already shrink the row set.

### Deciding What to Promote

**Promote if:**
- It appears in `WHERE` or `GROUP BY` on 3+ dashboards
- It's low-cardinality (< 100 distinct values)
- It doesn't change after the event is logged (plan name at event time is fine; current user subscription is not)

**Keep in MAP if:**
- It's queried rarely (once per month, or ad-hoc troubleshooting)
- It's high-cardinality (session_id, trace_id, hash values)
- It changes frequently and you need *current* values (then JOIN to a dimension instead)

### How Trino Handles `MAP<VARCHAR, VARCHAR>` Filtering

Trino supports array/map subscripting in predicates:

```sql
SELECT * FROM table WHERE properties['key'] = 'value';
```

This works but is **not optimized** — no stats, full scan. For frequently-filtered properties, always promote them first. For occasional queries on properties that arrive out-of-band, the MAP fallback is fine — it's a deliberate trade-off between flexibility and query speed.

### Migration Plan (Postgres → Iceberg)

In your Spark ingestion job, flatten on the way in:

```python
from pyspark.sql.functions import col, from_json, schema_of_json

json_schema = """
{
  "plan_name": "string",
  "browser_type": "string",
  "country_code": "string",
  "feature_flags": "map<string, boolean>"
}
"""

parsed = df.withColumn("props_parsed", from_json(col("properties"), json_schema))

flattened = (
    parsed
    .withColumn("plan_name", col("props_parsed.plan_name"))
    .withColumn("browser_type", col("props_parsed.browser_type"))
    .withColumn("country_code", col("props_parsed.country_code"))
    .withColumn("feature_flags", col("props_parsed.feature_flags"))
    .withColumn("properties", col("props_parsed.properties"))
    .drop("props_parsed")
)

flattened.writeTo("iceberg.analytics.user_events").mode("append").saveAsTable()
```

Once it's in Iceberg as real columns + MAP, you never parse JSON again — Iceberg and Trino handle it natively.

### Storage Cost

No penalty. Promoted columns are low-cardinality and dictionary-compress to nearly nothing. A `plan_name` column with 10 distinct values takes ~1 byte per row in Parquet. The original JSON might be `"plan_name":"enterprise"` (25 bytes or more). You're actually *saving* space by promoting.

---

**Bottom line:** Promote the 5–10 properties you query most often to real columns. Keep everything else in MAP for ad-hoc access. You get Trino's columnar advantages where they matter most, and the flexibility of schemaless JSON where you need it.
