# Iter 161 Q2 — Federation vs Ingest: When to Keep Tables in Postgres

## Answer

## No, "always move to Iceberg" is not the right rule.

Your 20-minute-to-30-second speedup is real and dramatic — but it's not telling you to ingest everything. That query was slow **because you were joining a large Iceberg table to a Postgres table across catalogs**, and the federation connector wasn't optimized for that case. Moving the reference table to Iceberg fixed the join performance, but that doesn't generalize to settings tables that change constantly.

Here's the decision framework:

### When to keep tables in Postgres and federate them

**Freshness matters more than query speed.** Your settings table that applications write to every few seconds is the perfect example. If you move it to Iceberg:
- Your ingestion pipeline introduces latency (even the fastest batch ingestion is minutes at best, usually hours).
- Any setting change takes that long to appear in analytical queries.
- Dashboards and reports are stale relative to what the application actually sees right now.

Instead, keep the settings table in Postgres and query it live via the federation connector. Trino can join it to Iceberg events in a single query. Yes, cross-catalog joins run on Trino workers (not in Postgres), but small dimension tables joined to larger fact tables are **exactly what dynamic filtering is optimized for** — Trino derives the join keys from the small Postgres side and pushes that filter into the Iceberg scan, which drastically reduces the rows read.

### When to ingest to Iceberg

Move tables to Iceberg when:

1. **The query repeats constantly.** A dashboard running every 30 seconds should not hammer your operational database. Ingest it once, query Iceberg forever.
2. **You're aggregating historical data.** Iceberg's columnar format with partition pruning and predicate pushdown will outperform row-oriented Postgres by orders of magnitude for "sum all transactions from the last 5 years grouped by month."
3. **You need to isolate load.** Heavy analytical reporting on a live operational table (even a read replica) can still cause problems — connection pool exhaustion, replica CPU contention. Iceberg isolates you.

### The hybrid pattern (best practice for changing data)

For tables that are both queried frequently and updated live, use a **hybrid pattern**:
- **Iceberg** holds historical data (everything older than 1 hour).
- **Postgres** via federation provides the live tail (the last hour of changes).
- A **UNION ALL view** stitches them together so dashboards see both.

This gives you cheap analytical queries on history (Iceberg's columnar storage) plus absolute freshness on recent changes (Postgres live read), through a single seamless table from the user's perspective.

The settings table specifically might not even need the hybrid pattern — if it rarely gets queried analytically (more likely it's just referenced to add context to user events), you can keep it purely in Postgres and federate it on-demand.

### The real lesson from your speedup

Your 20-minute → 30-second improvement came from **moving a small table closer to where it was being joined**, not from "use Iceberg for everything." If you had instead added better predicates to your Postgres side or tuned dynamic filtering, that join might have been fast too. The right tool depends on:

- **How often the data changes**: fast-changing = stay in Postgres with federation
- **How often it's queried analytically**: frequent analytical queries = ingest to Iceberg
- **How large the table is**: small dimension = federation is fine

Leave the settings table in Postgres. You'll save yourself ingestion complexity and stay consistent with the application's source of truth.
