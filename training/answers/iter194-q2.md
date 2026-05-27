# Iter 194 Q2 — Trino Query Timeouts and Resource Management for Federation

## Answer

You're asking the right questions. Your concern about Postgres taking 10 minutes under load, and whether a bad query can starve other users, maps directly to **two different problems with two different solutions** in your Trino 467 setup.

The good news: yes, there are ways to set bounds on both. The bad news: one of the bounds is on **Postgres, not Trino** — and that's actually the most important one for your read replica. Let me break this down in layers.

### Part 1: Protecting your Postgres replica from runaway queries

When Trino issues a query to Postgres via the JDBC connector, there is **no native timeout inside the Trino PostgreSQL connector itself** (OSS Trino 467). The connector opens a connection, sends SQL, and waits for rows. If Postgres is stuck, Trino waits.

Your two defenses here are:

**1. `statement_timeout` on the Postgres replica (most important)**

Set this in your replica's `postgresql.conf`:

```
statement_timeout = '5min'
```

This kills any single Postgres query that runs longer than 5 minutes, regardless of whether Trino is waiting or not. If someone writes a query that full-table-scans your 200M row table without proper filters, Postgres cancels it server-side after 5 minutes. Trino sees the error and the client knows the query failed.

This is **critical** because even if Trino has timeouts configured, you don't want Postgres holding resources (locking, CPU, I/O, replication lag) while waiting for a Trino decision to kill the query. Cancel at the source.

**2. JDBC `socketTimeout` in the Trino catalog properties**

When Postgres is stuck or the network is flaky, you don't want your Trino workers blocked forever on a socket read. Add this to your `etc/catalog/app_pg.properties`:

```properties
connection-url=jdbc:postgresql://pgbouncer-or-postgres-host:5432/database?socketTimeout=60
```

This makes the JDBC driver give up after 60 seconds if no data arrives from Postgres. Combined with `statement_timeout`, it's a belt-and-suspenders approach: Postgres cancels at 5 minutes, but the JDBC client aborts at 60 seconds if the network goes silent.

### Part 2: Preventing one bad federated query from starving other users

**The core issue:** Trino uses a **resource group** system to control how many queries run concurrently. One query in your `federation` resource group does occupy one concurrency slot, but it does not directly block other resource groups or other slots in different groups. However, if you've configured your resource group with a low `hardConcurrencyLimit` (which you should), a single heavy query can cause subsequent federation queries to queue up.

The lever is **Trino resource groups** — specifically the `hardConcurrencyLimit` setting.

Here's a minimal example. Create (or update) `etc/resource-groups.json` on your Trino coordinator:

```json
{
  "groups": [
    {
      "name": "federation",
      "softMemoryLimit": "30%",
      "hardConcurrencyLimit": 10,
      "maxQueued": 100,
      "schedulingPolicy": "fair"
    }
  ],
  "selectors": [
    {
      "source": ".*federation.*",
      "group": "federation"
    },
    {
      "user": ".*",
      "group": "default"
    }
  ]
}
```

What this does:
- **`hardConcurrencyLimit: 10`** — at most 10 federated queries run at the same time. The 11th one queues.
- **`maxQueued: 100`** — up to 100 can wait in queue. The 101st is rejected immediately.
- **`source: ".*federation.*"`** — queries that set their client source to something matching `federation` land in this group. Queries from other sources go to the `default` group instead and are not throttled.

This means **one heavy federation query can only block other federation queries, not your BI dashboard queries or dbt jobs** — each workload class is isolated.

**Critical wiring detail:** This config goes in a **separate file**, `etc/resource-groups.properties`:

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

In Kubernetes, mount both `config.properties` and `resource-groups.json` as separate ConfigMap keys, then restart the coordinator. A **common mistake** is putting the resource group config into `config.properties` — it will silently have no effect.

### Part 3: Trino-side query timeouts — the full picture

If you want Trino itself to kill queries that exceed your SLA, there are **two distinct timeout settings**, and they bound different things:

```properties
# In etc/config.properties on the coordinator:
query.max-execution-time=30m    # active compute time only (does NOT include queue wait)
query.max-run-time=1h           # wall-clock time from submission to completion
```

- **`query.max-execution-time`** — counts only the time the query is actively running on workers. Does NOT count time waiting in a resource-group queue.
- **`query.max-run-time`** — counts from submission through completion: queue wait + analysis + planning + execution. This is what you want for "the user complained the query hung."

For a federated query hitting a slow Postgres, **`query.max-run-time` is more relevant** because it captures the full user experience.

You can also set these per-session:

```sql
SET SESSION query_max_run_time = '15m';
```

### Bringing it together — a defensive configuration

For your setup, layer these (from innermost/fastest-to-react outward):

| Layer | Setting | Value | Why |
|---|---|---|---|
| **Postgres replica** | `statement_timeout` | `5min` | Cancels runaway Postgres queries first |
| **JDBC driver** | `socketTimeout` in connection-url | `60` | Fails fast if network stalls |
| **Trino resource group** | `hardConcurrencyLimit` | `10` (example) | Queues excess federation queries, prevents connection storm |
| **Trino cluster** | `query.max-run-time` | `1h` | Kills queries that exceed total time, even if queued |

**Operational example — what happens when someone writes a bad query:**

1. Query hits Trino, gets queued in the `federation` resource group.
2. After 90 seconds, a slot opens. Query starts.
3. Query sends SQL to Postgres without proper filters — Postgres begins scanning 200M rows.
4. At 5 minutes of scanning, Postgres hits `statement_timeout` and cancels.
5. JDBC driver gets the cancellation message and fails the connection.
6. Trino fails the query. The 11 queries waiting in the queue are unaffected.
7. Other workloads (non-federation queries) continue running in their own resource groups, unstarved.

### One more detail: the connection pooling layer

Confirm you're **not connecting Trino directly to Postgres**. OSS Trino 467 has no native connection pool for the PostgreSQL connector. The standard pattern is **PgBouncer in transaction-pooling mode between Trino and Postgres**:

```
Trino → PgBouncer (pool_mode=transaction, default_pool_size=50) → Postgres replica
```

This caps the actual Postgres connections Trino can open at 50, no matter how many concurrent Trino queries exist. Combined with your resource group `hardConcurrencyLimit=10`, you have layered isolation.
