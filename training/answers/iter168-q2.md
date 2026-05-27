# Iter 168 Q2 — What Happens When Postgres Times Out in a Federated Query

## Answer

Trino does **not sit there waiting forever**. Here's exactly what happens in your stack with Trino 467, and what you can do about it.

## The timeout mechanisms (layered defense)

You have multiple timeout controls working together:

**1. Postgres `statement_timeout`** — set on the replica's `postgresql.conf` or at the role level. When you set `statement_timeout = '5min'`, any query Trino sends to Postgres that runs longer than 5 minutes gets killed by Postgres itself. Postgres sends an error back to Trino, and the Trino query fails.

**2. JDBC socket timeout** — controlled by `socketTimeout` in the catalog's JDBC URL:
```properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10&prepareThreshold=0
```
With `socketTimeout=60`, after 60 seconds of no data from Postgres (network-level hang, not just slowness), the JDBC driver fails the connection and Trino gets an error.

**3. Trino's own query timeout** — `query.max-execution-time` cluster-wide or per-session. This is a backstop if Postgres is stuck but the socket isn't actually broken.

## What happens to the query when it errors

**The entire query fails.** Trino cannot partially succeed. If Postgres times out mid-query, you don't get partial results from the Iceberg side plus nothing from Postgres — the whole query errors out. Here's why:

In your setup, the join between Iceberg events and Postgres accounts runs **on Trino workers**, not inside either database. The execution is:
1. Scan Postgres for accounts (predicates pushed down where possible).
2. Scan Iceberg for events.
3. Hash-join on Trino workers.

If Postgres hangs during step 1 and hits the timeout, the join never gets built, and your users see an error — not a partial result.

## What your users actually experience

- **During Postgres overload but before timeout**: The query hangs. Users see it running but getting no response.
- **After timeout**: The Trino query returns an error like:
  ```
  Query failed: java.io.IOException: Query aborted
  ```
  or
  ```
  PostgreSQL error: statement timeout
  ```
  depending on whether Postgres or the JDBC layer timed out first.
- **No retry, no partial data** — Trino fails the full query and users must retry manually.

## How to protect your users from this

1. **Set `statement_timeout` on the Postgres replica** (e.g., 5 minutes). This prevents runaway queries from hogging the replica indefinitely. Set it longer than your normal query SLO but short enough to fail before users give up and hammer the retry button.

2. **Set `socketTimeout` in the JDBC URL** (60 seconds is a good default) — catches network-level hangs, not just Postgres slowness.

3. **Put PgBouncer between Trino and Postgres** in transaction-pooling mode. When Postgres is under load, PgBouncer queues connections rather than opening new ones to an already-maxed-out replica, smoothing out spikes.

4. **Cap concurrent federation queries via Trino resource groups** with `hardConcurrencyLimit`. If too many federated queries hit Postgres simultaneously they compete for replica resources and slow each other down.

5. **Always use a read replica** — when timeouts happen, only analytics is affected, not your live application.

The key takeaway: **Trino does not retry automatically or return partial results.** It waits for timeouts to fire and then fails the entire query. Design your replica capacity and timeout thresholds with this all-or-nothing behavior in mind.
