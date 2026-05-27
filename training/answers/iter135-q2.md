# Iter135 Q2 — Answer

**Question**: "We already use OPA in our API layer — when a request comes in with a JWT token, OPA checks the claims and decides whether that user is allowed to call a given endpoint. Someone on our platform team mentioned that OPA can also plug directly into Trino as an authorization backend. I'm trying to understand what that would actually do. Right now, we have per-tenant views in Trino and tenant roles that can only SELECT from those views — so a tenant user can't touch the base table at all. If we wired OPA into Trino instead, would it replace that views+roles setup, or does it work alongside it? And what does OPA actually see when a Trino query comes in — does it know which tenant the query is for, and can it enforce row-level scoping, or does it only work at the table/column permission level like roles do?"

---

## OPA in Trino Is Alongside Your Views, Not a Replacement

Your current architecture — per-tenant views with hard-coded `WHERE tenant_id = 'acme'` plus roles that can only SELECT from those views — is solid. OPA in Trino works **as the enforcement layer behind that architecture**, not as a replacement. Think of it as the mechanism that enforces "tenant can touch the view but never the base table," replacing the SQL GRANT/REVOKE system with a centralized, dynamic policy engine that already speaks JWT.

---

## What OPA's Trino Plugin Actually Does

When you configure OPA as Trino's authorization backend (`access-control.name=opa` in `etc/access-control.properties`), you're making OPA Trino's **system access control plugin** — the component Trino calls before executing every query to make allow/deny decisions.

**What OPA can enforce in Trino:**

| What OPA controls | Example |
|---|---|
| Table/schema SELECT | Allow tenant to SELECT from their view; deny SELECT on base table |
| Catalog access | Deny all tenants access to the `system` catalog |
| Iceberg metadata tables | Deny access to `events$partitions`, `events$files`, `events$snapshots` |
| Column masking | Return a SQL expression that Trino substitutes for a sensitive column |
| Operation type | Allow SELECT, deny INSERT/DROP for tenant service accounts |

**What OPA does NOT enforce on its own:**

- **Row-level filtering.** OPA policy alone cannot say "return only rows where tenant_id = 'acme'." It makes an allow/deny decision at the table level, not a row-filter decision at the data level. Row-level filtering still comes from your view's `WHERE tenant_id = 'acme'` clause.

There is an extension called **row-filter mode** (discussed below) that can inject WHERE clauses, but that's distinct from basic allow/deny authorization.

---

## How OPA Knows Which Tenant Is Querying

OPA reads the JWT claims that Trino extracted during authentication. Your auth service already mints JWTs with a `tenant_id` claim — OPA policy can read that claim directly.

**The flow:**

1. Your backend obtains a JWT: `{"sub": "acme-service-account", "tenant_id": "acme", "iat": ..., "exp": ...}`
2. The backend presents this JWT to Trino via `Authorization: Bearer <token>` on the connection.
3. Trino validates the JWT signature and extracts the claims.
4. **On every query**, Trino calls OPA with the principal's identity (including claims) and the target table. Example OPA input:
   ```json
   {
     "action": {"operation": "SelectFromColumns", ...},
     "context": {
       "identity": {
         "user": "acme-service-account",
         "extraCredentials": {},
         "claims": {"tenant_id": "acme", "sub": "acme-service-account"}
       }
     },
     "resource": {"table": {"catalogName": "iceberg", "schemaName": "analytics", "tableName": "events"}}
   }
   ```
5. OPA's Rego policy reads `input.context.identity.claims.tenant_id` and makes the decision.

**Critical requirement:** `tenant_id` must be baked into the JWT at issue time, signed by your auth service. If OPA has to do a separate lookup (username → tenant_id via a mapping table), you've introduced latency and a correctness risk — a stale mapping could silently misdirect queries. Embed the claim in the token so OPA reads a cryptographically verified value.

---

## What OPA Cannot Do: Row-Level Filtering (and the Row-Filter Extension)

Standard OPA allow/deny authorization does not filter rows. If a tenant submits `SELECT * FROM analytics.events` (hitting the base table directly, not through a view), OPA can say "denied" — but it cannot say "allowed, but only show them acme's rows."

That gap is why your **view architecture remains essential**. The view does the row-level filtering:

```sql
CREATE VIEW iceberg.tenant_acme.events AS
  SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme';
-- OPA allows tenant_acme to SELECT from this view.
-- OPA denies tenant_acme from SELECT on iceberg.analytics.events (base table).
```

There is an OPA extension called **row-filter mode** that can close this gap for large deployments. When OPA returns a row-filter expression instead of just allow/deny, Trino automatically rewrites the query:

```sql
-- Tenant submits:
SELECT * FROM iceberg.analytics.events

-- OPA returns: {"rowFilters": [{"expression": "tenant_id = 'acme'"}]}

-- Trino rewrites and executes:
SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme'
```

