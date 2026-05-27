# Answer to Q2: Trino Join Performance — EXPLAIN ANALYZE and CBO Statistics

## Short answer

Yes, Trino has an equivalent to Postgres's `EXPLAIN ANALYZE`, and your coworker is right that statistics are likely the problem. The slow join is almost certainly because Trino doesn't know how many distinct values appear in each join key — so it's guessing join order instead of choosing it. Here's how to diagnose it and fix it.

## Does Trino have EXPLAIN ANALYZE?

Yes — but there's an important difference from Postgres.

**`EXPLAIN ANALYZE` in Trino actually runs the query.** Just like Postgres, it executes the full query, collects runtime stats on every operator (rows processed, wall time, memory used), and returns the plan with actual vs estimated row counts. This is exactly what you want for diagnosing a slow query — but be careful running it on a 45-minute query just to get the plan.

**Safer alternative for plan-only inspection: `EXPLAIN (TYPE DISTRIBUTED)`**

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM iceberg.analytics.events e
JOIN iceberg.app.accounts a ON e.account_id = a.id
JOIN iceberg.analytics.daily_rollup r ON a.id = r.account_id
WHERE e.occurred_at >= TIMESTAMP '2026-05-01 00:00:00';
```

This shows the full distributed execution plan — join order, broadcast vs partitioned joins, estimated row counts — **without actually running the query**. It's safe to run any time. This is the right tool for "why is Trino planning this query badly?"

## How to read the plan: look for `rows: ?`

In the EXPLAIN output, every operator shows an `Estimates` line:

```
Estimates: {rows: 500000000, cpu: 1.00E8, memory: 1.00E7, network: 1.00E7}
```

If you see `rows: ?` — a literal question mark — the CBO has **no statistics for that column** and is falling back to defaults. This is the smoking gun. It means:

- The optimizer doesn't know how selective your join keys are
- It's guessing join order instead of computing the cheapest one
- It may be building a hash table on the wrong (larger) side

When `rows: ?` appears on a large table, expect the optimizer to pick a bad join order.

## What are "CBO statistics" and what does ANALYZE do?

The **cost-based optimizer (CBO)** decides join order by estimating how many rows each step produces. To do that, it needs to know **how many distinct values (NDV)** each join key has.

Iceberg automatically records **min/max values per column per file** on every write — those power file-level data skipping and are always available. But Iceberg does **NOT** automatically collect NDV. That's what your coworker means by "update statistics" — you need to run ANALYZE to populate them.

**What happens without NDV stats:**
- With 3 tables (events, accounts, daily_rollup), there are 6 possible join orders. The CBO picks randomly or by heuristic.
- If it joins events × accounts first (500M rows × 50K rows) instead of accounts × daily_rollup first (50K × 365 rows = 18M rows → then joined to 500M events), the intermediate result is massive.
- The wrong build side means a large table gets hashed into memory → OOM or spill to disk → slow.

**What happens with NDV stats:**
- CBO knows `daily_rollup` has 365 distinct dates × 50K accounts = 18M rows max
- Knows `accounts` has 50K distinct account_ids
- Picks the join order that minimizes the largest intermediate: accounts × rollup first → then join events

## How to run ANALYZE in Trino

**CRITICAL syntax warning**: Trino's command is `ANALYZE schema.table` — there is **no `TABLE` keyword**. `ANALYZE TABLE schema.table` is Spark/Hive syntax and will fail in Trino with a parser error.

```sql
-- Analyze just the join-key columns (cheaper than full-table on wide tables):
ANALYZE iceberg.analytics.events
  WITH (columns = ARRAY['account_id', 'user_id', 'tenant_id', 'occurred_at']);

ANALYZE iceberg.app.accounts
  WITH (columns = ARRAY['id', 'tenant_id', 'plan']);

ANALYZE iceberg.analytics.daily_rollup
  WITH (columns = ARRAY['account_id', 'date']);
