# Multi-Tenant Analytics Isolation

How to keep customer A from ever seeing customer B's numbers when you move analytics out of your OLTP database (e.g., Postgres) and into a separate analytics stack (Trino + Iceberg + MinIO).

This guide assumes the production stack from `prod_info.md`: **Trino 467** as the query engine, **Apache Iceberg 1.5.2** as the table format, **Hive Metastore** as the catalog, **MinIO** as object storage, and **Spark** for ingestion. All on-prem in Kubernetes.

---

## Quick answer (TL;DR)

If you're a B2B SaaS moving analytics off Postgres and you need to guarantee one customer never sees another's data:

1. **Pick one of three isolation models**: (a) separate Iceberg namespace per tenant, (b) one shared table partitioned by `tenant_id`, or (c) shared tables with query-engine enforcement (Trino views + access control).
2. **For < 50 tenants and strict regulatory needs**, use separate namespaces (one schema per customer).
3. **For most B2B SaaS with 50–500 tenants**, use shared tables partitioned by `tenant_id` plus **Trino views** that hard-code `WHERE tenant_id = <caller's tenant>`. Customers only get access to the view, never the base table.
4. **Never rely on the application appending `WHERE tenant_id = ?`** as your only defense. One forgotten WHERE clause leaks every customer.
5. **Enforce at the query engine** using Trino's **system access control** (a Trino plugin that checks, before every query runs, whether the calling user is allowed to read each table/column — implemented via file-based rules or Open Policy Agent) so the database itself rejects cross-tenant queries.

---

## The three isolation models

There are three standard ways to lay out multi-tenant analytics data. Pick one based on tenant count, isolation strictness, and ops budget.

### Model 1: Separate database / schema per tenant

Each customer gets their own Iceberg **namespace** (the lakehouse equivalent of a Postgres schema — a logical folder of tables inside the Hive Metastore catalog). So customer Acme gets `acme.events`, `acme.users`, and customer Beta gets `beta.events`, `beta.users`.

- **Pros**:
  - Strongest isolation. A query against `acme.events` physically cannot return Beta's rows.
  - Easy to delete a customer (drop the namespace, delete the MinIO prefix).
  - Easy to give a customer their own credentials scoped to their namespace.
- **Cons**:
  - Operational explosion. 80 tenants = 80 schemas to migrate every time you add a column. Schema drift becomes painful fast.
  - Hard to run cross-tenant internal analytics (e.g., "total MRR across all customers") — you need UNION ALL across 80 schemas.
  - Hive Metastore performance can degrade with thousands of tables.
- **When to use this**:
  - Regulated industries (HIPAA, financial) where the contract demands physical separation.
  - Very few large tenants (< 50) with relatively stable schemas.
  - A customer asks to take their entire dataset with them on offboarding.

### Model 2: Shared tables, partitioned by `tenant_id`

One table holds all customers' data. The table is **partitioned** by `tenant_id` — meaning Iceberg physically splits the underlying Parquet files by tenant, so a query for one customer only reads that customer's files. (Iceberg "partition" = a directory-like grouping of files used for query pruning.)

The application layer is responsible for adding `WHERE tenant_id = ?` to every query.

- **Pros**:
  - One schema to maintain. Adding a column is one DDL command, not 80.
  - Easy cross-tenant internal analytics.
  - Iceberg's partition pruning makes per-tenant queries fast (it skips files for other tenants entirely).
- **Cons**:
  - **Isolation depends entirely on application code being correct.** A junior dev writing `SELECT COUNT(*) FROM events` (forgetting the WHERE clause) leaks every customer's row counts.
  - SQL injection or a bug in your tenant-resolution code can leak data.
  - Bad fit if one tenant has 1000x more data than the others (see "Noisy neighbor" below).
- **When to use this**:
  - Internal-only dashboards where only your engineers (not customers) write SQL.
  - You have a single, well-tested ORM/data access layer that always injects `tenant_id`.
  - You don't expose Trino directly to customers.

### Model 3: Shared tables + query-engine row-level enforcement

Same physical layout as Model 2 — one big table partitioned by `tenant_id` — but isolation is enforced **inside Trino**, not by the app. The app cannot bypass it even if it forgets the WHERE clause.

This is done with one or more of:
- **Trino views** that hard-code the tenant filter. Customers only get SELECT permission on the view, never on the underlying table.
- **Trino system access control** (file-based rules or OPA) that rejects any query touching another tenant's rows.
- **Iceberg row filters and column masks** exposed through Trino's connector.

- **Pros**:
  - Defense in depth. Even buggy app code can't leak data.
  - Single schema, single operational burden.
  - Customer-facing query access (giving customers direct SQL or BI tool access) becomes feasible.
- **Cons**:
  - More setup. You need an access control config that maps users to tenants.
  - Trino views and access policies must be tested carefully.
- **When to use this**:
  - You expose any kind of SQL or BI tool directly to customers.
  - You have ~50–500 tenants and a normal SaaS schema (not pathologically uneven data).
  - **This is the default recommendation for most B2B SaaS** on the Trino + Iceberg stack.

### Identifying "heavy" tenants — skew detection before you migrate

Before you decide which tenants to promote out of a shared table into Model 1 (their own namespace / dedicated table), quantify the data-volume skew. The right tool is the Iceberg `$files` metadata table, which gives you per-partition file count and total size without scanning the rows themselves. As long as your shared table is partitioned by `tenant_id` (per the recommended layout), this is a 3-line query:

```sql
-- Run as an admin principal — tenants should be denied access to $files (see
-- "Iceberg metadata table leak" section above). Shows the top 20 tenants by
-- storage footprint, with file counts to spot small-file fragmentation too.
SELECT partition.tenant_id, COUNT(*) AS file_count,
       ROUND(SUM(file_size_in_bytes)/1024.0/1024.0/1024.0, 1) AS total_gb
FROM iceberg.analytics."events$files"
GROUP BY 1 ORDER BY 3 DESC LIMIT 20;
```

