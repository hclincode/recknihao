# Iter239 Q1 — PostgreSQL Connection Pooling

**Short answer: No, OSS Trino 467 does NOT have built-in connection pooling for PostgreSQL.** You need PgBouncer or another proxy in front of Postgres. But first, let me explain why you're seeing 40–50 connections and why it matters.

### Why Trino opens many connections

Every time Trino executes a federated query against your PostgreSQL catalog, it opens **one JDBC connection per PostgreSQL table being scanned in that query**. This is NOT one connection per Trino worker — it's one connection per table in the query plan.

Here's the architecture reason: Trino's PostgreSQL connector uses a **per-split model**. For a non-partitioned PostgreSQL table, the entire table is **one split**, which means one JDBC connection, one worker task, and one thread reading rows. So if your query scans the `billing_events` table, that's one connection. If the same query also scans a `customers` table in Postgres, that's two connections.

When you see 40–50 connections, the most common cause is **concurrent queries stacking up** — not a single query splitting into parallel reads. With 10 concurrent federated queries each scanning 4 Postgres tables, you get 40 connections. Add a second wave of 10 queries and you hit 50 and your `max_connections` limit starts to hurt.

### Does OSS Trino have a native pool?

**No.** The properties like `connection-pool.enabled` and `connection-pool.max-size` that you might find in documentation or blog posts belong to **Starburst Enterprise** (the commercial fork), not open-source Trino 467. OSS Trino's PostgreSQL connector has no native JDBC connection pooling. This is a known limitation tracked as [trinodb/trino#15888](https://github.com/trinodb/trino/issues/15888) since January 2023.

**Do NOT add `connection-pool.*` properties to your catalog file** — Trino will silently ignore them and your problem will persist.

### Mitigation: PgBouncer (the standard solution)

The correct OSS Trino approach is to **put PgBouncer between Trino and PostgreSQL**. PgBouncer is a lightweight connection pooler that multiplexes many short-lived Trino connections onto a small, bounded set of real Postgres backend connections.

**Deployment**: Run PgBouncer as a Kubernetes Deployment with a Service in front of it (in the same cluster as your Postgres replica, or as a sidecar). Point Trino's `connection-url` at PgBouncer's service address instead of Postgres directly.

**Configuration** (in `etc/catalog/app_pg.properties`):
```
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
```

**Critical detail — `prepareThreshold=0` is mandatory when using PgBouncer in transaction-pooling mode.** PgBouncer's transaction pooling reuses backends across client connections, which breaks the PostgreSQL JDBC driver's server-side prepared statements. Setting `prepareThreshold=0` disables prepared statements in the client (every query is sent as a simple query string), eliminating the "prepared statement does not exist" failures you'd otherwise get a few days into production.

**PgBouncer config** (`pgbouncer.ini` — minimal example):
```
pool_mode = transaction           # transaction pooling, not session
max_client_conn = 1000            # how many Trino connections PgBouncer accepts
default_pool_size = 50            # actual Postgres backend connections PgBouncer holds open
```

This configuration allows Trino to open up to 1000 short-lived connections to PgBouncer without Postgres seeing them. PgBouncer multiplexes them onto just 50 real backend connections to Postgres.

### Three-layer defense in depth

Even with PgBouncer, you should add two more layers:

**1. PostgreSQL role-level connection limit**
```sql
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```

This ensures that even if PgBouncer is misconfigured or a rogue connection bypasses it, Postgres enforces a hard cap. Applications and other users (with different roles) are unaffected.

**2. Trino resource groups — cap concurrent federation queries**

Add a resource group to `etc/resource-groups.json`:
```json
{
  "name": "federation",
  "hardConcurrencyLimit": 10,
  "selector": {
    "user": [".*"],
    "source": ["trino-cli|dashboards"],
    "queryType": ["SELECT"]
  }
}
```

This limits the `federation` resource group to 10 concurrent queries. With 10 concurrent queries and 4 Postgres tables per query, you get ~40 connections — well within your PgBouncer pool size. Any queries beyond the 10 concurrent limit wait in queue.

**Formula for peak connections:**
```
Peak connections = concurrent_queries × tables_per_query × 1
```
The **×1** is because each non-partitioned Postgres table is one split = one connection (not one per worker).

### What you should do right now

1. **Set up PgBouncer** in front of your Postgres replica with `pool_mode=transaction`, `default_pool_size=50` (or tune based on your expected concurrent queries).
2. **Update Trino's catalog** to point at PgBouncer instead of Postgres directly, and add `prepareThreshold=0` to the JDBC URL.
3. **Set `ALTER ROLE trino_reader CONNECTION LIMIT 50`** on your Postgres replica.
4. **Configure Trino resource groups** with `hardConcurrencyLimit` tuned to your workload — a good starting point is 10–20 concurrent federation queries.
5. **Also set `statement_timeout` on the replica** (e.g., `ALTER ROLE trino_reader SET statement_timeout='5m'`) as a safety valve — prevents long-running queries from hogging connections indefinitely.

This three-layer setup (PgBouncer pool + role-level connection limit + Trino resource groups) is the production-standard defense against exhausting Postgres connection slots due to Trino federation.
