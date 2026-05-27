# Iter255 Q2 — PgBouncer + Trino JDBC Connection Pooling

## Answer

## Yes, Your Diagnosis Is Correct — But There's More to the Story

Your guess about PgBouncer rotating connections mid-query and breaking prepared statements is exactly right. Let me walk through what's happening, how many connections Trino actually needs, and how to fix it.

### The Prepared Statement Problem: Why PgBouncer's Transaction Mode Breaks Trino

PostgreSQL server-side prepared statements are **connection-scoped**. When the JDBC driver sends a `PREPARE` statement to Postgres, it lives inside that specific backend process. PgBouncer in **transaction-pooling mode** (`pool_mode = transaction`) — which you likely have configured — routes successive transactions from the same client to **potentially different Postgres backend connections**.

Here's the failure sequence:

1. Trino's JDBC driver connects to PgBouncer and runs a query. By default, after the 5th execution of the same SQL (`prepareThreshold=5`), the driver issues `PREPARE` on backend connection A.
2. PgBouncer routes the next transaction to backend connection B (different from A).
3. Backend B never saw the original `PREPARE`, so when Trino tries to use the prepared statement, Postgres returns: `ERROR: prepared statement "S_1" does not exist`.

Your federation will appear to work fine for the first few queries, then fail intermittently after the driver promotes statements to prepared form. This is typically why "we get weird prepared statement errors a few minutes into the day" reports come on day 2–3 of production.

### How Many Connections Does Trino Open to Postgres?

**One per non-partitioned Postgres table scanned per query.**

OSS Trino does NOT support parallel sharded reads of a single Postgres table. When Trino scans a Postgres table:
- **One non-partitioned table** = 1 split → 1 JDBC connection → 1 Trino worker thread
- **Multiple Postgres tables in the same query** = one connection per table
- **Iceberg + Postgres join** = 1 connection for Postgres side + parallelized Iceberg reads (80+ connections if 80 Parquet files)

The limiting factor is the **split model**, not the number of workers. A 20-worker Trino cluster scanning one Postgres table gets 19 idle workers and 1 worker threading rows through a single JDBC connection. This is why single-table Postgres scans are bounded by **JDBC throughput on a single thread** — typically 50K–200K rows/second depending on row width and network.

### The Fix: Two Options

#### Option 1: PgBouncer Transaction Mode + `prepareThreshold=0` (Recommended)

Keep PgBouncer in transaction-pooling mode for maximum multiplexing, but disable server-side prepared statements in the JDBC driver. In your Trino catalog file (`etc/catalog/app_pg.properties`):

```properties
connector.name=postgresql
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=trino_reader
connection-password=${ENV:PG_PASSWORD}
```

The `prepareThreshold=0` setting disables server-side prepared statements entirely. Every query is sent as a simple query string with inline parameters instead. This adds a small per-query parsing overhead (no plan reuse), but **eliminates the prepared-statement routing error entirely**. This is the standard, documented workaround for PgBouncer + PostgreSQL JDBC in transaction mode.

**Why this is better than session mode**: PgBouncer's `pool_mode = session` would solve the prepared-statement problem (each client gets a dedicated backend for its whole session), but at the cost of much lower multiplexing — you'd need almost as many backends as concurrent Trino client connections, which defeats the point of using a pooler. Transaction-pooling + `prepareThreshold=0` gives you the highest multiplexing factor while staying safe.

#### Option 2: PgBouncer 1.21+ With Native Prepared-Statement Support

If your PgBouncer is version 1.21 or later (released October 2023), you can opt into native prepared-statement tracking by setting `max_prepared_statements > 0` in `pgbouncer.ini`:

```ini
[pgbouncer]
pool_mode = transaction
max_prepared_statements = 100   # tune to your peak unique prepared-statement count
```

With this enabled, PgBouncer **transparently replays the PREPARE on whichever backend it routes the next transaction to**, eliminating the error. However, **unless you have explicitly verified both (a) PgBouncer ≥ 1.21 AND (b) `max_prepared_statements > 0` is actually configured, keep `prepareThreshold=0`.**

Check your PgBouncer version:
```bash
pgbouncer --version
```

### Should You Run Separate PgBouncer Pools for Trino vs. Your App?

**Yes, separate pools is strongly recommended.** Here's why:

- **Your app server** likely uses session-pooling mode (`pool_mode = session`) — it holds connections open across multiple statements within a user session, relying on prepared statements and session-level state.
- **Trino** is stateless and read-only. It benefits from transaction-pooling mode (`pool_mode = transaction`) with `prepareThreshold=0`, which gives maximum multiplexing.

If you put both behind the same PgBouncer in transaction-pooling mode, your app's prepared statements will fail (same error you're seeing now, but from your app). If you use session-pooling for both, Trino's connection count will balloon because each Trino worker gets its own dedicated backend instead of multiplexing.

**Pattern:**
- PgBouncer pool A (port 6432, `pool_mode = transaction`, `max_client_conn = 1000`, `default_pool_size = 50`) → Trino
- PgBouncer pool B (port 6433, `pool_mode = session`, separate backend pool) → Your app server

Or run two PgBouncer instances (one sidecar to Trino, one co-located with your app server). Both patterns work.

### Full JDBC URL Parameters for Production

For Trino against PgBouncer, here's the complete recommended `connection-url`:

```properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
```

| Parameter | What it does | Why it matters |
|---|---|---|
| `prepareThreshold=0` | Disables server-side prepared statements | Prevents "prepared statement does not exist" errors in PgBouncer transaction-pooling mode |
| `defaultRowFetchSize=1000` | Batch size for fetching result rows | Reduces round-trips between Trino and Postgres |
| `socketTimeout=60` | Per-socket-read timeout in seconds | Prevents Trino workers from blocking forever on hung Postgres backends |
| `connectTimeout=10` | TCP connection establishment timeout in seconds | Fail-fast when PgBouncer or Postgres is down |

### The Complete Four-Layer Defense

To properly bound Postgres connections and prevent outages, layer these four mechanisms:

| Layer | Setting | Value | Where |
|---|---|---|---|
| **PgBouncer** | `default_pool_size` | 50 | `pgbouncer.ini` (actual backend connections) |
| **Postgres role** | `CONNECTION LIMIT` | 50 (match PgBouncer) | `ALTER ROLE trino_reader CONNECTION LIMIT 50` |
| **Trino resource groups** | `hardConcurrencyLimit` | 10 | `etc/resource-groups.json` (concurrent queries) |
| **Postgres timeout** | `statement_timeout` | 5 minutes | `ALTER ROLE trino_reader SET statement_timeout='5min'` |

The PgBouncer pool size and Postgres role `CONNECTION LIMIT` should be the same — the role limit acts as a "did anything bypass PgBouncer?" tripwire.
