# Iter 202 Q2 — JDBC Fetch Size and Timeout Tuning for Trino PostgreSQL Federation

## Answer

Your team's intuition about JDBC fetch size is correct — it's one of the key levers for federation performance. Trino's PostgreSQL connector doesn't expose fetch size as a separate catalog property; instead, you configure it via **JDBC URL parameters on the `connection-url` string** in your catalog properties file.

---

### What is `defaultRowFetchSize` and why it matters

`defaultRowFetchSize` controls how many rows the JDBC driver fetches per network round-trip from your Postgres replica to Trino workers. Think of it like a batch size: each time Trino needs more rows, the driver can grab 100 rows (small batch) or 5,000 rows (large batch) in a single network call. Larger batches reduce round-trips; smaller batches reduce memory pressure on Trino workers.

**Trade-off:**
- **Too low (e.g., 100)**: many round-trips to Postgres, high latency, unnecessary network chatter. This is likely contributing to your 30–60 second queries.
- **Too high (e.g., 50,000)**: fewer round-trips, but more memory consumed per query on Trino workers. Risk of hitting per-query memory limits on large result sets with many concurrent queries.
- **Goldilocks zone for analytics**: `1,000–5,000` for typical federated queries.

**Important caveat**: Fetch size tuning is a secondary optimization. The primary fixes for slow federation queries are: (1) **predicate pushdown** — verify your filters actually reach Postgres's WHERE clause, not just Trino's memory, and (2) **replica placement** — minimize network RTT to the replica.

---

### The two timeout parameters: `socketTimeout` vs. `connectTimeout`

These control different failure modes:

| Parameter | What it does | When it fires | Typical production value |
|---|---|---|---|
| **`socketTimeout`** | Abort the query if Postgres goes **silent** (no data arriving) for this many seconds | Network blip, hung Postgres backend | `60` seconds |
| **`connectTimeout`** | Abort immediately if the TCP connection can't open in this many seconds | Postgres/PgBouncer is down, network partition | `10` seconds |

**Without these timeouts**, a single stuck Postgres query can leave a Trino worker blocked forever on a socket read, cascading into starvation of other concurrent queries.

**If you set them wrong:**
- `socketTimeout` too low (e.g., 10s) → legitimate slow Postgres queries get killed mid-stream even when making progress. 25-second queries fail intermittently.
- `socketTimeout` too high (e.g., 3600s) → a hung backend blocks a Trino worker for an hour instead of failing fast.
- `connectTimeout` too high (e.g., 60s) → if Postgres is down, Trino workers wait 60 seconds per connection attempt.

---

### Minimum production-ready catalog configuration

In `etc/catalog/app_pg.properties`:

```properties
connector.name=postgresql
connection-url=jdbc:postgresql://postgres-replica.example.com:5432/appdb?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=${ENV:POSTGRES_USER}
connection-password=${ENV:POSTGRES_PASSWORD}
```

**If going through PgBouncer** (which you should for connection pooling — OSS Trino 467 has no native JDBC connection pool):

```properties
connector.name=postgresql
connection-url=jdbc:postgresql://pgbouncer.example.com:6432/appdb?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10&prepareThreshold=0
connection-user=${ENV:POSTGRES_USER}
connection-password=${ENV:POSTGRES_PASSWORD}
```

The `prepareThreshold=0` is mandatory in PgBouncer transaction-pooling mode to prevent prepared-statement errors.

---

### Recommended starting values for your workload

```properties
connection-url=jdbc:postgresql://replica.example.com:5432/appdb?defaultRowFetchSize=3000&socketTimeout=60&connectTimeout=10
```

- **`defaultRowFetchSize=3000`**: 3x the baseline default, reduces round-trips with modest memory increase. If per-query memory pressure appears, drop to 1500.
- **`socketTimeout=60`**: fail in 60 seconds if a Postgres backend hangs. Pair with `statement_timeout=5m` on your replica role.
- **`connectTimeout=10`**: fail fast if the replica is unreachable.

---

### Other things to check before concluding JDBC is the bottleneck

1. **Predicate pushdown** — verify in `EXPLAIN (TYPE DISTRIBUTED)` that your WHERE filters push down to Postgres. If Physical Input is much larger than expected, the filter is running in Trino memory after a full table scan.

2. **Postgres replica lag** — run `SELECT now() - pg_last_xact_replay_timestamp();` on the replica. Significant lag means slow queries even with perfect JDBC tuning.

3. **Query frequency / caching** — if analysts run the same query every 30 seconds instead of caching results for 5 minutes, application-layer caching is more impactful than JDBC tuning.

---

### One critical reminder

**OSS Trino 467 has NO native connection pooling for the PostgreSQL connector.** Properties like `connection-pool.enabled` and `connection-pool.max-size` belong to Starburst Enterprise, not open-source Trino. If you need connection pooling (which you do for production), put PgBouncer in front of Postgres.
