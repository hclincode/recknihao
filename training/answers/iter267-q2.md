# Iter267 Q2 — Why LEFT JOIN Between Postgres and Iceberg Doesn't Get Dynamic Filtering Optimization

## Answer

You're observing exactly the right behavior — but for a precise reason that's worth understanding.

**The short answer:** Trino's dynamic filtering optimization does NOT work with LEFT OUTER JOIN (including LEFT JOIN). It only works with INNER JOIN and RIGHT JOIN. This is a fundamental limitation by design, not a configuration issue you can tweak.

The reason is logical: a LEFT JOIN must return every row from the left side, even if there's no match on the right side. Dynamic filtering works by using join-key values from one side to prune reads on the other — but pruning the left side of a LEFT JOIN would drop rows the query is required to return. So Trino doesn't apply dynamic filtering to LEFT JOINs.

### How Dynamic Filtering Works with INNER JOIN

When you write an INNER JOIN:

```sql
SELECT c.account_id, c.account_name, SUM(e.amount) AS usage
FROM app_pg.public.customer_accounts c
INNER JOIN iceberg.analytics.events e ON e.account_id = c.account_id
GROUP BY 1, 2;
```

Trino does this:
1. Scans the small Postgres table (2,000 rows)
2. Collects the account IDs it found (say, 1,800 distinct IDs)
3. Derives a runtime IN-list: `account_id IN (123, 456, ..., [1800 values])`
4. Pushes that filter into the Iceberg scan BEFORE reading the table
5. Iceberg prunes file splits — skips Parquet files whose `account_id` min/max stats fall outside the list
6. Result: Instead of scanning 800 million rows, it scans only the rows matching the 1,800 account IDs

### Why LEFT JOIN Blocks Dynamic Filtering

With LEFT JOIN, the semantics require returning every account row even if it has no matching events (producing NULL values in the event columns). If Trino applied dynamic filtering and pruned Iceberg reads, it might drop rows — and the query is logically required to return them. Trino cannot safely apply the optimization.

| Join Type | Dynamic Filtering? |
|---|---|
| INNER JOIN | YES |
| RIGHT JOIN | YES |
| LEFT OUTER JOIN | NO |
| FULL OUTER JOIN | NO |

### How to Rewrite LEFT JOIN to Get Dynamic Filtering Back

Use the **INNER JOIN + UNION ALL** pattern to preserve all Postgres rows while recovering the optimization:

```sql
-- ORIGINAL (slow — no dynamic filtering):
SELECT c.account_id, c.account_name, SUM(e.amount) AS usage
FROM app_pg.public.customer_accounts c
LEFT JOIN iceberg.analytics.events e ON e.account_id = c.account_id
GROUP BY 1, 2;

-- REWRITTEN (fast — dynamic filtering active on the INNER JOIN part):
SELECT c.account_id, c.account_name, SUM(e.amount) AS usage
FROM app_pg.public.customer_accounts c
INNER JOIN iceberg.analytics.events e ON e.account_id = c.account_id
GROUP BY c.account_id, c.account_name

UNION ALL

SELECT c.account_id, c.account_name, NULL AS usage
FROM app_pg.public.customer_accounts c
WHERE NOT EXISTS (
  SELECT 1 FROM iceberg.analytics.events e
  WHERE e.account_id = c.account_id
);
```

What this does:
- **First part (INNER JOIN)**: Returns accounts that HAVE events, with aggregated usage. Dynamic filtering prunes the Iceberg scan efficiently.
- **Second part (UNION ALL)**: Returns accounts that have NO events, with NULL usage. This is Postgres-only — no Iceberg involvement.
- **Combined**: Every account appears exactly once, with usage if they have events, NULL if they don't — identical semantics to the original LEFT JOIN, but the expensive Iceberg scan got the dynamic filtering benefit.

### Alternative: CTE Pattern

If the `NOT EXISTS` subquery is slow, materialize the INNER JOIN result first:

```sql
WITH joined_accounts AS (
  SELECT c.account_id, c.account_name, SUM(e.amount) AS usage
  FROM app_pg.public.customer_accounts c
  INNER JOIN iceberg.analytics.events e ON e.account_id = c.account_id
  GROUP BY c.account_id, c.account_name
)
SELECT c.account_id, c.account_name, j.usage
FROM app_pg.public.customer_accounts c
LEFT JOIN joined_accounts j ON c.account_id = j.account_id;
```

The INNER JOIN inside the CTE gets dynamic filtering. The outer LEFT JOIN is now between the small Postgres table (2K rows) and a much smaller CTE result — fast even without dynamic filtering.

### Verifying Dynamic Filtering Is Working

Run `EXPLAIN ANALYZE` on your INNER JOIN rewrite and check the Iceberg TableScan:

```sql
EXPLAIN ANALYZE
SELECT c.account_id, c.account_name, SUM(e.amount) AS usage
FROM app_pg.public.customer_accounts c
INNER JOIN iceberg.analytics.events e ON e.account_id = c.account_id
GROUP BY 1, 2;
```

**With dynamic filtering active**: `Input:` row count on the Iceberg scan is much smaller than 800M (e.g., 50M matching rows). The plan shows `dynamicFilters` annotation on the Iceberg TableScan.

**Without dynamic filtering**: `Input: 800000000 rows` — full table scan.

### The `iceberg.dynamic-filtering.wait-timeout` Property

If dynamic filtering is configured but still not pruning much, the Postgres build side may be slower than the default 1-second timeout. Increase the timeout in your Iceberg catalog config:

```properties
# etc/catalog/iceberg.properties
iceberg.dynamic-filtering.wait-timeout=20s
```

This property lives on the **Iceberg catalog** (the probe side receiving the filter), not the Postgres catalog. Trino waits up to this long for the Postgres side to finish and deliver the IN-list before launching the Iceberg scan. If Postgres finishes in time, the filter applies; if not, Trino scans Iceberg unfiltered and applies the filter in memory.

### Summary

The LEFT JOIN behavior you're seeing is intentional — Trino cannot safely use dynamic filtering on LEFT OUTER JOINs. The fix is to rewrite as INNER JOIN + UNION ALL, which gives you identical semantics while keeping the Iceberg scan pruned. For your case (2K Postgres rows, 800M Iceberg rows), this rewrite should dramatically reduce scan time.
