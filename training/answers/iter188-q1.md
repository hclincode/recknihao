# Iter 188 Q1 — CBO Join Ordering with Federated Postgres Tables: ANALYZE and Statistics

## Answer

The short answer is: **`ANALYZE` works in Trino, but it only affects join ordering decisions for Iceberg tables, NOT Postgres tables.** Here's what's happening and why it matters for your federated queries.

### How Trino makes join-ordering decisions

When Trino plans a query like `SELECT * FROM iceberg.analytics.events JOIN app_pg.public.users ON ...`, the **cost-based optimizer (CBO)** decides:
- Which table should be the "build side" (loaded into a hash table in memory — should be small)?
- Which table should be the "probe side" (streams past the hash table)?
- Should the build side be broadcast to every worker, or should both sides be shuffled across the cluster?

Making the wrong choice can turn a 5-second query into a 45-minute one. **The CBO makes these decisions based on row-count estimates.** Without good estimates, it guesses — that's when you see the "huge table scanned first" problem.

### What `ANALYZE` does and does NOT do

**Critical distinction**: `ANALYZE` in Trino works **only on Iceberg tables**.

```sql
-- This works on Iceberg tables:
ANALYZE iceberg.analytics.events;

-- This does NOTHING on Postgres tables — the PostgreSQL connector does not support it:
ANALYZE app_pg.public.users;
```

When you run `ANALYZE iceberg.analytics.events`, Trino computes the number of distinct values (NDV) in each column and writes them to a Puffin statistics file in MinIO. The CBO then uses those numbers to estimate join cardinality.

**For the Postgres table, Trino cannot run ANALYZE.** The PostgreSQL connector in OSS Trino 467 does not expose an ANALYZE operation.

### What Trino actually gets from Postgres (and what it doesn't)

**Trino CAN get**: total row counts from Postgres metadata (`pg_class.reltuples`). The PostgreSQL connector queries Postgres metadata when planning queries. Row counts are available — just approximate (they reflect the last autovacuum/analyze run on Postgres).

**Trino does NOT get from Postgres**:
- Number of distinct values (NDV) per column
- Value distribution (uniform vs. skewed?)
- Histograms of value ranges

Without NDV, the CBO's cardinality estimates for **filtered rows** are just heuristic guesses. `WHERE plan = 'enterprise'` might return 1% of rows or 80% — the CBO has no idea.

### What happens when those guesses are wrong

1. **Memory exhaustion**: Optimizer picks the large Postgres table as the "build side," tries to load a billion rows into a hash table on each worker → query crashes with `Query exceeded per-node memory limit`.
2. **Unnecessary shuffles**: Optimizer picks a partitioned join instead of a broadcast join → expensive cross-cluster data shuffle.
3. **Slow execution**: Join runs correctly but inefficiently — large intermediate results, wrong filter order.
4. **Inconsistent performance**: Same query runs at different speeds depending on data changes or Trino version upgrades that change heuristics.

### How to mitigate

**Option 1: ANALYZE Postgres directly (not through Trino)**

Run ANALYZE from psql on your Postgres replica — this updates `pg_class.reltuples` (the row count estimate) and `pg_stats`, which Trino reads via JDBC:

```sql
-- On the Postgres replica directly (not through Trino):
ANALYZE users;
ANALYZE events;
```

This doesn't give Trino NDV stats, but at least row counts are fresher for the CBO.

**Option 2: ANALYZE the Iceberg side of your joins**

```sql
-- From Trino:
ANALYZE iceberg.analytics.events WITH (columns = ARRAY['user_id', 'tenant_id']);
```

This populates NDV statistics for the Iceberg table, so at least one side of the join has good stats.

**Option 3: Hint the join distribution explicitly**

When you know the Postgres table is small, tell Trino:

```sql
SET SESSION join_distribution_type = 'BROADCAST';
SELECT * FROM iceberg.analytics.events e
JOIN app_pg.public.users u ON e.user_id = u.id
WHERE ...;
```

`BROADCAST` tells Trino "ship the smaller side to all workers." If you're joining a large Iceberg table to a small Postgres lookup, BROADCAST avoids the CBO picking the wrong side.

**Option 4: Filter the Postgres side early**

Push selective predicates to a subquery so Postgres returns fewer rows before the join:

```sql
-- Instead of joining first and filtering after:
SELECT * FROM iceberg.analytics.events e
JOIN app_pg.public.users u ON e.user_id = u.id
WHERE u.plan = 'enterprise';

-- Filter Postgres side early — Postgres returns only matching rows:
SELECT * FROM iceberg.analytics.events e
JOIN (
  SELECT id FROM app_pg.public.users 
  WHERE plan = 'enterprise'
) u ON e.user_id = u.id;
```

### Summary

- **`ANALYZE` in Trino works only on Iceberg, not Postgres** — the PostgreSQL connector doesn't support it
- **Trino gets row counts from Postgres but not NDV or distribution stats** — the CBO guesses on filtered-row estimates
- **When those guesses are wrong**: wrong build/probe side, memory pressure, expensive shuffles
- **Mitigations**: ANALYZE Postgres directly via psql, ANALYZE Iceberg tables, use `join_distribution_type = 'BROADCAST'` hint, filter early on the smaller side

The best long-term fix: accept that Postgres and Iceberg are separate query engines. Design your federated joins to keep the Postgres side small via early filters, ANALYZE your Iceberg tables so at least that side has good stats, and hint join distribution when you know it's wrong.
