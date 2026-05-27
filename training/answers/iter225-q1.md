# Iter 225 Q1 — OPA Row-Filter + Cross-Catalog Views: Which Identity Does OPA Use?

## Answer

When a user queries a view defined in your Iceberg catalog that joins tables from multiple catalogs (including billing_mysql), **OPA still enforces row-level access control against the underlying tables** — but which identity OPA uses depends on whether your view is `SECURITY DEFINER` (the default in Trino) or `SECURITY INVOKER`.

### The Two-Check OPA Model for SECURITY DEFINER Views

When a caller queries a SECURITY DEFINER view, Trino issues **two distinct OPA checks with two different identities.**

1. **View-level check** — Trino asks OPA: "Can the *caller* SELECT from this view?" This uses the **caller's identity** (e.g., `alice@acme`). Any row-level filters configured on the view object itself fire here.

2. **Base-table checks** — Trino asks OPA: "Can [someone] SELECT from each underlying table the view references?" For each table (including `billing_mysql.app.invoices`), this check uses the **view owner's identity**, not the caller's.

In OPA decision logs, you'll see this as two separate `GetRowFilters` operations:
- One against `iceberg.analytics.billing_summary` (the view) with identity = `alice@acme`
- One against `billing_mysql.app.invoices` with identity = whoever owns the view (probably a service account or admin)

### The Security Implication: "Privilege Escalation" Through Views

Here is the trap: **if the view owner is a privileged user or service account with broad access to billing_mysql, then every user querying that view can read rows from billing_mysql that they would NOT be able to read if they queried it directly.**

Example:
- Alice is a regular analyst with OPA row filters blocking her from invoices where `customer = 'secret-competitor'`.
- You create a view `iceberg.analytics.billing_summary` owned by `svc-analytics` (a service account with full MySQL access).
- Alice queries the view. OPA evaluates the base-table check on `billing_mysql.app.invoices` as `svc-analytics`, who has no row restrictions. Alice sees the restricted invoices through the view. ✗

**This is NOT a bypass of your OPA policy.** OPA is working correctly — you've architected a situation where the policy doesn't apply to Alice at the point she needs restriction.

### How to Enforce Row-Level Security Through Views

**Option 1: Attach the row filter to the VIEW, not the base table (recommended for SECURITY DEFINER).**

Configure your OPA row filter for `iceberg.analytics.billing_summary` rather than `billing_mysql.app.invoices`. When Alice queries the view, Trino's first check evaluates the filter under Alice's identity and injects `WHERE customer != 'secret-competitor'` before the view body expands. This applies to all base-table joins inside the view:
- Alice keeps no direct grants to billing_mysql.
- Row-level enforcement is tied to the caller's identity.
- The view is her only access path.
- You keep SECURITY DEFINER for tenant isolation.

**Option 2: Make the view owner a restricted user.**

Own the view with a restricted principal that has the same OPA row-filter restrictions as end users. When OPA evaluates the base-table check under that restricted identity, it enforces the same boundaries. Harder to maintain (view owner permissions must stay in sync with user permissions) but works.

**Option 3: Use SECURITY INVOKER (when appropriate).**

Switch the view to `SECURITY INVOKER`. The caller's identity is used for both checks — the caller's row filters apply to the view AND base tables. This works only if callers have direct SELECT grants on all base tables, which defeats the isolation model you're probably building with multi-catalog views.

### Verification: Check OPA Decision Logs

When Alice queries the view, look for `GetRowFilters` operations in your OPA decision logs:

```json
// Check 1: view-level, caller identity
{
  "input": {
    "action": {"operation": "GetRowFilters"},
    "context": {"identity": {"user": "alice@acme"}},
    "resource": {
      "table": {"catalogName": "iceberg", "schemaName": "analytics", "tableName": "billing_summary"}
    }
  },
  "result": [{"expression": "customer != 'secret-competitor'"}]
}

// Check 2: base-table, view owner identity
{
  "input": {
    "action": {"operation": "GetRowFilters"},
    "context": {"identity": {"user": "svc-analytics"}},
    "resource": {
      "table": {"catalogName": "billing_mysql", "schemaName": "app", "tableName": "invoices"}
    }
  },
  "result": []  // No filter for svc-analytics → Alice can see all rows through the view
}
```

If the base-table check returns no filter for the view owner, your row-level control is not enforced at MySQL for end users querying through the view. Fix it by attaching the filter to the view object (Option 1).

### Key Takeaway

**A user cannot bypass OPA row filtering by querying through a view — OPA still fires `GetRowFilters` against the underlying tables.** But for a SECURITY DEFINER view, OPA uses the **view owner's identity** for those base-table checks. If the view owner is privileged and the caller is not, the caller may see data they can't access directly. Fix this by attaching row filters to the view object itself, keyed to the caller's identity, rather than only to the MySQL base table.
