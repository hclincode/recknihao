# Iter 230 Q1 — EXPLAIN ANALYZE for Federated Cross-Catalog Query Diagnosis

## Answer

### What EXPLAIN ANALYZE Actually Shows

First, understand that `EXPLAIN ANALYZE` **actually executes your query** to collect real runtime statistics — so it's not a cheap operation. You're re-running the actual expensive query. For a one-minute query, be prepared to spend one more minute understanding it.

When you look at the output, you'll see fragments (parallel execution stages) and operators. Each operator block prints:

- **`CPU:`** — actual compute time the operator spent on workers
- **`Scheduled:`** — total wall-clock time the operator was scheduled (use this, not "Wall time" — that field doesn't exist in Trino 467)
- **`Blocked: Input` / `Blocked: Output`** — time waiting on upstream data or downstream capacity
- **`Input:`** — logical rows and uncompressed size the operator read
- **`Physical Input:`** — actual bytes read from storage (Iceberg or the MySQL connector)

### The Three-Layer Problem in Federated Queries

When a cross-catalog query is slow, it's almost always one of these:

**1. The Iceberg side is scanning too much data**

Look at the scan operator for your Iceberg table. If `Physical Input:` is much larger than expected — say your query should only touch one day of data but `Physical Input` shows 90 days' worth — partition pruning or file skipping broke down on the Iceberg side. This is **not** a federation problem; it's an Iceberg query issue.

Check this first: does your WHERE clause filter on a **partition column**? If you're filtering on a non-partition column (like `event_type = 'signup'` when the table is partitioned by `event_date`), the Iceberg side scans every file. That's your problem.

**2. Dynamic filtering from the MySQL side didn't push down**

Here's what *should* happen on a fact-to-dimension join (large Iceberg events × small MySQL customers):

- Trino scans the small MySQL `customers` table first (the "build" side of the join)
- It derives a runtime predicate from the join key — for example, a list of valid `customer_id` values: `IN (123, 456, 789, ...)`
- It pushes that predicate back to the Iceberg scan before running the join (this is called "dynamic filtering")
- The Iceberg side only reads files that *might* contain those customer IDs

**If dynamic filtering didn't fire**, the Iceberg scan reads every row, then the join filters it down post-scan — much slower.

To see if dynamic filtering is working: look at the EXPLAIN output for a "DynamicFilter" or "DynamicFilterAssignment" operator node. If you don't see one, or if you see it but the `Blocked: Input` time on the Iceberg scan is very high, dynamic filtering either didn't trigger or timed out waiting for the MySQL side.

**Why dynamic filtering might not work:**
- **The MySQL table is too large.** If the build side (MySQL) doesn't finish quickly, Trino times out waiting for the dynamic filter and proceeds without it.
- **The join key has low selectivity.** If joining on a column that appears in many rows (like `region_id` with only 5 values), the dynamic filter is just a small IN-list and doesn't buy much.

**3. The join distribution was inefficient**

Look for `Join[BROADCAST]` or `Join[PARTITIONED]` in the EXPLAIN output.

- If you see `PARTITIONED` and the MySQL table is tiny (< 100 MB), that's wrong — Trino should broadcast it. This means the cost-based optimizer (CBO) either lacks table statistics or underestimated the build side.
- If you see `BROADCAST` and the MySQL table is gigabytes, that's wrong — BROADCAST would OOM every worker.

### Practical Checklist — When Your 1-Minute Query is Slow

Work through these in order:

**Step 1: Check the Iceberg `Physical Input`**

```
ScanFilterProject[table = iceberg:analytics.events$data, ...]
    Physical Input: 2.10GB
```

Does 2.10GB match what you expect? If your query filters to one day and 2.10GB is the entire month's data, **partition pruning is broken**. Check if your WHERE clause uses a partition column. Example that WORKS: `WHERE event_date >= CURRENT_DATE - INTERVAL '1' DAY`. Example that DOESN'T: `WHERE event_type = 'signup'` (if `event_type` is not a partition column).

**Step 2: Check for dynamic filtering in the plan**

Search the EXPLAIN output for `DynamicFilter`. If it's there and the Iceberg scan has low `Blocked: Input` time, dynamic filtering is working. If it's absent or the Iceberg scan shows high `Blocked: Input`, the MySQL side was either too slow to return results or timed out.

**Step 3: Check the MySQL scan operator**

Look at the scan operator for your MySQL table. Check its `Scheduled:` time and `Physical Input:`. The MySQL side should be fast — a scan of a few million rows takes seconds, not minutes.

If the MySQL scan itself is slow, check: Is there a WHERE filter on the MySQL side? Are you selecting a lot of columns? If the MySQL query is slow in isolation, that's a MySQL replica issue or a missing index — not a Trino problem.

**Step 4: Check the join type**

Look for `Join[BROADCAST]` or `Join[PARTITIONED]` in the plan.

- If it says BROADCAST and memory usage is high, the broadcast might be oversized.
- If it says PARTITIONED and you expected BROADCAST (because you know the MySQL table is small), the CBO lacked statistics. Run `ANALYZE TABLE` on both sides to populate NDV (number of distinct values) so the optimizer makes a better decision. For MySQL catalogs, run native `ANALYZE` on the MySQL replica — `SHOW STATS FOR app_mysql.public.customers` on the Trino side shows if MySQL's statistics are populated.

**Step 5: Check for network/I/O time**

If `Scheduled:` >> `CPU:` (e.g., 45s scheduled, 5s CPU), the query is I/O-bound, waiting for data from Iceberg or MySQL, not compute-bound. That's expected on a remote scan.

### Key Insight: It's Rarely a "Federation Problem"

Most "federated query is slow" issues are actually:
1. Iceberg partition/file skipping misconfigured
2. MySQL table scan missing a filter or index (MySQL replica issue)
3. CBO lacking statistics so it picked the wrong join type (run ANALYZE on both sides)

The federation layer itself — Trino's ability to push predicates to MySQL and pull data via JDBC — is fast. What's slow is usually *data volume* because filtering broke down.
