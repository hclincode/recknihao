# Iter 223 Q1 — Dynamic Filtering Not Firing: Diagnosis and Fix

## Answer

You've stumbled into one of the most important—and least visible—optimization mechanisms in Trino. Let me walk through what's happening, how to diagnose it, and how to fix it.

### 1. What Dynamic Filtering Is and How It Works

**Dynamic filtering** is a runtime optimization where Trino takes actual join-key values from the **build side** (your smaller table) and derives a compact filter that it **pushes down to the probe side** (your larger table) *while the probe is still scanning*.

In your case, the flow should be:
1. Trino scans the small side of the join (build side, e.g., the Iceberg events after filtering to "a few thousand customers")
2. Trino collects the actual join key values from those rows
3. Trino creates an `IN`-list: `WHERE customer_id IN (1, 2, 3, ..., 5000)`
4. **Before the probe side finishes its full scan**, Trino sends that filter to the probe-side connector
5. The probe connector uses the filter to skip rows that can't match
6. Result: the probe table scans far fewer rows

Without dynamic filtering, the probe side (your 50M-row MySQL customers table) would scan every row, even though only a tiny fraction matches the join keys from Iceberg.

### 2. How to Tell from EXPLAIN Whether DF Was Wired at Plan Time

Run `EXPLAIN (TYPE DISTRIBUTED)` on your join query and look for a `dynamicFilters` annotation on the **probe-side TableScan** (the large MySQL customers table):

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM iceberg.events e
JOIN billing_mysql.customers c ON e.customer_id = c.id
WHERE c.tenant_id = '...';
```

In the output, find the `TableScan` node for the MySQL table. Look for a line like:

```
TableScan[billing_mysql:billing.customers, dynamicFilters = {df_customer_id_0 = ...}]
```

**If you see `dynamicFilters = {...}` on the MySQL TableScan:** DF was wired up at plan time. The optimizer intended for it to fire.

**If you don't see it:** DF was not even planned, which means the optimizer chose the wrong join orientation or DF was skipped due to estimated sizes. Jump to Section 4 below.

### 3. How to Tell from EXPLAIN ANALYZE Whether DF Actually Fired at Runtime

`EXPLAIN (TYPE DISTRIBUTED)` only tells you DF was *planned*. To verify it *actually fired*, you must run the query and look at `EXPLAIN ANALYZE`:

```sql
EXPLAIN ANALYZE
SELECT ...
FROM iceberg.events e
JOIN billing_mysql.customers c ON e.customer_id = c.id;
```

Look at the **MySQL TableScan node** (the probe side) and check:

1. **`dynamicFilterSplitsProcessed`** — a non-zero integer means DF fired and pruned splits. **This is the smoking gun that DF actually executed.**

2. **`Input: X rows` vs `Output: Y rows`** — compare the row counts at the MySQL scan. If Input is much smaller than the 50M total rows in the table, the DF and/or static filters pruned at the source. If Input is still ~50M rows, DF did not push to MySQL.

**Critical:** if `EXPLAIN (TYPE DISTRIBUTED)` showed `dynamicFilters = {...}` on the plan but `EXPLAIN ANALYZE` shows `dynamicFilterSplitsProcessed = 0`, **DF was set up but did not fire at runtime** — usually because the build side was slow and hit the wait-timeout.

### 4. Four Main Reasons DF Doesn't Fire

#### a) Build Side Exceeded Size Thresholds

If your Iceberg side returns more distinct join-key values than Trino's DF thresholds allow, Trino switches from an exact IN-list to a weaker min/max range filter (or skips DF entirely). The real property names (as of Trino 467):

- **`dynamic-filtering.small.max-distinct-values-per-driver`** — if the build side produces more distinct join-key values per driver than this limit, Trino switches from IN-list to min/max range
- **`dynamic-filtering.small.max-size-per-driver`** — if the total byte size of collected values exceeds this, also switches to range filter
- **`dynamic-filtering.small.range-row-limit-per-driver`** — row count threshold above which Trino falls back to range filter
- **`dynamic-filtering.small-partitioned.*`** variants — equivalent thresholds for partitioned/hash joins
- **`enable-large-dynamic-filters`** — session property that enables larger thresholds for big dimension tables

**Symptom:** `EXPLAIN ANALYZE` shows `dynamicFilterSplitsProcessed = 0` even though the plan showed DF was wired up.

#### b) Wait-Timeout Hit — Probe Scan Launched Before Build Completed

By design, Trino does not wait forever for the build side to finish. After the timeout, the probe-side scan starts **without** the dynamic filter to avoid indefinite blocking.

```
dynamic-filtering.wait-timeout = 20s  (default for JDBC connectors)
```

If your Iceberg events query takes 25 seconds to filter, the MySQL probe scan starts at 20 seconds without DF.

**Symptom:** `EXPLAIN ANALYZE` shows `dynamicFilterSplitsProcessed = 0` and large `Input:` row count on the MySQL scan, but the plan showed DF was wired.

#### c) Wrong Join Orientation — MySQL Chosen as Build Side

DF flows from **build → probe**. If the CBO wrongly estimates the build/probe assignment (MySQL as build and Iceberg as probe), DF goes the wrong direction and doesn't help the 50M-row MySQL scan.

**Symptom:** `EXPLAIN (TYPE DISTRIBUTED)` shows `dynamicFilters` on the Iceberg TableScan (not the MySQL one), meaning DF is flowing toward Iceberg instead of MySQL.

**Fix:** Run `ANALYZE` on both tables so the CBO has accurate cardinality estimates. Or force the join orientation with `SET SESSION join_distribution_type = 'BROADCAST'`.

#### d) VARCHAR Join Key — IN-Lists Do NOT Push to MySQL

If your join key is a VARCHAR (e.g., `ON e.customer_code = c.code`), Trino **cannot** push an IN-list to MySQL. This is the same collation-correctness reason that static VARCHAR predicates don't push to MySQL. Even if DF fires on the Iceberg side (file pruning), the MySQL side will not receive the IN-list filter.

**Fix:** Use a numeric surrogate key (BIGINT, INT) for the join if possible. DATE and TIMESTAMP join keys also push to MySQL.

### 5. Real Property Names That Control DF Thresholds

From `trino.io/docs/current/admin/dynamic-filtering.html`:

```
dynamic-filtering.small.max-distinct-values-per-driver
dynamic-filtering.small.max-size-per-driver
dynamic-filtering.small.range-row-limit-per-driver
dynamic-filtering.small-partitioned.max-distinct-values-per-driver
dynamic-filtering.small-partitioned.max-size-per-driver
dynamic-filtering.small-partitioned.range-row-limit-per-driver
enable-large-dynamic-filters (session property — toggles larger thresholds)
```

Do **NOT** use `dynamic-filtering.small-join.estimated-size-in-bytes` — this property does not exist.

### 6. How to Tune: Catalog-Prefixed Session Properties

To extend the wait-timeout without restarting the coordinator:

```sql
-- For the Iceberg connector (build side):
SET SESSION iceberg.dynamic_filtering_wait_timeout = '30s';

