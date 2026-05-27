# Iter 163 Q2 — Trino PostgreSQL Connection Pool Configuration

## Answer

## Yes, Trino has connection pooling controls for Postgres — it's a server-level catalog setting, not per-query.

Your Postgres team's concern is valid: Trino workers can easily saturate a database's connection slots. The good news is that Trino 467's PostgreSQL connector includes built-in connection pooling that you can configure per catalog.

### Where the settings live

Connection pool configuration goes in the **catalog properties file** — typically `etc/catalog/app_pg.properties` if your Postgres catalog is called `app_pg`. These are **static, cluster-wide settings** mounted via Kubernetes ConfigMap. You cannot adjust them per query.

### The three key properties

```properties
connection-pool.enabled=true
connection-pool.max-size=10
connection-pool.max-connection-lifetime=30m
```

- **`connection-pool.enabled`**: must be `true` to turn pooling on
- **`connection-pool.max-size`**: the maximum number of connections **per Trino worker**. This is important — if you have 20 workers and set `max-size=10`, Trino can open up to 200 simultaneous connections to Postgres (20 workers × 10 per worker)
- **`connection-pool.max-connection-lifetime`**: how long a connection stays in the pool before being recycled (e.g., `30m` means connections are recycled every 30 minutes)

### A practical sizing example

If you have 20 Trino workers and a Postgres replica with `max_connections=300`:

```properties
connection-pool.enabled=true
connection-pool.max-size=10
connection-pool.max-connection-lifetime=30m
```

This tops out at **200 connections from Trino** (20 × 10), leaving 100 for your application and other services.

### Critical gotcha: the property name

A common mistake is writing `postgresql.connection-pool-max-size` with a hyphen instead of a dot. **This is wrong and Trino will silently ignore it.** The correct form uses dots: `connection-pool.max-size`.

### How to size it properly

1. **Find your replica's `max_connections` setting:** `SHOW max_connections;`
2. **Estimate how many connections Trino and other clients need.** Peak query load on a busy Trino cluster can spike to 30-50 connections.
3. **Calculate the per-worker budget:** Divide the remaining capacity by your number of workers. For the example above: (300 - 50 reserved for app - 20 safety margin) ÷ 20 workers = 6 per worker, so set `max-size=6` or `max-size=10` with growth headroom.
4. **Verify under peak load:** After deployment, check with `SELECT count(*) FROM pg_stat_activity WHERE usename = 'trino_reader';` on the Postgres side.

### Why always use a read replica

Pointing Trino at your OLTP primary is asking for an outage. A federation query can tie up connection slots your application needs, trigger long-running transactions that block VACUUM, and saturate primary I/O. Always dedicate a **read replica** to Trino traffic, and set an aggressive `statement_timeout` on that replica (e.g., `5min`) so runaway queries don't run forever.

### Rolling out your changes

1. Update the ConfigMap mounted to Trino pods with the new pool settings
2. Roll the coordinator and worker pods
3. Verify the catalog loads: `SHOW CATALOGS;`
4. Run a test query and monitor connections on the Postgres replica with `pg_stat_activity`

This is a static configuration — you cannot tune it per query or per user. If you find yourself constantly needing different pool sizes for different workloads, that's a signal that you may be doing too much analytical work against Postgres and should consider ingesting those tables into Iceberg instead.
