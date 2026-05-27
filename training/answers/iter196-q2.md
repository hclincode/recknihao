# Iter 196 Q2 — PostgreSQL Connector Properties Deep Dive

## Answer

Based on OSS Trino 467 on on-prem Kubernetes with a Postgres read replica, here's concrete guidance on each question.

---

## 1. Parallel reads with `partition-column` — NOT available in OSS Trino 467

**OSS Trino 467 does NOT have a `partition-column` or `partition-count` property** for parallel Postgres reads. This feature is requested but unimplemented (GitHub issue trinodb/trino#389, open since 2019).

Those properties exist **only in Starburst Enterprise** (the commercial fork), not in open-source Trino. Do not add them to your `postgresql.properties` file — Trino will silently ignore them.

**What you CAN do in OSS Trino 467:**

- **Rely on Postgres-side partition pruning** — if your table uses Postgres declarative partitioning, a selective WHERE clause will prune child partitions server-side.
- **Push down selective predicates** (most impactful) — a highly selective WHERE clause reduces rows at source far more than parallelism would help.
- **Ingest to Iceberg long-term** — for large analytical tables, replicate the Postgres data to Iceberg (via Spark batch or Debezium CDC). Each Iceberg Parquet file becomes a split, so 100 files = 100 parallel worker reads.

---

## 2. Connection and query timeouts

Timeout properties do NOT exist as OSS Trino 467 catalog properties. Configure them via **JDBC URL parameters** in the `connection-url` itself:

```properties
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}
```

| Parameter | What it does | Recommended value |
|---|---|---|
| `socketTimeout=60` | Per-socket-read timeout in **seconds**. After 60s with no data from Postgres, JDBC read fails and the Trino worker unblocks. | `60`; raise to `120` for slow queries |
| `connectTimeout=10` | Initial TCP-connect timeout in **seconds**. Fail-fast if PgBouncer or Postgres is down. | `10` |
| `defaultRowFetchSize=1000` | Rows fetched per network round-trip from Postgres to Trino. | `1000`–`5000` depending on row width |

Pair with `statement_timeout` on the Postgres replica side (e.g., 5–10 minutes) for defense in depth.

---

## 3. SSL for your Kubernetes-internal Postgres replica

**Intra-cluster same-cluster communication does NOT intrinsically require SSL** on isolated on-prem clusters. However, if your security policy requires it:

**For intra-cluster (minimal risk):**
```properties
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb?ssl=true&sslmode=require&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
```

**For full certificate verification:**
```properties
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb?ssl=true&sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10
```

The CA certificate must be mounted on **every Trino pod** (coordinator AND all workers — workers do the actual JDBC reads). Forgetting the workers is a common mistake.

---

## 4. `unsupported_type_handling` — what to do with custom Postgres types

This is a **session property** (not a catalog property). It tells Trino how to handle Postgres data types it doesn't natively understand.

**Default behavior:** `IGNORE` — Trino skips the column entirely from the result set. The table remains accessible; just that column is missing.

**If you need to read those columns:**

```sql
SET SESSION app_pg.unsupported_type_handling = 'CONVERT_TO_VARCHAR';
SELECT * FROM app_pg.public.my_table_with_custom_types;
```

With `CONVERT_TO_VARCHAR`, Trino reads unsupported types as strings. You lose type-level operations but get the data.

**When do you hit this?** Custom domains, PostGIS geometry columns, Postgres enum types, arrays of non-standard types.

**Check your 15 tables for custom types:**
```sql
-- Run against your Postgres replica:
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND data_type NOT IN ('integer', 'bigint', 'text', 'character varying', 'boolean',
                        'timestamp without time zone', 'date', 'numeric', 'uuid', 'jsonb', 'json');
```

If the result is empty, you don't need this property.

---

## 5. Session-level properties for the Postgres connector

**Yes, the PostgreSQL connector has session properties you can set per-query** without restarting the coordinator:

```sql
-- Raise the IN-list threshold if dynamic filters hit a compaction limit:
SET SESSION app_pg.domain_compaction_threshold = 1024;

-- Wait longer for dynamic filters from joins:
SET SESSION app_pg.dynamic_filtering_wait_timeout = '45s';

-- Disable intra-catalog join pushdown (for debugging):
SET SESSION app_pg.join_pushdown_enabled = false;

-- Read Postgres custom types as strings:
SET SESSION app_pg.unsupported_type_handling = 'CONVERT_TO_VARCHAR';

-- Enable array column mapping:
SET SESSION app_pg.array_mapping = 'AS_ARRAY';
```

**What does NOT exist as session properties:**
- `<catalog>.fetch_size` / `<catalog>.socket_timeout` — ONLY as JDBC URL parameters
- `<catalog>.partition_column` / `<catalog>.partition_count` — Starburst Enterprise only
- Bare property names without catalog prefix (must be `SET SESSION app_pg.join_pushdown_enabled`, not `SET SESSION join_pushdown_enabled`)

**See all available session properties on your cluster:**
```sql
SHOW SESSION LIKE 'app_pg.%';
```

---

## Summary — your updated `postgresql.properties`

```properties
connector.name=postgresql

connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb?ssl=true&sslmode=require&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10

connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}

# Cache schema metadata to reduce repeated catalog queries
metadata.cache-ttl=60s
metadata.cache-missing=true
```
