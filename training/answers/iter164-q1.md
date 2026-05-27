# Iter 164 Q1 — Trino PostgreSQL Federation Performance Config

## Answer

You're right to suspect there's more to tune than just "overhead is the price of federation." Here's what matters for your specific setup:

## The critical reality: OSS Trino 467 has NO native PostgreSQL connection pooling

This is the first thing to understand. Connection timeout and fetch-size settings **don't exist in the Trino PostgreSQL connector** because there is no connection pool at all in open-source Trino 467. Properties like `connection-pool.enabled`, `connection-pool.max-size`, or `connection-pool.max-connection-lifetime` are **Starburst Enterprise only** — Trino will silently ignore them if you add them to your catalog file.

Without a connection pool, every concurrent query on a worker opens a **fresh Postgres connection for the duration of the query**. With 20 workers and several concurrent federated queries, you can easily exhaust Postgres's `max_connections` — and that manifests as sluggish queries waiting for connection slots.

## The actual performance levers (outside Trino's catalog config)

Your slow-via-Trino problem is likely one of these, and none are fixed by catalog properties:

**1. Predicate pushdown isn't firing**
Use `EXPLAIN (TYPE DISTRIBUTED)` on your cross-catalog JOIN to verify that both the Postgres and Iceberg sides show predicates actually pushed down inside the `ScanFilterProject` node. If you see a separate `Filter` node *above* the scan (rather than predicates embedded inside `ScanFilterProject`), Trino is pulling full tables and filtering in memory — catastrophic for joins. This is especially common if your join key or filter uses string ranges (like `WHERE email LIKE 'a%'`), which don't push down by default on the Postgres side. For those, you'd need the experimental flag `postgresql.experimental.enable-string-pushdown-with-collate=true`, but test it on a non-prod replica first.

**2. No dynamic filtering**
For large-to-large joins, dynamic filtering (where Trino derives a filter from the small side and pushes it to the big side at runtime) is what makes them survivable. Run `EXPLAIN ANALYZE` (not just `EXPLAIN`) and look for `dynamicFilterSplitsProcessed = N` on the probe-side scan. If it's zero, DF didn't fire — your join is scanning way more rows than needed. Raise `dynamic_filtering_wait_timeout` if your Postgres replica is slow: the default is 2 seconds, but if the build side takes longer, the probe side starts without a filter.

**3. Connection congestion (the real killer)**
Because there's no Trino-side pool, you must bound connections from **outside** Trino. Your actual config options:

- **Point at a read replica, never the OLTP primary** — a single slow federated query holds a long transaction on the primary, blocks VACUUM, and bloats tables.
- **Put PgBouncer between Trino and Postgres** in transaction-pooling mode. Trino opens many short-lived connections to PgBouncer; PgBouncer multiplexes them onto a small, bounded set of real Postgres connections. Set `connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb` in your catalog file instead of pointing directly at Postgres.
- **Set a Postgres role-level connection cap**: `ALTER ROLE trino_reader CONNECTION LIMIT 50;` — this is defense-in-depth so a misconfigured PgBouncer doesn't exhaust Postgres.
- **Cap concurrent federation queries in Trino resource groups** — a `hardConcurrencyLimit: 10` on the federation workload group means at most 10 concurrent queries hit Postgres simultaneously, regardless of how many users ask.
- **Set `statement_timeout = '5min'` on the Postgres replica** so a runaway query that somehow didn't get pushdown doesn't run forever.

## The slowness you're feeling is likely

1. **Predicate pushdown not happening** — confirm with `EXPLAIN`, especially if your join predicates are string-based or if you're joining on a non-indexed column.
2. **Dynamic filtering not firing** — run `EXPLAIN ANALYZE` and check `dynamicFilterSplitsProcessed`.
3. **Connection exhaustion or queueing** — if PgBouncer isn't in front of Postgres, the replica's connection slots are getting saturated and queries are waiting.

## What to do right now

1. On one of your slow reports, run `EXPLAIN (TYPE DISTRIBUTED)` to see if predicates are actually pushing down.
2. Then run `EXPLAIN ANALYZE` to confirm dynamic filtering is firing (look for `dynamicFilterSplitsProcessed > 0` on the Iceberg side).
3. If both are working, check Postgres: `SELECT count(*) FROM pg_stat_activity WHERE usename = 'trino_reader';` — if you're consistently near `max_connections`, add PgBouncer.

The hybrid pattern (Iceberg history + federated Postgres live tail via a UNION ALL view) only works well if the above three are already tuned. Otherwise, you're paying Trino overhead without the predicate pushdown / dynamic filtering benefit that makes federation worthwhile.
