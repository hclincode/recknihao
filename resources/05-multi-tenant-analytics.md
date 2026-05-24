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

---

## Trino-specific enforcement

This is the section that matters most for the production stack. Trino is where the query is parsed and executed, so it's the right place to enforce isolation.

### Trino views that bake in the tenant filter

A **Trino view** is a saved SELECT statement that looks like a table to callers. If you grant a customer access only to the view (not the base table), they cannot see other tenants' data even if they try.

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

-- One view per tenant, baked-in filter
CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM analytics.events
  WHERE tenant_id = 'acme';

-- Step 1: create the role (a named bundle of permissions, like a Postgres role or Linux group).
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

For dynamic per-session enforcement (one view that adapts to the caller), use Trino's `current_user` function combined with a lookup table:

```sql
-- Form 1: explicit SECURITY INVOKER clause
CREATE VIEW analytics.my_events
SECURITY INVOKER
AS
  SELECT e.*
  FROM analytics.events e
  JOIN config.user_tenant_map m
    ON e.tenant_id = m.tenant_id
  WHERE m.username = current_user;

-- Form 2: equivalent table-property syntax (some Trino versions and
-- ORM/migration tools prefer this form — both forms produce the same view).
CREATE VIEW analytics.my_events
WITH (security_invoker = true)
AS
  SELECT e.*
  FROM analytics.events e
  JOIN config.user_tenant_map m
    ON e.tenant_id = m.tenant_id
  WHERE m.username = current_user;
```

> **WARNING: Trino views default to SECURITY DEFINER. For tenant isolation to work, the view MUST be created with `SECURITY INVOKER`. Otherwise the view runs with the view owner's broad table grants, which collapses isolation.**
>
> **What `current_user` actually returns (both modes):** `current_user` **always returns the principal who is *executing* the query** — i.e., the tenant who submitted the SELECT — regardless of whether the view is `SECURITY DEFINER` or `SECURITY INVOKER`. This is a common misconception: `current_user` is **not** rewritten to the view owner under DEFINER mode.
>
> **What actually changes between DEFINER and INVOKER:** the difference is **whose table GRANTS are used to read the tables referenced inside the view body**. This is the real security knob.
>
> - **`SECURITY DEFINER` (the default — UNSAFE for multi-tenant):** the view body runs with the **view owner's** grants. The owner typically has full SELECT on `analytics.events` (every tenant's rows). So the filter `WHERE m.username = current_user` evaluates against the owner's wide-open access to all partitions. The filter itself does correctly use the caller's `current_user` value — but the security boundary is gone, because:
>   - If `current_user` matches a row in `user_tenant_map` for tenant T, the view returns T's rows — but the view *had access to every tenant's data* and any bug, typo, or stale `user_tenant_map` entry can leak across tenants.
>   - If `current_user`'s JWT subject format doesn't match any `user_tenant_map.username` row (e.g., JWT issues `sub=acme-svc@auth.local` but the map stores `acme-svc`), the join returns zero rows — silent empty result, with no indication anything is wrong.
>   - There is **no enforcement of "tenant T's role can only read tenant T's data"** at the storage layer, because the owner's grants are what's being checked.
>
> - **`SECURITY INVOKER` (CORRECT for multi-tenant):** the view body runs with the **querying user's** grants. If tenant T's role lacks SELECT on `analytics.events`, the query fails with `Access Denied`. This is the correct isolation model: each tenant can read only the rows their role is granted to see, and the view's WHERE clause is layered on top of the role's grants as a second line of defense. A misconfigured `user_tenant_map` cannot expand a tenant's reach beyond what their role permits.
>
> **30-second test to confirm INVOKER is actually applied.** Connect as two different tenant principals and run `SELECT current_user, count(*) FROM analytics.my_events` from each. Under both DEFINER and INVOKER, `current_user` will correctly differ between the two sessions — that's not the diagnostic. The actual test is: **as a tenant principal, run `SELECT * FROM analytics.events` directly (the base table).** Under correct INVOKER + role configuration, this fails with `Access Denied`. Under DEFINER (or if the tenant role still has SELECT on the base table), it succeeds and returns every tenant's rows — that's the leak.

