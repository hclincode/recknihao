# Iter262 Q1 — Fault-Tolerant Execution (FTE) with Federated Postgres+Iceberg Queries

## Answer

Fault-tolerant execution (FTE) is a real feature in Trino that can help with the worker-crash problem you're describing, but there are important nuances with federated queries and some specific risks you should understand before enabling it.

### What FTE Actually Does

Fault-tolerant execution (configured with `retry-policy=TASK` or `retry-policy=QUERY` in your coordinator's `etc/config.properties`) works like this:

**When a worker node goes down during a query**, instead of killing the entire query, Trino can retry the failed task on a different worker. For your 20-30 minute queries, this is genuinely valuable — instead of restarting from scratch, a worker failure only requires re-running the chunk of work that worker was handling.

To make this work, Trino needs an "exchange manager" — a place where intermediate shuffle results survive worker death. In your on-prem environment, this would typically be a filesystem-based exchange spill (using a Kubernetes PVC) or writing to MinIO.

### The Critical Limitation: FTE Only Covers Workers, Not the Coordinator

**Important:** If your **coordinator** goes down, FTE does not help. The coordinator holds the master query plan and all the retry decisions. When it dies, the query dies — FTE enabled or not. Your problem last week (worker node went down) would be helped by FTE. A coordinator failure would not be.

### FTE with Postgres Federated Queries — The Isolation Risk

Here's where you need to be careful. When Trino retries a task that was reading from Postgres:

1. The **original attempt** opens one JDBC connection and one PostgreSQL `SELECT` statement, which takes a `READ COMMITTED` snapshot at that moment.
2. If that task fails and **Trino retries it**, the retry opens a **brand-new JDBC connection** and issues a **brand-new `SELECT`**, which takes a **fresh `READ COMMITTED` snapshot**.
3. **Any rows committed to Postgres between the original attempt and the retry are now visible to the retry**, even though they were not visible to any other part of your query.

In plain terms: if your query joins Iceberg events against Postgres account records, and a worker crashes partway through scanning Postgres, the retry may see Postgres rows that were inserted/updated *after* the original query started. This creates a subtle inconsistency — some of your events may join against stale account records (from the original attempt), while rows from the retry join against newer account records.

**Is this a problem for you?** It depends on your use case:
- If Postgres accounts change infrequently and the query is for analytics (not a financial reconciliation), the inconsistency window is typically small and acceptable.
- If you're doing a critical audit or reconciliation where "state of account at query start time" matters, this is a real risk.

Note: the Iceberg side of your query is always consistent — Iceberg pins to a specific snapshot at plan time, which doesn't change on retry. The inconsistency risk is Postgres-specific.

### Downsides and Behavioral Changes to Expect

1. **Postgres will see more connections and retries.** Expect occasional duplicate or re-executed `SELECT` statements in your Postgres logs when workers fail. This is normal and expected.

2. **Query behavior becomes non-deterministic around failures.** A query that fails and is retried may return slightly different results than the original would have (due to the Postgres snapshot difference above). The Iceberg side is always pinned to its snapshot at plan time, but the Postgres side advances on retry.

3. **Requires an exchange manager setup.** You'll need to configure either a filesystem spill location (PVC) or MinIO-based exchanges. This is infrastructure work — it's not just a flag flip.

4. **No planning benefit.** FTE does not change how Trino plans or optimizes your query — it only adds retry logic for when execution fails. If your queries are slow for planning reasons, FTE won't help.

### Risk Checklist Before Enabling

Before you turn on `retry-policy=TASK`:

- [ ] **Is inconsistency acceptable?** If queries are for analytics dashboards, probably yes. If they're financial reconciliations, no.
- [ ] **Can you set up an exchange manager?** MinIO spill or a Kubernetes PVC with sufficient I/O capacity.
- [ ] **Have you tested it on a non-production cluster first?** FTE is a major behavioral change; test the retry logic with realistic load.
- [ ] **Is your Postgres connection pool stable?** Workers need to be able to cleanly return connections on retry. If your pool is already stressed, adding retry logic may make things worse.

### Better Alternative: Materialize the Postgres Table

If the inconsistency risk concerns you, there's a simpler mitigation that doesn't require FTE infrastructure: **materialize the Postgres dimension into Iceberg on a regular cadence** (every 5-15 minutes, via Spark or dbt). Then both sides of your federated join live in Iceberg, both pinned to snapshots at plan time — no retry-induced inconsistency possible. This also makes your queries faster (no JDBC overhead on every scan).

### Summary

**Enable FTE if:**
- Worker crashes are your immediate production pain point.
- You can accept Postgres snapshot drift on retries (analytics use case).
- You have infrastructure (PVC or MinIO) for the exchange manager.

**Avoid FTE if:**
- You need strong consistency guarantees for federated joins.
- Your current pain is planning time or query complexity, not worker failures.
- You don't have spare storage capacity for exchange spill.
