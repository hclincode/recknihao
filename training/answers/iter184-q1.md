# Iter 184 Q1 — SET SESSION Properties for PostgreSQL Connector Catalogs

## Answer

Here's the complete map of what you can tune per-session vs what's locked in catalog properties for your Postgres federation catalogs.

---

### The critical syntax rule: connector session properties REQUIRE the catalog prefix

**Most common mistake**: bare `SET SESSION domain_compaction_threshold = 32` fails with "Session property does not exist." You must prefix with the catalog name:

```sql
SET SESSION billing_pg.domain_compaction_threshold = 32;
SET SESSION app_pg.enable_string_pushdown_with_collate = true;
```

The catalog prefix tells Trino which connector instance the property applies to. No coordinator restart required for any of these.

---

### Session properties available for PostgreSQL catalogs in OSS Trino 467

#### `domain_compaction_threshold` — IN-list compaction control

- **What it does**: When a dynamic filter produces more distinct values than this threshold, Trino compacts the IN-list to a `BETWEEN min..max` range before sending SQL to Postgres. BETWEEN is less selective and pulls more rows.
- **Default**: 256
- **Syntax**: `SET SESSION billing_pg.domain_compaction_threshold = 1024;`
- **When to raise**: Your join produces 300–1000 distinct keys and you're seeing `BETWEEN` in the Postgres slow log instead of `IN (...)`. Raise to 1024; verify via Postgres slow log.

#### `enable_string_pushdown_with_collate` — string range pushdown

- **What it does**: Enables range predicates on `VARCHAR`/`CHAR` columns (`>`, `<`, `BETWEEN`, anchored `LIKE`) to push down to Postgres. Disabled by default because collation differences between Postgres and Trino could cause incorrect results.
- **Default**: `false`
- **Syntax**: `SET SESSION billing_pg.enable_string_pushdown_with_collate = true;`
- **Caveat**: This is **experimental**. Test on a read replica first. It can disable Postgres index usage in some cases. Always verify with `EXPLAIN ANALYZE` before relying on it in production.

Note: this is also configurable as a catalog property `postgresql.experimental.enable-string-pushdown-with-collate=true` (requires coordinator restart). The session form lets you test it per-query without restart.

---

### What CANNOT be SET SESSION'd (and why)

#### `join_pushdown_enabled` — controls intra-catalog join pushdown per-query

**OSS Trino 467 DOES expose session properties for join pushdown.** For intra-catalog joins (both tables in `billing_pg`), you can disable pushdown per-query:

```sql
SET SESSION billing_pg.join_pushdown_enabled = false;  -- force join on Trino workers
SET SESSION billing_pg.join_pushdown_strategy = 'EAGER';  -- default: AUTOMATIC
```

- **`join_pushdown_enabled`** (default: `true`): Enables or disables intra-catalog join pushdown for this session. Useful for debugging when Postgres is making a bad join plan.
- **`join_pushdown_strategy`** (default: `AUTOMATIC`): `AUTOMATIC` pushes down only when the cost model estimates it's beneficial. `EAGER` pushes down whenever structurally possible.

**Cross-catalog joins** (`billing_pg` + `app_pg`, or `billing_pg` + Iceberg): **the join always runs on Trino workers** regardless of any session property. This is architecturally required — Postgres doesn't understand Iceberg tables and cannot execute cross-system joins. There is no session property to change this; it's a fundamental constraint.

Verify available properties for your cluster:
```sql
SHOW SESSION LIKE 'billing_pg.%';
```

#### No `fetch_size`, `socket_timeout`, `connect_timeout`

These **do not exist as Trino session properties**. They are configured via JDBC URL parameters in the catalog properties file:

```properties
# In etc/catalog/billing_pg.properties
connection-url=jdbc:postgresql://pgbouncer:6432/billing?defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10&prepareThreshold=0
```

Changing these requires a coordinator restart (or dynamic catalog drop/create). They cannot be changed per-session.

Note: Trino's internal JDBC layer already defaults to fetching ~1000 rows per round-trip, so `defaultRowFetchSize=1000` in the URL primarily serves as explicit documentation and an edge-case guard.

#### No `partition_column`, `partition_count`, parallelism controls

These **do not exist in OSS Trino 467**. They are Starburst Enterprise features. Running `SET SESSION billing_pg.partition_column = 'id'` produces "Unknown session property." Postgres tables always produce one split = one worker = one JDBC connection, regardless of any per-session settings.

---

### How to discover what session properties actually exist

```sql
SHOW SESSION LIKE 'billing_pg.%';
```

This lists every available session property for the `billing_pg` catalog. If a property doesn't appear here, it doesn't exist on that connector in your Trino version. Do not add it to your catalog properties file expecting it to work.

---

### The mental map: catalog properties vs session properties

| What you're tuning | Catalog properties file | Session properties |
|---|---|---|
| **IN-list compaction threshold** | `domain-compaction-threshold=256` (restart needed) | `SET SESSION billing_pg.domain_compaction_threshold = 1024` ✓ |
| **String range/LIKE pushdown** | `postgresql.experimental.enable-string-pushdown-with-collate=true` (restart needed) | `SET SESSION billing_pg.enable_string_pushdown_with_collate = true` ✓ |
| **Intra-catalog join pushdown** | `join-pushdown-enabled=false` (restart needed) | `SET SESSION billing_pg.join_pushdown_enabled = false` ✓ |
| **Intra-catalog join strategy** | (default AUTOMATIC) | `SET SESSION billing_pg.join_pushdown_strategy = 'EAGER'` ✓ |
| **Cross-catalog join pushdown** | Not configurable (structural — cross-engine joins always on Trino) | Not configurable |
| **Fetch size / socket timeout** | JDBC URL parameters (restart needed) | ✗ Does not exist |
| **Parallelism / partition-column** | Not available in OSS Trino 467 | Not available |
| **Connection pooling** | Not available in OSS Trino 467 (use PgBouncer) | Not available |

---

### Summary: what you can actually change on the fly

For `billing_pg` and `app_pg` in OSS Trino 467, per-session tuning includes:

1. **`domain_compaction_threshold`** — raise to keep IN-lists precise when dynamic filtering produces >256 values
2. **`enable_string_pushdown_with_collate`** — experimental; enables string range/LIKE pushdown when collation allows
3. **`join_pushdown_enabled`** — disable intra-catalog join pushdown for a specific query (useful for debugging Postgres join planner choices)
4. **`join_pushdown_strategy`** — `AUTOMATIC` (default) or `EAGER` for intra-catalog join pushdown

Fetch size, timeouts, and parallelism are locked in catalog properties or don't exist in the open-source version. Cross-catalog join pushdown (across `billing_pg` + Iceberg) is architecturally impossible regardless of any setting.