> **IMPORTANT — INVOKER mode requires the querying user to have SELECT on EVERY referenced table, not just the view.** Under `SECURITY DEFINER`, you only had to grant the tenant SELECT on the view; the owner's grants covered the joined lookup tables. Under `SECURITY INVOKER`, the tenant role must have SELECT on **every table the view body references**. For the dynamic view above, that means the tenant role needs SELECT on `config.user_tenant_map` in addition to whatever access the view itself provides:
>
> ```sql
> -- WITHOUT this grant, the tenant gets "Access Denied: Cannot select from
> -- table config.user_tenant_map" when they query the view — which looks
> -- exactly like the isolation broke, but is actually a missing grant.
> GRANT SELECT ON config.user_tenant_map TO ROLE tenant_1001_role;
> ```
>
> Some teams keep `user_tenant_map` in a separate schema with deliberately restricted access. Under INVOKER, you must either (a) grant tenant roles SELECT on that lookup table (the simplest fix), or (b) wrap the JOIN in a Trino-side helper view owned by an admin and have tenant roles SELECT from the helper view (re-introduces DEFINER risk; not recommended). Default to (a) — granting read on the mapping table is low-risk because the table only contains username-to-tenant rows the tenant already knows about themselves.

> **Tradeoff: blast radius of a bug in the dynamic-view pattern vs per-tenant views.** A bug in the `user_tenant_map` lookup table (wrong username mapping, stale entry, accidental row deletion, typo when onboarding a new tenant) breaks isolation for **ALL tenants simultaneously** — every tenant gets the wrong data, or no data, on the next query. With per-tenant hardcoded views (`tenant_acme.events` with `WHERE tenant_id = 'acme'`), a bug in one view affects only that one tenant; the other 79 are untouched. At 80 tenants, per-tenant views are still manageable — adding a tenant means one `CREATE VIEW` and one `GRANT`, which fits comfortably in an onboarding script — and they offer this **one-at-a-time failure mode**. The dynamic `current_user` pattern becomes compelling at **200+ tenants** where per-tenant view provisioning becomes a maintenance burden (large CREATE VIEW migrations on schema changes, role-grant sprawl, longer Hive Metastore catalog listings). Below ~150 tenants, prefer per-tenant views; above, the dynamic pattern's operational simplicity outweighs its single-point-of-failure risk — but only if you have CI tests that detect a stale `user_tenant_map` immediately.

### Trino system access control

Trino's **system access control** is a plugin that decides, for every query, whether a user can read a given table, column, or row.

**When in the query lifecycle does this happen?** A common shorthand is "Trino evaluates permissions before parsing" — that's wrong, and a security reviewer will catch it. The accurate version: **access control is evaluated after parsing but before execution.** Trino parses the SQL into an abstract syntax tree (AST), runs the analysis phase (which is when the access control plugin is consulted for each table, column, and view referenced), and only if every check passes does the query proceed to the execution stage where it would actually read data. The substantive guarantee you care about still holds: **Trino rejects the query during analysis, before touching any data in MinIO.** Unauthorized queries never reach the storage layer — they fail at the coordinator with a `Access Denied` error before a single Parquet file is opened.

Two common implementations on-prem:

- **File-based access control**: a JSON or properties file (`rules.json`) on the Trino coordinator that maps users/groups to allowed catalogs, schemas, and tables. Good for small numbers of static rules.
- **Open Policy Agent (OPA)**: an external policy engine. Trino calls out to OPA for every query, asking "can user X read table Y?". OPA evaluates a policy written in Rego (its policy language). Good for complex, dynamic rules that change without restarting Trino.

For multi-tenant, the typical setup is: file-based rules for ops staff, plus per-tenant Trino roles that only grant SELECT on the matching tenant view.

Configuration lives in `etc/access-control.properties` on the Trino coordinator pod.

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

Audit guardrail: include in the CI test that connects as `spark-ingest` and asserts `SELECT * FROM analytics.events` fails with `Access Denied`. Mirror it with a test that connects as `trino-query` and asserts `INSERT INTO analytics.events VALUES (...)` fails. If either succeeds, the role grants have drifted.

