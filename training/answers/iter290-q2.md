# Iter290 Q2 — Why JOIN Order Matters in Trino and How to Control It

## Short answer

JOIN order matters in Trino because one side of every join must be loaded into memory as a hash table (the "build" side). Trino's Cost-Based Optimizer picks which side based on table size statistics. For a 400M-row events table joined against 50K accounts, the CBO should broadcast accounts (load into every worker's memory) and stream events. If the CBO doesn't have good statistics, it may choose wrong — leading to slow queries or OOM crashes.

## Why this is different from Postgres

Postgres has B-tree indexes: the planner can probe an index one row at a time and never loads entire tables into memory for most joins. Trino queries Iceberg files in MinIO — no row-level indexes exist. When Trino joins two tables, it must pick a strategy:

- **Broadcast join**: load the smaller table into every worker's memory as a hash table; each worker joins against its local slice of the big table. Fast for small-vs-large joins.
- **Partitioned join (shuffle)**: split both tables by join key so matching rows land on the same worker. Required when both tables are large, but network-expensive.

For your 400M events × 50K accounts join, broadcast is the right call — accounts fits in memory, events does not.

## How Trino decides

Trino's CBO needs two numbers per table:
1. **Row count** — Iceberg always provides this from table metadata (free, always available)
2. **NDV (number of distinct values) per column** — NOT collected automatically; requires `ANALYZE TABLE`

Without NDV, the CBO guesses. Guesses are often wrong. The result: wrong join strategy, slow query, or OOM.

## Diagnosing the plan with EXPLAIN

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT a.account_name, COUNT(*)
FROM iceberg.analytics.events e
JOIN iceberg.analytics.accounts a ON e.account_id = a.id
WHERE e.event_date = DATE '2026-05-27'
GROUP BY a.account_name;
```

Look for:
- `Join[BROADCAST]` on the accounts side → correct, accounts is being broadcast
- `Join[PARTITIONED]` on both sides → both are being shuffled; CBO may not have stats
- `Estimates: {rows: ?}` → question mark means CBO is guessing; run ANALYZE

## Fix: run ANALYZE on both tables

```sql
ANALYZE iceberg.analytics.events;
ANALYZE iceberg.analytics.accounts;
```

After ANALYZE, re-run EXPLAIN — the estimates will show real numbers instead of `?`, and the CBO should pick BROADCAST for accounts automatically.

## Force it if the CBO still gets it wrong

```sql
SET SESSION join_distribution_type = 'BROADCAST';

SELECT a.account_name, COUNT(*)
FROM iceberg.analytics.events e
JOIN iceberg.analytics.accounts a ON e.account_id = a.id
WHERE e.event_date = DATE '2026-05-27'
GROUP BY a.account_name;

RESET SESSION join_distribution_type;
```

Options:
- `AUTOMATIC` (default) — CBO decides; needs statistics to work well
- `BROADCAST` — force broadcast of the smaller (build) side
- `PARTITIONED` — force shuffle of both sides (for large-to-large joins)

## SQL join order as a hint

The left-to-right order in your FROM clause is a hint to the CBO when statistics are absent. Convention: put the smaller table first.

```sql
-- Better hint: small table (accounts) first
FROM accounts a
JOIN events e ON e.account_id = a.id

-- Less helpful: big table first
FROM events e
JOIN accounts a ON e.account_id = a.id
```

This doesn't force the decision, but helps the CBO make a better guess when NDV stats are missing.

## Production workflow for your stack (Trino 467 + Iceberg 1.5.2 + MinIO)

1. After any large ingest into events or accounts, run `ANALYZE TABLE`
2. Before shipping a new join query, run `EXPLAIN (TYPE DISTRIBUTED)` and verify `Join[BROADCAST]` on the dimension side
3. If a join query OOMs or hangs despite ANALYZE, use `join_distribution_type = 'BROADCAST'` as a temporary override while investigating
4. For 3+ table joins, ANALYZE all joined tables — the CBO's job gets harder with more tables

## Summary table

| Situation | What to do |
|---|---|
| CBO guessing (`Estimates: {rows: ?}`) | Run `ANALYZE` on both tables |
| CBO showing `Join[PARTITIONED]` for 50K table | Run ANALYZE; if still wrong, force `join_distribution_type='BROADCAST'` |
| Query OOMing on workers | Check EXPLAIN for which table is the build side; force BROADCAST on the small one |
| New dimension table ingested | Always run `ANALYZE` after first load |