```

**Only Iceberg connector property**: `columns`. The `partitions = ARRAY[...]` property is **Hive-only** — using it on Iceberg tables throws `analyze property 'partitions' does not exist`.

This runs a real scan to count distinct values. Small tables finish in seconds; large tables (hundreds of millions of rows) can take minutes. Results are written as a **Puffin file** (a small `.stats` blob) in the table's metadata directory in MinIO.

## Verify that stats are populated

After ANALYZE, run:

```sql
SHOW STATS FOR iceberg.analytics.events;
```

Look at the `distinct_values_count` column. If it shows real numbers (like `1.45E5` for 145,000 distinct user IDs), the CBO now has what it needs. If `distinct_values_count` is NULL for a join key, ANALYZE didn't cover that column — re-run with the right column list.

## Enable the CBO join reordering

Make sure Trino is actually using the stats. Set this per session or cluster-wide:

```sql
SET SESSION join_reordering_strategy = 'AUTOMATIC';
```

Options:
- `NONE` — keep join order exactly as written in SQL, no reordering
- `ELIMINATE_CROSS_JOINS` — only reorder to avoid cross joins
- `AUTOMATIC` — full CBO-driven reordering based on cost estimates (what you want)

With `AUTOMATIC` + populated NDV stats, re-run `EXPLAIN (TYPE DISTRIBUTED)`. The join order in the plan may change — that's the CBO doing its job.

## Stats don't auto-update — you must refresh them

This is the most important operational note: **ANALYZE results do not update automatically when new data arrives.** Every new ingest adds rows but the Puffin statistics file from last week still shows old NDV counts.

Recommended cadence:
- **Weekly**: re-ANALYZE your main join tables
- **After large bulk ingests**: re-ANALYZE immediately after any backfill that materially changes the data shape

Schedule it via k8s CronJob alongside your existing Iceberg maintenance:

```bash
trino --execute "ANALYZE iceberg.analytics.events WITH (columns = ARRAY['account_id', 'user_id'])"
trino --execute "ANALYZE iceberg.app.accounts WITH (columns = ARRAY['id', 'tenant_id'])"
trino --execute "ANALYZE iceberg.analytics.daily_rollup WITH (columns = ARRAY['account_id', 'date'])"
```

## The three-layer optimization stack

Your slow join sits at Layer 3. Keep these straight — they're independent:

| Layer | Mechanism | What it fixes | Requires ANALYZE? |
|---|---|---|---|
| **1. Partition pruning** | Iceberg partition spec — eliminates whole partitions at planning time | Scanning too many partitions | NO — always on |
| **2. File skipping** | Iceberg manifest min/max stats — skips files whose value ranges can't match your WHERE | Reading too many files within a partition | NO — auto-collected on write |
| **3. CBO join ordering** | NDV stats from Puffin files — picks join order, build/probe side, broadcast vs shuffle | Bad join order, wrong memory allocation, wrong join strategy | **YES — requires ANALYZE** |

Running ANALYZE improves **only Layer 3** — CBO join decisions. It does NOT change which files are read (that's Layer 2, always on). If your problem is "Trino is reading too much data," the fix is better partitioning + sort-based compaction, not ANALYZE.

## Diagnostic checklist for your slow 3-table join

1. **Run `EXPLAIN (TYPE DISTRIBUTED)`** — safe, doesn't execute the query.
2. **Find `rows: ?` in the Estimates** — identifies which table has missing NDV stats.
3. **Run `SHOW STATS FOR <table>`** — verify `distinct_values_count` is NULL for join keys.
4. **Run `ANALYZE` on all three tables** with join-key columns listed.
5. **Verify `join_reordering_strategy = 'AUTOMATIC'`** — `SHOW SESSION LIKE 'join_reordering_strategy'`.
6. **Re-run `EXPLAIN (TYPE DISTRIBUTED)`** — join order should change if stats were the problem.
7. **Run the actual query** and compare wall time.

If join order changes but is still slow → check Layer 2 (data skipping). `ANALYZE` is not a cure for bad file layout.
