# Iter274 Q2 — Trino JDBC Connection Pooling to PostgreSQL: What Happens Under Load

## Answer

The short answer: **OSS Trino 467 has no native JDBC connection pool for PostgreSQL.** There is no single knob in Trino to turn. Instead, you control connection pressure using four layered mechanisms outside Trino: PgBouncer, a Postgres role connection cap, Trino resource groups, and a statement timeout.

When load spikes and queries back up, they queue inside Trino — they do not fail immediately unless the queue itself is full.

### How Many JDBC Connections Does One Query Open?

**A single Trino query scanning one Postgres table opens exactly 1 JDBC connection — one split, one worker task, one connection.** Trino does not open one connection per worker.

With 15-20 customers loading dashboards at once, you're opening roughly 15-20 concurrent Postgres connections (more if individual dashboards join multiple Postgres tables). At this scale you shouldn't be hitting connection exhaustion on a well-configured replica — but under-configured resource groups or a missing PgBouncer can amplify the problem.

### OSS Trino 467 Has No Native Connection Pool

`connection-pool.enabled`, `connection-pool.max-size`, and similar properties you might find in blog posts or Starburst documentation **do not exist in OSS Trino 467**. If you add them to `etc/catalog/app_pg.properties`, Trino silently ignores them.

Do not add these — they have no effect and give false confidence that you've set a limit.

### The Four-Layer Defense: What Actually Works

#### Layer 1: PgBouncer (network-level multiplexer)

Run PgBouncer between Trino workers and the Postgres replica. It multiplexes many client connections onto a small pool of real Postgres backend connections.

`pgbouncer.ini`:
```ini
[databases]
appdb = host=postgres-replica.svc.cluster.local port=5432 dbname=appdb

[pgbouncer]
listen_port = 6432
listen_addr = 0.0.0.0
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000          # how many client connections PgBouncer accepts
default_pool_size = 50          # how many REAL Postgres backend connections to hold
reserve_pool_size = 10
server_idle_timeout = 600
```

With `default_pool_size=50`, Postgres sees at most 50 connections from PgBouncer, regardless of how many Trino queries run.

**Critical — append `prepareThreshold=0` to your JDBC URL when using PgBouncer in transaction mode:**

```properties
# etc/catalog/app_pg.properties
connection-url=jdbc:postgresql://pgbouncer.svc.cluster.local:6432/appdb?prepareThreshold=0
```

**Why**: PgBouncer in transaction mode routes successive transactions from the same client to potentially different Postgres backends. If Trino's JDBC driver prepares a statement on backend A and the next query routes to backend B, Postgres returns `ERROR: prepared statement does not exist`. The driver creates server-side prepared statements after the 5th execution of the same SQL by default, so failures appear intermittently after queries seem to work.

Setting `prepareThreshold=0` disables server-side prepared statements — every query is sent as a plain string. Small per-query parsing overhead on Postgres, but eliminates the routing failure entirely.

#### Layer 2: Postgres role connection cap (defense in depth)

Set a hard cap on the Postgres role:

```sql
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```

This is enforced by Postgres itself. If anything bypasses PgBouncer and opens the 51st connection as `trino_reader`, Postgres rejects it. It's a tripwire, not the primary control.

Monitor:
```sql
SELECT count(*) FROM pg_stat_activity WHERE usename = 'trino_reader';
```

#### Layer 3: Trino resource groups (Trino-level concurrency cap)

Resource groups limit how many queries run concurrently. Fewer concurrent queries = fewer simultaneous Postgres connections.

`etc/resource-groups.json`:
```json
{
  "rootGroups": [
    {
      "name": "federation",
      "softMemoryLimit": "60%",
      "hardConcurrencyLimit": 15,
      "maxQueued": 200,
      "schedulingPolicy": "fair",
      "selectors": [
        {
          "source": ".*dashboard.*",
          "group": "federation"
        }
      ]
    }
  ]
}
```

