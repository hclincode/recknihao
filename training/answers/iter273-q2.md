# Iter273 Q2 — Federate or Ingest: The Deciding Factors for Cross-Catalog Joins

## Answer

The decision boils down to three measurable factors: **table size, query frequency, and freshness requirements**. Here's a concrete framework to answer this for your specific situation.

### The Core Trade-off

**Keep federating** (query Postgres through Trino) when:
- The Postgres table is small enough that re-scanning it per query is fast
- Queries are infrequent enough that cumulative JDBC cost is acceptable
- You need data to always be current without ingestion lag

**Ingest into Iceberg** (snapshot Postgres data on a schedule) when:
- The table is large and the same join runs repeatedly
- Postgres replica load or JDBC overhead becomes a bottleneck
- You can tolerate some lag between the live app and analytics

### The Decision Table

| Postgres Table Size | Queries/Day | Lag Tolerance | Decision |
|---|---|---|---|
| < 10M rows | Any | Any | **Federate** — JDBC cost is trivial |
| 10M–100M rows | < 10 | None required | **Federate** — occasional scans are fine |
| 10M–100M rows | 10–100 | Hours acceptable | **Ingest nightly** |
| 10M–100M rows | > 100 | Minutes acceptable | **Ingest frequently** (hourly or every 5 min) |
| > 100M rows | Any | Any | **Ingest** — federation becomes a bottleneck |

### Factor 1: Table Size (The Entry Point)

**< 10 million rows** → federate. A 10M-row Postgres table scans in 1–2 seconds. Trino fetches it over JDBC, dynamic filtering pushes the Iceberg join key back to reduce rows if you're on an INNER JOIN. Total overhead is acceptable even at moderate query volume.

**10M–100M rows** → it depends on frequency and freshness. At this scale, a full scan takes 5–30 seconds. That's fine for 5 queries a day; it's a problem for 200.

**> 100M rows** → ingest. Full-table scans will saturate your Postgres replica within weeks of dashboard growth.

### Factor 2: Query Frequency (The Multiplier)

Use this formula:
```
daily_postgres_cost_seconds = scan_duration_seconds × queries_per_day
```

If `daily_postgres_cost_seconds > 600` (10 minutes of Postgres scanning per day on this one table), ingesting is almost always cheaper than federating — one nightly Spark job replaces hundreds of JDBC scans.

**Your situation**: You have a Postgres `accounts` table and "some queries are slow." Run `EXPLAIN ANALYZE` on your slowest join to see the actual `Input: X rows` at the Postgres TableScan. If Trino is reading millions of rows from Postgres on every query, that's the bottleneck.

### Factor 3: Freshness Requirements

**Sub-second freshness required** → federate (only option).

**Minutes of lag acceptable** → ingest on a short schedule (every 5 min with an incremental watermark).

**Hours of lag acceptable** → ingest nightly (simplest operationally).

For your `accounts` table: account metadata (name, plan, tier) doesn't change per-second. Hourly or nightly sync is usually fine for analytics.

### The Dimension vs Fact Test

**Dimension tables** (small, join-key, stable): < 10M rows, changes rarely → **always federate**. Examples: `accounts` (10K rows), `plans` (100 rows), `tenants` (200 rows). JDBC overhead for 10K rows is negligible.

**Fact tables** (large, high volume, constantly growing) → **ingest immediately**. Examples: `events`, `pageviews`, `orders`. Even moderate-traffic dashboards will saturate Postgres if they repeatedly scan fact tables over JDBC.

### Three Architecture Patterns

**Option A: Direct federation** — `JOIN app_pg.public.accounts ON ...` in every query. Works for small tables and low traffic. Every query opens a JDBC connection to Postgres.

**Option B: Nightly ingest** — snapshot the Postgres table to Iceberg once a night, dashboards query Iceberg:

```sql
-- Nightly job (idempotent with MERGE INTO)
MERGE INTO iceberg.analytics.accounts_snapshot AS target
USING (
  SELECT id, tenant_id, name, plan, updated_at
  FROM app_pg.public.accounts
  WHERE updated_at > CURRENT_TIMESTAMP - INTERVAL '25' HOUR
) AS source
ON target.id = source.id
WHEN MATCHED THEN UPDATE SET name = source.name, plan = source.plan, updated_at = source.updated_at
WHEN NOT MATCHED THEN INSERT (id, tenant_id, name, plan, updated_at)
  VALUES (source.id, source.tenant_id, source.name, source.plan, source.updated_at);
```

Postgres is touched once per night. All 100+ daily dashboard queries read Iceberg (fast, columnar, no JDBC).

**Option C: Hybrid** — keep Postgres federated for ad-hoc queries that need live data; pre-join and materialize the most common join for high-traffic dashboards:

```sql
-- Materialize the hot join nightly
INSERT OVERWRITE iceberg.analytics.events_with_accounts
SELECT e.event_id, e.event_time, a.account_name, a.plan
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.account_id = a.id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '90' DAY;
```

Dashboards query `events_with_accounts` (Iceberg, fast). Live-data queries still go to Postgres directly for freshness.

### The Quick Diagnostic for Your Situation

Run these two checks to make the decision:

**Check 1: How big is your Postgres `accounts` table?**
```sql
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT COUNT(*) AS row_count FROM public.accounts'
  )
);
```

**Check 2: Is Trino reading the whole table on every join?**
```sql
EXPLAIN ANALYZE
SELECT e.event_id, a.account_name
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.account_id = a.id
WHERE e.event_date >= CURRENT_DATE - INTERVAL '7' DAY
  AND a.tenant_id = 'acme';
```

Look at `Input:` at the Postgres TableScan node. If it shows millions of rows and your table has millions of rows, Trino is full-scanning Postgres on every query. That's when ingestion pays off.

### Concrete Recommendation for Your Setup

Based on what you described (Postgres `accounts` as a lookup, Iceberg `events` as the fact table):

1. **If `accounts` is < 10M rows and queries run < 50 times/day** → keep federating, but make sure you're using INNER JOIN (not LEFT) so dynamic filtering can push the join-key IN-list back to the Iceberg scan
2. **If queries run 50+ times/day** → ingest `accounts` nightly with MERGE INTO, dashboards read Iceberg only
3. **If you need always-current `accounts` but high query volume** → hybrid: ingest for dashboards, federate for live lookups

The lift for nightly ingestion is smaller than it sounds — a single MERGE INTO query in a scheduled job handles it, and the `accounts` table is already relatively small compared to `events`.