> **Trino SQL gotcha — `^` is NOT exponentiation in Trino.** Engineers coming from Postgres, Python, or BigQuery instinctively write `1024.0^3` to convert bytes to GB. **This is a parse-time error in Trino.** Per [trino.io/docs/current/functions/math.html](https://trino.io/docs/current/functions/math.html), Trino's documented arithmetic operators are `+ - * / %` only — there is no `^` exponentiation operator. Use one of:
>
> ```sql
> -- Option A: repeated multiplication (most common, matches the divide form above):
> total_bytes / (1024.0 * 1024.0 * 1024.0)
>
> -- Option B: the power() function:
> total_bytes / power(1024.0, 3)
> ```
>
> Both produce identical results; pick whichever reads cleaner in context. **Never** write `1024.0^3` in a Trino SQL block — the query fails at parse time with a cryptic syntax error, and copy-paste from a Postgres example is the most common way this bug enters a Trino runbook.

> **CAVEAT — `partition.tenant_id` works ONLY for identity-partitioned tables.** The query above assumes the table was created with `partitioning = ARRAY['tenant_id', ...]` (an **identity partition** on `tenant_id` — the partition transform is the identity function, so the partition column is exactly `tenant_id`). The `partition` struct on `$files` then contains a field literally named `tenant_id`, and `partition.tenant_id` dereferences it.
>
> If the table uses **`bucket(tenant_id, N)`** instead (the recommended pattern for 100+ tenants to avoid partition-count explosion — see the partition strategy section below), the partition struct contains a field named **`tenant_id_bucket`** holding an integer in `0..N-1`, NOT the original tenant_id string. `partition.tenant_id` does not exist on a bucket-partitioned table and the query fails with `Column 'tenant_id' cannot be resolved`. To recover per-tenant storage from a bucket-partitioned table you have to either:
> - Read the actual data files (defeats the metadata-only goal of `$files`), or
> - Scan the `lower_bounds` / `upper_bounds` column-statistics fields on `$files` and only get useful per-tenant results when each tenant's values fall in a narrow range — usually only the case for monotonic IDs that map cleanly to bucket boundaries, which tenant strings almost never do.
>
> **Recommendation:** if per-tenant metadata-only storage reports are a requirement (cost dashboards, capacity planning, GDPR audit), keep `tenant_id` as an **identity partition column** — either alone (`partitioning = ARRAY['tenant_id']`) or as a component of a composite partition with `day(event_ts)` as the leading pruning key (`partitioning = ARRAY['day(event_ts)', 'tenant_id']`). The composite form gives you both time-range pruning AND identity-partitioned per-tenant metadata access. Switch to `bucket(tenant_id, N)` only if your tenant count is high enough that identity partitioning produces an unmanageable number of small partitions, and accept that you lose the metadata-only per-tenant storage report when you do.

A typical result for an 80-tenant cluster looks like: 3 tenants holding > 50 GB each, 10 tenants in the 5–50 GB range, and the long tail under 1 GB. The 3 large tenants are your migration candidates — they dominate scan cost on every cross-tenant maintenance job (compaction, snapshot expiry), and isolating them into their own tables means routine maintenance on the shared table no longer pays their cost. Tenants in the long tail almost never benefit from migration; the operational overhead of an extra namespace outweighs the noisy-neighbor risk.

> **Simpler alternative for identity-partitioned tables — use `$partitions` instead of `$files + GROUP BY`.** For the common identity-partition case, Iceberg exposes a `$partitions` metadata table that **pre-aggregates** `record_count`, `file_count`, and `total_size` per partition. No `GROUP BY`, no `SUM` — just one row per partition value. This is the more idiomatic query for per-tenant storage reports:
>
> ```sql
> -- Per-tenant storage report — simpler form using $partitions.
> -- Works for identity-partitioned tables (`partitioning = ARRAY['tenant_id', ...]`).
> SELECT
>   partition.tenant_id,
>   record_count,
>   file_count,
>   ROUND(total_size / (1024.0 * 1024.0 * 1024.0), 2) AS total_gb
> FROM iceberg.analytics."events$partitions"
> ORDER BY total_size DESC
> LIMIT 20;
> ```
>
> **When to still prefer `$files`:** when you need **per-file detail** that `$partitions` aggregates away — for example, computing the compression ratio (`file_size_in_bytes / record_count`) to spot tenants with unusually large rows, identifying small-file fragmentation within a single tenant's partition (count of files under 100 MB), or listing the exact `file_path` values for ad-hoc inspection or targeted compaction. For top-line per-tenant storage and event-volume summaries, `$partitions` is strictly simpler.

Pair this with `record_count` from `$partitions` if you also want to know event-volume skew (not just byte size — high-cardinality JSON payload tenants can have small row counts but large storage):

```sql
SELECT partition.tenant_id, record_count, file_count
FROM iceberg.analytics."events$partitions"
ORDER BY record_count DESC LIMIT 20;
```

Run both queries weekly via a cron and alert when any single tenant exceeds (say) 30% of the table's total size — that's the trigger to start a migration plan, not after a customer complains about query latency.

> **Always verify the partition column name with `DESCRIBE TABLE` before writing `$partitions` queries.** On bucket-partitioned tables (`partitioning = ARRAY['bucket(tenant_id, N)']` or similar), the `$partitions` column for tenant_id is **NOT** `partition.tenant_id` — it is `partition.tenant_id_bucket` (an INT bucket id in `0..N-1`, not the tenant name string). Writing `partition.tenant_id` against a bucket-partitioned table fails with `Column 'tenant_id' cannot be resolved`. Even on identity-partitioned tables, partition column names follow the transform applied (`day(event_ts)` → `partition.day`, `month(event_ts)` → `partition.month`, etc.). Before writing any `$partitions` or `$files` metadata query, run:
>
> ```sql
> -- Lists every column in the partition struct with its actual materialized type
> -- and field name — the single source of truth for which `partition.<name>` to use.
> DESCRIBE iceberg.analytics."events$partitions";
> -- Or equivalently for the file-level metadata table:
> DESCRIBE iceberg.analytics."events$files";
> ```
>
> The output enumerates the exact `partition.<field_name>` paths available for the current partition spec. This is also what lets you discover when the partition spec has been silently changed (e.g., someone added an `ALTER TABLE ... ADD PARTITION FIELD` migration and the new field appears in the struct without updating downstream queries).

### Safe cutover sequence — migrating a tenant from a shared table to a dedicated one

Once you've identified a heavy tenant and decided to promote them out of the shared `analytics.events` table into a dedicated `analytics.acme_events` table, the migration order matters. The naive sequence (INSERT into the dedicated table, DELETE from the shared one, then swap the view) is **unsafe** — if anything fails between DELETE and the view swap, the tenant's data is missing from both tables and queries return empty results until you restore from a snapshot.

**The correct 4-step order is INSERT → verify → swap view → DELETE.** The DELETE happens last because, until it runs, the shared table still holds a complete copy of the tenant's data — meaning every intermediate failure point is recoverable by rolling back the view swap.

```sql
-- ============================================================
-- Step 1: INSERT the tenant's rows into the dedicated table.
-- The shared table is untouched; readers see no change yet.
-- ============================================================
CREATE TABLE iceberg.analytics.acme_events (
  LIKE iceberg.analytics.events INCLUDING PROPERTIES
)
WITH (partitioning = ARRAY['day(event_ts)']);  -- no need for tenant_id; only Acme lives here
-- Since only one tenant (Acme) will ever write to this table, `tenant_id` is not
-- needed in the partition spec — use `day(event_ts)` only. This gives you the
-- same time-based partition pruning the shared table had, without the overhead
-- of an always-identical partition column (every partition would carry
-- tenant_id='acme', adding metadata weight and an extra partition dimension for
-- the planner to walk for zero pruning benefit).
-- NOTE: Trino 467 does NOT support `INCLUDING ALL` (some other SQL dialects do, but
-- Trino's CREATE TABLE LIKE grammar only accepts `INCLUDING PROPERTIES` /
-- `EXCLUDING PROPERTIES`). Writing `INCLUDING ALL` is a parse-time error in Trino 467.
-- INCLUDING PROPERTIES copies the table's WITH (...) properties (format, sort order,
-- etc.) — the column list itself is always copied; the INCLUDING/EXCLUDING clause only
-- controls property copying.

INSERT INTO iceberg.analytics.acme_events
SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme';

-- ============================================================
-- Step 2: VERIFY row counts match BEFORE touching anything else.
-- This is the single most important step — cross-table writes in Iceberg are
-- NOT atomic (no two-table transaction). If the INSERT silently dropped rows
-- because of a Spark task failure, a partial commit, or a partition spec
-- mismatch, this is where you catch it.
-- ============================================================
SELECT
  (SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme') AS shared_count,
  (SELECT COUNT(*) FROM iceberg.analytics.acme_events)                      AS dedicated_count;
-- The two values MUST be equal. If they differ by even one row, ABORT and
-- investigate. Do NOT proceed to step 3.

-- For belt-and-suspenders, also check a checksum / hash on key columns:
SELECT
  (SELECT SUM(event_id) FROM iceberg.analytics.events WHERE tenant_id = 'acme') AS shared_sum,
  (SELECT SUM(event_id) FROM iceberg.analytics.acme_events)                      AS dedicated_sum;
-- Equal sums confirm the same row identities (not just the same count).

-- ============================================================
-- Step 3: SWAP the Trino view to point at the dedicated table.
-- This is a metadata-only commit — atomic, instantaneous, zero downtime.
-- Readers see either the old definition or the new one, never an empty result.
-- ============================================================
CREATE OR REPLACE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM iceberg.analytics.acme_events;
-- (Note: WHERE tenant_id = 'acme' is no longer needed — the dedicated table
-- only holds Acme's rows.)

-- ============================================================
-- Step 4: ONLY NOW delete the tenant's rows from the shared table.
-- At this point the dedicated table is verified and live; readers are already
-- going through the new view. The DELETE just reclaims space on the shared
-- table; if it fails partway, the shared table still has the rows (harmless
-- duplicates) and you can retry the DELETE later.
-- ============================================================
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';

-- Optional cleanup: follow with the 3-step physical-removal sequence
-- (rewrite_data_files + expire_snapshots + remove_orphan_files) from the GDPR
-- section if you need to reclaim MinIO storage from the shared table.

-- ============================================================
-- Step 6: POST-CUTOVER VERIFICATION — run as the tenant principal AND as admin.
-- This is the close-the-loop step that confirms the migration produced exactly
-- the expected end state. Both checks MUST pass before the migration ticket is
-- closed. If either check fails, the migration is incomplete and you have a
-- correctness incident — either the tenant is now seeing wrong data, or the
-- shared table still holds tenant rows that should have been moved.
-- ============================================================

-- Check 1: as the tenant principal (acme-service-account), the tenant view
-- must return EXACTLY ONE distinct tenant_id — 'acme'. Any other result
-- means either the view is pointing at the wrong table, or the dedicated
-- table accidentally got rows from another tenant during the INSERT.
SELECT DISTINCT tenant_id FROM tenant_acme.events;
-- Expected: one row, tenant_id = 'acme'. If you see more than one tenant_id
-- or a different tenant_id, ABORT — the migration is wrong and customers
-- may already be seeing cross-tenant data. Revert step 3 (CREATE OR REPLACE
-- VIEW pointing back at the shared table with WHERE tenant_id = 'acme') as
-- the immediate mitigation, then diagnose.

-- Check 2: as an admin principal, the SHARED table's $partitions metadata
-- must show ZERO rows for the migrated tenant. This confirms step 4's DELETE
-- actually removed the tenant's partitions from the shared table — without
-- it, you have the data living in BOTH tables, doubling storage and risking
-- future cross-tenant query bugs.
SELECT *
FROM iceberg.analytics."events$partitions"
WHERE partition.tenant_id = 'acme';
-- Expected: zero rows. If any rows return, the DELETE in step 4 did not
-- complete — re-run it. (If the table is bucket-partitioned, see the
-- "$partitions for bucket-partitioned tables" callout — use the data-layer
-- check SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme'
-- which must return 0.)
```

**Why the order matters — concrete failure scenarios:**

| Failure point | If order is INSERT → verify → swap → DELETE (CORRECT) | If order is INSERT → DELETE → swap (WRONG) |
|---|---|---|
| INSERT crashes midway | Dedicated table is partial; shared table is intact. Drop dedicated table and retry. **No data loss.** | Same — INSERT is first in both orders. |
| Verification fails (row counts don't match) | Abort. Shared table is intact; readers continue against shared. **No data loss.** | N/A — wrong order skips verification. |
| Coordinator crashes between DELETE and view swap | N/A — view swap happens before DELETE in the correct order. | **Data is missing from both tables.** Readers see empty results until you restore from a snapshot. P0 incident. |
| View swap fails | Dedicated table exists and matches; shared table still has the rows. Retry the view swap. **No data loss.** | N/A — DELETE already ran in the wrong order, so failure of the swap leaves readers seeing empty results. |
| DELETE fails after a successful swap | Readers are already on the dedicated table — they don't notice. Shared table has stale duplicates you can clean up later. **No user-visible impact.** | N/A — DELETE was already done in the wrong order. |

> **Cross-table writes are NOT atomic in Iceberg.** Iceberg's transaction guarantees are per-table — `INSERT INTO acme_events` and `DELETE FROM events` are two independent commits. There is no `BEGIN ... COMMIT` that spans both tables. This is the foundational reason the order matters: **never put the DELETE before a step you can't undo.** The view swap is undoable (run `CREATE OR REPLACE VIEW` again to point back at the shared table); the DELETE is undoable too (via `rollback_to_snapshot`) but only for ~7 days, and only if `expire_snapshots` hasn't run. The verify step is your last chance to abort before any destructive operation; the view swap is the actual cutover; the DELETE is just storage cleanup. Sequencing them in that order makes every intermediate failure recoverable.

> **Apply the same pattern in reverse for de-promotion** (moving a tenant from a dedicated table back into the shared table — e.g., they downsized and no longer warrant isolation): INSERT into shared → verify counts match → swap view back to shared (now with `WHERE tenant_id = 'acme'` re-added) → DROP the dedicated table. Same invariant: the destructive step is last.

> **Tenant migration and resource groups are complementary, not alternative, levers.** Promoting a tenant out of the shared table is a **storage-layout** intervention — it isolates the heavy tenant's data files so routine maintenance (compaction, snapshot expiry) on the shared table no longer pays their cost, and so per-tenant query scans against the dedicated table never compete with shared-table I/O. But it does **not** solve the **CPU/memory contention** problem at query time: an enterprise tenant running a 12-month aggregation query against their dedicated table can still saturate Trino worker CPUs and slow every other tenant's dashboard query, because all tenants share the same Trino cluster regardless of which Iceberg table their data lives in.
>
> The standard pairing on this stack: **migrate heavy tenants into dedicated tables (storage isolation) AND route their queries into a dedicated resource group queue (compute isolation).** Configure a `global.enterprise_tenants` subgroup in `etc/resource-groups.json` with `hardConcurrencyLimit`, `softMemoryLimit`, and `hardCpuLimit` set generously enough for their workload, then add selectors that route their principals into that subgroup. A dashboard query from `acme-service-account` lands in `global.enterprise_tenants` and competes only with other enterprise tenants for cluster CPU — small-tenant principals routed to `global.small_tenants` (with tighter caps) never get starved by Acme's monthly export. See the **Noisy neighbor** and **Resource groups JSON** sections below for the full configuration shape; the key teaching point here is that tenant migration is the storage half of the answer, and the resource group routing is the compute half — both are usually needed for an enterprise tenant whose workload would otherwise dominate the cluster.

---

## Trino-specific enforcement

This is the section that matters most for the production stack. Trino is where the query is parsed and executed, so it's the right place to enforce isolation.

### Trino views that bake in the tenant filter

A **Trino view** is a saved SELECT statement that looks like a table to callers. If you grant a customer access only to the view (not the base table), they cannot see other tenants' data even if they try.

> **CALLOUT — Trino views default to SECURITY DEFINER.** This means the view executes with the view **owner's** privileges, not the calling user's. When tenant Acme runs `SELECT * FROM tenant_acme.events`, Trino checks that the **view owner** has SELECT on the base table — not that Acme does. This is exactly what makes the filtered view secure: **Acme never needs (and should never be granted) direct access to `iceberg.analytics.events`.** The view owner reads the base table on Acme's behalf, the WHERE clause filters out everything that isn't Acme's, and only Acme's rows reach Acme. If you skip naming this mechanism, readers (and security reviewers) will reasonably ask "how does this work if the tenant has no base-table grant?" — the one-line answer is "SECURITY DEFINER is Trino's default; the view runs with the owner's grants."

> **CALLOUT — Operational risk: a single owner-account permission change can break every tenant view at once.** If the view owner account loses SELECT on the base table (e.g., an admin revokes permissions during a security audit, an OPA policy push accidentally removes the owner from the allow-list, or the service account is rotated incorrectly and the new identity wasn't granted base-table SELECT), **all per-tenant views break simultaneously** — every tenant sees `Access Denied` on every query through their view, with no indication of why. The Trino error message points at the view, not at the missing owner grant, so the root cause is non-obvious and the blast radius is total (every tenant, every dashboard, every BI report fails at once).
>
> To prevent this:
> - **Use a dedicated, stable service account as the view owner** (e.g., `trino-view-owner@internal`) — never an individual engineer's identity, never a shared admin account that might be rotated.
> - **Protect its grants with OPA policy** so they cannot be accidentally revoked. The OPA bundle should explicitly allow `trino-view-owner@internal` SELECT on `iceberg.analytics.*` and treat any change to that rule as a security-review-required event.
> - **Add a synthetic test query in CI / monitoring**: `SELECT 1 FROM tenant_acme.events LIMIT 1` against a representative tenant view, run every minute by your monitoring system. If this returns `Access Denied`, page the on-call — it means either the view owner has lost base-table access OR the view itself is broken, and both have the same all-tenants-down symptom. Failing fast on a synthetic query lets you fix the policy in minutes; waiting for a real tenant to file a support ticket can mean hours of total dashboard outage.

```sql
-- Base table — only ops/admin users can SELECT directly
CREATE TABLE analytics.events (
  event_id    BIGINT,
  tenant_id   VARCHAR,
  user_id     VARCHAR,
  event_type  VARCHAR,
  event_ts    TIMESTAMP,
  payload     VARCHAR
)
WITH (
  partitioning = ARRAY['tenant_id', 'day(event_ts)']
);

-- PREREQUISITE: create the per-tenant schema before any CREATE VIEW into it.
-- Without this step, the CREATE VIEW below fails with `Schema 'tenant_acme'
-- does not exist`. Trino does NOT auto-create the schema from the
-- `tenant_acme.events` qualified name. This is the first step of every tenant
-- onboarding workflow — easy to forget, very loud failure when you do.
CREATE SCHEMA IF NOT EXISTS tenant_acme;

-- One view per tenant, baked-in filter.
-- NOTE: SECURITY DEFINER (the Trino DEFAULT — no clause needed) is the correct
-- choice for multi-tenant isolation in this stack. Under DEFINER, the view body
-- runs with the VIEW OWNER's grants (a privileged service account that holds
-- SELECT on analytics.events). The tenant principal needs only SELECT on the
-- view itself — NOT on the base table. That's exactly the property you want:
-- the tenant has no direct base-table access, so they cannot bypass the view's
-- WHERE clause even if they try. OPA enforces this by denying tenant principals
-- direct base-table SELECT. See the DEFINER vs INVOKER section below for the
-- full discussion of why DEFINER (not INVOKER) is correct here.
--
-- STYLE TIP — even though SECURITY DEFINER is Trino's default and the
-- `SECURITY DEFINER` keyword can be omitted, writing it explicitly is
-- recommended for security-relevant views. The keyword turns the view's
-- security mode from "implicit, depends on Trino default" into "explicit,
-- visible to anyone reading the DDL or doing a security review." Reviewers
-- should not have to know Trino's default to confirm the view runs with the
-- owner's grants; the keyword tells them directly. Both forms below are
-- equivalent at runtime — pick the explicit form for production DDL.
CREATE VIEW tenant_acme.events SECURITY DEFINER AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM analytics.events
  WHERE tenant_id = 'acme';

-- Equivalent (relies on Trino's SECURITY DEFINER default) — accepted, but
-- the explicit form above is preferred for documentation clarity.
-- CREATE VIEW tenant_acme.events AS
--   SELECT event_id, user_id, event_type, event_ts, payload
--   FROM analytics.events
--   WHERE tenant_id = 'acme';

-- Step 1: create the role (a named bundle of permissions, like a Postgres role or Linux group).
--
-- IMPORTANT: Trino does NOT support `CREATE ROLE IF NOT EXISTS` (unlike Postgres).
-- The Trino CREATE ROLE synopsis is: `CREATE ROLE role_name [ WITH ADMIN ... ] [ IN catalog ]`
-- — no IF NOT EXISTS clause. Writing `CREATE ROLE IF NOT EXISTS acme_role` is a
-- SYNTAX ERROR and the statement will be rejected by the Trino parser.
--
-- For idempotency in a provisioning script (so re-running the script on an
-- already-onboarded tenant doesn't crash), do NOT add IF NOT EXISTS. Instead,
-- catch the "Role already exists" error at the application layer and treat it
-- as success. A typical Python pattern:
--
--   try:
--       trino_conn.execute("CREATE ROLE acme_role")
--   except trino.exceptions.TrinoUserError as e:
--       if "already exists" not in str(e).lower():
--           raise   # re-raise anything that ISN'T the expected "already exists"
--       # else: role exists, idempotent re-run — continue
--
-- Same pattern applies to GRANT ROLE and GRANT SELECT — these do NOT support
-- IF NOT EXISTS in Trino. (CREATE SCHEMA IS an exception — Trino's CREATE SCHEMA
-- syntax DOES support IF NOT EXISTS, as used in the prerequisite step above.)
-- For GRANT statements, wrap each in a try/except that whitelists the specific
-- "already granted" error and re-raises everything else. This keeps
-- provisioning scripts idempotent without hiding real failures.
CREATE ROLE acme_role;

-- Step 2: assign the role to the user who will query as this tenant.
-- THIS STEP IS REQUIRED — without it, the role exists but nobody has it.
-- Creating a role without GRANT ROLE ... TO USER is a silent no-op:
-- the role exists but no principal is assigned to it.
GRANT ROLE acme_role TO USER "acme-service-account";

-- Step 3: grant the role only access to the tenant-scoped view, not the base table.
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;

-- Step 4: REVOKE base-table access from the USER PRINCIPAL — not the role.
-- CRITICAL: Trino's default access control is allow-all for user principals.
-- The user "acme-service-account" already had implicit base-table access from
-- default allow-all BEFORE the role was created. The newly-created role never
-- had a base-table grant, so REVOKE FROM ROLE acme_role is a no-op against
-- that pre-existing access. You must REVOKE from the USER directly:
REVOKE ALL PRIVILEGES ON analytics.events FROM USER "acme-service-account";
```

> **OPA-backed Trino (this production stack) — what the SQL above actually does and does not do.** The production stack uses OPA (Open Policy Agent) as Trino's authorization backend (`access-control.name=opa` in `etc/access-control.properties`). On an OPA-backed cluster, the SQL `GRANT`, `REVOKE`, and `CREATE ROLE` statements shown above are **illustrative orientation** — they help you understand the conceptual access model (which principal should have what privilege on which object), but they are **not the real enforcement mechanism**. In this stack, the actual enforcement happens via OPA Rego policy in the external governance document (see `prod_info.md`). OPA is the authorization backend; SQL grants are not the source of truth. Concretely: running `REVOKE ALL PRIVILEGES ON analytics.events FROM USER "acme-service-account"` on an OPA-backed cluster has no effect on whether `acme-service-account` can actually read `analytics.events` — that decision is made by OPA's Rego evaluation, not by Trino's grants table.
>
> **What is still required and correct, regardless:** the view-as-isolation-boundary pattern (`CREATE VIEW tenant_acme.events AS SELECT ... WHERE tenant_id = 'acme'`) is still the right architectural shape — it ensures the WHERE clause is always applied, the view's `SECURITY DEFINER` semantics let the tenant read through it without holding base-table grants, and the principle of "one filtered view per tenant" is engine-agnostic. But the *mechanism* that prevents a tenant from querying the base table directly is **OPA denying the request**, not a `REVOKE` statement. Practical implication: when you provision a new tenant, the steps that actually change behavior are (a) `CREATE VIEW` for the tenant-scoped view, and (b) update the OPA Rego bundle to allow the tenant principal SELECT on the view AND deny it SELECT on the base table. The `GRANT ROLE` / `REVOKE` SQL is conceptually correct but operationally a no-op on this stack; do not skip the OPA bundle update thinking the SQL did the job.
>
> See the "SQL GRANT/REVOKE vs OPA — which one is the actual enforcement layer?" callout further down for the full picture.

> **Why the REVOKE step is defense-in-depth, given Trino's SECURITY DEFINER default.** Trino views run with **SECURITY DEFINER by default** — the view body executes with the view OWNER's grants (the admin / privileged service account that issued the `CREATE VIEW`), NOT the caller's grants. This means the view can read `analytics.events` on the tenant's behalf even though the tenant principal has no direct table access. So strictly speaking, the view's `WHERE tenant_id = 'acme'` filter IS the isolation boundary, and the tenant cannot bypass it by querying the view differently. The `REVOKE ALL PRIVILEGES ON analytics.events FROM USER ...` step ensures the tenant ALSO cannot bypass the view by querying the raw base table directly — closing the back door that Trino's default allow-all access control would otherwise leave open. In short: SECURITY DEFINER makes the view safe; the REVOKE makes sure the view is the *only* path to the data.

> **REVOKE target: USER vs ROLE — this distinction matters.** When a user principal was created under Trino's default "allow-all" access control, that user already had implicit access to every table by default — not because of any role, but because of the allow-all default itself. A newly-created role does NOT inherit or proxy that default access; the role simply has no grants at all. This means:
>
> - `REVOKE ALL PRIVILEGES ON analytics.events FROM ROLE acme_role` — **no-op against the reported symptom.** The role never had the grant; revoking from it changes nothing. The user still reads the base table through their own default allow-all access.
> - `REVOKE ALL PRIVILEGES ON analytics.events FROM USER "acme-service-account"` — **this is what actually closes the back door.** It removes the user principal's direct base-table access.
>
> In production with **file-based access control or OPA**, the effective mechanism is the policy file / OPA Rego rules — not SQL GRANT/REVOKE statements. The SQL REVOKE commands above work in Trino's built-in access control, but with OPA configured, the OPA policy must explicitly deny base-table SELECT for non-admin principals. SQL-level revokes do not affect what OPA decides. Defer specific OPA policy rules to your external governance document.
>
> **Bottom line:** after creating a role and granting it to a user, you must ALSO either (a) `REVOKE ALL PRIVILEGES ON base_table FROM USER "the-principal"`, or (b) configure your access control policy to deny base-table access for this principal. Doing only the view GRANT and role assignment but skipping the revoke leaves the base table readable — a silent back door that bypasses the view layer entirely.

> **TENANT-ADMIN AND SUB-TENANT (BUSINESS UNIT) ROLES MUST ALSO BE SCOPED VIA A TENANT-FILTERED VIEW — NEVER GRANTED DIRECTLY ON THE BASE TABLE.** This is the single most common cross-tenant data exposure bug when teams introduce "admin" or "business-unit" roles on top of the per-tenant role layout. The mistake looks reasonable: "tenant 5001's admin should see *all* of tenant 5001's data, so just give them SELECT on the base table." That is wrong. Granting SELECT on the base table to a tenant-admin role exposes **every tenant's** rows, not just tenant 5001's — because the base table holds all tenants' data and there is nothing on the base table itself that filters by `tenant_id`. The leak is total and silent: the admin can run `SELECT * FROM analytics.events` and see every customer's data.
>
> The correct pattern is the **same view-scoping discipline** you used for the regular tenant role — just applied to the admin role too. Create a tenant-scoped admin view, grant the admin role SELECT on that view, and revoke any access on the base table:
>
> ```sql
> -- Step 1: create a tenant-scoped admin view. The view's WHERE clause is the
> -- security boundary — the admin sees ALL columns for tenant 5001, but ONLY
> -- tenant 5001's rows.
> CREATE VIEW tenant_5001_admin_view AS
>   SELECT *  -- admin sees every column, unlike the customer-facing view
>   FROM analytics.events
>   WHERE tenant_id = '5001';
>
> -- Step 2: grant the admin role SELECT on the tenant-scoped view ONLY.
> -- CORRECT — scoped to tenant 5001's rows:
> GRANT SELECT ON tenant_5001_admin_view TO ROLE tenant_5001_admin;
>
> -- NEVER do this — it exposes ALL tenants' data to the tenant-5001 admin:
> --   GRANT SELECT ON analytics.events TO ROLE tenant_5001_admin;
>
> -- Step 3: belt-and-suspenders — revoke any inherited base-table access.
> REVOKE ALL PRIVILEGES ON analytics.events FROM ROLE tenant_5001_admin;
> ```
>
> The same rule applies to sub-tenant or business-unit roles inside a single customer (e.g., tenant 5001 has business units `bu_north`, `bu_south`): create one tenant-and-BU-scoped view per business unit (`WHERE tenant_id = '5001' AND business_unit = 'bu_north'`), grant the BU role SELECT on that view, and never on the base table. The only roles that should ever receive SELECT on the unfiltered base table are your **internal data team / platform admins** who legitimately need cross-tenant access — and even then, audit-log every base-table query (see the HTTP event listener section). If a CI test ever observes a tenant-scoped role with a successful `SELECT FROM analytics.events`, treat it as a P0 security incident.

Now an Acme user running `SELECT * FROM tenant_acme.events` only ever sees Acme rows. They cannot query `analytics.events` directly — Trino blocks them.

> **View invalidation on schema changes.** When the underlying base table schema changes (a column is added or dropped), any views that reference that table may become invalid in Trino. After running `ALTER TABLE analytics.events ADD COLUMN new_col VARCHAR`, run `SHOW CREATE VIEW tenant_acme.events` to verify the view still resolves. If it fails, recreate it. For large deployments, script a `SHOW CREATE VIEW` check across all tenant views as part of your schema migration process — fail the migration if any view fails to resolve, so a single ALTER TABLE never silently breaks 80 tenant views at once.

For dynamic per-session enforcement (one view that adapts to the caller), use Trino's `current_user` function combined with a lookup table. Leave the view as **`SECURITY DEFINER` (the default)** — under DEFINER, the view body runs with the owner's grants (the owner holds SELECT on both `analytics.events` and `config.user_tenant_map`), and the tenant principal only needs SELECT on the view itself:

```sql
-- Trino default is SECURITY DEFINER — no explicit clause needed.
-- The view runs with the OWNER's grants; the calling tenant principal needs
-- only SELECT on this view, not on analytics.events or config.user_tenant_map.
-- current_user still returns the CALLING tenant's principal (DEFINER does NOT
-- rewrite current_user to the owner — see the DEFINER vs INVOKER section).
CREATE VIEW analytics.my_events AS
  SELECT e.*
  FROM analytics.events e
  JOIN config.user_tenant_map m
    ON e.tenant_id = m.tenant_id
  WHERE m.username = current_user;
```

> **CORRECTION — for multi-tenant isolation on this stack, USE `SECURITY DEFINER` (the Trino default). DO NOT add `SECURITY INVOKER`.** Earlier versions of this guide incorrectly recommended INVOKER. The corrected model below explains why DEFINER is the right answer when tenants do NOT hold direct base-table grants (the standard OPA-backed setup).
>
> **What `current_user` actually returns (both modes):** `current_user` **always returns the principal who is *executing* the query** — i.e., the tenant who submitted the SELECT — regardless of whether the view is `SECURITY DEFINER` or `SECURITY INVOKER`. This is a common misconception: `current_user` is **not** rewritten to the view owner under DEFINER mode. The mode only affects **whose grants are used to read the base tables**, not what `current_user` returns.
>
> **What actually changes between DEFINER and INVOKER:** the difference is **whose table GRANTS are used to read the tables referenced inside the view body**. This is the real security knob — and for a deny-by-default OPA setup where tenants have no direct base-table access, DEFINER is what makes the view pattern work at all.
>
> - **`SECURITY DEFINER` (Trino DEFAULT — CORRECT for multi-tenant on this stack):** the view body runs with the **view owner's** grants. The owner is a privileged service account (e.g., `analytics-owner`) that holds SELECT on `analytics.events`. The tenant principal needs **only SELECT on the view itself** — NOT on the base table. Because OPA denies the tenant principal any direct SELECT on `analytics.events`, the tenant has exactly two paths to the data: (a) through the view, where the baked-in `WHERE tenant_id = 'acme'` filter limits what they see; or (b) directly against `analytics.events`, which OPA rejects with `Access Denied`. Path (b) is closed by policy, so the view's WHERE clause IS the isolation boundary, and it cannot be bypassed. This is the standard "view-as-security-boundary" pattern, and it relies on DEFINER semantics plus OPA's base-table deny.
>
>   Defense-in-depth requirements when using DEFINER:
>   - The OPA policy MUST explicitly deny base-table SELECT for every tenant principal (otherwise the tenant can just bypass the view by selecting from `analytics.events` directly).
>   - The view owner must be a dedicated service account whose credentials are not held by anyone except the platform team — if a tenant could compromise the owner identity, they would inherit the owner's full base-table access.
>   - The view's WHERE clause must be reviewed carefully (CI test: as each tenant principal, `SELECT DISTINCT tenant_id FROM <their_view>` must return exactly one value — their own).
>
> - **`SECURITY INVOKER` (NOT the right choice for tenant isolation here):** the view body runs with the **querying user's** grants. The caller MUST have SELECT directly on every base table the view references. If the tenant principal has no grant on `analytics.events`, the query fails at planning with `Access Denied` — the view does not give them a back door to the table. In other words: **INVOKER does NOT let a "no-grant" tenant query through a view.** That commonly-stated pattern ("tenant has no base-table grant, but the view's WHERE clause filters their query through") is DEFINER's pattern, not INVOKER's.
>
>   What INVOKER would mean in this OPA environment: you would have to write an OPA policy that ALLOWS each tenant direct SELECT on `analytics.events` (otherwise INVOKER views can't read anything), and then ALSO have OPA enforce a row filter that restricts what rows that tenant can see. In that world, the view's `WHERE tenant_id = 'acme'` clause is a saved-filter convenience for the user — it is NOT the security boundary; OPA's row-level policy is. This is strictly weaker than DEFINER for tenant isolation: every tenant principal now has a direct base-table grant (broader blast radius if OPA's row filter is misconfigured), and you are running the same authorization decision twice (once in OPA, once in the view's WHERE).
>
> **Decision rule.** For multi-tenant analytics on Trino + OPA + Iceberg + MinIO:
>
> | Goal | Use | Why |
> |---|---|---|
> | Tenant queries through a view; tenant has NO base-table grant | **`SECURITY DEFINER` (default)** | View owner's grants read the table; OPA blocks the tenant from selecting the base table directly; the view's WHERE clause is the isolation boundary. |
> | Tenant has direct base-table access enforced by OPA row-level policy; the view is a UX convenience | `SECURITY INVOKER` | Caller's grants read the table; OPA's row filter does the isolation. Weaker for tenant isolation; rarely the right model. |
>
> **30-second test to confirm the model is set up correctly.** Connect as a tenant principal and run two queries:
>
> 1. `SELECT count(*) FROM tenant_acme.events` — must succeed and return only Acme's rows.
> 2. `SELECT count(*) FROM analytics.events` (the base table directly) — must fail with `Access Denied` (rejected by OPA).
>
> If query 1 succeeds and query 2 fails, your DEFINER + OPA setup is correct: the tenant can reach the data only through the filtered view. If query 2 also succeeds, OPA is not denying the tenant direct base-table access and the view is not actually an isolation boundary — fix the OPA policy.

> **IMPORTANT — under DEFINER (the default), tenants need SELECT ONLY on the view, NOT on the base tables or any joined lookup tables.** This is exactly what makes DEFINER the right choice for this pattern. For the dynamic `current_user` view shown above, the view owner needs SELECT on both `analytics.events` and `config.user_tenant_map`; the tenant principal needs only SELECT on `analytics.my_events`. You do NOT grant tenant roles SELECT on `config.user_tenant_map` — under DEFINER, that lookup table is read with the owner's grants, not the tenant's. (If you switched to INVOKER, you WOULD need to grant tenant roles SELECT on every table the view body references — including `config.user_tenant_map` — which is another reason INVOKER is the wrong choice for this pattern: it forces you to widen tenant grants for tables they shouldn't see directly.)

> **Tradeoff: blast radius of a bug in the dynamic-view pattern vs per-tenant views.** A bug in the `user_tenant_map` lookup table (wrong username mapping, stale entry, accidental row deletion, typo when onboarding a new tenant) breaks isolation for **ALL tenants simultaneously** — every tenant gets the wrong data, or no data, on the next query. With per-tenant hardcoded views (`tenant_acme.events` with `WHERE tenant_id = 'acme'`), a bug in one view affects only that one tenant; the other 79 are untouched. At 80 tenants, per-tenant views are still manageable — adding a tenant means one `CREATE VIEW` and one `GRANT`, which fits comfortably in an onboarding script — and they offer this **one-at-a-time failure mode**. The dynamic `current_user` pattern becomes compelling at **200+ tenants** where per-tenant view provisioning becomes a maintenance burden (large CREATE VIEW migrations on schema changes, role-grant sprawl, longer Hive Metastore catalog listings). Below ~150 tenants, prefer per-tenant views; above, the dynamic pattern's operational simplicity outweighs its single-point-of-failure risk — but only if you have CI tests that detect a stale `user_tenant_map` immediately.

> **Lighter alternative: single service account + session property + query-rewrite proxy.** Before committing to the full per-principal + OPA setup (which requires an OPA bundle, JWT issuance, per-tenant role provisioning, and CI assertions for every tenant), some teams ship a **simpler middle ground**: one shared Trino service account that the backend uses for all tenants, plus a thin **query-rewrite proxy** (a small HTTP service in front of Trino) that injects `WHERE tenant_id = '<caller>'` into every incoming SQL statement based on the **caller's session property** (e.g., a custom `X-Tenant-Id` header the backend sets per request, or a Trino session property `set session tenant_id = 'acme'` the proxy adds). The proxy parses the SQL, rewrites the FROM clauses to point at filtered subqueries, and forwards the rewritten SQL to Trino under the shared service account. Trino sees only one principal, so there is no per-tenant grant management, no JWT issuance, no OPA bundle — the entire isolation boundary lives in the proxy's rewrite logic. **The cost: the proxy is now a single point of failure for cross-tenant isolation** — a parser bug, a missed AST case, or any path that lets raw SQL through unrewritten is a total leak. There is also no defense-in-depth: if the proxy is bypassed (someone connects directly to Trino with the shared service-account credential), they see every tenant's data. **Recommend the per-principal + OPA pattern for production multi-tenant deployments** — it survives proxy bypass, gives you query-engine-level audit (every event listener entry carries the real tenant principal), and matches what regulated customers expect to see in a security review. The lighter alternative is a reasonable bridge for **teams not yet ready to roll out OPA** (no bundle infrastructure, no JWT issuer, small tenant count, low regulatory exposure) — ship it as the day-one isolation layer, then migrate to per-principal + OPA before the tenant count, audit scope, or compliance posture forces the issue.

### Trino system access control

Trino's **system access control** is a plugin that decides, for every query, whether a user can read a given table, column, or row.

**When in the query lifecycle does this happen?** A common shorthand is "Trino evaluates permissions before parsing" — that's wrong, and a security reviewer will catch it. The accurate version: **access control is evaluated after parsing but before execution.** Trino parses the SQL into an abstract syntax tree (AST), runs the analysis phase (which is when the access control plugin is consulted for each table, column, and view referenced), and only if every check passes does the query proceed to the execution stage where it would actually read data. The substantive guarantee you care about still holds: **Trino rejects the query during analysis, before touching any data in MinIO.** Unauthorized queries never reach the storage layer — they fail at the coordinator with a `Access Denied` error before a single Parquet file is opened.

Two common implementations on-prem:

- **File-based access control**: a JSON or properties file (`rules.json`) on the Trino coordinator that maps users/groups to allowed catalogs, schemas, and tables. Good for small numbers of static rules.
- **Open Policy Agent (OPA)**: an external policy engine. Trino calls out to OPA for every query, asking "can user X read table Y?". OPA evaluates a policy written in Rego (its policy language). Good for complex, dynamic rules that change without restarting Trino.

For multi-tenant, the typical setup is: file-based rules for ops staff, plus per-tenant Trino roles that only grant SELECT on the matching tenant view.

Configuration lives in `etc/access-control.properties` on the Trino coordinator pod.

> **SQL GRANT/REVOKE vs OPA — which one is the actual enforcement layer?** This is a constant source of confusion. Trino has TWO independent authorization paths and they do NOT stack the way engineers usually expect:
>
> - **Built-in SQL ACL (no OPA plugin)**: `GRANT SELECT ON ... TO ROLE ...` / `REVOKE ...` statements are stored in the Trino catalog and consulted by Trino's default access control. This is the path the GRANT/REVOKE examples earlier in this guide demonstrate.
> - **OPA plugin enforcement (the production stack)**: when `access-control.name=opa` is configured in `etc/access-control.properties`, **OPA becomes the ONLY authorization backend**. Trino routes every access decision (table SELECT, column read, query submission, view access) to OPA via an HTTP call. **SQL `GRANT` and `REVOKE` statements are effectively bypassed** — running `GRANT SELECT ON analytics.events TO ROLE acme_role` on an OPA-backed cluster does nothing useful because Trino does not consult its own grants table when OPA is the configured access controller; OPA's Rego policy is what answers "can acme_role read analytics.events?"
>
> **On the production stack: OPA IS the ACL layer.** The GRANT/REVOKE SQL shown in code examples above is educational (it shows what the equivalent permission model looks like), but the actual enforcement is defined in your OPA Rego policy bundle — not in SQL. Defer the specific Rego rules to your external governance document (see `prod_info.md`); update the OPA bundle, not SQL grants, when permissions need to change.

> **Defense-in-depth on this stack — the three layers are all engine-level, NOT a mix of SQL grants and OPA.** A common (incorrect) mental model is "Layer 1 = view WHERE clause; Layer 2 = SQL GRANT/REVOKE on the base table; Layer 3 = OPA policy." That model is wrong for the production stack because **SQL GRANT/REVOKE is not the enforcement mechanism here — OPA is.** The correct three-layer model when Trino is configured with OPA as the system access control:
>
> - **Layer 1 — Per-tenant view's WHERE clause.** `CREATE VIEW tenant_acme.events AS SELECT ... WHERE tenant_id = 'acme'`. This is the hard-coded tenant filter that runs whenever a tenant principal reads through the view. Under SECURITY DEFINER (Trino default), the view runs with the owner's grants, so the tenant principal never needs base-table access to read through it. If a single bug deletes this WHERE clause, Layer 2 still denies the request before the user can exploit it.
>
> - **Layer 2 — OPA policy denies base-table SELECT for tenant principals.** OPA's allow/deny rule rejects any direct query against `iceberg.analytics.events` from a tenant principal — they can only reach the data through the per-tenant view (or via OPA's row-filter mode on the base table; the two patterns are alternatives, not stacked). This closes the back door that Trino's default allow-all would otherwise leave open. **This is the layer that, in a non-OPA cluster, would be implemented as `REVOKE ALL ON analytics.events FROM USER ...` — but on an OPA-backed cluster, only the OPA policy matters; the REVOKE statement is a no-op.**
>
> - **Layer 3 — OPA policy denies system catalog and Iceberg metadata table access.** OPA rejects any tenant principal's query that mentions `system.runtime.queries` (would leak other tenants' SQL), any `iceberg.<schema>."*$*"` table (would leak partition/file metadata revealing tenant counts and sizes), and any cross-tenant admin view. See the "system catalog leak" and "Iceberg metadata table leak" sections below for the specific tables to deny.
>
> All three layers live in **engine-level configuration** — the view definition (Layer 1) is a Trino DDL artifact; Layers 2 and 3 are OPA Rego rules in your governance bundle. SQL `GRANT` and `REVOKE` are not in any layer on this stack. If you find yourself writing "Layer N = SQL GRANT/REVOKE" in a security design doc for an OPA-backed Trino cluster, replace it with "Layer N = OPA Rego rule" — that is the actual enforcement.

### OPA authorization lifecycle — when OPA fires, and what happens when it doesn't

This section answers the most common on-call question about OPA: **"My OPA service is down (or a policy just changed mid-flight) — what happens to queries that are already running?"** The answer is precise, quotable, and almost always misunderstood on first read.

#### The one-line quotable rule

> **OPA is consulted only during query analysis (planning), never during distributed execution. A query that has passed authorization and begun executing will run to completion regardless of subsequent OPA outages or policy updates.**

This rule has two practical halves:

1. **Authorization happens once per query, at the start, on the coordinator.** Every table, column, view, function, and system-catalog reference in the SQL is checked against OPA during the analysis phase. If any check fails, the query is rejected with `Access Denied` before a single byte of data is read from MinIO.
2. **After analysis passes, OPA is out of the picture for that query.** Workers do not call OPA when they read splits, when they shuffle data, or when they stream results to the client. There is no "mid-query reauthorization" hook in Trino. A policy that changes one second after a query starts executing applies to the **next** query — never to the running one.

#### The four-scenario failure mode table

This is the authoritative reference for what happens to **new** queries vs **in-flight** queries under each common OPA-related event:

| Scenario | New queries | In-flight queries |
|---|---|---|
| **OPA service goes down** (pod crash, network partition, HTTP 5xx) | **FAIL CLOSED** — `Access Denied` / HTTP error returned at the coordinator; the query is rejected during analysis and never starts execution | **Unaffected** — the query has already passed authorization and runs to completion, even if OPA never recovers before the query finishes |
| **Policy change pushed** (new Rego rule or bundle replaces the prior one) | The new policy takes effect on the **next** query's analysis — the very next `SELECT` evaluated by OPA sees the new rule | **NOT affected** — they completed their authorization decision before the policy changed; the old policy's decision sticks for the lifetime of the query |
| **OPA bundle refresh** (data bundle update, e.g., a new tenant added to `data/tenants.json`) | New bundle data becomes available on OPA's next poll cycle (typically 30s–5min depending on `services.<name>.polling.min_delay_seconds`/`max_delay_seconds`); subsequent queries see the new data | **NOT affected** — same reasoning; authorization already happened with the prior bundle |
| **Coordinator restart** (pod evicted, JVM crash, rolling deploy) | New queries hit the new coordinator and reauthorize against OPA normally | **In-flight queries on workers may fail** with coordinator-disconnect errors (worker-coordinator heartbeat channels are broken) — this is a coordinator-failure issue, not an OPA issue; OPA's behavior is irrelevant here |

**Why this matters on-call.** If you get paged at 3am because OPA's pod is crashlooping, you do NOT need to also page the data team to "kill in-flight queries before they read stale data." In-flight queries are decoupled from OPA — they will finish whatever they were doing. Your only urgent task is to restore OPA so new queries can be accepted. Conversely: if a tenant just had their access revoked via a Rego push and a 4-hour `INSERT INTO ... SELECT` is mid-flight under that tenant's principal, **the running query will complete and write its results.** The policy change does not retroactively kill in-flight work. If you need to stop it, you must explicitly cancel the query (`CALL system.runtime.kill_query('<query_id>')`).

#### JDBC cancel lifecycle on query failure or cancellation

This explains what happens to the **PostgreSQL JDBC connections** that a federated query holds open, when the query is cancelled or fails for any reason (OPA denial of a follow-up query is one cause; `kill_query()`, query timeout, and coordinator disconnect are others).

When a Trino query is cancelled or fails (regardless of cause):

- The coordinator sends a cancel signal to all workers participating in the query.
- Workers call `Statement.cancel()` on any open JDBC statements the query owns. This is implemented in Trino's JDBC-based connectors (PostgreSQL, MySQL, etc.) since PR [#7306](https://github.com/trinodb/trino/pull/7306) and PR [#7819](https://github.com/trinodb/trino/pull/7819).
- PostgreSQL receives the cancel and **terminates the backend process** servicing that connection's in-flight query.
- You can verify the cleanup from the Postgres side: `SELECT * FROM pg_stat_activity WHERE usename = 'trino_reader'` — the row for the cancelled query disappears within a few seconds.
- **There is no zombie connection risk for properly cancelled queries**; the JDBC cancel mechanism cleans them up deterministically.

**Edge case — worker crash without graceful cancel.** If a Trino worker dies abruptly (JVM OOM kill, Kubernetes pod eviction, kernel panic), the `Statement.cancel()` path may never fire. In that case, the Postgres backend keeps running the query until one of:

- Postgres's own `tcp_keepalives_idle` detects the dead TCP peer (default **7200 seconds** = 2 hours — far too long for a busy Postgres).
- Postgres's `statement_timeout` (or `idle_in_transaction_session_timeout`) fires.

**Mitigation for your read replica config** (set in `postgresql.conf` on the read replica Trino connects to):

```
tcp_keepalives_idle = 300        # check for dead peer every 5min instead of 2h
tcp_keepalives_interval = 30
tcp_keepalives_count = 3
statement_timeout = 1800000      # kill any query running >30min as a backstop
```

With these set, a Trino worker that dies abruptly will leave a zombie Postgres backend for at most ~5 minutes (instead of 2 hours), and any single query will be capped at 30 minutes regardless.

#### OPA observability hooks for production debugging

When OPA misbehaves in production, these are the hooks that let you diagnose without guesswork:

- **Trino OPA plugin logger.** Set the logger `io.trino.plugin.opa.OpaHttpClient` to `DEBUG` in `etc/log.properties` on the coordinator. This logs every HTTP request to OPA, the response body, and any HTTP error. Crucial for distinguishing "OPA returned `allow: false`" (policy denial) from "OPA returned HTTP 503" (service outage) — they look identical in the user-facing error message, but the root cause is different.
- **Trino error codes.** OPA-denied queries show up in `system.runtime.queries.error_code` as `PERMISSION_DENIED`. OPA-unreachable queries show up as `EXTERNAL` (or `SERVER_STARTING_UP` if it's at coordinator boot). Grep your event listener output by `error_code` to separate policy denials from infrastructure failures.
- **`system.runtime.queries` lookup.** `SELECT query_id, query, error_code, error_message FROM system.runtime.queries WHERE error_message LIKE '%Access Denied%' ORDER BY created DESC LIMIT 20` — the recent OPA-denied queries with their full SQL, useful for "which query did OPA just kill?"
- **OPA decision log.** See the "OPA decision log" section earlier in this file for the authoritative per-decision audit trail (every allow/deny with full input/output JSON). For runtime debugging, the decision log answers "what input did Trino send OPA, and what did OPA return?" — when the user-facing error doesn't tell you why a policy denied.
- **Postgres-side verification.** For federated queries that touch Postgres, `SELECT pid, usename, query, state, query_start FROM pg_stat_activity WHERE usename = 'trino_reader'` shows what Trino is currently running over the federation — useful for confirming that a cancelled Trino query actually freed its Postgres backend.

#### On-call decision tree

A compressed decision tree for the common OPA-related pages. Use this to triage in 30 seconds:

```
Query received "Access Denied" at submission:
  -> OPA is up and policy denied it
  -> Action: check OPA policy / user identity / JWT-to-username mapping
  -> Likely causes: tenant principal mapping missing from data bundle;
     Rego rule changed; user's JWT claim missing or wrong

Query "Access Denied" but the SAME query previously worked:
  -> OPA policy update landed; the new rule denies what the old rule allowed
  -> Action: diff the latest OPA bundle against the prior version
  -> Verify with `opa eval -d <bundle> -i <captured_input.json> data.trino.allow`
     using a captured Trino->OPA input payload

Long-running query died unexpectedly mid-execution:
  -> OPA was NOT the cause (authorization already passed before execution started)
  -> Check worker logs for OOM / pod eviction / network failure
  -> Check Postgres slow-query log for the JDBC session that backed it
  -> Check Trino coordinator logs for split-failure messages

OPA service is DOWN (pod CrashLoopBackOff, HTTP 5xx, network partition):
  -> All NEW queries fail at analysis with `Access Denied` (or `EXTERNAL` error code)
  -> All IN-FLIGHT queries continue running unaffected — they passed authz earlier
  -> Action: restart the OPA pod / fix the bundle that's crashing OPA / restore network
  -> No Trino-side recovery needed; no in-flight query state to clean up
  -> Do NOT mass-cancel in-flight queries — they will finish normally

OPA service is SLOW (high latency, intermittent timeouts):
  -> NEW queries may time out at analysis (Trino has a per-call OPA HTTP timeout)
  -> Consider enabling the OPA batch endpoint (opa.policy.batched-uri) to reduce
     the number of HTTP calls per query — see the batched-uri section in this file
  -> Check `io.trino.plugin.opa.OpaHttpClient` DEBUG log for per-call latency
```

The single most common on-call mistake is **conflating "OPA is down" with "running queries are unsafe."** They are not. OPA's outage affects the front door (new query admission), not the queries already inside. Internalize this and you can answer 80% of OPA-related pages correctly without escalating.

### OPA row-filter mode — automatic per-caller WHERE clause injection

Most engineers' first mental model of OPA is "allow/deny": Trino asks OPA "can user X read table Y?" and OPA answers yes or no. That's correct but incomplete — OPA can do **more than allow/deny**. The Trino OPA plugin also supports **row-level filter injection**: a mode where OPA returns not just a boolean decision but a **WHERE clause fragment** that Trino automatically appends to the user's query. This is the direct answer to "automatically filter rows based on who's running the query, without requiring every query to include `WHERE tenant_id = ...`."

**How it works.** For tables configured under the row-filter policy, Trino sends OPA a context payload that includes the calling principal and the target table. OPA evaluates the Rego rule and returns a SQL expression like `tenant_id = 'acme'`. Trino's analyzer then rewrites the query as if the user had typed:

```sql
-- User typed this:
SELECT * FROM analytics.events;

-- Trino actually executes this (OPA-injected predicate in bold):
SELECT * FROM analytics.events WHERE tenant_id = 'acme';
```

The injection happens transparently at query analysis time — the application sends a bare `SELECT *`, OPA injects the predicate, and only the caller's tenant rows ever leave the engine. No WHERE clause in the SQL the app submits. No per-tenant view to maintain. No risk of a forgotten filter leaking everything.

**Conceptual Rego shape (pseudocode — DO NOT copy as actual policy).** The Rego rule shape, in plain English: "for table `analytics.events`, derive `tenant` from `input.context.identity.user` (via username encoding or an OPA data bundle lookup — see Patterns 1 and 2 in the callout below) and return the filter expression `tenant_id = '<tenant>'`." Note that the derivation reads only `input.context.identity.user` and possibly `data.tenant_map` — **never `input.context.identity.claims`, because that field does not exist on Trino 467's OPA integration**. The real Rego (including the exact `rowFilters` response shape the Trino OPA plugin expects, the principal-to-tenant mapping, and how to handle admin principals who should NOT have a filter applied) lives in your external governance document — per `prod_info.md`, do not hand-craft Rego in this guide.

> **CRITICAL — OPA does NOT receive JWT claims. It only sees the Trino username and groups.** This is the single most common factual error engineers make when first designing tenant-aware OPA policy on Trino. The mental model "OPA reads my JWT's `tenant_id` claim and routes accordingly" is **wrong** for Trino 467's OPA system access control plugin. Per the official Trino OPA documentation, the `identity` object Trino passes to OPA contains **only two fields**: `user` (the Trino username, which is whatever Trino's authenticator mapped the credential to) and `groups`. **There is no `claims` field. `input.context.identity.claims.tenant_id` does not exist** — an OPA policy that reads it gets undefined / null silently, and the rule fires (or fails) in unexpected ways. (The PR that would add JWT claims to the identity object — trinodb/trino #22944 — is unmerged as of Trino 467.)
>
> **What actually happens with JWTs on this stack:**
> 1. The client presents a JWT in the `Authorization: Bearer <jwt>` header.
> 2. Trino's JWT authenticator (configured via `http-server.authentication.type=JWT`) validates the signature and extracts a **username** from a configured claim — typically `sub`, but configurable via `http-server.authentication.jwt.user-mapping.pattern` / `.principal-field`.
> 3. That extracted username becomes Trino's principal — it is what shows up in `current_user`, in event-listener logs, AND in `input.context.identity.user` that OPA receives.
> 4. The rest of the JWT (other claims, signing metadata, original token) is **discarded** before the access-control plugin is consulted. OPA never sees it.
>
> **What OPA's `input` object actually contains** (the real Trino 467 payload, verified against the official Trino OPA docs):
>
> ```json
> {
>   "action": {
>     "operation": "SelectFromColumns",
>     "resource": {
>       "table": {
>         "catalogName": "iceberg",
>         "schemaName": "analytics",
>         "tableName": "events"
>       },
>       "columns": ["user_id", "event_name", "occurred_at"]
>     }
>   },
>   "context": {
>     "identity": {
>       "user": "acme--svc",
>       "groups": []
>     },
>     "softwareStack": {
>       "trinoVersion": "467"
>     }
>   }
> }
> ```
>
> Notice: `identity` has only `user` and `groups`. **No `claims`. No `tenant_id`. No JWT.** Any tenant-extraction logic in Rego MUST work from the `user` string (or the `groups` list).
>
> **The two correct patterns for tenant-aware OPA policy.** Since OPA only sees the Trino username, you must encode the tenant somewhere derivable from that username. Two production-proven patterns:
>
> **Pattern 1 — Encode tenant ID in the Trino username (simplest, most common).** Configure your JWT issuer (or whatever authenticator Trino is using) so the Trino username it produces carries the tenant as a prefix. For example, instead of mapping a JWT's `sub` claim to `acme-service-account`, map it to `acme--svc` — where the segment before the `--` separator is the tenant ID. Then in Rego:
>
> ```rego
> # Extract tenant from username like "acme--svc" -> "acme"
> tenant := split(input.context.identity.user, "--")[0]
> ```
>
> The double-dash `--` is a safe separator because tenant IDs (UUIDs, slugs) don't contain `--`. Single-dash `-` would collide with multi-word tenant IDs like `acme-corp`; pick a separator your tenant IDs will never contain.
>
> **Pattern 2 — OPA data bundle mapping (more flexible, no username convention required).** Maintain a username-to-tenant lookup table in OPA's data bundle:
>
> ```json
> // OPA data bundle: data/tenants.json
> {
>   "tenant_map": {
>     "acme-svc": "acme",
>     "beta-svc": "beta",
>     "internal-analytics": "internal"
>   }
> }
> ```
>
> Then in Rego:
>
> ```rego
> tenant := data.tenant_map[input.context.identity.user]
> ```
>
> Onboarding a new tenant means adding one line to `data/tenants.json` and pushing the bundle — no Rego changes, no Trino restart. Pattern 2 is the better choice when username conventions can't be enforced (e.g., human-user principals don't follow the service-account naming scheme), when the same username must map to different tenants in different environments (the bundle differs per env), or when tenant identity needs to be revocable (delete the row from the bundle, and the next OPA evaluation denies that username).
>
> **Operational caveat — OPA data bundle polling cadence creates a propagation window.** Changes to `data/tenants.json` (and the rest of the OPA data bundle) propagate to OPA on the **next bundle poll cycle**. OPA pulls its bundle from the configured bundle server (S3, an HTTP endpoint, etc.) at a fixed interval set in OPA's configuration — **typically 30 seconds to 5 minutes depending on `services.<name>.polling.min_delay_seconds` / `max_delay_seconds`**. During the window between (a) pushing a new `tenants.json` to the bundle server and (b) OPA picking it up on the next poll, **the previous tenant_map is still in effect** — a user who has been moved from tenant `acme` to tenant `beta` will still see `acme`'s data on any query that runs during that window. For routine adds/removes the staleness window is harmless, but for **tenant changes that affect a specific human user** (e.g., user `alice@beta.com` is reassigned from tenant `acme` to tenant `beta`), the correct sequence is:
>
> 1. **Revoke `alice`'s current JWT first** at the issuer (mark it invalid in your IdP's revocation list, rotate the signing key if you must, or set a very short TTL on tenant-bound JWTs from day one so revocation is implicit). This ensures `alice` cannot mint or replay a JWT mapped to the old tenant during the propagation window.
> 2. **Then push the updated `tenants.json` to the OPA bundle server.**
> 3. `alice` re-authenticates against the IdP and receives a new JWT; by the time she makes her next request, OPA has polled the new bundle and her identity now maps to the correct tenant.
>
> If you skip step 1 and update the bundle first, `alice` retains a valid JWT mapped to the **old** tenant for up to one poll cycle, and any request she makes during that window is authorized against the wrong tenant. This is the kind of race condition that only shows up in audit logs after the fact — design the sequence correctly from day one. For tenants/users that are deleted entirely (not reassigned), the same ordering applies: revoke the JWT at the issuer first, then drop the bundle entry.
>
> **Third option — custom JWT authenticator via Trino's SPI (heavy lift, mention for completeness).** Patterns 1 and 2 above are config-only solutions: they require no Java, no plugin build, no Trino restart for tenant adds. The **third** option is to **build a custom Trino plugin that implements `Authenticator` (or `HeaderAuthenticator`) from the Trino SPI**, parses the raw JWT yourself, extracts whichever custom claim you want (`tenant_id`, `department`, `clearance_level`), and **encodes it into the `Identity` object's principal name or its associated metadata** that gets passed to the access-control plugin. This is the only OSS Trino 467 path that lets you propagate a custom JWT claim straight into the identity context OPA sees.
>
> However: this is a **real Java plugin build** — you write Java against the Trino SPI, package it as a JAR, drop it in `plugin/<your-plugin>/` on every coordinator and worker, and own its lifecycle across Trino version upgrades (the SPI is stable but not frozen, and breaking changes do happen between major Trino versions). It is appropriate only for teams that already have **Java platform engineering capacity** and are comfortable maintaining an in-house Trino plugin. For most SaaS teams — including the platform-engineering-light teams this guide targets — **the two simpler patterns (username encoding + OPA data bundle) are strictly preferred** because they require zero Java, zero plugin lifecycle, and zero Trino restarts when tenants change. Reach for the custom SPI plugin only if both Pattern 1 and Pattern 2 are demonstrably insufficient for your tenant-identity model (extremely rare; in practice they cover essentially every multi-tenant SaaS shape we have seen).
>
> **What you still need to get right in JWT issuance** — even though OPA doesn't read JWT claims, the JWT-to-Trino-username mapping is the place tenant identity enters the system. Your auth service must mint JWTs whose `sub` (or the claim Trino is configured to read for principal) deterministically encodes the tenant per Pattern 1 OR matches a Pattern 2 bundle entry. If two tenants' users can ever share the same Trino username, OPA cannot distinguish them and per-tenant isolation is broken at the identity layer — long before any Rego rule runs.

**Row-filter mode vs allow/deny mode — when each one wins.**

| Mode | What OPA returns | What Trino does | When to use |
|---|---|---|---|
| **Allow/deny** | `{"allow": true}` or `{"allow": false}` | Lets the query proceed unchanged, or rejects with `Access Denied` | Block tenants from `system` catalog, deny base-table access entirely, gate admin-only tables |
| **Row filter** | `{"rowFilters": [{"expression": "tenant_id = 'acme'"}]}` | Appends the expression as a `WHERE` predicate before execution | Multi-tenant fact tables where every tenant queries the same physical table and you want OPA to enforce the per-tenant filter automatically |

The two modes **compose**, and you usually want both in the same policy:
- Allow/deny first guards what tables a tenant can mention at all (denies `system`, denies `$`-suffix metadata tables, denies cross-tenant admin views).
- Row filters then constrain what rows the tenant sees from the tables they ARE allowed to touch.

**Why this is sometimes preferable to the per-tenant view pattern.** The view pattern (CREATE VIEW tenant_acme.events AS SELECT ... WHERE tenant_id = 'acme') requires you to provision one view and one role per tenant; onboarding tenant #81 means another `CREATE VIEW` + `GRANT`. With OPA row filters, you have ONE table (`analytics.events`) and ONE OPA rule that injects the right predicate based on the caller — adding tenant #81 is a row in your principal-to-tenant mapping, not a SQL DDL change. At hundreds of tenants this is materially less work. The cost is that the security boundary now lives entirely in OPA policy (which must be tested as carefully as any view, with CI assertions that each tenant principal can only see their own rows). See the per-tenant view tradeoff discussion above — row filters are essentially the "dynamic `current_user` view" pattern reimplemented at the policy layer, with the same blast-radius caveat: a bug in the OPA principal-to-tenant mapping breaks isolation for everyone simultaneously.

> **Concrete threshold — at what tenant count should you migrate from per-tenant views to OPA row filters?**
>
> | Tenant count | Recommended pattern | Why |
> |---|---|---|
> | **1–50** | Per-tenant views | Trivial to provision and audit; one-at-a-time blast radius. The view DDL fits in a Terraform module or a 50-line provisioning script. |
> | **50–200** | Per-tenant views, still works | Onboarding still tractable (one `CREATE VIEW` + `GRANT ROLE` per tenant). Hive Metastore catalog listings start to feel slow but are still acceptable. Most production SaaS deployments live in this band — including the 80-tenant prod stack this guide targets. |
> | **200+** | **Migrate to OPA row filters** | The per-tenant view layout becomes operationally painful: every base-table schema change triggers a `SHOW CREATE VIEW` audit across 200+ views, the catalog listing in `SHOW TABLES` returns hundreds of tenant schemas (slowing every catalog-aware client), and onboarding scripts become a meaningful percentage of total deploy time. OPA row filters collapse all of this into one table + one Rego rule + one entry per tenant in the principal-to-tenant mapping. |
> | **1000+** | OPA row filters, almost certainly | Per-tenant views become a planner bottleneck on every schema change. OPA row filter is the standard pattern at this scale. |
>
> The 200-tenant threshold is a rule of thumb, not a hard line — if your tenant churn is high (50+ tenant adds/removals per week), you may want OPA row filters earlier; if your tenant count is stable and growing slowly, per-tenant views can stretch further. The migration is non-trivial (you must rewrite the policy, get CI passing for every tenant under the new model, and run both patterns in parallel during cutover) — plan for it before you cross the threshold, don't react after.

**Verification recipe.** As a tenant principal, run `SELECT DISTINCT tenant_id FROM analytics.events` — it must return exactly one row (their own tenant). As an admin principal (whose OPA policy carves out the row-filter rule), the same query must return all tenant IDs. Add both as CI tests. If a tenant principal ever sees more than one `tenant_id`, the row-filter Rego is misconfigured — treat as a P0 cross-tenant data leak.

### OPA column-masking mode — per-caller column rewriting

OPA's column-masking mode is the column-level analog of row-filter mode: instead of returning a `WHERE` predicate, OPA returns a **SQL expression that Trino substitutes for the column** at query analysis time. Use it to hide PII (email, phone, SSN) from analysts who should see aggregated activity but never the raw identifier.

> **Where the masking actually happens — and what it does NOT prevent.** OPA column masking applies at **query analysis time inside Trino** (specifically the `StatementAnalyzer` phase, before the query plan is finalized). The OPA-provided SQL expression is substituted for the column reference in the query plan, so when the plan executes, it computes the masked expression rather than emitting the raw column. **What this means for the data path:** Trino workers still read the **raw bytes** of the underlying Parquet files from MinIO into worker memory — the masking does NOT prevent MinIO reads, and the raw values are momentarily present in worker process memory before the masking expression is evaluated. The mask only guarantees that the value **returned to the calling client** is the masked one, not the raw one. If your threat model requires that the raw bytes never enter the query engine at all (e.g., the Trino worker pods themselves are untrusted), column masking is the wrong tool — you need encryption-at-rest with per-tenant keys or physically separate tables, not a Trino-side mask. For the common case where the worker pods are trusted and the goal is "the analyst running the SELECT must not see the raw email," masking is exactly right.

**Wiring it up.** Column masking is configured via its own Trino OPA plugin property, analogous to the row-filter one:

```properties
# etc/access-control.properties on the Trino coordinator
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask

# For tables with many columns, use the batch endpoint to avoid per-column HTTP round-trips:
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask
```

> **Use the batch endpoint on wide tables.** The single-column endpoint (`column-masking-uri`) makes **one HTTP call per column per query** — on a 40-column user table, that is 40 sequential OPA round-trips before the query can even start planning, which becomes a measurable per-query latency tax on a busy cluster. The batch endpoint (`batch-column-masking-uri`) sends every column for a given table in **one request** and OPA returns the full masking decision for all of them at once.
>
> **How the two URIs interact — `batch-column-masking-uri` COMPLEMENTS (does NOT replace) `column-masking-uri`.** Like the broader `opa.policy.batched-uri` / `opa.policy.uri` pairing, the column-masking pair is **additive**: `column-masking-uri` remains the always-available baseline, and `batch-column-masking-uri` is the **opt-in performance optimization** for tables with many columns. When `batch-column-masking-uri` is configured, Trino prefers it for per-table column-masking calls; when it is not configured, Trino falls back to one call per column to `column-masking-uri`. Both URIs should be configured in production. **Correct deployment pattern**: implement the batch handler in your Rego policy AND keep the single-column handler available; configure both URIs. The batch handler in Rego is a small wrapper around the per-column rule (it iterates the input column list using `some i ... input.action.filterResources[i]` — the same `filterResources` family pattern as the broader batched-uri — and emits an array of `{index, viewExpression}` entries), so the migration is mechanical.

**Rego response shape — DIFFERENT for single-column vs. batch endpoints.**

> **ANTI-PATTERN WARNING — the single-column and batch endpoints return DIFFERENT JSON shapes.** Using the single-column shape in a batch Rego rule (or vice versa) produces a policy-eval error or silently returns no mask.

- **Single-column endpoint** (`column-masking-uri`): OPA returns one object per HTTP call:
  ```json
  {"expression": "to_hex(sha256(to_utf8(email)))"}
  ```

- **Batch endpoint** (`batch-column-masking-uri`): OPA receives all columns in one request and must return an array, one entry per input column, in this shape:
  ```json
  [
    {"index": 0, "viewExpression": {"expression": "to_hex(sha256(to_utf8(email)))"}},
    {"index": 1, "viewExpression": {"expression": "'****'"}}
  ]
  ```
  Note: the outer key is `viewExpression`, NOT `expression`. A Rego rule that returns `{"expression": "..."}` at the batch endpoint fails.

When the analyst runs `SELECT email FROM analytics.users`, Trino rewrites it to (for the hash-mask case) `SELECT to_hex(sha256(to_utf8(email))) AS email FROM analytics.users`.

> **What OPA actually receives — `{user, groups}`, NOT the full JWT or custom claims.** Trino sends OPA only the resolved `{user, groups}` identity payload for policy evaluation — **not** the raw JWT token, **not** any custom claims the JWT may carry (tenant ID, department, employee level, security clearance, etc.). Concretely:
> - The `user` field contains the JWT `sub` claim (or the principal name resolved by whichever authenticator processed the request — `sub` for JWT auth, the LDAP username for LDAP, etc.).
> - The `groups` field is populated by a **separately configured group provider**, NOT by the JWT authenticator. **OSS Trino 467's JWT authenticator extracts the username only — it does NOT pull groups from any JWT claim.** Properties like `http-server.authentication.jwt.groups-field` **do NOT exist** in OSS Trino 467 (this is a frequently-invented config property; copying it from a blog post will cause a startup config error OR be silently ignored, depending on Trino's strict-properties mode). Group membership is supplied by one of the **group providers** configured in `etc/group-provider.properties`:
>   - **File-based group provider** (`group-provider.name=file`, with `file.group-file=etc/groups.txt`) — flat file mapping usernames to groups.
>   - **LDAP group provider** (`group-provider.name=ldap`) — queries an LDAP directory for the user's group memberships.
>   - **Custom group provider** — a plugin you build against Trino's GroupProvider SPI.
>   If NO group provider is configured, `input.context.identity.groups` is the **empty list** for every user — OPA policies that check group membership will deny (or allow, depending on rule shape) for everyone, often "failing open" if the rule checks for membership in an exclusion list. The "JWT carries a `groups` claim → Trino forwards it to OPA" path is **NOT supported natively in OSS Trino 467** (the relevant feature request is GitHub issue trinodb/trino #28571, unmerged as of Trino 467).
> - **Rego rules that try to look at `input.token.claims.tenant_id` or any other custom JWT claim will silently fail** — those claims never reach OPA. The decision context OPA has is exactly `{user, groups}` plus the resource being accessed (catalog, schema, table, column).
>
> If role-based masking depends on something other than user identity (e.g., "users with security clearance Level 3+ see unmasked SSN"), the supported path on OSS Trino 467 is: (a) configure a group provider (file-based for small static rosters, LDAP for IdP-backed memberships), (b) ensure the user's directory entry has the `security-level-3` group membership, (c) write the Rego rule against `"security-level-3" in input.context.identity.groups`. Do NOT try to thread extra claims through the JWT into OPA via a `groups-field` property — that property and that path do not exist on this stack. If you genuinely need JWT-derived groups, the workarounds are (a) write a custom group provider plugin that parses the JWT from request context, or (b) wait for the upstream PR. Both are heavy lifts; in practice, mirror the group data into LDAP or a file-based group provider and read it from there.

**Critical gotcha — constant masks collapse GROUP BY and JOIN.** Masking a column to a literal like `'****'` makes **every row's masked value identical**. Any `GROUP BY email` then collapses to a single group, and any `JOIN ... ON a.email = b.email` becomes a full cartesian product — all rows appear to have the same value. If downstream queries group or join on the masked column, use a **deterministic hash** instead — `to_hex(sha256(to_utf8(email)))` preserves equality (same input → same hash) so grouping and joining still work, while the underlying PII never leaves the engine.

### The broader batch endpoint: `opa.policy.batched-uri` — COMPLEMENTS (does NOT replace) the single-call `uri`

> **CRITICAL — `opa.policy.batched-uri` is OPT-IN and ADDITIVE. It does NOT override or replace `opa.policy.uri`.** Both URIs must be configured. The two endpoints serve **different categories of operations**, not "batch vs. single mode of the same operation set."

**What each endpoint actually covers.** Per the Trino OPA plugin docs:

- **`opa.policy.uri`** (REQUIRED, always-on baseline) — handles **single-resource operations**. These have one subject and get one OPA call regardless of whether a batched URI is configured. Examples: `CreateTable`, `DropTable`, `DeleteFromTable`, `ExecuteQuery`, `AccessCatalog`, individual `SelectFromColumns` on a single table, `CreateSchema`, `RenameTable`, `SetTableProperties`, etc. There is no `filterResources` array for these — the resource is singular.

- **`opa.policy.batched-uri`** (OPTIONAL, additive, filter-list ops only) — handles **filter-list operations** where Trino has N candidate resources and asks OPA "which of these may the user see?" Examples: `FilterCatalogs`, `FilterSchemas`, `FilterTables`, `FilterColumns`, `FilterViews`. If `opa.policy.batched-uri` is **not** configured, Trino falls back to sending **one request to `opa.policy.uri` for each candidate object** in the filter list. If it **is** configured, Trino collapses those N per-object calls into **one HTTP request** that carries all N candidates in an `action.filterResources` array.

**What "batching" actually collapses.** Batching collapses **N candidate resources WITHIN A SINGLE filter operation** into one HTTP call. It does NOT collapse N separate filter operations into one HTTP call, and it does NOT touch the single-resource operations at all.

- Example that batches: `FilterTables` on a schema with 50 visible tables. Without batched-uri: 50 calls to `opa.policy.uri` (one per table). With batched-uri: 1 call to `opa.policy.batched-uri` containing all 50 tables in `action.filterResources`; OPA returns the indices of the visible subset.
- Example that does NOT batch: a query that does `CREATE TABLE`, then `DELETE FROM`, then `SELECT` from a single table. These are three single-resource operations and each gets its own call to `opa.policy.uri`, regardless of `batched-uri` configuration.

**Configuration — both URIs configured:**
```properties
# etc/access-control.properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow                             # REQUIRED — single-resource ops (always called)
opa.policy.batched-uri=http://opa:8181/v1/data/trino/batchAllow                # OPTIONAL — additive, filter-list ops only
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters            # row filters
opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask         # per-column masking
opa.policy.batch-column-masking-uri=http://opa:8181/v1/data/trino/batchColumnMask  # per-table batch masking
```

**The `opa.policy.uri` is mandatory; `opa.policy.batched-uri` is optional.** If `batched-uri` is not configured, Trino falls back to one OPA call per candidate object in filter operations — there is no "queries fail at analysis if batch handler missing" behavior, because the single-call endpoint is the always-present baseline. The `batched-uri` is purely a performance optimization for the filter-list family of operations.

#### Batched-uri input shape — `action.filterResources`

When Trino calls `opa.policy.batched-uri`, it sends a request that contains an `action.filterResources` array — one entry per candidate resource:

```json
{
  "action": {
    "operation": "FilterTables",
    "filterResources": [
      {"table": {"catalogName": "iceberg", "schemaName": "analytics", "tableName": "events"}},
      {"table": {"catalogName": "iceberg", "schemaName": "analytics", "tableName": "audit_log"}},
      {"table": {"catalogName": "app_pg",  "schemaName": "public",    "tableName": "tenants"}}
    ]
  },
  "context": {
    "identity": {"user": "acme--alice", "groups": []}
  }
}
```

The operation field (`FilterTables`, `FilterSchemas`, `FilterColumns`, `FilterCatalogs`, `FilterViews`) tells the Rego policy which resource shape to expect inside each `filterResources` entry (`table`, `schema`, `column`, `catalog`, etc.).

#### Batched-uri output shape — the indices-return contract

OPA must return an array of **zero-based indices** of the candidate resources the user is allowed to see. The indices reference positions in the `filterResources` array Trino sent in the request:

```json
{"result": [0, 2]}
```

For the three-table example above, returning `[0, 2]` means the user can see resource at index 0 (`events`) and index 2 (`tenants`), but NOT index 1 (`audit_log`). Indices not in the returned array are filtered out by Trino — they will not appear in `SHOW TABLES`, will not be selectable, and will not show up in `information_schema.tables`.

> **Empty array vs. omitted array.** Returning `{"result": []}` means "user can see none of these." Returning `{"result": [0, 1, 2]}` means "user can see all three." A missing `result` field or a non-array value is a policy-evaluation error and the request fails closed (user sees nothing).

#### Minimal correct Rego batch handler

Here is a minimal `FilterTables` handler that returns the indices of tables in the user's tenant schema (parsed from a `tenant--username` principal convention) plus any tables in a `shared` schema. The key idiom is the `some i` quantifier indexing into `input.action.filterResources`:

```rego
package trino

import future.keywords.contains
import future.keywords.if

# Trino calls this rule via opa.policy.batched-uri.
# Returns the set of indices into input.action.filterResources
# that the caller is permitted to see.

batch contains i if {
    some i
    resource := input.action.filterResources[i]
    tenant := split(input.context.identity.user, "--")[0]
    # Allow if the table is in the user's tenant schema
    resource.table.schemaName == tenant
}

batch contains i if {
    some i
    resource := input.action.filterResources[i]
    # Also allow tables in the shared schema for all tenants
    resource.table.schemaName == "shared"
}
```

> **The `import future.keywords.contains` (and `import future.keywords.if`) at the top of the Rego file are REQUIRED for the `contains` / `if` keywords used in `batch contains i if { ... }`.** On OPA 0.50+ these keywords are stable but still gated behind the `future.keywords` import unless you have set `rego.v1` in your bundle (Rego v1 makes them default-available). If you omit the imports and OPA is running on the legacy Rego v0 dialect, the policy will fail to compile with `rego_parse_error: var contains is not allowed` (or a similar shape). Always include the imports unless your entire bundle is `rego.v1`. This is one of the most common "my batch handler doesn't work" gotchas — the rule looks right but the parser rejects it before evaluation.

For a user `acme--alice` and the three-table request above, `batch` would evaluate to the set `{0, 2}` (events is in `analytics` schema — denied; audit_log same — denied; tenants is in `public` — denied unless one of the rules above matches; in the corrected example, replace the schema check with whatever your tenant→schema mapping is). The Trino OPA plugin serializes the `batch` set as the `result` array OPA returns.

#### Parallel structure: `opa.policy.batch-column-masking-uri`

`opa.policy.batch-column-masking-uri` follows the **same `filterResources`-based family pattern** as `opa.policy.batched-uri`:

- **Same input shape**: a `filterResources`-style array, but each entry is a **column candidate** (`{"column": {"catalogName": ..., "schemaName": ..., "tableName": ..., "columnName": ...}}`) instead of a table.
- **Same indices-return contract**: OPA returns an array of entries keyed by `index` (matching the position in the request) plus the mask expression for that column (see the batch column masking response shape earlier in this file — `[{"index": 0, "viewExpression": {"expression": "..."}}, ...]`).
- **Same complement-not-replace relationship**: `opa.policy.column-masking-uri` (the per-column endpoint) and `opa.policy.batch-column-masking-uri` (the batch endpoint) are both configured; the batch endpoint is the additive optimization for tables with many columns.

The Rego patterns you write for one transfer directly to the other — index into `input.action.filterResources`, evaluate per-resource rules, return the matching indices (or, for masking, return the index plus the per-column mask expression).

#### Summary — what changed vs. earlier (wrong) framing

If you have read older drafts of this guide or other blog posts that claim `opa.policy.batched-uri` **overrides** or **replaces** the single-call `opa.policy.uri`, or that queries **fail at analysis** if the batch handler is missing, those claims are **wrong** — they invert the actual behavior. The correct framing per the official Trino OPA plugin docs:

1. `opa.policy.uri` is always required and always called for single-resource operations.
2. `opa.policy.batched-uri` is opt-in and only handles filter-list operations.
3. Without `batched-uri`, filter operations fall back to one call per candidate to the single-call URI — they do not fail.
4. Batching collapses N candidates within one filter operation into one HTTP call; it does not collapse separate filter operations into one call.

> **Upstream work in flight — batch chunking on the Trino OPA plugin side.** Today the Trino OPA plugin sends **every** candidate for a given filter operation in a single batched request body — no chunking, no max-size cap. On a `FilterTables` against a schema with many thousands of tables (rare on most clusters but real on data-lake-style namespaces), this can produce a single OPA request with megabytes of JSON payload, which OPA evaluates more slowly than several smaller requests would. Work to add **automatic chunking** (split a large `filterResources` array into N smaller per-request batches) is tracked in **trinodb/trino issue #25748**. As of Trino 467 it is **not** merged — if you hit the giant-payload case in production today, work around it at the Rego policy level (deny early, return empty quickly for known-bad principals) rather than waiting on the chunking change. Check the issue status before any roadmap planning that assumes batch chunking is available.

### OPA pod placement on Kubernetes — sidecar vs. separate service

**Trino and OPA are "very chatty."** For every query, Trino makes multiple HTTP calls to OPA — one per resource access check (the literal SPI operations Trino sends are `SelectFromColumns`, `FilterCatalogs`, `FilterSchemas`, `FilterTables`, `ExecuteQuery`, etc. — these are the exact strings to grep in OPA decision logs), plus row-filter and column-masking calls. On a busy cluster running wide-table queries with column masking, a single query can trigger 20–60+ OPA HTTP round-trips in the analysis phase before planning even starts.

**Trino's official k8s deployment recommendation: run OPA as a sidecar inside the Trino coordinator pod.** The rationale from the Trino docs:

- Sidecar communication is localhost-to-localhost (sub-millisecond per call vs. 1–20ms for pod-to-pod across the cluster network).
- For queries that trigger 40 sequential OPA calls (column masking on a wide table without batch endpoint), the difference is: 40 × 0.1ms = 4ms (sidecar) vs. 40 × 10ms = 400ms (separate service). That is a 400ms analysis-phase tax visible to every dashboard user.
- OPA is stateless between requests — the sidecar pattern is safe (no cross-request state).

**When a separate OPA service is better:**
- Your OPA data bundle is very large (gigabytes) and you need independent OPA pod scaling or memory limits separate from the coordinator.
- You have multiple Trino coordinators and want a shared, independently-scaled OPA cluster (though the latency cost grows with coordinator count).
- Compliance requires an independently auditable, separately-resourced authorization service.

**If you are on the separate-service pattern and want to reduce latency without migrating to sidecar:**
1. Enable `batch-column-masking-uri` first — this cuts masking calls from N-per-column to 1-per-table (far bigger win than pod placement).
2. Enable `batched-uri` for non-masking authorization checks — cuts the remaining per-resource calls.
3. Use Kubernetes pod affinity to schedule OPA pods on the same node as coordinator pods — reduces network latency from 10–20ms (cross-node) to 1–2ms (local node), without the lifecycle coupling of a sidecar.

> **DECISION GUIDE — sidecar vs. separate service:**
> | Your situation | Recommendation |
> |---|---|
> | Single coordinator, already have batch endpoint enabled | Sidecar (Trino-recommended; minimal operational change) |
> | Multiple coordinators, need independent OPA scaling | Separate service + batch endpoint + pod affinity |
> | Not yet using batch endpoint | Enable batch endpoint FIRST; then revisit pod placement |
> | Regulated environment, OPA must be separately audited | Separate service (compliance requirement overrides latency) |

### OPA decision log — the auditable record of every authz decision (NOT durable by default)

> **Every authorization decision OPA makes is loggable — but the log is NOT durable on its own.** Engineers commonly assume "OPA writes a durable decision log" the way a SIEM writes durable events. **It does not.** OPA writes decisions to stdout (when configured) and from there you MUST ship the stream to an external store. Without that shipping, the decision log lives only in the OPA pod's stdout buffer and is lost on pod restart or k8s log rotation.

#### What's in each decision log entry

When you enable `decision_logs.console: true` in the OPA configuration, OPA emits **one structured JSON line per policy evaluation**. Each entry contains:

- **Timestamp** of the evaluation
- **The full input document** — including `input.action` (`SELECT`, `INSERT`, `ExecuteQuery`, etc.), `input.resource` (catalog, schema, table, column), and `input.context.identity` (user + groups — see the prior section for what's IN and what's NOT in this object)
- **Which Rego rules fired** during evaluation and the value each returned
- **The final allow/deny outcome**
- **Latency of the policy evaluation** (the exact key is `metrics.timer_rego_query_eval_ns` — see the field reference table immediately below)

##### Decision log field reference — exact JSON paths

When you build dashboards or alerts on top of the OPA decision log (in OpenSearch / Loki / Kibana / Grafana), reference fields by their **exact JSON path** in each decision-log line. The Trino OPA plugin nests input under `input.action.*` and `input.context.*`; OPA itself adds `decision_id` and `metrics.*` at the top level of each entry.

| Field | JSON path | Example value |
|---|---|---|
| Operation | `input.action.operation` | `"CreateCatalog"`, `"SelectFromColumns"` |
| Catalog being accessed | `input.action.resource.catalog.name` | `"app_pg"` |
| User (Trino principal) | `input.context.identity.user` | `"analyst-alice"` |
| Groups | `input.context.identity.groups` | `["engineers"]` |
| Query ID | `input.context.queryId` | `"20260526_120000_00001_xxxxx"` |
| Allow / deny | `result.allow` | `true` or `false` |
| Decision trace ID | `decision_id` | UUID string |
| Policy eval time (ns) | `metrics.timer_rego_query_eval_ns` | integer (nanoseconds) |

> **Note on the eval-time field name.** This guide and older notes sometimes use `metrics.eval_ns` as a **shorthand** for the policy evaluation latency. The **actual key name written into the JSON record by OPA** is `metrics.timer_rego_query_eval_ns`. When you write a Kibana DSL filter, a Loki LogQL query, or a Grafana alert rule against the decision log, use `metrics.timer_rego_query_eval_ns` — `metrics.eval_ns` will not match. The shorthand exists only because the full name is long; the actual field reference must be the full name.

##### OPA operation names — audit-relevant subset

The Trino OPA plugin sends a fixed set of operation strings in `input.action.operation`. The full set in Trino 467 is around 60 operation names (the complete list is in `OpaAccessControl.java` in the Trino source); the table below is the **audit-relevant subset** — the operations you actually filter on in security dashboards. For "did anyone change a catalog?" or "who SELECTed from this table?" alerts, these eight are the ones to know:

| `input.action.operation` | What the user did in Trino |
|---|---|
| `CreateCatalog` | User ran `CREATE CATALOG` (dynamic catalog mode only) |
| `DropCatalog` | User ran `DROP CATALOG` |
| `AccessCatalog` | User's query touched a catalog (lightweight pre-check before any per-object check) |
| `SelectFromColumns` | User selected specific columns from a table |
| `FilterCatalogs` | The query planner asked OPA "which catalogs is this user allowed to see?" (drives `SHOW CATALOGS` and metadata listing) |
| `InsertIntoTable` | User ran `INSERT INTO` on a connector table |
| `ExecuteQuery` | Query execution started (one entry per query — useful as a join key against the event listener) |
| `ImpersonateUser` | User tried to impersonate another identity (e.g., via `SET SESSION AUTHORIZATION`) — high-signal for audit |

Operations NOT in this subset (e.g., `ShowSchemas`, `ShowTables`, `CreateView`, `DropView`, etc.) still produce decision-log entries — you can filter on them when you need to — but the eight above are the ones that matter most for routine security dashboards.

#### Wiring it up — enable AND ship

The OPA configuration is two parts: turn on logging, then make it durable.

```yaml
# In OPA's config.yaml (or Helm chart values):
decision_logs:
  console: true          # writes one JSON record per evaluation to OPA's stdout
  # AND/OR push to a remote sink for durability:
  service: backend
services:
  backend:
    url: https://opa-decisions.observability.svc.cluster.local/ingest
```

Then deploy one of the following shippers to persist the stream:

- **Fluent Bit / Fluentd / Vector sidecar** tailing the OPA container's stdout → ship to **OpenSearch** (queryable via Kibana) or **Loki** (search via Grafana). Most common pattern on on-prem k8s.
- **OPA's remote `decision_logs.service` sink** → POST to your own collector (or a SIEM that ingests OPA decisions natively).
- **ELK pipeline** (Filebeat → Logstash → Elasticsearch) for shops already running it.

**Do not describe the OPA decision log as "durable" without the caveat.** "OPA logs every decision" is true. "The decision log is durable by default" is FALSE. The accurate framing: *the OPA decision log captures every authz decision; durability comes from the shipper + retention policy of the downstream store. On this stack, that means Vector → OpenSearch (or equivalent); without that pipeline, the decisions live only in the OPA pod's stdout and disappear on restart.*

#### What the OPA decision log answers vs. what the Trino event log answers

The two log streams are **complementary, not redundant**. They answer different questions:

- **OPA decision log** answers: **"WHO tried to access WHAT (catalog/schema/table/column) and was it ALLOWED?"** — the authorization decision, the input identity, allow/deny, which rule fired.
- **Trino query event log** (Trino event listener; see resource 22 section 8.4D) answers: **"WHAT SQL ran and HOW EXPENSIVE was it?"** — full query text, wall-clock time, bytes scanned, errors, peak memory.

A complete audit trail for "who ran this expensive query at 2 AM and was it authorized" needs BOTH. An access review ("which users queried `app_pg` over the last 7 days?") is answerable from the OPA decision log alone — provided the durability wiring is in place.

#### Decision logs for batch calls (`opa.policy.batched-uri`) — what each entry contains

When `opa.policy.batched-uri` is enabled (see the "Broader batch endpoint" section earlier in this file), each filter-list call to OPA produces **one decision log entry** — not one entry per candidate resource. For example, `FilterTables` on a schema with 50 visible tables emits a single batched HTTP call to OPA, which writes a single decision log line. That line contains BOTH the full `action.filterResources` array (all 50 candidates Trino sent in) AND the `result` (the indices OPA returned for the permitted subset).

This is **highly useful for auditing**: when a customer support engineer asks "why did `SHOW TABLES` return only 3 of 50 tables for tenant-acme's user?", you can answer the question without re-running the query — pull the decision log entry for that `queryId`, and you have the full candidate set, the returned indices, and the rule firing trace in one record.

```json
// One OPA decision log entry for a single FilterTables batched call:
{
  "decision_id": "ab12cd34-...",
  "input": {
    "action": {
      "operation": "FilterTables",
      "filterResources": [
        {"table": {"catalogName": "iceberg", "schemaName": "analytics", "tableName": "events"}},
        {"table": {"catalogName": "iceberg", "schemaName": "analytics", "tableName": "orders"}},
        {"table": {"catalogName": "iceberg", "schemaName": "analytics", "tableName": "internal_audit"}}
        // ... 47 more table candidates ...
      ]
    },
    "context": {
      "identity": {"user": "acme--alice", "groups": ["tenant-acme"]},
      "queryId": "20260526_120000_00001_xxxxx"
    }
  },
  "result": [0, 1],                          // OPA returned: only indices 0 and 1 (events, orders) are visible
  "metrics": {"timer_rego_query_eval_ns": 2400000}
}
```

Without batched-uri configured, the same `FilterTables` operation produces **50 separate decision log entries** (one per candidate to `opa.policy.uri`), each carrying a single `resource.table.*` — same audit information, just denormalized across many lines. Both forms are valid for forensics; the batched form is easier to grep and quicker to reconstruct the "why was this list filtered down" story.

#### Three-way cross-reference for forensics — Trino event listener + OPA decision log + `pg_stat_activity`

When a customer reports "my query returned the wrong data" or "data is missing from this result," the complete observability path requires **all three** of the following — from query submission through authorization through actual source-database execution:

1. **Trino event listener `queryCompleted` event** (see resource 22 section 8.4D for full schema, and the "HTTP event listener" section later in this file for the wiring). For an OPA-denied query, the event's `errorCode.name = "PERMISSION_DENIED"` and `errorCode.type = "USER_ERROR"`. For a successful query the `errorCode` field is absent. This event also carries `queryId`, full query text, the principal, wall-clock time, and bytes scanned — your starting point for every forensic investigation.
2. **OPA decision log entries for the analysis-phase calls** of that `queryId` (the join key is `input.context.queryId` in OPA, matched against `metadata.queryId` in the Trino event listener payload). These tell you exactly which catalogs, schemas, tables, and columns OPA was asked about during planning, and which were filtered out — including the batched-call records described above.
3. **Postgres `pg_stat_activity` snapshot** (for federated queries hitting the Postgres connector — see resource 22's pushdown verification sections). This is the verbatim SQL Trino's JDBC connector sent to Postgres, captured server-side. It tells you whether predicate pushdown actually carried the filter to Postgres, or whether Trino fetched the table unfiltered.

The forensic workflow when a customer reports missing data: (1) start at the Trino event listener `queryCompleted` for the failing query (look up by `queryId` or by `user` + time range), (2) pull the OPA decision log entries for that same `queryId` to see what authz filtered out at analysis time, (3) pull the `pg_stat_activity` capture (or Postgres slow-query log entry) for the actual SQL the federated source received. Together these three give you the **complete observability story from query submission through authorization through execution** — and they let you definitively answer "did OPA hide rows from this user?" vs. "did Postgres receive the wrong predicate?" without guesswork.

#### Dashboards worth building

Once the OPA decision log lands in OpenSearch/Loki, the high-value dashboards are:

- **Deny events on sensitive catalogs** — filter `decision = deny` AND `input.resource.catalog IN (app_pg, billing, ...)`. **Any deny event is either a misconfiguration (legitimate user blocked) or a security incident (someone probing).** Alert on either case — both deserve a human look within the hour. This is the single most important OPA decision-log alert to set up.
- **Policy evaluation latency p50/p95/p99** — track `metrics.timer_rego_query_eval_ns` (this is the exact JSON key — `metrics.eval_ns` is shorthand and will not match in your log store; see the field reference table above). If p95 climbs above ~50 ms on a busy cluster, query planning slows down for everyone; investigate which rule got expensive.
- **Catalog access patterns by user / group** — last 7 days of accesses by `input.context.identity.user`, grouped by catalog. Useful for monthly access reviews and for spotting users who suddenly start accessing catalogs they never touched before.
- **Rule firing frequency** — which Rego rules fire most often? Candidates for optimization or for caching their inputs in OPA's data bundle.

### Two service accounts, one strict rule

A subtle leak path that resource-1-style isolation alone won't catch: **the ingestion path and the query path must use separate identities.** It's tempting to give Spark and Trino the same metastore/catalog credentials because "it's all internal" — don't. The blast radius if either side is compromised, or if a coding mistake reuses the wrong credential, is the entire dataset.

The strict rule: **the backend write account (Spark ingestion) and the analytics read account (Trino queries) must be separate Kubernetes ServiceAccounts mapped to separate Trino principals.** Concretely:

| Account | Kubernetes ServiceAccount | Trino principal | Grants on base tables (`analytics.events`) | Grants on per-tenant views (`tenant_acme.events`, ...) |
|---|---|---|---|---|
| **Ingestion (Spark)** | `spark-ingest-sa` | `spark-ingest` | `INSERT`, `DELETE` (or `MERGE` for upserts). **No `SELECT`.** | None. |
| **Analytics (Trino end users)** | `trino-query-sa` | `trino-query` (or per-tenant role: `acme_role`, `beta_role`, ...) | None — no direct base-table access. | `SELECT` on the matching tenant's view only. |

Why this matters concretely:

- **A bug in the ingestion job cannot exfiltrate data.** If `spark-ingest` has no `SELECT` privilege on the base tables, a misbehaving Spark job can't accidentally `SELECT *` and dump tenant data into a log file, a debug bucket, or a sidecar service.
- **A bug in the analytics query path cannot mutate data.** If `trino-query` has no `INSERT`/`DELETE`, a vulnerable BI tool or a SQL injection in a dashboard can never corrupt or wipe tables.
- **Per-tenant role isolation continues to work cleanly.** Customer A's user holds `acme_role` (which extends `trino-query`'s read-only base permissions), so even if the application layer is misconfigured, Trino still rejects any attempt to query another tenant's view.

**How a pod identity becomes a Trino principal** (this is the missing link engineers often skip): in Kubernetes, each pod runs under a ServiceAccount. To turn that into a Trino identity:

1. The Spark/Trino client pod authenticates to Trino with either a long-lived password (stored as a k8s Secret bound to that ServiceAccount) or — preferred — a short-lived JWT issued by your in-cluster identity provider (e.g., the k8s ServiceAccount token projected into the pod, validated by Trino's JWT authenticator).
2. Trino's `password-authenticator.properties` or `http-server.authentication.type=JWT` maps the credential to a Trino principal (`spark-ingest`, `trino-query`, etc.).
3. The principal is looked up by the system access control plugin (file-based rules or OPA) to determine grants.

> **You do NOT maintain 80 separate JDBC connection pools — one per tenant — to do this.** A frequent misconception when engineers first hear "per-tenant Trino principal" is that the backend service must open and pool a brand-new JDBC connection per customer (with a different credential each time), which doesn't scale past a handful of tenants. **That is not how the production pattern works.** A single backend service holds **one** JDBC/HTTP connection pool to Trino and presents per-tenant identity **on each individual request** via one of two mechanisms:
>
> - **HTTP `X-Trino-User` header (impersonation).** The backend authenticates to Trino once as a privileged service principal (e.g., `backend-app-svc`) and then sets `X-Trino-User: acme-service-account` on every outgoing query header. Trino uses the header value as the effective principal for that query — OPA, resource groups, and view-grant checks all see `acme-service-account`, not `backend-app-svc`. The connection pool is unchanged; only the per-request header rotates. Requires the privileged service principal to have **impersonation rights** on the tenant principals it is allowed to claim — configured in OPA policy (or, on file-based ACL, via `impersonation` rules). Without those rights, Trino rejects the impersonation attempt with `Access Denied: User <backend-app-svc> cannot impersonate user <acme-service-account>`.
> - **JWT `sub` claim — issue a new JWT per request.** The backend mints a short-lived JWT whose `sub` claim is the calling tenant's principal (e.g., `sub: "acme--svc"` if you use Pattern 1 username encoding, or `sub: "acme-svc"` if you use a Pattern 2 OPA bundle mapping) and embeds it in the HTTP `Authorization: Bearer <jwt>` header. Trino's JWT authenticator validates the signature, extracts the `sub`, maps it to a Trino username, and treats it as the principal for the request. Same connection pool, different JWT per request. This pattern is preferred when the backend already mints JWTs for downstream services (zero new infrastructure) and when you want each tenant action to be auditable to a distinct, short-lived token.
>
> Either pattern lets one process handle thousands of tenants over a single (small) connection pool. The choice between them is mostly operational: impersonation is one less moving part if you already have a service-principal credential; per-request JWT is preferred if your auth service is the source of truth for tenant identity and you want every Trino request to carry its own signed, expiring credential. **The wrong mental model — one pool per tenant — is what makes engineers think per-principal isolation can't scale; the right mental model is "one pool, per-request principal switching via header or JWT."**
>
> **One more wrong mental model to correct: "OPA will read the extra claims I stuff in the JWT and use them in policy decisions." It will NOT.** Whatever the JWT carries beyond the principal claim, Trino discards before invoking OPA — OPA receives only the resolved Trino username and the user's groups (see the "What OPA's `input` object actually contains" callout in the row-filter section). If a tenant-aware OPA policy needs more context than the username can carry, put the extra context in OPA's data bundle (Pattern 2 above), not in the JWT.

Audit guardrail: include in the CI test that connects as `spark-ingest` and asserts `SELECT * FROM analytics.events` fails with `Access Denied`. Mirror it with a test that connects as `trino-query` and asserts `INSERT INTO analytics.events VALUES (...)` fails. If either succeeds, the role grants have drifted.

> **Interactive verification — `SHOW GRANTS`.** `SHOW GRANTS ON TABLE analytics.events` and `SHOW GRANTS ON VIEW tenant_acme.events` let you audit the grant state interactively without running test queries. Use these as day-2 verification after provisioning a new tenant: the output lists every (grantee, privilege) pair currently in effect for that object, so you can immediately confirm that `acme_role` has `SELECT` only on the view and no privileges on the base table. Pair with the CI tests above — the CI tests prove the deny-path actually rejects queries, while `SHOW GRANTS` shows the grant state at a glance for human review.

### The `system` catalog leak — tenant service accounts can snoop every other tenant's SQL

This is one of the most under-recognized cross-tenant data leaks in a Trino deployment, and it is **not** blocked by any of the view / role / `analytics` catalog rules above. It must be fixed separately by explicitly denying tenant principals access to the `system` catalog.

> **Glossary (plain-English definitions for this section).** A SaaS engineer new to Trino + OPA encounters several terms here as jargon. Quick definitions to keep handy while reading:
> - **principal** — any authenticated identity that Trino sees: a human user, a service account, or an application. "Tenant principal" = the identity Acme's app uses to log into Trino. Not the same thing as a Trino "role" (a role is a bundle of grants you assign to a principal).
> - **Rego** — OPA's policy language. A Rego file is one you write (and check into git) that declares rules like "deny if the catalog is `system` and the principal is not in the admin list." Trino calls out to OPA, OPA evaluates the Rego rules, and returns allow/deny.
> - **hot-reload** — policy changes take effect immediately, without restarting Trino. With OPA, you push a new Rego bundle and within seconds every subsequent query uses the new policy. (File-based access control does NOT hot-reload — you must restart the Trino coordinator.)
> - **carve-out** — an explicit exception to a deny rule that allows a specific identity through. Example: "deny everyone from the `system` catalog, EXCEPT carve out `admin`, `data-team`, and `spark-ingest`." The carve-out is the allow-list that lives alongside the broader deny rule.
> - **deny-by-default** — the policy's starting position is "no one can do anything," and you add explicit allow rules for the access you want to grant. The opposite (allow-by-default) is Trino's out-of-the-box behavior and is unsafe for multi-tenant.

**The threat.** Trino exposes a built-in `system` catalog (the **Trino system connector**) whose tables surface live cluster state — including `system.runtime.queries`, an in-memory table that lists **every running and recently completed query from every user on the cluster**. The actual columns (verified against the Trino `QuerySystemTable.java` source) are:

- `query` — the **complete SQL text** of the query, verbatim
- `user` — which Trino principal ran it (i.e., which other tenant)
- `source` — the client-supplied source string (e.g., BI tool name)
- `query_id`, `state`, `resource_group_id` — query identity and routing
- `queued_time_ms`, `analysis_time_ms`, `planning_time_ms` — phase timings (in milliseconds)
- `created`, `started`, `last_heartbeat`, `end` — timing metadata (column is named `end`, **not** `end_time`; you must quote it as `"end"` in SQL because it's a Trino reserved word)
- `error_type`, `error_code` — failure classification for `FAILED` queries

The table does **NOT** have: `query_type`, `statistics` (no nested JSON column), `totalBytes`, `elapsedTime`, `bytes_scanned`. These are common invented names — referencing any of them in a SQL query produces a parse-time `Column ... cannot be resolved` error. For per-tenant bytes-scanned figures, use the HTTP event listener audit log path (see "Query audit logging for security auditors" below), not this runtime table.

So when tenant Acme's service account runs `SELECT * FROM system.runtime.queries`, it sees the full SQL text of every query that tenant Beta, tenant Charlie, and every other tenant has just executed — including customer IDs that may be embedded in `WHERE` clauses, schema names that reveal product structure, filter values that may include emails or account identifiers, and the literal query strings that may contain sensitive analytic logic. The data lives in coordinator memory (it is not persisted across coordinator restarts), but for the duration of the coordinator's uptime — typically weeks — the entire query history is visible to anyone with `SELECT` on the `system` catalog. **Default Trino installations grant this access to all authenticated users.**

A related leak vector: `system.runtime.queries` also exposes query text to **same-tenant** users. If a single tenant's data engineer authenticates as `acme-engineer`, they can see every query run by `acme-service-account`, `acme-analyst`, and any other Acme principal. Whether this is acceptable depends on the tenant's internal governance — some customers expect query-text confidentiality even between their own team members; others do not care. **Decide explicitly per-tenant; do not leave it as a default.**

**Fix 1 (illustrative): file-based access control.** The conceptual shape of the fix is a deny rule on the `system` catalog for any principal except internal service accounts. In a file-based `rules.json`, the rule structure is:

```json
{
  "catalogs": [
    {
      "user": "(admin|data-team|spark-ingest|trino-internal)",
      "catalog": "system",
      "allow": "all"
    },
    {
      "catalog": "system",
      "allow": "none"
    },
    {
      "catalog": "(iceberg|hive)",
      "allow": "all"
    }
  ]
}
```

The first rule grants `system` catalog access only to a whitelist of internal principals. The second rule (which acts as the catch-all because rules are evaluated in order) denies `system` to every other principal — including all tenant service accounts. The third rule preserves normal access to the data catalogs.

**Fix 2 (production stack): OPA policy.** The production environment uses OPA as the Trino authorization backend, not file-based rules. The OPA policy must reject any catalog-level access where `catalog = "system"` and the JWT principal is not on the internal-services allow-list (e.g., the JWT subject is not one of `admin`, `data-team`, `spark-ingest`, etc.). The specific Rego policy code lives in the external governance document (see `prod_info.md`) — do not invent it here. What you need to know as an engineer is: **the policy exists, it must be in place, and it must explicitly deny the `system` catalog to tenant principals.**

**Partial mitigation (NOT a substitute).** Trino has a coordinator property `query.client.info-is-sensitive=true` that hides client-supplied metadata (such as the `X-Trino-Client-Info` header) from cross-user views. This property exists and is worth enabling, **but it does NOT hide the `query` text column itself** — tenants can still read every other tenant's SQL. Setting this property and considering the leak "fixed" is a common mistake. The only correct fix is catalog-level denial as described above.

**Verification step.** After applying the OPA policy (or file-based rule), connect as a tenant service account and run:

```sql
-- Should fail with "Access Denied" after the fix is in place.
SELECT count(*) FROM system.runtime.queries;
```

If this query returns a number instead of failing, the policy has not been applied correctly. Also try:

```sql
-- These are other system tables that leak operational data — they must all
-- fail with Access Denied for tenant principals.
SELECT * FROM system.runtime.nodes LIMIT 1;
SELECT * FROM system.runtime.transactions LIMIT 1;
SELECT * FROM system.metadata.table_properties LIMIT 1;
```

A correct catalog-level deny rule blocks **all** tables in the `system` catalog at once — you do not need to enumerate them individually. Add a CI test that authenticates as each tenant role and asserts `SELECT count(*) FROM system.runtime.queries` returns `Access Denied`. If this test ever passes a `count(*)` value, treat it as a P0 cross-tenant data leak.

> **Deployment timing: changes to file-based access control rules (`rules.json`) require a coordinator restart in Trino to take effect.** There is no hot-reload mechanism for the file-based ACL plugin — editing `rules.json` on a running coordinator changes nothing until you bounce the coordinator pod. **OPA-based policies, by contrast, hot-reload when the OPA bundle is updated** — no Trino restart required. The Trino OPA plugin re-queries OPA per request (or per cached interval), so a policy change pushed to OPA's bundle server takes effect within seconds for every subsequent query.
>
> On the production stack (which uses OPA, per `prod_info.md`), this means **system catalog policy changes are instant once the OPA bundle is deployed** — useful both for fast incident response (a tenant is exploiting `system.runtime.queries` right now and you want them blocked in the next 30 seconds) and for routine policy iteration (you want to add a new internal-services principal to the allow-list without a 10-minute coordinator restart window). If you were on file-based rules, the same `rules.json` change would require a coordinator restart and a brief query-rejection window while the pod restarts. This is one of the operational reasons to prefer OPA over file-based ACL on a production multi-tenant cluster.

### Iceberg metadata table leak — `$partitions`, `$files`, and related tables

The `system` catalog is not the only metadata leak path. Iceberg tables expose a set of built-in **metadata tables** accessible by appending a `$`-suffix to the table name. These metadata tables expose structural information about the entire table — independent of any row-level view filter.

**The threat.** If your Iceberg events table is partitioned by `tenant_id`, a tenant service account that can reference `iceberg.analytics."events$partitions"` sees:
- All partition key values — meaning all `tenant_id` values in the system (your complete customer roster)
- `record_count` per partition — reveals each tenant's event volume per day
- `file_count` and `total_size` per partition — reveals each tenant's storage footprint
- `column_sizes`, `null_value_counts` — additional column-level statistics

This is not row-level data (the tenant cannot read other tenants' events), but it is structural intelligence: which customers exist, how active they are, and their relative scale.

**Why view-level isolation does NOT protect metadata tables.** A Trino view's `WHERE tenant_id = 'acme'` filter applies to the data rows returned by the view. It does not apply to queries against `iceberg.analytics."events$partitions"` — that metadata table bypasses the view entirely and queries the table's metadata layer directly. If a tenant principal has any access path to the `iceberg.analytics` schema (even only through a view), they may also be able to reference the metadata tables.

**Complete list of Iceberg metadata tables to deny for tenant principals:**

| Table name | What it exposes |
|---|---|
| `"events$partitions"` | Partition key values (tenant IDs), record counts, file counts, total_size |
| `"events$files"` | Individual file paths (may reveal MinIO path structure), record counts, column min/max |
| `"events$snapshots"` | All snapshots — commit timestamps, operation types, summary stats |
| `"events$history"` | Snapshot lineage and parent-child relationships |
| `"events$manifests"` | Manifest file paths and partition summary stats |
| `"events$all_manifests"` | Same as $manifests but includes all historical manifests |
| `"events$entries"` | Data file entries per manifest |
| `"events$refs"` | Named references (branches, tags) if using Iceberg branching |
| `"events$properties"` | Table-level Iceberg properties — retention settings, format versions |
| `"events$metadata_log_entries"` | Metadata file history |

**The fix: deny all `$`-suffix metadata tables in OPA.** With OPA as the Trino authorization backend (the production stack), add a rule that denies any query from a tenant principal where the table name contains `$`. This covers the entire metadata table surface in a single rule, without enumerating individual table names. The specific Rego code lives in the external governance document (see `prod_info.md`) — do not write Rego here.

**Verification recipe:**
```sql
-- Connect as a tenant service account, run all of these — all should fail with Access Denied
SELECT * FROM iceberg.analytics."events$partitions" LIMIT 1;
SELECT * FROM iceberg.analytics."events$files" LIMIT 1;
SELECT * FROM iceberg.analytics."events$snapshots" LIMIT 1;
```

Add these as CI tests. The base view should still work:
```sql
SELECT COUNT(*) FROM iceberg.tenant_acme.events;  -- should succeed
```

> **Note**: the `$partitions` metadata table is a separate exposure path from the `system.runtime.queries` system catalog leak. Both must be fixed independently — a catalog-level deny on `system` does not protect Iceberg metadata tables in the `iceberg` catalog.

### Iceberg hidden columns — `$path`, `$partition`, `$file_modified_time`

Distinct from the `$`-suffix metadata **tables** above, Trino's Iceberg connector also exposes a set of **hidden columns** on every Iceberg table. These columns do not appear in `DESCRIBE` output or `information_schema.columns` and are not part of the table schema — but they are queryable on any table the user has SELECT on, by referencing them with a `$`-prefixed quoted identifier:

| Hidden column | What it exposes |
|---|---|
| `"$path"` | The full MinIO/S3 object path of the data file each row came from (e.g., `s3a://lakehouse/warehouse/analytics/events/data/...parquet`) — reveals MinIO bucket layout and lets an attacker bypass Trino by downloading the file directly with `mc cp` (same exfil shape as the `$files` metadata table). |
| `"$partition"` | The partition values for each row as a struct — for a `partitioning = ARRAY['tenant_id', 'day(event_ts)']` table, this exposes the `tenant_id` of each row even when the SELECT-list does not include `tenant_id`. Lets an attacker enumerate which `tenant_id` values exist in any row they can read. |
| `"$file_modified_time"` | The modification timestamp of the underlying file. Less sensitive than the other two, but reveals write cadence and may help an attacker correlate Iceberg compaction events with external activity. |

All three can be referenced in any SELECT — for example:

```sql
SELECT "$path", "$partition", "$file_modified_time", event_id
FROM iceberg.tenant_acme.events
LIMIT 10;
```

**Why this is a separate vector from `$files` / `$partitions` tables.** The `$`-suffix tables (`events$files`, `events$partitions`) are **separate table references** — they appear in the FROM clause and are filtered by table-level OPA rules (`SELECT` on `iceberg.analytics."events$files"`). The hidden columns above appear inside an otherwise-normal SELECT on the **base view** (`SELECT "$path" FROM tenant_acme.events`). A table-level deny rule that blocks `events$files` does **NOT** block `"$path"` on the base view — those go through different OPA operations.

**The fix: deny the three hidden columns in OPA via `FilterColumns`.** The OPA Trino plugin issues a `FilterColumns` request when a query references columns; the Rego policy can deny `"$path"`, `"$partition"`, and `"$file_modified_time"` for tenant principals by name. Group all three in a single deny rule — they are always denied together for tenant roles, since exposing any one of them undermines the row-level isolation boundary. The specific Rego code lives in the external governance document; what you must know as an engineer is: **a complete tenant-isolation OPA policy must deny these three hidden columns alongside the `$`-suffix metadata tables and the `system` catalog.**

**Verification recipe — add to CI alongside the metadata-table tests:**

```sql
-- Connect as a tenant service account — all of these MUST fail with Access Denied:
SELECT "$path" FROM iceberg.tenant_acme.events LIMIT 1;
SELECT "$partition" FROM iceberg.tenant_acme.events LIMIT 1;
SELECT "$file_modified_time" FROM iceberg.tenant_acme.events LIMIT 1;
```

### `system.metadata.table_properties` — Iceberg `location` leak via the system catalog

The `system` catalog deny rule from the earlier "system catalog isolation" section covers `system.runtime.*` (the query/transaction/nodes tables) and is the right shape — but it is worth calling out specifically that `system.metadata.table_properties` also belongs on the deny list. For every Iceberg table the principal can see, this view returns the table's full property bag — including the Iceberg **`location`** property, which is the MinIO warehouse path of the table:

```sql
-- For a tenant principal with SELECT on tenant_acme.events:
SELECT property_name, property_value
FROM system.metadata.table_properties
WHERE catalog_name = 'iceberg'
  AND schema_name  = 'analytics'
  AND table_name   = 'events';
-- Returns rows including:
--   ('location', 's3a://lakehouse/warehouse/analytics/events')
--   ('format-version', '2')
--   ...
```

Once a tenant has the `location` value, they have the MinIO path to attempt direct object download — the same exfil pathway as the hidden `"$path"` column and the `$files` metadata table, but reachable through a different surface. The same applies to `system.metadata.materialized_view_properties` (and any other `system.metadata.*` view) — anything that returns a `location`, file path, or storage URI is in scope.

**The fix is the catalog-level `system` deny rule already documented above** — it covers `system.runtime.*` AND `system.metadata.*` in one shot. The reason to call this out explicitly: engineers reviewing a partial OPA policy sometimes see "the deny rule says `system.runtime.queries`" and assume `system.metadata.*` is a separate concern. It is not — both live in the same `system` catalog and are both blocked by a single `catalog = "system"` deny. **Confirm both surfaces are covered when you write or review the OPA rule**, and include `SELECT * FROM system.metadata.table_properties LIMIT 1` in the verification recipe (as already shown in the system catalog section above).

### CTAS / INSERT INTO ... SELECT — the write-side exfiltration surface

The view-as-isolation-boundary pattern stops a tenant from `SELECT`-ing data they shouldn't see. It does **not**, by itself, stop a tenant from **writing** data they CAN see into a table they own — and then exporting the underlying files out of MinIO. This is the **write-side exfiltration surface** and it must be closed independently of the SELECT-side controls.

**The attack shape.** Suppose tenant `acme` has SELECT on `tenant_acme.events` (their filtered view) — exactly as the per-tenant view pattern intends. Acme also has CREATE TABLE privilege somewhere (perhaps in a scratch schema like `iceberg.acme_scratch.*` they were given for their own intermediate tables). Acme runs:

```sql
-- Step 1: create a table they own, in a schema they have CREATE on.
CREATE TABLE iceberg.acme_scratch.exfil AS
SELECT * FROM tenant_acme.events;        -- only their own rows, fine so far
```

So far, nothing is breached — the view returned only Acme's rows. The problem starts when the attacker walks the next step:

```sql
-- Step 2: peek at the file paths via the metadata table.
SELECT file_path FROM iceberg.acme_scratch."exfil$files";
-- Returns something like: s3a://lakehouse/warehouse/acme_scratch/exfil/data/...parquet
```

Now the attacker has a list of MinIO object paths they own. If their MinIO credentials grant them read access to the path prefix where their own scratch table is stored (a common setup when the platform team gives tenants direct MinIO read access for "BYO BI tool" or "export your data as Parquet" workflows — see the ad-hoc export pattern in `prod_info.md`), they can download the Parquet files directly using `mc cp`, `aws s3 cp`, or any S3-compatible client — completely outside Trino. The data leaves the engine and lands on the attacker's laptop. The Trino audit log shows a CTAS and a metadata-table SELECT, both of which look benign in isolation.

**Where the boundary leaks** (and why CTAS specifically is the dangerous verb):

- `CREATE TABLE ... AS SELECT` (CTAS) reads from the view (allowed), writes to a tenant-owned table (allowed if they have CREATE), and produces Parquet files in MinIO that the tenant can download directly. No row-level boundary is crossed inside Trino — the boundary leaks at the storage layer.
- `INSERT INTO ... SELECT` is the same story for an existing tenant-owned table — append rows to a table they own, then export the resulting files.
- `UNLOAD` / `EXPORT` SQL is **not** a Trino feature, but the CTAS-then-download path achieves the same effect via the file system.
- The same path also enables **cross-tenant exfil if the SELECT side ever leaks**: any view bug, any OPA misconfiguration, any row-filter regression that lets Acme see Beta's rows for even a few seconds, is now permanently extractable — Acme CTASes the leaked rows into a table they own, takes their time exporting the files, and the leak is no longer ephemeral.

**The required OPA policy additions.** Closing this surface requires OPA to deny **writes** beyond just denying SELECTs on cross-tenant tables:

1. **Deny `CreateTable`, `InsertIntoTable`, `CreateTableAsSelect` on every schema OUTSIDE the tenant's own scratch schema.** Tenant principals must not be able to CTAS into `iceberg.analytics.*`, `iceberg.public.*`, or any schema that is not explicitly their scratch space. Specifically deny `CreateTableAsSelect` (the operation name in the OPA input payload — distinct from `CreateTable` for empty tables) for any target schema not matching `iceberg.<tenant_id>_scratch.*`.
2. **Deny SELECT against `$files`, `$partitions`, and `$manifests` metadata tables on tenant scratch tables** — not just on the analytics base table. Even if Acme owns the scratch table, exposing the file paths is what makes the MinIO bypass usable. The `$`-suffix metadata-table deny rule from the previous subsection should cover the **entire iceberg catalog**, not just `iceberg.analytics.*`.
3. **Restrict the tenant's MinIO IAM policy** so they cannot read raw Parquet from any path — including their own scratch tables' paths. If tenants need bulk export, run it through a controlled export endpoint (see "Large tenant data export" later in this file) that produces a tenant-isolated CSV / Parquet under a signed URL, rather than giving them direct MinIO read on the warehouse bucket. The principle: Trino is the only path to the data; MinIO is treated as engine-internal storage.
4. **Audit-log every CTAS by tenant principals.** Add an alert: any `CreateTableAsSelect` event in the HTTP event listener whose principal is a tenant role should page if the target schema is not the tenant's own scratch space. Even with OPA denying these, a successful CTAS (the deny rule misfires, or a new tenant is provisioned without OPA coverage) is a P0 finding.

**Verification recipe — add to CI.** Connect as a tenant principal and run:

```sql
-- All of these MUST fail with Access Denied:
CREATE TABLE iceberg.analytics.exfil_attempt AS SELECT * FROM tenant_acme.events;
CREATE TABLE iceberg.public.exfil_attempt    AS SELECT * FROM tenant_acme.events;
INSERT INTO iceberg.analytics.events SELECT * FROM tenant_acme.events;
SELECT file_path FROM iceberg.tenant_acme."events$files";
SELECT file_path FROM iceberg.acme_scratch."exfil$files";  -- even own scratch table
```

If any of these succeed, the write-side surface is open. Combine with the SELECT-side CI tests from earlier sections — both sides must pass before a tenant principal is allowed in production.

> **The simplest hardening: do not give tenant principals CREATE TABLE at all.** If your product does not expose an "let customers materialize their own tables" feature, the cleanest answer is to deny `CreateTable` and `CreateTableAsSelect` globally for tenant principals — no scratch schema, no exceptions. Force every workload through views and the controlled export endpoint. Most SaaS multi-tenant deployments do not need per-tenant CTAS; eliminating it removes this entire class of bug without limiting the customer experience. Reach for the schema-scoped allow-list only if a product feature genuinely requires tenants to land their own derived tables.

### The foot-gun: trusting application-layer WHERE clauses

The single most common multi-tenant data leak in SaaS analytics is: **the app builds queries by string concatenation and forgets the `WHERE tenant_id = ?` once.**

Why this is dangerous on Trino + Iceberg:

- Trino does not know which tenant the caller represents unless you tell it.
- A query without the filter scans every file — so the leak is total, not partial.
- Iceberg tables often hold years of history, so the leak window is huge.

**What to do instead**:

1. Never let the application generate raw SQL against base tables. Always go through a view that has the filter baked in.
2. Run the customer-facing user as a different Trino role than the ingestion user, and only grant the customer role access to views.
3. Add a CI test that tries `SELECT * FROM analytics.events` as the customer role and asserts it fails with a permission error.
4. If you must compose SQL in the app, validate at the gateway: reject any query that doesn't reference the tenant view, or that mentions another tenant's identifier.

---

## Iceberg partition strategy for multi-tenant

How you partition the table affects both query speed and isolation efficiency. (A **partition** here = a grouping Iceberg uses to skip irrelevant files at query time.)

### Option A: Partition by `tenant_id`

```sql
CREATE TABLE analytics.events (...)
WITH (partitioning = ARRAY['tenant_id']);
```

- **Good**: Queries with `WHERE tenant_id = 'acme'` only read Acme's files. Maximum pruning.
- **Good for small fleets**: For tenant counts up to ~50, the identity-partition layout is the cleanest choice — partition count stays small enough that the planner's manifest-list traversal is not a bottleneck.
- **Bad**: If tenants are wildly uneven (one tenant has 100M rows, another has 1K), partitions are skewed. A skewed partition means one Parquet file is huge and another is tiny — both bad. Tiny files cause "small files problem" (many file opens, slow scans); huge files can't be parallelized well.
- **Bad at scale**: For 100+ tenants — and especially when combined with daily/hourly partitioning — the manifest-list grows large enough that the planner's traversal cost dominates query planning time even on per-tenant queries that prune correctly. Switch to `bucket(tenant_id, N)` (Option C below) when tenant count crosses ~100.

### Option B: Partition by `(tenant_id, day(event_ts))` — RECOMMENDED FOR MOST SAAS

```sql
CREATE TABLE analytics.events (...)
WITH (partitioning = ARRAY['tenant_id', 'day(event_ts)']);
```

- **Good**: A query like `WHERE tenant_id = 'acme' AND event_ts >= DATE '2026-05-01'` prunes to just Acme's files for that date range. This is the typical analytics access pattern (per-customer, per-time-window).
- **Good**: Spreads each tenant's data across multiple files by date, so even big tenants get parallelism.
- **Bad**: If you have many small tenants and short retention, you may still produce small files. Compact regularly with `ALTER TABLE ... EXECUTE optimize` from Trino 467 (Trino-native, no Spark hop) or `CALL iceberg.system.rewrite_data_files` from Spark — see the **Compaction — pick the engine that matches your runbook** subsection below.

### Option C: Partition by `(day(event_ts), bucket(tenant_id, N))` — RECOMMENDED FOR 100+ TENANTS

```sql
CREATE TABLE analytics.events (...)
WITH (partitioning = ARRAY['day(event_ts)', 'bucket(tenant_id, 32)']);
```

The identity-`tenant_id` partition layout (Options A and B) works great up to roughly **50 tenants**. Past that, the partition count grows multiplicatively with the date axis and starts to bloat manifest metadata. The Iceberg **manifest list** (Iceberg's top-level metadata index that maps partition ranges to individual manifest files — it is what Trino's query planner reads first on every query to identify which manifests could contain matching data) pre-filters manifests by partition range (each entry carries the partition-value ranges for the files in that manifest, so manifests that cannot contain matching data are skipped without being opened), **but as the manifest count grows the planner must traverse more entries to find the surviving manifests** — and that traversal happens on every query's planning phase, becoming the latency bottleneck.

**Arithmetic of the bloat.** Consider a table with daily partitions over a 90-day rolling window:

| Tenant count | Partition spec | Total partitions | Manifest-list traversal cost |
|---|---|---|---|
| 50 tenants × 90 days | `('day(event_ts)', 'tenant_id')` | 4,500 | Small — manifest list fits in coordinator heap easily; traversal adds tens of ms to planning |
| 100 tenants × 90 days | `('day(event_ts)', 'tenant_id')` | 9,000 | Moderate — manifest-list traversal adds ~100ms to planning |
| 400 tenants × 90 days | `('day(event_ts)', 'tenant_id')` | **36,000** | **Painful — multi-second planning, manifest-list traversal dominates planning time** |
| 400 tenants × 90 days | `('day(event_ts)', 'bucket(tenant_id, 32)')` | 90 × 32 = **2,880** | Small — back to healthy planning latency |

The `bucket(tenant_id, 32)` partition transform hashes `tenant_id` into one of 32 buckets and partitions by the bucket id. Every value of `tenant_id` deterministically maps to exactly one bucket, so **equality predicates still prune perfectly**: `WHERE tenant_id = 'acme'` evaluates Iceberg's `bucket(tenant_id, 32)` transform once on the literal `'acme'`, identifies bucket 17 (or whichever), and reads only the files in bucket 17 — typically ~1/32 of the table's data files, with the unwanted buckets pruned at manifest time. The pruning ratio is the same per-query as identity partitioning; you just trade per-tenant file isolation for a bounded partition count.

**Pick N to bound your partition count.** A reasonable rule of thumb is to choose `N` so that the total partition count (date × bucket) stays under ~10,000 for typical retention windows. For a 90-day window and 400 tenants: 90 days × 32 buckets = 2,880 partitions — comfortable. Common practical values for `N` are 16, 32, 64, or 128; pick the smallest one that keeps your `tenant_count / N` ratio above ~5 (so each bucket holds a healthy number of tenants and partitions don't end up too small).

**Tradeoffs vs identity partitioning:**

| Aspect | Identity `tenant_id` | `bucket(tenant_id, N)` |
|---|---|---|
| Per-tenant query pruning | Perfect — one tenant = one partition slice | Good — one tenant = 1/N of the partitions (still much less than full scan) |
| Cross-tenant query parallelism | Per-tenant file isolation enables per-tenant parallel scan | Per-bucket parallelism still works; bucket holds ~`tenant_count/N` tenants |
| Manifest size at scale | Grows linearly with tenant count | Capped at `N` × date partitions |
| Per-tenant storage report via `$partitions` | Works (`partition.tenant_id` is the original string) | **Does NOT work** — `partition.tenant_id_bucket` is an integer; you cannot recover original tenant_id from the metadata |
| GDPR per-tenant DELETE | Surgical — files contain exactly one tenant | Still works, but each bucket contains ~`tenant_count/N` tenants; `DELETE WHERE tenant_id = 'acme'` writes position deletes within the affected bucket's files |

**Decision rule:** identity-partition `tenant_id` for tenant counts up to ~50; switch to `bucket(tenant_id, 32)` (or larger) above ~100 tenants; revisit `N` if the tenant count crosses 1000 (consider `N=128`). Below the 50-tenant threshold the identity layout's per-tenant metadata access (storage reports, billing) is more valuable than the partition-count headroom; above 100 the manifest bloat outweighs the metadata convenience.

#### Worked case study — a 200-tenant SaaS table on a 90-day rolling window

A concrete example to anchor the decision rule. Suppose your B2B SaaS has grown to **200 active tenants** and your events table holds **90 days of rolling history** before older data is moved to a colder archive table.

**Layout option 1 — identity partition `(day(event_ts), tenant_id)`:**
- Partition count = 90 days × 200 tenants = **18,000 partitions**
- This is **past the ~10,000-partition comfort zone** the resource warns about above.
- Operational symptoms you will see: query planning latency adds ~200–500ms per query (manifest list traversal grows roughly linearly with partition count); the Iceberg manifest-list file itself grows to multiple MB; compaction jobs that iterate over per-partition file lists take noticeably longer; small-file fragmentation on per-tenant per-day boundaries becomes harder to avoid because the per-partition row count for low-activity tenants is already small.
- **What you do get** that is genuinely valuable at this scale: the `$partitions.partition.tenant_id` metadata column is the original tenant string (`'acme'`, `'beta'`), so per-tenant storage reports, GDPR audit queries, and billing dashboards remain a one-line `$partitions` query without ever opening a data file.

**Layout option 2 — switch to `(day(event_ts), bucket(tenant_id, 32))`:**
- Partition count = 90 days × 32 buckets = **2,880 partitions**
- Comfortably under the 10,000 threshold — manifest list stays small, planning latency stays in the tens-of-ms range, compaction jobs iterate over a bounded partition set regardless of tenant growth.
- Per-query pruning still works correctly: `WHERE tenant_id = 'acme'` evaluates `bucket('acme', 32)` once, identifies the matching bucket (say, bucket 17), and reads only the files in that bucket — typically ~1/32 of the table's data files, with the other 31 buckets pruned at manifest time.
- **What you lose**: the `$partitions` per-tenant metadata column is no longer `partition.tenant_id` (a string) — it is `partition.tenant_id_bucket` (an INT in `0..31`). A query like `SELECT partition.tenant_id_bucket, record_count FROM iceberg.analytics."events$partitions"` shows you bucket-level totals (`bucket 17 has 4.2M rows`) but you can't get per-tenant storage from metadata alone — you'd need to fall back to scanning the data files with `SELECT tenant_id, COUNT(*) FROM iceberg.analytics.events GROUP BY tenant_id`, which is much more expensive.

**Threshold rule, made concrete by the case study:**

| Tenant count | Recommended partition spec | Reasoning |
|---|---|---|
| Up to ~100 tenants | `partitioning = ARRAY['day(event_ts)', 'tenant_id']` (identity on tenant_id) | Total partition count stays under ~9,000 even at 100 tenants over 90 days. Per-tenant `$partitions` metadata access is free and is the primary win at this scale (storage reports, billing dashboards, GDPR audit queries are all one-line queries). |
| 100–1000 tenants | `partitioning = ARRAY['day(event_ts)', 'bucket(tenant_id, 32)']` | Caps partition count at 90 × 32 = 2,880 regardless of how many tenants land in each bucket. Per-tenant query pruning still works (the bucket transform is deterministic). Accept the loss of per-tenant `$partitions` metadata in exchange for bounded partition count and query-planning latency. |
| Above 1000 tenants | Reconsider `N` — `bucket(tenant_id, 128)` or `bucket(tenant_id, 256)` | At 1000+ tenants in 32 buckets, each bucket holds ~30+ tenants and per-tenant queries scan more data per bucket than they should. Bumping N keeps each bucket sparser and per-tenant scans tighter. Revisit when crossing 1000. Note that the spec change itself is metadata-only (`ALTER TABLE ... SET PROPERTIES`); to re-layout historical data under the new spec, use `rewrite_data_files` / `EXECUTE optimize` as the standard Phase 2 path — see the "Migrating historical data after partition evolution" subsection in the compaction section below. CTAS is reserved for special cases documented there. |

The 200-tenant case from this section sits firmly in the second row of the table — switch to `bucket(tenant_id, 32)`. The 18,000-partition layout from option 1 is not catastrophic, but you will spend operational time fighting symptoms (planning latency, manifest bloat, compaction duration) that the bucket layout makes go away. The metadata-access cost is real but rarely worth keeping 18,000 partitions to preserve.

### Sort order within partitions — pin time-based dashboards

Iceberg supports an optional **sort order** on top of the partition spec, declared via `WITH (sorted_by = ARRAY['event_ts ASC'])` (Trino) or `WRITE ORDERED BY event_ts` (Spark). The sort order doesn't change pruning at the partition level — that's the partition spec's job — but it **clusters rows within each data file by the sort column**, which lets Iceberg's per-row-group min/max statistics skip entire row groups on time-range predicates.

```sql
-- Trino DDL with sort order
CREATE TABLE analytics.events (...)
WITH (
  partitioning = ARRAY['day(event_ts)', 'bucket(tenant_id, 32)'],
  sorted_by    = ARRAY['event_ts ASC']
);
```

**Why this matters for dashboard queries.** Within a single day's partition, a dashboard query like `WHERE event_ts >= TIMESTAMP '2026-05-25 14:00:00' AND event_ts < '2026-05-25 15:00:00'` (one hour of data) without sort order has to scan every row group in every file in that day's partition — the engine has no information about which row groups overlap the time range. With `sorted_by = ARRAY['event_ts ASC']`, each Parquet row group's `event_ts` min/max bounds are tight (the row group covers a narrow time slice within the day), and Iceberg's predicate pushdown skips the row groups whose bounds don't overlap the hour window. Typical speedup for hour-granular dashboards on day-partitioned tables: 5–20x.

**The sort order applies to NEW writes, not existing files.** Adding `sorted_by` to an existing table via `ALTER TABLE ... SET PROPERTIES` flips the spec for future writes only. To apply the sort order to historical data, run `rewrite_data_files` (Spark) or `EXECUTE optimize` (Trino) — both re-sort within each rewritten file.

### Compaction — pick the engine that matches your runbook

Both Trino 467 and Spark can compact small Iceberg files into healthy 256MB–1GB Parquet files. **On the on-prem stack the Trino-native form is the default** for routine compaction because it requires no `spark-submit`, no separate Spark cluster lifecycle, and runs from the same SQL session you already have open for the query that diagnosed the problem.

```sql
-- TRINO 467 — the default for routine compaction. Runs entirely from a Trino session.
-- file_size_threshold marks any file smaller than the threshold as a compaction candidate.
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '100MB');

-- Without any options (uses Trino's defaults for target file size).
ALTER TABLE iceberg.analytics.events EXECUTE optimize;

-- Per-partition compaction — same as Trino default, restricted via WHERE on the partition column.
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '100MB')
WHERE day_event_ts = DATE '2026-05-24';

-- SPARK — equivalent procedure, use when you need options Trino doesn't expose
-- (e.g., delete-file-threshold to fold MoR position deletes into data files, custom
-- target-file-size-bytes, partial-progress mode for incremental commits).
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files',        '5'
  )
);
```

> **After `rewrite_data_files` or `EXECUTE optimize`, run `expire_snapshots` to reclaim MinIO storage from the pre-rewrite snapshots.** Otherwise the old (pre-compaction) Parquet files remain referenced by historical snapshots and stay on MinIO until the retention window expires automatically (5 days for Iceberg's `history.expire.max-snapshot-age-ms` default, 7 days for Trino's `iceberg.expire-snapshots.min-retention` floor). Standard post-compaction one-liner from Trino: `ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d');` — see the dedicated subsection further down for the full mechanics and the Trino minimum-retention caveat for GDPR-urgent zero-day cases.

**When to pick which engine:**

| Use case | Engine | Why |
|---|---|---|
| Routine weekly/monthly compaction of small files | Trino `EXECUTE optimize` | No Spark hop; runs from the dashboard SQL session that detected the small-file count |
| Per-partition surgical rewrite after a one-off load | Trino `EXECUTE optimize WHERE ...` | Surgical, no full-table cost |
| Fold MoR position-delete files back into data files (bulk DELETE recovery) | Spark `rewrite_data_files` with `delete-file-threshold => '1'` | Trino's OPTIMIZE cannot apply position deletes — see resource 13's "Diagnosing position-delete-file accumulation" subsection |
| GDPR per-tenant data physical removal (step 2 of the 4-step purge) | Spark `rewrite_data_files` with `where => "tenant_id = 'acme'"` | Trino's OPTIMIZE has no `where` filter for the rewrite scope, and cannot apply position deletes — see the GDPR purge section above |
| Large historical re-layout after partition evolution | Spark `rewrite_data_files` | Better partial-progress control and stronger options vocabulary |

#### Try `rewrite_manifests` FIRST — often recovers planning latency without any spec change

Before committing to a partition spec evolution, **try compacting manifests first**. The actual planning-time bottleneck on a 12,000-partition table is usually not the partition count itself but the **manifest count** — Trino's planner reads the manifest list, then opens each surviving manifest file to look up data file metadata. A long history of many small commits produces many small manifest files; combining them into a small number of large manifests (without changing the partition spec or rewriting any data file) often reduces planning time from hundreds of milliseconds back to tens of milliseconds.

```python
# Spark — compact manifests. Does NOT change partition spec. Does NOT rewrite data files.
# Combines many small manifest files into a small number of larger ones.
spark.sql("""
    CALL iceberg.system.rewrite_manifests(table => 'analytics.events')
""")
```

```sql
-- Trino 467 equivalent
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d');
-- Note: Trino 467 does not yet have a native EXECUTE form of rewrite_manifests
-- (see trinodb/trino #14249). For manifest compaction, use the Spark CALL above.
```

**What `rewrite_manifests` does and doesn't do:**

| Operation | Changes partition spec? | Rewrites data files? | Combines manifests? | Typical runtime on 12k partitions |
|---|---|---|---|---|
| `rewrite_manifests` | No | No | Yes | Minutes |
| `rewrite_data_files` / `EXECUTE optimize` | No (uses current spec for outputs) | Yes — bin-packs / re-sorts / re-buckets | Implicitly (new files get new manifests) | Hours for full table |
| `ALTER TABLE ... SET PROPERTIES partitioning = ARRAY[...]` | Yes (metadata-only) | No | No | Seconds |

**Run `rewrite_manifests` first** as the lowest-risk planning-latency intervention. If planning is still slow after manifest compaction, then consider a partition-spec evolution. Many incidents that look like "we need to repartition" are actually "we need to compact manifests" and are resolved by this one operation alone.

#### Migrating historical data after partition evolution: `rewrite_data_files` vs CTAS

When you do change the partition spec — e.g., switching from `ARRAY['day(event_ts)', 'tenant_id']` to `ARRAY['day(event_ts)', 'bucket(tenant_id, 32)']` — Iceberg records a **new partition spec version** in the table metadata; the change itself is metadata-only and completes in seconds. **Existing data files keep their original spec** (Iceberg tracks each file's spec id in the manifest entry, so the table can correctly contain files written under multiple specs at the same time and queries still return correct results). **New writes** use the new spec. The remaining question is: how do you re-layout the historical files under the new spec?

**The standard answer: `rewrite_data_files` (Spark) or `EXECUTE optimize` (Trino) — they use the table's CURRENT partition spec when writing the rewritten files, which is the new spec after the `SET PROPERTIES` change.** This is the correct and lower-risk Phase 2 migration path. There is no need for CTAS in the typical case.

**Standard Phase 2 recipe — after the partition spec evolution, rewrite under the new spec:**

```python
# Spark — rewrite the data files. After the SET PROPERTIES change above, the table's
# CURRENT partition spec is the new one (day + bucket), and rewrite_data_files
# writes the rewritten files under that current spec. Old files written under the
# prior identity-tenant_id spec are rewritten into bucket-partitioned files.
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.events',
        options => map('target-file-size-bytes', '268435456')   -- 256 MB
    )
""")
```

```sql
-- Trino 467 equivalent — also uses the table's current (new) partition spec for the
-- rewritten files. No spec_id argument is needed; Trino's OPTIMIZE always writes
-- under the table's current spec.
ALTER TABLE iceberg.analytics.events EXECUTE optimize(file_size_threshold => '100MB');
```

> **After `rewrite_data_files` / `EXECUTE optimize`, ALWAYS run `expire_snapshots` to reclaim MinIO storage from the pre-rewrite snapshots.** Iceberg keeps the old data files on MinIO as long as any live snapshot still references them — and the snapshots from before the rewrite still reference every old file. Without `expire_snapshots`, you have effectively **doubled your MinIO storage** until the default retention window elapses (5 days for Iceberg's `history.expire.max-snapshot-age-ms`, 7 days for Trino's `iceberg.expire-snapshots.min-retention` floor). Run it explicitly after the rewrite:
>
> ```sql
> -- Trino 467: expire snapshots older than 7 days (default minimum-retention floor) to
> -- reclaim MinIO storage from the pre-rewrite snapshots. Tune the threshold down only
> -- if your rollback window can tolerate it; never below the Trino catalog property
> -- iceberg.expire-snapshots.min-retention without coordinating with the data team.
> ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d');
> ```
>
> See resource 13's GDPR-purge section for the Spark-side `CALL iceberg.system.expire_snapshots(...)` syntax and the `iceberg.expire-snapshots.min-retention` floor caveat. For routine post-rewrite cleanup, 7 days is the recommended default — it preserves the standard one-week rollback window while still reclaiming the pre-rewrite bytes.

**When to use CTAS instead (special cases only):**

CTAS (CREATE TABLE AS SELECT into a new table with the desired partition spec, then swap views, then drop the old table) is **not** the default Phase 2 path. Reserve it for the following special cases:

| Special case | Why CTAS, not `rewrite_data_files` |
|---|---|
| You need to change the **partition column itself** (e.g., currently `day(event_ts)` but the application now wants `month(occurred_at)` against a different timestamp column) | A spec evolution can add or remove transforms on existing columns, but switching the underlying partition column entirely is operationally cleaner via CTAS into a fresh table with the new spec |
| The table is **so fragmented that a full rebuild is faster than compaction** (e.g., millions of <1MB files from a long history of streaming writes, where iterating in `rewrite_data_files` would take days) | CTAS in parallel can occasionally outperform incremental compaction in pathological cases — measure first; do not assume |
| You need a **zero-downtime cutover with the old table as a safety net** (e.g., a major refactor where rolling back must be instantaneous, not a `rollback_to_snapshot`) | CTAS gives you a separate table you can point views at; rolling back is a single `CREATE OR REPLACE VIEW` away |

**CTAS risks to document — before choosing CTAS over `rewrite_data_files`, weigh these explicitly:**

- **Doubles MinIO storage during the rewrite.** Both the old table and the new table exist simultaneously until you drop the old one. For a 10TB events table this is 10TB of extra MinIO capacity for the duration of the rewrite — make sure your MinIO cluster has the headroom before you start.
- **Loses Iceberg snapshot history on the new table.** Time-travel queries (`FOR VERSION AS OF`, `FOR TIMESTAMP AS OF`) against pre-rewrite snapshots no longer work — the new table's snapshot history begins at the moment of CTAS. If your audit, rollback, or reconciliation processes depend on time-travel into the old snapshots, CTAS breaks them. `rewrite_data_files` preserves the snapshot history (the rewrite is just another snapshot in the chain).
- **Requires redirecting all dependent views and grants.** With 140+ per-tenant views, you must `CREATE OR REPLACE VIEW` every one of them to point at the new table name (or use the safe RENAME pattern below). Miss one and that tenant breaks.
- **Window between DROP and RENAME where the table doesn't exist.** If you DROP the old table first then RENAME the new one, there is a brief window (seconds) where the table name doesn't resolve — concurrent ingestion writes fail during that window. **Always RENAME first, then DROP** (see the safety note below).

**CTAS recipe — if you really need it:**

```sql
-- Trino 467: CTAS into a new table with the explicit new partition spec.
-- This rewrites every row under the new layout — expensive (full table read + write).
CREATE TABLE iceberg.analytics.events_v2
WITH (partitioning = ARRAY['day(event_ts)', 'bucket(tenant_id, 32)'])
AS SELECT * FROM iceberg.analytics.events;

-- Verify row counts and a few sample columns match before any destructive step.
SELECT
    (SELECT COUNT(*) FROM iceberg.analytics.events)    AS old_count,
    (SELECT COUNT(*) FROM iceberg.analytics.events_v2) AS new_count;

-- Update dependent views to point at events_v2 (one CREATE OR REPLACE VIEW per tenant).
-- (Use the safe cutover pattern documented earlier in this resource for the 5-step swap.)

-- After all views verify against events_v2, rename FIRST then drop:
-- 1) Stash the old table under a holding name so the production name is free:
ALTER TABLE iceberg.analytics.events RENAME TO iceberg.analytics.events_old;
-- 2) Promote the new table to the production name (atomic in Iceberg):
ALTER TABLE iceberg.analytics.events_v2 RENAME TO iceberg.analytics.events;
-- 3) ONLY AFTER (1) and (2) succeed and a brief soak period (24h+) to confirm
--    no ingestion failures, drop the old table:
DROP TABLE iceberg.analytics.events_old;
```

> **CTAS-cutover safety note: always `RENAME` BEFORE `DROP TABLE`. NEVER drop the old table first.** A `DROP TABLE iceberg.analytics.events` followed by `ALTER TABLE iceberg.analytics.events_v2 RENAME TO events` creates a brief window where the production table name does not exist. During that window — even if it is only a few seconds — every Debezium / Spark / Trino ingestion job writing to `iceberg.analytics.events` fails with `Table 'iceberg.analytics.events' does not exist`. Reads fail too. The safe pattern is the three-step shape above: (1) RENAME old → `events_old`, (2) RENAME new → production name, (3) ONLY THEN drop `events_old`. Steps 1 and 2 are atomic in Iceberg's commit protocol; between them the production name is briefly missing, so coordinate them as a single client session and back-to-back execution (no human break between them). For zero-downtime, pause ingestion for the duration of steps 1+2 (typically <1 second total).

**Bottom line: prefer `rewrite_data_files` / `EXECUTE optimize` as the standard Phase 2 path** — it uses the table's current (new) partition spec for the rewritten files, preserves snapshot history, doesn't double your MinIO storage, doesn't require view-swaps, and is operationally simpler. Reserve CTAS for the special cases above where a full rebuild into a new table is genuinely required. Both paths end with `expire_snapshots` to reclaim MinIO storage from the pre-rewrite snapshots.

**Verifying compaction worked — `partition.day` is INT, NOT VARCHAR.** A common AI-generated diagnostic bug: writing the `$files` query like this fails or produces wrong results on Trino 467:

```sql
-- WRONG — type mismatch. partition.day is INT (days-since-epoch), not VARCHAR.
SELECT COUNT(*) AS small_file_count
FROM iceberg.analytics."events$files"
WHERE file_size_in_bytes < 100 * 1024 * 1024
  AND partition.day >= CAST(CURRENT_DATE - INTERVAL '1' DAY AS VARCHAR);
```

When the partition transform is `day(event_ts)`, the `$files` metadata table materializes the partition value as the **integer day-count since the Unix epoch (1970-01-01)** — NOT as a string, NOT as a DATE. The correct date comparison converts CURRENT_DATE to days-since-epoch and compares ints:

```sql
-- CORRECT — compare INT to INT (days since epoch).
SELECT COUNT(*) AS small_file_count
FROM iceberg.analytics."events$files"
WHERE file_size_in_bytes < 100 * 1024 * 1024
  AND partition.day >= date_diff('day', DATE '1970-01-01', CURRENT_DATE - INTERVAL '1' DAY);

-- Or use the data-layer column directly if you don't strictly need metadata-only:
SELECT COUNT(*) FROM iceberg.analytics."events$files"
WHERE file_size_in_bytes < 100 * 1024 * 1024;  -- whole table, no partition predicate
```

**Reference — `partition.*` field types on `$files` for each transform.** Match the right comparison type or your predicate is silently a no-op (or worse — implicit-cast misbehavior):

| Partition transform | `partition.<name>` type | Example correct predicate |
|---|---|---|
| `day(ts)` | **INT** (days since epoch, 1970-01-01) | `partition.day >= date_diff('day', DATE '1970-01-01', CURRENT_DATE)` |
| `month(ts)` | **INT** (months since epoch — Jan 1970 = 0) | `partition.month >= date_diff('month', DATE '1970-01-01', CURRENT_DATE)` |
| `year(ts)` | **INT** (years since 1970, so 2026 = 56) | `partition.year >= year(CURRENT_DATE) - 1970` |
| `hour(ts)` | **INT** (hours since epoch) | `partition.hour >= date_diff('hour', TIMESTAMP '1970-01-01 00:00:00', CURRENT_TIMESTAMP)` |
| `bucket(col, N)` | **INT** (bucket index, 0..N-1) | `partition.col_bucket = 17` |
| `truncate(col, W)` | **same type as source column** | depends on source column type |
| identity (no transform) | **same type as source column** | `partition.tenant_id = 'acme'` (string), `partition.region = 1` (int) |

When in doubt, run `DESCRIBE iceberg.analytics."events$files"` to inspect the materialized types of every field inside the `partition` struct.

### Hidden partitioning — Iceberg's nice feature

Iceberg has **hidden partitioning**: you declare the partition spec once when you create the table (e.g., `day(event_ts)`), and after that **users don't need to know the partition key**. They write `WHERE event_ts >= DATE '2026-05-01'` and Trino + Iceberg automatically translate that into the right partition filter behind the scenes.

In older Hive-style tables, users had to write `WHERE event_date = '2026-05-01'` separately from `event_ts`, or the query would scan everything. Iceberg removes that foot-gun. So your tenants writing normal SQL still get fast queries.

### Warning: don't change the partition spec casually

Iceberg supports partition evolution (changing the spec over time), but each change creates a different layout for new data. Pick a spec you can live with for years. `(tenant_id, day(event_ts))` is a safe default.

---

## Cross-tenant internal analytics — rollup tables

A common SaaS production pattern: customer-facing dashboards query a single tenant's slice of the events table (fast — prunes to one tenant's partitions). Internal billing, finance, and customer-success teams need cross-tenant queries like "total events per tenant this week" for billing reports, growth metrics, and tier-upgrade conversations. Those queries must touch every tenant's partition, so they're significantly slower than the per-tenant queries — and they compete with customer queries for the same files in the same Iceberg snapshots.

The standard answer is a **pre-aggregated rollup table** updated by a nightly Spark job. Billions of raw event rows compress to thousands of pre-aggregated rows per day; internal queries get sub-second response and don't compete with customer dashboards for the same files.

### Rollup table DDL — Spark SQL

```sql
-- Spark SQL DDL. Run via spark-sql or a Spark job that creates the table.
-- The Trino equivalent uses WITH (partitioning = ARRAY['event_date', 'tenant_id']) syntax instead;
-- both produce the same Iceberg table.
CREATE TABLE iceberg.analytics.daily_event_rollup (
  event_date   DATE,
  tenant_id    STRING,
  event_type   STRING,
  event_count  BIGINT,
  unique_users BIGINT,
  rollup_time  TIMESTAMP
)
USING iceberg
PARTITIONED BY (event_date, tenant_id);
```

### Exclude internal/test accounts from reporting

Before writing the aggregation, decide what counts as "a tenant" for the rollup. Internal tenants (your own QA tenant, demo accounts, the sandbox you use for sales demos, churned-but-not-yet-deleted accounts) skew every metric — MRR is inflated, event counts include synthetic load, "average events per tenant" gets dragged toward whatever your QA team did this morning. The standard pattern is to JOIN to the tenant registry and filter to production-active rows during the aggregation:

```sql
-- The standard exclude-internal/test pattern: JOIN to the tenant registry and filter.
-- Apply this filter inside the rollup SELECT, NOT at downstream query time — it keeps
-- the rollup table itself clean and avoids every downstream consumer having to re-apply it.
SELECT
  DATE(event_ts)         AS event_date,
  e.tenant_id,
  e.event_type,
  COUNT(*)               AS event_count,
  COUNT(DISTINCT user_id) AS unique_users,
  CURRENT_TIMESTAMP      AS rollup_time
FROM iceberg.analytics.events e
JOIN iceberg.catalog.tenants t
  ON e.tenant_id = t.tenant_id
WHERE DATE(event_ts) = DATE '2026-05-24'
  AND t.account_type = 'production'   -- exclude 'internal', 'demo', 'qa', 'sandbox'
  AND t.status       = 'active'       -- exclude 'churned', 'suspended', 'trial_expired'
GROUP BY DATE(event_ts), e.tenant_id, e.event_type;
```

This requires an `account_type` and `status` column on the tenant registry table (`iceberg.catalog.tenants` or whatever your registry table is called). If those columns don't exist yet, add them — `account_type` as VARCHAR with values like `'production'`, `'internal'`, `'demo'`, `'qa'`; `status` as VARCHAR with values like `'active'`, `'churned'`, `'suspended'`, `'trial_expired'`. Backfill them once from your application's source-of-truth (tenant provisioning database, Salesforce account type, etc.). The cost of this JOIN is negligible because the tenant registry is small (one row per tenant, typically thousands of rows) and Trino broadcasts it to every worker.

### Nightly rollup job — the WRONG (naive) pattern first

```python
# Spark SQL. Naive INSERT INTO that looks correct but is NOT idempotent.
# Re-running this job for the same logical day produces DUPLICATE rows.
spark.sql("""
    INSERT INTO iceberg.analytics.daily_event_rollup
    SELECT
      DATE(event_ts)         AS event_date,
      tenant_id,
      event_type,
      COUNT(*)               AS event_count,
      COUNT(DISTINCT user_id) AS unique_users,
      CURRENT_TIMESTAMP      AS rollup_time
    FROM iceberg.analytics.events
    WHERE event_ts >= CURRENT_TIMESTAMP - INTERVAL '1' DAY
    GROUP BY 1, 2, 3
""")
```

> **WARNING — `INSERT INTO ... SELECT ... GROUP BY` is NOT idempotent for rollup tables.** If this job re-runs (job retry after a pod crash, an Airflow `clear` of the failed task, a manual operator re-run because it looked stuck, or late events arriving after the original run), the same `(event_date, tenant_id, event_type)` combination gets INSERTed a **second** time — producing **two** rows for that key with two different `event_count` values and two different `rollup_time` values. Internal queries that `SELECT event_date, tenant_id, SUM(event_count)` then **double-count** every metric.
>
> No error is raised. The rollup table still passes basic sanity checks (row counts grow, recent dates appear). The downstream billing dashboard quietly reports 2x the real event counts for the day the job re-ran. Engineers usually discover this when a customer disputes their invoice and the audit trace shows two `rollup_time` entries for the same (event_date, tenant_id) — by which point several days of billing reports are wrong.

### Nightly rollup job — TWO idempotent patterns (pick one)

**Pattern A — `INSERT OVERWRITE` to atomically replace the affected partition (Spark SQL only, simplest).** When you re-run the job for a logical day, `INSERT OVERWRITE` atomically replaces that day's partition contents — old rows for the day are dropped in the same commit that writes the new rows. Re-running with the same `event_date` parameter produces the **same** final state; no duplicates regardless of how many times the job runs.

> **`INSERT OVERWRITE` is Spark SQL syntax — it does NOT exist in Trino 467.** Trino's `INSERT` only appends; there is no `INSERT OVERWRITE` form in Trino 467. If you need to run this rollup from Trino, the closest equivalent is two statements: `DELETE FROM iceberg.analytics.daily_event_rollup WHERE event_date = DATE '...'` followed by `INSERT INTO iceberg.analytics.daily_event_rollup SELECT ...`. The two-statement form is NOT atomic together — a reader hitting the table between the DELETE and INSERT sees the partition as empty. For idempotent rollup jobs, run from Spark with `INSERT OVERWRITE` so the partition replacement is one atomic commit.

```python
# SAFE: Spark INSERT OVERWRITE replaces only the affected event_date partition.
# Re-running with the same batch_date is idempotent — same input, same output.
batch_date = "2026-05-24"  # passed as a CLI / Airflow parameter

spark.sql(f"""
    INSERT OVERWRITE TABLE iceberg.analytics.daily_event_rollup
    PARTITION (event_date = DATE '{batch_date}')
    SELECT
      tenant_id,
      event_type,
      COUNT(*)               AS event_count,
      COUNT(DISTINCT user_id) AS unique_users,
      CURRENT_TIMESTAMP      AS rollup_time
    FROM iceberg.analytics.events
    WHERE DATE(event_ts) = DATE '{batch_date}'
    GROUP BY tenant_id, event_type
""")
```

**Why this is idempotent:** Iceberg commits the OVERWRITE as a single atomic snapshot — readers see either the prior version of the partition or the fully-written new one, never a partial state mid-overwrite. The new partition entirely replaces the old one; no double-counting possible. The `batch_date` is an **explicit parameter**, not a `CURRENT_TIMESTAMP - INTERVAL` window — so re-running the job for the same date deterministically reproduces the same partition contents.

**Pattern B — `MERGE INTO` to upsert aggregated values (works for both Spark and Trino; right choice when late events trickle in over time).** When new events for an already-rolled-up day arrive after the original rollup run (mobile clients syncing offline buffered events, webhooks retrying, partner integrations pushing late data), you want to **add** the late counts to the existing aggregated rows, not double-insert them. MERGE INTO matches on `(event_date, tenant_id, event_type)` and updates the existing row if matched, inserts if not.

```python
# Pattern B: re-aggregate from raw events for the affected day, then MERGE INTO.
# Handles both first-run and re-run scenarios identically; late events update
# the existing aggregated row in place instead of double-counting.
batch_date = "2026-05-24"

spark.sql(f"""
    CREATE OR REPLACE TEMPORARY VIEW daily_rollup_delta AS
    SELECT
      DATE '{batch_date}'    AS event_date,
      tenant_id,
      event_type,
      COUNT(*)               AS event_count,
      COUNT(DISTINCT user_id) AS unique_users,
      CURRENT_TIMESTAMP      AS rollup_time
    FROM iceberg.analytics.events
    WHERE DATE(event_ts) = DATE '{batch_date}'
    GROUP BY tenant_id, event_type
""")

spark.sql("""
    MERGE INTO iceberg.analytics.daily_event_rollup t
    USING daily_rollup_delta s
    ON  t.event_date  = s.event_date
    AND t.tenant_id   = s.tenant_id
    AND t.event_type  = s.event_type
    WHEN MATCHED THEN UPDATE SET
        event_count  = s.event_count,
        unique_users = s.unique_users,
        rollup_time  = s.rollup_time
    WHEN NOT MATCHED THEN INSERT *
""")
```

**Why this is idempotent:** the MERGE matches on the full rollup grain — `(event_date, tenant_id, event_type)`. If a row already exists for that key (re-run, late re-aggregation, backfill), it's UPDATEd in place with the recomputed values from the delta. If no row exists yet (first run, or a new event_type appeared), it's INSERTed. Re-running the same MERGE multiple times produces the same final state.

> **When to pick which:**
> - **`INSERT OVERWRITE` (Pattern A — Spark SQL only)** is the right default for daily rollups that fully re-aggregate the affected day from raw events. It's atomic, simpler to reason about, and the partition contents always match a fresh re-aggregation of the source — there is no drift possible. Run this from Spark; Trino 467 has no `INSERT OVERWRITE` form. If your rollup pipeline is Trino-only (no Spark step), use Pattern B (`MERGE INTO`) instead — Trino 467 supports `MERGE INTO` on Iceberg tables.
> - **`MERGE INTO` (Pattern B)** is the right choice when the rollup is computed incrementally (e.g., only the new events since the last run are pulled, not the full day) **AND** late events for already-rolled-up days are expected. The MERGE updates the existing aggregated row rather than overwriting the partition with a partial delta. Note: if you use Pattern B with only the *delta* of new events (not the full day's re-aggregation), the `s.event_count` from the delta only contains the new events — you'd need `t.event_count + s.event_count` on the UPDATE side to accumulate, which makes the MERGE no longer idempotent on re-run. For full safety, always re-aggregate the entire `(event_date, tenant_id, event_type)` grain from raw events into the delta view, then MERGE — that way the UPDATE just `SET event_count = s.event_count` and the operation stays idempotent.
>
> **Never** rely on the bare `INSERT INTO ... SELECT ... GROUP BY` pattern shown in the WRONG section above for any production rollup — there is no idempotency story for it and a single retry produces silently doubled metrics.

### Internal team queries the rollup, not raw events

```sql
-- Trino. Sub-second response — reads thousands of pre-aggregated rows, not billions of raw events.
SELECT
  event_date,
  tenant_id,
  SUM(event_count) AS total_events
FROM iceberg.analytics.daily_event_rollup
WHERE event_date >= DATE '2026-05-19'
GROUP BY event_date, tenant_id
ORDER BY event_date DESC, total_events DESC;
```

> **CRITICAL SQL FOOTGUN — Trino does NOT support `PERCENTILE_CONT ... WITHIN GROUP`. Use `approx_percentile(col, p)` instead.** This is one of the most common copy-paste failures for engineers coming from Postgres, SQL Server, Snowflake, BigQuery, or any other ANSI-flavored SQL dialect. Those engines all support `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY session_length_ms)` as the standard way to compute a median or other percentile. **Trino does not.** Per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html), Trino's ordered-set aggregate `WITHIN GROUP` syntax is supported **only for `listagg`** — not for any percentile function. Writing `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY x)` against Trino fails at parse time with a cryptic syntax error.
>
> The correct Trino expression for percentiles is `approx_percentile(column, fraction)`, which uses the T-Digest algorithm under the hood (fast, memory-bounded, suitable for arbitrarily large datasets):
>
> ```sql
> -- WRONG (Postgres / Snowflake / SQL Server syntax — fails on Trino):
> SELECT tenant_id,
>        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY session_length_ms) AS p50,
>        PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY session_length_ms) AS p95
> FROM iceberg.analytics.session_events
> GROUP BY tenant_id;
>
> -- CORRECT (Trino):
> SELECT tenant_id,
>        approx_percentile(session_length_ms, 0.5)  AS p50,
>        approx_percentile(session_length_ms, 0.95) AS p95
> FROM iceberg.analytics.session_events
> GROUP BY tenant_id;
>
> -- BONUS — compute multiple percentiles in a single pass with the array form:
> SELECT tenant_id,
>        approx_percentile(session_length_ms, ARRAY[0.5, 0.95, 0.99]) AS p50_p95_p99
> FROM iceberg.analytics.session_events
> GROUP BY tenant_id;
> ```
>
> **Why this matters operationally.** A Postgres-trained engineer writes a "compute p50/p95 session length per tenant" dashboard, copy-pastes the `PERCENTILE_CONT WITHIN GROUP` form they have used for years, and the query fails at parse time. They lose 30 minutes debugging what looks like a typo. Worse — if the query is embedded in dbt or in application code that submits SQL through a connector, the error surfaces as a downstream pipeline failure, not as an obvious "wrong SQL dialect" message. **When writing any Trino aggregation involving percentiles, medians, or quantiles, default to `approx_percentile`.** Reserve `PERCENTILE_CONT` for queries that target Postgres or another dialect.
>
> Other Trino aggregate-function gotchas in the same family:
> - `MEDIAN(x)` does NOT exist in Trino — use `approx_percentile(x, 0.5)`.
> - `STDDEV()` and `VARIANCE()` DO exist (`stddev`, `variance`, `stddev_pop`, `var_pop`) — these match the cross-dialect names.
> - `MODE()` does not have a built-in equivalent; use `array_agg(x)` + `array_position` patterns, or precompute in a rollup.

### Why this preserves per-tenant isolation

The rollup table is an **internal** artifact — it's not exposed to customer-facing dashboards or the per-tenant views. Customer queries still go through the existing per-tenant view → base events table → OPA policy chain (see "Trino views that bake in the tenant filter" earlier in this file). The rollup table is granted only to internal data-team principals; customer roles have no access to it. None of the partition layout changes, view definitions, or OPA policies on the base events table are affected by introducing a rollup.

> **OPA admin carve-out for internal principals.** The OPA authorization policy grants internal service accounts (e.g., `internal-data-team-sa`, `finance-team-sa`, `customer-success-sa`) an **admin carve-out** that bypasses the per-tenant row filter — so when these principals query the base `events` table (or the rollup table), OPA does NOT inject `WHERE tenant_id = '...'`. Without the carve-out, internal cross-tenant queries would either return zero rows (no matching `tenant_id` for an internal principal) or be denied outright. The specific carve-out mechanism — which Rego rule recognizes which JWT claim, how the internal allow-list is maintained, how onboarding/offboarding internal users updates the policy — lives in the external governance document (see `prod_info.md`). What you need to know as an engineer building a rollup pipeline: **the carve-out must exist for your internal service account, or your rollup job's Spark identity will be silently row-filtered to zero rows from the base events table** during the aggregation step. Verify with a `SELECT DISTINCT tenant_id FROM iceberg.analytics.events` as the rollup job's service account — it must return all tenant IDs, not one.

### Internal analytics audit lane — separate audit log for cross-tenant queries

Internal cross-tenant queries (the data team running "total MRR across all tenants this month" via `data-team` principal, the customer-success team computing per-tenant engagement scores) are **higher-privilege than customer queries** — by definition, they read data spanning multiple tenants. For SOC2, ISO 27001, and most enterprise customer security reviews, you need to **distinguish internal cross-tenant queries from customer queries in your audit log** so compliance reviewers can answer "who at your company ran a query that touched my tenant's data, and when?" without having to manually filter thousands of routine per-tenant queries.

**Two implementation options, both cheap:**

1. **Tag internal queries via a dedicated resource group + separate audit sink.** Internal principals (`data-team`, `finance-team`, `customer-success`) are already routed to their own resource group (`internal-analytics`). Configure the HTTP event listener to send query events for that resource group to a **dedicated audit endpoint** (e.g., `http://audit-collector:8080/events/internal` vs `/events/customer`). The collector writes to a separate Iceberg table (`iceberg.analytics.internal_query_audit_log` vs `iceberg.analytics.query_audit_log`), making compliance queries trivially scoped.

2. **Single audit table with a `query_lane` column.** Simpler: one audit table, but the receiver inspects the `context.user` principal on every incoming event and writes either `'internal'` or `'customer'` into a `query_lane VARCHAR` column. A compliance reviewer's query becomes `SELECT * FROM iceberg.analytics.query_audit_log WHERE query_lane = 'internal' AND create_time > DATE '2026-04-01'` — every cross-tenant query the data team ran in the reporting window, with full SQL text, timing, and bytes-scanned.

Either way, the **key property** is that an auditor can answer "did anyone at your company query my data outside my normal customer-facing access path?" without trawling through the entire query log. Internal queries are not necessarily suspicious — they're how billing works — but they ARE the queries a customer's security team will want to see explicitly enumerated during a SOC2 audit, and surfacing them on a separate lane (table or column) makes that disclosure a one-line SQL query rather than a multi-hour log-grep exercise. Pair with the existing `tenant_id`-as-partition layout (next paragraph): when an internal query touches the partition for tenant Acme, the audit row's `query_lane = 'internal'` is enough to flag it for review — no separate data-access classification is needed.

**Bonus: `tenant_id`-as-partition makes cross-tenant aggregates parallelizable per-tenant.** When the base `events` table is partitioned by `tenant_id` (the recommended layout for multi-tenant), a `GROUP BY tenant_id` query like `SELECT tenant_id, SUM(event_count) FROM events WHERE event_date >= ...` becomes a **per-partition parallel scan** — each Trino worker reads one tenant's partition independently, computes the local sum, and the coordinator merges the small per-tenant aggregates at the end. This is dramatically faster than an unstructured scan that has to read every file and then bucket rows by `tenant_id` post-hoc. For 80 tenants on a 10-worker Trino cluster, this turns a 5-minute cross-tenant query into a 30-second one. The same partition layout that makes per-tenant queries fast (via partition pruning) also makes internal cross-tenant aggregates fast (via partition-parallel scans) — no separate optimization needed.

### Faster alternative for simple per-tenant `COUNT(*)`: metadata-only queries

Before standing up a rollup table, check whether your query can be answered from Iceberg's metadata alone. For **identity-partitioned** tables where `tenant_id` is a partition column (not bucketed), per-tenant `COUNT(*)` and storage-byte sums are metadata-only — they read manifest files only, never opening Parquet data files. Sub-second response with no rollup job needed:

```sql
-- Per-tenant record counts and file counts from Iceberg's $partitions metadata table.
-- Reads ONLY the manifest list; never opens a Parquet data file.
-- Runs in milliseconds regardless of table size (works even on multi-TB tables).
--
-- IMPORTANT: partition.day_occurred_at is INT (days since 1970-01-01), NOT DATE.
-- Comparing it against a DATE literal silently fails on Trino 467. Convert the
-- DATE to days-since-epoch with date_diff().
SELECT partition.tenant_id, SUM(record_count) AS total_rows, SUM(file_count) AS files
FROM iceberg.analytics."events$partitions"
WHERE partition.day_occurred_at >= date_diff('day', DATE '1970-01-01', DATE '2026-05-19')
GROUP BY partition.tenant_id
ORDER BY total_rows DESC;
```

This works for `COUNT(*)`, file counts, and storage bytes — exactly what most billing dashboards need. It does NOT work for more complex aggregations (`COUNT(DISTINCT user_id)`, `SUM(amount)`, per-event-type breakdowns) — those still need a rollup table because the metadata only tracks file-level statistics, not column-level distinct counts or column-value sums. **Caveat:** the metadata-only approach requires `tenant_id` to be an **identity** partition; `bucket(tenant_id, N)` stores the bucket integer (0..N-1) in the partition struct, not the original tenant_id, and the metadata-only count becomes useless. **Type caveat:** any partition column that came from a `day()`, `month()`, `year()`, `hour()`, or `bucket()` transform is **INT** in the `partition` struct — not the original DATE/TIMESTAMP/STRING type. See the "Verifying compaction worked — `partition.day` is INT, NOT VARCHAR" subsection earlier in this resource for the full transform-to-type table.

> **`$partitions` reflects the CURRENT partition spec only.** If the table has undergone partition evolution (e.g., previously partitioned by `tenant_id` alone, now by `(day(occurred_at), tenant_id)`), the `$partitions` metadata table only shows rows for files written under the current spec. Older files written under the prior spec are missing from `$partitions` results. For tables that have evolved their partition spec, fall back to `$files` (which lists every data file individually regardless of the spec it was written under) plus an explicit `GROUP BY` for accurate full-history counts.

---

## Noisy neighbor

In any shared-table multi-tenant setup, a small number of tenants typically generate most of the data and most of the query load. If 3 of your 80 customers produce 90% of the events, their analytical queries can saturate the Trino cluster and slow everyone else down — even though their data is logically isolated.

### Why small-tenant queries get slower when large tenants are added

This is the most common multi-tenant performance regression and the symptom is confusing on first contact: nothing changed about the small tenants — same query, same partition predicates, same dashboard — but the wall-clock time on their queries went from ~200ms to ~800ms after a new enterprise tenant onboarded. The small tenants' partitions weren't touched. **What changed is not their data; it's the shape of the rest of the table**, and the small-tenant queries pay for that change in three specific mechanisms. Each mechanism has a different fix; understanding which one dominates lets you pick the right intervention instead of doing all three.

**Mechanism 1 — Manifest-list growth slows planning even for queries that prune correctly.**

Iceberg organizes its metadata as a tree: the table's current snapshot points to a **manifest list** (one file per snapshot), which points to multiple **manifest files**, each of which lists data files for one slice of the table. When a query runs, Trino's planner walks the manifest list to identify which manifests could contain matching files, then walks the surviving manifests to identify the data files to scan. The Iceberg manifest list **pre-filters manifests by partition range** (each manifest-list entry carries the partition-value ranges for the files in that manifest), so manifests that cannot contain matching data are skipped without opening them. This is the partition-pruning property that makes Iceberg queries fast.

**But** as the enterprise tenant's files accumulate, the **number of manifest-list entries grows** — each new manifest the writer creates adds another entry the planner must traverse to evaluate the partition-range filter, even on small-tenant queries that ultimately prune to zero matching manifests. At small scale (one or two enterprise tenants worth of data), this adds tens of milliseconds to planning latency. At large scale (a multi-TB enterprise tenant on a shared table), it can add hundreds of ms — enough to be visible on a sub-second dashboard query.

The small tenant's query plan still correctly prunes to the tiny set of files containing their data; the cost lives entirely in the **traversal of the manifest list to find those files**. This is invisible in the query plan itself (the file-read count is unchanged), but appears as elevated `analysisTime` / `planTime` in the HTTP event listener payload.

**Fix:** the right structural intervention is **migrating the enterprise tenant into a dedicated table** (the "Safe cutover sequence" earlier in this resource). Once the enterprise tenant's files live in `iceberg.analytics.acme_events` rather than `iceberg.analytics.events`, the shared table's manifest list shrinks back to its pre-enterprise size and small-tenant query planning returns to its baseline latency. The dedicated table has its own (small) manifest list dedicated to one tenant's queries.

**Mechanism 2 — Shared maintenance jobs (compaction, snapshot expiry, orphan cleanup) now iterate over the enterprise tenant's much larger file sets.**

`rewrite_data_files` / `EXECUTE optimize`, `expire_snapshots`, and `remove_orphan_files` all walk the table's file metadata to do their work. Compaction iterates over candidate small files; snapshot expiry walks every historical snapshot's manifests; orphan-file cleanup walks the MinIO prefix and compares against live manifests. **All three procedures now have an enterprise-tenant-sized scope** even when the small tenants' partitions don't need any maintenance.

The result: maintenance jobs that used to run in 5 minutes now run in 30; weekly compaction windows that fit comfortably overnight now spill into the business day; the cluster's Trino workers that run the maintenance jobs are unavailable to serve query traffic while the jobs are in flight. Even though the small tenants' partitions are untouched, the **workers** are busy compacting and cleaning the enterprise tenant's files, and small-tenant queries queue waiting for an available worker slot.

**Fix:** the same dedicated-table migration that fixes mechanism 1 ALSO fixes mechanism 2 — once the enterprise tenant lives in its own table, its compaction and snapshot-expiry jobs operate on its own table independently of the shared table's maintenance schedule. The shared table's maintenance returns to its pre-enterprise duration. Optionally, schedule the enterprise tenant's maintenance during off-business-hours windows (e.g., 2am–6am local) so that even within the dedicated table, the maintenance overhead doesn't compete with query traffic.

**Mechanism 3 — No per-tenant resource group quota — enterprise queries saturate cluster CPU.**

This is the runtime-side counterpart to mechanism 2. Even if storage is perfectly isolated (mechanism 1 + 2 fixed via dedicated tables), all tenants still share the **same Trino cluster** — the same workers, the same CPU, the same memory. An enterprise tenant running a 12-month full-history aggregation query against their dedicated table can pin every available worker core at 100% for the duration of the scan, queueing every small-tenant dashboard query behind it. The small-tenant query never gets to run until the enterprise query's slot frees up.

The defining symptom: small-tenant queries that used to return in 200ms now spend most of their wall-clock time in the `QUEUED` state, not `RUNNING`. Examining `system.runtime.queries` shows them sitting in `QUEUED` with `queued_time_ms` dominating the total. The query plan itself is still fast (when it finally gets to run); the latency lives in waiting for a worker slot.

**Fix:** **Trino resource groups** (`etc/resource-groups.json`) — configure a separate subgroup for enterprise tenants with bounded `hardConcurrencyLimit`, `softMemoryLimit`, and `hardCpuLimit`, plus selectors that route enterprise principals into that subgroup. Small tenants land in their own subgroup with their own quotas and never compete for cluster slots with enterprise queries. See the "Resource groups JSON" section immediately below for the full configuration shape (including the exact property names — using invented names like `maxRunning` silently disables every limit).

**Three mechanisms, three fixes — and they are usually all needed for a heavy tenant.** Mechanism 1 + 2 are storage-layer interventions (dedicated table migration); mechanism 3 is compute-layer (resource groups). They are **complementary, not alternative** — migrating to a dedicated table fixes storage contention but does nothing for CPU contention, because all tenants still share the same Trino cluster regardless of which table their data lives in. Similarly, resource groups alone fix CPU contention but do nothing for the manifest-list growth or shared-maintenance costs that come from storing the enterprise tenant in the shared table. **For an enterprise tenant whose workload would otherwise dominate the cluster, expect to apply both: migrate them to a dedicated table AND route them into a dedicated resource group queue.**

---

The mitigation on Trino is **resource groups** (a Trino configuration that creates named query-admission queues — each group has caps on how much cluster CPU/memory it can use and how many of its queries can run at once; queries that exceed the caps wait in the queue instead of choking the cluster): a configuration that caps CPU, memory, and concurrent queries per tenant (or per role). You define groups in `etc/resource-groups.json` on the coordinator, e.g., "tenant Acme can use at most 20% of cluster memory and run at most 5 concurrent queries." This keeps a noisy tenant from starving the rest. For deep isolation needs, you can also run separate Trino clusters per tenant tier (e.g., one cluster for free-tier shared usage, one for enterprise customers), all reading from the same Iceberg tables in MinIO.

> **RESOURCE GROUP SELECTORS MATCH JWT PRINCIPAL NAMES, NOT TRINO ROLE NAMES.** In `resource-groups.json`, the `"user"` field in a selector is matched against the **connection's JWT principal** (the `sub` claim or username field from the JWT token) — it is NOT matched against a Trino role name. If the production stack uses JWT authentication (which it does), each tenant's service account authenticates with a JWT whose subject is the service account name (e.g., `acme-service-account`). Configure selectors to match that username: `"user": "acme-service-account"`, not `"user": "acme_role"`. If you configure the selector to match the role name and the JWT principal is different, the resource group silently never applies — the noisy tenant is uncapped and the isolation appears to work in tests but fails in production.

### Resource groups JSON — use the correct property names

> **CRITICAL — the JSON file alone is INERT until you register it.** Writing `etc/resource-groups.json` is necessary but not sufficient. Trino does not auto-discover the file from its filename or location — you must explicitly tell Trino to use the file-based resource group manager by creating a **NEW, SEPARATE file** named `etc/resource-groups.properties` on the coordinator with these two lines:
>
> ```properties
> # Create a NEW file: etc/resource-groups.properties on the Trino coordinator
> # (this is a SEPARATE file from etc/config.properties — do NOT merge them)
> resource-groups.configuration-manager=file
> resource-groups.config-file=etc/resource-groups.json
> ```
>
> **Common mistake — these two lines go in `etc/resource-groups.properties`, NOT `etc/config.properties`.** If you add `resource-groups.configuration-manager=file` to `etc/config.properties`, Trino will start successfully with no error message, but it will silently ignore the resource group configuration entirely — the resource group manager never loads, the JSON file is never read, and every query runs under the default unlimited group. The Trino coordinator boots cleanly, the JSON sits on disk, all selectors appear correctly configured, and yet no caps apply. This is the single most common "the JSON looks right but the limits aren't applying" misconfiguration.
>
> Why this works the way it does: `etc/config.properties` is reserved for Trino node-level settings (HTTP server port, coordinator/worker flags, JVM-tuning toggles). The resource-groups property names are not recognized in that file and are silently dropped. The resource-group manager only initializes when it finds its own dedicated `etc/resource-groups.properties` file at startup.
>
> Verify both files exist on the coordinator before debugging the JSON content:
>
> ```bash
> # On the coordinator pod — both files MUST be present.
> ls etc/config.properties               # Trino node settings (already there)
> ls etc/resource-groups.properties      # Resource group manager pointer (NEW file you create)
> ls etc/resource-groups.json            # The actual group definitions
> ```
>
> If `etc/resource-groups.properties` does not exist, the JSON is dead config — no error, no warning, just silent inertia.

This is the single most common config bug for resource groups: engineers invent property names like `maxRunning`, `maxMemoryPercent`, `maxCpuPercent`, or `queues`. **Those names do not exist in Trino** — the config file will load (Trino does not strictly validate unknown keys) but the limits will silently never apply. Use the exact property names from the [Trino resource groups docs](https://trino.io/docs/current/admin/resource-groups.html):

| Correct Trino property | Type | What it caps | Common WRONG name to avoid |
|---|---|---|---|
| `hardConcurrencyLimit` | integer | Max queries running concurrently in this group | ~~`maxRunning`~~ |
| `softMemoryLimit` | string (`"10GB"` or `"20%"`) | Soft memory cap; new queries queue when exceeded | ~~`maxMemoryPercent`~~ |
| `maxQueued` | integer | Max queries that can wait in the queue | (correct as-is) |
| `subGroups` | array of nested group objects | Child groups for hierarchical limits | ~~`queues`~~ |
| `hardCpuLimit` / `softCpuLimit` | duration string (`"1h"`, `"30m"`) | CPU-time cap per rolling window (NOT a percentage); window length set by root-level `cpuQuotaPeriod` | ~~`cpuLimit`~~ (does NOT exist — common mistake), ~~`maxCpuPercent`~~ (Trino has no such field) |
| `cpuQuotaPeriod` (root level only) | duration string (`"1h"`, `"15m"`) | Length of the rolling window for `softCpuLimit`/`hardCpuLimit`. Set ONCE at the root of the JSON, not per group. | — |

> **COMMON MISTAKE — `cpuLimit` is not a valid Trino field.** Engineers frequently write `"cpuLimit": "1h"` in `resource-groups.json`, expecting it to cap aggregate CPU. **That field does not exist in Trino.** The hard cap is `hardCpuLimit` (refuses new query admission once exceeded), and the soft cap is `softCpuLimit` (throttles by reducing effective concurrency rather than rejecting). Trino silently ignores unknown JSON keys, so the typo loads without error and provides ZERO protection — the cluster sees no cap. Always use `hardCpuLimit` / `softCpuLimit`, paired with a root-level `cpuQuotaPeriod` that defines the rolling window length.

**Selector field name warning — `"user"` is a regex, but the field is NOT called `"userRegex"`:**

The selector field that matches the JWT principal is named **`"user"`** in Trino's resource-groups.json — not `"userRegex"`. The value is *interpreted as a Java regex*, which makes the name confusing, but the key itself is always `"user"`. `"userRegex"` does not exist in Trino and will be silently ignored:

```json
// CORRECT — field name is "user", value is a Java regex
{ "user": "acme-service-account", "group": "global.tenant_acme" }
{ "user": "tenant-.*",            "group": "global.tenants" }  // regex matching multiple tenants

// WRONG — "userRegex" is not a valid Trino selector field; silently ignored
{ "userRegex": "acme-service-account", "group": "global.tenant_acme" }
```

**The complete two-file layout — both files are required, side-by-side, in the Trino coordinator's `etc/` directory.** A common copy-paste mistake is to put the JSON content directly inside `etc/resource-groups.properties` (because the JSON looks like the "real" config and the properties file looks like a stub). That fails silently — `etc/resource-groups.properties` is a Java properties file that must contain ONLY key=value lines, not JSON. Below are both files shown in full as you would lay them on disk:

**File 1: `etc/resource-groups.properties`** (Java properties — exactly two lines; this is the pointer that registers the JSON file with Trino):

```properties
# etc/resource-groups.properties — Java properties format, NOT JSON.
# Only these two key=value lines belong here. Adding JSON to this file
# is a parse error; Trino fails to load the resource-group manager.
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**File 2: `etc/resource-groups.json`** (the actual JSON config with `rootGroups`, `subGroups`, and `selectors`).

> **STARTER SNIPPET — every field is the EXACT name Trino expects.** Copy this as your starting point and rename groups/selectors to fit your tenants. Every field below is a real Trino key — there are no placeholders. The most-confused field names are flagged inline.

```json
{
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "80%",
      "hardConcurrencyLimit": 100,
      "maxQueued": 200,
      "softCpuLimit": "1h",
      "hardCpuLimit": "2h",
      "schedulingPolicy": "fair",
      "subGroups": [
        {
          "name": "analytics",
          "softMemoryLimit": "40%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 20,
          "hardCpuLimit": "30m"
        },
        {
          "name": "dashboard",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 10,
          "maxQueued": 50
        }
      ]
    }
  ],
  "selectors": [
    {
      "group": "global.analytics",
      "user": "analytics_.*"
    },
    {
      "group": "global.dashboard",
      "source": "trino-gateway-dashboard"
    },
    {
      "group": "global"
    }
  ]
}
```

> **What the `selectors` array does — and why omitting it makes every limit a no-op.** The `selectors` array routes incoming queries to resource groups based on the **submitting user, the client `source` string, the query text, query type, user groups, etc.** Each entry has a `"group"` (the destination, dot-separated path like `"global.analytics"`) plus zero-or-more matcher fields. **Without a `selectors` block, no queries are assigned to any group — the limits sit in the JSON but have zero effect at runtime; every query runs unlimited.** This is one of the most common "I configured the limits but they aren't applying" misconfigurations. In the snippet above:
> - Queries from users matching `analytics_.*` (e.g., `analytics_batch_job`, `analytics_etl`) land in `global.analytics` with the batch caps (5 concurrent, 30m CPU).
> - Queries with the client-set `source` string `trino-gateway-dashboard` (set via `X-Trino-Source` header or `--source` CLI flag) land in `global.dashboard` with the interactive caps (10 concurrent).
> - **The trailing `{"group": "global"}` with NO matcher fields is the catch-all fallback** — any query that didn't match the earlier selectors lands at the root `global` group. Without this fallback, queries that don't match any selector are **rejected with `QUERY_REJECTED: No matching resource group found`** — leave the unconditional fallback in place to avoid that failure mode.
>
> **Selector evaluation is top-down, first-match-wins.** Put more-specific selectors (single tenant, specific source) above broader ones. If the catch-all `{"group": "global"}` were first, it would swallow every query and the per-tenant routing below would never fire.

> **Field-name cheat sheet (these are the names engineers most commonly get wrong):**
> - **`hardConcurrencyLimit`** — integer count of queries that may run concurrently in the group. NOT `concurrencyLimit`, NOT `maxRunning`.
> - **`softMemoryLimit`** — percentage (`"80%"`) of cluster memory OR absolute bytes (`"10GB"`). NOT `memoryLimit`, NOT `maxMemoryPercent`.
> - **`maxQueued`** — integer count of queries that can sit in the queue before new submissions are rejected with `QUERY_QUEUE_FULL`. Once this is hit, the next query gets an immediate error rather than waiting. (The name happens to be correct as-is — no common misnomer.)
> - **`hardCpuLimit`** / **`softCpuLimit`** — time-window CPU budget formatted as duration strings (`"1h"`, `"30m"`, `"500ms"`). NOT `cpuLimit` (that field does not exist). Pair with root-level `"cpuQuotaPeriod": "1h"` to define the rolling window length.
> - **`schedulingPolicy`** — one of `"fair"` (default round-robin), `"weighted"`, `"weighted_fair"`, or `"query_priority"`. Required at the parent if subgroups use `schedulingWeight`; otherwise the weights are silently ignored.
> - **`"user"` in selectors** — value is interpreted as a Java regex matching the submitting username. **The field is literally named `"user"`, NOT `"userRegex"`** (despite the value being a regex). Trino Gateway's separate routing-rules JSON uses `userRegex`/`sourceRegex` — those are a different schema. The core Trino `etc/resource-groups.json` uses `"user"` and `"source"` (no `Regex` suffix). The catch-all selector at the bottom of the list (`{"group": "global"}` in the snippet) has NO matchers and acts as a fallback.
> - **`"source"` in selectors** — Java regex matching the client `source` string (set by the client via the `X-Trino-Source` HTTP header or the `--source` flag on the CLI). Used to distinguish workload classes that share a user — e.g., the same service principal might submit both dashboard queries (`source = "trino-gateway-dashboard"`) and batch jobs (`source = "airflow"`).

The minimal layout above protects against runaway CPU (the global `hardCpuLimit: "2h"` per rolling window) AND runaway query count (the global `hardConcurrencyLimit: 100` plus `maxQueued: 200`) AND lets you isolate two workload classes (`analytics` for batch, `dashboard` for interactive). Once this is in place, you can subdivide further (per-tenant subgroups under `dashboard`) without restructuring the top-level shape.

Minimal example to ground the layout for the more-detailed multi-tenant version below:

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "subGroups": [
      {"name": "tenant_acme", "softMemoryLimit": "20%", "hardConcurrencyLimit": 5},
      {"name": "tenant_beta", "softMemoryLimit": "20%", "hardConcurrencyLimit": 5}
    ]
  }],
  "selectors": [
    {"user": "acme-service-account", "group": "global.tenant_acme"},
    {"user": "beta-service-account", "group": "global.tenant_beta"}
  ]
}
```

**Working `etc/resource-groups.json` for a multi-tenant cluster (full version with CPU caps, sub-groups, and weighted-fair scheduling):**

```json
{
  "cpuQuotaPeriod": "1h",
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "80%",
      "hardConcurrencyLimit": 100,
      "maxQueued": 1000,
      "schedulingPolicy": "weighted_fair",
      "subGroups": [
        {
          "name": "tenant_acme",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50,
          "schedulingPolicy": "weighted_fair",
          "subGroups": [
            { "name": "dashboards", "softMemoryLimit": "10%", "hardConcurrencyLimit": 4, "maxQueued": 40, "schedulingWeight": 10 },
            { "name": "exports",    "softMemoryLimit": "15%", "hardConcurrencyLimit": 1, "maxQueued": 10, "schedulingWeight": 1  }
          ]
        },
        {
          "name": "tenant_beta",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50
        },
        {
          "name": "enterprise_tenant",
          "softMemoryLimit": "40%",
          "hardConcurrencyLimit": 10,
          "maxQueued": 100,
          "softCpuLimit": "2h",
          "hardCpuLimit": "3h"
        },
        {
          "name": "internal_admin",
          "softMemoryLimit": "40%",
          "hardConcurrencyLimit": 10,
          "maxQueued": 100
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "acme-service-account",
      "source": ".*dashboard.*",
      "group": "global.tenant_acme.dashboards"
    },
    {
      "user": "acme-service-account",
      "source": ".*export.*",
      "group": "global.tenant_acme.exports"
    },
    {
      "user": "acme-service-account",
      "group": "global.tenant_acme.dashboards"
    },
    {
      "user": "beta-service-account",
      "group": "global.tenant_beta"
    },
    {
      "user": "data-team",
      "group": "global.internal_admin"
    }
  ]
}
```

> **`softCpuLimit` / `hardCpuLimit` — capping CPU time, not just memory and concurrency.** The `enterprise_tenant` group in the example above adds two CPU-time fields that the other groups omit: `softCpuLimit: "2h"` and `hardCpuLimit: "3h"`. These cap the **total CPU time** the group's queries are allowed to consume within a rolling window. CPU limits are NOT a percentage; they are durations (`"2h"`, `"30m"`, `"500ms"`) measured as wall-clock CPU time aggregated across all workers. The rolling window length is set by `cpuQuotaPeriod` at the root of the JSON (`"cpuQuotaPeriod": "1h"` in the example). When the group's queries collectively consume more CPU than `softCpuLimit` within one window, Trino reduces their `hardConcurrencyLimit` proportionally (slowing them down but still admitting); when they cross `hardCpuLimit`, Trino refuses to admit new queries from the group until the window rolls over.
>
> **When CPU limits matter (and when memory + concurrency alone are not enough).** An enterprise tenant running CPU-intensive analytics — a Spark-style aggregation over 100M rows, a wide JOIN with hash-rebuild, regex-heavy `LIKE '%...%'` scans — can hold their `hardConcurrencyLimit` of 10 slots **continuously**, each slot pegging a worker core at 100% for 20 minutes. Memory limits don't help because the queries respect `softMemoryLimit`; concurrency limits don't help because they're already inside the cap (10 slots, used continuously). The cluster's CPU is fully saturated by the one tenant despite all per-group limits being honored. `hardCpuLimit: "3h"` is what stops that pattern: once the tenant burns 3 CPU-hours in the rolling 1-hour window, their next query queues until the window advances. Use CPU limits specifically when one tenant runs **CPU-intensive analytics** (long aggregations, heavy compaction jobs, wide JOINs) and other tenants need protection from sustained CPU starvation, not just spike protection.
>
> **Selector evaluation order — first match wins, top to bottom.** Selectors are evaluated **top-down**; the **first matching selector wins** and Trino stops looking. Put **more-specific selectors** (single tenant match, e.g., `"user": "acme-service-account"`) **before catch-all patterns** (e.g., `"user": ".*"` or any regex that matches multiple tenants). If you put the catch-all first, every query lands in the catch-all group and the per-tenant selectors below it are never reached. In the example above, the two `source`-filtered selectors for `acme-service-account` must come before the unconditional `acme-service-account` selector for the same reason — the unconditional one would otherwise swallow every Acme query, and the `dashboards`/`exports` routing would silently never apply.

> **`schedulingPolicy: "weighted_fair"` — why dashboards and exports need it.** When the same tenant runs both quick dashboard queries (sub-second) and long-running export queries (a 12-month CSV export that takes 20 minutes), they compete for the same group's concurrency slots. Without a scheduling policy, Trino's default FIFO admission can let one in-flight export occupy the slot for 20 minutes while every dashboard query queues behind it — a single export starves the tenant's interactive workload. Setting `"schedulingPolicy": "weighted_fair"` on the parent group (with `schedulingWeight` on each child subgroup) tells Trino to admit queries proportionally to their weight when there's contention: in the config above, the `dashboards` subgroup has weight 10 and the `exports` subgroup has weight 1, so the scheduler hands out roughly 10 dashboard slots for every 1 export slot when both groups have queued work. The export still runs — it just no longer blocks the interactive dashboards. The `weighted_fair` policy is also what allows short queries to be scheduled ahead of long-running ones inside a single group when subgroup weights are set, preventing a 12-month export from starving quick dashboard calls from the same tenant.

> **Alternative: `schedulingPolicy: "query_priority"` — deterministic FIFO with per-query priority.** If your team prefers explicit, deterministic ordering over weight-based proportional admission, set `"schedulingPolicy": "query_priority"` on the group. Trino then admits queued queries in strict FIFO order, but sorted by each query's `query_priority` session property (higher value runs first; ties break by submission time). For example, an interactive dashboard query can set `SET SESSION query_priority = 10` while a scheduled nightly report sets `SET SESSION query_priority = 1` — the dashboard query always jumps ahead in the queue regardless of arrival order. This is simpler than `weighted_fair` for teams that want **per-query priority control** rather than **per-subgroup weight allocation**: there are no subgroup weights to balance, and the behavior is easy to reason about (highest-priority query in the queue runs next). Use it when query importance is a property of the workload itself (interactive vs. scheduled) rather than of the tenant tier (premium vs. free) — for tenant-tier isolation, `weighted_fair` is still the better fit.

> **`schedulingWeight` is INERT unless the PARENT group's `schedulingPolicy` is `"weighted"` or `"weighted_fair"`.** A common configuration bug: engineers set `schedulingWeight: 10` on the `dashboards` subgroup and `schedulingWeight: 1` on the `exports` subgroup, but forget to set `schedulingPolicy` on the parent group at all. Trino's **default scheduling policy is `"fair"`** (round-robin admission across subgroups), and `"fair"` **ignores `schedulingWeight` entirely** — every subgroup gets equal admission share regardless of the weight you assigned. The config loads cleanly, the JSON validates, and the weights you set silently do nothing. **The rule: any time subgroups under a parent have non-uniform `schedulingWeight` values, you MUST set `"schedulingPolicy": "weighted"` (or `"weighted_fair"`) on the parent group, or the weights are dead config.** The full list of valid `schedulingPolicy` values is `"fair"` (default, round-robin, ignores weights), `"weighted"` (admits proportionally to `schedulingWeight`, FIFO within each subgroup), `"weighted_fair"` (admits proportionally to `schedulingWeight`, prefers subgroups with fewer running queries — best when you want both weight-fairness and short-query preference), and `"query_priority"` (admits in `query_priority` session-property order — rarely the right choice for tenant-isolation use cases). For the dashboards-vs-exports example, `"weighted_fair"` is the recommended choice.

> **`schedulingWeight` — concrete tenant-tier example.** When `schedulingPolicy` on a parent group is set to `"weighted"`, each sub-group uses a `schedulingWeight` integer to control its relative share of slots. Example:
>
> ```json
> { "name": "premium_tenants", "schedulingWeight": 3, ... }
> { "name": "free_tenants",    "schedulingWeight": 1, ... }
> ```
>
> This gives `premium_tenants` 3x the query slots of `free_tenants` when both are competing for the parent's available slots. The `"weighted_fair"` policy also respects these weights while preventing complete starvation of low-weight groups (the `free_tenants` queue will still drain, just more slowly under contention).

> **Per-query memory cap — `query.max-memory-per-node` is the defense-in-depth companion to `softMemoryLimit`.** `softMemoryLimit` on a resource group limits **total memory across all queries in the group** (e.g., the sum across every concurrent query that landed in `global.tenant_acme`). As a defense-in-depth companion, `query.max-memory-per-node` (set in `etc/config.properties` on each node, NOT in `resource-groups.json`) caps memory per **individual query** per worker node. This prevents a single runaway query from hitting the group limit before admission control can queue it — without it, one tenant's pathological JOIN can blow past the per-node memory budget in milliseconds and OOM-kill the worker before the group-level `softMemoryLimit` accounting catches up. Set both: the group cap bounds the tenant's aggregate footprint; the per-query cap bounds any single query's worst case.

> **DEPLOYMENT TIMING: file-based resource group config requires a Trino coordinator restart to take effect. It is NOT hot-reloaded.** Editing `etc/resource-groups.json` (or `etc/resource-groups.properties`) on a running coordinator changes nothing until you bounce the coordinator pod. There is no file-watcher, no `RELOAD` SQL command, and no admin endpoint that re-reads the file. Engineers routinely push a tightened limit during an incident, see the noisy tenant continue to exceed it, and waste 20 minutes debugging "the wrong" JSON before realizing the coordinator never re-read the file.
>
> Key operational consequences:
>
> - **Changes affect only NEW queries submitted after the restart.** Queries already running when the coordinator restarts continue under the **old** limits until they finish (or the worker process terminates them). A tenant who is mid-incident, holding 80% of cluster memory with a runaway query, will keep holding it through the restart — the new `softMemoryLimit` only constrains their *next* query.
> - **This is precisely why the live-incident sequence is: kill first, then restart.** During an active noisy-neighbor incident:
>   1. Kill the offending query with `CALL system.runtime.kill_query(...)` — gives you immediate relief, returns cluster resources right now.
>   2. Push the updated `resource-groups.json` to the ConfigMap and restart the coordinator pod — prevents the same tenant from submitting another unbounded query in the next 30 seconds.
>   Skipping step 1 and only restarting does nothing for the in-flight runaway query — the new limit cannot retroactively cap a query that's already running.
> - **Restart blast radius — coordinator restart KILLS ALL in-flight queries.** A Trino coordinator restart causes **every** currently-running query on the cluster to be **immediately terminated with an error** — there is no graceful drain, no in-flight query continues past the restart, and there is no way to checkpoint and resume. Clients see `connection refused` (or `coordinator unavailable` / `server restarted`) for **30–60 seconds** until the new coordinator pod becomes Ready and starts accepting connections again. Tenant dashboards mid-render fail, long-running exports abort entirely (they do not resume — the client must re-submit from scratch), and any client without retry logic surfaces the error directly to its end user. **Plan this for a low-traffic maintenance window — overnight or weekends in the cluster's primary timezone — and notify affected teams before restarting.** During an active incident, accept the blast radius as the cost of stopping the leak; outside an incident, treat coordinator restart as a planned maintenance event, not an ad-hoc push.
>
> **Concrete restart command on the production stack (Kubernetes).** Since the production stack runs Trino on Kubernetes, the restart is a `kubectl rollout restart` against the coordinator Deployment:
>
> ```bash
> # Rolling restart of the Trino coordinator. Kubernetes terminates the existing
> # pod, the new pod re-reads etc/resource-groups.json (mounted from a ConfigMap)
> # at startup, and the new limits take effect for queries submitted after the
> # new pod is Ready.
> kubectl rollout restart deployment/trino-coordinator -n trino
>
> # Watch the rollout to know when the new coordinator is serving:
> kubectl rollout status deployment/trino-coordinator -n trino
> ```
>
> Adjust the deployment name and namespace to match your cluster (some teams name it `trino` or `trino-coord`; the namespace is whatever your Trino Helm chart installed into). The rollout takes 10-30 seconds end-to-end; clients see connection errors during the window and should reconnect.
>
> > **WARNING — `kubectl rollout restart` KILLS ALL in-flight queries on the cluster.** Restarting the Trino coordinator immediately terminates **every** currently-running query with a `server restarted` (or `coordinator unavailable`) error — tenant dashboards mid-render fail, long-running exports abort entirely, and any client without retry logic surfaces the error to its end user. Clients see `connection refused` for **30–60 seconds** while the new pod initializes. **Plan this for a low-traffic maintenance window — overnight or weekends in the cluster's primary timezone — and notify affected teams before restarting** (status page, Slack channel, whatever tenant-notification channel your stack provides). During an active incident — when stopping a noisy-neighbor's leak is more important than preserving in-flight queries — accept the blast radius as the cost of fast mitigation; outside an incident, treat the restart as a planned maintenance event, not an ad-hoc push.
>
> **Alternative for hot-reload: the database-backed resource group manager (`resource-groups.configuration-manager=db`).** Trino ships a database-backed resource group manager that stores group definitions and selectors in a relational database (Postgres or MySQL). It **re-reads the configuration every 1 second by default** (tunable via `resource-groups.refresh-interval`), so changes to the limits take effect within seconds — no coordinator restart required. Teams that need to tune per-tenant caps frequently (e.g., onboarding a new tenant, adjusting limits in response to traffic patterns, or running automated cost-management policies) should prefer the `db` manager over the file-based one specifically for this hot-reload property. The tradeoff is one extra dependency (a small Postgres/MySQL instance dedicated to resource-group config) and the operational complexity of keeping that database highly available — but on a cluster where resource-group tuning is part of the routine workload, the absence of restart windows usually pays for that cost.
>
> Configuration switch in `etc/resource-groups.properties`:
>
> ```properties
> # File-based (default) — requires coordinator restart on every change.
> resource-groups.configuration-manager=file
> resource-groups.config-file=etc/resource-groups.json
>
> # Database-backed — hot-reloads every 1 second from the configured DB.
> # resource-groups.configuration-manager=db
> # resource-groups.config-db-url=jdbc:postgresql://rg-config-db:5432/trino_rg
> # resource-groups.config-db-user=trino_rg
> # resource-groups.config-db-password=...
> # resource-groups.refresh-interval=1s
> ```

> **Immediate-relief tool during a live noisy-neighbor incident:** resource group config changes require a coordinator config push and (depending on the resource group manager) may take effect only for *new* queries. While the new limits are being deployed, kill the offending live query directly:
>
> ```sql
> -- Run as an admin user in Trino. Replace the query_id with the one you see in the
> -- coordinator UI or in `SELECT query_id, user, state, query FROM system.runtime.queries`.
> CALL system.runtime.kill_query(
>   query_id => '20260524_134522_00123_abcde',
>   message  => 'Throttling noisy query — see incident #4421'
> );
> ```
>
> This terminates the running query immediately and returns the cluster resources. Use it as your first action when one tenant is starving the cluster, *then* deploy the resource-groups.json change to prevent the next occurrence. `system.runtime.kill_query` is the live-incident tool; resource groups are the prevention tool.
>
> **`kill_query` requires admin-level authorization in OPA — tenant principals CANNOT kill each other's queries.** `CALL system.runtime.kill_query(...)` is a privileged Trino operation: it terminates somebody else's running work, and the Trino OPA plugin checks this as a `queryType` action (specifically, the `ExecuteQuery` action on the `system.runtime.kill_query` procedure plus the implicit "kill another user's query" capability). On the production stack, only principals mapped to the platform-admin role (incident responders, on-call SREs, the data-platform team) have the OPA policy permissions to execute `kill_query`. A tenant service-account principal (e.g., `acme-service-account`) running `CALL system.runtime.kill_query(...)` against another tenant's query will be denied at the OPA evaluation step with `Access Denied` — they cannot weaponize this primitive against neighbors. This is the correct security posture: live-incident query termination is an admin-only operational capability, not a tenant-facing self-service feature. (Do **not** attempt to write the specific OPA Rego policy here — that lives in the external governance document referenced by `prod_info.md`. The teaching point for application engineers is the access-control shape, not the policy code.)
>
> **Finding which resource group a running query is in — use the `resource_group_id` column.** `system.runtime.queries` exposes a `resource_group_id` column that directly shows the resource group path each running query was assigned to. This is the fastest way to diagnose "is the selector matching what I expect?" during an incident — you do not have to guess from the username:
>
> ```sql
> -- Shows every running and queued query along with the resource group
> -- path the selector matched (e.g., ARRAY['global', 'tenant_acme']). If a
> -- tenant's queries are landing in ARRAY['global'] instead of
> -- ARRAY['global', 'tenant_acme'], the selector regex or username mapping
> -- is wrong.
> --
> -- TYPE NOTE: in Trino 467, `resource_group_id` is of type `array(varchar)`,
> -- NOT a plain varchar / dotted string. The column contains the full group
> -- path as an ordered array of path segments — `ARRAY['global', 'tenant_acme']`
> -- rather than the string `'global.tenant_acme'`. This matters for filtering
> -- (see the filter example below) and for any downstream code that expects
> -- to split on dots — there is no dot to split on; the array elements ARE
> -- the path segments.
> SELECT query_id, user, state, resource_group_id
> FROM system.runtime.queries
> WHERE state IN ('RUNNING', 'QUEUED')
> ORDER BY created DESC;
> ```
>
> The `resource_group_id` value is the full group path as an array (e.g., `ARRAY['global', 'tenant_acme']`). If you see queries from `acme-service-account` landing in `ARRAY['global']` rather than `ARRAY['global', 'tenant_acme']`, your selector did not match — typically because the JWT principal does not exactly match the selector's `"user"` regex.
>
> **Filtering on `resource_group_id` — use array equality, not string equality.** Because the column is `array(varchar)`, the natural-looking filter `WHERE resource_group_id = 'global.free_tier'` is a **type error** (comparing array to varchar), and even if it parsed it would never match anything. Use array literal syntax:
>
> ```sql
> -- WRONG — type mismatch; will fail at analysis time, or silently match nothing.
> SELECT query_id, user, state
> FROM system.runtime.queries
> WHERE resource_group_id = 'global.free_tier';
>
> -- CORRECT — array literal compares element-by-element against the array column.
> SELECT query_id, user, state
> FROM system.runtime.queries
> WHERE resource_group_id = ARRAY['global', 'free_tier'];
>
> -- Also useful: filter by a prefix segment (any subgroup under 'global') using
> -- element access — Trino arrays are 1-indexed.
> SELECT query_id, user, state, resource_group_id
> FROM system.runtime.queries
> WHERE resource_group_id[1] = 'global'
>   AND cardinality(resource_group_id) >= 2
>   AND resource_group_id[2] LIKE 'tenant_%';
> ```

---

## Large tenant data export (SELECT * timing out)

When a large tenant asks for a full data export — "give me all our events data" — a naive `SELECT *` through the application layer will time out. The right approach is to run the export as a Trino job that writes directly to MinIO, then hand the customer the resulting files.

### Engine note: INSERT INTO ... SELECT for bulk exports runs in Trino 467, not Spark

This is a common point of confusion. When you write:

```sql
INSERT INTO iceberg.exports.acme_events_20260524
SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

This is a **Trino** SQL statement. Trino distributes the read across its worker nodes, applies the partition pruning for `tenant_id = 'acme'` (reading only Acme's Parquet files), and writes the results as new Parquet files to MinIO via the Iceberg connector. This is **not** a Spark operation — do not confuse it with Spark JDBC ingestion jobs, which use a completely different code path. The resulting files land in MinIO under the new table's prefix.

### Step-by-step export pattern

**Step 1: Create the export table**

```sql
-- Run in Trino
CREATE TABLE iceberg.exports.acme_events_20260524 (
  -- Trino 467 supports INCLUDING PROPERTIES (NOT `INCLUDING ALL`, which is a
  -- different dialect's grammar and a parse-time error in Trino).
  LIKE iceberg.analytics.events INCLUDING PROPERTIES
)
WITH (
  location = 's3a://lakehouse/exports/acme/events/20260524/',
  format  = 'PARQUET'
);
```

**Step 2: Write the data (Trino INSERT INTO ... SELECT)**

```sql
-- Still Trino. Trino reads from analytics.events (partition-pruned to Acme's files)
-- and writes Parquet files to MinIO under the exports prefix.
INSERT INTO iceberg.exports.acme_events_20260524
SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

For a large tenant (100M+ events), this query can take minutes. To avoid Trino gateway timeouts:
- Increase the Trino coordinator's `query.max-execution-time` for this session (e.g., `SET SESSION query_max_execution_time = '4h'`).
- Or submit it as a background job via the Trino REST API (`POST /v1/statement`, poll `/v1/query/{queryId}`).

**Step 2b: Row-count integrity handshake (MANDATORY before handoff)**

Before handing the export to the customer, verify the export-table row count matches the source-table row count at the same snapshot:

```sql
-- Run BOTH counts back-to-back. They MUST be exactly equal.
-- For point-in-time consistency, capture the source snapshot id first and
-- pin the source-side count to it via FOR VERSION AS OF, so any concurrent
-- writes after the INSERT INTO ... SELECT started don't perturb the
-- comparison.
SELECT COUNT(*) AS export_count
FROM iceberg.exports.acme_events_20260524;

SELECT COUNT(*) AS source_count
FROM iceberg.analytics.events
WHERE tenant_id = 'acme';
```

`SELECT COUNT(*) FROM iceberg.exports.acme_events_20260524` MUST equal `SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme'` taken at the same snapshot. **If counts differ by even one row, ABORT and re-run the export** — a silently-truncated export from a Trino worker crash, a partial commit, or a planner-side filter mistake is the failure mode this check catches. The export-table row count is the only thing you hand to the customer; if it's short by 47 rows out of 12M, neither you nor the customer will ever notice until a regulator audits the export and finds the discrepancy. Treat the handshake mismatch the same way you would treat a CI failure on the migration sequence — block the workflow at this step.

For an even tighter check, also compare a checksum/hash on a stable key column (the same belt-and-suspenders pattern used in the tenant migration sequence earlier in this resource):

```sql
SELECT SUM(event_id) AS export_sum
FROM iceberg.exports.acme_events_20260524;

SELECT SUM(event_id) AS source_sum
FROM iceberg.analytics.events
WHERE tenant_id = 'acme';
```

Equal sums confirm the same row identities (not just the same row count). Both checks must pass before the export is considered ready to ship.

**Step 3: Download from MinIO**

Once the INSERT succeeds, the Parquet files are on MinIO. Hand them to the customer using the MinIO client:

```bash
# mc cp (MinIO client) — copies files from MinIO to local disk or directly to the customer's S3 bucket
mc cp --recursive minio/lakehouse/exports/acme/events/20260524/ ./acme_export/
```

Or generate a time-limited pre-signed URL for each file so the customer can download directly from MinIO without needing your credentials:

```bash
mc share download --expire 24h minio/lakehouse/exports/acme/events/20260524/
```

**Step 4: Clean up the export table**

After the customer confirms receipt, drop the export table to free MinIO storage:

```sql
DROP TABLE iceberg.exports.acme_events_20260524;
```

Dropping an Iceberg table via Trino removes the table metadata from the Hive Metastore and — if the table was created with `location` pointing to an isolated prefix — should remove the files from MinIO.

> **DROP TABLE + MinIO file deletion caveat — known open issues on this stack.** On Trino + Hive Metastore + MinIO, `DROP TABLE` *should* remove the export data files, but there are **known open issues** (Trino #5616, Trino #25097) where files can linger on object storage depending on the catalog implementation and Hive Metastore configuration — the metadata is gone but the Parquet bytes stay on MinIO. **Always** follow `DROP TABLE` with an explicit orphan-file sweep on the exports namespace and a bucket-direct audit:
>
> ```sql
> -- After the DROP TABLE above, sweep the exports namespace to remove any
> -- files left behind by the known DROP TABLE issues on this stack.
> -- Run this from a Spark session because Trino enforces a 7-day minimum
> -- retention floor on remove_orphan_files; the Spark form has no floor.
> CALL iceberg.system.remove_orphan_files(
>   table      => 'exports.acme_events_20260524',
>   older_than => current_timestamp()
> );
> ```
>
> Then audit the MinIO bucket directly to confirm zero residual bytes:
>
> ```bash
> # Lists every object under the exports prefix for this customer.
> # Expected output: empty (no files). If anything is listed, the DROP TABLE
> # + remove_orphan_files combination did not fully clean up — investigate
> # before signing off the export ticket.
> mc ls --recursive minio/lakehouse/exports/acme/
> ```
>
> **For a regulator-grade audit, the bucket-direct check is what counts** — do not rely on `DROP TABLE` alone. The 3-line sequence (`DROP TABLE` → `remove_orphan_files` → `mc ls --recursive`) is the only combination that guarantees compliance-grade cleanup on this stack. Treat any residual bytes shown by `mc ls` as an incident, not as expected lag.

### Why SELECT * times out in the application layer

A direct `SELECT *` routed through your application times out for two reasons:
1. **Query timeout**: Application frameworks (Rails, Django, etc.) typically have a database query timeout of 30–60 seconds. A large analytical query runs for minutes.
2. **Memory pressure**: Streaming millions of rows through your application process uses large amounts of RAM. The query may be terminated by the OS or your k8s container memory limit before it completes.

The INSERT INTO ... SELECT pattern avoids both problems by writing results directly to MinIO without passing them through the application layer.

### Freshness note

The export captures a point-in-time snapshot of the data. Iceberg snapshot isolation means new events written after the export started do not appear in the results — which is correct behavior for an export.

---

## GDPR right to erasure — the correct 4-step sequence

When a customer invokes their right to be forgotten (GDPR Article 17, CCPA equivalent), you must guarantee their bytes are **physically gone from MinIO** — not just hidden from queries. This is a place where the obvious workflow (DELETE, verify COUNT = 0, sign off) is **wrong**. After a DELETE, the customer's original Parquet bytes are still sitting on MinIO. You are not GDPR-compliant until you complete all four steps below.

### Why the obvious workflow is wrong

Iceberg uses **MVCC** (multi-version concurrency control — every write creates a new immutable snapshot and the old snapshot is retained so you can time-travel or roll back). A DELETE does not erase Parquet files; it writes a small **delete file** that says "ignore these rows in those Parquet files." The original Parquet files (and the original rows inside them) remain on MinIO, referenced by older snapshots, until you explicitly expire those snapshots. A privacy auditor checking MinIO directly will still find the customer's bytes.

### The 4-step physical-removal sequence

> **REPEAT-FOR-EVERY-TABLE INVARIANT — read this first.** The full 4-step sequence (DELETE → `rewrite_data_files` → `expire_snapshots` → `remove_orphan_files`) must be repeated, in order, for **every** Iceberg table that holds tenant data — not just the `events` table shown in the examples below. A typical SaaS schema has many tables that carry a `tenant_id` (events, orders, users, sessions, invoices, audit_log, ...); each one stores the customer's bytes independently on MinIO, and each one needs its own complete 4-step pass. **Running the sequence on `analytics.events` alone is not GDPR-compliant** — the customer's rows still live physically in the other tables. Maintain an explicit list of tenant-carrying Iceberg tables (treat it as part of your data inventory) and run the 4-step sequence against every entry on the list as one atomic compliance unit. Skipping one table is the most common cause of a "we did the purge but the bytes are still there" finding in a GDPR audit.

Run all four steps, in order, on the production Trino 467 + Iceberg 1.5.2 + Spark + MinIO stack. Steps 2, 3, and 4 are Iceberg maintenance procedures **available from BOTH Spark and Trino 467** — the `CALL iceberg.system.*` syntax shown below is Spark SQL, but every step has an equivalent `ALTER TABLE ... EXECUTE` form in Trino 467 (see the engine-note callout immediately below for the full mapping and the important Trino minimum-retention caveat for zero-day GDPR purges). Most teams run them via the Spark job scheduler (Kubernetes CronJob or Airflow DAG that does a `spark-submit`) because Spark does not enforce Trino's 7-day minimum-retention floor on `expire_snapshots` / `remove_orphan_files`, which the GDPR sequence specifically needs to bypass. The four steps are: (1) `DELETE` the rows, (2) `rewrite_data_files` to compact away delete markers / clean MoR delete files, (3) `expire_snapshots` to retire old snapshot metadata so the data files they referenced become unreferenced, (4) `remove_orphan_files` to sweep MinIO for any file no live snapshot ever referenced (catches partially-failed ingestion artifacts).

> **CATALOG NAME — ENGINE MATTERS:** Steps 2 and 3 use `CALL iceberg.system.*`. The production Spark catalog is named `iceberg` (configured via `spark.sql.catalog.iceberg=org.apache.iceberg.spark.SparkCatalog`). Do NOT use `spark_catalog.system.*` — that catalog name does not exist in this production environment and will produce a "catalog not found" runtime error.

> **ENGINE NOTE — `CALL iceberg.system.*` IS SPARK SQL SYNTAX. THE SAME OPERATIONS ARE FULLY SUPPORTED IN TRINO 467 VIA `ALTER TABLE ... EXECUTE`.** The production stack runs both engines, and the same underlying Iceberg maintenance procedures are available from either one — only the SQL syntax differs. **Do not read "Spark procedure" below as "Spark-only operation"** — that is a common misreading. The operations themselves (`expire_snapshots`, `remove_orphan_files`, `rewrite_data_files`) are Iceberg-level procedures the Iceberg library implements; both Spark and Trino expose them, just with different syntax.
>
> - **Spark SQL syntax** (use when running via `spark-submit` or a Spark SQL session): `CALL iceberg.system.<procedure>(...)`. Pasting these `CALL` statements into a Trino client (DBeaver, `trino` CLI, JDBC) produces a syntax error because Trino's Iceberg connector does not expose the procedures via the `CALL` dispatch.
> - **Trino 467 syntax** (use when running from a Trino session — no `spark-submit` needed): `ALTER TABLE ... EXECUTE <procedure>(...)`. These have been available in the Trino Iceberg connector since Trino 378, so they are fully supported on Trino 467.
>
> The Trino-native equivalents for every step of the GDPR purge sequence:
>
> ```sql
> -- Trino 467 equivalents (run from any Trino client; no spark-submit needed):
> ALTER TABLE iceberg.analytics.events EXECUTE optimize;
>   -- equivalent to: CALL iceberg.system.rewrite_data_files(table => 'analytics.events')
>   -- compacts small files and applies pending delete files
>
> ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d');
>   -- equivalent to: CALL iceberg.system.expire_snapshots(table => '...', older_than => current_timestamp() - interval '7' day)
>
> ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d');
>   -- equivalent to: CALL iceberg.system.remove_orphan_files(table => '...', older_than => current_timestamp() - interval '7' day)
> ```
>
> Both forms perform the same underlying Iceberg operation — the difference is purely the engine submitting it. The production runbook should pick one engine per scheduled job and stick with it; mixing engines per step (one Spark CALL, one Trino ALTER TABLE EXECUTE) makes incident debugging harder, but either engine alone can execute the entire GDPR purge sequence end-to-end.
>
> > **TRINO MINIMUM RETENTION ENFORCEMENT — this is the catch for GDPR urgency.** Trino enforces a **minimum retention floor** on `expire_snapshots` and `remove_orphan_files` to protect operators from catastrophic mistakes. The floors are configured via catalog properties on the Iceberg connector and **default to 7 days**:
> >
> > - `iceberg.expire-snapshots.min-retention` (default `7d`) — minimum allowed value for the `retention_threshold` parameter of `expire_snapshots`.
> > - `iceberg.remove-orphan-files.min-retention` (default `7d`) — minimum allowed value for `remove_orphan_files`.
> >
> > If you try to run `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '0d')` from Trino with the defaults in place, Trino **rejects the statement** with an error like `Retention specified (0.00d) is shorter than the minimum retention configured in the system (7.00d)`. Setting `older_than => current_timestamp` (the zero-day retention pattern used for GDPR urgency in the Spark examples below) is **blocked by this floor** when run from Trino.
> >
> > **For GDPR right-to-erasure where you need to purge bytes immediately** (cannot wait 7 days), you have two paths:
> >
> > 1. **Run the purge from Spark** — Spark does not have this minimum-retention enforcement; the Spark `CALL iceberg.system.expire_snapshots(... older_than => current_timestamp(), retain_last => 1)` form runs without complaint. This is what the Spark examples in the steps below show.
> > 2. **Temporarily lower the Trino catalog property** — set `iceberg.expire-snapshots.min-retention=0s` (and the orphan-files equivalent) on the Trino coordinator's Iceberg catalog properties file, restart the coordinator (these are catalog properties, NOT hot-reloadable), run the GDPR purge from Trino, then revert the property and restart again. The double-restart blast radius is real (two query-rejection windows in one incident), so most teams use path 1 (Spark) for GDPR work and keep Trino's safety floor at the 7-day default for everything else.
> >
> > Spark's lack of an equivalent floor is intentional — Spark is the maintenance engine, expected to be operated by the data team who already know what they're doing. Trino is the interactive query engine, where a typo in an admin's `ALTER TABLE EXECUTE` could wipe out the rollback window for every snapshot in the table; the 7-day floor is the guardrail against that mistake.

**Step 1: DELETE the rows (Trino or Spark SQL — either works)**

```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

What happened on disk: Iceberg created a new snapshot whose manifests reference **delete files** (small markers listing the deleted row positions). The original Parquet data files are untouched. `SELECT COUNT(*) WHERE tenant_id = 'acme'` already returns 0, but the bytes are still on MinIO.

> **CoW vs MoR at DELETE time — which one does your table use?** Iceberg supports two physical write modes for DELETE, and which mode is in effect changes whether step 2 (`rewrite_data_files`) is strictly necessary or merely helpful. **Critically: regardless of mode, all 4 purge steps are still required for GDPR compliance — the mechanism differs, but the required sequence does not.** In both modes, the previous snapshot still references the old state, so steps 3 (`expire_snapshots`) and 4 (`remove_orphan_files`) are mandatory in both — the only difference is whether step 2 is strictly necessary or merely a safe no-op cleanup.
>
> - **Copy-on-Write (CoW)**: `DELETE FROM` rewrites all affected Parquet data files immediately, producing new files without the deleted rows. The new snapshot points at the rewritten files directly. Step 2 (`rewrite_data_files`) may not be strictly necessary in this mode — the data files are already clean — but running it is still safe and cleans up any residual delete files. **The previous snapshot still references the original (pre-rewrite) data files on MinIO, so steps 3 and 4 remain required to physically remove those bytes.**
> - **Merge-on-Read (MoR — the default in most production configs)**: `DELETE FROM` writes small **positional delete files** that mark which rows to skip at read time; the original Parquet data files are completely untouched. The new snapshot points at the original data files PLUS the new delete files. Step 2 (`rewrite_data_files`) is **essential** — without it, the current snapshot still references the original data files which physically contain the deleted rows on MinIO. A privacy auditor scanning MinIO would still find the deleted tenant's bytes.
>
> The mode is controlled by the table property `write.delete.mode` (`copy-on-write` or `merge-on-read`), and many Iceberg configurations default to MoR for write-throughput reasons. **If you don't know which mode your table is in, check `SHOW CREATE TABLE iceberg.analytics.events` for `write.delete.mode`, or just assume MoR and always run step 2.** Treating step 2 as "always required" is the safe operational default — it is a no-op cost on CoW tables and a correctness requirement on MoR tables. The 4-step sequence (DELETE → rewrite → expire → orphan-sweep) is the same on either mode; only step 2's importance changes.
>
> **How to inspect and set the delete mode (the two concrete commands you actually need):**
>
> ```sql
> -- Inspect: run in Trino (or Spark) to see the current delete mode.
> -- Look in the WITH (...) clause of the CREATE TABLE output for write.delete.mode.
> -- If write.delete.mode is absent from the output, the table is using the
> -- engine/format-version default (typically merge-on-read on Iceberg v2 tables).
> SHOW CREATE TABLE iceberg.analytics.events;
>
> -- Set explicitly to merge-on-read (more efficient for row-level GDPR deletes;
> -- recommended default for any table that will see frequent point deletes).
> -- This is the Spark SQL form using ALTER TABLE ... SET TBLPROPERTIES.
> ALTER TABLE iceberg.analytics.events
>   SET TBLPROPERTIES ('write.delete.mode' = 'merge-on-read');
>
> -- Alternative: set explicitly to copy-on-write (each DELETE rewrites affected
> -- data files synchronously — higher DELETE cost but no separate compaction
> -- needed before bytes are physically replaced).
> ALTER TABLE iceberg.analytics.events
>   SET TBLPROPERTIES ('write.delete.mode' = 'copy-on-write');
> ```
>
> The Trino-native equivalent is `ALTER TABLE iceberg.analytics.events SET PROPERTIES delete_mode = 'merge-on-read'` — same effect, slightly different syntax. Either engine can change the property; the change applies to subsequent DELETE statements (existing snapshots are not rewritten).
>
> **Cross-link — Trino OPTIMIZE and MoR position-delete files: the qualified picture.** Trino's `ALTER TABLE ... EXECUTE optimize` **does** clean up MoR position-delete files, **but only when it is processing whole partitions and only without `file_modified_time` or path predicates** (per the Trino Iceberg connector documentation and issue #24086). For a per-tenant GDPR sweep with a `WHERE tenant_id = 'acme'` clause, that whole-partition condition does not hold — the filter scopes the rewrite to a partition slice, not the whole partition's file set, so Trino's OPTIMIZE in that mode will not reliably retire the position deletes for those rows. **Use Spark `rewrite_data_files` with the `where => "tenant_id = 'acme'"` option for the GDPR purge sequence** — Spark reliably reads the original Parquet files PLUS the position-delete files, applies the deletes in memory, and writes new clean data files regardless of partition slice or predicate shape. This is **the primary reason GDPR runbooks should use Spark for step 2**, not Trino. For routine whole-partition compaction with no per-tenant filter (e.g., the weekly maintenance job that compacts yesterday's whole day partition), Trino's `EXECUTE optimize` is fine and does fold in the position deletes; the Spark recommendation is specifically for the per-tenant scoped form. See resource 10 for the full Trino OPTIMIZE limitation note. Bottom line on the production stack: do the DELETE in either engine, but **always do step 2 in Spark when the rewrite must be scoped to one tenant via a `where` clause**.
>
> **Snapshot retention table properties can override `expire_snapshots(retain_last => 1)`.** When you run `CALL iceberg.system.expire_snapshots(table => '...', retain_last => 1)` for a GDPR purge, the **table-level** Iceberg properties `history.expire.min-snapshots-to-keep` and `history.expire.max-snapshot-age-ms` may quietly force Iceberg to retain MORE snapshots than `retain_last` requested. The semantics are "keep the MAXIMUM of all configured constraints" — if your table has `history.expire.min-snapshots-to-keep = 5` set as a property, calling `expire_snapshots(retain_last => 1)` still keeps 5 snapshots, not 1, and the older snapshots (which still reference the deleted tenant's Parquet files) survive — meaning the bytes survive too. This silently breaks GDPR compliance. **Before any GDPR purge run, check the table properties:**
>
> ```sql
> -- Inspect snapshot-retention properties on the table.
> -- If either property is set to a value greater than 1, expire_snapshots(retain_last => 1) will NOT
> -- expire down to a single snapshot — it will retain whatever the property dictates.
> SHOW CREATE TABLE iceberg.analytics.events;
> -- Look for: history.expire.min-snapshots-to-keep, history.expire.max-snapshot-age-ms
>
> -- If the properties are set and you need to bypass them for a GDPR purge,
> -- temporarily unset them, run the purge, then restore the prior values:
> ALTER TABLE iceberg.analytics.events
>   UNSET TBLPROPERTIES ('history.expire.min-snapshots-to-keep',
>                         'history.expire.max-snapshot-age-ms');
> -- ...run the GDPR purge sequence (steps 1-4)...
> ALTER TABLE iceberg.analytics.events
>   SET TBLPROPERTIES (
>     'history.expire.min-snapshots-to-keep' = '5',          -- restore prior value
>     'history.expire.max-snapshot-age-ms'  = '432000000'   -- restore prior value (5d in ms)
>   );
> ```
>
> Treat this as a mandatory preflight check for every GDPR purge: an unaudited `min-snapshots-to-keep = 5` on the table makes `retain_last => 1` a no-op, and you sign off thinking you purged the bytes when you actually only purged the most recent snapshot's references to them.

**Step 2: rewrite_data_files (Spark `CALL` syntax shown — Trino 467 equivalent is `ALTER TABLE iceberg.analytics.events EXECUTE optimize`)**

```sql
-- Spark SQL syntax — run via spark-submit. The Iceberg system procedures are
-- exposed via the Spark Iceberg extensions under the configured catalog.
--
-- Why Spark, not Trino, for THIS specific step in a per-tenant GDPR purge:
-- Trino's ALTER TABLE ... EXECUTE optimize also cleans up MoR position deletes
-- (per Trino issue #24086), BUT only when it is processing whole partitions and
-- only without file_modified_time or path predicates. For a per-tenant GDPR
-- sweep with a WHERE tenant_id = 'acme' clause the rewrite is scoped to a
-- partition slice rather than the whole partition's file set, so the whole-
-- partition condition does not hold and Trino will not reliably apply the
-- position deletes for those rows. Use Spark rewrite_data_files with the
-- where => "tenant_id = 'acme'" option — it reliably rewrites and applies
-- position deletes regardless of partition slice or predicate shape.
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => "tenant_id = 'acme'"
);
```

What happened on disk: Spark read the affected Parquet files plus the delete files, applied the deletes in memory, and wrote **new** Parquet files without Acme's rows. A new snapshot now points at the new files. **The old Parquet files (with Acme's bytes inside them) still exist on MinIO** because the previous snapshot still references them.

**Step 3: expire_snapshots (Spark `CALL` syntax shown — Trino 467 equivalent is `ALTER TABLE ... EXECUTE expire_snapshots(retention_threshold => '7d')`, but see the minimum-retention caveat below) — this is the step that physically removes the bytes**

```sql
-- Spark SQL syntax — run via spark-submit.
-- Trino 467 equivalent for ROUTINE use:
--   ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d');
--
-- IMPORTANT: the zero-day GDPR form shown below
-- (older_than => current_timestamp - interval '0' day) is BLOCKED by Trino's
-- iceberg.expire-snapshots.min-retention catalog property, which defaults to 7d.
-- For GDPR urgency (need to purge NOW, not in 7 days), either:
--   (a) run this step from Spark, which does not enforce the floor, OR
--   (b) temporarily set iceberg.expire-snapshots.min-retention=0s on the Trino
--       coordinator's catalog properties, restart the coordinator, run the
--       Trino ALTER TABLE EXECUTE expire_snapshots(retention_threshold => '0s'),
--       then revert the property and restart again.
-- Most teams pick (a) for GDPR work — one Spark job is simpler than two
-- coordinator restarts during a compliance incident.
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp() - INTERVAL '0' DAY,
  retain_last  => 1
);
```

For GDPR specifically, override the default retention to expire snapshots immediately: pass `older_than => current_timestamp - interval '0' day` and `retain_last => 1` to aggressively expire **all** old snapshots immediately, keeping only the current one. The procedure walks the now-unreferenced manifest files, identifies Parquet data files no longer referenced by any live snapshot, and **issues S3 DELETE calls against MinIO**. Only after this step are the bytes physically gone.

`expire_snapshots` removes **all** unreferenced files from MinIO — not just the obvious Parquet data files. Specifically, the procedure issues S3 DELETE calls for: the **Parquet data files** that held the customer's row bytes, the **position delete files and equality delete files** (Parquet files of `(file_path, row_position)` or column-value tuples) that the prior `rewrite_data_files` step retired, the **Avro manifest files** (each describing a set of data/delete files in a snapshot), and the **manifest list files** (the Avro snapshot-level index that maps partition ranges to manifests). After this step completes, **no trace of the old snapshot remains on storage** — the data bytes, the delete-marker bytes, and every layer of metadata that ever pointed at them are all gone from MinIO. This completeness is what makes `expire_snapshots` the actual GDPR-compliant step: a regulator-grade audit looks at the MinIO bucket and finds nothing.

> **Correct retention defaults (often misquoted as "30 days").** Iceberg's actual default for the table property **`history.expire.max-snapshot-age-ms` is 5 days** — that is the age at which `expire_snapshots` (with no `older_than` argument) drops a snapshot. Trino additionally enforces a **minimum-retention floor of 7 days** via the `iceberg.expire-snapshots.min-retention` catalog property — it will refuse to expire any snapshot newer than 7 days, regardless of what `retention_threshold` you pass to `ALTER TABLE ... EXECUTE expire_snapshots`. There is **no 30-day default anywhere in Iceberg or Trino** — that figure shows up in some runbooks as a chosen retention setting (a common operator preference for "keep about a month of rollback history") but is not a default. For GDPR right-to-erasure, run the purge from Spark (no minimum-retention floor) with `older_than => current_timestamp() - interval '0' day, retain_last => 1` — that bypasses both Iceberg's 5-day default and Trino's 7-day floor in one step.

> **SAFETY — `older_than = current_timestamp` / `interval '0' day` IS DANGEROUSLY AGGRESSIVE FOR NON-GDPR USE.** Outside of GDPR hard-delete work, do NOT call `expire_snapshots` with `older_than => current_timestamp` or `older_than => current_timestamp - interval '0' day`. It immediately expires the most recent snapshot, which breaks:
>
> - **Time-travel queries against recent snapshots** — `SELECT * FROM iceberg.analytics.events FOR VERSION AS OF <recent_snapshot_id>` fails with "snapshot not found" the moment the procedure finishes, because the snapshot's manifests have been deleted.
> - **Concurrent readers who opened a scan against a snapshot that's now expired** — Trino queries already in flight at the moment of expiry can fail mid-scan with file-not-found errors against MinIO, because the Parquet files they were planning to read have just been deleted underneath them. This shows up as flaky query failures during the maintenance window.
> - **The 24-hour rollback window** documented elsewhere in this resource — once the prior snapshots are gone, `rollback_to_snapshot` to anything before the current one is impossible.
>
> **Safe defaults by use case:**
>
> | Use case | `older_than` | `retain_last` | Why |
> |---|---|---|---|
> | Routine maintenance (weekly/monthly compaction) | `current_timestamp - interval '7' day` | (default) | Keeps at least 7 days of snapshot history for time-travel and rollback |
> | Storage-pressure cleanup | `current_timestamp - interval '3' day` | (default) | Tighter than 7 days, still leaves a rollback window |
> | GDPR hard-delete (right-to-be-forgotten) | `current_timestamp - interval '0' day` | `1` | Required to physically remove the bytes — but removes time-travel ability and rollback |
> | Tenant offboarding (contract-driven hard delete) | `current_timestamp - interval '0' day` | `1` | Same as GDPR |
>
> The `interval '0' day, retain_last => 1` form is the **GDPR exception**, not the default. Using it for routine maintenance is the most common way teams turn a one-line cleanup script into a P1 incident that wipes out their last-known-good snapshot history.
>
> **GDPR / tenant offboarding exception:** If you need to immediately purge a churned tenant's bytes for compliance, using `retain_last => 1` with an aggressive `older_than` (e.g., `interval '1' day`) is acceptable — but accept that time-travel queries going back beyond that window will fail, and the deletion is irreversible.

> **PRE-FLIGHT BEFORE `remove_orphan_files` — read this checklist before you run step 4 with a sub-default `older_than`.** When `older_than` is tightened from Iceberg's documented 3-day default to 1 day (or shorter) for GDPR urgency, the safety margin against deleting in-flight files shrinks dramatically. Three concrete pre-flight actions reduce that risk to near-zero:
>
> 1. **Pause or drain ingestion first.** Any Spark ingestion job that is currently staging files (mid-write, files on MinIO but no commit yet) risks having those files deleted by an aggressive `older_than` — the procedure cannot distinguish "Spark crashed and left these stranded" from "Spark wrote these 30 minutes ago and is about to commit them." With ingestion paused for the duration of the purge, no files are mid-write, so the risk is zero. Pause your Airflow DAG or scale the Spark ingestion deployment to 0 replicas before step 4, and resume after step 4 completes. The pause window is typically minutes; the consistency win is total.
>
> 2. **DROP the export table after handoff.** If you exported the customer's data via `CREATE TABLE iceberg.exports.customer_offboard AS SELECT ...` (the CTAS pattern from the "Large tenant data export" section), the customer's bytes also live in **that export table's** files on MinIO — not just in the main `analytics.events` table. The 4-step GDPR purge on `analytics.events` does not touch the export table. After the customer confirms they've downloaded the export, drop and PURGE the export table to trigger its own orphan cleanup:
>
>    ```sql
>    -- Run on the export table after customer handoff confirmation.
>    -- Iceberg's DROP TABLE on a managed location also deletes the underlying
>    -- data files; for an external-location table, follow with mc rm on the path.
>    DROP TABLE iceberg.exports.customer_offboard;
>    ```
>
>    Forgetting this step leaves a full copy of the customer's bytes on MinIO indefinitely — a GDPR violation just as severe as skipping step 4. **The GDPR audit checklist should include `DROP TABLE` on every export table created for the offboarding customer.**
>
> 3. **Prefer a flat export format for customer delivery, not Iceberg CTAS.** When you use `CREATE TABLE iceberg.exports.customer_offboard AS SELECT ...` to produce the export, Iceberg writes Parquet files in its **nested directory layout** (`metadata/`, `data/`, manifest files, etc.) — most customers cannot consume this without an Iceberg-capable reader. Prefer one of the customer-consumable shapes:
>
>    ```sql
>    -- Option A: write to a flat MinIO directory via Trino's INSERT INTO ... external location.
>    -- The customer downloads from a plain Parquet directory, no Iceberg reader required.
>    INSERT INTO TABLE iceberg.exports.customer_offboard_flat
>    SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'departing-customer';
>    -- (The external table is pre-created with `WITH (location = 's3a://lakehouse/exports/flat/...', format = 'PARQUET')`)
>
>    -- Option B: produce a gzipped CSV via Spark for maximum customer compatibility.
>    --   df = spark.sql("SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'departing-customer'")
>    --   df.coalesce(N).write.option("compression", "gzip").csv("s3a://lakehouse/exports/flat/")
>    -- See coalesce(N) sizing note immediately below — do NOT just hardcode 1 or 10.
>    ```
>
>    A flat Parquet directory or a gzipped CSV is universally readable by Pandas, DuckDB, Excel (CSV), pyarrow, and every BI tool — no Iceberg-specific knowledge required. The Iceberg CTAS shape is convenient for a quick internal export but is the wrong format to hand to a customer.
>
> **`coalesce(N)` sizing note — pick N from the dataset size, not a magic number.** `coalesce(N)` controls how many output files Spark writes — one file per partition after the coalesce. `coalesce(1)` produces a single giant file (convenient for one-file delivery but unreadable for multi-GB datasets in Excel/pyarrow and a memory hog for the customer); `coalesce(10)` produces ten files of whatever size happens to fall out (could be 50MB each on a small export, could be 5GB each on a big one). Pick N so each output file lands roughly **500MB–2GB compressed** for downstream usability — small enough to fit in a desktop tool's working memory and to transfer/restart on a flaky connection, large enough to avoid the small-file fragmentation tax (thousands of 5MB files are slow to download and slow to read). Rule of thumb: `N ≈ ceil(total_compressed_export_size_gb / 1.0)` — gives you ~1GB per file. For a 12GB compressed export, that's `coalesce(12)`. For a 200MB tiny export, `coalesce(1)` is fine. Estimate the compressed size by running `SELECT SUM(file_size_in_bytes) FROM iceberg.exports.<table>."<table>$files"` after the export INSERT, then divide by 2^30 to get GB.

**Step 4: remove_orphan_files (Spark `CALL` syntax shown — Trino 467 equivalent is `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')`, subject to the same minimum-retention floor) — sweep MinIO for files no snapshot ever referenced**

```sql
-- =====================================================================
-- SPARK SQL signature (named args via =>):
-- CALL iceberg.system.remove_orphan_files(
--   table       => 'schema.table',          -- REQUIRED
--   older_than  => <timestamp>,             -- default = 3 days ago
--   dry_run     => true | false,            -- default false
--   location    => 's3a://...',             -- optional override
--   max_concurrent_deletes => <int>         -- optional concurrency
-- )
--
-- TRINO 467 signature (entirely different — DO NOT mix):
--   ALTER TABLE iceberg.analytics.events
--   EXECUTE remove_orphan_files(retention_threshold => '7d');
--
-- Trino does NOT expose `CALL iceberg.system.remove_orphan_files(...)`.
-- Trino does NOT support a `dry_run` parameter — preview from Spark only.
-- Trino enforces a 7-day MINIMUM retention (catalog property
-- `iceberg.remove-orphan-files.min-retention`, default '7d'). The 1-day
-- window below would be REJECTED by Trino. For GDPR purges that need a
-- tighter window, run from Spark (no floor) or temporarily lower the
-- Trino catalog property and restart the coordinator.
-- =====================================================================

-- STEP 4a (MANDATORY) — Spark dry-run preview. ALWAYS run this first.
-- Orphan-file deletion is irreversible; for GDPR the tenant's bytes
-- being deleted MUST be the right bytes. Review the file list before
-- the actual delete.
CALL iceberg.system.remove_orphan_files(
  table   => 'analytics.events',
  dry_run => true
);

-- STEP 4b — actual deletion after dry-run review.
CALL iceberg.system.remove_orphan_files(
  table       => 'analytics.events',
  older_than  => current_timestamp() - INTERVAL '1' DAY
);
```

**What are orphan files?** During normal operation, Spark ingestion jobs write Parquet data files to MinIO **first**, then commit a new Iceberg snapshot that references them. If an ingestion job crashes, gets killed by Kubernetes (OOM, eviction, pod restart), or fails between the write and the commit, the Parquet files it already wrote are stranded on MinIO — they exist physically, but no Iceberg snapshot ever references them. These are **orphan files**.

**Why step 3 doesn't catch them.** `expire_snapshots` removes snapshot metadata and the files referenced *by those expired snapshots*. It walks Iceberg's metadata tree to decide what's safe to delete. But because orphan files were never committed to any snapshot in the first place, they're invisible to that walk — `expire_snapshots` doesn't even know they exist. They will sit on MinIO indefinitely.

**Why this matters for GDPR.** If one of the partially-failed ingestion jobs happened to be writing the deleted tenant's events at the moment it crashed, the orphan Parquet file on MinIO **still contains that tenant's bytes**. A privacy auditor running `mc ls --recursive` against MinIO will find it. Steps 1–3 alone are not enough; you need step 4 to be fully compliant.

**How `remove_orphan_files` works.** It scans the actual MinIO prefix where the table's files live, builds the set of files currently referenced by any live manifest, and deletes any file in the prefix that's not in that set. The `older_than` filter is the critical safety knob.

> **SAFETY — always give `older_than` a generous buffer (Iceberg's documented default is 3 days, and there's a reason for it).** The `older_than` parameter tells the procedure to ignore any file whose last-modified timestamp is newer than the cutoff. This protects in-flight ingestion jobs: a Spark job that is right now writing Parquet files (but hasn't yet committed the snapshot) will appear to have "orphan" files for the duration of the write. If `older_than` is too aggressive (e.g., `current_timestamp() - INTERVAL '1' MINUTE`), the procedure will race the in-flight write and delete files mid-flight — corrupting the ingestion and producing missing-data incidents.
>
> **Iceberg's documented default for `remove_orphan_files.older_than` is 3 days** — that is the conservative value the project recommends precisely because most production pipelines have at least one job class (overnight batch, cross-cluster sync, multi-hour Spark rewrite) that can stay "in flight" for many hours. Three days leaves comfortable headroom for those slow paths.
>
> **When can you safely use 1 day instead?** Only when **every** ingestion job that writes to this table is known to commit within hours, not days. Concretely: Spark streaming micro-batches that commit every 5 minutes, batch jobs that complete in under 2 hours, no overnight cross-region replication. For GDPR urgency where you need to purge immediately and you control the ingestion schedule, 1 day is acceptable. **If you have any overnight batch jobs, multi-hour rewrite procedures, or cross-cluster sync, stick to the 3-day default.** The downside of the generous buffer is only that orphan files linger a few extra days; the downside of an aggressive value is real data corruption.
>
> Recommended values:
>
> | Use case | `older_than` | Why |
> |---|---|---|
> | Routine maintenance, no urgency | `INTERVAL '3' DAY` (Iceberg default) | Matches Iceberg's documented safe default; tolerates any reasonable ingestion job duration |
> | Conservative for multi-hour rewrites or overnight ETL | `INTERVAL '7' DAY` | Extra headroom for slow-running maintenance procedures |
> | GDPR urgent purge, ingestion jobs all complete in hours | `INTERVAL '1' DAY` | Safe only when you've confirmed no long-running Spark or batch jobs touch the table |
> | Anything shorter (minutes/hours) | **Don't** | Will race in-flight ingestion and corrupt data |

### Partition-key precondition for file-level isolation

The file-level isolation guarantees in steps 2, 3, and 4 of the purge sequence (and the cross-tenant safety claims they're built on) rest on a specific table-layout assumption: **the table must be partitioned by `tenant_id`** (or a transform of it, like `bucket(tenant_id, N)`). When that assumption holds, the tenant's data lives in physically separate files from other tenants' data, and each step operates on a clean per-tenant set of files. When it doesn't hold, the steps still produce **correct** results, but with different efficiency and blast radius properties — read this before you sign off on a non-partitioned table.

**When the table IS partitioned by `tenant_id`:**

| Step | What it touches when tenant_id is in the partition spec |
|---|---|
| Step 1 (DELETE) | Iceberg's planner prunes to the target tenant's partitions only. Other tenants' files are not opened or rewritten. |
| Step 2 (`rewrite_data_files where => "tenant_id = 'acme'"`) | Reads and rewrites ONLY the target tenant's partition files. Other tenants' data stays exactly where it was, untouched. |
| Step 3 (`expire_snapshots`) | Operates on snapshot metadata; partition layout is irrelevant. Removes any data file no longer referenced by a live snapshot, including the rewritten ones from step 2. |
| Step 4 (`remove_orphan_files`) | Operates on the MinIO file listing for the table prefix; partition layout is irrelevant. Removes files no snapshot ever referenced. |

**When the table is NOT partitioned by `tenant_id` (tenant_id is only a regular column):**

| Step | What changes |
|---|---|
| Step 1 (DELETE) | Still correct — Iceberg writes positional delete markers (MoR) or rewrites affected files (CoW) — but now any data file containing **even one row** of the target tenant must be touched. On a table partitioned by `day(occurred_at)` alone, a year of DELETE for one tenant means rewriting one file per day across all 365 days. **Other tenants' rows in those same files are rewritten alongside** (the engine writes new files that include the surviving rows from every other tenant). |
| Step 2 (`rewrite_data_files where => "tenant_id = 'acme'"`) | Still correct, but **less efficient** — the engine cannot prune at the partition level on `tenant_id`. It must scan every data file in the affected partitions (whatever partitioning the table does use) to apply the predicate. On a table partitioned by `day(occurred_at)` alone, the rewrite must read every file in the date range that holds any of the tenant's rows. Correct result, longer wall-clock time, more I/O. |
| Step 3 (`expire_snapshots`) | **Unaffected by partitioning.** It works on snapshot metadata, not on file contents. The same procedure call works identically regardless of partition spec. |
| Step 4 (`remove_orphan_files`) | **Unaffected by partitioning.** It works on the MinIO file listing for the table's storage prefix, not on partition layout. The same procedure call works identically regardless of partition spec. |

**Bottom line:** the 4-step purge sequence is **correct on any table** — partitioned by tenant_id or not. The only difference is **how efficiently step 2 runs**. If your shared multi-tenant table is partitioned by `day(occurred_at), tenant_id` (the recommended layout in this guide), step 2 is fast and surgical. If your table is partitioned by `day(occurred_at)` alone and `tenant_id` is a regular column, step 2 still works, but expect a multi-hour Spark job for a year of history instead of minutes. **For tables holding multi-tenant data that will see GDPR right-to-erasure requests, partitioning by `tenant_id` (identity or bucket) is the right design choice from day one** — see the partition strategy section above.

### GDPR audit checklist

Use this exact checklist for compliance sign-off — do not sign off before the last item:

1. `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'` — succeeds.
2. `CALL iceberg.system.rewrite_data_files(table => 'analytics.events', where => "tenant_id = 'acme'")` — succeeds.
3. `CALL iceberg.system.expire_snapshots(table => 'analytics.events', older_than => current_timestamp() - interval '0' day, retain_last => 1)` — succeeds.
4. `CALL iceberg.system.remove_orphan_files(table => 'analytics.events', dry_run => true)` — review the candidate file list (Spark-only; Trino has no dry_run). Then `CALL iceberg.system.remove_orphan_files(table => 'analytics.events', older_than => current_timestamp() - interval '1' day)` — succeeds. (Trino equivalent for the actual deletion: `ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d')` — note Trino's 7-day floor and lack of `dry_run`.)
5. Verify the query layer: `SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme'` returns `0`.
6. Verify the metadata layer (see "Verification via metadata tables" below): `$snapshots` shows only the post-purge snapshot; `$files` returns 0 rows for the deleted tenant's partition.
7. Verify the storage layer: list the MinIO prefix for the table (`mc ls --recursive minio/lakehouse/warehouse/analytics/events/`) and confirm no Parquet files contain the tenant's data. For belt-and-suspenders, grep file metadata or sample a few files.
8. Repeat steps 1–7 for every Iceberg table that holds Acme data (events, orders, users, sessions, ...).
9. Now sign off.

If you sign off after only steps 1–3, orphan files from any partially-failed ingestion job may still hold the tenant's bytes on MinIO and you are not GDPR-compliant. Step 4 is the catch-all sweep.

### Verification via metadata tables

After running steps 1–4, the most structured and auditable way to confirm the purge is complete is to query Iceberg's built-in `$`-suffix metadata tables directly (these are the same metadata tables called out in the "Iceberg metadata table leak" security section above — they expose internal state, which is exactly what you want for verification). Run these from Trino (or Spark SQL — the syntax is identical) as an admin principal that has SELECT on the metadata tables.

```sql
-- 1. Confirm no pre-delete snapshots remain.
-- After step 3 (expire_snapshots with retain_last => 1), only the current
-- post-purge snapshot should be present. Each older snapshot in this result
-- would still reference the deleted tenant's original Parquet files.
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at;
-- Expected: a single row (the current snapshot). If multiple rows appear,
-- step 3 didn't expire what you expected — re-run with the right older_than.

-- 2. Confirm no files reference the deleted tenant's partition.
-- This query is meaningful only if the table is partitioned by tenant_id
-- (the recommended layout in this guide). It walks the live manifest tree
-- and reports every file currently referenced by the current snapshot.
SELECT file_path, record_count
FROM iceberg.analytics."events$files"
WHERE partition.tenant_id = 'acme';
-- Expected: 0 rows. If any rows return, step 2 (rewrite_data_files) did not
-- fully rewrite the affected files — re-run with a broader `where` clause
-- or check that the table is in MoR mode and the rewrite actually executed.

-- 3. Confirm no leftover position-delete files reference the deleted tenant's
-- partition. After a clean rewrite_data_files, the position delete files
-- written by step 1's DELETE should no longer be referenced by the live snapshot.
-- The `content` column on $files is an integer enum: 0=DATA, 1=POSITION_DELETES,
-- 2=EQUALITY_DELETES. Use `content = 1` to count position-delete files specifically.
-- DO NOT use `file_type = 'POSITION_DELETE'` — there is no `file_type` column on
-- Iceberg's $files metadata table in Trino; that query returns
-- "Column 'file_type' cannot be resolved" and fails immediately.
SELECT COUNT(*) AS leftover_position_delete_files
FROM iceberg.analytics."events$files"
WHERE content = 1                                  -- 1 = POSITION_DELETES
  AND partition.tenant_id = 'acme';
-- Expected: 0 rows. If any rows return, the rewrite did not fold in the deletes
-- — re-run rewrite_data_files with `delete-file-threshold => '1'` in the options
-- map (see resource 13's "Diagnosing position-delete-file accumulation" section).
```

> **PRECONDITION — `partition.tenant_id` ONLY WORKS IF `tenant_id` IS A CURRENT PARTITION COLUMN.** The query above silently produces misleading results if your table's partition spec doesn't actually include `tenant_id` as an identity-partition column. There are three cases to be aware of, each with a different failure mode:
>
> 1. **Identity-partitioned on `tenant_id` (e.g., `partitioning = ARRAY['tenant_id']` or `ARRAY['day(event_ts)', 'tenant_id']`)** — the query works as documented. The `partition` struct on `$files` contains a field named exactly `tenant_id`, and the filter prunes to the deleted tenant's files. Expected: 0 rows after the purge.
> 2. **Bucket-partitioned on `tenant_id` (e.g., `partitioning = ARRAY['bucket(tenant_id, 32)']`)** — the partition struct field is named `tenant_id_bucket` (an integer 0..31), NOT `tenant_id`. The query fails to parse with `Column 'tenant_id' cannot be resolved`. To verify deletion in this case, fall back to the data-layer check: `SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme'` (which should return 0 after the rewrite).
> 3. **Partitioned by something else entirely (e.g., `partitioning = ARRAY['day(event_ts)']`, with `tenant_id` as a regular column)** — the query parses successfully but returns **0 rows even on a buggy purge**, because there is no partition spec field named `tenant_id` at all and the filter silently matches nothing. This is the most dangerous case — you sign off thinking the purge was successful when in reality you never verified anything.
>
> **Always verify your partition spec first.** Run:
>
> ```sql
> -- Inspect the partition spec. Look at the `WITH (partitioning = ...)` clause
> -- in the output to confirm tenant_id is listed (and how — identity vs bucket).
> SHOW CREATE TABLE iceberg.analytics.events;
> ```
>
> **Decision tree based on what `SHOW CREATE TABLE` reveals:**
>
> | Partition spec contains... | Verification query that actually works |
> |---|---|
> | `'tenant_id'` (identity) | `SELECT COUNT(*) FROM iceberg.analytics."events$files" WHERE partition.tenant_id = 'acme';` → expect 0 rows |
> | `'bucket(tenant_id, N)'` | `SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme';` → expect 0 rows (data-layer check, not metadata-only) |
> | `tenant_id` not in spec at all | `SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme';` → expect 0 rows (data-layer check; the `$files` metadata path is unusable for this verification) |
>
> The data-layer fallback (`SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme'`) scans data files rather than only metadata, so it's slower than the `$files` path — but it is the **only correct verification** when `tenant_id` is not an identity partition column. Always use it after the rewrite has committed so the count reflects post-purge state.

**Why this is more auditable than scanning MinIO.** The `mc ls` approach (`mc ls --recursive minio/lakehouse/...`) tells you what files exist on object storage, but it doesn't tell you what those files contain or which snapshot owns them — you'd have to open each Parquet file and inspect the data. The metadata-table approach asks Iceberg itself: "according to your current snapshot, are there any files containing tenant `acme`'s rows?" That's the authoritative answer at the table-format level, and it's a single SQL query you can paste into a runbook, a compliance ticket, or a CI assertion. Use both methods together — metadata tables for the table-format perspective, `mc ls` for the object-storage perspective — and you have defense in depth on the verification side too.

### The rollback window (a feature, not a bug)

Between step 1 and step 3, the deletion is reversible. Until `expire_snapshots` runs, the pre-deletion snapshot still exists and you can undo a mistaken deletion:

```sql
-- "I deleted the wrong tenant!" — recoverable until step 3.
CALL iceberg.system.rollback_to_snapshot(
  table       => 'analytics.events',
  snapshot_id => <id of snapshot before the DELETE>
);
```

After step 3 expires the old snapshot, the data is **permanently gone** — there is no rollback path. This is exactly what GDPR requires (no recoverable copies), but it means you should:

- Always sanity-check the tenant_id before running step 1.
- For high-risk deletions, wait 24 hours between step 2 and step 3 to allow a recovery window. (Don't wait longer than the GDPR statutory deadline — typically 30 days.)
- For low-risk routine erasures, you can run all three steps back-to-back in one Spark job.

### Common mistake: running expire_snapshots with the default retention

```sql
-- WRONG for GDPR — keeps recent snapshots (Iceberg's `history.expire.max-snapshot-age-ms`
-- defaults to 5 days), so the snapshot containing Acme's bytes lives on for at least
-- that long. From Trino, the minimum-retention floor (default 7 days) also blocks any
-- attempt to expire snapshots younger than 7 days.
CALL iceberg.system.expire_snapshots(table => 'analytics.events');
```

The actual default behavior: Iceberg's `history.expire.max-snapshot-age-ms` default is **5 days**, and Trino's `iceberg.expire-snapshots.min-retention` catalog property defaults to **7 days** (Trino will refuse to expire snapshots newer than 7 days even if you pass a shorter `retention_threshold`). Neither default is "30 days" — that figure does not exist in Iceberg or Trino documentation. For GDPR erasure, the 5-day Iceberg default and the 7-day Trino floor are both compliance violations. Always pass the explicit `older_than => current_timestamp() - interval '0' day, retain_last => 1` from **Spark** (which has no minimum-retention floor) for erasure work.

### Quick reference

| Step | Spark SQL syntax | Trino 467 syntax | What's on MinIO afterwards |
|---|---|---|---|
| 1. DELETE | `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'` | same | Original Parquet + delete files. **Bytes still there.** |
| 2. rewrite_data_files | `CALL iceberg.system.rewrite_data_files(table => '...', where => "tenant_id = 'acme'")` | `ALTER TABLE iceberg.analytics.events EXECUTE optimize` — also folds in MoR position deletes, but only when processing whole partitions without `file_modified_time`/path predicates; **for a per-tenant `WHERE tenant_id = ...` GDPR scope, use Spark instead** (Trino's whole-partition condition is not met). | New Parquet (without Acme) + old Parquet still referenced by old snapshot. **Bytes still there.** |
| 3. expire_snapshots | `CALL iceberg.system.expire_snapshots(table => '...', older_than => current_timestamp() - interval '0' day, retain_last => 1)` | `ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d')` — **the zero-day form is BLOCKED by Trino's `iceberg.expire-snapshots.min-retention` default (7d). For GDPR-urgent zero-day expiry, use Spark or temporarily lower the catalog property.** | Old snapshot expired, MinIO deletes Parquet referenced only by expired snapshots. **Snapshot-referenced bytes gone.** |
| 4. remove_orphan_files | **Preview first:** `CALL iceberg.system.remove_orphan_files(table => '...', dry_run => true)`. Then delete: `CALL iceberg.system.remove_orphan_files(table => '...', older_than => current_timestamp() - interval '1' day)` | `ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d')` — **same min-retention floor (`iceberg.remove-orphan-files.min-retention=7d` default) applies. NO `dry_run` parameter in Trino — preview from Spark.** | MinIO swept for files no snapshot ever referenced (orphans from failed ingestion jobs). **All tenant bytes physically gone.** |

**Both engines run the same Iceberg procedures.** The "Spark SQL syntax" column is what you submit when running via `spark-submit`; the "Trino 467 syntax" column is what you submit from a Trino client. Pick one engine per scheduled job. The only operational difference is that **Trino enforces a minimum-retention floor (default 7 days) on `expire_snapshots` and `remove_orphan_files`** to protect operators from accidentally wiping the rollback window; Spark does not. For routine maintenance, the 7-day Trino floor is exactly what you want. For GDPR right-to-erasure with zero-day urgency, either run the purge from Spark or temporarily lower the Trino catalog property (and restart the coordinator) — both paths are documented in the engine-note callout above.

---

## Per-tenant data retention (READ CALLOUT A FIRST — partition DROP is a data-loss bug)

When tenants have different data-retention requirements (HIPAA customers must retain for 90 days; standard customers for 3 years; free-tier for 30 days), engineers reach for Iceberg-level retention controls and find a pile of foot-guns. **The biggest is below — partition DROP is NOT a safe per-tenant retention mechanism on shared tables and routinely deletes every tenant's data.** Read these three callouts before designing your retention strategy.

> **CALLOUT A — DANGER: Partition DROP is the #1 multi-tenant data-loss bug. Do NOT use partition DROP for per-tenant retention on shared tables.**
>
> **COMMON MISTAKE: Do not use partition DROP for shared multi-tenant tables.** This is the single most destructive mistake in this entire guide. Engineers reach for `ALTER TABLE ... DROP PARTITION` because it sounds like the "fast, clean" way to expire old data. On a shared multi-tenant table, it is a catastrophe.
>
> **WHY IT WIPES EVERYONE'S DATA, NOT JUST ONE TENANT'S:** A partition is just a physical grouping of files on disk. With a partition scheme of `(day)` or `(day, tenant_id)`, a single day-partition file group contains rows from **all tenants who had activity that day**. Even with `(tenant_id, day)` ordering, partition-DROP semantics operate at file-group granularity and routinely include rows beyond the named tenant due to how Iceberg writes mixed partition-spec history. **A single `DROP PARTITION (day = '2025-02-23')` deletes every tenant's rows for 2025-02-23 in one atomic, irreversible operation.** If you have 80 customers and 60 of them had activity on Feb 23, you just deleted 60 customers' data when you only meant to expire one.
>
> The leak is **total, silent, and instant**. There is no warning, no row count preview, no "are you sure?" prompt. The query simply succeeds and the snapshot reflects the deletion across every tenant.
>
> ```sql
> -- ============================================================
> -- WRONG — wipes EVERY tenant's data for 2025-02-23, not just acme's.
> -- A day-partition holds rows from all tenants who were active that day.
> -- ============================================================
> ALTER TABLE iceberg.analytics.events DROP PARTITION (day = '2025-02-23');
>
> -- ============================================================
> -- ALSO WRONG — even when the partition spec is (tenant_id, day) and you
> -- name both, partition-DROP semantics on a multi-tenant table are too
> -- coarse for safe per-tenant retention. Iceberg's partition evolution
> -- means historical files may have been written under a different spec
> -- (e.g., the table started life partitioned by day alone). Use row-level
> -- DELETE instead — always.
> -- ============================================================
>
> -- ============================================================
> -- CORRECT — row-level DELETE scoped to the target tenant.
> -- This is the ONLY safe pattern for per-tenant retention on shared tables.
> -- ============================================================
> DELETE FROM iceberg.analytics.events
> WHERE tenant_id = 'acme'
>   AND occurred_at < TIMESTAMP '2025-02-23 00:00:00';
> ```
>
> Use row-level `DELETE WHERE tenant_id = ? AND occurred_at < ?` for per-tenant retention enforcement. It writes Iceberg delete files (slower until next compaction), but it is the only safe way to expire one tenant's data in a shared table. Follow with `rewrite_data_files` + `expire_snapshots` (the 3-step GDPR sequence above) to physically reclaim storage.
>
> **Rule for code review:** Any pull request, ticket, or runbook that contains `DROP PARTITION` on a shared multi-tenant table is a P0 bug. Reject it on sight. The only place `DROP PARTITION` is acceptable is on per-tenant tables (Model 1 — one namespace per tenant) where the partition genuinely contains only one customer's rows.

> **CALLOUT B — Separate tables per tenant is the cleanest solution when retention requirements differ by more than ~10x.** Example: HIPAA customers require 90-day retention; standard customers want 3-year retention — that's a 12x spread (1095 days / 90 days). When the spread is that large, a shared table forces you to either (a) keep all tenants at the longest retention (wasting storage on the HIPAA tenants who legally must purge sooner), or (b) run constant per-tenant row-level DELETEs across a giant shared table (high MinIO churn, high compaction cost, high risk of an off-by-one DELETE wiping the wrong tenant).
>
> Separate tables (`iceberg.tenant_hipaa.events`, `iceberg.tenant_standard.events`) eliminate **cross-tenant partition contamination** and allow per-table `write.data.retention.days` without coupling tenants. You can also run different maintenance schedules per table (the HIPAA table gets daily snapshot expiry and aggressive compaction; the standard table gets weekly maintenance) and apply different OPA policies per namespace. This sits naturally on top of Model 1 (separate namespace per tenant) from the isolation models section above.
>
> Rule of thumb: if **max retention ÷ min retention > 10**, prefer separate tables per tenant (or per retention tier — e.g., one "hipaa_events" table that holds all HIPAA tenants' data with 90-day retention, one "standard_events" table with 3-year retention, partitioned by `tenant_id` within each). Below 10x spread, shared tables with row-level DELETE are usually fine.

> **CALLOUT C — `write.data.retention.days` is a TABLE-level Iceberg property — it controls how long expired snapshots are retained before cleanup, NOT per-tenant data retention.** Engineers often grep the Iceberg docs for a "retention" property hoping to find a per-tenant control, find `write.data.retention.days`, and assume it does what they want. **It does not.** There is **no per-tenant retention property in Iceberg.** Iceberg has no concept of a "tenant" — it only sees rows and partitions.
>
> Concretely:
> - `write.data.retention.days` (and the related `history.expire.max-snapshot-age-ms`) governs **snapshot retention**: how far back in time you can `rollback_to_snapshot` or time-travel. Setting it to 7 days means "keep 7 days of old snapshots." It says **nothing** about how long rows live.
> - There is no `write.data.retention.days.acme` or `tenant.retention.acme` property. Iceberg has no per-tenant configuration surface.
> - The only mechanisms for enforcing per-tenant retention are: (i) a scheduled job that runs `DELETE FROM ... WHERE tenant_id = ? AND occurred_at < ?` per tenant, or (ii) separate tables per tenant (or per retention tier) each with their own properties and lifecycle.
>
> If a tenant contract requires "delete our data after 90 days," your implementation is a scheduled Spark/Airflow job that runs the row-level DELETE plus the 3-step physical-removal sequence (DELETE → `rewrite_data_files` → `expire_snapshots`) — not an Iceberg table property. Document this explicitly in your design so the next engineer doesn't waste a day looking for the property that doesn't exist.

---

## Query audit logging for security auditors

When a security auditor asks "who queried which customer's data, and when?", you need an audit trail of every query Trino executed. Trino ships a built-in **HTTP event listener** that produces a structured JSON event for every completed query. No third-party plugin is required.

### How to enable the HTTP event listener

Create `etc/http-event-listener.properties` on the Trino coordinator:

```properties
event-listener.name=http
http-event-listener.connect-ingest-uri=http://audit-collector:8080/events
http-event-listener.log-completed=true
http-event-listener.log-created=false
# log-split is not applicable — SplitCompletedEvent was removed in Trino 430+.
# Do not include this property for Trino 467 deployments.
```

Reference it from `etc/config.properties`:

```properties
event-listener.config-files=etc/http-event-listener.properties
```

For Kubernetes deployments: mount both files via a ConfigMap and add the mount to the Trino coordinator pod spec. **Restart the Trino coordinator after adding the event listener config** — it is not hot-reloaded.

### What each completed query sends (QueryCompletedEvent)

For every query that completes (successfully or with an error), Trino POSTs a JSON body to your configured URI.

**Important — the JSON is nested, not flat.** If you write a parser using top-level keys like `user` or `query`, you will get null results. Use the actual nested paths shown below.

| What you want | Actual JSON path | Notes |
|---|---|---|
| Who ran the query | `context.user` | Maps to the tenant when role-per-tenant is in place |
| Authenticated principal | `context.principal` | Kubernetes ServiceAccount name or JWT subject |
| Full query text | `metadata.query` | The complete SQL, verbatim |
| Query ID | `metadata.queryId` | Unique identifier for cross-referencing in logs |
| Query state | `metadata.queryState` | `FINISHED`, `FAILED`, etc. |
| Tables and columns touched | `ioMetadata.inputs[n].columns[]` | Array of table inputs; each entry has `catalogName`, `schemaName`, `tableName`, and `columns` (list of column names) |
| Error details | `failureInfo.errorCode` | Set when `queryState` is `FAILED` |

**Concrete JSON example** — what Trino POSTs to your collector for a completed query:

```json
{
  "context": {
    "user": "acme-service-account",
    "principal": "acme-service-account"
  },
  "metadata": {
    "queryId": "20260525_091234_00001_xyz",
    "query": "SELECT COUNT(*) FROM tenant_acme.events WHERE occurred_at >= DATE '2026-05-01'",
    "queryState": "FINISHED"
  },
  "statistics": {
    "wallTime": "PT2.345S",
    "cpuTime": "PT1.8S",
    "physicalInputBytes": 5242880,
    "processedInputBytes": 1048576,
    "outputBytes": 32,
    "peakUserMemoryBytes": 16777216
  },
  "ioMetadata": {
    "inputs": [
      {
        "catalogName": "iceberg",
        "schemaName": "analytics",
        "tableName": "events",
        "columns": ["event_id", "tenant_id", "occurred_at"]
      }
    ]
  }
}
```

The `statistics` field names above are the verified ones from the Trino `QueryStatistics` SPI source. Do not invent `totalBytes`, `elapsedTime`, or `bytes_scanned` — those names do not exist and your parser will get `null` / `KeyError` on every event.

Note: `ioMetadata.inputs` is an array — one entry per table the query read. A join across two tables produces two entries.

Because role-per-tenant is already in place (each tenant has their own Trino role and service account), the `context.user` field in every audit event already carries the tenant identity. No extra tagging is required — the audit log tells you which tenant's data was touched just by looking at `context.user`.

### On-prem Kubernetes options for consuming audit events

Three practical patterns that work on the production k8s stack:

**Option 1 — POST to a Loki sidecar (zero extra infrastructure if Loki is already deployed)**

Run a Loki push gateway (or the Loki HTTP endpoint directly) on the coordinator pod or as a cluster service. The HTTP event listener POSTs JSON directly to it. Loki stores the events as structured logs queryable via Grafana's LogQL. If Grafana + Loki are already in your observability stack, this adds no new services.

**Option 2 — POST to Filebeat or Fluentd**

Run Filebeat or Fluentd as a DaemonSet. Set `http-event-listener.connect-ingest-uri` to the local agent's HTTP intake endpoint. The agent ships events to Elasticsearch or another log store. Good if your team already uses the ELK stack for application logs.

**Option 3 — Write to an Iceberg audit table in MinIO**

Run a lightweight HTTP receiver (e.g., a small FastAPI service) that receives the JSON payloads, batches them, and writes them to `iceberg.analytics.query_audit_log` via Spark. This gives the security team SQL access to audit data via Trino itself — fully self-contained, no external log store.

```sql
-- Example audit table schema — CORRECT Trino 467 DDL syntax
CREATE TABLE iceberg.analytics.query_audit_log (
    query_id      VARCHAR,
    trino_user    VARCHAR,
    principal     VARCHAR,
    query_text    VARCHAR,
    create_time   TIMESTAMP(6) WITH TIME ZONE,
    end_time      TIMESTAMP(6) WITH TIME ZONE,
    query_state   VARCHAR,
    error_code    VARCHAR,
    queried_tables VARCHAR    -- JSON array (or comma-separated) of resolved
                              -- catalog.schema.table names from ioMetadata.inputs
)
WITH (
    format = 'PARQUET',
    partitioning = ARRAY['day(create_time)']
);
```

> **Engine note on DDL vs writes.** The audit table itself is created via Trino DDL (shown above) — `WITH (format = 'PARQUET', partitioning = ARRAY['day(create_time)'])` is Trino 467's Iceberg-connector syntax, NOT Spark SQL's `USING iceberg PARTITIONED BY (...)`. To populate the table, your lightweight HTTP receiver writes batched events via Spark or a JDBC insert — not Trino's streaming write path. Trino is designed for large analytical writes (INSERT INTO ... SELECT, CTAS), not high-frequency per-event inserts; let Spark handle the micro-batch writes (e.g., every 30s flush of accumulated events), then query the resulting table from Trino.

### Using the HTTP event listener for query cost tracking

The same HTTP event listener that captures audit data also carries query cost metrics: CPU time, wall time, and bytes scanned. You can use these to build a per-tenant cost dashboard for CS conversations.

> **SECURITY NOTE — tenants must NEVER have SELECT access to `system.runtime.queries` or `system.runtime.tasks` for cost monitoring.** It is tempting to skip the HTTP event listener and instead build cost tracking by periodically querying `system.runtime.queries` directly — that path is a **cross-tenant data leak**. Those system views expose the **full query text of ALL queries on the cluster**: a tenant who can read them sees every other tenant's complete SQL — including potentially sensitive `WHERE` clause values, customer IDs, email addresses embedded in filters, and proprietary analytic logic.
>
> Concrete rules for any cost-monitoring or chargeback implementation:
>
> - **Monitoring queries against `system.runtime.queries` / `system.runtime.tasks` must run as an admin service account only** (e.g., `data-team`, `cost-monitor-svc`), **never as a tenant principal**. Treat these system views as admin-only telemetry.
> - **Your OPA policy (or file-based Trino access control) must explicitly deny the entire `system` catalog to all tenant principals.** This is the same catalog-level deny rule documented in "The `system` catalog leak" section above — it protects cost-monitoring snooping as a side effect of the broader protection.
> - **The per-tenant cost dashboard tenants see (if you expose one) must read from your own Iceberg audit table** (e.g., `iceberg.analytics.tenant_query_costs` below), filtered by `WHERE tenant_id = <caller's tenant>` exactly like every other tenant-facing view in this guide. Never expose `system.runtime.queries` to tenants even in a "read-only" capacity.
> - **CI assertion:** authenticate as each tenant role and assert `SELECT count(*) FROM system.runtime.queries` returns `Access Denied`. If it returns a number, the policy is misconfigured and tenants can read every other tenant's SQL — treat as a P0 cross-tenant leak.
>
> The HTTP event listener is the safe path for cost tracking because (a) events flow to a collector you control, (b) you decide what to store and what to expose, and (c) the per-tenant cost table is filtered the same way as any other tenant-scoped table.

**Ad-hoc admin-only query against `system.runtime.queries` — using real columns only.** When the full audit pipeline is overkill (e.g., a quick "who's running the most queries today?" check) an admin principal can query `system.runtime.queries` directly. Use only the columns that actually exist in the table — `query_type`, `statistics`, `totalBytes`, and `bytes_scanned` are common invented column names that will cause SQL parse errors. The example below uses the verified column set (see the "Trino exposes a built-in `system` catalog" section above for the full list).

```sql
-- Per-user query volume and timing — admin-only.
-- Note: "user" and "end" must be double-quoted (both are Trino reserved words),
-- and there is no query_type / statistics / bytes_scanned column on this table.
SELECT
  "user",
  COUNT(*) AS query_count,
  COUNT(*) FILTER (WHERE state = 'FAILED') AS failed_queries,
  ROUND(AVG(CAST("end" AS DOUBLE) - CAST(started AS DOUBLE)) / 1000, 1) AS avg_duration_seconds
FROM system.runtime.queries
WHERE state IN ('FINISHED', 'FAILED')
GROUP BY "user"
ORDER BY query_count DESC
LIMIT 20;
```

For per-tenant **bytes scanned**, this runtime table does not help — `system.runtime.queries` exposes no I/O-bytes column. Use the HTTP event listener path (with the verified `physicalInputBytes` field, documented immediately below) and aggregate from your `iceberg.analytics.tenant_query_costs` table instead.

**Query cost fields in the event payload (verified against the Trino `QueryStatistics` SPI source):**
- `statistics.wallTime` — wall-clock duration of the query (total real time)
- `statistics.cpuTime` — actual CPU processing time across all workers
- `statistics.physicalInputBytes` — compressed bytes read from storage (MinIO/S3) — the real I/O cost
- `statistics.processedInputBytes` — bytes processed after filtering (post pushdown)
- `statistics.outputBytes` — bytes returned to the client
- `statistics.peakUserMemoryBytes` — peak user memory usage per query

> **CRITICAL — `totalBytes` and `elapsedTime` DO NOT EXIST in the QueryStatistics payload.** Earlier drafts of this guide showed these field names; they were wrong and would have produced `KeyError` / `null` in any parser that consumed them. The verified field names (from the Trino `QueryStatistics` SPI source) are:
>
> | What you want | Correct field | Common WRONG name to avoid |
> |---|---|---|
> | Wall-clock duration | `wallTime` | ~~`elapsedTime`~~ |
> | CPU time | `cpuTime` | (correct — keep `cpuTime`) |
> | Bytes read from MinIO | `physicalInputBytes` | ~~`totalBytes`~~ |
> | Bytes processed after filter | `processedInputBytes` | (no common wrong name) |
> | Bytes returned to client | `outputBytes` | (no common wrong name) |
>
> Use the correct names when writing your HTTP receiver. A parser that looks up `event["statistics"]["totalBytes"]` will silently return `None` on every event and your cost dashboard will report zero bytes scanned for everything.

> **IMPORTANT — `wallTime` and `cpuTime` are ISO-8601 Duration objects, NOT millisecond integers.** This is the #1 parsing bug for engineers consuming the HTTP event listener payload. The Trino SPI's `QueryStatistics` field names are `wallTime` and `cpuTime` (no `Ms` suffix), and they serialize to JSON as ISO-8601 duration **strings** like `"PT2.345S"` (2.345 seconds) or `"PT1M30.5S"` (1 minute 30.5 seconds), not as numeric milliseconds. Naive code like `cost.wallTime * 1.0` or `int(event["statistics"]["wallTime"])` throws a TypeError on the first event.
>
> **Parsing pattern in Python:**
> ```python
> from datetime import timedelta
> import re
>
> def parse_iso8601_duration_to_ms(s: str) -> int:
>     # Minimal parser for the subset Trino emits: PT<minutes>M<seconds>S
>     # In production prefer a library like isodate or aniso8601.
>     m = re.match(r"PT(?:(\d+)M)?(\d+(?:\.\d+)?)S", s)
>     if not m:
>         raise ValueError(f"unexpected duration: {s}")
>     minutes = int(m.group(1) or 0)
>     seconds = float(m.group(2))
>     return int((minutes * 60 + seconds) * 1000)
>
> wall_ms = parse_iso8601_duration_to_ms(event["statistics"]["wallTime"])
> cpu_ms  = parse_iso8601_duration_to_ms(event["statistics"]["cpuTime"])
> bytes_read = event["statistics"]["physicalInputBytes"]  # plain integer, no parsing needed
> ```
>
> Always parse these into a numeric type before doing arithmetic. Store as `BIGINT` milliseconds in the Iceberg audit table for SQL-side aggregation (see `tenant_query_costs` schema below).

**Store cost metrics in Iceberg, not a separate database:**

```sql
-- Create cost tracking table in Iceberg (run once)
CREATE TABLE iceberg.analytics.tenant_query_costs (
    query_id          VARCHAR,
    tenant_id         VARCHAR,   -- extracted from context.user (JWT principal)
    wall_time_ms      BIGINT,
    cpu_time_ms       BIGINT,
    bytes_scanned     BIGINT,    -- compressed Parquet bytes
    peak_memory_bytes BIGINT,
    query_state       VARCHAR,   -- 'FINISHED' or 'FAILED' — Trino's only terminal states
    error_code        VARCHAR,   -- NULL on success; set on FAILED (e.g., 'QUERY_QUEUE_FULL')
    query_date        DATE
)
USING iceberg
PARTITIONED BY (day(query_date));
```

Your HTTP receiver writes each event to this Iceberg table. The production stack already has Iceberg + MinIO — no external database (PostgreSQL, etc.) is needed. CS teams can then run SQL directly via Trino:

```sql
-- Top tenants by compute cost (last 30 days)
SELECT
    tenant_id,
    COUNT(*) AS query_count,
    ROUND(SUM(wall_time_ms) / 3600000.0, 1) AS cpu_hours,
    ROUND(SUM(bytes_scanned) / 1073741824.0, 1) AS gb_scanned
FROM iceberg.analytics.tenant_query_costs
WHERE query_date >= CURRENT_DATE - INTERVAL '30' DAY
GROUP BY tenant_id
ORDER BY cpu_hours DESC;
```

> **NOTE on bytes_scanned**: `physicalInputBytes` in Trino's `QueryStatistics` SPI is the compressed Parquet size read from MinIO, not the uncompressed data size. Parquet compression is typically 5–10x, so 5 GB scanned ≈ 25–50 GB of raw uncompressed data. Use the compressed figure for cost calculations (that's what you actually read off disk). The other related field, `processedInputBytes`, is the post-filter size (after predicate pushdown drops irrelevant column chunks and row groups) — useful for understanding pushdown effectiveness, but `physicalInputBytes` is the cost-attributable figure for chargeback.

#### Tracking queue saturation per tenant — use `query_state = 'FAILED' AND error_code = 'QUERY_QUEUE_FULL'`

> **Trino has only TWO terminal query states: `FINISHED` and `FAILED`.** There is no `QUEUED_TIMEOUT`, no `QUEUE_EXCEEDED`, no `TIMED_OUT`, no `KILLED` terminal state. Engineers regularly invent these state names when writing audit-table queries; the queries silently return zero rows because no Trino query ever lands in those states. The real "I waited in the queue too long and was rejected" outcome is `queryState = 'FAILED'` with `failureInfo.errorCode.name = 'QUERY_QUEUE_FULL'`. Resource-group queue overflow, query-max-execution-time overruns, and admin kills all surface as `FAILED` with different `errorCode` values — always filter on `error_code`, never on a non-existent state.
>
> The full set of common `errorCode` values you should be ready to see on `FAILED` queries:
>
> | `errorCode` | Meaning |
> |---|---|
> | `QUERY_QUEUE_FULL` | Resource group's `maxQueued` was reached — query was rejected at submission |
> | `EXCEEDED_TIME_LIMIT` | Query ran past `query.max-execution-time` (or session override) |
> | `EXCEEDED_MEMORY_LIMIT` | Query exceeded `query.max-memory-per-node` or group memory cap |
> | `USER_CANCELED` | Killed via `CALL system.runtime.kill_query(...)` |
> | `PERMISSION_DENIED` | Access control rejected the query at analysis time |
> | `SYNTAX_ERROR` | Parser rejected the SQL |

Both the `query_audit_log` table (line ~1027) and the `tenant_query_costs` table (above) include `query_state VARCHAR` and `error_code VARCHAR` columns. With those columns populated, a queue-saturation dashboard is one query:

```sql
-- Queue saturation: tenants whose queries fail due to queue overflow.
-- Reads from the same tenant_query_costs table created above — the DDL and
-- this query are aligned (both reference query_state and error_code).
SELECT
  tenant_id,
  COUNT(*) FILTER (WHERE query_state = 'FAILED' AND error_code = 'QUERY_QUEUE_FULL') AS queue_failures,
  COUNT(*)                                                                            AS total_queries,
  ROUND(100.0 * COUNT(*) FILTER (WHERE query_state = 'FAILED' AND error_code = 'QUERY_QUEUE_FULL')
        / COUNT(*), 1)                                                               AS queue_failure_pct
FROM iceberg.analytics.tenant_query_costs
WHERE query_date >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY tenant_id
HAVING COUNT(*) FILTER (WHERE query_state = 'FAILED' AND error_code = 'QUERY_QUEUE_FULL') > 0
ORDER BY queue_failure_pct DESC;
```

A high `queue_failure_pct` for one tenant means their resource group's `maxQueued` is too low for their workload (or their `hardConcurrencyLimit` is too tight). Tune the per-tenant subgroup in `resource-groups.json` and (on the file-based manager) restart the coordinator — or, if you use the database-backed resource group manager, push the change and it hot-reloads within seconds.

### What the audit trail answers for a security auditor

With the HTTP event listener enabled:

- **Who queried which tenant's data**: `context.user` (maps to tenant role) + `ioMetadata.inputs[n].tableName` and `.columns[]` (which tables and columns were touched)
- **When**: top-level `createTime` and `endTime` timestamps in the event payload
- **Exact SQL**: `metadata.query` — the full text of every query, verbatim
- **Whether it succeeded**: `metadata.queryState` (`FINISHED` vs `FAILED`)

A query like "show me every query user `acme-service-account` ran against `tenant_acme.events` in May 2026" becomes a standard SQL query against the audit table.

### Cross-tenant access detection — match on resolved tables, NOT raw query text

A common security question: "find every query where a tenant principal touched another tenant's data, or where an internal user touched the base table outside the approved data-team accounts." The temptation is to grep the raw `query_text` column with a `LIKE` clause:

```sql
-- WRONG — fragile, easily evaded, and produces false positives.
-- Do NOT use LIKE matching on raw query_text for security detection.
SELECT query_id, trino_user, query_text
FROM iceberg.analytics.query_audit_log
WHERE query_text LIKE '%FROM analytics.events%'
  AND trino_user NOT IN ('data-team', 'admin-service-account');
```

This LIKE pattern misses queries that use aliases (`FROM iceberg.analytics.events e`), schema-qualified names (`FROM iceberg.analytics.events` vs `FROM analytics.events`), subqueries (`FROM (SELECT * FROM analytics.events) sub`), unusual whitespace (`FROM\n  analytics.events`), CTEs (`WITH x AS (SELECT * FROM analytics.events) ...`), or any query that references the table indirectly via a view. It also generates false positives on comments and string literals that happen to contain the table name. **Do not rely on query-text matching for any security-grade detection.**

The correct signal is the **resolved table list** from `ioMetadata.inputs`. When Trino executes a query, the engine's analyzer resolves every table reference (including those hidden in views, subqueries, and CTEs) to its real `catalog.schema.table` name, and reports the resolved list in `ioMetadata.inputs[n].tableName`. Your HTTP receiver should serialize that resolved list into the `queried_tables` column at ingest time (JSON array or simple comma-separated string).

```sql
-- CORRECT — match against resolved table names from ioMetadata.inputs.
-- These are the actual tables read by the query engine, not what the user typed.
SELECT
    query_id,
    trino_user,
    query_text,
    create_time,
    queried_tables
FROM iceberg.analytics.query_audit_log
WHERE queried_tables LIKE '%analytics.events%'
  AND trino_user NOT IN ('data-team', 'admin-service-account')
  AND query_state = 'FINISHED'
ORDER BY create_time DESC;
```

> **Why this works.** The `queried_tables` column stores the resolved table names from `ioMetadata.inputs` — these are the actual tables read by the query engine, not what the user typed. This is more reliable than LIKE matching on raw `query_text`, which can be fooled by aliases, subqueries, or whitespace. The Trino analyzer has already done the hard work of resolving every table reference (including those reached through views, subqueries, and CTEs) before the query executes; trust that resolved list, not the human-readable SQL text. The `LIKE '%analytics.events%'` on `queried_tables` is still a simple substring match, but it operates on the post-resolution table list — so a query that touches `analytics.events` through any path (alias, subquery, view, qualified name) all serialize to the same canonical `iceberg.analytics.events` entry in `ioMetadata.inputs`. For even stronger guarantees, store `queried_tables` as an ARRAY<VARCHAR> and use Trino's `contains()` or `any_match()` array functions instead of LIKE.

This pattern is also how you build a per-tenant access report ("which tenant principals queried which tables this month") and how you implement a CI assertion that detects any tenant role with a successful base-table read.

---

## Key terms

- **Tenant**: one of your customers (e.g., one B2B company using your SaaS).
- **Namespace / schema** (in Iceberg + Hive Metastore): a logical group of tables, like a folder. `analytics.events` means schema `analytics`, table `events`.
- **Partition** (Iceberg): a way of grouping a table's underlying files so the query engine can skip irrelevant files. Set when the table is created.
- **Hidden partitioning** (Iceberg): users write queries against the logical columns; Iceberg rewrites them to use the partition key automatically.
- **Trino view**: a saved SELECT, queryable like a table. Used here to inject a tenant filter the caller can't remove.
- **System access control** (Trino): the plugin layer that authorizes queries. Implementations include file-based rules and OPA.
- **OPA (Open Policy Agent)**: an external service that evaluates authorization policies. Trino can call it per query.
- **Resource groups** (Trino): per-user or per-role caps on CPU, memory, and concurrency.
- **Noisy neighbor**: a tenant whose workload degrades performance for others on shared infrastructure.

---

## Concrete recommendation for an 80-tenant B2B SaaS

If you're the engineer who asked the original question — 80 customers, moving from Postgres `tenant_id` columns to a separate analytics stack on Trino + Iceberg + MinIO — here's the default path:

1. **One shared Iceberg table per fact**, e.g., `analytics.events`, `analytics.orders`. Partition by `(tenant_id, day(<timestamp>))`.
2. **One Trino view per tenant**, named like `tenant_acme.events`, with `WHERE tenant_id = 'acme'` baked in.
3. **One Trino role per tenant** (`acme_role`, `beta_role`, ...): `CREATE ROLE acme_role`, then `GRANT ROLE acme_role TO USER "acme-service-account"` (both steps required — the role is useless until at least one user is assigned). Grant SELECT only on that tenant's views.
4. **A separate admin role** (your data team) with SELECT on the base tables for internal cross-tenant analytics.
5. **Trino system access control** (file-based to start, OPA later if rules get complex) that denies access to the base tables for tenant roles.
6. **Resource groups** capping per-tenant concurrency so big tenants can't starve small ones.
7. **A CI test** that authenticates as each tenant role and confirms it cannot read another tenant's view or the base table.

This gets you defense in depth (view + role + access control), strong query performance (partition pruning + hidden partitioning), and a single operational schema you can evolve without touching 80 copies of DDL.
