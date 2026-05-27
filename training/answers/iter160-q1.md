# Iter 160 Q1 — Cross-Catalog Join Performance: Dynamic Filtering and Predicate Pushdown

## Answer

## The Core Problem: You Need Dynamic Filtering

Your 20-minute query (or timeout) is almost certainly happening because **Trino is scanning the entire 500 million Iceberg rows**, even though you filtered the Postgres side. The WHERE clause on Postgres helps, but if the Postgres result set is large and the join isn't optimized, you're still pulling far too much data from Iceberg.

The solution is **dynamic filtering** — a runtime optimization where Trino builds a small list of join keys from the Postgres side and pushes that list back into the Iceberg scan as an extra filter. This can drop your Iceberg read from 500M rows to just the 5–10M rows that could actually join.

## Your Actual Problem: Is One Side Small Enough?

The question is whether your Postgres side, after filtering, returns a small enough result set. If your WHERE clause on Iceberg brings you down to 500 million rows per day, and your Postgres table is 8 million rows **without additional filtering**, dynamic filtering won't help much — the build side is still too large.

**Here's what to check immediately:**

1. **Do you have a selective WHERE on the Postgres side?** Not just on the Iceberg side. For example: `WHERE user_id IN (list of active customers)` or `WHERE tenant_id = '...'` on the Postgres table. This is critical. If your query looks like:
   ```sql
   SELECT ... FROM postgres_table u
   JOIN iceberg_events e ON u.id = e.user_id
   WHERE e.occurred_at > NOW() - INTERVAL '30 days'
   ```
   The Postgres side has no predicate and returns all 8M users. That's why it's slow.

2. **Run `EXPLAIN (TYPE DISTRIBUTED)` on your actual query.** Look for:
   - A `ScanFilterProject` line for the Postgres side — does it show a `filterPredicate`? If yes, that predicate is pushed down to Postgres and you're returning fewer rows. If no, you're pulling all 8M rows over JDBC.
   - A `dynamicFilters = {user_id = #df_...}` annotation on the Iceberg side. This is the runtime filter. If it's missing, dynamic filtering didn't fire.

## What to Actually Do

**Step 1: Add a selective WHERE on the Postgres side.** Instead of joining all 8M users, filter to a meaningful subset first. Examples:
- Active customers only: `WHERE status = 'active'`
- A specific tenant or region
- Users who had any activity in the last 30 days (if you have an index on that)

This keeps the Postgres result set to tens of thousands, not millions. That triggers dynamic filtering.

**Step 2: Verify the filter pushes down.** Run your query with `EXPLAIN (TYPE DISTRIBUTED)` and paste the output. You should see your WHERE clause embedded in the Postgres-side `ScanFilterProject` node. If it appears as a separate `Filter` node above the scan, the predicate didn't push down — that's a separate problem.

**Step 3: Confirm dynamic filtering kicked in.** In the EXPLAIN output, look for `dynamicFilters = {...}` on the Iceberg side. If it's there, you're done and the query should be fast. If it's not, the Postgres result set is still too large (over ~1,000 distinct join keys) — go back to step 1 and make the Postgres filter more selective.

**Step 4: Check your join direction.** Make sure Trino is treating the filtered Postgres side as the **build side** (the smaller side), not the probe side. This is usually automatic if the Postgres result is small enough, but you can verify in EXPLAIN or the Trino UI.

## The Indexing You Already Did Won't Help Enough

You mentioned "made sure the join column is indexed in Postgres" — good, but that only helps if Trino actually queries Postgres selectively. The Postgres index on your join column doesn't reduce the 500M Iceberg rows; it just makes the Postgres lookups fast. You need the **dynamic filter** to prune Iceberg itself.

## One More Thing: Verify Predicate Pushdown Isn't Breaking

If your WHERE clause on the Iceberg side is something like `WHERE event_timestamp LIKE '2026-05%'` (a string range), that **won't push down to Iceberg** by default — Trino will filter in-memory after pulling rows. Replace it with an exact timestamp range: `WHERE event_timestamp >= TIMESTAMP '2026-05-01' AND event_timestamp < TIMESTAMP '2026-06-01'`. This will push down to Iceberg and prune partitions/files.

## When Dynamic Filtering Still Won't Save You

If both the Postgres table and the Iceberg table are genuinely large with no selective predicates, federation is not the right tool. You'd need to ingest the Postgres data into Iceberg as a regular table, or restructure the query to ask a smaller, more specific question. But start with step 1 above first — most 20-minute queries have a missing WHERE clause on one side.
