# Iter120 Q2 — Answer

**Question**: A few of our enterprise customers run a lot of heavy queries — big cross-tenant reports their ops teams pull weekly. We've noticed those queries are clearly slowing things down for everyone else on the same Trino setup, including customers on our free tier who are just loading basic dashboards. We haven't done anything to separate them. Is there a way to give different customer tiers different amounts of Trino compute so one customer can't hog everything? I don't even know if Trino has a concept for this or if we'd need to run separate Trino clusters per tier.

---

## Resource Isolation for Multi-Tenant Trino: Handling "Noisy Neighbors"

Your situation is a classic **noisy-neighbor problem** — heavy enterprise queries and lightweight free-tier queries sharing the same Trino cluster, competing for the same compute resources. You have two complementary solutions: **separate clusters** (strongest isolation) or **resource groups** (more efficient, sharing one cluster with quotas).

### The short answer

**No, you don't need separate clusters.** Trino has **resource groups** — a built-in quota system that caps memory, concurrency, and CPU per tenant. One cluster, multiple "virtual compute pools" per tier. This is the standard production pattern on your Trino 467 stack.

---

## Option 1: Resource Groups (Recommended)

**What it does:** Configure Trino to accept queries from each customer but enforce per-tenant limits. Enterprise tenants get (say) 20 concurrent queries and 60% of cluster memory; free tiers get 3 concurrent queries and 10%. Heavy queries from Acme still run but never starve free-tier dashboards.

**Why this works:** Trino routes every query to a **resource group** based on the calling principal (your JWT token). Inside each group, memory and query concurrency are capped. Exceed the cap? New queries queue instead of running until a resource becomes available. A 12-month aggregation from enterprise Acme takes 45 minutes and ties up 5 of their 20 concurrent slots — but free-tier customers still have their 3 slots available and their dashboard loads normally.

### Configuration: Two files on the Trino coordinator

**File 1: `etc/resource-groups.properties`** (tells Trino where to find the config)

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**Critical note:** This goes in its **OWN separate file** in the `etc/` directory, NOT in `etc/config.properties`. If you add it to `config.properties`, Trino silently ignores it and applies no resource limits.

**File 2: `etc/resource-groups.json`** (the actual quotas)

```json
{
  "cpuQuotaPeriod": "1h",
  "rootGroups": [
    {
      "name": "global",
      "softMemoryLimit": "80%",
      "hardConcurrencyLimit": 100,
      "maxQueued": 1000,
      "subGroups": [
        {
          "name": "free_tier",
          "softMemoryLimit": "10%",
          "hardConcurrencyLimit": 3,
          "maxQueued": 20
        },
        {
          "name": "professional_tier",
          "softMemoryLimit": "30%",
          "hardConcurrencyLimit": 10,
          "maxQueued": 100
        },
        {
          "name": "enterprise_tier",
          "softMemoryLimit": "40%",
          "hardConcurrencyLimit": 20,
          "maxQueued": 200,
          "softCpuLimit": "4h",
          "hardCpuLimit": "6h"
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": "acme-service-account",
      "group": "global.enterprise_tier"
    },
    {
      "user": "customer-.*",
      "group": "global.professional_tier"
    },
    {
      "user": "free-tier-.*",
      "group": "global.free_tier"
    }
  ]
}
```

**What each field means:**

| Field | Purpose | Example |
|---|---|---|
| `hardConcurrencyLimit` | Maximum queries running **simultaneously** in this group | `3` = free tier can run at most 3 queries at once |
| `softMemoryLimit` | Soft cap on total memory consumption (% of cluster or absolute) | `"10%"` = free tier can use up to 10% of cluster memory |
| `maxQueued` | How many queries can **wait in line** if the concurrency limit is hit | `20` = 21st free-tier query in queue is rejected |
| `hardCpuLimit` / `softCpuLimit` | CPU-time cap per rolling window | `"6h"` = enterprise tenant can consume 6 CPU-hours per rolling window |

**How the routing works:** The `selectors` array matches the JWT principal (the username in your auth token) to a resource group. The `user` field matches against the JWT principal using regex.

### What happens when limits are hit

**Hard concurrency limit hit:** The next query from that tenant **queues**. It waits until a running query finishes and a slot opens up. From the tenant's perspective: "My query is in `QUEUED` state instead of `RUNNING` state." This is your defense against the noisy neighbor — their 12-month export ties up their 20 slots, but your free tier never goes below 3 available slots.

**Hard CPU limit exceeded:** New queries from the group are rejected until the rolling window advances.

### Critical deployment detail: Restart required

**Resource group config changes require a coordinator restart** — they do NOT hot-reload:

```bash
kubectl rollout restart deployment/trino-coordinator -n trino
```

During the restart (30–60 seconds), existing queries may drop. Schedule this during low-traffic windows.

---

## Option 2: Separate Clusters (When Resource Groups Aren't Enough)

If you want **absolute isolation** — enterprise queries cannot even compete with free-tier infrastructure — run two Trino clusters: one for enterprise, one for free/professional customers.

**Tradeoff:** More operational overhead (two coordinators, two worker fleets), but zero cross-contamination. **Most SaaS teams do NOT need this.** Only choose separate clusters if resource group limits are correctly tuned and still insufficient.

---

## How to debug if resource groups aren't working

**Check which resource group a query lands in:**

```sql
SELECT query_id, user, state, resource_group_id
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC
LIMIT 10;
```

The `resource_group_id` column shows the group path (e.g., `global.free_tier`). If you see free-tier queries landing in `global` instead of `global.free_tier`, your selector regex didn't match. Verify:
1. The JWT principal (the `user` column) exactly matches the `"user"` regex in your selector.
2. The field name is **`"user"`** — this matches against the JWT principal, not the Trino role name.

**Common mistake:** Config file in wrong location. Verify both files exist:
```bash
ls etc/resource-groups.properties
ls etc/resource-groups.json
```

If `etc/resource-groups.properties` is missing, the entire resource group system is silently disabled.

---

## Monitoring: Track queue depth

```sql
SELECT
  resource_group_id,
  COUNT(*) FILTER (WHERE state = 'RUNNING') AS running,
  COUNT(*) FILTER (WHERE state = 'QUEUED') AS queued,
  MAX(queued_time_ms) / 1000 AS max_queued_seconds
FROM system.runtime.queries
WHERE created > CURRENT_TIMESTAMP - INTERVAL '1' HOUR
GROUP BY resource_group_id
ORDER BY queued DESC;
```

---

## The cost-benefit summary

| Approach | Isolation | Complexity | Cost |
|---|---|---|---|
| **Resource groups (one cluster)** | Queries queue but share cluster | Medium — two config files, one restart | Lowest — use existing hardware |
| **Separate clusters** | Complete isolation, no queueing | High — dual-stack deployment, monitoring | Higher — duplicate infrastructure |

**Recommendation:** Start with resource groups. Monitor for a month. If free-tier SLAs are consistently met, you're done. Only move to separate clusters if resource group limits are correctly tuned and still insufficient — that's rare.
