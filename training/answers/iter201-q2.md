# Iter 201 Q2 — Federate vs Ingest: Decision Framework

## Answer

You're asking exactly the right question — the federation vs. ingestion decision is one that makes or breaks a production analytics system.

---

## Decision Criteria: The Core Trade-offs

### 1. Freshness SLO — the primary decision lever

- **Sub-minute freshness required**: federate live from Postgres, period. Ingestion can't compete.
- **5-minute to 1-hour freshness** (typical for SaaS dashboards): ingest with hourly batch Spark jobs or micro-batch every 5–10 minutes. Federation is a fallback only if ingestion falls behind.
- **Hour-level or daily freshness** (executive reporting, cohort analysis): always ingest. Federation adds complexity with zero freshness benefit.

### 2. How often the source data changes

- **Append-only tables** (events): ingestion wins. A simple incremental Spark job `WHERE created_at > last_ts` runs in minutes, reads Postgres once per batch, and lands the data in columnar Iceberg where it compresses 5–10x better. The `events` table (500M rows, append-only) is the textbook case for ingestion.
  
- **Frequently updated tables** (customers): ingest with MERGE INTO on an `updated_at` watermark (idempotent, handles late arrivals). Unless customer metadata changes are mission-critical within 5 minutes, ingest hourly and accept 1-hour staleness.

### 3. Query complexity and scale

- **Joining a small dimension against huge fact tables** (2M customers × 500M events): if you keep customers federated, Trino pulls the full 2M customers over JDBC (20–40 seconds single-threaded for a non-selective scan) then shuffles them against 500M events. If you ingest customers to Iceberg, Trino can broadcast them (small side) with full dynamic filtering and CBO stats — orders of magnitude faster.

- **Aggregations over historical data**: Iceberg always wins. Columnar storage with partition pruning and Parquet min/max stats beats row-store Postgres on every analytical query.

### 4. Load on Postgres — the hidden cost

Every federation query reads from your replica. 10 concurrent queries = 10 JDBC connections reading millions of rows concurrently. 30 concurrent queries = dashboards slow down, BI tools time out, replica CPU spikes. Ingest once to Iceberg, then serve all queries from columnar storage — the replica never sees the analytical load.

---

## Your Two Tables: Specific Guidance

### Customers table (2M rows, frequently updated) → **INGEST (not federate)**

**Why:**
1. 2M rows is large enough that full JDBC scans are slow (20–40 seconds per non-selective query)
2. Updates are frequent — need MERGE INTO or full-table refresh at regular cadence
3. Cross-catalog joins (customers × events) are your main use case — ingested customers enable broadcast join with dynamic filtering; federated customers require a full table scan + shuffle

**Ingestion pattern:**
- Hourly Spark job: `WHERE updated_at > '{last_ts}'` with a 15–30 minute lag buffer
- Write strategy: **MERGE INTO** on `customer_id` (handles updates in place)
- Schedule: hourly or every 4 hours depending on freshness SLO

**What breaks if you federate instead:** Dashboard queries joining customers to event cohorts stall. A 2M-customer scan via JDBC takes 30–40 seconds single-threaded. Multiply by 5 concurrent BI dashboard refreshes and the Postgres replica CPU spikes. Replication lag grows. Analysts file "why is Trino so slow?" tickets.

---

### Events table (500M rows, append-only) → **INGEST (not federate)**

**Why:**
1. Append-only is the killer pattern for ingestion — a simple `WHERE created_at > last_ts` watermark is bulletproof
2. 500M rows is far too big for live JDBC scans (a non-filtered scan = 40+ minutes at 100K–200K rows/sec)
3. Iceberg is purpose-built for this: columnar storage, partition pruning by day, Parquet min/max stats, aggregations orders of magnitude faster than Postgres row-store

**Ingestion pattern:**
- Hourly Spark job: `WHERE created_at > '{last_ts}'`
- Write strategy: `.append()` or `.overwritePartitions()` by day (both safe on append-only)
- Late arrivals (mobile app offline, syncs backdated events): use MERGE INTO with a 6–24 hour re-read window to avoid silent data loss

**What breaks if you federate instead:** First to break: concurrent load. Five analysts run date-filtered queries simultaneously — each is a 20-second JDBC scan. The replica saturates. Second: any unfiltered query scans 500M rows over JDBC and runs for 40+ minutes.

---

## What Breaks First in Production: The Failure Modes

### If you federate customers:
1. **First**: dashboard reloads during peak hours slow to 45 seconds (vs 8 seconds from Iceberg). Multiple concurrent refreshes cause timeouts.
2. **Then**: Postgres replica replication lag drifts toward 1–5 minutes.
3. **Then**: connection saturation. Without PgBouncer + resource groups, you hit 100+ connections. Postgres rejects the 101st. Trino queries fail with `too many connections`.

### If you federate events:
1. **First**: the first unfiltered or unpushable query scans all 500M rows over JDBC — 20+ minutes until it times out or someone kills it.
2. **Then**: concurrent load. Five analysts' time-filtered queries stack up, each 20-second JDBC scans. Replica saturates.
3. **Then**: network throughput becomes the bottleneck — 500M rows streaming across the network repeatedly instead of serving from a 50–100 GB compressed Iceberg table.

---

## The Hybrid Pattern (If Freshness < 1 Hour)

For tight freshness SLOs without full streaming infrastructure: ingest hourly to Iceberg, federate Postgres for the last hour only.

```sql
CREATE OR REPLACE VIEW analytics.customers_live AS
SELECT id, tenant_id, name, plan_type, created_at
FROM iceberg.analytics.customers
WHERE created_at < (current_timestamp - INTERVAL '1 HOUR')
UNION ALL
SELECT id, tenant_id, name, plan_type, created_at
FROM app_pg.public.customers
WHERE created_at >= (current_timestamp - INTERVAL '1 HOUR');
```

Old data (> 1 hour) is fast columnar Iceberg. Live tail (last hour) is federated but tiny — maybe 50K new/updated rows instead of 2M.

---

## Decision Matrix

| Table | Size | Change pattern | Freshness SLO | Decision | Why |
|---|---|---|---|---|---|
| customers | 2M | Frequent UPDATEs | 1–4 hours | **Ingest hourly** | MERGE INTO handles updates; broadcast join on Iceberg is fast |
| events | 500M | Append-only | 1–4 hours | **Ingest hourly** | Columnar Iceberg crushes row-store Postgres; no UPDATE complexity |
| (small dim) user_preferences | 100K | Mostly reads | 30 seconds | **Federate** | Small table, selective reads, natural JDBC fit |
| (large fact) audit_log | 1B | Append-only | 24 hours | **Ingest nightly** | Too big for live JDBC; batch ingestion simple and fast |

**Bottom line:** Ingest both tables. Customers as hourly MERGE INTO (handles updates), events as hourly append. Your replica stays quiet, your dashboards are fast. Federation is best for small, highly-selective, freshness-critical tables — not for dimension or fact tables that analytics queries will scan broadly.
