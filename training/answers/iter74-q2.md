# Iter74 Q2 — Answer

**Question**: Postgres `tags TEXT[]` and `scores INT[]` array columns need to land in Iceberg. Do we have to convert them to comma-joined strings, or does Parquet support arrays natively? And in Trino, how do we find rows where a specific tag value appears in the array — is it `ANY(tags)` like Postgres, or different syntax?

---

## Answer

Good news: Parquet and Iceberg both support arrays as native types — you do not need to stringify them. Here's how to handle the full pipeline from Postgres to Trino queries.

### Does Parquet/Iceberg support arrays natively?

Yes. Parquet's column format supports nested types including arrays (called "repeated fields"). Iceberg maps these to its `ARRAY<element_type>` type. When Spark writes a DataFrame with an `ArrayType` column to Iceberg, it creates proper Parquet array columns — no stringification needed. You keep the data structure intact and don't lose query capability.

### Representing Postgres arrays in Iceberg

Postgres delivers `TEXT[]` columns as a string representation when read via JDBC (e.g., `{billing,enterprise,us-west}`). You need to parse these into Spark's `ArrayType` at ingest time.

**For TEXT[] → ARRAY\<VARCHAR\>:**

```python
from pyspark.sql.functions import split, col, regexp_replace
from pyspark.sql.types import ArrayType, StringType

df = spark.read.jdbc(
    url="jdbc:postgresql://pg-primary:5432/app",
    table="public.events",
    properties={"user": PG_USER, "password": PG_PASS, "fetchsize": "10000"}
)

# Postgres delivers TEXT[] as "{billing,enterprise,us-west}"
# Strip braces, split on comma
df = df.withColumn(
    "tags",
    split(regexp_replace(col("tags_raw"), r"[{}]", ""), ",")
)
```

**For INT[] → ARRAY\<INTEGER\>:**

```python
from pyspark.sql.functions import from_json
from pyspark.sql.types import ArrayType, IntegerType

scores_schema = ArrayType(IntegerType())
df = df.withColumn(
    "scores",
    from_json(
        regexp_replace(col("scores_raw"), r"\{(.+)\}", "[$1]"),  # {1,2,3} → [1,2,3]
        scores_schema
    )
)
```

**The resulting Iceberg table schema:**

```sql
CREATE TABLE iceberg.analytics.events (
    event_id   VARCHAR,
    tenant_id  VARCHAR,
    tags       ARRAY(VARCHAR),
    scores     ARRAY(INTEGER),
    event_date DATE
)
WITH (
    format = 'PARQUET',
    partitioning = ARRAY['day(event_date)']
);
```

Iceberg stores these as proper Parquet repeated fields — the array structure is preserved, elements are typed, and Parquet statistics are maintained at the array level.

### Querying array membership in Trino

**The answer to your key question: Postgres's `'billing' = ANY(tags)` does NOT work in Trino.** Trino uses `contains()`:

```sql
-- Find all rows where 'billing' is in the tags array
SELECT event_id, tenant_id, tags
FROM iceberg.analytics.events
WHERE contains(tags, 'billing');
```

`contains(array, element)` is Trino's standard function for array membership checks. It returns `true` if the element appears anywhere in the array, `false` otherwise — equivalent to Postgres `= ANY(array)`.

**Other useful array operations in Trino:**

```sql
-- Find rows with multiple required tags (both must be present)
WHERE contains(tags, 'billing') AND contains(tags, 'enterprise')

-- Count distinct tag values across all rows (unnest to rows)
SELECT tag_value, COUNT(*) AS row_count
FROM iceberg.analytics.events
CROSS JOIN UNNEST(tags) AS t(tag_value)
GROUP BY tag_value
ORDER BY row_count DESC;

-- Find rows where any score exceeds a threshold
WHERE contains(scores, 100)
-- or with comparison (unnest needed):
WHERE (SELECT max(s) FROM UNNEST(scores) AS t(s)) > 50

-- Check array length
WHERE cardinality(tags) > 3
```

**Important:** `UNNEST` expands one row into multiple rows (one per array element). You explicitly said you don't want this for membership checks — use `contains()` instead. `UNNEST` is useful for aggregations over all array values, not for filtering.

### Performance considerations

Array columns in Parquet are stored as repeated fields. Trino reads the entire array column for all matched files; there are no per-element statistics (unlike scalar columns which have min/max statistics for file pruning). This means:

- `contains(tags, 'billing')` reads all rows in matching partitions and evaluates the function per row
- If your most common query is "find rows tagged 'billing'" and that's a small fraction of rows, consider promoting that tag to a boolean column (`is_billing_customer BOOLEAN`) extracted at ingest time, in addition to keeping the full array

This is the same selective-flattening principle as JSONB: extract the highest-frequency values into real columns for fast filtering, keep the full array for flexibility.

### Summary

| Approach | Native arrays (recommended) | Comma-joined string |
|---|---|---|
| Parquet support | Yes — ARRAY type | Yes — VARCHAR |
| Trino membership query | `contains(tags, 'billing')` | `tags LIKE '%billing%'` (unreliable) |
| Type safety | Yes | No — 'billing' matches 'billing-plus' |
| Array length | `cardinality(tags)` | String split required |
| Recommendation | Use this | Only if you have no other choice |

Store as native ARRAY types. Parse Postgres's `{}` syntax into Spark `ArrayType` at ingest time. Query with `contains()` in Trino — not `ANY()`, which is Postgres syntax.
