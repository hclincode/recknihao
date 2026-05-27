# Answer to Q1: Trino Resource Groups Time Limits — What's Available (Iter 334)

**The short answer: Trino's resource group definition does NOT have a direct per-query execution time limit property.** There is no field like `maxExecutionTime` or `executionTimeLimit` in the resource group JSON that auto-kills a query after a fixed duration.

## What Resource Groups CAN Control

The valid resource group properties include:

- `hardConcurrencyLimit` — max queries running simultaneously (once queued and started, doesn't kill them based on time)
- `softMemoryLimit` — memory cap (what you're already using)
- `maxQueued` — max queries that can wait in the queue
- `hardCpuLimit` / `softCpuLimit` — *aggregate* CPU-time budget per rolling window across all queries in the group (e.g., `"30m"` = 30 CPU-minutes across all queries in the group per rolling hour)

**Important**: CPU limits are aggregate across the group and per rolling window — not a per-query execution time limit. A single slow query could run for hours if it stays within the group's aggregate CPU budget.

## Practical Approach for Your Problem

For free-tier queries holding concurrency slots for hours:

1. **Lower `hardConcurrencyLimit` for free tier** — fewer concurrent slots means fewer long-running queries can occupy them simultaneously. Combined with `maxQueued`, this creates back-pressure that makes the operational problem more visible.

2. **CPU limit as a proxy** — if free-tier queries are CPU-intensive, a tight `softCpuLimit` on the free-tier group will eventually throttle them, though this doesn't kill a single long-running query directly.

3. **Global Trino configuration** — the resources note that some time-based limits exist as global session/config properties separate from the resource group definition. For per-tier execution time limits, you would need to check the Trino documentation for `query.max-run-time` or similar global properties and whether they can be set per resource group.

## What the Resources Don't Cover

The available resources do not document a per-resource-group execution time limit property for Trino 467. Per-query time limits beyond CPU budgets may exist as global coordinator config properties rather than per-group settings. Consult the official Trino resource groups documentation to verify what's available in Trino 467 specifically.

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`
