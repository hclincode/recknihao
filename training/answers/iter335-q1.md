# Answer to Q1: Per-Tier Query Time Limits in Trino (Iter 335)

The issue you're hitting is a common misconfiguration: **resource groups in Trino do NOT have a built-in property to kill individual queries after a time limit.** They only control concurrency, memory, and aggregate CPU — but they have no mechanism to say "kill any query in this group running longer than 5 minutes."

What you're missing is the **session property manager** — a separate Trino component that works *alongside* resource groups to enforce per-query time limits. This is the documented Trino pattern for different execution time limits per tenant tier.

## The actual solution: Session property manager

You need to set up two additional files on your Trino coordinator:

**File 1: `etc/session-property-config.properties`**
```properties
session-property-config.configuration-manager=file
session-property-manager.config-file=etc/session-property-manager.json
```

**File 2: `etc/session-property-manager.json`**
```json
{
  "defaultSessionProperties": {
    "query_max_execution_time": "8h"
  },
  "sessionPropertySpecs": [
    {
      "name": "free-tier-limits",
      "match": {
        "group": "global.free_tier"
      },
      "sessionProperties": {
        "query_max_execution_time": "5m",
        "query_max_run_time": "10m"
      }
    },
    {
      "name": "enterprise-limits",
      "match": {
        "group": "global.enterprise_tier"
      },
      "sessionProperties": {
        "query_max_execution_time": "30m",
        "query_max_run_time": "60m"
      }
    }
  ]
}
```

## What these properties do

- **`query_max_execution_time`** — wall-clock time from when the query *starts executing*. Free-tier queries die after 5 minutes, enterprise after 30 minutes. Trino kills them with `EXCEEDED_TIME_LIMIT`.
- **`query_max_run_time`** — wall-clock time from when the query is *submitted*, including time sitting in the queue. Set it longer than `query_max_execution_time` as a backstop.

The `"group"` field is a Java regex matched against the resource group path (the same path you see in `system.runtime.queries.resource_group_id`). Free-tier queries landing in `global.free_tier` automatically get a 5-minute timeout. Enterprise queries in `global.enterprise_tier` get 30 minutes.

## Important caveats

1. **Requires coordinator restart** — changes to `session-property-manager.json` only take effect when Trino starts up. If you're running on Kubernetes, use `kubectl rollout restart deployment/trino-coordinator -n trino`.

2. **OPA security consideration** — tenants can try to override these limits with `SET SESSION query_max_execution_time = '24h'` before their query. If you use the Trino OPA plugin, add an OPA rule that denies `SetSessionProperty` actions on `query_max_execution_time` for non-admin principals. Otherwise a savvy tenant can bypass the per-tier limit.

3. **For immediate relief during an incident** — while you're deploying the session property manager config, kill the offending query directly:
```sql
CALL system.runtime.kill_query(
  query_id => '20260524_134522_00123_abcde',
  message  => 'Throttling noisy query'
);
```

## How to verify it's working

Once deployed, check that free-tier queries are actually landing in the right resource group:

```sql
SELECT query_id, user, state, resource_group_id, query
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;
```

Look for free-tier queries in `resource_group_id = ARRAY['global', 'free_tier']`.

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`
