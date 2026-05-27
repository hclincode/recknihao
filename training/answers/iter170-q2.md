# Iter 170 Q2 — Resource Groups to Isolate Federation from Iceberg Queries

## Answer

Yes — **Trino resource groups** are exactly the right tool for this. They let you create separate queues with their own concurrency limits, preventing federation queries from crowding out your internal Iceberg work.

## The configuration

You need two files on your Trino coordinator:

**`etc/resource-groups.properties`** (registers the JSON config):
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

**`etc/resource-groups.json`** (the actual limits):
```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "subGroups": [
      {
        "name": "postgres_federation",
        "softMemoryLimit": "25%",
        "hardConcurrencyLimit": 8,
        "maxQueued": 50
      },
      {
        "name": "internal_iceberg",
        "softMemoryLimit": "50%",
        "hardConcurrencyLimit": 20,
        "maxQueued": 100
      }
    ]
  }],
  "selectors": [
    { "user": "customer-service-.*", "group": "global.postgres_federation" },
    { "user": "data-team", "group": "global.internal_iceberg" },
    { "user": ".*", "group": "global.postgres_federation" }
  ]
}
```

At most 8 federation queries run concurrently; your internal Iceberg queries get up to 20 concurrent slots. When Postgres queries exceed 8, new ones queue instead of evicting Iceberg work.

## Deployment

After creating both files, restart the coordinator:
```bash
kubectl rollout restart deployment/trino-coordinator -n trino
```

## How selectors work

Selectors match the **JWT principal** (the `sub` claim from your JWT tokens). Selector evaluation is **top-down; first match wins** — put specific matches before catch-all regex patterns.

## Connection between resource groups and Postgres connection pressure

Since OSS Trino 467 has no native PostgreSQL connection pooling, resource groups are the standard way to cap concurrent JDBC connections. At `hardConcurrencyLimit: 8`, at most 8 customer federation queries can open Postgres connections simultaneously, even with 20 workers. This directly reduces connection saturation on the Postgres replicas.

## What NOT to do

- **Don't use property names like `maxRunning` or `queues`** — these are silently ignored. Use only `hardConcurrencyLimit`, `softMemoryLimit`, `hardCpuLimit`, `maxQueued`.
- **Don't merge the resource-groups config into `etc/config.properties`** — Trino silently ignores resource group settings there.
- **File-based config requires a coordinator restart for changes.** If you need live tuning without restarts, switch to `resource-groups.configuration-manager=db` (database-backed, reloads every 1 second).

## For per-customer isolation (beyond the 15-catalog case)

If you need "customer A's queries never slow down customer B's," add per-customer sub-groups or selectors matching the specific catalog or JWT principal for each enterprise customer.