**When row-filter mode makes sense:** if you have 100+ tenants and per-tenant view provisioning (`CREATE VIEW tenant_81.events AS ...`) is becoming a maintenance burden, row-filter mode lets you have one table and one OPA rule that injects the right filter per tenant. Adding tenant #100 is just a principal-to-tenant mapping update, not a `CREATE VIEW` statement.

**Why to keep views at your current scale:** row-filter mode moves all isolation responsibility into OPA policy. A single bug in the Rego rule (a wrong condition, a copy-paste error in the tenant mapping) could expose every tenant's data to every other tenant simultaneously. With views, a bug in one view affects one tenant; a bug in the row-filter mapping affects all. At 50 tenants with working views, stick with the defense-in-depth approach.

---

## The Three-Layer Defense-in-Depth Pattern

Your current setup plus OPA creates three independent layers:

```
Layer 1 (innermost):   View's WHERE clause hard-codes the tenant filter
                       → tenant_acme.events always returns WHERE tenant_id = 'acme'

Layer 2:               Role grant restricts tenant to the view only
                       → GRANT SELECT ON tenant_acme.events TO role_acme

Layer 3 (outer):       OPA policy denies base-table SELECT for tenant principals
                       → OPA returns "deny" for iceberg.analytics.events to acme principal
```

If any layer has a bug, the others still protect you. This is the recommended pattern for multi-tenant SaaS with regulatory requirements — three independent mechanisms means no single misconfiguration exposes data.

**OPA also adds protections your current setup doesn't cover:**

```
Layer 4:  OPA denies tenant access to system catalog
          → Prevents tenant from querying system.runtime.queries and seeing other tenants' running queries

Layer 5:  OPA denies tenant access to Iceberg metadata tables
          → Prevents SELECT on iceberg.analytics."events$partitions" (reveals customer roster and data volumes)
```

Without OPA (or equivalent access control), a tenant who knows the base table name could run `SELECT * FROM iceberg.analytics."events$files"` and see the partition values (tenant IDs, dates) for the entire table — a significant data leak even though they can't read the actual event data.

---

## The SECURITY DEFINER Risk — the View Owner Grant Is a Single Point of Failure

Trino views use **SECURITY DEFINER** mode by default. This means the view executes with the **view owner's** privileges, not the calling tenant's:

```sql
-- When acme-service-account runs:
SELECT * FROM iceberg.tenant_acme.events

-- Trino executes the view body as the view owner (e.g., trino-view-owner@internal):
SELECT * FROM iceberg.analytics.events WHERE tenant_id = 'acme'
-- The view owner must have SELECT on analytics.events. The tenant does not.
```

This is correct and necessary — the tenant never holds a direct base-table grant. But it creates **a critical operational risk:**

**If the view owner account loses SELECT on `analytics.events`, every tenant view breaks simultaneously.**

Every tenant sees "Access Denied" on every query, at the same moment, for the same root cause (the view owner's grant was revoked). The failure modes:
- An OPA bundle deployment has a typo in the view owner's allow-rule.
- A security audit inadvertently revokes the view owner's base-table grant.
- The view owner service account is rotated and the new identity isn't in OPA's policy yet.

When this happens, the Trino error message says the view failed — it doesn't say "the view owner lost base-table access." The root cause is non-obvious and the blast radius is total.

**Mitigations:**

1. **Use a dedicated, stable service account as the view owner** — e.g., `trino-view-owner@internal`. Not an individual engineer's account. Not a shared admin account that's touched during security audits.

2. **Add an explicit carve-out in OPA policy** that allows `trino-view-owner@internal` SELECT on `iceberg.analytics.*`. Mark this rule as protected — require a separate approval workflow to change it.

3. **Monitor with a synthetic query.** Every minute, your monitoring system should run:
   ```sql
   SELECT 1 FROM iceberg.tenant_acme.events LIMIT 1
   ```
   If this returns "Access Denied," page the on-call immediately. The mean time to detect a view-owner grant revocation should be < 2 minutes, not "until a tenant files a support ticket."

---

## Summary

| Question | Answer |
|---|---|
| Does OPA replace views + roles? | No — it's the enforcement layer that sits behind them |
| How does OPA know the tenant? | From the `tenant_id` claim in the JWT, which Trino extracts and passes to OPA |
| Can OPA enforce row-level filtering? | Not with standard allow/deny. Row-filter mode can inject WHERE clauses, but requires care |
| Should you switch to row-filter mode? | Not at current scale. Keep views for defense-in-depth |
| What does OPA add beyond your current setup? | Blocks `system` catalog access and Iceberg metadata table access that your current role grants may not cover |
| What's the key operational risk? | SECURITY DEFINER means view owner grant revocation breaks every tenant simultaneously — monitor it |
