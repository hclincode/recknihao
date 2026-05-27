# Iter 189 Q1 — OPA + CREATE CATALOG Privilege

## Answer

## What OPA Actually Intercepts

**The short answer**: OPA does intercept CREATE and DROP CATALOG operations in Trino. OPA is a **system access control plugin** that evaluates **every query** against a policy before it executes. OPA receives the full input document including `input.action` (which contains operations like `SelectFromColumns`, `INSERT`, `ExecuteQuery`, etc.) and `input.resource` (the catalog, schema, table being accessed). This means Trino's authorization layer sends these DDL catalog operations to OPA for evaluation.

However, the resources do NOT contain specific documentation about the exact `input.action` operation name for CREATE CATALOG or DROP CATALOG, or concrete Rego rules that specifically target catalog-level operations.

## What the Resources DO Cover

The production environment uses **OPA as the authorization enforcement layer** — not file-based access control. When you configure Trino with OPA, every query decision goes through OPA before execution. The resources explain that:

1. **OPA gets called for every query** with a decision context containing the user, groups, and resource details
2. **OPA can return allow/deny decisions** or (for certain table operations) inject row filters or column masks
3. **The correct three-layer defense model on your stack** (when OPA is configured) is:
   - Layer 1: Per-tenant view's WHERE clause (hard-coded tenant filter)
   - Layer 2: OPA deny rules that block base-table access for non-admin principals
   - Layer 3: OPA deny rules that block access to `system` catalog tables and Iceberg metadata tables (those with `$` suffixes)

4. **Rego rules encode the policy** — your OPA bundle contains `.rego` files that declare rules like "deny if the catalog is `system` and the principal is not in the admin list"

## What's Missing from Resources

The resources do NOT provide:

- The exact Trino action name for CREATE CATALOG and DROP CATALOG (e.g., is it `CreateCatalog`, `CatalogCreate`, `AdminOperation`?)
- Concrete Rego rule examples for restricting catalog creation/deletion to the platform team only
- Explanation of whether CREATE/DROP CATALOG is treated as a standard `action.operation` in the OPA decision context, or as a separate admin gate

## Practical Next Steps

Per `prod_info.md`, **specific OPA Rego policies are defined in an external governance document not yet available in this repo**. Your next steps:

1. **Check if your OPA bundle already has rules for catalog operations** — the platform team who set up OPA may already have included this.
2. **Consult your external governance document** — that is where the detailed permission model and specific Rego rules live, including (hopefully) catalog-level restrictions.
3. **Test empirically on your cluster**: connect as a regular engineer and try `CREATE CATALOG test_cat USING ...` — if it fails with `Access Denied`, your OPA policy is already enforcing this. If it succeeds, you need to add the rule.
4. **If you need to write the rule yourself**, reach out to your platform team or OPA maintainers. The Rego pattern will likely be similar to the `system` catalog deny rule shown in the existing resources, but adapted for whatever Trino names the CREATE CATALOG action (check your Trino audit logs for the exact action string).

The resources confirm OPA is the right authorization layer for your stack and that it intercepts all operations — but the specific Rego policy for catalog management operations belongs in your external governance document.
