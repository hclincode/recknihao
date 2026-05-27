# Iter 233 Q1 — Dynamic Filtering for Iceberg + MySQL Join

## Answer

Your gut is right — and yes, Trino is doing it (probably). You're describing exactly what **dynamic filtering** does, and it's enabled by default in Trino. Your 50k-row MySQL accounts table is the "build side" of the join, and the 500M-event Iceberg table is the "probe side." After Trino reads the accounts table, it derives a filter from the account_id values it saw, and pushes that filter back into the Iceberg scan — which can then skip entire Parquet files whose min/max statistics don't overlap your account_ids. Without this optimization, you'd scan all 500M rows. With it, you scan only event rows from those active accounts.

### Step 1: Check the Plan (Planning-Time Signal)

Run `EXPLAIN (TYPE DISTRIBUTED)` on your query without executing it:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM mysql_catalog.schema.accounts a
JOIN iceberg_catalog.analytics.events e ON e.account_id = a.id
WHERE a.status = 'active';
```

Look at the **Iceberg side** (the probe scan). You should see:

```
dynamicFilters = {account_id = #df_accounts_id_0}
```

**If you see this**: dynamic filtering is wired up at plan time.

**If you don't see it**: either the join is backwards (Iceberg is the build side — unlikely at 500M rows), or the join key is not numeric. Check that your join key is numeric or UUID.

### Step 2: Verify It Actually Fired (Runtime Signal)

Run `EXPLAIN ANALYZE VERBOSE`:

```sql
EXPLAIN ANALYZE VERBOSE
SELECT ...
FROM mysql_catalog.schema.accounts a
JOIN iceberg_catalog.analytics.events e ON e.account_id = a.id
WHERE a.status = 'active';
```

**Warning**: This actually executes your query. Look for two critical runtime fields on the Iceberg TableScan node:

1. **`dynamicFilterSplitsProcessed = N`** (where N > 0) — The smoking gun. A non-zero value means the dynamic filter fired during execution and pruned Iceberg files.

2. **`Input: X rows`** — Compare against 500M. Dramatically smaller means the IN-list from the accounts table pruned the Iceberg side.

**Dynamic filtering working:**
```
TableScan[table = iceberg:analytics.events]
    Input: 47200000 rows (8.2GB)
    dynamicFilterSplitsProcessed = 1247
    dynamicFilters = {account_id = ...}
```

**Dynamic filtering NOT working (timed out):**
```
TableScan[table = iceberg:analytics.events]
    Input: 482000000 rows (84GB)
    dynamicFilterSplitsProcessed = 0
    dynamicFilters = {account_id = ...}
```

The filter was wired up (`dynamicFilters =` present) but `dynamicFilterSplitsProcessed = 0` means the Iceberg scan started before the MySQL build side finished — a **wait-timeout** issue.

### Why It Might Not Be Working: The Wait-Timeout

There's one pitfall specific to MySQL + Iceberg: **wait-timeout mismatch**.

When Iceberg is the probe side, it waits up to **1 second** (default) for the MySQL build side to finish and produce the filter. If MySQL takes longer than 1 second to scan 50k rows, Iceberg gives up and starts scanning the full 500M rows without the filter.

Check your Iceberg catalog configuration (`etc/catalog/iceberg.properties`):

```properties
# Default is 1s — too short when MySQL is the build side
dynamic-filtering.wait-timeout=1s
```

Increase it to match MySQL's timeout:

```properties
dynamic-filtering.wait-timeout=20s   # MySQL JDBC default — much safer
```

Or set it per-session:

```sql
SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';
```

This is the #1 reason dynamic filtering appears to fail in Iceberg + JDBC (MySQL/PostgreSQL) joins — not because it's broken, but because the probe side gives up waiting.

### One Caveat: VARCHAR / String Join Keys

If your `account_id` is stored as VARCHAR, dynamic filtering still works — but if your active accounts list exceeds 256 distinct IDs (`domain-compaction-threshold` default), Trino compacts the IN-list into a `BETWEEN` range, which returns more rows than strictly necessary. For typical scenarios (50k accounts filtering 500M events), this is fine — the `BETWEEN` still prunes heavily.

### Quick Checklist

1. **`EXPLAIN (TYPE DISTRIBUTED) SELECT ...`** — confirm `dynamicFilters` appears on the Iceberg scan
2. **`EXPLAIN ANALYZE VERBOSE SELECT ...`** — confirm `dynamicFilterSplitsProcessed > 0`
3. **Check `etc/catalog/iceberg.properties`** — ensure `dynamic-filtering.wait-timeout` is at least 20s

If step 2 shows `dynamicFilterSplitsProcessed = 0`, increase the wait-timeout and retry.