### The `system` catalog leak — tenant service accounts can snoop every other tenant's SQL

This is one of the most under-recognized cross-tenant data leaks in a Trino deployment, and it is **not** blocked by any of the view / role / `analytics` catalog rules above. It must be fixed separately by explicitly denying tenant principals access to the `system` catalog.

**The threat.** Trino exposes a built-in `system` catalog (the **Trino system connector**) whose tables surface live cluster state — including `system.runtime.queries`, an in-memory table that lists **every running and recently completed query from every user on the cluster**, with each row containing:

- `query` — the **complete SQL text** of the query, verbatim
- `user` — which Trino principal ran it (i.e., which other tenant)
- `query_id`, `state`, `created`, `started`, `end_time` — timing metadata
- `error_code` and `error_type` for failed queries

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
- **Bad**: If tenants are wildly uneven (one tenant has 100M rows, another has 1K), partitions are skewed. A skewed partition means one Parquet file is huge and another is tiny — both bad. Tiny files cause "small files problem" (many file opens, slow scans); huge files can't be parallelized well.

### Option B: Partition by `(tenant_id, day(event_ts))` — RECOMMENDED FOR MOST SAAS

```sql
CREATE TABLE analytics.events (...)
WITH (partitioning = ARRAY['tenant_id', 'day(event_ts)']);
```

- **Good**: A query like `WHERE tenant_id = 'acme' AND event_ts >= DATE '2026-05-01'` prunes to just Acme's files for that date range. This is the typical analytics access pattern (per-customer, per-time-window).
- **Good**: Spreads each tenant's data across multiple files by date, so even big tenants get parallelism.
- **Bad**: If you have many small tenants and short retention, you may still produce small files. Compact regularly with Iceberg's `OPTIMIZE` command via Trino, or rewrite via Spark.

### Hidden partitioning — Iceberg's nice feature

Iceberg has **hidden partitioning**: you declare the partition spec once when you create the table (e.g., `day(event_ts)`), and after that **users don't need to know the partition key**. They write `WHERE event_ts >= DATE '2026-05-01'` and Trino + Iceberg automatically translate that into the right partition filter behind the scenes.

In older Hive-style tables, users had to write `WHERE event_date = '2026-05-01'` separately from `event_ts`, or the query would scan everything. Iceberg removes that foot-gun. So your tenants writing normal SQL still get fast queries.

### Warning: don't change the partition spec casually

Iceberg supports partition evolution (changing the spec over time), but each change creates a different layout for new data. Pick a spec you can live with for years. `(tenant_id, day(event_ts))` is a safe default.

---

## Noisy neighbor

In any shared-table multi-tenant setup, a small number of tenants typically generate most of the data and most of the query load. If 3 of your 80 customers produce 90% of the events, their analytical queries can saturate the Trino cluster and slow everyone else down — even though their data is logically isolated.

The mitigation on Trino is **resource groups** (a Trino configuration that creates named query-admission queues — each group has caps on how much cluster CPU/memory it can use and how many of its queries can run at once; queries that exceed the caps wait in the queue instead of choking the cluster): a configuration that caps CPU, memory, and concurrent queries per tenant (or per role). You define groups in `etc/resource-groups.json` on the coordinator, e.g., "tenant Acme can use at most 20% of cluster memory and run at most 5 concurrent queries." This keeps a noisy tenant from starving the rest. For deep isolation needs, you can also run separate Trino clusters per tenant tier (e.g., one cluster for free-tier shared usage, one for enterprise customers), all reading from the same Iceberg tables in MinIO.

> **RESOURCE GROUP SELECTORS MATCH JWT PRINCIPAL NAMES, NOT TRINO ROLE NAMES.** In `resource-groups.json`, the `"user"` field in a selector is matched against the **connection's JWT principal** (the `sub` claim or username field from the JWT token) — it is NOT matched against a Trino role name. If the production stack uses JWT authentication (which it does), each tenant's service account authenticates with a JWT whose subject is the service account name (e.g., `acme-service-account`). Configure selectors to match that username: `"user": "acme-service-account"`, not `"user": "acme_role"`. If you configure the selector to match the role name and the JWT principal is different, the resource group silently never applies — the noisy tenant is uncapped and the isolation appears to work in tests but fails in production.

