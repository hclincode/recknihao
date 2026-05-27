# OLAP vs OLTP: What's the Difference and Why It Matters for SaaS

> **Note:** The production environment in `prod_info.md` is not yet filled in. This resource gives advice for a generic SaaS setup. Once your stack is described, re-read this with your specific tools in mind.

---

## Concept in one sentence

**OLTP** (Online Transaction Processing) is your regular application database — it records individual events fast. **OLAP** (Online Analytical Processing) is a different class of system built to *ask questions across millions of those events at once*.

---

## Why it matters for SaaS

Every SaaS product runs on an OLTP database (Postgres, MySQL, etc.) to serve users — saving orders, updating records, checking balances. That works great for one row at a time.

The problem appears when your product manager asks: *"How many users completed onboarding last month, broken down by plan tier?"* Your OLTP database will answer that — slowly. It has to scan thousands or millions of rows, touch columns it doesn't need, and lock up resources that your live application also needs. As you scale, these analytical queries start degrading the user experience, or you start giving up and avoiding the question altogether.

OLAP systems are designed so those questions are *cheap*, fast, and don't compete with your application traffic.

---

## Concrete example

Imagine your SaaS has 500,000 user accounts and logs every feature interaction in a `events` table (50 million rows).

**OLTP query (what your app does):**
```sql
SELECT * FROM users WHERE id = 12345;
-- Returns 1 row. Milliseconds. Fine.
```

**Analytical query (what your BI dashboard needs):**
```sql
SELECT feature, COUNT(*), AVG(duration_ms)
FROM events
WHERE created_at >= '2024-01-01'
GROUP BY feature
ORDER BY COUNT(*) DESC;
-- Scans 50M rows. On Postgres: minutes. On ClickHouse or BigQuery: seconds.
```

On your production Postgres, that second query competes for disk I/O with every user currently using your product. On an OLAP system, it's isolated and optimized for exactly this shape of work.

---

## When to use OLAP / when not to

**Reach for OLAP when:**
- Analytical queries are noticeably slow on your production DB (>1–2 seconds for dashboard queries)
- You want to run reports without affecting application performance
- You're aggregating across millions of rows regularly
- Multiple stakeholders (data team, CS, execs) need to run ad-hoc queries
- You need to join data from multiple sources (app DB + Stripe + Mixpanel)

**Stick with OLTP (your regular DB) when:**
- You have fewer than ~1–5 million rows in the tables you're querying
- Analytics is rare and internal (you can afford to run it off-hours or on a read replica)
- Your product is early-stage and the overhead of a second system isn't worth it
- A Postgres read replica with a few good indexes solves your problem today

**The rule of thumb:** your OLTP database *can* do analytics; OLAP makes it *practical* at scale without hurting your users.

---

## Before you switch: Postgres tuning checklist

Most "we need a warehouse" complaints turn out to be untuned Postgres. Work through this list before standing anything up:

- **Read replica.** Stream a replica and point all analytics (BI, ad-hoc, dbt-on-Postgres) at it. The primary stops competing with analytical scans. Single highest-impact fix.
- **Partial indexes.** `CREATE INDEX ... WHERE deleted_at IS NULL` for soft-deleted SaaS data, or `WHERE plan_type = 'enterprise'` for skewed segments. Smaller indexes, faster scans.
- **Materialized views.** Pre-compute the slow dashboard query (`signups_by_plan_daily`) and refresh on a schedule. The dashboard does a point-lookup instead of an aggregate scan.
- **`EXPLAIN ANALYZE` every slow query.** Look for `Seq Scan`, sorts spilling to disk, or nested loops over big tables. Often the fix is one missing index.
- **`pg_partman` for table partitioning.** Split a 200M-row `events` table into one partition per month. Queries with `WHERE created_at >= ...` only scan the partitions they need.
- **`pg_stat_statements` and connection pooling.** Find your real top-10 slowest queries; put PgBouncer in front so analytics tools can't exhaust connections.

If after all of this your dashboards are still slow, *that's* when OLAP earns its complexity. See `06-when-to-add-olap.md` for the migration path.

---

## Why read replicas help but don't fully solve it

A Postgres read replica is the right first move — it stops analytics from competing for the primary's CPU and I/O. But once your analytical workload gets serious, three failure modes show up on the replica that no amount of tuning will eliminate. They are structural, not configurational.

1. **The replica is still row-oriented.** A query like `SELECT AVG(duration_ms) FROM events WHERE created_at >= '2024-01-01'` only needs two columns, but Postgres stores rows together on disk. The replica must read every column of every matching row off disk into memory, then throw away the columns it doesn't need. The I/O and CPU cost is identical to running the same query on the primary — you've just moved *where* it hurts, not reduced *how much* it hurts. A columnar engine (Trino over Iceberg) reads only the two columns from object storage, which is often a 10–50x reduction in bytes scanned.

2. **Long analytical scans grow replication lag.** A multi-minute analytical scan holds open a transaction and a WAL position on the replica. While that scan runs, the replica cannot apply newer WAL records that would conflict (or, if `hot_standby_feedback` is on, the primary delays vacuum). The result: replication lag grows during your heaviest analytics windows, which is exactly when application reads on the replica (read-after-write for users routed there, dashboards expecting fresh data) start returning stale rows. You discover this the day finance runs end-of-month reports and the product dashboard starts showing yesterday's data.

3. **The structural fix is moving analytics off Postgres entirely.** In the production stack (Spark + Iceberg on MinIO, Trino for queries), analytics queries (a) read only the columns they aggregate — columnar Parquet on object storage, (b) run on distributed compute that scales horizontally with no impact on Postgres, and (c) share zero resources (CPU, memory, WAL, connections) with the OLTP path. The read replica is a useful bridge — Iceberg + Trino is the destination.

---

## Key terms defined

| Term | Plain meaning |
|---|---|
| **OLTP** | The database your app writes to constantly — optimized for fast single-row reads and writes |
| **OLAP** | A system optimized for scanning large amounts of data and computing aggregations |
| **Analytical query** | A question like "sum/count/average over all rows matching X" — as opposed to "fetch row with id=Y" |
| **Read replica** | A copy of your OLTP database that you can query without touching the primary; a lightweight first step before full OLAP |
| **Aggregation** | Collapsing many rows into a summary: SUM, COUNT, AVG, MIN, MAX |
| **HTAP** | Hybrid Transactional/Analytical Processing — newer systems that try to do both; useful to know the term, but most SaaS teams still separate the two |

---

## Summary

Your application database (OLTP) is optimized for serving users one request at a time. Analytical questions require scanning and summarizing huge amounts of data, which is what OLAP systems are designed for. As a SaaS product grows, the practical reason to add an OLAP layer is *protecting application performance* and *making analytics fast enough to actually use*.
