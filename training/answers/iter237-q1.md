# Iter 237 Q1 — Dynamic Filtering for Iceberg-Only Joins

## Answer

Yes, dynamic filtering absolutely applies to Iceberg-to-Iceberg joins, and it's just as smart as Iceberg-to-JDBC joins — but with a critical caveat about same-catalog behavior.

### 1. Does DF Apply When Both Tables Are Iceberg?

**Yes, but there's an important architectural distinction.** When both your billing events and product plan tables live in the same Iceberg catalog (same MinIO/Hive Metastore combo), the join executes as an **intra-catalog join**. The behavior differs fundamentally from a cross-catalog federated join:

- **Cross-catalog join** (Iceberg + Postgres): Trino always runs the join on workers. Dynamic filtering is the runtime mechanism that makes it efficient.
- **Same-catalog join** (both tables in Iceberg): Trino's cost-based optimizer (CBO) can plan an efficient broadcast join across workers. Dynamic filtering is still available as part of Trino's join strategies, and columnar Parquet scans combined with broadcast joins are already efficient for small-to-medium joins.

The bottom line: if both tables are in Iceberg, you get good performance for different reasons than cross-catalog scenarios — not because of DF alone.

### 2. Mechanism: File-Level Skipping, Not Row-Level IN-Lists

This is the key difference from Iceberg-fact × JDBC-dimension joins:

- **JDBC-dimension probe**: Dynamic filter produces an IN-list (or BETWEEN min/max range) that Postgres receives as part of a SQL WHERE clause — row-level filtering on the database side.

- **Iceberg probe**: Dynamic filter still produces the IN-list, but Iceberg doesn't filter rows with a WHERE clause. Instead, Trino uses the filter to **skip entire Parquet files** whose min/max statistics don't overlap the IN-list values. This happens at the file manifest level, not row-by-row:
  1. Trino reads the build table (your product definitions), extracts join-key values (say, 50 distinct plan IDs).
  2. Trino derives an IN-list or BETWEEN range from those IDs.
  3. When scanning the probe table (billing events), Iceberg checks each file's manifest entry for `lower_bounds` and `upper_bounds` on the join key column.
  4. Any file whose min/max range proves the join-key values cannot be present is skipped entirely — the file is never opened.
  5. Only overlapping files are read, then within those files, Parquet row-group pruning may further narrow the scan.

So it's "smarter than brute-force" but in a different way: it's not a SQL WHERE clause pushed to a JDBC connection, it's intelligent file pruning at the manifest level.

### 3. How to Confirm DF Is Working: EXPLAIN ANALYZE VERBOSE

Use this three-step verification:

**Step 1 — Plan-time check** (does NOT run the query):
```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ... FROM iceberg.analytics.events e
JOIN iceberg.analytics.plans p ON e.plan_id = p.id
```

Look for `dynamicFilters = {...}` annotation on the **probe-side TableScan** node (the larger table). If you see this annotation, DF was wired up at plan time:
```
TableScan[table = iceberg:analytics.events, ...]
    Layout: [plan_id, ...]
    dynamicFilters = {plan_id = #df_plans_id_0}
    # ^ this means DF will fire if the build side finishes in time
```

**Step 2 — Runtime confirmation** (actually runs the query — use sparingly on large datasets):
```sql
EXPLAIN ANALYZE VERBOSE
SELECT ... FROM iceberg.analytics.events e
JOIN iceberg.analytics.plans p ON e.plan_id = p.id
```

Look for two metrics on the probe-side scan:

- **`dynamicFilterSplitsProcessed = N`** — a non-zero value confirms DF actually fired and pruned N splits (Iceberg files). If this is 0 despite the `dynamicFilters` annotation in the plan, the build side didn't finish before the wait-timeout expired.
- **Dynamic-filter wait time** (in VERBOSE output) — shows how many milliseconds the probe scan waited for the build side before giving up and starting the scan anyway.

**Step 3 — Live query UI** (easiest post-mortem):
Run the query, then visit Trino's UI at `/ui/query.html?<query_id>`. The "Dynamic filters" panel shows which DFs were generated, how many splits they pruned, and the timing.

### 4. Configuration Levers for Iceberg-Only DF

**The critical asymmetry — wait-timeout lives on the probe catalog:**

When one table is the build side and the other is the probe, the wait-timeout that matters is on the **probe catalog**.

For Iceberg-fact × Iceberg-plan joins (where plans is the smaller build side):
- Plans table finishes first, derives the IN-list.
- Iceberg's default `dynamic-filtering.wait-timeout` is **1 second** — this is how long the events scan will wait for the plan scan to complete.
- 1 second is usually fine for same-catalog joins (both on MinIO, local network), but if your plan table is large, increase it:

```properties
# etc/catalog/iceberg.properties
dynamic-filtering.wait-timeout = 20s       # default: 1s — increase if DF keeps timing out
```

Or per-session (no coordinator restart):
```sql
SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '20s';
```

**`domain-compaction-threshold`** (default: 256) — if the IN-list exceeds 256 values, Trino compacts it to a BETWEEN min/max range. For Iceberg, this is less critical than for JDBC (Iceberg uses file-level pruning anyway), but if your build side regularly produces 300+ distinct join keys and you want to keep the precise IN-list, raise it to 1024+.

### Summary

When both tables are Iceberg, dynamic filtering absolutely applies — Trino is still "doing something smart." The mechanism is file-level manifest pruning (not row-level filtering), which skips entire Parquet files without opening them. Verify it's working with `EXPLAIN ANALYZE VERBOSE`, watching for `dynamicFilterSplitsProcessed > 0`. If you see timeouts (the field is 0 despite the plan annotation), increase `dynamic-filtering.wait-timeout` in your Iceberg catalog config.

For the typical SaaS billing use case (small product-plans table × large events table), DF should fire quickly because both scans are on local MinIO storage and the plans table scan finishes fast.
