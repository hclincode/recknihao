# Answer to Q1: softMemoryLimit Won't Kill a Running Query — Use kill_query (Iter 342)

**No.** Lowering `softMemoryLimit` will not kill the query that's currently running. It only affects new queries trying to start. To kill the runaway query right now, use `CALL system.runtime.kill_query(...)` from an admin session.

## Why softMemoryLimit doesn't stop running queries

Think of `softMemoryLimit` as a **bouncer at the door, not a power cord**:

- `softMemoryLimit` is evaluated by Trino's coordinator **before** a query is allowed to start. It's admission control — a gatekeeper that decides whether new queries are allowed in.
- Once a query is already admitted and running, `softMemoryLimit` does nothing to it. The coordinator only uses it to prevent **new** queries from the same customer from starting.

In your scenario: the 20-minute query was admitted before `softMemoryLimit` was exceeded. Lowering `softMemoryLimit` now will prevent the customer's next query from starting (it will queue or reject it), but the runaway query keeps running with its full memory consumption intact.

## The right tool for right now: kill_query

Use `system.runtime.kill_query` to terminate a running query immediately:

```sql
CALL system.runtime.kill_query(query_id => '20260527_120530_00042_abcde');
```

Find the query ID in the Trino UI, call this from an admin session, and the query terminates immediately and releases its memory. This is the live-incident tool.

## The two-layer defense for next time

To prevent this from happening again, you need **two knobs working together**:

| Knob | Where it lives | What it does | Kills in-flight query? |
|---|---|---|---|
| `softMemoryLimit` | resource groups config | Queues/rejects NEW queries when group is over budget | **NO** — only admission control |
| `query.max-memory` | `etc/config.properties` | Per-query ceiling; automatically kills ANY query that exceeds the limit mid-flight | **YES** — terminates running queries |

**`softMemoryLimit` alone is insufficient.** A single runaway query can be admitted when the group is under budget, then balloon during execution. `softMemoryLimit` blocks the *next* query from that customer, but does nothing to the runaway. `query.max-memory` is the circuit breaker that terminates a query mid-flight if it exceeds the per-query hard limit.

**Three-layer deployment recommendation**:
1. `softMemoryLimit` on the free-tier resource group — group-level throttle
2. `query.max-memory` in config.properties — per-query circuit breaker (kills runaway mid-flight)
3. `query.max-memory-per-node` in config.properties — per-worker safety net

## Your immediate next steps

1. **Right now**: `CALL system.runtime.kill_query(query_id => '<id from Trino UI>')` to stop the current runaway.
2. **After the incident**: Add `query.max-memory=<limit>GB` to `etc/config.properties` so the next runaway gets killed automatically before it gets this far. Pair it with `softMemoryLimit` on the resource group so future queries queue rather than pile on.

**Resources cited:** `/Users/hclin/github/recknihao/resources/05-multi-tenant-analytics.md`