### Resource groups JSON — use the correct property names

This is the single most common config bug for resource groups: engineers invent property names like `maxRunning`, `maxMemoryPercent`, `maxCpuPercent`, or `queues`. **Those names do not exist in Trino** — the config file will load (Trino does not strictly validate unknown keys) but the limits will silently never apply. Use the exact property names from the [Trino resource groups docs](https://trino.io/docs/current/admin/resource-groups.html):

| Correct Trino property | Type | What it caps | Common WRONG name to avoid |
|---|---|---|---|
| `hardConcurrencyLimit` | integer | Max queries running concurrently in this group | ~~`maxRunning`~~ |
| `softMemoryLimit` | string (`"10GB"` or `"20%"`) | Soft memory cap; new queries queue when exceeded | ~~`maxMemoryPercent`~~ |
| `maxQueued` | integer | Max queries that can wait in the queue | (correct as-is) |
| `subGroups` | array of nested group objects | Child groups for hierarchical limits | ~~`queues`~~ |
| `hardCpuLimit` / `softCpuLimit` | duration string (`"1h"`, `"30m"`) | CPU-time cap per period (NOT a percentage) | ~~`maxCpuPercent`~~ (Trino has no such field) |

**Selector field name warning — `"user"` is a regex, but the field is NOT called `"userRegex"`:**

The selector field that matches the JWT principal is named **`"user"`** in Trino's resource-groups.json — not `"userRegex"`. The value is *interpreted as a Java regex*, which makes the name confusing, but the key itself is always `"user"`. `"userRegex"` does not exist in Trino and will be silently ignored:

```json
// CORRECT — field name is "user", value is a Java regex
{ "user": "acme-service-account", "group": "global.tenant_acme" }
{ "user": "tenant-.*",            "group": "global.tenants" }  // regex matching multiple tenants

// WRONG — "userRegex" is not a valid Trino selector field; silently ignored
{ "userRegex": "acme-service-account", "group": "global.tenant_acme" }
```

**Working `etc/resource-groups.json` for a multi-tenant cluster:**

```json
{
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "80%",
      "hardConcurrencyLimit": 100,
      "maxQueued": 1000,
      "subGroups": [
        {
          "name": "tenant_acme",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50
        },
        {
          "name": "tenant_beta",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50
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
      "group": "global.tenant_acme"
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
  LIKE iceberg.analytics.events INCLUDING ALL
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

Dropping an Iceberg table via Trino removes the table metadata from the Hive Metastore and — if the table was created with `location` pointing to an isolated prefix — removes the files from MinIO.

### Why SELECT * times out in the application layer

A direct `SELECT *` routed through your application times out for two reasons:
1. **Query timeout**: Application frameworks (Rails, Django, etc.) typically have a database query timeout of 30–60 seconds. A large analytical query runs for minutes.
2. **Memory pressure**: Streaming millions of rows through your application process uses large amounts of RAM. The query may be terminated by the OS or your k8s container memory limit before it completes.

The INSERT INTO ... SELECT pattern avoids both problems by writing results directly to MinIO without passing them through the application layer.

### Freshness note

The export captures a point-in-time snapshot of the data. Iceberg snapshot isolation means new events written after the export started do not appear in the results — which is correct behavior for an export.

---

## GDPR right to erasure — the correct 3-step sequence

When a customer invokes their right to be forgotten (GDPR Article 17, CCPA equivalent), you must guarantee their bytes are **physically gone from MinIO** — not just hidden from queries. This is a place where the obvious workflow (DELETE, verify COUNT = 0, sign off) is **wrong**. After a DELETE, the customer's original Parquet bytes are still sitting on MinIO. You are not GDPR-compliant until you complete all three steps below.

### Why the obvious workflow is wrong

Iceberg uses **MVCC** (multi-version concurrency control — every write creates a new immutable snapshot and the old snapshot is retained so you can time-travel or roll back). A DELETE does not erase Parquet files; it writes a small **delete file** that says "ignore these rows in those Parquet files." The original Parquet files (and the original rows inside them) remain on MinIO, referenced by older snapshots, until you explicitly expire those snapshots. A privacy auditor checking MinIO directly will still find the customer's bytes.

### The 3-step physical-removal sequence

Run all three steps, in order, on the production Trino 467 + Iceberg 1.5.2 + Spark + MinIO stack. Steps 2 and 3 are **Spark procedures** (the Iceberg system procedures are exposed via the Spark Iceberg extensions); they are not Trino DDL. Run them via the Spark job scheduler (Kubernetes CronJob or Airflow DAG that does a `spark-submit`).

> **CATALOG NAME — ENGINE MATTERS:** Steps 2 and 3 use `CALL iceberg.system.*`. The production Spark catalog is named `iceberg` (configured via `spark.sql.catalog.iceberg=org.apache.iceberg.spark.SparkCatalog`). Do NOT use `spark_catalog.system.*` — that catalog name does not exist in this production environment and will produce a "catalog not found" runtime error.

> **ENGINE NOTE — `CALL iceberg.system.*` IS SPARK SQL ONLY. IN TRINO 467, USE `ALTER TABLE ... EXECUTE`.** The production stack uses Trino 467 for SQL queries and Spark for maintenance procedures. The `CALL iceberg.system.*` syntax below is **Spark SQL syntax** and only works when submitted via `spark-submit` / Spark SQL session — pasting these `CALL` statements into a Trino client (DBeaver, `trino` CLI, JDBC) produces a syntax error because Trino does not implement the `CALL` procedure dispatch for the Iceberg connector. If you need to run maintenance from Trino, use the `ALTER TABLE ... EXECUTE` syntax instead:
>
> ```sql
> -- ENGINE NOTE: The CALL iceberg.system.* commands below run in Spark SQL only.
> -- In Trino 467, use ALTER TABLE ... EXECUTE syntax instead:
> --   ALTER TABLE iceberg.analytics.events EXECUTE rewrite_data_files
> --   ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '7d')
> --   ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '7d')
> ```
>
> Both forms perform the same underlying Iceberg operation — the difference is purely the engine submitting it. The production runbook should pick one engine per scheduled job and stick with it; mixing engines per step (one Spark CALL, one Trino ALTER TABLE EXECUTE) makes incident debugging harder.

**Step 1: DELETE the rows (Trino or Spark SQL — either works)**

```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

