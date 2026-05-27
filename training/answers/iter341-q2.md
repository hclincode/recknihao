# Answer to Q2: query_max_memory Didn't Cap Memory — Why? (Iter 341)

The core problem: **`query_max_memory` is a default, not an enforced ceiling.** Setting it via the session property manager tells Trino what memory limit to use if the customer doesn't override it — but any customer who knows the property name can run `SET SESSION query_max_memory = '<larger_value>'` and bypass your limit entirely.

## The three memory knobs in Trino

| Knob | What it is | Can SET SESSION bypass it? | When to use it |
|---|---|---|---|
| **`query_max_memory`** | Session property — a suggested default | **YES** — customers can override upward (up to the cluster ceiling) | Only as a starting default; needs OPA to enforce |
| **`softMemoryLimit`** (resource group) | Aggregate memory cap across all queries in the group | **NO** — engine-enforced ceiling, not a session property | Primary lever for per-tier memory limits |
| **`query.max-memory`** | Cluster-wide hard ceiling in `config.properties` | **NO** — absolute backstop for any single query | Defense-in-depth; protects the whole cluster |

## Why your customer's query wasn't killed

Most likely, the customer ran `SET SESSION query_max_memory = '20GB'` (or similar) before their large query, overriding your default. Trino saw that the session value was now higher, and as long as the query stayed under the cluster-wide `query.max-memory`, it ran without being killed.

Even if the customer didn't manually override it, `query_max_memory` set via the session property manager is still just a default — it doesn't prevent a smart client from changing it.

## What to do instead

**Use resource groups for real memory enforcement.** In `etc/resource-groups.json`, set the free-tier group's `softMemoryLimit` to the aggregate memory budget for that tier:

```json
{
  "name": "free_tier",
  "softMemoryLimit": "2GB",
  "hardConcurrencyLimit": 5,
  "maxQueued": 10
}
```

`softMemoryLimit` is enforced by Trino's admission controller — no customer can `SET SESSION` their way around it. If the free-tier group's total memory usage hits `2GB`, Trino starts queuing or rejecting new queries from that group.

For additional per-query defense-in-depth, set `query.max-memory-per-node` in `etc/config.properties` to cap memory per worker node cluster-wide.

## If you need query_max_memory to act as a real ceiling

You'd need to pair the session property manager default with an **OPA deny rule for `SetSystemSessionProperty`** targeting `query_max_memory` for non-admin principals. This blocks the customer from running `SET SESSION query_max_memory = '<larger_value>'` at all. But this is extra complexity — resource groups give you the same protection more simply, and they also control concurrency.

## Key takeaway

`query_max_memory` is a default that customers can override with `SET SESSION`. For a real ceiling on free-tier memory, use `softMemoryLimit` in your resource group config — that is engine-enforced and cannot be bypassed through any session property mechanism.

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`