`etc/resource-groups.properties` (separate file from `config.properties`):
```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

Key properties:
- **`hardConcurrencyLimit: 15`** — at most 15 federation queries run at once. Query 16 waits in queue.
- **`maxQueued: 200`** — up to 200 queries can queue. When both slots and queue are full, new queries are rejected with `Too many queued queries for group`.

**Important**: The `source` selector matches the client-supplied source string. Set it in your BI tool or dashboard code via `?source=dashboard-queries` in the JDBC URL, or `X-Trino-Source: dashboard-queries` HTTP header. If clients don't set the source, the selector won't match and queries bypass the concurrency limit entirely.

Restart the coordinator after creating both files.

#### Layer 4: Statement timeout on Postgres (backstop)

```sql
ALTER ROLE trino_reader SET statement_timeout = '300000';  -- 5 minutes in milliseconds
SELECT pg_reload_conf();
```

This kills any Postgres statement from Trino that runs longer than 5 minutes, freeing the connection for queued queries.

### What Happens When Load Spikes

With the above in place, here's the flow when 20 dashboards load simultaneously:

1. **Queries 1–15** execute immediately (within `hardConcurrencyLimit: 15`)
2. **Queries 16–200** queue inside Trino — they do not hit Postgres yet. From users' perspective, the dashboard is slow but loads eventually.
3. **Query 201+** is rejected: `Too many queued queries for group 'federation'`. User sees an error.

Postgres only ever sees the ≤15 actively executing queries. The queued queries don't consume Postgres connections.

### Practical Sizing for Your Setup

| Layer | Setting | Value | Reasoning |
|---|---|---|---|
| PgBouncer | `default_pool_size` | 50 | 50 real Postgres connections max |
| Postgres role | `CONNECTION LIMIT` | 50 | Matches PgBouncer ceiling |
| Trino resource group | `hardConcurrencyLimit` | 15 | 15 concurrent queries; 20 users will see slight queuing |
| Trino resource group | `maxQueued` | 200 | Generous queue before rejecting |
| Postgres | `statement_timeout` | 5 min | Kill runaway scans |

15 concurrent queries × 1–3 Postgres tables per dashboard = 15–45 Postgres connections at peak, well within the 50-connection ceiling.

### What to Monitor

**On Postgres:**
```sql
-- Real-time connection count from Trino:
SELECT count(*) FROM pg_stat_activity WHERE usename = 'trino_reader';

-- Active queries (what Postgres is actually running):
SELECT pid, query, state, state_change
FROM pg_stat_activity
WHERE usename = 'trino_reader' AND state = 'active';
```

**On PgBouncer** (from inside the PgBouncer pod):
```bash
psql -p 6432 pgbouncer
SHOW POOLS;    -- pool utilization (cl_active, sv_active, sv_idle)
SHOW CLIENTS;  -- all client connections to PgBouncer
SHOW SERVERS;  -- all backend connections to Postgres
```

**In Trino UI** (`http://coordinator:8080/ui/`): Check "Queued time" on query details — large values mean `hardConcurrencyLimit` is too low or queries are too slow.

### The Longer-Term Fix: Remove Postgres from the Hot Path

If dashboards still back up after sizing these four layers, the underlying problem is that your queries are too large for federation. Federation is designed for analytical joins against small operational tables, not for scanning millions of rows on every dashboard load.

The production fix is to **ingest the Postgres account data into Iceberg** on a schedule matching your SLA (e.g., nightly MERGE INTO, or hourly if freshness matters), then have dashboards query Iceberg instead. This removes Postgres from the hot path entirely.

### Key Reminders

1. **OSS Trino 467 has no native PostgreSQL connection pool** — ignore any `connection-pool.*` properties
2. **PgBouncer + `prepareThreshold=0` in the JDBC URL** is the standard fix for connection pressure
3. **Queries queue at Trino, not Postgres** — they don't fail immediately unless `maxQueued` is exceeded
4. **Set `source=` in client connections** for resource group selectors to work
5. **Monitor `pg_stat_activity` and PgBouncer `SHOW POOLS;`** to see saturation in real time
