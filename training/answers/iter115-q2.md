# Iter115 Q2 — Answer

**Question**: We have around 140 tenants in our Iceberg `events` table, all partitioned by `tenant_id` and `day(event_ts)`. Adding new tenants is fine, but I'm hearing from the team that as we cross 100+ tenants the partition metadata is getting large enough to slow down query planning — even queries that filter to a single tenant are taking a few extra seconds just before results start coming back. Is this a known problem with this kind of partition layout, and is there a way to restructure the partitions or evolve the partition spec without rewriting all the existing data? We're on Trino 467 with Iceberg 1.5.2 on-premises if that matters.

---

## Answer

Yes, this is a known and well-documented problem with the identity-partitioned `(day(event_ts), tenant_id)` layout above 100 tenants. At 140 tenants × 90-day rolling window, you're at roughly 12,600 partitions — past the comfort zone where manifest-list traversal dominates query planning. The good news: Iceberg partition evolution is metadata-only, so you can switch to bucket partitioning for new data immediately without touching existing files.

### What's Happening at Query Planning Time

When Trino plans `SELECT ... WHERE tenant_id = 'acme' AND event_ts >= ...`, it walks the **Iceberg manifest list** to find which manifests could contain matching files. Even though partition pruning eventually narrows to just one tenant's files, the planner must traverse all 12,600 partition entries in the manifest list to find them. This traversal cost grows linearly with partition count — at your scale it adds 200–500ms to every query's planning phase, before any data is read (hence the few-second delay before results start appearing).

### Fix: Switch to Bucket Partitioning

For 100–1000 tenants, the recommended layout is `(day(event_ts), bucket(tenant_id, 32))`:

- `bucket(tenant_id, 32)` hashes each tenant into 1 of 32 buckets (deterministically)
- Partition count: 90 days × 32 buckets = **2,880 entries** (vs. 12,600 today)
- A query with `WHERE tenant_id = 'acme'` still prunes well: Trino evaluates `bucket('acme', 32)` once, identifies the right bucket, and reads only that bucket's files — roughly 1/32 of the table
- Manifest-list traversal drops by 4× → planning latency returns to baseline

### Two-Phase Migration (Minimizes Downtime)

**Phase 1: New data immediately (metadata-only, zero downtime)**

```sql
-- Trino 467 — affects ONLY new writes; existing files keep their old partition spec
ALTER TABLE iceberg.analytics.events
SET PROPERTIES partitioning = ARRAY['day(event_ts)', 'bucket(tenant_id, 32)'];
```

Iceberg records a new partition spec version in the table metadata. New writes immediately use the bucket spec. Old files keep their identity-partition layout unchanged. Trino handles the mixed layout transparently at query time (tracks spec version per file). Your ingestion pipeline sees instant planning-latency improvement on new data.

**Phase 2: Rewrite historical data (off-peak hours, ~1–3 hours)**

Once new data is flowing under the new spec, rewrite historical data in the background:

```sql
-- Step 1: CTAS — read old table, write under new partition spec
-- Partition evolution is metadata-only; rewrite_data_files does NOT re-layout
-- under a new spec. Use CTAS to actually re-layout historical data.
CREATE TABLE iceberg.analytics.events_v2
WITH (partitioning = ARRAY['day(event_ts)', 'bucket(tenant_id, 32)'])
AS SELECT * FROM iceberg.analytics.events;

-- Step 2: Verify row counts match before cutover
SELECT
  (SELECT COUNT(*) FROM iceberg.analytics.events)    AS old_count,
  (SELECT COUNT(*) FROM iceberg.analytics.events_v2) AS new_count;
-- If counts differ, ABORT and investigate.

-- Step 3: Redirect views to the new table (atomic, instant)
CREATE OR REPLACE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM iceberg.analytics.events_v2
  WHERE tenant_id = 'acme';
-- Repeat for each tenant view

-- Step 4: Drop old table after verification (frees MinIO storage)
DROP TABLE iceberg.analytics.events;

-- Step 5: Rename to reclaim the original table name
ALTER TABLE iceberg.analytics.events_v2 RENAME TO iceberg.analytics.events;
```

### The Key Tradeoff: Per-Tenant Metadata Queries

Switching to bucket partitioning has one important side effect:

| | Identity `tenant_id` | `bucket(tenant_id, 32)` |
|---|---|---|
| Per-tenant query pruning | Exact — one tenant = one partition | Good — one tenant = ~1/32 of table |
| Planning latency at 140 tenants | 200–500ms overhead | Baseline (~tens of ms) |
| `$partitions` metadata queries | `partition.tenant_id` = readable tenant name | `partition.tenant_id_bucket` = INT 0..31 only |

**If per-tenant storage reporting matters** (for billing, capacity, or GDPR auditing), you have two options:

1. Keep identity partitioning and accept the planning latency — mitigate by migrating the heaviest 3–5 tenants to dedicated tables and using resource groups to cap their CPU.
2. Switch to buckets AND maintain a pre-aggregated per-tenant storage metrics table (nightly Spark job).

To confirm the bucket column name in your table metadata before writing `$partitions` queries:

```sql
DESCRIBE iceberg.analytics."events$partitions";
-- Look for the partition column: 'day' (INT, days since epoch) and 'tenant_id_bucket' (INT 0..31)
-- NOT 'tenant_id' (string) — that disappears in a bucket-partitioned spec
```

### Alternative: Selective Tenant Migration (Hybrid)

If a small number of very large tenants are driving the partition count growth, migrate only the top 3–5 heaviest tenants to dedicated tables and keep the rest in the shared table. This reduces shared-table partition count and keeps per-tenant metadata readable for the remaining tenants.

Identify migration candidates:

```sql
-- Find tenants by storage volume (metadata-only, no table scan)
SELECT partition.tenant_id, SUM(record_count) AS total_rows, SUM(file_count) AS files
FROM iceberg.analytics."events$partitions"
GROUP BY partition.tenant_id
ORDER BY total_rows DESC
LIMIT 10;
```

Then use the 5-step safe cutover sequence (INSERT → verify → swap view → DELETE) for each migration candidate. This hybrid approach works well when a handful of enterprise tenants have orders-of-magnitude more data than the rest.

### Verify Improvement After Migration

After the partition spec change, confirm planning latency has improved:

```sql
-- Run a representative tenant query and check planning time in Trino UI or system.runtime.queries
SELECT COUNT(*) FROM iceberg.analytics.events
WHERE tenant_id = 'acme' AND event_ts >= TIMESTAMP '2026-05-01';
-- Planning time should drop from 200-500ms to under 50ms
```

**Recommendation for your 140-tenant case:** Switch to `bucket(tenant_id, 32)` via Phase 1 (immediate spec change for new data) now. Schedule Phase 2 (CTAS rewrite of historical data) during the next maintenance window. If per-tenant billing metadata is required, add a nightly rollup job rather than relying on `$partitions` directly.
