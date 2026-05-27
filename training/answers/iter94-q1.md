# Iter94 Q1 — Answer

**Question**: We set up resource groups in Trino to isolate our tenants from each other, but now we're trying to figure out what limits to actually set. The docs mention both a cap on how many queries can run at the same time and a cap on how much memory a group can use, and we're not sure which one to reach for first. For example, if one tenant fires off a giant query, should we be protecting other tenants by capping that tenant's concurrency, capping their memory, or both — and does it matter which one hits first? Also, what actually happens to a query that gets blocked by these limits: does it fail immediately or sit in a queue somewhere?

---

## Answer

## The two limits and what they do

Trino resource groups have two independent controls:

- **`hardConcurrencyLimit`** — the maximum number of queries that can run simultaneously in this group. It's a hard ceiling: once that many queries are running, the next query cannot start.
- **`softMemoryLimit`** — the maximum amount of cluster memory this group can use. It's called "soft" because it doesn't kill running queries when crossed; instead, it blocks new queries from starting until memory drops back below the limit.

Both limits protect other tenants. They work in different ways and you should set both.

## What happens when a limit is hit

When a new query arrives at a resource group that has hit either limit, it does **not** fail immediately. It goes into a **queue**. The queue is controlled by a third setting: `maxQueued`.

The flow is:
1. Query arrives → group is at `hardConcurrencyLimit` or over `softMemoryLimit`
2. Query waits in the group's queue
3. When a running query finishes (freeing a concurrency slot or releasing memory), the oldest queued query starts
4. If the queue is already full (`maxQueued` reached), the new query fails immediately with `QUERY_QUEUE_FULL`

So the failure mode you're worried about — one tenant's giant query starving others — is handled by the queue: that query might sit and wait, but it won't consume resources it hasn't been given yet.

## Which limit hits first: does it matter?

Yes, it matters because they protect against different failure modes.

**Concurrency limit** protects against **queue flooding**: a tenant spinning up 50 queries at once, each small, exhausts their slot budget before any run. Other tenants are unaffected.

**Memory limit** protects against **runaway queries**: a tenant runs one query that scans a 500 GB partition and tries to load it all into memory. The concurrency limit won't help here — it's just one query. The `softMemoryLimit` stops new queries from starting in that group until the giant query releases its memory.

A tenant firing a giant query hits the memory limit, not the concurrency limit. You need both:

| Scenario | Which limit triggers |
|---|---|
| Tenant runs 10 small queries at once | `hardConcurrencyLimit` |
| Tenant runs 1 huge scan that blows up memory | `softMemoryLimit` |
| Tenant runs 3 huge scans simultaneously | Both |

## Recommended starting values

For a multi-tenant SaaS setup where you don't yet know your traffic patterns:

```json
{
  "name": "tenant_${USER}",
  "softMemoryLimit": "20%",
  "hardConcurrencyLimit": 5,
  "maxQueued": 50
}
```

- **20% memory per tenant**: on a 10-node cluster with 400 GB worker memory, this is 80 GB — enough for real analytics, not enough to starve all other tenants.
- **5 concurrent queries**: prevents a single tenant from monopolizing all coordinators slots. Adjust up for power-user tenants.
- **50 queued**: gives breathing room for burst traffic without letting queues grow forever. If a tenant has 50 queries backed up, something is wrong — fail fast rather than queue forever.

## Wiring the selector to your tenant identity

The resource group only works if queries are routed to the right group. Your selector matches on the JWT `sub` claim:

```json
{
  "selectors": [
    {
      "group": "tenant_${USER}",
      "user": ".*"
    }
  ]
}
```

`${USER}` is a Trino substitution that expands to the authenticated user. If your JWT `sub` is `acme-corp`, the query goes to `tenant_acme-corp`. Make sure the `user` field in your JWT matches what Trino sees as the principal.

## One operational note

Resource group config changes require a **coordinator restart** to take effect. For immediate relief (e.g., a runaway query right now), use:

```sql
CALL system.runtime.kill_query(query_id => 'q_12345', message => 'exceeded tenant memory budget');
```

This terminates a specific query without a restart.
