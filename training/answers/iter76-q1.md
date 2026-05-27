# Iter76 Q1 — Answer

**Question**: We're running a single shared Trino cluster. Enterprise tenants' heavy queries are starving smaller tenants. What are Trino resource groups, how do they work, and can I configure them without restarting Trino every time I onboard a new tenant?

---

## Answer

Trino **resource groups** are exactly what you need for this situation. They're not a CPU cap per user — they're a query-queuing system that lets you allocate guaranteed shares of your cluster to different tenants so one heavy customer can't starve the smaller ones.

### What resource groups actually do

Resource groups work like traffic lanes for Trino queries. You define named groups (one per tenant, or one per tenant tier) with limits on:

- **Memory**: "This tenant can use at most 20% of cluster memory"
- **Concurrent queries**: "This tenant can run at most 5 queries simultaneously"
- **Queue depth**: "At most 50 queries can wait in this tenant's queue"

When a tenant's queries hit these limits, new ones don't fail — they **wait in a queue** until an earlier query finishes and frees up resources. Enterprise customers get good performance; smaller tenants don't hang; nobody gets refused outright.

### Yes, you can give guaranteed cluster shares

Here's an example for your situation — 3 heavy enterprise tenants, 77 smaller ones:

```json
{
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "80%",
      "hardConcurrencyLimit": 100,
      "subGroups": [
        {
          "name": "tenant_acme",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50
        },
        {
          "name": "small_tenants",
          "softMemoryLimit": "30%",
          "hardConcurrencyLimit": 50,
          "maxQueued": 300
        }
      ]
    }
  ],
  "selectors": [
    { "user": "acme-service-account",  "group": "global.tenant_acme" },
    { "user": "beta-service-account",  "group": "global.tenant_acme" },
    { "user": ".*-service-account",    "group": "global.small_tenants" }
  ]
}
```

Now when Acme's dashboard pulls a year of data, it consumes from its 5-concurrent-query slot. After 5 queries, the 6th queues. Meanwhile smaller tenants query from their own 50-concurrent allocation and experience normal latency — they never wait for Acme.

### No restart required — if you use DB-backed config

**Default behavior (file-based)**: Changes to `etc/resource-groups.json` require a Trino coordinator restart to take effect. New tenant onboarding means push the updated JSON and restart — which briefly drops in-flight queries.

**Better option**: Trino has a **database-backed resource group manager** that reads limits from a Postgres or MySQL table instead of a JSON file. This **hot-reloads every ~1 second** — no restart needed. New tenant limits take effect within seconds of an INSERT or UPDATE to the config table. The tradeoff is one extra dependency (a small Postgres instance), but if you're onboarding 15–20 tenants per month this is worth it.

To enable it:
```properties
# config.properties
resource-groups.configuration-manager=db
resource-groups.config-db-url=jdbc:postgresql://pg-host:5432/trino_config
resource-groups.config-db-user=trino
resource-groups.config-db-password=...
```

Once enabled, you manage tenant limits with SQL instead of JSON files — no coordinator restart ever needed for resource group changes.

### Critical gotcha: selectors match the JWT principal

Your production environment uses JWT authentication. Resource group selectors match the **JWT principal name** (the `sub` field of the token), not Trino role names. If you configure:

```json
{ "user": "acme_role", "group": "global.tenant_acme" }
```

But the JWT has `sub: "acme-service-account"`, the selector won't match. Acme's queries silently land in the uncapped default group and the noisy-neighbor problem continues — while the config looks correct. Always match the JWT principal:

```json
{ "user": "acme-service-account", "group": "global.tenant_acme" }
```

### Live relief right now

If you're getting support tickets right now, kill the offending query immediately:

```sql
CALL system.runtime.kill_query(
  query_id => '20260524_134522_00123_abcde',
  message  => 'Noisy neighbor throttling'
);
```

Find the query ID via `SELECT query_id, user, state FROM system.runtime.queries WHERE state = 'RUNNING' ORDER BY elapsed_time DESC`. This stops the runaway query while you deploy the resource group config.

### No separate cluster needed

You're right to avoid per-customer clusters. Resource groups on a single shared cluster isolate query load without the operational overhead of separate Trino deployments.
