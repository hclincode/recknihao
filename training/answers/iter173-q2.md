# Iter 173 Q2 — Federation Timeouts and Cluster Isolation When Postgres Is Slow

## Answer

Your problem has four layers to fix, and the solution involves configuring them all together. Here's the complete picture.

### (1) JDBC URL Timeout Parameters: `socketTimeout` and `connectTimeout`

These are the innermost timeout layer — they protect individual JDBC reads from hanging forever.

In your PostgreSQL catalog file (`etc/catalog/app_pg.properties`), add these to the JDBC URL:

```properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?\
ssl=true&sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt&\
defaultRowFetchSize=1000&\
socketTimeout=60&\
connectTimeout=10&\
prepareThreshold=0
```

- **`socketTimeout=60`** — per-socket-read timeout in seconds. If Postgres goes silent for more than 60 seconds during a JDBC read (network blip, replica under load), the JDBC driver closes the socket and the Trino worker fails the query rather than hanging forever. This is the most important one.
- **`connectTimeout=10`** — initial TCP connection timeout. If PgBouncer or Postgres is down, Trino workers fail fast (10s) instead of accumulating blocked connection attempts.

**Critical caveat**: `socketTimeout` is per-read, not per-query. If Postgres is slow but responds within 60 seconds per read, the query can still take many minutes total. The query-wide timeout is layer (2).

### (2) `query.max-execution-time` — The Query-Wide Timeout

Set a cluster-wide limit in the coordinator's `etc/config.properties`:

```properties
query.max-execution-time=10m
```

Or per-session:
```sql
SET SESSION query_max_execution_time = '10m';
```

When this fires, you get: `Query exceeded maximum time limit of 10.00m`. Trino kills the query cluster-wide immediately, releasing all its resource slots. This is the backstop for queries that are slow but not completely hung.

### (3) Resource Groups: `hardConcurrencyLimit` — Protecting Other Queries

This is the key isolation mechanism. Resource groups cap the number of concurrent queries against a workload, which bounds how many Postgres connections get opened simultaneously.

```json
{
  "rootGroups": [
    {
      "name": "federation",
      "softMemoryLimit": "30%",
      "hardConcurrencyLimit": 10,
      "maxQueued": 100,
      "schedulingPolicy": "fair"
    },
    {
      "name": "analytics",
      "softMemoryLimit": "70%",
      "hardConcurrencyLimit": 50,
      "maxQueued": 200,
      "schedulingPolicy": "fair"
    }
  ],
  "selectors": [
    { "source": ".*federation.*", "group": "federation" },
    { "user": ".*", "group": "analytics" }
  ]
}
```

At most 10 federation queries run concurrently. The 11th waits in queue. This means at most ~10 Postgres connections are open at any time per federation slot.

**Important**: `hardConcurrencyLimit` caps concurrent **Trino queries**, not JDBC connections directly. With multiple Trino workers, a single query may open multiple JDBC connections (one per worker touching the Postgres connector). The actual connection count depends on worker parallelism. PgBouncer (layer below) handles the actual connection cap.

### (4) What Happens to Other Trino Queries While One Federation Query Hangs

Trino uses a **query slot model**, not a thread-pool model:

- Each Trino query acquires a slot in its resource group for its duration.
- **Non-federation queries live in a different resource group** (`analytics`) with their own `hardConcurrencyLimit` — completely separate slot pool.
- **Within the federation group**: if one query hangs waiting on Postgres, it holds one of the 10 slots. The other 9 slots are unaffected and continue running. Query 11+ waits in the federation queue.
- **Other resource groups are completely unaffected** — a hung federation query doesn't starve your general analytics queries.

In short: **Trino isolates hung federation queries to their own resource group, so the rest of the cluster is protected** — provided you configure resource groups to separate federation from general-purpose queries.

### (5) Concrete Configuration for k8s + Trino 467

**The four-layer defense stack working together:**

1. **`socketTimeout=60`** in JDBC URL → fails fast when Postgres is completely unresponsive
2. **`query.max-execution-time=10m`** in coordinator config → kills queries that are slow but not hung
3. **Resource group `hardConcurrencyLimit: 10`** → caps concurrent Postgres connections, protects other queries
4. **PgBouncer between Trino and Postgres** → multiplexes Trino's many per-worker connections onto a bounded connection pool (OSS Trino 467 has no native JDBC connection pooling)

**PgBouncer config** (`transaction` pooling mode is required; `prepareThreshold=0` in JDBC URL matches this):
```ini
[pgbouncer]
pool_mode = transaction
default_pool_size = 50
max_client_conn = 1000
server_idle_timeout = 600
```

**How the failure mode works when Postgres gets bogged down:**

1. Postgres replica CPU goes to 100% from OLTP reports.
2. A federation query reads rows but Postgres responds slowly.
3. After 60 seconds of silence, `socketTimeout` fires — JDBC aborts the socket.
4. **Trino fails the query with a clear error** (`SocketTimeoutException: Read timed out`), not a hang.
5. **That query releases its resource-group slot** — the next waiting federation query can proceed.
6. **The `analytics` resource group continues completely undisturbed.**

**Three most common failures** in practice:
1. Forgetting `socketTimeout` → queries hang 30+ minutes waiting on a slow replica.
2. Not putting PgBouncer between Trino and Postgres → OSS Trino 467 has no native connection pool, so Postgres connection count explodes.
3. Not separating resource groups → a hung federation query starves analytics queries.

Set all three correctly and your federation setup handles a slow Postgres replica without cascading to the rest of the cluster.