What happened on disk: Iceberg created a new snapshot whose manifests reference **delete files** (small markers listing the deleted row positions). The original Parquet data files are untouched. `SELECT COUNT(*) WHERE tenant_id = 'acme'` already returns 0, but the bytes are still on MinIO.

**Step 2: rewrite_data_files (Spark)**

```sql
-- Run via spark-submit, not Trino. Iceberg's system procedures live in the Spark catalog.
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => "tenant_id = 'acme'"
);
```

What happened on disk: Spark read the affected Parquet files plus the delete files, applied the deletes in memory, and wrote **new** Parquet files without Acme's rows. A new snapshot now points at the new files. **The old Parquet files (with Acme's bytes inside them) still exist on MinIO** because the previous snapshot still references them.

**Step 3: expire_snapshots (Spark) — this is the step that physically removes the bytes**

```sql
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp() - INTERVAL '0' DAY,
  retain_last  => 1
);
```

For GDPR specifically, override the default 30-day retention: pass `older_than => current_timestamp - interval '0' day` and `retain_last => 1` to aggressively expire **all** old snapshots immediately, keeping only the current one. The procedure walks the now-unreferenced manifest files, identifies Parquet data files no longer referenced by any live snapshot, and **issues S3 DELETE calls against MinIO**. Only after this step are the bytes physically gone.

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

### GDPR audit checklist

Use this exact checklist for compliance sign-off — do not sign off before the last item:

