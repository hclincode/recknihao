# Feedback — Iter 66 Q2 (Multi-tenant analytics: automated tenant provisioning)

**Question**: Automated provisioning workflow when new SaaS customers sign up — what specific steps, in what order, against which systems, so a new tenant can query analytics within seconds with no manual intervention.

**Final score**: **4.00 / 5** (Completeness 4.5, Accuracy 3.0, Clarity 5.0, No hallucination 3.5)

**Status**: Passes the 3.5 threshold, but contains one critical factual error that would break the provisioning script in production.

---

## What the answer did well

1. **All 5 expected-coverage points are present.** The 6-step ordered workflow (CREATE ROLE → GRANT ROLE TO USER → CREATE VIEW → GRANT SELECT ON VIEW → REVOKE base table → OPA system+metadata denial) maps cleanly to the rubric. The OPA discussion in Step 6 correctly defers specifics to the external governance document (per `prod_info.md`).

2. **Excellent failure-mode table** distinguishing visible errors (steps 2 and 4 → tenant gets "Access Denied" and reports it) vs silent security breaches (steps 5 and 6 → tenant reads other tenants' data and never reports it). This is exactly the right framing for a SaaS engineer thinking about production risk.

3. **Concrete Python automation example** using `trino.dbapi.connect` and `trino.auth.JWTAuthentication` — correct API surface per the trino-python-client GitHub repo.

4. **Strong verification section** with 5 distinct CI checks: own view succeeds, base table denied, other tenant's view denied, system catalog denied, and `DISTINCT tenant_id` check on the view (which detects view-filter bugs before the tenant ever runs a real query).

5. **End-to-end timing** ("under 10 seconds") gives the engineer a concrete expectation they can build a UX around ("Your analytics access is ready").

---

## Critical issues

### 1. `CREATE ROLE IF NOT EXISTS` is INVALID Trino syntax (Accuracy issue)

The answer's Step 1 example, and the Python `steps` list, both use:

```sql
CREATE ROLE IF NOT EXISTS acme_role;
```

Per the official Trino documentation (https://trino.io/docs/current/sql/create-role.html), the documented syntax is:

```
CREATE ROLE role_name
[ WITH ADMIN ( user | USER user | ROLE role | CURRENT_USER | CURRENT_ROLE ) ]
[ IN catalog ]
```

**There is no `IF NOT EXISTS` clause.** A SaaS engineer copy-pasting the Python `steps` list into production will get a syntax error on the very first step for every new tenant. The intended idempotency must be implemented via try/except (the same way the answer already does for the GRANT step).

**This is a propagated error from the resource.** `resources/05-multi-tenant-analytics.md` does NOT use `CREATE ROLE IF NOT EXISTS`, but the resource also does not warn that Trino lacks this Postgres-friendly construct. The weak-responder likely hallucinated it from Postgres habit. Teacher should add an explicit anti-pattern callout.

### 2. Missing `SECURITY INVOKER` on the CREATE VIEW

The resource has a very prominent warning:

> "Trino views default to SECURITY DEFINER. For tenant isolation to work, the view MUST be created with `SECURITY INVOKER`. Otherwise the view runs with the view owner's broad table grants, which collapses isolation."

The answer's Step 3 CREATE VIEW omits this. For per-tenant hardcoded views (`WHERE tenant_id = 'acme'`), the filter is baked in and partial isolation still holds — but a provisioning runbook is exactly where this gets locked in for years, so the omission matters for defense-in-depth.

### 3. Minor inconsistency in the Python view DDL

The standalone SQL example uses an explicit column list:

```sql
SELECT event_id, user_id, event_type, event_ts, payload
```

The Python automation uses `SELECT *`. Small inconsistency; either is OK but pick one.

---

## Action for the teacher

1. **Add anti-pattern callout to `resources/05-multi-tenant-analytics.md`** in the tenant-provisioning section:
   > **TRINO DOES NOT SUPPORT `CREATE ROLE IF NOT EXISTS`.** Unlike Postgres, Trino's CREATE ROLE has no IF NOT EXISTS clause. Provisioning scripts must catch the "Role already exists" error and treat it as success — same pattern as for already-granted GRANT statements. The documented syntax is `CREATE ROLE role_name [ WITH ADMIN ... ] [ IN catalog ]`.

2. **In the provisioning code example**, the per-tenant view DDL should explicitly include `SECURITY INVOKER`:
   ```sql
   CREATE OR REPLACE VIEW iceberg.tenant_acme.events
   SECURITY INVOKER
   AS SELECT ... WHERE tenant_id = 'acme'
   ```
   With a one-line comment that DEFINER (the default) defeats the per-tenant role boundary.

3. **(Optional)** A short reference Python provisioning skeleton in the resource that catches both "Role ... already exists" and "Grant ... already exists" errors, so future answers stop reaching for IF NOT EXISTS.

---

## Source verification

- Trino CREATE ROLE syntax: https://trino.io/docs/current/sql/create-role.html (no IF NOT EXISTS)
- Trino GRANT ROLE syntax: https://trino.io/docs/current/sql/grant-roles.html (confirmed correct in answer)
- Trino CREATE VIEW with OR REPLACE: https://trino.io/docs/current/sql/create-view.html (confirmed correct in answer; SECURITY DEFINER is default — missing in answer)
- trino-python-client (JWTAuthentication, dbapi.connect): https://github.com/trinodb/trino-python-client (confirmed correct in answer)
