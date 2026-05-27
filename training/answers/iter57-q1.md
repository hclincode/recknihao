# Iter57 Q1 — Answer

**Question**: We've had a few incidents over the past month where our analytics dashboards get slow for all customers at the same time, and we suspect one heavy-query customer is the cause — probably one of our enterprise accounts running a huge data export or a badly-written custom report. How do we actually figure out which customer is the culprit when this is happening live? And once we set up resource group limits per tenant, how do we verify the limits are actually being applied rather than silently not working?

---

## Answer

This is a classic "noisy neighbor" incident — one tenant's workload saturating the shared Trino cluster and starving everyone else. The diagnosis and fix split into two parts: **real-time identification** and **prevention with verification**.

### Part 1: Identifying the noisy tenant in real time

When your dashboards slow down, your diagnostic tool is `system.runtime.queries` — an in-memory table listing every running and recently completed query on the cluster. Connect as an admin user:

```sql
SELECT
    query_id,
    user,
    state,
    elapsed_time,
    query
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY elapsed_time DESC;
```

**What to look at:**
- `user` — the Trino principal (tenant's service account name). This identifies the customer.
- `state` — `RUNNING` means executing; `QUEUED` means waiting because resource limits are hit.
- `elapsed_time` — long-running queries are likely suspects.
- `query` — the actual SQL. `SELECT *` with no filters, huge LIMIT clauses, or unfiltered joins across large tables are typical culprits.

To aggregate by tenant and see the full picture:

```sql
SELECT
    user,
    COUNT(*) AS total_queries,
    SUM(CASE WHEN state = 'RUNNING' THEN 1 ELSE 0 END) AS running,
    SUM(CASE WHEN state = 'QUEUED' THEN 1 ELSE 0 END) AS queued
FROM system.runtime.queries
GROUP BY user
ORDER BY running DESC;
```

If one tenant has 20 running queries and everyone else has 1–2, that's your noisy neighbor.

### Part 2: Immediate relief — kill the offending query

Once you identify the query_id, terminate it immediately:

```sql
CALL system.runtime.kill_query(
  query_id => '20260524_091234_00001_abcde',
  message  => 'Throttling noisy query — see incident #4421'
);
```

This releases all cluster memory held by that query. Dashboard queries for other customers should recover within seconds. Use this as your first action during a live incident.

### Part 3: Prevention with resource groups

Configure resource groups — Trino's per-tenant query-admission controls. A resource group caps:
- **Concurrent queries** — max queries running at once from that tenant
- **Memory usage** — soft and hard memory limits per tenant
- **Queue size** — how many queries can wait in that tenant's queue (beyond which, new queries are rejected)

**`etc/resource-groups.json` on the Trino coordinator:**

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
      "user": "data-team",
      "group": "global.internal_admin"
    }
  ]
}
```

With `hardConcurrencyLimit: 5`, Acme's 6th query waits in the queue instead of running — protecting all other tenants.

**Critical: `selectors` routes tenants to their group using the JWT principal name — NOT the Trino role name.** The `user` field matches the `sub` claim from the JWT token (the service account name). If you write the role name instead, the selector silently never matches and the limit never applies.

```json
// CORRECT — "user" field, value is the JWT principal (service account name)
{ "user": "acme-service-account", "group": "global.tenant_acme" }

// WRONG — "userRegex" is not a valid Trino field; silently ignored
{ "userRegex": "acme-service-account", "group": "global.tenant_acme" }

// WRONG — Trino role name, not the JWT sub claim
{ "user": "acme_role", "group": "global.tenant_acme" }
```

### Part 4: Verifying resource groups are actually working

Resource groups fail silently — the JSON loads without errors even if misconfigured, and limits silently don't apply. You must actively test.

**Test 1: Verify selector matched**

Submit a query as the Acme service account. While it's running, check which resource group it was routed to:

```sql
SELECT query_id, resource_group_id
FROM system.runtime.queries
WHERE user = 'acme-service-account';
```

The `resource_group_id` column should show `global.tenant_acme`. If it shows NULL or a default group, the selector didn't match. Fix the config.

**Test 2: Trigger the concurrency limit**

Submit 6 queries simultaneously as the Acme service account. Then check:

```sql
SELECT query_id, user, state
FROM system.runtime.queries
WHERE user = 'acme-service-account'
ORDER BY created;
```

Expected: 5 queries show `RUNNING`, 1 shows `QUEUED`. If all 6 show `RUNNING`, the limit is not applied — check property names.

**Test 3: Use exact property names — Trino silently ignores wrong names**

| Correct Trino property | Caps what | WRONG name (silently ignored) |
|---|---|---|
| `hardConcurrencyLimit` | Max concurrent queries | `maxRunning` |
| `softMemoryLimit` | Memory limit (string like `"20%"`) | `maxMemoryPercent` |
| `maxQueued` | Max waiting in queue | `queueSize` |

If you write `"maxRunning": 5` instead of `"hardConcurrencyLimit": 5`, Trino loads the file successfully, logs no warning, and silently ignores the limit.

### Summary

| Step | When | Tool |
|---|---|---|
| Diagnose noisy tenant | During incident | `system.runtime.queries` — check `user`, `elapsed_time`, `query` |
| Immediate relief | During incident | `CALL system.runtime.kill_query()` |
| Prevention | After incident | `resource-groups.json` with `hardConcurrencyLimit` per tenant |
| Verification | After deploying | Submit test queries, confirm `QUEUED` state in `system.runtime.queries` |

Resource groups fail silently — the verification step is not optional. Always confirm the `resource_group_id` is correct and that a 6th query shows `QUEUED` before trusting the configuration is working.
