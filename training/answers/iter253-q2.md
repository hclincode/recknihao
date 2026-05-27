# Iter253 Q2 — Timeout Coordination Between Trino and Postgres in Federated Queries

## Answer

You have discovered a critical reality in federated queries: **there is not one timeout — there are multiple timeout layers stacked on top of each other, and each can independently kill your query.** Your Trino `query.max-execution-time` at 15 minutes is only the outermost layer. Your DBA's Postgres `statement_timeout` is a much more powerful one that fires inside Trino's timeout window, and the two need to be coordinated.

## How to Identify Which Timeout Fired from the Error Message

Open the Trino Web UI (`http://<coordinator>:8080/ui/`), find your failed query, and look at the **Query Details** page's error section. The verbatim error string tells you exactly which layer fired:

| Error message you see | What it means | Which layer |
|---|---|---|
| `ERROR: canceling statement due to statement timeout` | Postgres itself killed the query on the replica. The connection is alive; only this statement was cancelled. | **Postgres `statement_timeout`** |
| `Query exceeded maximum time limit of Xm` (e.g., `10.00m`) | Trino's own `query.max-execution-time` or `query.max-run-time` fired. | **Trino** |
| `java.net.SocketTimeoutException: Read timed out` | The JDBC driver gave up waiting for a response from Postgres. Postgres may still be running the query. | **JDBC socket timeout** |

Based on your description — failure after about 10 minutes, something about the query being cancelled on the Postgres side — you are almost certainly seeing the first error: `ERROR: canceling statement due to statement timeout`. That error comes verbatim from Postgres, not from Trino. Your DBA's `statement_timeout` on the read replica is active and killing statements that run longer than it allows.

## Why the Two Timeouts Are Fighting Each Other

Here is what happens inside your federated query:

1. Trino launches the query and starts a 15-minute clock for `query.max-execution-time`.
2. Trino sends the pushed-down SQL to Postgres over a JDBC connection.
3. **Postgres has its own `statement_timeout`** — say 5 minutes, set cluster-wide in `postgresql.conf` or per-role via `ALTER ROLE trino_reader SET statement_timeout`.
4. **Postgres cancels the query at 5 minutes, regardless of what Trino is doing.** Postgres does not know about Trino's 15-minute limit.
5. Trino receives the cancellation from Postgres and reports: `ERROR: canceling statement due to statement timeout`.

The two timeouts are not coordinating — they are racing. Whichever fires first wins (from your perspective, loses). Postgres's timeout is firing before Trino's.

## The Right Way to Coordinate: Belt-and-Suspenders Ordering

Think of timeout layers like nested Russian dolls. **The rule: the innermost layer (the database) should fire first, and the outermost layer (Trino) should fire last.** This produces the cleanest failure mode and does not waste replica CPU.

Proper ordering from innermost (fires first) to outermost (fires last):

1. **Innermost**: Postgres `statement_timeout = '5min'` — Postgres kills the statement cleanly.
2. **Next**: JDBC `socketTimeout=60` (seconds) — the driver gives up if Postgres goes silent mid-query.
3. **Next**: Trino `query.max-execution-time = 10m` — caps active compute time.
4. **Outermost**: Trino `query.max-run-time = 15m` — caps total user-perceived time.

**Why Postgres first is better**: A Postgres `statement_timeout` cancellation does NOT break the JDBC connection — only the statement is killed; the connection stays in the pool. Socket-level timeouts often discard the connection entirely, increasing reconnection churn. The two Trino-side caps catch any cases where the lower layers do not.

**What happens if you reverse the order** (Trino fires first): Trino cancels the query cluster-wide and abandons the JDBC connection. Postgres does not know it was cancelled and continues running the query on the replica, wasting replica CPU. The next time someone checks the replica's process list, they will see orphaned Trino queries still executing.

## Implementation

### Step 1: Check and Set Postgres `statement_timeout` on the Replica

Connect to the replica and check what is set on the `trino_reader` role:

```sql
-- On the Postgres replica:
SELECT rolname, rolconfig
FROM pg_roles
WHERE rolname = 'trino_reader';
```

Set it explicitly if not present:

```sql
-- On the Postgres replica, for the trino_reader role:
ALTER ROLE trino_reader SET statement_timeout = '5min';
SELECT pg_reload_conf();
```

### Step 2: Set Trino's Timeout Layers in `etc/config.properties`

```properties
query.max-execution-time=10m    # cap on active compute time only
query.max-run-time=15m          # cap on total elapsed time (includes queue wait)
```

## Key Distinction: `query.max-execution-time` vs `query.max-run-time`

These are NOT the same — this trips engineers up constantly:

- **`query.max-execution-time`**: counts **active compute time only**. Does NOT include time spent waiting in a resource-group queue for a concurrency slot. Does not include analysis or planning time. Starts ticking only when workers begin executing.
- **`query.max-run-time`**: counts **total elapsed wall-clock time** from when the user submitted the query to when it succeeded, failed, or was killed. Includes analysis + planning + queue wait + active execution. This is what the user actually experiences.

**Example**: A query waits 9 minutes in a resource-group queue then executes for 1 minute. `query.max-execution-time=10m` will NOT fire (it counts only the 1-minute execution window). `query.max-run-time=5m` WILL fire (it counts the full 10 minutes from submission). For "the user complained the query hung for several minutes" reports, `query.max-run-time` is the correct limit to set.

## If Postgres Keeps Killing Your Legitimate Queries

### Option 1: Raise the Postgres `statement_timeout` (quick but risky)

```sql
ALTER ROLE trino_reader SET statement_timeout = '10min';
```

Adjust to match your legitimate workload duration. But be careful: a long timeout can mask bad query plans. A query that takes 10 minutes but should take 30 seconds (because pushdown failed or there is a Cartesian join) will silently consume replica resources.

### Option 2: Fix the Query to Push Down Properly (the Right Approach)

Check whether predicates are actually pushing down to Postgres. While your federated query is running, check what SQL Postgres actually received:

```sql
-- On the Postgres replica:
SELECT pid, query_start, state, query
FROM pg_stat_activity
WHERE usename = 'trino_reader';
```

If you see a full table scan (`SELECT col1, col2, ... FROM table`) instead of a filtered query (`SELECT col1, col2, ... FROM table WHERE date > '2025-01-01'`), the predicate pushdown failed. The query is dragging the full table over JDBC, which will hit `statement_timeout` much faster than a filtered query would.

### Option 3: Defense in Depth — Add an Idle-Transaction Guard

```sql
-- On the Postgres replica:
ALTER ROLE trino_reader SET idle_in_transaction_session_timeout = '60s';
```

This catches sessions left in transaction state with no active query — a rare but real scenario if a Trino worker dies mid-transaction. Without this, an orphaned session holds locks indefinitely.

## Summary

**Should the Trino timeout be shorter, longer, or the same as Postgres?**

**Trino's timeout should be LONGER than Postgres's.** Let Postgres kill runaway queries first — cleanly, without breaking JDBC connections. Trino's timeouts act as outer safety caps.

Typical production setup:
- Postgres `statement_timeout = '5min'` (fires first — clean statement cancellation, connection preserved)
- JDBC `socketTimeout=60` (seconds, fires if Postgres goes silent)
- Trino `query.max-execution-time = 10m` (fires if Postgres lets it run past 5 min)
- Trino `query.max-run-time = 15m` (outer cap on total elapsed time including queue wait)
