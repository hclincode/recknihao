# Iter55 Q1 — Answer

**Question**: One of our customers has a data engineer who hooks up their BI tool directly to Trino using the credentials we issue them. They told us they were exploring around and found they could run a query like `SELECT * FROM iceberg.analytics."events$snapshots"` and it actually returned data — stuff like commit timestamps going back months, and notes on what type of operation happened. They also tried `"events$files"` and got back what looked like file paths and row counts. None of our view-based access setup blocked this. We assumed giving them SELECT only on the per-customer view would be sufficient. What exactly is exposed in these $snapshots and $files tables — is this just structural bookkeeping information or is actual customer data in there? And how do we block tenant users from being able to query these tables at all, while keeping our internal team's access working?

---

## Answer

This is a serious data isolation gap that your view-based access control doesn't catch — but it's fixable. Let me explain what's exposed, why views don't help, and how to block it.

### What `$snapshots` and `$files` actually expose

These are not row-level data, but they're sensitive structural intelligence about your entire system:

**`$snapshots` table** exposes:
- **Commit timestamps** — when each data load happened going back months
- **Operation type** — whether it was an append, overwrite, or other operation
- **Summary statistics per snapshot** — how many records were added or deleted in each operation
- This lets a tenant infer: which customers have data, how active they are, and when significant data changes occur

**`$files` table** exposes:
- **Individual Parquet file paths** on MinIO — if your file paths are structured like `s3a://lakehouse/tenant/acme/events/2026-05-24/part-001.parquet`, the tenant can see other customers' partition paths and learn who else exists in the system
- **Per-file row counts** — reveals event volume per file, which combined with dates shows customer activity levels
- **File sizes and column statistics** (min/max values) — shows the range and scale of data for other tenants
- This is structural espionage: a competitor could learn how many events competitors log, their data shape, and activity patterns

The key point: **No row-level data is exposed** (they can't read `event_id`, `user_id`, or `event_type`), but the metadata is damaging enough — it reveals which customers exist and their relative scale.

### Why your per-tenant Trino views don't block this

Your setup probably looks like this:

```sql
-- Base table (only ops can query directly)
CREATE TABLE analytics.events (...);

-- Per-tenant view (customer only sees their rows)
CREATE VIEW tenant_acme.events AS
  SELECT event_id, user_id, event_type, event_ts, payload
  FROM analytics.events
  WHERE tenant_id = 'acme';

-- Grant customer access to the view, not the base table
GRANT SELECT ON tenant_acme.events TO ROLE acme_role;
```

This works for row-level data — a query against `tenant_acme.events` returns only Acme's rows. **But `$snapshots` and `$files` bypass the view layer entirely.** When a tenant runs `SELECT * FROM iceberg.analytics."events$snapshots"`, they're querying Iceberg's **metadata layer**, not the data rows. The view's `WHERE tenant_id = 'acme'` filter doesn't apply to metadata tables — they show the entire table's structural information.

### The fix: deny `$`-suffix tables in your OPA policy

On your production stack (which uses OPA for authorization), you need an OPA Rego rule that rejects any query from a tenant principal where the table name contains a `$` character. This is a single rule that covers all metadata tables at once: `$snapshots`, `$files`, `$partitions`, `$history`, `$manifests`, `$entries`, etc.

> **Glossary**: A *principal* is any authenticated identity — a user, a service account, or an application. *Rego* is OPA's policy language — a file you write that says who can access what. A *carve-out* is an exception to a deny rule that explicitly allows a specific identity. *Deny-by-default* means: unless a rule explicitly allows something, it's blocked.

The specific Rego code belongs in your external governance document, not here. But conceptually, the rule is:

```
If the caller is a tenant principal (not internal/admin)
AND the query references a table name with '$' in it
THEN deny the query with "Access Denied"
```

For your internal data team (`admin`, `data-team`, `spark-ingest` principals), carve them out of this deny rule so they can still use metadata tables for debugging and maintenance.

### Verification recipe

After your OPA policy is deployed, the tenant role should be unable to run these queries — all should return `Access Denied`:

```sql
-- Run these as a tenant service account. All should fail.
SELECT * FROM iceberg.analytics."events$snapshots" LIMIT 1;
SELECT * FROM iceberg.analytics."events$files" LIMIT 1;
SELECT * FROM iceberg.analytics."events$partitions" LIMIT 1;
```

But the normal per-tenant view should still work:

```sql
-- This should still succeed — the view filter still applies
SELECT COUNT(*) FROM tenant_acme.events;
```

### Important: this is separate from the `system` catalog leak

You may also want to verify that tenants cannot query `SELECT * FROM system.runtime.queries` — that's a different metadata leak path (the `system` catalog, not Iceberg metadata tables) that requires a separate OPA rule denying access to the `system` catalog for tenant principals. Both rules are needed to fully seal the metadata leakage.

### Action items

1. **Alert your OPA/governance team** that Iceberg metadata tables are currently exposed to tenants.
2. **Add a rule to the OPA policy** that denies table-name access containing `$` for tenant principals.
3. **Add a CI test** that authenticates as a tenant role and asserts `SELECT 1 FROM iceberg.analytics."events$snapshots"` returns `Access Denied`.
4. **Do the same for the `system` catalog** if that hasn't already been blocked separately.

This is a high-priority security fix because the metadata leakage is silent — tenants find it by accident, but once they know the `$`-suffix pattern exists, they can explore systematically. Block it now before it becomes a contractual or compliance issue.
