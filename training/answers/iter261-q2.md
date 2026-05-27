# Iter261 Q2 — Federated CREATE VIEW vs INSERT INTO Iceberg: Does a View Cache Anything?

## Answer

Here's the critical thing to understand: **a Trino view does NOT cache or store anything.** It's pure SQL substitution — every time someone queries the view, Trino rewrites it with the join definition inlined and runs the full join again. A view is *just* a naming convenience; it has no caching layer underneath.

### How Trino Views Actually Work

When you create a Trino view like this:

```sql
CREATE VIEW analytics.customers_with_events AS
SELECT c.id, c.name, e.event_count
FROM app_pg.public.customers c
JOIN iceberg.analytics.event_counts e ON c.id = e.customer_id;
```

And then your dashboard runs:

```sql
SELECT * FROM analytics.customers_with_events WHERE name LIKE '%Acme%';
```

Trino **immediately expands the view name into its definition** and runs it exactly as if the dashboard had typed the full join by hand. The plan you get from `EXPLAIN` shows two TableScans (one from Postgres, one from Iceberg) and a HashJoin operator — the view name is completely gone. This expansion happens **on every single query**. There is no hidden query-results cache, no metadata layer that remembers the last result. Every dashboard refresh re-runs the full federation.

### Option 1: Federated View — Naming Convenience Only

**What it does:** Names the join for ergonomics. Saves your dashboard developers from typing the join 50 times.

**Performance:** Zero caching. Your dashboard still pays the full federation cost per page load. If you have 5 widgets refreshing on page load, you're running the same federated join 5 times.

**Use it when:**
- The dashboard refreshes once per hour or less (federation cost is bounded).
- You care about schema contracts (the view output columns are stable even if the underlying tables change).
- The Postgres table is small enough that the join itself is not the bottleneck.

**Don't use it when:**
- Your dashboard refreshes multiple times per minute (you'll overload Postgres).
- Multiple dashboards query the same view (you're refederating per dashboard instead of once).
- Postgres table size makes the federation join the latency bottleneck.

### Option 2: Nightly Materialization — The Actual Caching Pattern

Instead of a view, you run a scheduled job (dbt, Spark, or a nightly Trino statement) like:

```sql
-- Run this once per night, e.g., at 2 AM
INSERT INTO iceberg.analytics.customers_enriched
SELECT c.id, c.name, c.email, c.plan, e.event_count, e.last_event_date
FROM app_pg.public.customers c
JOIN iceberg.analytics.event_counts e ON c.id = e.customer_id;
```

Now your dashboards query **only** `iceberg.analytics.customers_enriched` — no Postgres reads, no federation at all. Every dashboard refresh reads pre-computed Parquet files on your object store. The join happens **once per night**, not once per page load.

**Performance:** Eliminates the federation cost from dashboards entirely. Dashboards read pre-computed columnar files — much faster than re-running a cross-catalog join.

**Freshness tradeoff:** Your dashboard data is stale by up to 24 hours (or however long your batch window is). If you need sub-hour freshness, run the materialization job more frequently (e.g., every 15 minutes) instead.

**Use it when:**
- Multiple dashboards query the same join (materializing once is cheaper than re-federating per dashboard).
- Dashboard traffic is high (many page loads per hour).
- Your freshness tolerance is hours, not minutes.
- The Postgres table is large enough that federation is the bottleneck.

### The Key Comparison

| Aspect | Federated View | Materialized Iceberg Table |
|---|---|---|
| **Result caching** | None — re-federates every query | Yes — reads pre-computed files |
| **Postgres load per page load** | Full federation cost × dashboard refresh count | Zero (until the next batch) |
| **Join cost per query** | Paid every time | Paid once per night (batch refresh) |
| **Freshness** | Live (a few seconds of replica lag) | Stale (hours or minutes, depending on batch window) |
| **Maintenance** | None | A periodic INSERT/MERGE job |
| **Right for** | Low-traffic dashboards, ad-hoc queries, developer ergonomics | High-traffic dashboards, large joins, acceptable staleness |

### What to Do Now

**Your situation:** "Every dashboard widget runs this join fresh every time a user loads the page, and it's getting slow."

This is the classic symptom that a federated view is the wrong tool. The federation cost scales linearly with dashboard refreshes. Postgres is getting hammered.

**Next step:** Measure how many times per minute your dashboards run this join. If it's more than a few queries per minute, **stop using a view and materialize the join into Iceberg**. Set up a nightly (or hourly) job that runs the INSERT, and point your dashboards at the Iceberg table instead.

If you're currently on 5-10 dashboard page loads per day, keep the federated view — it's fine. If you're on 50+ per day, or multiple dashboards are reading the same view, materialize.

### Summary

A Trino view is pure SQL substitution — it re-runs the full federation on every query, no caching. For high-traffic dashboards hitting a slow Postgres+Iceberg join, the answer is to materialize the result into an Iceberg table with a periodic INSERT job. Dashboards then read only the Iceberg table (no Postgres reads, no federation cost per page load). The trade-off is data staleness — the Iceberg table is as fresh as your last batch run.
