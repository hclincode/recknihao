# Iter244 Q2 — Ingest vs. Federate: 500M-row Iceberg × 50M-row PostgreSQL Join

## When federation with a 50M Postgres table actually works

Trino's PostgreSQL federation connector uses **predicate pushdown** — it can push `WHERE` clauses down to Postgres before pulling data. More importantly, if you're joining your small customer profiles (50M rows) *against* the large event log (500M rows), Trino uses **dynamic filtering**: it builds a list of the tenant IDs (or customer IDs) actually in your event sample, converts that to an IN-list, and pushes it to Postgres. This means you may not pull all 50M profiles — only the ones that match the join.

**But here's the catch:** predicates push down cleanly for equality/IN/IS NULL. Range predicates on VARCHAR columns do NOT push down by default. And dynamic filtering only helps if:
1. Your join key is selective (if 99% of customer IDs are in the event log anyway, the IN-list doesn't filter much).
2. Your profile table fits in Trino's broadcast size (default 100MB). 50M rows of customer data are probably larger, so Trino will stream the probe side instead — less efficient.

For a 50M-row dimension table, **you're at the edge of what federation handles gracefully.**

---

## Observable signals that federation is failing

Before you decide to copy, measure whether federation is actually breaking things:

- **Postgres read-replica CPU sustained >70%** during query load and attributable to Trino's JDBC connection (check `pg_stat_activity`).
- **Query latency exceeding your SLO** — if the join takes >2 seconds consistently and your dashboard expects <500ms, federation is too slow.
- **Query volume share >20%** — if Trino federation is now responsible for >20% of all queries hitting that Postgres table, you've shifted from "live data tail" to "primary analytical workload," and Postgres is the wrong tool.
- **Physical input bytes on the Postgres scan in `EXPLAIN ANALYZE VERBOSE`** approaching the full 50M-row table size, even with a WHERE clause — this means predicate pushdown failed and you're doing a full table scan over JDBC.

**If you're not seeing those signals yet, federation may be fine.** One Trino query scanning 50M rows once a day is not the same as doing it every 5 seconds.

---

## When to copy the Postgres table into Iceberg

Three decision points:

### 1. If queries are repeating and dashboards refresh often
Pay the ingestion cost once at write time, then serve infinite fast reads from Iceberg. This is the strongest case for copying.

**How often does the customer table actually change?** If it changes once per hour and your dashboards refresh every 5 minutes, an hourly incremental Spark job copying the delta into Iceberg is strictly better than repeatedly pulling 50M rows over JDBC.

### 2. If your Postgres replica is already under load
Migrate to Iceberg when read-replica CPU stays >70% during business hours AND you can attribute it to Trino. At that point, moving the table to Iceberg removes the load entirely (Trino reads MinIO, not Postgres). You don't pay per-query anymore.

### 3. If freshness tolerance is >15 minutes
**Federation is only worth the operational cost when sub-minute freshness is mandatory.**

If your product manager says "we need real-time customer profile data," that means <30 seconds. But if they mean "within 15 minutes is fine," then: **a 15-minute Spark micro-batch into Iceberg beats federation on every dimension** — faster queries, no Postgres load, snapshot-isolated reads, time travel, partition pruning.

---

## The practical decision framework

- **Start with full refresh** — Spark JDBC read + Iceberg rewrite every night. Takes maybe 5-10 minutes for 50M rows. Simplest shape.
  - Use the **staging table + view swap** pattern to eliminate the brief table-not-found window during reload.
  - Once nightly stabilizes, measure Postgres replica load. If it's acceptable, stop there.

- **If nightly is too stale,** move to **incremental refresh** — Spark reads only rows where `updated_at > last_run_ts` and appends/upserts to Iceberg. Most Postgres tables have an `updated_at` column; if not, add one with a trigger.
  - For the 50M customer table, an hourly incremental job reading only changes (maybe 100K rows/hour) is 500× lighter than a full 50M re-read.
  - Use `overwritePartitions()` or `MERGE INTO` (not `append()`, which is not idempotent).

- **If you need sub-minute freshness** (e.g., a feature flag or billing-tier table that app servers read), then federation stays your answer, OR you graduate to CDC (Debezium + Kafka + Spark Structured Streaming). This is higher complexity but is the only way to get sub-minute freshness without hammering Postgres every query.

---

## Row count and change-frequency heuristics

| Scenario | Verdict | Why |
|---|---|---|
| Joining 1× per day, no SLA | Federate | One query hitting 50M rows once a day is fine. |
| Dashboard refreshes every 5 min | **Copy to Iceberg** | Paying the full 50M JDBC cost 12× per hour is wasteful; hourly incremental ingest is better. |
| Replica CPU >70% attributable to Trino | **Copy to Iceberg** | Postgres is overloaded; remove the load. |
| Freshness tolerance is 2+ hours | **Copy to Iceberg** | No reason to pay federation's per-query cost; batch ingest is cheaper and faster. |
| Table changes <100 rows/hour | Incremental ingest every 15 min | Spark reads only the delta; Postgres load = near zero. |
| Table changes 1000s rows/hour + need <5 min freshness | **CDC (Debezium)** | Only pattern that scales. |

---

## The hybrid pattern (often the real answer)

Most production SaaS teams run: **Iceberg holds everything older than 1 hour; Postgres (federated) provides the live 1-hour tail.** A single view stitches them together:

```sql
CREATE OR REPLACE VIEW analytics.customers_live AS
  SELECT * FROM iceberg.analytics.customers
  WHERE updated_at < (current_timestamp - INTERVAL '1 HOUR')
UNION ALL
  SELECT * FROM app_pg.public.customers
  WHERE updated_at >= (current_timestamp - INTERVAL '1 HOUR');
```

This way:
- The Iceberg side uses partition pruning (scanning only the latest hour's partition).
- The Postgres side pushes down the time predicate (scanning only the last hour's rows).
- Your event-join query hits the view, gets fresh data on both sides, and Postgres never re-scans the full 50M rows.

---

## Your next step

1. **Measure first.** Run your join query 10 times. Capture `physicalInputBytes` from the Postgres scan via `EXPLAIN ANALYZE VERBOSE`. If it's close to "50M rows × row width," predicate pushdown failed — time to copy. If it's much smaller, federation is working.

2. **If replicating: start with nightly incremental.** Add a trigger for `updated_at` if missing, then a simple Spark job reading `WHERE updated_at > last_run_ts` with `overwritePartitions()`. Measure Postgres load after one week.

3. **If load doesn't improve: consider the hybrid view.** 1-hour Iceberg + 1-hour federated tail is a one-day change and costs almost nothing operationally.

4. **Document your freshness SLO.** That single number drives whether federation, batch, or CDC is the right answer.
