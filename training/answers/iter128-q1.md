# Iter128 Q1 — Answer

**Question**: We're a multi-tenant SaaS — every customer's data lives in the same Iceberg tables, separated by a `tenant_id` column. Right now our Trino queries just have a `WHERE tenant_id = ?` that we inject in the app layer. But I'm worried: what happens if a bug in our query-building code drops that filter? One customer could accidentally see another's rows. Is there a way to enforce the isolation at the database or query engine level, so even if our app code screws up, the wrong data can't come back? Like, does Trino have something like row-level security, or do we need a completely different table layout per customer?

---

## Database-Level Row Isolation in Trino + Iceberg

Your instinct is correct — relying solely on application-layer `WHERE tenant_id = ?` is dangerous. **"Never rely on the application appending `WHERE tenant_id = ?` as your only defense. One forgotten WHERE clause leaks every customer."**

Trino does have mechanisms to enforce isolation at the query engine level. Here are your options.

---

## Three Isolation Models

### Model 1: Separate Iceberg Namespace Per Tenant (Strongest, Highest Ops Cost)

Each customer gets their own schema: `acme.*`, `beta.*`, etc.

**Pros:** Maximum isolation — a query against `acme.events` physically cannot return Beta's rows. Easy per-tenant offboarding (drop the schema). Easy per-tenant credentials.

**Cons:** Operational burden explodes. 80 tenants = 80 schemas to migrate on every schema change. Hard to run cross-tenant internal analytics. Hive Metastore degrades with thousands of tables.

**When to use:** Heavily regulated industries (HIPAA, financial services); small tenant count (< 50); contractual physical separation requirements.

### Model 2: Shared Table, App-Layer Filter Only (Fast, Risky)

One table, all customers, partitioned by `tenant_id`. The app injects `WHERE tenant_id = ?`.

```sql
CREATE TABLE iceberg.analytics.events (
  event_id    BIGINT,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  event_ts    TIMESTAMP
)
WITH (partitioning = ARRAY['tenant_id', 'day(event_ts)']);
```

**Pros:** One schema. One DDL command to add a column. Fast per-tenant queries (partition pruning reads only that tenant's files). Easy cross-tenant internal analytics.

**Cons:** Isolation depends entirely on app code. A developer writing `SELECT COUNT(*) FROM events` (forgetting the WHERE) leaks every customer's data.

**When to use:** Only if you control all SQL generation and have a single, well-tested ORM that always injects `tenant_id`. **Not suitable for a SaaS with any risk of query-building bugs.**

### Model 3: Shared Table + Query-Engine Enforcement (RECOMMENDED)

Same physical layout as Model 2, but isolation is enforced inside Trino via views and OPA (your production authorization layer), not the app.

```sql
-- Base table (ops-admin access only)
CREATE TABLE iceberg.analytics.events (
  event_id    BIGINT,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  event_ts    TIMESTAMP
)
WITH (partitioning = ARRAY['tenant_id', 'day(event_ts)']);

-- Per-tenant schema and view (created once at customer onboarding)
CREATE SCHEMA IF NOT EXISTS tenant_acme;

CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts
  FROM iceberg.analytics.events
  WHERE tenant_id = 'acme';
-- Note: omit tenant_id from SELECT list — tenant never needs to see it
```

**Three enforcement layers:**

1. **Trino view with baked-in filter.** The view's `WHERE tenant_id = 'acme'` runs with the view owner's grants. The tenant principal reads through the filtered view and cannot modify the filter.

2. **OPA access control.** OPA denies the tenant principal any direct SELECT on `analytics.events` — only the view is permitted. A bug in app code that drops the WHERE clause still hits OPA rejection.

3. **Role-based grants.** The tenant role has SELECT only on the view, not the base table.

**Verification test (required after setup):**
```sql
-- Connect as tenant Acme and verify:

-- Should succeed:
SELECT COUNT(*) FROM tenant_acme.events;

-- Should fail with Access Denied (OPA blocks base table):
SELECT COUNT(*) FROM iceberg.analytics.events;
```

**Pros:** Defense in depth. Single schema, single operational burden. Scales to 50–500 tenants.

**Cons:** Per-tenant view provisioning on each schema migration. Above ~500 tenants, switch to OPA row-filter mode (see below).

**This is the recommended model for most B2B SaaS.**

---

## Advanced: OPA Row-Filter Mode (Scales to Thousands of Tenants)

Instead of per-tenant views, OPA automatically injects the tenant filter based on the calling principal's JWT claims.

```
-- User runs:
SELECT * FROM iceberg.analytics.events;

-- OPA reads the JWT 'tenant_id' claim, injects filter, Trino actually executes:
SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

**Pros:** Onboarding tenant #501 is a row in your principal-to-tenant mapping, not a DDL change. Single OPA policy enforces all tenants.

**Cons:** A bug in the OPA principal-to-tenant mapping breaks isolation for all tenants simultaneously (vs. a per-tenant view bug affecting only one). Requires OPA Rego expertise.

**Use this:** Above ~500 tenants or when per-tenant view provisioning is a maintenance bottleneck.

---

## Critical Leak Paths to Block

**1. System catalog leak (`system.runtime.queries`):**

Tenant Acme can run `SELECT * FROM system.runtime.queries` and see the complete SQL text of every query from every tenant — including customer IDs, emails, and sensitive logic.

**Fix:** OPA must deny the `system` catalog to all tenant principals. Test:
```sql
-- Must fail with Access Denied for any tenant principal:
SELECT COUNT(*) FROM system.runtime.queries;
```

**2. Iceberg metadata table leak (`$partitions`, `$files`, `$snapshots`):**

Even through a filtered view, a tenant may be able to query `iceberg.analytics."events$partitions"` and see: all tenant IDs in the system, record counts per tenant (volume intelligence), and file counts per tenant.

**Fix:** OPA must deny all `$`-suffix metadata tables to tenant principals. Test:
```sql
-- All must fail with Access Denied for tenant principals:
SELECT * FROM iceberg.analytics."events$partitions" LIMIT 1;
SELECT * FROM iceberg.analytics."events$files" LIMIT 1;
SELECT * FROM iceberg.analytics."events$snapshots" LIMIT 1;
```

---

## Implementation Checklist for Model 3

1. **Partition the table** by `tenant_id` + `day(event_ts)` so per-tenant queries don't scan the entire table.
2. **Create per-tenant views** with `WHERE tenant_id = '<tenant>'` baked in.
3. **OPA policy:**
   - Allow tenant principals SELECT on their view only.
   - Deny tenant principals Select on the base table.
   - Deny tenant principals access to the `system` catalog.
   - Deny tenant principals access to any `$`-suffix metadata tables.
4. **Separate service accounts:** `spark-ingest` (INSERT/DELETE only), `trino-query` (SELECT on views only).
5. **CI tests** confirming: view queries succeed; base-table queries fail; system catalog and metadata tables deny access.

---

## Why This Matters

A query-building bug that drops `WHERE tenant_id = ?` in Model 2 returns every customer's data. With Model 3 + OPA, the same bug fails safely at the authorization layer — Trino rejects the base-table query before reading a single file. Your defense is the database itself, not a lucky WHERE clause.
