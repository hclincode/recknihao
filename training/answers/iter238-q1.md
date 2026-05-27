# Iter 238 Q1 — Dynamic Filtering Wait-Timeout: Which Config File?

## Answer

**The core issue: `dynamic-filtering.wait-timeout` is a PROBE-SIDE property, not a build-side property.**

Your query joins Iceberg (`events`, 800M rows — the probe) against PostgreSQL (`accounts`, 50K rows — the build). The dynamic filter flows **from PostgreSQL to Iceberg**, so the timeout that matters lives in the **Iceberg catalog**, not the PostgreSQL catalog.

### 1. Which Catalog File Gets `dynamic-filtering.wait-timeout`?

**Put it in `etc/catalog/iceberg.properties`**, not your PostgreSQL catalog. Here's why:

- Trino reads PostgreSQL first (the build side) to collect the 50,000 account IDs
- It then tries to push that IN-list of IDs to the Iceberg probe scan to skip unnecessary Parquet files
- The Iceberg connector is the one that **waits** for the IN-list to arrive before launching the scan
- Therefore, the wait-timeout lives on the **receiving side**, which is Iceberg

If you set `dynamic-filtering.wait-timeout` in your PostgreSQL catalog properties, it has **no effect** on this query — PostgreSQL is the build side and doesn't wait for a filter; it publishes one.

### 2. What Are the Defaults?

| Connector | Default timeout |
|-----------|-----------------|
| **Iceberg** | **1 second** (very short) |
| **PostgreSQL** | 20 seconds (only relevant when PostgreSQL is the probe, not the build) |

The 1-second default for Iceberg is the binding constraint in your case. PostgreSQL rarely finishes scanning 50K rows and publishing the IN-list in just 1 second, so the timeout fires before Iceberg even gets the filter — meaning Iceberg scans all 800M rows anyway.

### 3. What to Set and How to Verify

Add this to `etc/catalog/iceberg.properties`:

```properties
# Increase from default 1s to match JDBC's publishing speed
iceberg.dynamic-filtering.wait-timeout=20s
```

Then restart the coordinator (or use a per-session setting to avoid restart — see below).

**To verify dynamic filtering is actually working**, run:

```sql
EXPLAIN ANALYZE VERBOSE
SELECT COUNT(*)
FROM iceberg.analytics.events e
JOIN postgresql_catalog.public.accounts a ON e.account_id = a.id
WHERE a.plan = 'premium';
```

Look for these signals in the output:

- **`dynamicFilterSplitsProcessed = N`** (where N > 0) on the Iceberg TableScan — proves the filter was applied at runtime
- **`dynamicFilters = {...}`** annotation on the Iceberg TableScan — confirms DF was wired into the plan
- **`VERBOSE` output shows the actual IN-list or BETWEEN range** that was pushed to Iceberg

If you see `dynamicFilterSplitsProcessed=0` even with the longer timeout, check that:
- The join key column exists in both tables with compatible types
- Your PostgreSQL connector is configured to a read replica (not a slow primary)

### 4. Per-Session Alternative (No Coordinator Restart Needed)

Before running your join query:

```sql
SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';
```

Replace `iceberg` with your actual Iceberg catalog name (the filename from `etc/catalog/` without `.properties`). Check with `SHOW CATALOGS;` if unsure.

This setting lasts for your session only and takes effect immediately — useful for testing whether the longer timeout fixes your "zero splits pruned" problem without downtime.

---

**Why you're seeing zero splits pruned right now:** The 1-second default timeout fires before PostgreSQL finishes scanning and publishing the account IDs, so Iceberg launches its scan without the filter and reads all 800M rows. Increasing the timeout to 20 seconds gives PostgreSQL time to finish before Iceberg gives up waiting.