-- For the MySQL connector (probe side, if needed):
SET SESSION billing_mysql.dynamic_filtering_wait_timeout = '30s';
```

**Critical:** the catalog prefix is **required** — bare `SET SESSION dynamic_filtering_wait_timeout = ...` fails with "Session property does not exist." Property uses underscores in session form, hyphens in config files.

To allow larger build sides:
```sql
SET SESSION enable_large_dynamic_filters = true;
```

To prevent IN-list compaction on MySQL:
```sql
SET SESSION billing_mysql.domain_compaction_threshold = 1024;
```

### 7. Practical Next Steps

1. **Run EXPLAIN ANALYZE** → does the MySQL TableScan show `dynamicFilterSplitsProcessed > 0`? If yes, DF fired. If no, move to step 2.
2. **Check EXPLAIN (TYPE DISTRIBUTED)** → does the MySQL TableScan show `dynamicFilters = {...}`? If yes, DF was planned but didn't fire (timeout or build too large). Bump `iceberg.dynamic_filtering_wait_timeout` to `60s`. If no, DF was never wired — check join orientation and join key type.
3. **Check the MySQL slow log** → what predicate is actually being sent? `WHERE customer_id IN (...)` means DF reached MySQL. No IN-list means DF didn't push.
4. **Verify the join key type** → `DESCRIBE billing_mysql.billing.customers;`. If `customer_id` is VARCHAR, switch to a numeric key for DF to work.
