# Answer to Q1: Multi-Tenant Data Isolation — One Table vs Separate Tables per Customer

## Short answer

Keep one shared table at 80 tenants. Table-per-tenant is a mistake at your scale. The operational burden of 80 separate schemas — 80x migrations, schema drift, UNION ALL cross-tenant queries — is far worse than the isolation risk. The real safety comes from enforcing isolation **inside Trino with views and OPA**, not from spreading data across 80 tables.

## Why table-per-tenant breaks at 80 customers

Every time you add a column — a new event property, a user attribute, a billing field — you run that migration against 80 separate tables. One missed migration creates schema drift between tenants, which causes subtle bugs that are hard to detect and harder to fix. You can't run a cross-tenant report without UNION ALL across 80 tables. Onboarding a new customer requires creating a new table, wiring up new grants, updating all your tooling.

At 80 tenants, table-per-tenant costs hours every week. It seemed reasonable at 5 customers.

The Iceberg + Trino stack is designed to keep data isolated *logically* — via partitioning and query filters — without maintaining 80 separate physical tables. That's the whole point.

## The three isolation models

### Model 1: Separate table per tenant (NOT recommended at 80 tenants)

Each customer gets `acme.events`, `beta.events`, etc. Strongest isolation — a query against `acme.events` physically cannot touch Beta's data.

Operational nightmare: 80 schemas = 80x maintenance burden. Every schema migration, every column addition, every drift bug hits 80 times. 

Use when: you have fewer than ~10 tenants AND a compliance regime (HIPAA, financial) that literally mandates physical data separation.

### Model 2: Shared table, app-enforced WHERE (risky)

One `analytics.events` table. Application code appends `WHERE tenant_id = ?` to every query.

Pro: Simple. Con: One forgotten WHERE clause leaks every customer's data. A junior engineer writes `SELECT COUNT(*) FROM events` to debug, forgets the filter, and suddenly has aggregate counts across all tenants.

Acceptable only for internal-only dashboards where a single ORM layer always injects the filter.

### Model 3: Shared table, Trino-enforced (recommended)

Same physical layout as Model 2 — one table partitioned by `tenant_id` — but isolation is enforced **inside Trino**, not by the app. This is the standard for B2B SaaS on the Trino + Iceberg stack.

## The recommended architecture for your 80-customer stack

### Step 1: One events table, partitioned by day + tenant_id

```sql
CREATE TABLE iceberg.analytics.events (
    event_id    BIGINT,
    occurred_at TIMESTAMP(6),
    tenant_id   VARCHAR,
    user_id     BIGINT,
    event_type  VARCHAR,
    payload     VARCHAR
)
WITH (
    partitioning = ARRAY['day(occurred_at)', 'tenant_id']
);
```

Iceberg's partition pruning automatically skips files from other tenants when you filter by `tenant_id`. A query for `tenant_id = 'acme'` only reads Acme's partition files — true physical isolation at scan time. No cross-tenant data is read.

### Step 2: Create Trino views with hard-coded tenant filters

One view per tenant, each pointing at the shared base table:

```sql
CREATE SCHEMA IF NOT EXISTS tenant_acme;

CREATE VIEW tenant_acme.events AS
SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

The view bakes in the filter. App code queries `tenant_acme.events` — no WHERE clause needed, no WHERE clause to forget.

### Step 3: Enforce access control via OPA

Your production stack uses Open Policy Agent (OPA) for Trino authorization. Configure OPA to:

- **DENY** all principals direct access to `iceberg.analytics.events` (the base table)
- **ALLOW** each tenant principal to SELECT from `tenant_<name>.events` (their scoped view only)

Even if app code contains a bug that omits the tenant filter, OPA at the Trino level rejects the query against the base table. Defense in depth: the database rejects it regardless of what the app sends.

This also means you can give customers direct SQL access or BI tool access (Metabase, Superset, Looker) without risking cross-tenant data leakage — they authenticate to Trino and OPA limits them to their view.

## What about the `tenant_id` partition cardinality?

At 80 tenants, `tenant_id` is safe to use as a partition column. The cardinality concern (millions of small partitions) arises when you partition on high-cardinality columns like `user_id` or `event_id`. 80 distinct values across a large table is a healthy partition count — Iceberg handles this efficiently.

For comparison, partitioning by `user_id` on a table with 500K users would create 500K partitions — a metadata overhead nightmare. `tenant_id` at 80 values is designed for exactly this.

### Monitoring tenant size distribution

Run this metadata query weekly to check for skew:

```sql
SELECT
    partition.tenant_id,
    ROUND(total_size / (1024.0 * 1024.0 * 1024.0), 2) AS total_gb,
    record_count
FROM iceberg.analytics."events$partitions"
ORDER BY total_size DESC
LIMIT 20;
```

If one tenant exceeds 30–50% of the table's total size (a "whale tenant"), promote them to a dedicated table with only `day(occurred_at)` partitioning. Then update their view to point at the dedicated table and delete their rows from the shared table. The other 79 tenants stay in the shared table; the whale gets their own optimized layout.

## What about data isolation in Postgres vs Iceberg?

Your current Postgres row-level security (RLS) setup enforces isolation in a different way: Postgres evaluates the security policy on every row read, at the database engine level. It works, but it doesn't scale well because Postgres still reads those rows from disk before applying the filter.

On the Iceberg + Trino side, isolation is enforced at the *file* level (the partition pruner skips entire files before reading data) and at the *query planning* level (via views and OPA). For a move to a data warehouse setup, the Trino view + OPA approach gives you comparable security guarantees to Postgres RLS — without the per-row overhead.

## Summary

| Approach | At 80 tenants | Security | Ops burden |
|---|---|---|---|
| Table per tenant | NOT recommended | Strongest (physical) | 80x migrations, drift |
| Shared table, app WHERE | Acceptable for internal only | Weakest (app bugs leak) | Low |
| Shared table, Trino views + OPA | **Recommended** | Strong (engine-enforced) | Low — one schema |

At 80 customers, keep one table. Use Iceberg partitioning for performance isolation. Use Trino views to bake in the tenant filter. Use OPA to deny access to the base table. That combination gives you the isolation guarantees of table-per-tenant without 80x the operational cost.
