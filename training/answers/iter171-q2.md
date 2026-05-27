# Iter 171 Q2 — OPA for Trino Catalog Authorization

## Answer

Yes, Trino knows how to talk to OPA natively — it's a built-in plugin system. You don't wire anything up yourself; you configure Trino to call your OPA endpoint and OPA evaluates your Rego policy for every query decision.

### (1) How OPA integrates: System access control plugin

Trino has a **system access control** plugin architecture that intercepts every query-related action before execution. Configuration is simple — add two lines to `etc/access-control.properties` on your Trino coordinator:

```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
```

That's it. Trino handles the HTTP calls to OPA; you write the Rego policy at the endpoint you specify.

### (2) Granularity: Catalog → Schema → Table → Column

OPA checks work at **multiple granularities**. The same policy can enforce all of them:

- **Catalog**: "Can you touch the `iceberg` catalog at all?" (deny access to `system` or your internal `postgres` catalog entirely)
- **Schema**: "Can you touch the `analytics` schema within that catalog?"
- **Table**: "Can you select from `analytics.events`?"
- **Column**: "Can you select the `email` and `ssn` columns?" (OPA can mask columns, replacing them with masked expressions like `'****'` or hashed values)

For your use case: deny tenants the `postgres` catalog at the catalog level, allow `iceberg.analytics.*` at the table level, optionally mask sensitive columns.

### (3) When the check happens: Query analysis time, before execution

OPA checks happen **before the query runs**:

1. Client submits a query with a JWT in the `Authorization: Bearer <token>` header.
2. Trino authenticates the JWT, extracts a username, and resolves it to a principal.
3. Trino's analyzer parses the SQL and identifies what tables and columns are being touched.
4. **Before executing anything**, Trino calls out to OPA for each table/column: "Can `acme--svc` read `iceberg.analytics.events`?" OPA evaluates your policy and returns allow/deny.
5. If OPA denies, Trino rejects the query with `Access Denied` — the query is never sent to the storage engine.

This means OPA is fast (fails early) and auditable.

### (4) What Trino sends to OPA: Username + groups, NOT raw JWT claims

This is the most important constraint. Trino extracts the **username** from your JWT and passes it to OPA, but **discards the rest of the JWT before OPA sees it**. OPA receives:

```json
{
  "action": {
    "operation": "SelectFromColumns",
    "resource": {
      "table": {
        "catalogName": "iceberg",
        "schemaName": "analytics",
        "tableName": "events"
      },
      "columns": ["user_id", "event_type", "timestamp"]
    }
  },
  "context": {
    "identity": {
      "user": "acme--svc",
      "groups": []
    },
    "softwareStack": {
      "trinoVersion": "467"
    }
  }
}
```

**No JWT claims. No tenant ID claim. No custom fields.** OPA only sees the extracted `user` string and any group claims Trino explicitly forwards (configured via `http-server.authentication.jwt.groups-field=groups` in `config.properties`).

### (5) Mapping JWT principals to Trino users for tenant isolation

Since OPA can't see the raw JWT, you must encode the tenant identity in the **Trino username itself**. Two production patterns:

**Pattern 1 — Tenant ID prefix in username (simplest, recommended):**
Configure your JWT auth so that when a user from tenant Acme authenticates, the extracted username is `acme--svc` (tenant ID + double-dash separator + service account name). Then in your Rego policy:

```rego
# Extract "acme" from "acme--svc"
tenant := split(input.context.identity.user, "--")[0]

allow {
  # Allow access to iceberg catalog for any tenant
  input.action.resource.table.catalogName == "iceberg"
}

allow {
  # Allow access to postgres only for internal service accounts
  input.action.resource.table.catalogName == "postgres"
  startswith(input.context.identity.user, "internal--")
}
# Explicit deny: if neither rule fires, the default is deny
```

The double-dash `--` is a safe separator because tenant IDs (UUIDs, slugs) don't contain `--`.

**Pattern 2 — OPA data bundle lookup (more flexible):**
Maintain a JSON file in your OPA bundle that maps usernames to tenants:
```json
{ "tenant_map": { "acme-svc": "acme", "beta-svc": "beta" } }
```
Then in Rego: `tenant := data.tenant_map[input.context.identity.user]`

### (6) OPA decision logging for audit

OPA maintains a **durable decision log** of every policy evaluation. Each log entry records:
- Timestamp of the decision
- The input document (action, resource, identity)
- Which policy rules fired
- The allow/deny outcome
- Latency of policy evaluation

This is separate from Trino's query event log. The OPA decision log answers **who tried to access what and whether it was allowed**; the Trino query event log answers **what SQL ran and how expensive it was**.

Enable it in your OPA configuration:
```yaml
decision_logs:
  console: true  # writes to OPA stdout; pipe to your logging backend
```

For your use case, build a dashboard that watches for deny events on the `postgres` catalog — any tenant principal hitting that catalog is either a misconfiguration or a security incident.

### Full configuration for your use case

**`etc/access-control.properties`** on Trino coordinator:
```properties
access-control.name=opa
opa.policy.uri=http://opa:8181/v1/data/trino/allow
opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters
```

**OPA Rego policy sketch:**
```rego
tenant := split(input.context.identity.user, "--")[0]

allow {
  input.action.resource.table.catalogName == "iceberg"
}

allow {
  input.action.resource.table.catalogName == "postgres"
  startswith(input.context.identity.user, "internal--")
}
```

When customer A's JWT is presented, your JWT authenticator extracts the username to something like `acme--svc`. OPA sees this username, extracts the `acme` tenant prefix, and applies the policy. Access to `postgres` catalog is denied; access to `iceberg` catalog is allowed. Every attempt is recorded in the OPA decision log.
