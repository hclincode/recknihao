# Iter255 Q1 — domain_compaction_threshold for Large IN-lists

## Answer

## Your Trino Query Slows Down with Large IN-lists: The `domain_compaction_threshold` Issue

You've hit a well-known performance trap in Trino when querying PostgreSQL. Yes, Trino is silently converting your large IN-list into something much worse — a BETWEEN range — and there's a setting you can change.

### 1. What's Happening: The Default Cutoff (256)

By default, Trino has a setting called **`domain_compaction_threshold`**, which is set to **256 distinct values**. When a WHERE clause has an IN-list with more than 256 values, Trino doesn't send the exact list to PostgreSQL. Instead, it compacts the list into a BETWEEN range using the minimum and maximum values.

Here's the transformation your 1,200 tenant IDs are going through:

```
Original Trino query:
  WHERE tenant_id IN (1, 2, 3, ..., 1200)

What Postgres receives (when 1200 > 256):
  WHERE tenant_id BETWEEN 1 AND 1200
```

The query remains *correct* — Trino re-applies the original IN-list filter on its worker nodes after fetching rows from PostgreSQL — but the cost is paid in unnecessary network traffic and Postgres I/O.

### 2. Why BETWEEN Is So Much Slower Than IN for Sparse Data

Your enterprise customer's 1,200 tenant IDs probably aren't contiguous. If they're scattered across a wide range (e.g., tenant IDs 1, 50, 223, 891, ..., 1200), the BETWEEN range covers hundreds of thousands of intermediate values that your customer never owns.

Here's the concrete impact:

- **With IN-list (≤256 values)**: PostgreSQL scans only rows matching the exact 256 tenant IDs you specified. Let's say 100 rows per tenant = 25,600 rows from the database.
- **With BETWEEN (>256 values)**: PostgreSQL scans every row with tenant_id between the minimum and maximum in your list. If your min is 1 and max is 1200, it scans *all* rows for tenants 1–1200, whether your customer owns them or not. That's potentially hundreds of thousands of rows.

Trino fetches all those false-positive rows over the JDBC connection, then throws away the ones that don't match your original IN-list. You pay the network cost and the Postgres I/O cost of rows you didn't want.

For multi-tenant SaaS, this is a nightmare scenario: a customer with a small number of scattered sub-tenant IDs causes the query to run 10× slower because the BETWEEN has to return all the intermediate rows.

### 3. How to Fix It: Raise the Threshold Using SET SESSION

Before you run your large-IN query, use `SET SESSION` to raise the threshold. The syntax requires the **catalog name prefix** (the name of your PostgreSQL catalog in Trino):

```sql
-- Replace 'app_pg' with YOUR actual Postgres catalog name
SET SESSION app_pg.domain_compaction_threshold = 1024;

-- Now run your query — the full 1,200-ID IN-list ships to Postgres as IN (...)
SELECT *
FROM app_pg.public.tenants
WHERE tenant_id IN (1, 2, 3, ..., 1200);
```

**Important syntax notes:**
- Use **underscores** in the session property name: `domain_compaction_threshold` (NOT hyphens)
- The **catalog prefix is mandatory**. A bare `SET SESSION domain_compaction_threshold = 1024;` will fail with "Unknown session property"
- This applies to your entire session — every query after this point uses the higher threshold until you change it again or end the session

Alternatively, to set it **cluster-wide and persistent**, add this line to your `etc/catalog/<catalog-name>.properties` file (then restart the Trino coordinator):

```properties
# etc/catalog/app_pg.properties
domain-compaction-threshold=1024
```

Note the **hyphens** in the catalog file property name (a Trino convention).

### 4. How to Verify the Fix: Use EXPLAIN

To confirm that your IN-list is actually pushing instead of compacting to BETWEEN, run **`EXPLAIN (TYPE DISTRIBUTED)`**:

```sql
-- First, raise the threshold
SET SESSION app_pg.domain_compaction_threshold = 1024;

-- Then examine the plan
EXPLAIN (TYPE DISTRIBUTED)
SELECT COUNT(*)
FROM app_pg.public.events
WHERE tenant_id IN (1, 2, 3, ..., 1200);
```

Look at the `TableScan` node for the PostgreSQL table. You will see a `constraint on` block showing what predicate the connector is pushing down:

**If the IN-list is pushing (≤ threshold):**
```
constraint on [tenant_id]
  tenant_id IN ('val1', 'val2', ..., 'val1200')
```

**If compaction happened (> threshold):**
```
constraint on [tenant_id]
  tenant_id BETWEEN 'val_min' AND 'val_max'
```

**The definitive check — PostgreSQL's side of the story:**

While your Trino query is running, log into your PostgreSQL read replica and check `pg_stat_activity`:

```sql
-- On the Postgres replica:
SELECT query 
FROM pg_stat_activity 
WHERE state = 'active' AND query LIKE '%tenant_id%';
```

The `query` column shows the exact SQL that Trino's JDBC driver sent. This is the ground truth:

- `WHERE tenant_id IN (1, 2, 3, ...)` = full IN-list pushed successfully
- `WHERE tenant_id BETWEEN 1 AND 1200` = compaction happened

### 5. Tuning Guidance: What Value to Use

**Raise to `1024` (4× default)** when your typical large-IN query is in the 300–1000 range. This covers most multi-tenant SaaS scenarios (tenant filtering, cohort queries, backfill jobs) without hitting query planning overhead.

**Do NOT raise it too high globally.** Large IN-lists increase planning cost on both Trino and PostgreSQL side:
- Trino has to serialize and deserialize a longer list when moving it between coordinator and workers
- PostgreSQL's query planner can struggle with a 5,000-element IN-list; sometimes a BETWEEN + full scan is actually faster if your values are dense

**Best practice: use per-session tuning** for the specific query that needs it:
```sql
SET SESSION app_pg.domain_compaction_threshold = 1024;
-- Run your 1,200-tenant query here
-- Threshold reverts at session end
```

This way, normal queries (with <256 values) keep the conservative default, and you only pay the cost for the specific workload that needs it.

If you do measure that you need values higher than 1,024 (e.g., 4,096 for a backfill processing 5,000 customers at once), test on your PostgreSQL read replica first to ensure:
1. The JDBC query text doesn't exceed PostgreSQL's internal parse limits
2. Postgres index usage isn't degraded by the larger IN-list (run `EXPLAIN ANALYZE` on the Postgres side)