1. `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'` — succeeds.
2. `CALL spark_catalog.system.rewrite_data_files(table => 'analytics.events', where => "tenant_id = 'acme'")` — succeeds.
3. `CALL spark_catalog.system.expire_snapshots(table => 'analytics.events', older_than => current_timestamp() - interval '0' day, retain_last => 1)` — succeeds.
4. Verify the query layer: `SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme'` returns `0`.
5. Verify the storage layer: list the MinIO prefix for the table (`mc ls --recursive minio/lakehouse/warehouse/analytics/events/`) and confirm no Parquet files contain the tenant's data. For belt-and-suspenders, grep file metadata or sample a few files.
6. Repeat steps 1–5 for every Iceberg table that holds Acme data (events, orders, users, sessions, ...).
7. Now sign off.

If you sign off after only steps 1 and 2, the customer's bytes are still on MinIO and you are not GDPR-compliant.

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
-- WRONG for GDPR — keeps 30 days of old snapshots, including the one with Acme's data.
CALL iceberg.system.expire_snapshots(table => 'analytics.events');
```

The default `older_than` is "30 days ago" — so the snapshot containing Acme's bytes is **kept for 30 more days**. For routine compaction this is fine; for GDPR erasure it is a compliance violation. Always pass the explicit `older_than => current_timestamp() - interval '0' day, retain_last => 1` for erasure work.

### Quick reference

| Step | SQL | Where to run | What's on MinIO afterwards |
|---|---|---|---|
| 1. DELETE | `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'` | Trino or Spark | Original Parquet + delete files. **Bytes still there.** |
| 2. rewrite_data_files | `CALL iceberg.system.rewrite_data_files(table => '...', where => "tenant_id = 'acme'")` | Spark only | New Parquet (without Acme) + old Parquet still referenced by old snapshot. **Bytes still there.** |
| 3. expire_snapshots | `CALL iceberg.system.expire_snapshots(table => '...', older_than => current_timestamp() - interval '0' day, retain_last => 1)` | Spark only | Old snapshot expired, MinIO deletes orphaned Parquet. **Bytes physically gone.** |

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
    "queryId": "20260524_091234_00001_xyz",
    "query": "SELECT COUNT(*) FROM tenant_acme.events WHERE occurred_at >= DATE '2026-05-01'",
    "queryState": "FINISHED"
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
-- Example audit table schema
CREATE TABLE iceberg.analytics.query_audit_log (
    query_id      VARCHAR,
    trino_user    VARCHAR,
    principal     VARCHAR,
    query_text    VARCHAR,
    create_time   TIMESTAMP,
    end_time      TIMESTAMP,
    query_state   VARCHAR,
    error_code    VARCHAR,
    queried_cols  VARCHAR   -- JSON array of catalog.schema.table.column
)
USING iceberg
PARTITIONED BY (day(create_time));
```

### Using the HTTP event listener for query cost tracking

The same HTTP event listener that captures audit data also carries query cost metrics: CPU time, wall time, and bytes scanned. You can use these to build a per-tenant cost dashboard for CS conversations.

**Query cost fields in the event payload:**
- `statistics.elapsedTimeMs` — wall time (real seconds elapsed)
- `statistics.cpuTimeMs` — actual CPU processing time
- `statistics.totalBytes` — compressed Parquet bytes read from MinIO (the real I/O cost)
- `statistics.peakMemoryBytes` — peak memory usage per query

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

> **NOTE on bytes_scanned**: `totalBytes` in Trino stats is the compressed Parquet size read from MinIO, not the uncompressed data size. Parquet compression is typically 5–10x, so 5 GB scanned ≈ 25–50 GB of raw uncompressed data. Use the compressed figure for cost calculations (that's what you actually read off disk).

### What the audit trail answers for a security auditor

With the HTTP event listener enabled:

- **Who queried which tenant's data**: `context.user` (maps to tenant role) + `ioMetadata.inputs[n].tableName` and `.columns[]` (which tables and columns were touched)
- **When**: top-level `createTime` and `endTime` timestamps in the event payload
- **Exact SQL**: `metadata.query` — the full text of every query, verbatim
- **Whether it succeeded**: `metadata.queryState` (`FINISHED` vs `FAILED`)

A query like "show me every query user `acme-service-account` ran against `tenant_acme.events` in May 2026" becomes a standard SQL query against the audit table.

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
