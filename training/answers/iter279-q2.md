# Iter279 Q2 — Dynamic Filtering: Why Join Order Matters in Postgres+Iceberg Queries

## Answer

You've found Trino's dynamic filtering optimization. The performance difference is not about join symmetry — it's about which table becomes the "build side," whether Trino can collect join keys from it, and whether it can push an IN-list filter back into the Postgres scan before Postgres reads its 200M rows.

### 1. What Dynamic Filtering Does

In a hash join, Trino always has two sides:
- **Build side** — the smaller table, scanned first and loaded into an in-memory hash table
- **Probe side** — the larger table, streamed through row-by-row to check against the hash table

Dynamic filtering works by collecting all distinct join-key values from the **build side's hash table** and pushing them as an IN-list filter INTO the **probe side's scan** — before the probe scan starts. If the probe side is Postgres, Trino pushes `WHERE segment_id IN (seg_1, seg_2, ..., seg_50k)` directly into the JDBC query. Postgres skips 150M+ rows that don't match.

### 2. Why the Fast Path Is Fast (Iceberg on right → build side)

`SELECT ... FROM postgres_events e JOIN iceberg_segments s ON e.segment_id = s.id`

Trino's optimizer sees: Postgres (200M rows) vs Iceberg (50K rows). It assigns:
- **Iceberg as build side** (small, fits in memory)
- **Postgres as probe side** (large, to be scanned with dynamic filter applied)

Execution:
1. Scan Iceberg segments (50K rows) → build hash table → collect segment ID values
2. Push `IN (seg_1, ..., seg_50k)` INTO the Postgres JDBC scan
3. Postgres applies the filter server-side, returns only matching rows
4. Trino streams the filtered Postgres rows through the hash table

Result: 8 seconds because Postgres scans a small fraction of the 200M rows.

### 3. Why the Slow Path Is Slow

When the optimizer assigns Postgres as build side (which may happen when statistics are missing or join semantics prevent DF), dynamic filtering cannot push values INTO Iceberg easily. If Postgres is the probe side but dynamic filtering doesn't reach it in time (see wait-timeout below), Postgres scans all 200M rows. The filter arrives too late or not at all.

Additionally: **dynamic filtering only flows from the build side to the probe side**. It cannot flow in reverse. If Iceberg needs to be filtered by values from Postgres, DF cannot help — you must write the query so Iceberg is the probe of a Postgres build, which is unusual.

### 4. Which Join Types Enable Dynamic Filtering

| Join type | DF enabled on probe side | Why |
|---|---|---|
| **INNER JOIN** | Yes | Probe can safely drop rows unmatched by build |
| **RIGHT JOIN** | Yes | Same logic |
| **LEFT OUTER JOIN** | **No** | Left side must return ALL rows, even unmatched — DF would drop required rows |
| **FULL OUTER JOIN** | **No** | Both sides must return all rows |

For your use case (INNER JOIN), DF is enabled. If you change to LEFT OUTER, DF turns off and Postgres scans all 200M rows regardless of the Iceberg filter.

### 5. Does SQL Join Order Control This?

**The optimizer decides, not SQL order.** Trino's cost-based optimizer (CBO) reassigns build/probe based on table statistics, not the order you write the join. Writing `FROM postgres_events JOIN iceberg_segments` vs `FROM iceberg_segments JOIN postgres_events` doesn't change the physical plan — the CBO reorders.

**The real lever is accurate table statistics.** Without them, the CBO guesses and may pick the wrong build/probe assignment:
- Iceberg: `ANALYZE iceberg.schema.segments;` — writes Puffin files with row counts and NDV; CBO reads these automatically
- Postgres: run native `ANALYZE` on the Postgres table (on the primary, not replica); CBO reads from `pg_stats` automatically

Verify with `EXPLAIN ANALYZE` — look for `DynamicFiltersEnabled=true` on the probe-side scan and `dynamicFilterSplitsProcessed: N` (non-zero means DF fired).

### 6. The Wait-Timeout Footgun

Trino has a default 1-second wait before the probe-side scan starts without a dynamic filter. If the build side (Iceberg 50K rows) takes >1 second to finish scanning and load into the hash table, the Postgres probe starts without the filter:

```properties
# etc/catalog/iceberg.properties (applies when Iceberg is the probe side)
iceberg.dynamic-filtering.wait-timeout=20s
```

Or per-session:
```sql
SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';
```

Note: use underscores in the SQL session form; hyphens in the catalog properties file. Set this on the **probe-side catalog**.

### Summary

1. **Keep writing queries with Iceberg as the smaller side** — that's the natural join direction for a dimension/lookup table anyway.
2. **Run ANALYZE** on both tables so the CBO knows their actual sizes and picks the right build/probe assignment.
3. **Use INNER or RIGHT joins** when you need DF — avoid LEFT/FULL OUTER if Postgres scan performance is critical.
4. **Raise the wait-timeout** if your Iceberg scan takes more than 1 second to collect build-side values: `iceberg.dynamic-filtering.wait-timeout=20s`.
5. **Verify with EXPLAIN ANALYZE** — `DynamicFiltersEnabled=true` and non-zero `dynamicFilterSplitsProcessed` confirms DF is working.
