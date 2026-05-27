# Iter 177 Q2 — Postgres Connection Pool Sizing and PgBouncer for Trino Federation

## Answer

Your worry is absolutely valid. Let me walk through the actual connection model and the complete set of guardrails you need.

---

### The JDBC Single-Split Model

This is the critical detail: **Trino's PostgreSQL connector uses a JDBC single-split model.**

For a non-partitioned Postgres table (which is most tables), Trino creates **exactly ONE split for the entire table**. One split means:
- One Trino worker task
- One JDBC connection
- One thread reading rows sequentially over the network

So per query, Trino opens **one JDBC connection per worker that touches the Postgres table** — not one per query total, but one per worker-query combination.

Concrete math for your situation (8 workers):

| Scenario | Calculation | Result |
|---|---|---|
| 1 concurrent query, 8 workers | 1 × 8 = 8 connections | 8 connections |
| 10 concurrent queries, 8 workers | 10 × 8 = 80 connections | 80 connections |
| 20 concurrent queries, 8 workers | 20 × 8 = 160 connections | 160 connections (danger zone) |
| 25 concurrent queries, 8 workers | 25 × 8 = 200 connections | **hits your limit** |

With your application using some of those 200 slots, you can exhaust capacity with just 10–15 concurrent federated queries. **The connection pressure is real.**

---

### OSS Trino 467 Has No Native Connection Pool

This is critical: **OSS Trino 467's PostgreSQL connector has NO built-in JDBC connection pooling.**

You may have seen `connection-pool.enabled`, `connection-pool.max-size`, or `connection-pool.max-connection-lifetime` mentioned in docs or blog posts. **Do not use these.** They belong to Starburst Enterprise (the commercial fork), not open-source Trino 467. If you add them to your catalog properties file, Trino silently ignores them and the pool never materializes.

**The fix is a network-side pool: PgBouncer.**

---

### The Complete Solution: Four Layered Guardrails

#### 1. PgBouncer in Transaction-Pooling Mode (The Primary Fix)

Run PgBouncer as a Kubernetes Deployment in your cluster pointing at your Postgres replica:

```ini
# pgbouncer.ini
[databases]
appdb = host=app-postgres-replica.app.svc.cluster.local port=5432 dbname=appdb

[pgbouncer]
listen_port = 6432
listen_addr = 0.0.0.0
pool_mode = transaction
max_client_conn = 1000           # Trino can open up to 1000 connections to PgBouncer
default_pool_size = 50           # PgBouncer holds only 50 real backend connections to Postgres
server_idle_timeout = 600
```

The magic is `default_pool_size = 50`: **no matter how many concurrent connections Trino opens to PgBouncer, PgBouncer multiplexes them onto only 50 real backend connections to Postgres.**

Point your Trino catalog at PgBouncer:

```properties
# etc/catalog/app_pg.properties
connector.name=postgresql
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
```

**Why `prepareThreshold=0` is mandatory with PgBouncer transaction-pooling mode:**

The PostgreSQL JDBC driver caches server-side prepared statements by default (`prepareThreshold=5` — after 5 executions, it issues a `PREPARE` and reuses the plan). In PgBouncer transaction-pooling mode, each new transaction may be routed to a different Postgres backend connection. If the JDBC driver issues `PREPARE` on backend A, then PgBouncer routes the next transaction to backend B, Postgres returns:
```
ERROR: prepared statement "S_1" does not exist
```

**Without `prepareThreshold=0`, your federation will work fine at first, then fail intermittently** after the driver promotes statements to prepared form. `prepareThreshold=0` disables server-side prepared statements entirely, forcing every query to be sent as a simple string — negligible overhead, eliminates the routing error.

#### 2. Postgres Role-Level Connection Cap (Defense in Depth)

Even with PgBouncer, set a hard cap on the Postgres replica:

```sql
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```

This is enforced by Postgres itself. If anything bypasses PgBouncer (misconfiguration, a direct connection from a test), Postgres rejects the 51st connection from `trino_reader`. Your application's own role is unaffected.

Check current usage:
```sql
SELECT count(*) FROM pg_stat_activity WHERE usename = 'trino_reader';
SELECT rolname, rolconnlimit FROM pg_roles WHERE rolname = 'trino_reader';
```

#### 3. Trino Resource Groups (Query Admission Control)

Resource groups cap how many federated queries run concurrently. Fewer concurrent queries = fewer simultaneous Postgres connections.

```json
{
  "rootGroups": [
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
      "user": ".*",
      "queryType": "SELECT",
      "source": ".*federation.*",
      "group": "federation"
    }
  ]
}
```

`hardConcurrencyLimit: 10` means at most 10 federation queries run concurrently — the 11th waits in queue until one finishes.

**Critical setup step:** Clients must set a `source` parameter so the selector matches:
```
# JDBC URL
jdbc:trino://trino-coordinator:8080/iceberg?source=federation-queries

# CLI
trino --server coordinator:8080 --source federation-queries
```

If no client sets the source, the selector doesn't match and queries bypass the `hardConcurrencyLimit` entirely.

#### 4. Statement Timeout on Postgres (Runaway Query Backstop)

```sql
-- Role-scoped (recommended — only affects trino_reader):
ALTER ROLE trino_reader SET statement_timeout = 300000;  -- 5 minutes in milliseconds
SELECT pg_reload_conf();
```

Kills runaway queries that somehow avoid predicate pushdown before they bloat the replica indefinitely.

---

### Sizing Everything Together

Your setup: 8-worker Trino cluster, Postgres replica with `max_connections=200`, application using ~100 of those:

| Layer | Setting | Value | Reasoning |
|---|---|---|---|
| PgBouncer | `default_pool_size` | `50` | Hard ceiling on real Postgres connections |
| Postgres role | `CONNECTION LIMIT` | `50` | Defense in depth; matches PgBouncer ceiling |
| Trino resource group | `hardConcurrencyLimit` | `10` | At most 10 concurrent federated queries |
| Postgres | `statement_timeout` | `5 min` | Kill runaway queries |
| Headroom | `200 - (100 app + 50 PgBouncer)` | `50` | Safe headroom for admin/monitoring |

With this config, when the 11th federation query arrives, it queues behind the first 10 in the resource group. No connection exhaustion, no errors.

---

### Should You Use PgBouncer? Yes.

- **Trino has no pool.** You have to pool somewhere.
- **PgBouncer is lightweight.** A single K8s Deployment (2–3 replicas) handles thousands of connections with negligible overhead.
- **Resource groups alone are not enough.** They limit query concurrency but don't reduce the number of physical Postgres connections — you still spike during bursts.
- **PgBouncer + resource groups is the right combination.** Resource groups prevent admission storms; PgBouncer multiplexes the admitted queries onto a bounded backend pool.

---

### Verification Checklist After Deploying

1. **Test PgBouncer routing:**
   ```bash
   psql -h pgbouncer.app.svc.cluster.local -U trino_reader -d appdb -c "SELECT 1"
   ```

2. **Run a federation query and monitor Postgres connections:**
   ```sql
   -- On Postgres replica:
   SELECT count(*) as trino_conns FROM pg_stat_activity WHERE usename = 'trino_reader';
   ```
   Should see at most 50 connections (your PgBouncer ceiling) even with 20 concurrent federation queries.

3. **Confirm resource group is queuing correctly:**
   ```sql
   SELECT query_id, state, resource_group_id FROM system.runtime.queries
   WHERE query LIKE '%app_pg%'
   ORDER BY created DESC LIMIT 5;
   ```
   Should see queries in `QUEUED` state when you hit the `hardConcurrencyLimit`.
