# Iter114 Q2 — Answer

**Question**: We run an internal weekly report that shows product usage across all of our tenants — things like active users per tenant, feature adoption rates, and event counts by category. Right now it's a single Trino query against our shared `events` Iceberg table with no `WHERE tenant_id = ?` filter, so it scans everything. The query works, but it returns data for every tenant including our own internal test accounts, staging environments, and churned customers we want to exclude from the numbers. More importantly, some of our enterprise customers have contractual clauses saying their data can't be commingled with other tenants' data in any query, even for internal analytics — so scanning everything in one query might be a compliance problem. Is there a way to run cross-tenant aggregations for internal reporting while still keeping each tenant's data logically or physically isolated so we don't violate those contracts? Or does "can't commingle data" mean we literally have to run 80 separate queries and stitch the results together?

---

## Answer

You don't need 80 separate queries. The answer is a **pre-aggregated rollup table** for internal reporting, combined with per-tenant views for customer-facing queries. "Can't commingle data" almost always means logical isolation (data is grouped and aggregated per tenant before any summary is produced) rather than physical isolation (a literal ban on ever touching two tenants' files in one Spark job). Here's how to satisfy both requirements.

### What "Can't Commingle" Usually Means

Enterprise contracts typically prohibit one thing: **a query result where tenant A's raw records are joined with or mixed into tenant B's raw records mid-computation**. A cross-tenant aggregation that computes `COUNT(*) GROUP BY tenant_id` does NOT commingle data — each tenant's rows stay in their own partition and are counted separately. The result set contains one row per tenant; no tenant's data appears in another tenant's aggregate.

What IS a problem under these contracts:
- `SELECT a.user_id, b.event_type FROM acme_events a JOIN globex_events b ON ...` (cross-tenant join mixing raw records)
- A single per-row query that returns rows from two different tenants in the same result set without grouping
- An admin endpoint that exposes one tenant's raw data to another tenant's service account

Your current weekly report — `SELECT ..., tenant_id, COUNT(*) FROM events GROUP BY tenant_id` — is structurally fine. The problem is just that it scans *everything* including test/staging accounts you don't want.

### Fix 1: Exclude Internal Accounts at the Source

Before anything else, add an `account_type` or `is_internal` column to your tenant registry and filter it:

```sql
-- Trino: production tenants only, excluding test/staging/churned
SELECT
  t.tenant_id,
  t.plan_tier,
  COUNT(DISTINCT e.user_id) AS active_users,
  COUNT(*)                  AS total_events
FROM iceberg.analytics.events e
JOIN iceberg.catalog.tenants t ON e.tenant_id = t.tenant_id
WHERE t.account_type = 'production'
  AND t.status       = 'active'
  AND e.event_ts    >= TIMESTAMP '2026-05-18'
GROUP BY t.tenant_id, t.plan_tier
ORDER BY total_events DESC;
```

This is the simplest fix and handles the "internal test accounts and churned customers" problem immediately, with no data model changes.

### Fix 2: Pre-Aggregated Rollup Table (For Compliance + Performance)

For the "can't commingle" contractual requirement, the standard production pattern is a pre-aggregated rollup table. The nightly Spark job computes aggregates per-tenant from the raw events, then internal teams query only the rollup — they never touch raw events at all.

**Create the rollup table:**

```sql
CREATE TABLE iceberg.analytics.daily_event_rollup (
  event_date    DATE,
  tenant_id     VARCHAR,
  event_type    VARCHAR,
  event_count   BIGINT,
  unique_users  BIGINT,
  rollup_ts     TIMESTAMP
)
WITH (
  partitioning = ARRAY['event_date']
);
```

**Nightly Spark job to populate it (idempotent MERGE):**

```python
batch_date = "2026-05-24"

spark.sql(f"""
    CREATE OR REPLACE TEMPORARY VIEW rollup_delta AS
    SELECT
        DATE '{batch_date}'         AS event_date,
        e.tenant_id,
        e.event_type,
        COUNT(*)                    AS event_count,
        COUNT(DISTINCT e.user_id)   AS unique_users,
        CURRENT_TIMESTAMP           AS rollup_ts
    FROM iceberg.analytics.events e
    JOIN iceberg.catalog.tenants t ON e.tenant_id = t.tenant_id
    WHERE DATE(e.event_ts) = DATE '{batch_date}'
      AND t.account_type = 'production'
      AND t.status = 'active'
    GROUP BY e.tenant_id, e.event_type
""")

spark.sql("""
    MERGE INTO iceberg.analytics.daily_event_rollup t
    USING rollup_delta s
    ON  t.event_date = s.event_date
    AND t.tenant_id  = s.tenant_id
    AND t.event_type = s.event_type
    WHEN MATCHED THEN UPDATE SET
        event_count  = s.event_count,
        unique_users = s.unique_users,
        rollup_ts    = s.rollup_ts
    WHEN NOT MATCHED THEN INSERT *
""")
```

**Internal team queries the rollup — never raw events:**

```sql
-- Weekly report: sub-second, no commingling concern
SELECT
  event_date,
  tenant_id,
  SUM(event_count)  AS total_events,
  SUM(unique_users) AS dau
FROM iceberg.analytics.daily_event_rollup
WHERE event_date >= DATE '2026-05-18'
GROUP BY event_date, tenant_id
ORDER BY total_events DESC;
```

**Why this satisfies the contract:**
- The Spark job aggregates each tenant independently via `GROUP BY tenant_id`. No tenant's raw records touch another tenant's records.
- The rollup table contains only summaries — no individual user events, no cross-tenant joins.
- Internal teams access only the rollup, not the raw events table. Customer service accounts cannot see the rollup (grant access only to the internal analytics principal).

### Fix 3: Per-Tenant Views as the Customer-Facing Interface

Customer-facing dashboards should query filtered views, not the base table. This ensures no application bug can accidentally return another tenant's data:

```sql
-- Customer-facing view: returns only this tenant's events
CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM iceberg.analytics.events
  WHERE tenant_id = 'acme';
```

Partition pruning on `tenant_id` ensures only Acme's physical files are read — the isolation is both logical (WHERE clause) and physical (file-level).

### Access Control Separation

Route your principals to the right resources:

| Principal | Can access | Cannot access |
|---|---|---|
| `acme-service-account` | `tenant_acme.events` view | `analytics.events` base table, rollup table |
| `internal-data-team` | `analytics.daily_event_rollup` | `analytics.events` base table |
| `admin-batch-job` | `analytics.events` base table | — |

The exact access-control rules live in your OPA policy document (see `prod_info.md`). The conceptual shape: customer principals are routed through views only; internal analytics principals see only the pre-aggregated rollup; raw table access is restricted to batch job service accounts with full audit logging.

### What You Don't Need

- **80 separate queries** — the rollup table handles all tenants in one MERGE pass. Internal queries read a tiny summary table.
- **Dedicated table per tenant** — the shared `analytics.events` table with partitioning by `(day(event_ts), tenant_id)` handles isolation fine. You only migrate enterprise tenants to dedicated tables when their volume causes compaction noise for other tenants.
- **Custom query rewrite proxy** — views + OPA enforce isolation at the Trino layer; no application-layer middleware needed.
