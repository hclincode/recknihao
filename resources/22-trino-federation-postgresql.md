# Trino Federation: Querying PostgreSQL Directly from Trino

A practical guide for SaaS engineers who want to **join their live OLTP Postgres data against historical Iceberg data in a single SQL query** — using Trino's PostgreSQL connector. This is one of the most-asked, least-understood features of Trino.

> **Production stack assumed**: Trino 467 on on-prem Kubernetes, Iceberg 1.5.2 on MinIO via Hive Metastore, plus an existing operational Postgres (your SaaS app's primary DB or a read replica thereof). JWT auth, OPA authz. No cloud-managed services.

---

## Quick Reference — Topics Covered in This Resource

Search this document by keyword. Major topics and where they live:

- **Predicate pushdown**: Section 2A.2 (MySQL/PostgreSQL — what pushes, what doesn't, VARCHAR no-pushdown)
- **PostgreSQL VARCHAR pushdown — equality vs range** (the most-confused fact): Section 3.2 canonical callout — equality/IN/IS NULL/dynamic-filter IN-lists ALL push; only RANGE (`<`,`>`,`BETWEEN`) does not push by default
- **Top-N pushdown (`ORDER BY <col> LIMIT N`) on PostgreSQL**: Section 3.3A — **YES, it pushes** by default (session `app_pg.topn_pushdown_enabled = true`); EXPLAIN signature for SUCCESS = `sortOrder=[...] limit=N` annotations INSIDE the TableScan with NO separate TopN operator above; signature for FAILURE = a separate `TopN [topN=N, orderBy=[...]]` operator sitting ABOVE a bare TableScan. Doesn't push above Joins, Unions, Aggregations, or when sort key is a function. Fallback when it refuses: `system.query()` passthrough.
- **Iceberg time travel + live PostgreSQL federation** (FOR VERSION AS OF, FOR TIMESTAMP AS OF, snapshot expiry, tags for audits, domain_compaction_threshold, DF wait-timeout asymmetry): Section 4.7
- **Dynamic filtering (runtime join pruning)**: Section 5 — how build-side IN-lists prune probe-side Iceberg scans; wait-timeout defaults (JDBC 20s, Iceberg 1s); VARCHAR key caveat; EXPLAIN ANALYZE VERBOSE verification
- **DF build/probe direction rule (CRITICAL mental model)**: Section 5.1.1 — DF flows from SMALLER (build) table TO LARGER (probe) table, not the reverse; worked examples for both directions
- **DF supported join types + predicates (CRITICAL — commonly misstated)**: Section 5.1.1A — **INNER and RIGHT joins ONLY** (LEFT OUTER and FULL OUTER are NOT supported); **equality AND inequality (`<`, `<=`, `>`, `>=`, `IS NOT DISTINCT FROM`) predicates BOTH trigger DF** for INNER/RIGHT joins. `enable_dynamic_filtering` system session property for per-query debugging.
- **`domain-compaction-threshold` (IN-list → BETWEEN range compaction at 256)**: Section 5.1.2 — collision with VARCHAR range-pushdown on PostgreSQL; `domain_compaction_threshold` and `enable_large_dynamic_filters` tuning levers
- **Resource groups (`hardConcurrencyLimit`, `softConcurrencyLimit`, `maxQueued`, selectors, subgroups, hot-reload)**: Section 8.2C — full JSON schema, multi-subgroup selector routing pattern. **Hot-reload reality**: file-based manager (`configuration-manager=file`) requires coordinator restart on `resource-groups.json` changes; only the database-based manager (`configuration-manager=db`) supports live updates via `resource-groups.refresh-interval`. **DO NOT INVENT property names — `resource-groups.config-refresh-period` does NOT exist; `maxQueuedQueries` does NOT exist (use `maxQueued`); `http-server.max-connections` does NOT exist (use `http-server.threads.max` if you really need it, but resource groups are the right lever for concurrency limits).**
- **BROADCAST vs PARTITIONED join distribution**: Section 5.5.1 — what happens when build exceeds `join-max-broadcast-table-size` (100MB default); both sides shuffle in PARTITIONED, neither is "streamed"
- **metadata.cache-ttl (MySQL schema caching)**: Section 2A — default 0s (disabled), increase to 30s-60s to reduce planning latency
- **MERGE on MySQL**: Section 2A.7 — non_transactional_merge_enabled, MERGE_TARGET_ROW_MULTIPLE_MATCHES, ROW_NUMBER dedup
- **Connection pooling**: Section 3 — no OSS pool, connection-pool.* is Starburst Enterprise-only, ProxySQL
- **Timeouts (7 layers)**: Section 8.3A — socketTimeout (ms!), max_execution_time (ms!), query.max-execution-time
- **SSL/TLS for MySQL**: Section 2A.1A — trustCertificateKeyStoreUrl, sslMode=VERIFY_IDENTITY, keytool PEM->JKS
- **EXPLAIN ANALYZE for federated queries**: Section 7 — Physical Input, Scheduled vs CPU, join distribution
- **Per-split model (MySQL = 1 split, no parallelism)**: Section 2A.5 — NOT configurable in OSS Trino; Spark JDBC partition options do NOT apply
- **Unsupported PostgreSQL column types — `postgresql.unsupported-type-handling`**: Section 2.2A — default `IGNORE` silently drops columns (no error, missing from `DESCRIBE`); `CONVERT_TO_VARCHAR` is the schema-wide fix; JSONB is supported (maps to JSON natively); full diagnostic flow for "column X breaks federated SELECT"; common unsupported types (hstore, range, citext, xml, TIMESTAMPTZ arrays)
- **Cross-catalog CTAS vs INSERT INTO** (Postgres → Iceberg materialization patterns): Section 9.5 — CTAS creates a NEW Iceberg table from a Postgres source (full re-snapshot); `INSERT INTO iceberg.x SELECT FROM app_pg.x` appends to an EXISTING table (incremental refresh, preserves snapshot history). HMS registration at query start, atomic data visibility only at commit, orphan files from mid-INSERT failures need `ALTER TABLE ... EXECUTE remove_orphan_files`. Column type compatibility matrix included.
- **Three ways to expose a federated JOIN to dashboards**: (a) **`CREATE VIEW`** = Section 7.5 — pure SQL substitution, no caching, re-federates every query, right for low-traffic + schema-contract use; (b) **`CREATE MATERIALIZED VIEW` (Iceberg target only)** = Section 7.6 — Trino auto-creates an Iceberg storage table, `REFRESH MATERIALIZED VIEW` populates it, reads hit the cache and never touch Postgres; (c) **Manual `INSERT INTO iceberg.x SELECT ...`** = Section 9.5 — you own the target table and refresh job (dbt / Airflow / cron), supports MERGE / watermarked incremental / multi-step pipelines.

---

## 0. CRITICAL — OSS Trino 467 has NO native PostgreSQL connection pooling

> **Read this before you touch any catalog properties file.**
>
> **Open-source Trino 467's PostgreSQL connector does NOT have built-in JDBC connection pooling.** The feature is requested but not yet implemented — see [trinodb/trino#15888](https://github.com/trinodb/trino/issues/15888) (open since January 2023).
>
> Properties like `connection-pool.enabled`, `connection-pool.max-size`, and `connection-pool.max-connection-lifetime` that appear in some documentation and blog posts belong to **Starburst Enterprise** (the commercial fork of Trino), **NOT the open-source Trino 467 used in this stack**.
>
> **Do NOT add `connection-pool.*` properties to your PostgreSQL catalog properties file** — Trino will silently ignore them and the pool will not exist. If you copy-paste them from a Starburst doc, the missing-pool problem you were trying to solve will persist and you will blame the wrong layer.
>
> **The correct OSS Trino 467 mitigations for "too many Postgres connections" are documented in Section 8.2 below**: PgBouncer in front of Postgres, Postgres role-level `CONNECTION LIMIT`, Trino resource groups, and `statement_timeout` on the replica. Use those instead.
>
> **Connector-prefix rule clarification**: the only OSS Trino JDBC connector with native connection pooling (as of Trino 467) is **Oracle**, which uses the `oracle.connection-pool.*` prefix. No other standard JDBC connector (including PostgreSQL, MySQL, SQL Server) has native pooling in OSS Trino 467. Do not generalize the Oracle property names to other connectors.

---

## 1. The one-paragraph mental model

Trino is not just a query engine for Iceberg. It is a **federated SQL engine** — it can attach to many different data sources at once (Iceberg, Postgres, MySQL, Kafka, Elasticsearch, etc.), each as a separate **catalog**. Once you configure a PostgreSQL connector catalog called, say, `app_pg`, you can write `SELECT ... FROM app_pg.public.users` from any Trino session — same as you'd write `SELECT ... FROM iceberg.analytics.events`. The big win is that you can also **JOIN across catalogs in one statement**: `iceberg.analytics.events JOIN app_pg.public.users ON ...`. This works. There are real-world gotchas (predicate pushdown is partial, cross-catalog join pushdown does not exist, you need to point at a read replica) — this doc covers all of them.

> **Cross-catalog join performance — three things that matter most:**
> 1. **Predicate pushdown**: equality/range filters on each side push down to their respective storage engine (Postgres → SQL WHERE clause; Iceberg → partition pruning + file skipping). See Section 3.
> 2. **Dynamic filtering** (enabled by default): after the small build side of a join finishes, Trino derives a runtime predicate (IN-list or min/max range) from the join keys and pushes it to the large probe side's scan — this is what makes "small Postgres dimension × huge Iceberg fact" joins efficient. Without it, the Iceberg side scans every row. See Section 5 for the full mechanism, EXPLAIN signals, and wait-timeout tuning.
> 3. **No cross-catalog join pushdown**: the join itself always executes on Trino workers. Postgres doesn't see the Iceberg table; Iceberg doesn't see the Postgres table. Only each side's own predicates push down.

---

## 2. What the PostgreSQL connector is and how to configure it

### 2.1 What you get

The PostgreSQL connector (`connector.name=postgresql`) is a built-in Trino connector that uses JDBC under the hood to talk to a Postgres server. Once configured, every database/schema in that Postgres instance shows up as a Trino schema inside the catalog, and every Postgres table shows up as a Trino table. You can `SELECT`, `INSERT`, `CREATE TABLE`, `DROP TABLE` from Trino — though for a live OLTP database you should treat it as read-only.

### 2.2 Catalog configuration file

Trino reads catalog config from `etc/catalog/<catalog-name>.properties` on each coordinator and worker pod. To add a Postgres catalog named `app_pg`, you create `etc/catalog/app_pg.properties` (typically mounted in via a k8s ConfigMap):

```properties
# etc/catalog/app_pg.properties
connector.name=postgresql

# JDBC URL — point at the READ REPLICA, never the OLTP primary
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb

# Credentials come from a Kubernetes secret, mounted as env vars
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}

# NOTE: OSS Trino 467's PostgreSQL connector has NO native connection pooling.
# Do NOT add `connection-pool.enabled` / `connection-pool.max-size` /
# `connection-pool.max-connection-lifetime` here — those properties belong to
# the Starburst Enterprise fork, not OSS Trino. Trino will silently ignore them.
# See Section 0 (top of this doc) and Section 8.2 for the correct OSS mitigations
# for connection pressure (PgBouncer in front of Postgres, role-level CONNECTION
# LIMIT, Trino resource groups, statement_timeout on the replica).
#
# If you want a connection pool, point `connection-url` at PgBouncer in
# transaction-pooling mode instead of Postgres directly — PgBouncer becomes the
# pool layer. Example (note prepareThreshold=0 — mandatory in transaction-pooling
# mode, see Section 8.2A):
#   connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0
#
# See Section 2.4 for other useful JDBC URL parameters (defaultRowFetchSize,
# socketTimeout, connectTimeout) — these are the real catalog-level performance
# levers on OSS Trino 467, since separate `postgresql.fetch-size` etc. properties
# do NOT exist.

# Optional: experimental string range pushdown (see Section 3.3)
# postgresql.experimental.enable-string-pushdown-with-collate=true
```

The credentials reference `${ENV:...}` so that the actual values come from a Kubernetes secret rather than being checked into a ConfigMap. A typical secret + pod spec wiring looks like:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: trino-postgres-credentials
  namespace: trino
type: Opaque
stringData:
  username: trino_reader
  password: <strong-random>
---
# In the Trino coordinator/worker pod spec:
env:
  - name: APP_PG_USER
    valueFrom:
      secretKeyRef:
        name: trino-postgres-credentials
        key: username
  - name: APP_PG_PASSWORD
    valueFrom:
      secretKeyRef:
        name: trino-postgres-credentials
        key: password
```

After mounting the new catalog properties file, Trino picks it up at startup. Roll the coordinator and worker pods. Then verify:

```sql
SHOW CATALOGS;                              -- you should see app_pg
SHOW SCHEMAS FROM app_pg;                   -- list Postgres databases/schemas
SHOW TABLES FROM app_pg.public;             -- list tables in the 'public' schema
SELECT * FROM app_pg.public.users LIMIT 5;  -- read a row from Postgres
```

#### Schema discovery cheat sheet — these `SHOW` / `DESCRIBE` statements work uniformly across every Trino connector

The five statements below are the **portable, connector-agnostic** way to introspect Trino metadata. They behave identically whether the catalog points at Iceberg, PostgreSQL, MySQL, Delta Lake, or any other connector. Use these first when you need to find what's available — do NOT reach for connector-specific introspection (pg_catalog, etc.) unless these are insufficient.

```sql
SHOW CATALOGS;                                    -- every catalog the cluster knows about
SHOW SCHEMAS FROM <catalog>;                      -- schemas inside a catalog
SHOW TABLES FROM <catalog>.<schema>;              -- tables (and views) inside a schema
DESCRIBE <catalog>.<schema>.<table>;              -- columns + types (concise)
SHOW COLUMNS FROM <catalog>.<schema>.<table>;     -- columns + types + extra info (same answer, verbose form)
```

> **`DESCRIBE` and `SHOW COLUMNS` return the same information** in slightly different output formats. Either works. Both pull from Trino's metadata layer, which queries the connector's introspection APIs — they do NOT execute arbitrary Postgres SQL.

#### Trino's `<catalog>.information_schema` is Trino's OWN information_schema — NOT a pass-through of Postgres's

This is one of the most-confused points about Trino federation. When you query `app_pg.information_schema.tables` or `app_pg.information_schema.columns`, you are querying **Trino's own implementation of the standard SQL information_schema views**, populated by the connector from the metadata it has introspected from Postgres. You are NOT querying Postgres's actual `information_schema.tables` / `information_schema.columns` views.

**Practical implications:**
- Only the **standard SQL information_schema columns** appear (table_catalog, table_schema, table_name, column_name, data_type, is_nullable, ordinal_position, etc.). Postgres-specific extensions to information_schema — and any custom views Postgres exposes under `information_schema` — do **NOT** appear.
- Data types are reported as **Trino types** (e.g., `bigint`, `varchar`, `timestamp(6)`), not Postgres types (e.g., `int8`, `text`, `timestamptz`). The connector maps them.
- If you need a Postgres-specific introspection answer — "is this column part of an index?", "what's the table size on disk?", "what custom types exist?" — `<catalog>.information_schema` will not give it to you. Use the two escape hatches below.

#### Postgres-native introspection escape hatches — two ways to reach pg_catalog and friends

When the portable cheat sheet above isn't enough (you genuinely need pg_catalog data — index definitions, table sizes, custom types, pg_stat_* views, etc.), OSS Trino 467's PostgreSQL connector gives you two mechanisms:

**1. `postgresql.include-system-tables=true` — expose Postgres system schemas as Trino schemas**

This is a **catalog property** added to `etc/catalog/app_pg.properties`. Once enabled and the coordinator restarted, Trino exposes Postgres's system schemas (`pg_catalog`, plus `information_schema` as Postgres sees it) as queryable Trino schemas under the same catalog:

```properties
# etc/catalog/app_pg.properties (or billing_pg.properties — same idea)
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}

# Expose pg_catalog / pg_namespace / pg_class / pg_type / pg_attribute etc.
# as queryable schemas through Trino. Default: false.
postgresql.include-system-tables=true
```

**Requires a coordinator restart** (it's a catalog property, not a session property). After the restart:

```sql
-- pg_catalog is now visible as a Trino schema:
SHOW SCHEMAS FROM app_pg;
-- ... includes pg_catalog, information_schema (Postgres's own), etc.

-- Query Postgres's pg_type catalog through Trino:
SELECT typname, typtype
FROM app_pg.pg_catalog.pg_type
WHERE typtype = 'b'  -- base types only
LIMIT 20;

-- Find all indexes on a table:
SELECT i.relname AS index_name, a.attname AS column_name
FROM app_pg.pg_catalog.pg_index ix
JOIN app_pg.pg_catalog.pg_class i ON i.oid = ix.indexrelid
JOIN app_pg.pg_catalog.pg_class t ON t.oid = ix.indrelid
JOIN app_pg.pg_catalog.pg_attribute a ON a.attrelid = t.oid AND a.attnum = ANY(ix.indkey)
WHERE t.relname = 'users';
```

Trade-off: this **clutters `SHOW SCHEMAS`** with dozens of Postgres internals you usually don't care about, and the data is fetched via JDBC just like any other table. Use it when you genuinely want regular, queryable access to pg_catalog through Trino. Otherwise, prefer option 2.

**2. `system.query()` table function — primary escape hatch for arbitrary native Postgres SQL**

The PostgreSQL connector exposes a **table function** under `<catalog>.system.query()` that takes a raw Postgres SQL string, sends it directly to the Postgres JDBC driver, and returns the result as a Trino table. This is the cleanest way to run any Postgres-specific SQL (pg_catalog queries, custom functions, pg_stat_* views, vendor extensions, JSON/JSONB operators that don't have Trino equivalents, etc.) without enabling `include-system-tables` cluster-wide and without leaving Trino.

```sql
-- General form (table function — note TABLE(...) and named arg `query =>`):
SELECT * FROM TABLE(
  billing_pg.system.query(
    query => 'SELECT typname, typtype FROM pg_catalog.pg_type WHERE typtype = ''b'''
  )
);

-- pg_stat_user_tables — find which tables are getting the most writes on the replica:
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT relname, n_tup_ins, n_tup_upd, n_tup_del FROM pg_stat_user_tables ORDER BY n_tup_ins DESC LIMIT 20'
  )
);

-- Index usage stats — find unused indexes on the replica:
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT schemaname, relname, indexrelname, idx_scan FROM pg_stat_user_indexes WHERE idx_scan = 0'
  )
);

-- A Postgres-specific JSON operator (would not work as native Trino SQL):
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, payload->''customer_id'' AS customer_id FROM events WHERE payload ? ''customer_id'''
  )
);
```

**Key properties of `system.query()`:**
- The query string is sent **verbatim** to Postgres via JDBC. Use Postgres syntax, Postgres functions, Postgres operators. Trino does not parse or rewrite it.
- **No predicate pushdown** — Trino treats the result as an opaque source. Push down what you need INSIDE the SQL string. If your `system.query()` returns 5M rows and you wrap it in `WHERE ...` outside, Trino pulls all 5M rows then filters. Always filter inside the query string.
- **No join pushdown** — joining `TABLE(app_pg.system.query(...))` against another table executes the join on Trino workers.
- Use it for **escape-hatch** queries: introspection, vendor-specific operators, custom Postgres functions. Don't use it as your normal data-read path for tables that Trino's connector can already see — you lose pushdown, statistics, and dynamic filtering.
- **Connector availability**: `system.query()` is documented for the PostgreSQL, MySQL, SQL Server, and Oracle connectors in OSS Trino 467. Same pattern, same `query => 'string'` argument, per connector catalog.

> **SECURITY WARNING — OPA does NOT inject row filters or column masks into `system.query()`.** Because Trino passes the SQL string verbatim to Postgres without analysis, OPA's row-filter and column-mask policies are **never invoked** for the underlying tables. OPA is consulted once — to check whether the user may call the table function — but no `WHERE tenant_id = ...` predicate is injected, and no column is masked. **In a multi-tenant setup, this means a single `system.query()` call can bypass all OPA tenant isolation.** Restrict access to the function for non-admin users.
>
> **OPA operation name for `system.query()` access control**: the Trino OPA plugin emits `"ExecuteFunction"` (not `"ExecuteTableFunction"`) when a user calls `system.query()`. Use this exact string in your Rego deny rule:
> ```rego
> deny if {
>   input.action.operation == "ExecuteFunction"
>   input.action.resource.function.name == "query"
>   not "platform-admin" in input.context.identity.groups
> }
> ```
> Verify the exact operation string your Trino version emits by checking your OPA decision log for a test `system.query()` call and inspecting `input.action.operation`.

**Which escape hatch to pick:**

| Need | Use |
|---|---|
| One-off "what does pg_stat_user_tables say right now?" diagnostic | `system.query()` — no config change, no restart |
| Regular automated queries against pg_catalog (e.g., a monitoring dashboard) | `postgresql.include-system-tables=true` — pg_catalog becomes a normal queryable schema |
| Vendor-specific operator that has no Trino equivalent (JSONB `?`, `@>`, full-text `@@`, etc.) | `system.query()` — the only way to express it |
| Schema-drift script comparing Postgres reality vs. Trino's view | `system.query()` for the Postgres side (querying Postgres's actual `information_schema.columns`), then compare against Trino's `<catalog>.information_schema.columns` |

### 2.2A Handling unsupported PostgreSQL column types — `postgresql.unsupported-type-handling`

Sooner or later a federated query against Postgres will fail with a confusing error message that names a column, OR — worse — a column will simply **vanish from `SELECT *` with no error at all**. The canonical fix is a single catalog property: **`postgresql.unsupported-type-handling`**. Read this section before chasing a phantom "JSONB bug."

#### The property — what it does

`postgresql.unsupported-type-handling` lives in your catalog properties file (`etc/catalog/app_pg.properties`) and controls what happens when the PostgreSQL connector encounters a column whose Postgres type it cannot natively map to a Trino type (range types, `hstore`, `xml`, custom domains, geometric types like `POLYGON`, arrays of `timestamp with time zone`, `citext`, etc.).

| Value | Behavior |
|---|---|
| **`IGNORE`** *(default)* | The column is **silently dropped** during schema inference. It does NOT appear in `DESCRIBE`, does NOT appear in `SELECT *`, and **no error is thrown**. Trying to reference the column by name yields `Column 'foo' cannot be resolved` — making it look like the column never existed. |
| **`CONVERT_TO_VARCHAR`** | The column is rendered as a Trino `VARCHAR` (the Postgres text-cast representation). You lose type safety — every value is a string — but the column is readable. This is the quick workaround for almost every "Trino doesn't support this type" complaint. |

Example catalog file:

```properties
# etc/catalog/app_pg.properties
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb
connection-user=${ENV:APP_PG_USER}
connection-password=${ENV:APP_PG_PASSWORD}

# Make unsupported Postgres column types readable as text instead of silently dropping them
postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR
```

This is a catalog property — **changing it requires rolling the Trino coordinator and worker pods**. Session-property form (no restart, scoped to one session) uses underscores and a catalog prefix:

```sql
SET SESSION app_pg.unsupported_type_handling = 'CONVERT_TO_VARCHAR';
```

#### Beginner trap — the default is `IGNORE`, so unsupported columns vanish silently

This is the single most-confusing default in the Postgres connector. With the out-of-the-box configuration:

- An engineer adds an `hstore` column on the Postgres side.
- `SELECT * FROM app_pg.public.things` returns rows with **every column except `hstore`**.
- `DESCRIBE app_pg.public.things` shows **every column except `hstore`**.
- `SELECT hstore_col FROM app_pg.public.things` returns `Column 'hstore_col' cannot be resolved`.

The engineer assumes the column was never created, or that there's a Trino bug. In fact, Trino saw the column, decided it couldn't map the type, and dropped it silently because `IGNORE` is the default. **Most engineers expect an error and get a missing column instead.** If a Postgres column "isn't showing up in Trino but exists in Postgres," your first hypothesis should always be `unsupported-type-handling=IGNORE`.

#### JSONB IS supported — don't blame JSONB

`jsonb` and `json` Postgres columns map natively to Trino's `JSON` type. They are NOT routed through `unsupported-type-handling`. **A "JSONB column breaks my query" report is typically caused by either the focal column itself (if it's a non-trivial type like an array of JSONB, or a custom domain) OR by an adjacent column with an unsupported type** (an `hstore`, a range type, an array of `timestamp with time zone`, etc.) — and JSONB itself is almost never the actual cause.

Practical implication: when an engineer says "I can't `SELECT *` from a table that has a JSONB column," don't go hunting for JSONB workarounds first, and **don't pre-guess which column is at fault**. Run `DESCRIBE catalog.schema.table` in Trino and compare against the Postgres-side `\d table_name` — **the `DESCRIBE` diff is the authoritative diagnostic**. The columns that are MISSING from `DESCRIBE` (whether the focal column or some other one in the table) are the actual culprits. Do not assert "it must be an adjacent column" before you have the diff in hand.

#### Common unsupported PostgreSQL types

Types that the Postgres connector cannot natively map (and therefore route through `unsupported-type-handling`):

| Postgres type | Why unsupported | Workaround |
|---|---|---|
| `enum` types (custom user-defined enums) | Actually supported as `VARCHAR` natively in current Trino — **NOT routed through `unsupported-type-handling`**. (Listed here because engineers commonly assume it is.) | None needed; the text label is returned as VARCHAR. |
| `hstore` | Postgres-specific key/value type, no Trino equivalent | `CONVERT_TO_VARCHAR` (renders as the Postgres text format `"k"=>"v"`) — or `system.query()` to use Postgres `hstore_to_jsonb()` server-side |
| Range types (`int4range`, `int8range`, `tsrange`, `tstzrange`, `daterange`, `numrange`) | Postgres-specific, no Trino range type | `CONVERT_TO_VARCHAR` (renders as `[lower,upper)`) — or `system.query()` to use Postgres range operators |
| `citext` | Postgres case-insensitive text extension | `CONVERT_TO_VARCHAR` (you lose the case-insensitive comparison semantics on the Trino side, but the values come through) |
| Arrays of `timestamp with time zone` (`TIMESTAMPTZ[]`) | Trino's array mapping does not cover this element type | `CONVERT_TO_VARCHAR` — or `system.query()` |
| `xml` | No Trino XML type | `CONVERT_TO_VARCHAR` (returns the XML as a text string) |
| Custom domains over unsupported base types | Inherits the base type's unsupported status | `CONVERT_TO_VARCHAR` |
| Geometric types (`POINT`, `POLYGON`, `BOX`, `CIRCLE`, `LINE`, `LSEG`, `PATH`) | No Trino native equivalent | `CONVERT_TO_VARCHAR` for casual inspection; for analytics use PostGIS + `system.query()` or denormalize into Iceberg with explicit lat/lon columns |
| Multi-dimensional arrays (e.g., `INTEGER[][]`) | Trino `ARRAY<T>` is flat — cannot hold nested arrays directly | **Set `postgresql.array-mapping=AS_JSON`** to bring the nested array through as a Trino `JSON` value (e.g. `[[1,2],[3,4]]`), then parse on the Trino side. Alternative: `system.query()` with Postgres-side `unnest()` to flatten server-side. |

Note that **PostgreSQL `ENUM`** is in this list only as a clarification — it maps natively to `VARCHAR` and does NOT need `unsupported-type-handling`. If an engineer thinks the connector is "converting their enum to VARCHAR via CONVERT_TO_VARCHAR," they're wrong about the mechanism — the mapping happens natively. See Section 9.4b for the full type-mapping reference.

Also note that **Postgres arrays of supported scalar types** (`TEXT[]`, `INTEGER[]`, `BIGINT[]`, `BOOLEAN[]`) are routed through a SEPARATE property — `postgresql.array-mapping` — not `unsupported-type-handling`. The default for array-mapping is `DISABLED`, which also silently omits arrays from results. The three valid values are `DISABLED` (default), `AS_ARRAY` (typed Trino ARRAY — `INTEGER[]` → `ARRAY<INTEGER>`, NOT widened to `ARRAY<BIGINT>`), and `AS_JSON` (Trino JSON — the workaround for multi-dim arrays). See Section 9.4b for the full array-mapping details.

#### Diagnostic flow — "column X breaks my federated SELECT"

When an engineer reports a federated query failing or returning unexpected results because of a column type, walk through these steps in order. Do not skip ahead.

**Step 0 — Rule out the stale-cache hypothesis (it's almost never the cause).** Engineers commonly ask "is Trino caching a stale schema?" when a column appears to be missing. **In a default OSS Trino 467 PostgreSQL connector setup, `metadata.cache-ttl` defaults to `0s` (disabled)** — schema metadata is fetched fresh from Postgres on every query. **No caching is happening by default**, so a missing column in `DESCRIBE` is virtually never explained by stale cache. Verify by checking `etc/catalog/app_pg.properties` for `metadata.cache-ttl=`; if it's absent or set to `0s`, you can immediately dismiss the caching hypothesis and proceed to Step 1. (The only scenario where caching IS the cause is if your team has explicitly raised `metadata.cache-ttl > 0` for performance reasons AND someone just ran `ALTER TABLE` on Postgres in the last cache window — see Section 2.6 for that flow. For the "missing column that's been there for hours/days" case, the real cause is almost always `unsupported-type-handling=IGNORE`.)

**Step 0.5 — Enable JDBC debug logging on the coordinator (the diagnostic shortcut).** Before grinding through `DESCRIBE` diffs, you can ask Trino to **directly tell you which column it failed to map**. Add this single line to `etc/log.properties` on the coordinator:

```properties
# etc/log.properties (coordinator)
io.trino.plugin.jdbc=DEBUG
```

Restart the coordinator. The next time Trino introspects the table's schema, the JDBC plugin logs the **exact column name and Postgres type that it dropped** (or attempted to map and rejected). Look in `var/log/server.log` (or your shipped log destination — Loki, OpenSearch) for lines from `io.trino.plugin.jdbc`. Example log line you'll see:

```
io.trino.plugin.jdbc.DefaultJdbcMetadata - Unsupported type: hstore on column tenant_settings.extra_attrs
```

This bypasses the manual `DESCRIBE` vs `\d` diff and names the culprit directly. **Important — revert after diagnosis**: `io.trino.plugin.jdbc=DEBUG` is very verbose (it logs every JDBC call, including every metadata lookup and every query plan). Leaving it on in production will balloon log volume and slow the coordinator on a busy cluster. Set it back to `INFO` (the default) or remove the line once you've identified the offending column, then restart.

> **Scope note — `io.trino.plugin.jdbc=DEBUG` covers ALL JDBC connectors, not just PostgreSQL.** This logger is implemented in the shared JDBC base plugin (`io.trino.plugin.jdbc`), so it captures debug output from **every JDBC-based connector**: PostgreSQL, MySQL, SQL Server, Redshift, Oracle, etc. If your cluster has multiple JDBC catalogs (e.g., `app_pg` for PostgreSQL + `billing_mysql` for MySQL), the debug log lines from both connectors will be **interleaved** in `var/log/server.log`. To isolate output from a specific catalog, filter by catalog name or by the JDBC connection URL fragment that appears in the log line. Example: `grep "io.trino.plugin.jdbc" var/log/server.log | grep "app_pg\|jdbc:postgresql"` for the PostgreSQL-only subset. For per-connector logger overrides, use a more specific logger name if it exists (e.g., `io.trino.plugin.postgresql=DEBUG` for some PostgreSQL-specific code paths), but most of the useful "what SQL was sent / what type was rejected" output comes from the shared base logger and applies to all JDBC catalogs.

**Step 1 — Read the exact Trino error.** Trino's error message for an unsupported type almost always names the offending column and its Postgres type, e.g.:

```
Unsupported type: hstore
```

or

```
Failed to get table: tenant_settings_range is of unsupported type tsrange
```

The column name and type are the first thing to look at. The offending column might be the one the engineer is focused on, OR it might be a different column in the same table (e.g., a `SELECT *` that fails on an adjacent `hstore` column when the engineer was focused on a JSONB column). **Don't pre-decide which column is at fault — let the error message and the `DESCRIBE` diff in Step 2 tell you which.** (A common misdiagnosis: "my query joins on a JSONB column so JSONB must be the problem" — sometimes the table has an adjacent `hstore` column that broke `SELECT *`, but other times the focal column itself has a quirk like a custom domain over an unsupported base type. Don't assume; verify with Step 2.)

**Step 2 — Run `DESCRIBE catalog.schema.table` and compare to Postgres `\d`.** This is the **authoritative diagnostic**. If a column you know exists on the Postgres side is **MISSING entirely** from `DESCRIBE` (not showing up as a weird type — actually absent), it is being silently dropped by `postgresql.unsupported-type-handling=IGNORE`. This is the most common cause of "the column just isn't there." The missing column may be the one the engineer was focused on OR a different one — read the diff carefully; don't assume.

```sql
-- In Trino:
DESCRIBE app_pg.public.tenant_settings;
-- Compare to: \d public.tenant_settings on the Postgres side
-- Any column present in Postgres but ABSENT from DESCRIBE is being silently dropped.
```

**Step 3 — Set `postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR` and restart.** Add the property to `etc/catalog/app_pg.properties` and roll the Trino coordinator + worker pods. After the restart:

```sql
DESCRIBE app_pg.public.tenant_settings;
-- The previously-missing column now appears as VARCHAR.
SELECT my_unsupported_col FROM app_pg.public.tenant_settings LIMIT 5;
-- Returns the Postgres text-cast representation of each value.
```

For a one-off without restart, use the session property:

```sql
SET SESSION app_pg.unsupported_type_handling = 'CONVERT_TO_VARCHAR';
-- Run your query in the same session.
```

This is the schema-wide fix that resolves most "vanishing column" reports.

**Step 4 — For per-query Postgres-native type handling, use `system.query()` passthrough.** If `CONVERT_TO_VARCHAR` loses information you actually need (e.g., you want to filter on a range type using `<@` / `&&` operators, or query an `hstore` column with `?` / `->` operators), use the `system.query()` escape hatch to push the entire query to Postgres:

```sql
-- Use Postgres-native range operator @> ("contains")
SELECT * FROM TABLE(
  app_pg.system.query(
    query => 'SELECT id, tenant_id, valid_range
              FROM tenant_settings
              WHERE valid_range @> NOW()::timestamp'
  )
);
```

The full row, including the unsupported column rendered however Postgres's wire protocol sends it, is returned. Trino does not need to understand the type — it just passes results through. See Section 2.2 escape hatches (#2) for the full `system.query()` documentation.

**Step 5 — For analytics at scale, denormalize into Iceberg.** If you regularly need analytics over a Postgres table with unsupported column types, the right long-term fix is to ingest the table into Iceberg via Spark, projecting the unsupported columns into explicit, queryable shapes:

- `hstore` → expand into a long-form `key VARCHAR, value VARCHAR` Iceberg table, OR convert to JSON and store as `MAP<VARCHAR, VARCHAR>`.
- Range types → expand into `lower_bound TIMESTAMP, upper_bound TIMESTAMP, lower_inclusive BOOLEAN, upper_inclusive BOOLEAN`.
- `enum` (already VARCHAR in Trino) → no change needed.
- Multi-dim arrays → `unnest` into rows.

Once in Iceberg, the columns are first-class Trino types, predicates push down, and you no longer pay JDBC fetch latency per query. This fits the prod stack (Spark + Iceberg 1.5.2 + HMS + MinIO) and is the right pattern for any high-traffic analytical workload that today depends on `CONVERT_TO_VARCHAR` workarounds.

#### Quick recap — the six things to remember

1. **`postgresql.unsupported-type-handling=IGNORE` is the default**, and it silently drops columns Trino can't map — no error, just missing columns in `DESCRIBE`.
2. **JSONB is supported** — it maps natively to Trino `JSON`. If a query fails citing JSONB, the cause is either the focal column itself (e.g., a custom domain) or an adjacent column with a genuinely unsupported type — let the `DESCRIBE` diff decide.
3. **`CONVERT_TO_VARCHAR` is the schema-wide quick fix** for unsupported types; lose type safety but gain readability.
4. **`system.query()` is the per-query escape hatch** when you need Postgres-native operators (range `@>`, hstore `?`, full-text `@@`, etc.) that have no Trino equivalent.
5. **Caching is NOT the cause by default.** OSS Trino 467's PostgreSQL connector has `metadata.cache-ttl=0s` out of the box — schema is fetched fresh every query. Dismiss the "stale cache" hypothesis unless you've explicitly raised the TTL.
6. **`io.trino.plugin.jdbc=DEBUG` in `etc/log.properties` names the dropped column directly** in the coordinator log — faster than diffing `DESCRIBE` vs `\d` by hand. Revert after diagnosis (very verbose).

### 2.3 Why a read replica, not the OLTP primary

**This is the single most important operational rule.** Pointing Trino at your application's primary Postgres is asking for an outage. A single analytical join over a few million rows can:

- Hold long-running Postgres transactions, blocking VACUUM and bloating the table.
- Saturate connection slots — OSS Trino 467 has no JDBC connection pool, so every running query opens fresh Postgres connection(s) for the duration of that query. **JDBC connection model**: the PostgreSQL connector creates **one split per non-partitioned table scan**. One split = one worker task = **one JDBC connection**. This means a single federation query scanning one non-partitioned Postgres table opens **1 JDBC connection** (not one per worker). Connections to Postgres scale primarily with **concurrent queries × average splits per query** — NOT with worker count. Worker count multiplies connections only in unusual cases: (a) the query joins multiple Postgres tables, (b) Postgres-side table partitioning (the `partition-column` property — **Starburst Enterprise only, NOT available in OSS Trino 467**; see Section 4.4) is configured so Trino opens N parallel range-scan connections, or (c) a custom split strategy is used. **Capacity planning formula**: `peak_postgres_connections ≈ max_concurrent_federation_queries × avg_postgres_tables_per_query × avg_splits_per_table`. For typical single-table federation with a PgBouncer ceiling of 50, you can support roughly 50 concurrent federation queries (each reading one Postgres table) before saturating the pool. The mitigation when you DO push past the ceiling is **PgBouncer + Postgres role-level CONNECTION LIMIT + Trino resource groups** (see Section 8.2), NOT a Trino-side pool property — that property does not exist in OSS Trino 467.
- Cause replica lag (if you're using sync replication) or hot CPU contention.

Always stand up a dedicated **read replica** (logical or streaming replica is fine) for Trino, and ideally for any external analytical traffic. Set `statement_timeout` aggressively on that replica (e.g., 5 minutes) so a runaway Trino query doesn't run forever.

### 2.4 JDBC URL parameters — the real catalog-level performance levers

When someone asks "is there something we can set in the Trino catalog properties file to make the Postgres side faster?", the answer is mostly **"yes, but through the JDBC URL — not through `postgresql.*` properties."**

OSS Trino 467's PostgreSQL connector does **not** expose properties like `postgresql.fetch-size`, `postgresql.connection-timeout`, or `postgresql.socket-timeout` as separate catalog properties. They simply don't exist — adding them **may cause catalog startup failure or be ignored depending on the connector version — verify by checking Trino coordinator logs after catalog reload** (same trap as the bogus `connection-pool.*` properties in Section 0). The way you tune these on OSS Trino 467 is by appending **query parameters to the `connection-url` JDBC string**, which are interpreted by the underlying PostgreSQL JDBC driver.

The two parameters that matter most for federation performance:

```properties
# In etc/catalog/app_pg.properties
# All three parameters combined (and prepareThreshold=0 if going through PgBouncer):
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?\
defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10&prepareThreshold=0
```

| JDBC URL parameter | What it does | Typical setting for federation | Why it matters |
|---|---|---|---|
| `defaultRowFetchSize` | How many rows the JDBC driver fetches per network round-trip from Postgres to Trino workers. | `1000`–`5000` | **Trino's internal BaseJdbcClient already sets a default fetchSize of 1000 on JDBC statements**, so you may not see a dramatic improvement from adding this to the URL on a stock Trino install. However, setting it explicitly (a) documents intent, (b) guards against driver-level edge cases where the internal default is not applied (e.g., with certain PgBouncer configurations), and (c) allows you to raise the value to 5000+ for very wide rows. Do NOT expect a "one row at a time → 1000 rows" order-of-magnitude improvement from adding this URL parameter alone — if Trino is already fetching 1000 rows internally, the effect on throughput is minor. The bigger throughput levers are predicate pushdown (reduce total rows returned) and read replica placement (reduce network RTT). |
| `socketTimeout` | Per-socket-read timeout in **seconds**. After this many seconds with no data from Postgres, the JDBC read fails. | `60` (1 min) | Belt-and-suspenders alongside Postgres `statement_timeout` and Trino `query.max-execution-time`. Without `socketTimeout`, a hung Postgres backend (network blip, replication stall) can leave a Trino worker blocked forever on a socket read. |
| `connectTimeout` | Initial TCP-connect timeout in **seconds** (how long to wait when opening a new connection). | `10` | Fail-fast when PgBouncer or Postgres is down rather than letting Trino workers stack up blocked connection attempts. |
| `prepareThreshold` | Number of executions before the driver switches to a server-side prepared statement. **Set to `0` when going through PgBouncer in transaction pooling mode** (see 8.2A); leave at default otherwise. | `0` (with PgBouncer) | Prevents the "prepared statement does not exist" failure mode in PgBouncer transaction-pooling. |

> **PgBouncer ≥ 1.21 caveat**: If `max_prepared_statements > 0` is set in `pgbouncer.ini`, PgBouncer handles server-side prepared statements natively — `prepareThreshold=0` becomes **optional** (you can leave the JDBC driver at its default of `5`). For all PgBouncer versions prior to 1.21 — and for PgBouncer ≥ 1.21 with `max_prepared_statements = 0` (the default — it must be explicitly opted into) — `prepareThreshold=0` is **required**. See Section 8.2A for the full version-matrix and how to verify your live PgBouncer config.

> **Explicit note for anyone hunting for "fetch-size" / "socket-timeout" / "connection-timeout" as Trino catalog properties:** **They do not exist as separate catalog properties on OSS Trino 467's PostgreSQL connector.** You will not find `postgresql.fetch-size`, `postgresql.connection-timeout`, or `postgresql.socket-timeout` documented because they aren't implemented. The way to set them is via the `connection-url` JDBC URL parameters listed above (`defaultRowFetchSize`, `socketTimeout`, `connectTimeout`). The same applies to other JDBC connectors — when in doubt, check the **PostgreSQL JDBC driver docs** for the parameter name, not the Trino docs.

> **Aside — the `fetchsize` JDBC URL parameter (alias / lower-level cousin of `defaultRowFetchSize`):** `fetchsize=N` controls how many rows the PostgreSQL JDBC driver fetches from the server per network roundtrip (default varies by driver; pgjdbc default is `0` = **fetch the entire result set at once into client memory**). Setting `fetchsize=1000` or `fetchsize=10000` can improve memory stability for large result sets by **streaming rows in batches instead of buffering the entire result** on the Trino worker JVM heap. Add it to the JDBC URL:
>
> ```properties
> connection-url=jdbc:postgresql://host:5432/db?fetchsize=10000&prepareThreshold=0
> ```
>
> **Note**: raising `fetchsize` does **NOT** improve the single-split parallelism ceiling (see Section 2.3 — the PostgreSQL connector still issues one split = one JDBC connection per non-partitioned scan) — it only controls how data flows *within* that one connection. For throughput improvements that DO break the single-split ceiling, you need Postgres-side table partitioning + the Starburst Enterprise `partition-column` property (not available in OSS Trino 467), or predicate pushdown to reduce total rows scanned. Use `fetchsize` to **prevent OOM on large scans**, not to multiply parallelism. On modern pgjdbc, `defaultRowFetchSize` is the URL parameter most commonly cited — `fetchsize` is the older/equivalent name that appears in many code examples; either works.

The JDBC URL parameter list is documented by the PostgreSQL JDBC driver: [jdbc.postgresql.org/documentation/use](https://jdbc.postgresql.org/documentation/use/). Anything in that list can be appended to `connection-url`.

### 2.5 SSL/TLS for the PostgreSQL connector

> **This section exists because "how do I make the Trino-to-Postgres connection encrypted?" is one of the first questions security review asks. The answer is: the Trino PostgreSQL connector does NOT have separate `postgresql.ssl.*` catalog properties — you configure SSL via JDBC URL parameters on `connection-url`, the same way you configure `defaultRowFetchSize` / `socketTimeout` in Section 2.4.** Verified against [trino.io/docs/current/connector/postgresql.html](https://trino.io/docs/current/connector/postgresql.html), which directs you to the PostgreSQL JDBC driver's SSL parameter docs.

#### Minimal SSL — encrypt the wire, do NOT verify the server's certificate

```properties
# etc/catalog/app_pg.properties
connection-url=jdbc:postgresql://replica:5432/appdb?ssl=true&sslmode=require
```

- `sslmode=require`: encrypts the TCP connection but does **NOT** verify the server's certificate against any CA. Protects against passive eavesdropping, but vulnerable to **MITM** (an attacker presenting a self-signed cert will succeed). Use only for short-term unblock or strictly-trusted internal networks.

#### Production SSL — full certificate verification (what security review actually wants)

```properties
connection-url=jdbc:postgresql://replica:5432/appdb?ssl=true&sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt
```

- `sslmode=verify-full`: encrypts the connection AND verifies the server certificate's chain against the CA AND verifies the certificate's CN/SAN matches the hostname in the JDBC URL. **This is the production-correct mode.**
- `sslrootcert`: filesystem path to the CA certificate (PEM format is fine) that signed the Postgres server's cert. Must be present and readable on **every Trino pod** — coordinator and all workers — at the path you specify.

Intermediate modes you may see in docs (`verify-ca` — verify chain but not hostname; `prefer` — try SSL then fall back to plaintext) exist but are rarely the right answer: `verify-ca` is hostname-blind (vulnerable to a cert issued for a different host by the same CA), and `prefer` silently allows plaintext fallback, which defeats the point. Use `verify-full` in production.

#### Complete example — all recommended JDBC URL parameters together

```properties
connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?ssl=true&sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10&prepareThreshold=0
```

This combines SSL (`ssl=true&sslmode=verify-full&sslrootcert=...`), the federation-throughput parameters from Section 2.4 (`defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10`), and the PgBouncer-transaction-pooling fix from Section 8.2A (`prepareThreshold=0`). This is the typical production catalog `connection-url` on this stack.

#### Mounting the CA cert in Kubernetes (on-prem k8s stack)

The CA cert file must be present on every Trino pod at the path the JDBC URL references. The clean way is a Kubernetes Secret mounted as a file:

```bash
# Create a Secret from your CA certificate file (in the trino namespace)
kubectl create secret generic postgres-ca-cert \
  --from-file=ca.crt=/path/to/your/ca.crt \
  --namespace trino
```

```yaml
# In the Trino coordinator AND worker pod specs (both need it — workers do the actual JDBC reads):
spec:
  containers:
    - name: trino
      volumeMounts:
        - name: postgres-ca-cert
          mountPath: /etc/trino/certs
          readOnly: true
  volumes:
    - name: postgres-ca-cert
      secret:
        secretName: postgres-ca-cert
```

After mounting, `/etc/trino/certs/ca.crt` is readable from inside every Trino pod, and the `sslrootcert=/etc/trino/certs/ca.crt` JDBC URL parameter resolves correctly. **Forgetting to mount on the workers (only mounting on the coordinator) is a common mistake** — the coordinator plans the query but workers execute the JDBC reads, so workers need the cert too.

#### Verifying SSL is actually active (on the Postgres replica)

After deploying, run a Trino query against the catalog to force a connection, then on the Postgres replica:

```sql
SELECT ssl, version, cipher
FROM pg_stat_ssl
WHERE pid = pg_backend_pid();
-- ssl = t confirms the connection is encrypted.
-- For a Trino-originated session, run this AS Trino (in pg_stat_activity find the Trino pid first, then join):

SELECT a.usename, a.application_name, s.ssl, s.version, s.cipher
FROM pg_stat_activity a
JOIN pg_stat_ssl s ON a.pid = s.pid
WHERE a.usename = 'trino_reader';
```

If `ssl = f` (false) for `trino_reader` rows, the Trino-to-Postgres connection is plaintext despite your config — re-check the catalog file, the JDBC URL, and that the cert is actually mounted on the workers.

#### Certificate format note — pgjdbc client certs require PKCS-12, not PEM

If your security team requires **mutual TLS** (Postgres also verifies a client certificate presented by Trino), the relevant JDBC URL parameters are `sslcert` (client cert) and `sslkey` (client key). **The PostgreSQL JDBC driver (pgjdbc) requires client certificates in PKCS-12 format**, not PEM — this trips people up because the `sslrootcert` (CA cert, server-verification only) CAN be PEM. If your security team issues PEM client cert + key, convert with:

```bash
openssl pkcs12 -export \
  -out client.p12 \
  -inkey client.key \
  -in client.crt \
  -CAfile ca.crt
```

Then reference `sslcert=/etc/trino/certs/client.p12&sslkey=/etc/trino/certs/client.p12` in the JDBC URL. For server-side TLS only (which is what most production setups use — Trino authenticates with username/password, server cert verification only), you don't need this.

#### Quick recap

| What you want | JDBC URL parameter(s) | Notes |
|---|---|---|
| Encrypt only, no cert verification | `ssl=true&sslmode=require` | Vulnerable to MITM. Stopgap only. |
| Encrypt + verify server cert against CA + verify hostname (production) | `ssl=true&sslmode=verify-full&sslrootcert=/path/to/ca.crt` | The recommended production posture. CA cert must be mounted on every Trino pod. |
| Mutual TLS (server also verifies client) | Add `sslcert=...&sslkey=...` (PKCS-12 only) | Convert PEM client certs to PKCS-12 first. Rare in practice. |

### 2.6 Metadata cache and schema refresh — what to do after a Postgres schema change

> **This section exists because a common mistake is to claim "Trino's PostgreSQL connector has no schema cache." It does — it is just OFF by default. Many production clusters turn it ON, and at that point a Postgres schema change (column rename, ADD/DROP COLUMN) requires explicit cache invalidation.** Always check what `metadata.cache-ttl` is set to before answering "why is Trino still seeing the old schema?"

#### Catalog properties for schema metadata caching

OSS Trino 467's PostgreSQL connector has **two catalog properties** that control how it caches schema metadata (table list, column list, column types) from Postgres:

```properties
# In etc/catalog/app_pg.properties

# How long Trino caches schema metadata from Postgres.
# Default: 0s (caching disabled — every query asks Postgres for fresh metadata).
# Production-tuned values: 60s–300s, to reduce repeated catalog-metadata
# queries against the Postgres replica (these add up at high query volume).
metadata.cache-ttl=60s

# Negative caching — also cache "table not found" / "schema not found" responses
# for the same TTL. Without this, every query referencing a non-existent table
# still round-trips to Postgres. Default: false ("table not found" results are
# NOT cached by default). Recommend: true when cache-ttl > 0.
metadata.cache-missing=true  # default false
```

**Why enable `metadata.cache-missing`**: When `metadata.cache-missing=true`, Trino also caches **negative** lookup results (i.e., "table not found" responses). This prevents repeated `information_schema` round-trips to Postgres for tables that don't exist — useful when your application code probes for optional tables by name (e.g., feature-flagged tables, tenant-specific tables that may or may not be provisioned, BI tools that auto-discover schemas and try every name). Without it, every probe of a non-existent table re-hits Postgres for the same negative answer, which is wasteful at high QPS. **Caveat**: if you create a new table in Postgres while this is enabled, Trino won't see it until the cache TTL expires or you call `flush_metadata_cache()` — the same flush-or-wait rule that applies to positive metadata entries also applies to negative ones.

Documented at [trino.io/docs/current/connector/postgresql.html](https://trino.io/docs/current/connector/postgresql.html) under "General configuration properties" — these are real properties on OSS Trino 467, not Starburst-only.

#### Per-domain metadata cache sub-TTLs

Finer-grained control is available via per-domain sub-TTLs (all default to `metadata.cache-ttl` if not set individually):

- `metadata.schemas.cache-ttl` — TTL for schema (database) list cache
- `metadata.tables.cache-ttl` — TTL for table list and column definitions cache
- `metadata.statistics.cache-ttl` — TTL for table statistics (row counts, column NDVs) cache

**Typical pattern**: set `metadata.tables.cache-ttl=60s` (schema changes are infrequent) and `metadata.statistics.cache-ttl=300s` (statistics are more stable). This reduces metadata-query load on the Postgres replica while keeping schema changes visible quickly.

#### `metadata.cache-maximum-size`

`metadata.cache-maximum-size` (default: 10000) — maximum number of metadata entries cached per catalog. For very large databases (thousands of tables), this limit may cause cache churn when many distinct tables are queried. Raise it if you observe frequent metadata cache misses in a large-catalog environment.

> **CRITICAL — `metadata.cache-ttl` itself is NOT hot-loadable. Do not confuse "flushing the cache" with "changing the TTL".** These are two distinct operations:
>
> | Operation | What it does | Reload requirement |
> |---|---|---|
> | **`CALL <catalog>.system.flush_metadata_cache()`** (runtime) | Invalidates the in-memory metadata cache **immediately**. The very next query repopulates the cache from Postgres. | **No restart, no reload.** Hot operation. Run from any Trino client. |
> | **Changing the `metadata.cache-ttl` value** in the catalog properties file (e.g., editing `app_pg.properties` from `60s` to `300s`) | Changes the duration that future cache entries live for. | **Requires a catalog reload.** In **static catalog mode** (`catalog.management=static`, the default) this means rolling the coordinator + workers so the new properties file is re-read. In **dynamic catalog mode** (`catalog.management=dynamic`, see Section 2.8) you must `DROP CATALOG` + `CREATE CATALOG` with the new TTL value in the WITH clause — there is no `ALTER CATALOG` and `flush_metadata_cache` does not pick up properties-file changes. |
>
> Engineers commonly assume that editing the properties file and running `flush_metadata_cache` is enough to change the TTL. **It is not.** `flush_metadata_cache` clears existing cached entries but does NOT re-read the properties file — the catalog continues to use the TTL value it had at load time. The TTL change is only picked up by a full catalog reload (restart or DROP+CREATE). Plan the change accordingly.

#### When does schema caching actually matter?

| `metadata.cache-ttl` value | Behavior after a Postgres `ALTER TABLE ... RENAME COLUMN` |
|---|---|
| `0s` (default) | Trino sees the new schema **on the very next query**. No action needed. |
| `60s` | Trino continues serving the **old schema for up to 60 seconds**. Queries referencing the new column name fail with "column not found"; queries referencing the old column name may succeed at the Trino planner layer but **fail at the Postgres layer** when Trino's pushed-down SQL hits the renamed column. Confusing intermittent errors during the TTL window. |
| `300s` | Same as above but a 5-minute window. |

The same applies to `ADD COLUMN` (the new column is invisible to Trino until the cache expires) and `DROP COLUMN` (Trino keeps trying to project a column Postgres no longer has).

#### Force an immediate metadata refresh — `system.flush_metadata_cache()`

When the cache TTL is non-zero and you have just performed a Postgres schema change, you do **not** have to wait for the TTL to elapse or restart the cluster. OSS Trino 467 ships a system procedure (added in Trino 369, present in every release since) that invalidates the metadata cache on demand.

> **CRITICAL — `flush_metadata_cache` on the PostgreSQL connector is PARAMETERLESS.** Named parameters like `schema_name => 'public'` and `table_name => 'accounts'` **do NOT exist** on the PostgreSQL (or MySQL, SQL Server, Oracle) connector — they only work on the **Hive** and **Delta Lake** connectors. Trying to call the parameterless procedure with named parameters fails with `Procedure should only be invoked with named arguments` or `line X:Y: Procedure not registered`. To flush a single table on PostgreSQL, you scope via `USE <catalog>.<schema>` first, then call the parameterless form. Source: [trino.io/docs/current/connector/postgresql.html](https://trino.io/docs/current/connector/postgresql.html) (section "PostgreSQL connector — Procedures").

```sql
-- CORRECT for PostgreSQL connector (parameterless) — flush the entire catalog cache:
CALL app_pg.system.flush_metadata_cache();

-- To narrow the flush to a single schema's tables on PostgreSQL, change session scope
-- with USE first, then call the parameterless procedure. (Trino's PostgreSQL connector
-- still flushes the whole catalog cache; the USE statement is for session ergonomics —
-- subsequent unqualified table references resolve to that schema.)
USE app_pg.public;
CALL system.flush_metadata_cache();

-- WRONG — named params only work on Hive/Delta connectors, NOT on PostgreSQL/MySQL/SQL Server/Oracle:
-- CALL app_pg.system.flush_metadata_cache(schema_name => 'public', table_name => 'accounts');
-- ^ This fails on PostgreSQL with "Procedure should only be invoked with named arguments"
--   or "Procedure not registered". Do NOT copy this form from Hive/Delta examples.
```

This is the documented, supported way to react to an upstream schema change. **No pod restart is needed.** Run the procedure once on any coordinator; the cache invalidation is cluster-wide for that catalog.

> **The `system` schema here is the catalog's connector-provided system schema** (`app_pg.system.*`), not the cluster-wide `system` catalog. Every JDBC connector exposes its own `flush_metadata_cache` under its catalog's `system` schema. Use the catalog name you actually configured (`app_pg` here, whatever yours is named).

##### Connector compatibility matrix — `flush_metadata_cache` signature differs per connector

This is the table to bookmark. The procedure name is the same across connectors, but **the parameter signature is NOT** — and that mismatch is the cause of most "I copied a snippet from a blog post and it doesn't work" reports.

| Connector | `flush_metadata_cache` signature | Example |
|---|---|---|
| **Hive** | `(schema_name, table_name, partition_columns, partition_values)` — **named params** | `CALL hive.system.flush_metadata_cache(schema_name => 'sales', table_name => 'orders');` |
| **Delta Lake** | `(schema_name, table_name)` — **named params** | `CALL delta.system.flush_metadata_cache(schema_name => 'sales', table_name => 'orders');` |
| **PostgreSQL / MySQL / SQL Server / Oracle** (JDBC connectors) | **parameterless** — scope via `USE <catalog>.<schema>` if you want session-level narrowing | `CALL app_pg.system.flush_metadata_cache();` |
| **Iceberg** | Iceberg does NOT expose `flush_metadata_cache` — the Iceberg connector uses a metadata-file pointer (no in-engine cache to flush). Schema changes are picked up automatically on the next commit. | (N/A) |

**Rule of thumb:** if you are on a JDBC connector (PostgreSQL, MySQL, SQL Server, Oracle), the procedure takes **no parameters**. If you are on Hive or Delta Lake, you use named parameters. Confusing these is the most common "invented syntax" failure mode — it is the third such regression in this guide's history (after fake `connection-pool.*` properties and fake `ALTER CATALOG` syntax), and the resource has been corrected accordingly.

#### Checklist — Postgres schema change that affects Trino queries

When a teammate runs `ALTER TABLE` on Postgres and Trino federation users start complaining about errors:

1. **Check `metadata.cache-ttl`** in `etc/catalog/app_pg.properties` (or whatever your catalog file is called). If it's `0s` or absent, schema caching is OFF and the issue is something else — go look at the actual SQL the user wrote vs. the new column names.
2. **If `metadata.cache-ttl > 0`**: run the **parameterless** flush from any Trino client. The next query will pick up the new schema immediately:
   ```sql
   CALL app_pg.system.flush_metadata_cache();
   -- Do NOT pass schema_name / table_name named params on the PostgreSQL connector — those exist
   -- only on Hive/Delta and will fail here. See the connector compatibility matrix above.
   ```
3. **Update any Trino views** that reference the old column name: `CREATE OR REPLACE VIEW analytics.foo AS SELECT new_name AS old_name, ... FROM app_pg.public.accounts;` if you need to preserve a stable downstream contract, or just update the view to use the new name. See Section 2.7 below for the full view-lifecycle runbook (find affected views, update them, choose SECURITY mode).
4. **Coordinate with teams that have saved queries / dashboards** referencing the old column name — flushing the Trino cache does not fix their SQL, it only makes Trino aware of the new Postgres reality.
5. **Verify**: `DESCRIBE app_pg.public.accounts;` from a Trino client should now show the new column name.

#### Runbook — Schema migrations on a live federated Postgres source

This is the step-by-step operational playbook for the common case: your application team is about to run a Postgres DDL (ALTER TABLE, ADD COLUMN, DROP COLUMN, RENAME COLUMN, CREATE TABLE) on the same Postgres database that Trino federates against via `app_pg`. The goal is **zero stale-schema errors in Trino** during and after the migration.

1. **Default behavior (`metadata.cache-ttl=0s`)**: new columns/tables appear in Trino on the next query **automatically — no flush needed**. Just run the Postgres migration and proceed. Trino issues a fresh `information_schema` lookup for every query, so the next federation query sees the post-DDL schema immediately. This is the simplest mode and the right default if your Postgres metadata-query load is acceptable.

2. **If caching is enabled (`metadata.cache-ttl=60s` or similar)**: After running your Postgres DDL (`ALTER TABLE`, `ADD COLUMN`, `DROP COLUMN`, etc.), immediately run:

   ```sql
   CALL app_pg.system.flush_metadata_cache();
   ```

   OR the USE-scoped form (both are valid and equivalent on PostgreSQL — the connector flushes the entire catalog cache either way, the `USE` is purely for session ergonomics):

   ```sql
   USE app_pg.public;
   CALL system.flush_metadata_cache();
   ```

   Either form works. Pick whichever fits your migration script style. Both are parameterless on the PostgreSQL connector (see the connector compatibility matrix above — named params are Hive/Delta only).

3. **Verify the schema change is visible** from a Trino client:

   ```sql
   DESCRIBE app_pg.public.<table_name>;
   ```

   The new column should appear in the output. If it does not, the cache flush did not propagate — check that you ran the flush against the correct catalog name (`app_pg` here; substitute yours) and that no second Trino cluster is also serving traffic with a stale cache.

4. **Important caveat — flushing the cache does NOT pick up changes to `metadata.cache-ttl` itself.** `flush_metadata_cache()` clears the current cached entries. It does **NOT** re-read the `metadata.cache-ttl` value from the properties file. If you change the TTL value in `etc/catalog/app_pg.properties` (e.g., from `60s` to `300s`), that change requires a **full catalog reload** — coordinator + worker restart in static catalog mode for Trino 467 — flushing the cache does not pick up new property values. See the "CRITICAL — `metadata.cache-ttl` itself is NOT hot-loadable" callout above for the full operation-vs-reload table. This is a distinct operation from the runtime flush.

5. **Multi-node note — where the cache actually lives**: JDBC metadata caching (column lists, table existence, schema lookups) is **coordinator-side** — the coordinator resolves these during query planning, before splits are dispatched to workers. Workers do not hold a separate metadata cache for JDBC catalogs. In a clustered Trino deployment with **multiple coordinators** (HA setup), `flush_metadata_cache()` invalidates the cache on the coordinator where it ran; if you operate multiple independent coordinators they each have their own cache and must each be flushed (or routed through a single client). For the single-coordinator deployments that are typical on this stack, a single `flush_metadata_cache()` call is cluster-wide for that catalog — run it once from any Trino client and the next query plan reads fresh metadata. This is one of the few cluster-wide-effect procedures in Trino; do not confuse it with session-scoped settings.

6. **Runbook integration tip**: Add `CALL <catalog>.system.flush_metadata_cache();` as the **last step of your schema migration deploy script** (the same script that runs your Postgres DDL — Flyway/Liquibase/Atlas postdeploy hook, or whatever your team uses). This way future DDL changes are automatically visible in Trino without manual intervention, and you eliminate an entire class of "I changed Postgres but Trino still sees the old schema" tickets. The cost of a no-op flush (when nothing changed) is negligible — it is a cheap in-memory cache invalidation, not a re-fetch — so it is safe to run on every deploy.

#### Trade-off when choosing `metadata.cache-ttl`

| Value | Pros | Cons |
|---|---|---|
| `0s` (default) | Always-fresh schema; no flush ever needed. | Every Trino query that touches a Postgres table issues catalog-metadata queries to Postgres (small but non-zero load). At very high QPS this adds up on the replica. |
| `60s`–`300s` (typical prod) | Drastically reduces Postgres metadata-query load; speeds up query planning when many short queries hit the same tables. | After Postgres schema changes, you must run `flush_metadata_cache()` or wait for the TTL. Schema-evolving systems (frequent migrations) feel the pain. |

For a stable SaaS Postgres schema with infrequent migrations, `metadata.cache-ttl=60s` + `metadata.cache-missing=true` (default `false`) is the standard production setting. For a Postgres database under active schema evolution, leave `metadata.cache-ttl=0s` and accept the metadata query load.

#### The two failure modes after a Postgres schema change — silent vs hard error (do NOT conflate them)

When `metadata.cache-ttl > 0` and someone changes the Postgres schema, **two completely different things can happen** depending on the type of change. These are NOT the same failure mode and they require **different monitoring strategies**. Confusing them is the most common debugging mistake on a stale cache.

##### Mode 1 — GENUINELY SILENT: `ADD COLUMN` + cached `SELECT *` view

**The setup:**
- A Trino view is defined as `CREATE VIEW v AS SELECT * FROM app_pg.public.accounts;`
- Trino's metadata cache currently holds the OLD column list (let's say 5 columns: `id, name, plan_type, created_at, status`).
- Someone runs `ALTER TABLE accounts ADD COLUMN region VARCHAR(64);` on Postgres.
- The Trino cache still says 5 columns. Trino's query planner expands `SELECT *` into the **cached** 5-column projection.

**What happens at runtime:**
- Trino issues `SELECT id, name, plan_type, created_at, status FROM accounts` to Postgres (the cached column list — `region` is NOT in the SELECT list).
- Postgres happily returns those 5 columns. **No error. No warning. No log entry.** The new `region` column is invisible to every query going through this view.
- Downstream consumers (dashboards, reports, ML pipelines) silently lose the new column. Data analyses that depend on `region` produce wrong answers, and there is no signal anywhere that anything is wrong.

**This is the real silent-corruption risk.** No PSQLException. No Trino error. Just missing data, returned successfully.

**How to monitor for this:**
- **Cardinality anomaly detection** — track the column count of important views over time. A view that lost a column without a CREATE OR REPLACE deploy is suspicious.
- **NULL-rate alerts on downstream tables** — if `region` arrives via the view as missing entirely, downstream aggregations on `region` will show 100% NULL where they didn't before.
- **Schema-drift checks in CI** — compare the column list of the Postgres source table against the column list Trino sees (`information_schema.columns` on both sides) on a schedule; alert on drift.
- **Do NOT rely on error-rate alerts** — there are no errors to alert on in this mode.

**The fix:** flush the cache (`CALL app_pg.system.flush_metadata_cache();`), then re-deploy the view with `CREATE OR REPLACE VIEW v AS SELECT id, name, plan_type, region, created_at, status FROM ...;` — use an **explicit column list** to make the schema contract visible in code.

##### Mode 2 — HARD ERROR (not silent): `RENAME COLUMN` + view references old name

**The setup:**
- A Trino view is defined as `CREATE VIEW v AS SELECT plan_type, count(*) FROM app_pg.public.accounts GROUP BY plan_type;` — explicit reference to the old column name `plan_type`.
- Trino's metadata cache still has `plan_type` in its column list (cache says it exists).
- Someone runs `ALTER TABLE accounts RENAME COLUMN plan_type TO plan_tier;` on Postgres.
- The Trino cache is stale — it still says `plan_type` exists, so Trino's planner happily compiles the view. The query passes planning.

**What happens at runtime:**
- Trino sends the pushed-down SQL `SELECT plan_type, count(*) FROM accounts GROUP BY plan_type` to Postgres.
- Postgres receives a column reference to `plan_type` that no longer exists, and returns:
  ```
  ERROR: column "plan_type" does not exist
  ```
  This is a `PSQLException` from the Postgres JDBC driver.
- Trino's JDBC layer catches the PSQLException and **propagates it as a hard query failure** to the user. The Trino error surface shows the verbatim Postgres error string.
- **No NULLs are returned. No silent corruption. The query just fails outright every time, on every call, until the cache is flushed or the view is fixed.**

**How to monitor for this:**
- **Error-rate alerts on Trino queries** — a sudden spike in query failures naming a specific catalog/table is the signal. Alert on Trino `QueryFailedEvent` where `errorCode` indicates a JDBC source error.
- **Postgres slow-query / error logs** — look for `column "..." does not exist` errors originating from the `trino_reader` role.
- **Do NOT rely on NULL alerts** — there are no NULLs because there are no rows; the query fails before returning anything.

**The fix:** flush the cache AND fix the view definition in one operation (see the runbook in 2.8 below).

##### The distinction in one sentence

| Postgres DDL | Trino view shape | Result | What to monitor |
|---|---|---|---|
| `ADD COLUMN` | `SELECT *` view | **Silent** — new column invisible, no error | Cardinality / NULL-rate / schema-drift checks |
| `DROP COLUMN` | `SELECT *` view | **Silent** until the next plan refresh (then hard error) — old column appears in cached projection but Postgres rejects | Same as above, plus error monitoring |
| `RENAME COLUMN` | View references the OLD name explicitly | **Hard error** — `PSQLException: column "..." does not exist` | Query error-rate alerts |
| `RENAME COLUMN` | `SELECT *` view | **Hard error** — cached column list still includes old name → planner issues old name → Postgres rejects | Query error-rate alerts |
| `DROP COLUMN` | View references that column explicitly | **Hard error** at next query — Postgres rejects | Query error-rate alerts |

**The mental shortcut:** "silent" is the `ADD COLUMN` + `SELECT *` corner of the matrix — Trino's stale projection list omits a new column that nobody asked for explicitly, so nobody sees that it's missing. **Every other combination** (rename, drop, or any explicit reference to a missing/renamed column) is a hard error, not silent.

If a teammate says "stale metadata cache caused silent corruption," ask which corner of the matrix it was. If they say "rename" or "drop with explicit column reference," it is the hard-error mode — fix it with error-rate alerts, not NULL alerts.

### 2.7 View lifecycle runbook — keeping Trino views in sync with Postgres schema changes

> **When Postgres changes schema, the Trino views that join Postgres against Iceberg do NOT update themselves.** This runbook is the four-step procedure for re-syncing them. Run it any time you (or another team) is about to make a schema change on a Postgres table that has at least one Trino view referencing it. The runbook also doubles as a triage script when a federated view starts failing intermittently after a DDL push.

**How Trino stores views (the key to understanding schema-change behavior):**
Trino views store two things in the metastore at CREATE VIEW time: (1) the original SQL text, and (2) a **resolved column schema** — the explicit column list that `SELECT *` was expanded to at that moment. This resolved column list is **frozen**. Consequences:

- `SELECT *` in a view is expanded to an explicit column list once at CREATE time. Adding a column to the underlying Postgres table does NOT update the frozen list — the new column is invisible to existing views even with `metadata.cache-ttl=0s` (no caching at all).
- Flushing the metadata cache (`CALL system.flush_metadata_cache()`) makes Trino re-read Postgres's current column list for planning new queries — but it does **NOT** update a view's frozen resolved column schema. Flushing fixes hard errors on direct table queries; it does NOT fix silent data loss in SELECT * views.
- **Only `CREATE OR REPLACE VIEW` re-expands the column list.** This rewrites both the SQL text and the resolved column schema atomically in the metastore.

Practical rule: **flushing the cache is necessary for direct table queries after a schema change; rewriting the view is necessary for views.**

#### Step 1 — Find affected views (search Trino-native catalogs, NOT the JDBC catalog)

**IMPORTANT**: `<jdbc_catalog>.information_schema.views` (e.g., `app_pg.information_schema.views` or `billing_pg.information_schema.views`) returns **Postgres-side views** defined inside Postgres itself — it does NOT return Trino views that query Postgres tables. Trino views defined as `CREATE VIEW analytics.foo AS SELECT ... FROM app_pg.public.bar` live in the **analytics catalog's metastore** (Hive Metastore / HMS), so they appear in `analytics.information_schema.views`.

To find Trino views affected by a Postgres schema change, search your Trino-native catalogs (Iceberg/analytics catalogs):

```sql
-- Search Trino-native analytics catalogs (Hive/Iceberg), NOT the JDBC catalog
SELECT table_catalog, table_schema, table_name, view_definition
FROM analytics.information_schema.views
WHERE view_definition LIKE '%plan_type%'
   OR view_definition LIKE '%accounts%';

-- If you have multiple Trino-native catalogs, repeat for each:
SELECT table_catalog, table_schema, table_name, view_definition
FROM iceberg.information_schema.views
WHERE view_definition LIKE '%plan_type%';
```

Do NOT search `app_pg.information_schema.views` (or `billing_pg.information_schema.views`) for this purpose — you will get zero results (or only Postgres-side views) and incorrectly conclude no Trino views are affected.

Trino's `information_schema.views` is **per-catalog** — there is no global "find views referencing column X across all catalogs" query. You must run the lookup **once per Trino-native catalog** that might contain a view referencing the changed Postgres column.

> **Why this is per-catalog and how to extend it.** Trino's `information_schema` lives **inside** each catalog — there is no top-level `system.information_schema.views` that joins across catalogs. If you have N Trino-native catalogs (iceberg, analytics, hive, etc.), you need N queries (or a UNION ALL across them). For a one-time forensic search, just run them sequentially. For an ongoing automation, build a small script that iterates `SHOW CATALOGS`, filters out JDBC catalogs (those won't hold Trino views), and runs the same query against each.

The `view_definition` column contains the SQL text of the view, exactly as it was supplied to `CREATE VIEW`. Use `LIKE '%column_name%'` to find every reference. This is a substring match — false positives are possible (a comment containing the column name, a column with a coincidentally similar name) so always read the `view_definition` to confirm before changing anything.

#### Step 2 — Flush the metadata cache (parameterless on PostgreSQL connector)

```sql
-- PostgreSQL connector — parameterless, scoped to the entire catalog.
CALL app_pg.system.flush_metadata_cache();

-- If you only want to act inside a single schema for ergonomics, use USE first:
USE app_pg.public;
CALL system.flush_metadata_cache();

-- Do NOT use named parameters here — see Section 2.6 connector compatibility matrix.
```

After the flush, the next query against `app_pg.public.accounts` (or any other table in that catalog) reads fresh metadata from Postgres. The flush is cluster-wide — run it once on any Trino client connected to any coordinator.

**Post-flush verification — confirm Trino sees the new Postgres schema:**

```sql
-- Verify Trino now sees the post-change column list on the base table:
SHOW COLUMNS FROM app_pg.public.accounts;
-- (or, for the example column rename above)
SHOW COLUMNS FROM app_pg.public.invoices;
```

If `SHOW COLUMNS` still shows the old schema after the flush, something is wrong — the flush did not execute on the coordinator your client is connected to, or the catalog name is wrong. **Re-run the flush before continuing to Step 3.** Note that `SHOW COLUMNS` on the base table confirms direct-table queries are fixed; it does **not** confirm any view is fixed — views have their own frozen column schema (see the anchor paragraph above) and only `CREATE OR REPLACE VIEW` in Step 3 will fix those.

#### Step 3 — Update the view definition with `CREATE OR REPLACE VIEW`

`CREATE OR REPLACE VIEW` is the right tool here for two reasons: (a) it atomically replaces the view definition (no `DROP VIEW` + `CREATE VIEW` race where the view briefly doesn't exist), and (b) **it preserves all GRANTS on the view** — anyone who had `SELECT` on the old view still has `SELECT` on the new one, no re-grant required.

```sql
CREATE OR REPLACE VIEW analytics.events_with_accounts AS
SELECT
  e.event_id,
  e.event_time,
  e.user_id,
  a.account_id,
  a.account_name,
  a.plan_tier  -- renamed from plan_type
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.user_id = a.account_id;
```

**Use an EXPLICIT column list, not `SELECT *`.** The `SELECT *` form is the source of Mode 1 silent corruption (see the "two failure modes" subsection in 2.6 above) — switching to explicit columns makes the contract visible in code review and prevents future ADD COLUMN events from silently changing the view's output shape.

> **Note on Trino view storage.** Trino views are stored as **SQL text + a resolved column schema** in the metastore. `CREATE OR REPLACE VIEW` rewrites both atomically. There is no `ALTER VIEW ... RENAME COLUMN` — the only way to evolve a view definition is with CREATE OR REPLACE.

#### Step 4 — Choose the view's SECURITY mode deliberately

Trino views support two security modes that affect whose grants are used to read the **base tables** referenced inside the view body:

- **`SECURITY DEFINER`** (Trino's **default** if you don't specify) — the view body executes with the **view owner's grants**. The caller only needs `SELECT` on the view itself, NOT on the underlying base tables.
- **`SECURITY INVOKER`** — the view body executes with the **calling user's grants**. The caller must have `SELECT` on every base table the view touches; otherwise the query fails with `Access Denied`.

For a cross-catalog view that joins Postgres + Iceberg (the federation pattern), the implications are:

| Aspect | `SECURITY DEFINER` (default) | `SECURITY INVOKER` |
|---|---|---|
| Whose grants read `app_pg.public.accounts` and `iceberg.analytics.events`? | The view owner's. | The querying analyst's. |
| Analyst needs direct base-table SELECT? | NO — the view's WHERE clause and column list are the only thing they see. | YES — must have SELECT on both base tables in both catalogs (often a big ask for the federated Postgres side). |
| What happens when a sensitive new column is added to `accounts`? | If the view uses `SELECT *`, the new column **becomes accessible to all view grantees automatically** (the owner can read it, so the view body can read it, so the view exposes it). This is a leak vector. | The new column is only readable if the analyst also has direct SELECT on the column. OPA / column-level grants can gate it. |
| When to use? | Tenant-isolation pattern where analysts have NO direct base-table grants (see resource 05) — the view is the only path to the data. | Trusted analysts who already have base-table grants and the view is a convenience join, OR when you want OPA's row-filter / column-mask policies on the base table to apply equally to view queries. |

**The leak vector to internalize:** with `SECURITY DEFINER` + `SELECT *`, every column added to `accounts` becomes accessible to **every analyst with SELECT on the view**, automatically, without any ALTER VIEW or re-grant. If `accounts` gets a new `ssn` or `payment_token` column on the Postgres side, that column is immediately visible through the view. **Two defenses:**

1. **ALWAYS use an explicit column list in the view body** (`SELECT account_id, account_name, plan_tier`, never `SELECT *`). New columns added to the base table are NOT exposed unless you explicitly update the view.
2. **Use `SECURITY INVOKER` for cross-catalog views joining sensitive Postgres tables** when analysts have direct base-table grants and you want the underlying access controls (Postgres GRANTs, OPA column-mask) to apply.

```sql
-- Explicit SECURITY mode on view creation:
CREATE OR REPLACE VIEW analytics.events_with_accounts
SECURITY INVOKER  -- or SECURITY DEFINER (the default if omitted)
AS
SELECT
  e.event_id,
  e.event_time,
  e.user_id,
  a.account_id,
  a.account_name,
  a.plan_tier
FROM iceberg.analytics.events e
JOIN app_pg.public.accounts a ON e.user_id = a.account_id;
```

#### Step 5 — Audit the SECURITY mode of any existing view

> **Audit recipe — one command.** To check which SECURITY mode an existing view was created with, run `SHOW CREATE VIEW analytics.public.v_events_with_tenants;` — look for the `SECURITY DEFINER` or `SECURITY INVOKER` clause in the output. Trino prints the full view definition including the security mode and the OWNER. If the clause is missing from the output, that's `SECURITY DEFINER` (the default). This is the only reliable way to tell, after the fact, which mode a view actually uses — there is no separate `information_schema` column for it, so `SHOW CREATE VIEW` is the audit primitive you grep for in CI.

#### The two-check OPA call model for DEFINER views

> **CRITICAL — when a caller queries a SECURITY DEFINER view, Trino issues TWO distinct OPA calls, with TWO different identities in `input.context.identity`.** This is the model engineers most often get wrong. Understanding which call uses which identity is the difference between "my per-caller OPA row filter works" and "my per-caller OPA row filter never fires because OPA sees the view-owner identity instead of the caller."

The two OPA calls Trino sends, in order, for one SELECT against a DEFINER view:

1. **View-level check** — operation `SelectFromColumns` against the **view object**, with identity = **caller's identity**. This is where the caller's own per-principal row filters (if any are configured against the view object) fire.
2. **Base-table check(s)** — operation `SelectFromColumns` against **each underlying base table referenced inside the view body**, with identity = **view owner's identity** (because the view is DEFINER, base-table access runs as the owner). This is where row filters configured against the base table fire — but they fire under the **view owner's** principal, NOT the original caller's.

Concrete OPA request payloads — what your Rego policy actually sees:

```json
// Call 1 — view-level check, CALLER identity
// Fires per-caller row filters / column masks attached to the VIEW object.
{
  "action": {
    "operation": "SelectFromColumns",
    "resource": {
      "table": {
        "catalogName": "analytics",
        "schemaName": "public",
        "tableName": "v_events_with_tenants"
      },
      "columns": ["event_id", "occurred_at", "tenant_id", "tenant_name"]
    }
  },
  "context": {
    "identity": {"user": "acme--alice", "groups": []}
  }
}

// Call 2 — base-table check, VIEW OWNER identity (DEFINER)
// Fires base-table policy under the owner's principal — NOT the caller's.
{
  "action": {
    "operation": "SelectFromColumns",
    "resource": {
      "table": {
        "catalogName": "iceberg",
        "schemaName": "analytics",
        "tableName": "events"
      },
      "columns": ["event_id", "occurred_at", "tenant_id"]
    }
  },
  "context": {
    "identity": {"user": "svc-trino-views", "groups": ["view-owners"]}
  }
}
```

**The single most important consequence.** Per-caller row filters defined on the **base table** (e.g., `tenant_id = '<caller's tenant>'` derived from `input.context.identity.user`) **do NOT fire for the caller** under DEFINER — they fire for the **service principal** `svc-trino-views`, which is not bound to any tenant. The filter resolves to whatever the service principal would see (typically nothing tenant-specific), which is almost never what you want. This is the DEFINER + base-table-RLS anti-pattern, and it's the canonical "backdoor": every caller through the view sees every tenant's rows because the base-table RLS evaluated against the wrong identity.

#### The DEFINER-compatible per-caller RLS pattern — attach the row filter to the VIEW

> **The correct fix is NOT to switch to INVOKER. It is to attach the row filter to the VIEW object (not the base table).** Trino's `opa.policy.row-filters-uri` can attach a row filter to any table-like object, **including views**. The filter is evaluated during Call 1 above — under the **caller's** identity — and Trino injects the resulting WHERE clause before the view body expands. This gives you per-caller RLS without giving the caller any base-table grant, while keeping the view as DEFINER. It is the canonical pattern for the multi-tenant federation case.

Conceptual Rego shape — pseudocode, real policy lives in your external governance document per `prod_info.md`:

```rego
# In row_filters.rego — row filter attached to the VIEW object,
# evaluated as the CALLER identity (Call 1 above).
row_filters[{"expression": filter}] {
    input.action.resource.table.catalogName == "analytics"
    input.action.resource.table.schemaName == "public"
    input.action.resource.table.tableName == "v_events_with_tenants"
    tenant := split(input.context.identity.user, "--")[0]
    filter := sprintf("tenant_id = '%s'", [tenant])
}
```

What happens at query time, end-to-end, for `SELECT * FROM analytics.public.v_events_with_tenants` submitted by user `acme--alice`:

1. Trino sends Call 1 (view-level, caller identity = `acme--alice`). OPA's `row_filters` rule matches and returns `tenant_id = 'acme'`.
2. Trino rewrites the query as `SELECT * FROM analytics.public.v_events_with_tenants WHERE tenant_id = 'acme'`.
3. The view body is expanded (joining `iceberg.analytics.events` and `app_pg.public.accounts`). Because the view is DEFINER, Trino sends Call 2 (base-table check, identity = `svc-trino-views`) for each base table referenced. The base-table OPA rule simply checks that `svc-trino-views` has SELECT on each base table — no per-tenant logic needed there.
4. The query executes; the WHERE `tenant_id = 'acme'` predicate is pushed into the Iceberg scan and the federated Postgres join.

**Why this is the right shape.** The caller (`acme--alice`) never needs a base-table grant in OPA — only the service principal does. The per-tenant filter is enforced under the caller's identity (so it correctly resolves to the caller's tenant). The view stays DEFINER. The base-table policy stays simple (one rule: "is this principal `svc-trino-views`?"). Adding a tenant means adding a row to the OPA data bundle (Pattern 2 in resource 05), not creating a new view per tenant.

> **Scaling to hundreds of tenants — prefer OPA row-filter/column-mask endpoints over per-tenant `CREATE VIEW`.** The "one view per tenant" pattern (e.g., `v_events_acme`, `v_events_globex`, ...) does not scale: with 500 tenants you have 500 view objects to provision, maintain, and re-create on every schema change to the underlying tables. The scalable shape is **one shared view (or just the base tables) plus an OPA row-filter rule that derives the tenant filter from the caller's principal**. Trino's `opa.policy.row-filters-uri` (and its batched form `opa.policy.batch-row-filters-uri`, see section D2) is consulted on every SELECT; the Rego rule reads `input.context.identity.user`, looks up the tenant, and returns a `tenant_id = '<x>'` expression that Trino injects as a WHERE clause. Adding a new tenant is a single row in the OPA data bundle (or just a new JWT identity if tenant is encoded in the subject claim); no DDL, no view re-creation. Pair this with `opa.policy.batch-column-masking-uri` for per-tenant column visibility (e.g., hide PII columns from analyst tenants). The N-views pattern is fine at single-digit tenant counts; switch to OPA-managed row filters and column masks before you cross ~20 tenants.

**The wrong mental model to abandon:** "DEFINER and per-caller RLS are incompatible — you must switch to INVOKER for per-caller filters to work." That is **false**. DEFINER and per-caller RLS are compatible when the row filter is attached to the view (caller-identity check) instead of the base table (owner-identity check under DEFINER). INVOKER is the right answer when you want **all** of the base-table's own policies (column masks, base-table row filters, base-table allow/deny) to apply under the caller's identity — but that often means the caller needs base-table grants too. Pick the model based on whether the caller should have any base-table relationship at all; do not switch to INVOKER just to make per-caller RLS work.

> **`current_user` inside a SECURITY DEFINER view returns the INVOKER's identity (the person who called the view), not the view owner's.** This enables a useful pattern: OPA row-filter expressions on the underlying base tables can reference `current_user()` to enforce per-caller filtering even when the base-table OPA checks formally use the view owner's identity. Specifically, if the view owner's OPA policy allows `WHERE tenant_id = current_user()`, this condition is evaluated using the real invoker's principal — a clean way to achieve per-tenant row isolation through a DEFINER view without switching to INVOKER mode. This is a third valid shape alongside "attach the row filter to the view object" (the canonical pattern above) and "switch to INVOKER" — it lets you keep DEFINER semantics for grants while still resolving per-caller predicates at filter-evaluation time.

#### Cross-catalog view ownership — use a dedicated service principal

> **For cross-catalog views (joining Iceberg + Postgres, or any two catalogs), the view owner MUST be a fixed, dedicated service principal — not a per-tenant human user, and not a shared admin account that might rotate.** On the JWT + OPA + k8s stack, that means provisioning a dedicated JWT identity (e.g., `svc-trino-views`) issued by your auth service, with stable claims, and explicitly granted SELECT in the OPA policy on every catalog the view touches (here: both `iceberg.analytics.*` and `app_pg.public.*`).

Why this matters specifically for **cross-catalog** views:

- **Predictability of grants under DEFINER.** Under DEFINER, all base-table reads happen as the view owner. If a per-tenant human owns the view and that human is offboarded (leaves the company, role changes), the view starts failing at base-table access — for every caller, on every catalog, simultaneously. The blast radius is "every caller of every cross-catalog view that human happened to create."
- **OPA policy surface stays small.** With a dedicated `svc-trino-views` principal owning all cross-catalog views, the OPA policy needs exactly ONE rule per base table per catalog: "principal `svc-trino-views` is allowed SELECT here." You don't need to enumerate which human users happen to own which views.
- **Auditability.** Every base-table access from a DEFINER view shows up in OPA decision logs and `pg_stat_activity` as `svc-trino-views`. That makes "all federation traffic from views" trivially filterable in OPA's decision log (filter `input.context.identity.user = "svc-trino-views"`) and on the Postgres side (`SELECT ... FROM pg_stat_activity WHERE usename = 'svc-trino-views'`). If view ownership is spread across many per-tenant principals, you lose this single filter point.

**The provisioning checklist** for the service-principal owner, on this stack:

1. Mint a long-lived JWT identity at your auth service named (for example) `svc-trino-views`, with a stable `sub` claim. Do not issue this credential to humans; only the platform team's view-management tooling holds it.
2. In the OPA policy bundle, add explicit allow rules for `svc-trino-views` SELECT on every catalog the cross-catalog views will touch (`iceberg.*`, `app_pg.*`, etc.).
3. When creating cross-catalog views, authenticate to Trino with the `svc-trino-views` JWT before running `CREATE VIEW` — Trino records the current session principal as the view owner.
4. Verify with `SHOW CREATE VIEW <view>;` that the OWNER line shows `svc-trino-views`. If it shows any other principal, drop and recreate the view under the correct identity.
5. Add a monitoring rule: alert if any view in a cross-catalog schema has an OWNER other than `svc-trino-views`. This catches the case where someone created a "quick" view from their personal JWT and forgot.

**Do NOT** let per-tenant users or individual analysts own cross-catalog views. The behavior under DEFINER is unpredictable in the long run (a single grant change to one user's OPA rule can break every caller of that view), and the audit story collapses (you have to enumerate every possible owner to find "who did the federated read?").

#### Runbook summary — the five steps in order

1. **Find affected views** — query `<catalog>.information_schema.views` for each catalog (per-catalog scope).
2. **Flush the cache** — `CALL app_pg.system.flush_metadata_cache();` (parameterless on PostgreSQL).
3. **Update the view** — `CREATE OR REPLACE VIEW ... AS SELECT <explicit column list> FROM ...;` (preserves grants atomically; never use `SELECT *`).
4. **Confirm SECURITY mode** is appropriate for your trust model — DEFINER (default) for tenant isolation where analysts have no base-table access; INVOKER when analysts have base grants and you want underlying authz to apply.
5. **Audit with `SHOW CREATE VIEW`** — `SHOW CREATE VIEW <view>;` and verify (a) the SECURITY clause matches your trust model and (b) the OWNER is the dedicated `svc-trino-views` service principal (for cross-catalog views).

If you skip step 1, you may leave one or more stale views behind that fail intermittently. If you skip step 2, the new view definition resolves against the cached (old) column list at planning time. If you skip step 4, you may have introduced a leak vector (DEFINER + SELECT * + new sensitive column added later). If you skip step 5, you may have a view whose OWNER is an arbitrary per-tenant principal whose grants will silently break the view for all callers when that principal is offboarded.

### 2.8 Dynamic catalog management — add, remove, and update catalogs WITHOUT restarting Trino

> **This section exists because a common (and wrong) answer is "there is no hot-reload mechanism — you must restart the cluster to change a catalog." That was true on older Trino versions, but OSS Trino 467 has the `catalog.management=dynamic` feature (introduced in Trino 435, GA since) that allows runtime catalog CREATE/DROP via SQL. Use it. It is the correct answer for password rotation and adding new catalogs without downtime.**

> **Note**: Dynamic catalog management is marked **experimental** in Trino 467. The SQL syntax and property names may change in future releases. Evaluate against your upgrade cadence before depending on it in production.

#### Enabling dynamic catalog management

In `etc/config.properties` on the **Trino coordinator**:

```properties
catalog.management=dynamic
```

With this enabled, you can add/remove catalogs via SQL without restarting any pods. The default (`catalog.management=static`) requires catalog properties files on disk and a pod restart to pick up changes — that is the legacy behavior most blog posts describe.

> **`catalog.store` — where dynamic catalog state is persisted**: When `catalog.management=dynamic`, a companion property `catalog.store` controls WHERE Trino persists catalog definitions between restarts:
>
> | `catalog.store` value | What it does | Use when |
> |---|---|---|
> | `file` (default for dynamic mode) | Writes catalog definitions to `etc/catalog/` on the local filesystem. Survives coordinator restart IF the directory is backed by a PVC. Lost on pod eviction with `emptyDir`. | On-prem k8s with a PVC mounted at `/etc/trino/catalog` |
> | `memory` | Stores catalog definitions only in coordinator JVM heap. Every pod restart or eviction loses all dynamically-created catalogs — you must re-CREATE on startup. | Local development / ephemeral test clusters |
>
> In production Kubernetes, use `catalog.store=file` with a PVC. The `memory` store is useful for dev clusters where you want a clean slate on every restart. Without an explicit `catalog.store` property, Trino 467 defaults to `file` when `catalog.management=dynamic` is set.

> **Kubernetes gotcha — dynamic mode requires a writable catalog directory.** When `catalog.management=dynamic`, Trino writes catalog state to the filesystem at `etc/catalog/`. In a standard k8s deployment, this directory is mounted as a read-only ConfigMap. Dynamic catalog management will fail at startup with `FileNotFoundException: ... Read-only file system`.
>
> **Fix**: Mount a writable volume at `etc/catalog/` instead of (or in addition to) the read-only ConfigMap:
> ```yaml
> volumes:
>   - name: catalog-data
>     emptyDir: {}  # or a PersistentVolumeClaim for durability across restarts
> volumeMounts:
>   - name: catalog-data
>     mountPath: /etc/trino/catalog
> ```
> With `emptyDir`, catalogs created via `CREATE CATALOG` are lost on pod restart — you must re-CREATE them on startup (use an init container or operator). With a PVC, they persist across restarts.

#### Creating a catalog at runtime

```sql
CREATE CATALOG app_pg USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://replica:5432/appdb?ssl=true&sslmode=require&defaultRowFetchSize=1000&socketTimeout=60&connectTimeout=10',
  "connection-user" = 'trino_reader',
  "connection-password" = 'secret',
  "metadata.cache-ttl" = '60s'
);
```

The catalog is registered cluster-wide immediately. `SHOW CATALOGS` will list `app_pg` and queries against it will start working without any pod restart.

> **Security**: `CREATE CATALOG` SQL statements (including the `connection-password` value) are logged in full in the Trino Web UI's query history. **Never run CREATE CATALOG with a plain-text password in a shared or audited cluster.** Use environment-variable indirection or a secrets manager to inject credentials, or ensure only admins can see query history.

#### Rotating credentials without a restart (DROP + CREATE)

There is **no `ALTER CATALOG` in Trino 467** yet (tracked at [trinodb/trino#25542](https://github.com/trinodb/trino/issues/25542)). The credential-rotation pattern is **DROP + CREATE**.

> **IMPORTANT — security caveats for credential rotation via DROP+CREATE. Read all three before automating this in production.**
>
> **(a) `catalog.management=dynamic` is marked experimental in Trino 467.** The SQL surface, property names, and persistence behavior may change in future releases. **Verify your security / platform team approves use of experimental features before enabling in production**, and pin your runbook to a specific Trino version with a known-good behavior.
>
> **(b) The full `CREATE CATALOG ... WITH ("connection-password" = '...')` SQL statement is logged verbatim in the Trino Web UI query history** — every user who can view query history (typically anyone with the `system` UI role, plus admins) will see the rotated password in plaintext, along with all other CREATE CATALOG parameters. **ALWAYS use `${ENV:VAR}` indirection to reference passwords from environment variables** rather than hardcoding them in the CREATE CATALOG SQL — the environment variable name appears in the UI, but the resolved password value does not. Example:
> ```sql
> CREATE CATALOG app_pg USING postgresql
> WITH (
>   "connection-url" = 'jdbc:postgresql://replica:5432/appdb',
>   "connection-user" = 'trino_reader',
>   "connection-password" = '${ENV:APP_PG_PASSWORD}'   -- resolved on the coordinator; NOT logged verbatim
> );
> ```
> The environment variable must be present on every Trino coordinator/worker pod (mounted via the same Kubernetes Secret pattern shown in Section 2.2). To rotate, update the Secret, restart the pods to re-read the env var, then DROP + CREATE the catalog so Trino re-resolves the variable. (Alternatively, deploy a secrets-manager-backed config provider such as the Vault or AWS Secrets Manager Trino plugin if your stack supports it.)
>
> **(c) The role running DROP CATALOG / CREATE CATALOG must have `CreateCatalog` and `DropCatalog` privileges in your OPA policy** (see Section 2.8.1 for the authorization flow). Without these grants, even an admin-credentialed session will see `Access Denied: Cannot create catalog ...`. Make sure the rotation actor's identity (service account, CI/CD runner, on-call admin user) is a member of the `platform-admin` group (or whichever group your Rego policy gates these operations on).

The credential-rotation pattern is:

```sql
-- Step 1: Create a NEW catalog entry with the new password under a different name.
-- (Queries can still use the OLD catalog during this step — both coexist.)
CREATE CATALOG app_pg_new USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://replica:5432/appdb',
  "connection-user" = 'trino_reader',
  "connection-password" = 'new_secret'
  -- ... (other properties)
);

-- Step 2: Drop the OLD catalog. This does NOT interrupt in-flight queries
-- that are currently using it; they continue to completion. New queries
-- referencing `app_pg` will fail with "catalog not found" between this DROP
-- and the next CREATE — keep the window tight.
DROP CATALOG app_pg;

-- Step 3: Recreate with the ORIGINAL name (so existing user queries keep working).
CREATE CATALOG app_pg USING postgresql
WITH (
  "connection-url" = 'jdbc:postgresql://replica:5432/appdb',
  "connection-user" = 'trino_reader',
  "connection-password" = 'new_secret'
  -- ... (other properties)
);

-- Step 4: Drop the temporary catalog.
DROP CATALOG app_pg_new;
```

> **Important**: `DROP CATALOG` does **not** interrupt in-flight queries that are currently using that catalog — those queries continue to completion. **New** queries arriving after the `DROP` but before the `CREATE` will fail with "catalog not found." Keep the window between DROP and CREATE as short as possible (run them in the same client session, back-to-back).

> **ICEBERG / HIVE RESOURCE-LEAK WARNING**: `DROP CATALOG` for connectors that read from HDFS or object storage (Hive, Iceberg, Delta Lake) may **not** release all background resources (background split-enumeration threads, file-system connection pools, metadata caches) even after the SQL completes successfully. The Trino docs recommend restarting the coordinator and workers after dropping an Iceberg or Hive catalog in production. For the PostgreSQL connector used in this section, a full restart is NOT required — `DROP CATALOG app_pg` cleanly releases the JDBC connection pool. The restart recommendation applies specifically to Iceberg, Hive, and Delta Lake catalogs on this stack.

#### Dynamic catalog vs. Kubernetes ConfigMap approach

| Approach | How catalogs are managed | Restart needed? | Effect on in-flight queries |
|---|---|---|---|
| **Static** (default, `catalog.management=static`) | Catalog properties files mounted via ConfigMap → require a Trino pod restart to apply changes. | YES — coordinator + workers must roll. | In-flight queries on a restarted pod **fail**. Rolling restart minimizes blast radius but does not eliminate it. |
| **Dynamic** (`catalog.management=dynamic`) | Catalogs created/dropped via SQL at runtime. | NO. | `DROP CATALOG` does NOT interrupt queries currently using it; only new queries between DROP and CREATE fail. |

**For password rotation and adding new catalogs on this stack, the dynamic approach is preferred.** Enable `catalog.management=dynamic` in `etc/config.properties` and use the DROP+CREATE pattern above. The ConfigMap approach is fine for initial cluster bootstrap (defining the starter set of catalogs) but should not be the primary mechanism for ongoing catalog lifecycle.

#### Dual-role pattern for truly zero-downtime credential rotation

For zero-downtime credential rotation (no "catalog not found" window at all), coordinate with your Postgres team on a **dual-role** approach instead of dual-password:

1. Create a **second Postgres role** `trino_reader_v2` with the same grants as `trino_reader` (`GRANT CONNECT`, `GRANT USAGE`, `GRANT SELECT ...`).
2. Run the DROP+CREATE on the Trino side, but with `trino_reader_v2` credentials in the new CREATE. Existing queries keep using the old catalog (which uses `trino_reader`); new queries pick up the new catalog using `trino_reader_v2`.
3. Verify everything works on `trino_reader_v2` for some bake period (e.g., 24 hours).
4. **Revoke** the `trino_reader` role on Postgres (or change its password to invalidate it).
5. On the next rotation, repeat in the other direction (`trino_reader_v2` → `trino_reader_v3`, or rotate back to `trino_reader` with a fresh password).

> **Do NOT try a "dual password" approach** — standard PostgreSQL does **not support multiple passwords per role**. `ALTER ROLE <role> PASSWORD '<new>'` replaces the password atomically; there is no overlap window where both the old and new passwords work. The dual-role pattern is the actual mechanism for zero-downtime rotation. (PostgreSQL 17+ has limited multi-password support through extensions, but standard production Postgres does not.)

#### Quick recap

- Enable `catalog.management=dynamic` on the coordinator.
- Use `CREATE CATALOG` / `DROP CATALOG` SQL — no pod restart needed.
- Password rotation: DROP + CREATE (no `ALTER CATALOG` in 467; tracked in #25542).
- Zero-downtime rotation: dual-role on the Postgres side (NOT dual-password — Postgres doesn't support that).
- In-flight queries on a dropped catalog continue to completion; only new queries fail between DROP and CREATE.

#### 2.8.1 Restricting CREATE CATALOG / DROP CATALOG with OPA — who is allowed to run catalog DDL

> **This subsection exists because turning on `catalog.management=dynamic` only enables the *capability* to create and drop catalogs at runtime — it does NOT restrict *who* may do so. In a multi-tenant SaaS environment running Trino with the OPA access-control plugin, you almost always want CREATE CATALOG and DROP CATALOG limited to a platform-admin group, with regular engineers and customers blocked. This is enforced by your OPA policy, not by Trino config alone.**

##### 5-step debugging checklist for "Access Denied: Cannot create catalog ..."

When `CREATE CATALOG` fails with `Access Denied`, walk these five checks in order. Each check confirms or eliminates one of the most common failure modes; the rest of section 2.8.1 explains the underlying mechanism in detail.

1. **Confirm the feature gate is on.** On the coordinator pod:
   ```bash
   grep catalog.management /etc/trino/config.properties
   ```
   Must show `catalog.management=dynamic`. If it shows `static` (or the line is missing), Trino rejects the SQL at parse time and OPA is never consulted — fix the config and roll the coordinator before continuing.
2. **Turn on Trino-side OPA request/response logging** so you can see exactly what Trino is sending. In `etc/access-control.properties`:
   ```properties
   opa.log-requests=true
   opa.log-responses=true
   ```
   And in `etc/log.properties`:
   ```properties
   io.trino.plugin.opa.OpaHttpClient=DEBUG
   ```
   Entries appear in the **normal Trino server log** at DEBUG level under the `io.trino.plugin.opa.OpaHttpClient` logger. See the "Debugging: How to See What Trino Sends to OPA" subsection below for full details.
3. **Turn on OPA-side decision logging** so you can see what OPA decided. In OPA's config:
   ```yaml
   decision_logs:
     console: true
   ```
   Then:
   ```bash
   kubectl logs <opa-pod>
   ```
   You'll see one JSON record per decision with the full `input` document and `result`.
4. **Decode the JWT and inspect the `groups` claim.** From a session that holds the failing user's token:
   ```bash
   echo $JWT | cut -d. -f2 | base64 -d | jq .
   ```
   Confirm the `groups` claim actually contains the value your Rego rule checks for (e.g., `"platform-admin"`). A common failure is the JWT being valid but missing the expected group claim — Trino authenticates the user, OPA evaluates, no rule matches, default-deny fires.
5. **Verify the Rego rule matches the exact operation string.** The operation field uses the SPI method name in **PascalCase**: `"CreateCatalog"` (not `"CREATE CATALOG"`, not `"create_catalog"`, not `"createCatalog"`). A rule written as `input.action.operation == "CreateCatalog"` matches; anything else silently fails to match and the user hits default-deny.

If all five checks pass and CREATE CATALOG still fails, dive into the detailed flow analysis below — but in practice, one of these five is the cause about 95% of the time.

##### Does OPA actually see CREATE CATALOG / DROP CATALOG?

**Yes.** Catalog DDL flows through the `SystemAccessControl` SPI in Trino, the same SPI that the OPA plugin implements. When a user runs `CREATE CATALOG ...` or `DROP CATALOG ...`, the Trino coordinator invokes:

- `SystemAccessControl.checkCanCreateCatalog(SystemSecurityContext, String catalogName)`
- `SystemAccessControl.checkCanDropCatalog(SystemSecurityContext, String catalogName)`

The OPA plugin translates each call into an HTTP POST to your OPA decision endpoint with an input document whose `action.operation` is the string **`"CreateCatalog"`** or **`"DropCatalog"`** respectively. Your Rego policy can match on those operation values and decide allow/deny just as it does for `SelectFromColumns`, `RenameTable`, etc.

##### Order of checks — what Trino verifies *before* OPA is consulted

This ordering matters and is a common source of confusion when CREATE CATALOG appears to "silently fail":

1. **Trino first checks `catalog.management`** in `etc/config.properties`. If it is `static` (the default), `CREATE CATALOG` / `DROP CATALOG` are rejected at SQL parse/validation time with an error like `Catalog management type must be 'dynamic'`. **OPA is never consulted** in this case — the SQL is refused before the access-control layer is invoked.
2. **If `catalog.management=dynamic` is set**, Trino then calls `checkCanCreateCatalog` (or `checkCanDropCatalog`) on the configured `SystemAccessControl` — which, on this stack, is the OPA plugin.
3. **OPA evaluates the policy** with the input document (operation name + identity context + catalog name) and returns `{"result": {"allow": true|false}}`.
4. If OPA returns `allow=false`, Trino throws `AccessDeniedException` and the user sees `Access Denied: Cannot create catalog <name>` (or `Cannot drop catalog <name>`).

So both pieces are required for a working platform-admin-only CREATE CATALOG policy:
- **Config side**: `catalog.management=dynamic` enables the feature.
- **OPA side**: a Rego rule that allows the `CreateCatalog` / `DropCatalog` operations only for the platform-admin group.

> **Cross-reference — credential rotation actors must be in the privileged group.** When automating credential rotation via the DROP + CREATE CATALOG pattern (Section 2.8), the rotation actor's identity (service account, CI/CD runner, on-call admin user) must be a member of the `platform-admin` group (or whichever group your Rego policy grants `CreateCatalog` / `DropCatalog` privileges to). Otherwise the rotation script fails with `Access Denied: Cannot drop catalog ...` halfway through and you end up with a half-rotated catalog. Bake the group membership check into the runbook's preflight, not the post-mortem.

##### Critical distinction — `opa.allow-permission-management-operations` does NOT gate catalog DDL

In `etc/access-control.properties`, the OPA plugin supports a flag:

```properties
opa.allow-permission-management-operations=true
```

It is tempting to assume this controls "permission-y things" like CREATE CATALOG. **It does not.** That flag governs a separate, narrower set of SQL operations:

- `GRANT` / `REVOKE` / `DENY` of schema and table privileges
- `CREATE ROLE` / `DROP ROLE` / `GRANT ROLES` / `REVOKE ROLES`
- Role-show operations (`SHOW ROLES`, `SHOW CURRENT ROLES`, `SHOW ROLE GRANTS`)

These are the operations the Trino OPA docs explicitly list as "permission management." When `opa.allow-permission-management-operations=false` (the default), Trino denies them *without contacting OPA at all* — it short-circuits. When `true`, Trino *does* contact OPA for each, and your policy decides.

**`CreateCatalog` and `DropCatalog` are on a different code path.** They are always sent to OPA regardless of `opa.allow-permission-management-operations`. So you cannot lock down catalog DDL by leaving that flag at `false` — you must write an explicit OPA policy rule.

| Flag / setting | What it controls | Affects CREATE/DROP CATALOG? |
|---|---|---|
| `catalog.management=dynamic` (config.properties) | Whether the SQL syntax is even permitted | YES — gate #1; without it, OPA is never consulted |
| `opa.allow-permission-management-operations` (access-control.properties) | Whether GRANT/REVOKE/role ops contact OPA at all | **NO** — separate operation set |
| Your Rego policy's `allow` rule matching `CreateCatalog` / `DropCatalog` | Whether *this user* may create/drop *this catalog* | YES — gate #2 |

##### End-to-end flow — admin runs CREATE CATALOG

1. Platform admin holds a JWT with claim `groups: ["platform-admin"]` and submits:
   ```sql
   CREATE CATALOG sql_pg USING postgresql
   WITH (
     "connection-url" = 'jdbc:postgresql://replica:5432/appdb',
     "connection-user" = 'trino_reader',
     "connection-password" = 'secret'
   );
   ```
2. Trino coordinator validates the SQL. Because `catalog.management=dynamic` is in `config.properties`, the statement is accepted for execution.
3. Coordinator calls `SystemAccessControl.checkCanCreateCatalog(securityContext, "sql_pg")` on the OPA plugin.
4. OPA plugin POSTs to the OPA server with a body like:
   ```json
   {
     "input": {
       "context": {
         "identity": { "user": "alice", "groups": ["platform-admin"] },
         "queryId": "20260526_120000_00001_xxxxx",
         "trinoVersion": "467"
       },
       "action": {
         "operation": "CreateCatalog",
         "resource": { "catalog": { "name": "sql_pg" } }
       }
     }
   }
   ```
   > **Schema note**: `trinoVersion` is a direct field on `input.context`, not wrapped in a `softwareStack` (or any other) object. If your Rego policy references `input.context.softwareStack.trinoVersion`, it will never match — the correct path is `input.context.trinoVersion`. Confirm against your live OPA decision log (step 3 of the debugging checklist) before writing version-conditional rules.
5. OPA evaluates Rego, returns `{"result": {"allow": true}}`, Trino proceeds, the catalog is registered cluster-wide and visible via `SHOW CATALOGS`.

For a non-admin user (e.g., `groups: ["customer"]`), step 5 returns `allow=false` and the user sees:
```
Query failed: Access Denied: Cannot create catalog sql_pg
```
The catalog is **not** created. Same flow applies for `DROP CATALOG` with `operation: "DropCatalog"`.

##### Conceptual Rego pattern (illustrative only — see external governance document for production policy)

> **Reminder**: Per `prod_info.md`, this repo does not document the production permission model. The Rego below is a **conceptual illustration** of how to gate catalog DDL on group membership. Your real policy is defined in the external governance document. Group names like `"platform-admin"` are placeholders — substitute the actual group claim values your auth service emits in the JWT.

```rego
package trino

import future.keywords.in

# Default deny — every Trino action that doesn't match an explicit allow is denied.
default allow := false

# --- Catalog DDL: only platform admins may create or drop catalogs ---

allow if {
  input.action.operation == "CreateCatalog"
  "platform-admin" in input.context.identity.groups
}

allow if {
  input.action.operation == "DropCatalog"
  "platform-admin" in input.context.identity.groups
}

# --- Other operations (SelectFromColumns, etc.) handled by separate rules ---
# allow if { input.action.operation == "SelectFromColumns"; ... }
```

What this policy enforces:

- A user whose JWT-derived `groups` claim contains `"platform-admin"` is allowed to run `CREATE CATALOG` and `DROP CATALOG` on **any** catalog name.
- Every other user — regular engineers, customers, service accounts not in that group — falls through to `default allow := false` for those two operations and receives `Access Denied`.
- The rule matches *only* on `operation`; it does not depend on the catalog name. If you need finer control (e.g., "only platform-admin can create catalogs whose name starts with `prod_`"), add a check against `input.action.resource.catalog.name`.

If you want different groups for create vs. drop (a common pattern — give more people the ability to add catalogs than to remove them), split the rules:

```rego
allow if {
  input.action.operation == "CreateCatalog"
  some g in input.context.identity.groups
  g in {"platform-admin", "platform-onboarding"}
}

allow if {
  input.action.operation == "DropCatalog"
  "platform-admin" in input.context.identity.groups   # drop is admin-only
}
```

##### Verification recipe

After deploying the policy, prove it actually denies non-admins:

1. **Positive test (admin)** — using a JWT for a user in `platform-admin`:
   ```sql
   CREATE CATALOG test_temp USING tpch WITH ("tpch.splits-per-node" = '4');
   SHOW CATALOGS;          -- includes test_temp
   DROP CATALOG test_temp;
   ```
   All three should succeed.

2. **Negative test (non-admin)** — using a JWT for a regular engineer or customer:
   ```sql
   CREATE CATALOG test_temp USING tpch WITH ("tpch.splits-per-node" = '4');
   ```
   Expected response:
   ```
   Query failed (#xxxxx): Access Denied: Cannot create catalog test_temp
   ```
   And `SHOW CATALOGS` does **not** list `test_temp` — confirming the catalog was never registered.

3. **Audit verification** — check the OPA server's decision log for the denied request. You should see two entries for the negative test:
   - `input.action.operation == "CreateCatalog"`, `input.context.identity.user == "<engineer>"`, `result.allow == false`.
   - (And after the failed CREATE, no corresponding `DropCatalog` because the user never got that far.)

4. **Negative test for DROP** — admin creates a catalog, then a non-admin attempts `DROP CATALOG`:
   ```sql
   -- as non-admin:
   DROP CATALOG test_temp;
   -- → Access Denied: Cannot drop catalog test_temp
   ```

5. **Sanity-check the config gate is still doing its job**: temporarily comment out `catalog.management=dynamic`, restart, and re-run as admin. The CREATE should be rejected before OPA is consulted — confirming the config is gate #1 and OPA is gate #2.

##### Debugging: How to See What Trino Sends to OPA

When `CREATE CATALOG` returns `Access Denied` and you cannot tell from the error alone *why* OPA denied, you need to see (a) the exact JSON Trino sent to OPA and (b) the exact response OPA returned. The OSS Trino 467 OPA plugin and OPA itself each provide a logging mechanism. Wire both on, reproduce the failure, then read both logs side-by-side.

**Trino side — request/response logging in the OPA plugin.** In `etc/access-control.properties` (the same file where you configure `access-control.name=opa` and `opa.policy.uri`), add:

```properties
opa.log-requests=true
opa.log-responses=true
```

These two flags tell the OPA plugin to log each outbound request body and each inbound response body. They produce verbose output, so enable them only while debugging.

The plugin emits its log lines via the standard Trino logger named `io.trino.plugin.opa.OpaHttpClient`. By default that logger is at INFO, which suppresses the request/response detail. Lower it to DEBUG in `etc/log.properties`:

```properties
io.trino.plugin.opa.OpaHttpClient=DEBUG
```

Restart the coordinator (or reload the access-control config, depending on your deployment). Reproduce the failing `CREATE CATALOG`, then read the **normal Trino server log** — typically `kubectl logs <trino-coordinator-pod>` on this stack, or whatever sink your cluster ships coordinator stdout to. The OPA plugin's request/response entries appear inline with the rest of the server log, tagged with the `io.trino.plugin.opa.OpaHttpClient` logger name.

> **CRITICAL — what does NOT exist.** There is **no** `access-control.log=true` Trino configuration property. There is **no** dedicated `/var/log/trino/access-control.log` file written by the OPA plugin or by Trino itself. The OPA plugin's request/response entries appear in the **normal Trino server log at DEBUG level** under the `io.trino.plugin.opa.OpaHttpClient` logger — not in any separate access-control log file. If you grep your filesystem for `access-control.log` and find nothing, that is expected; you have not misconfigured anything. Look at the standard Trino server log (coordinator pod stdout on this stack) and filter for the `OpaHttpClient` logger name.

What you see in a successful request log entry: the full JSON `input` document the plugin POSTed to OPA — including `input.action.operation`, `input.action.resource.catalog.name`, and the entire `input.context.identity` block with the user's `groups` claim. This is the authoritative ground truth for "what did Trino actually send?" If your Rego policy expected `"platform-admin"` in the groups list and the request log shows `["customer"]`, the JWT or the auth service's group-mapping is the bug — not the policy.

**OPA side — decision logging.** Trino's logs show you the request and the HTTP response, but they do not show you which Rego rule fired (or did not fire) inside OPA. To see OPA's decision reasoning, enable decision logs in OPA's own config file (usually `config.yaml` in the OPA pod, or the Helm chart's values file):

```yaml
decision_logs:
  console: true
```

Then read OPA's stdout:

```bash
kubectl logs <opa-pod>
```

Each entry is a structured JSON record containing `input` (what OPA received — should mirror the Trino-side request log), `result` (the policy output, e.g., `{"allow": false}`), and metadata like `decision_id`, `metrics`, and timestamps. Cross-reference the `decision_id` (or matching `query_id` in `input.context`) against the Trino request log to confirm you're looking at the same decision on both sides.

> **CRITICAL — what does NOT exist on the OPA side either.** OPA has **no** REST endpoint for retrieving past decisions. `curl http://opa-server:8181/api/v1/decisions` does **not** work — that endpoint does not exist in OPA. Decisions are streamed in real-time to OPA's stdout (when `decision_logs.console: true` is set) or pushed to a remote HTTP sink (when `decision_logs.service` is configured) by OPA's built-in decision-log plugin. There is no on-disk decision database in OPA that you can query after the fact. If you need historical decision data, you must have shipped the stream to a durable backend (OpenSearch, Loki, ELK, a SIEM) *before* the decision happened — see Section 6.C for the durability wiring on this stack.

**Putting both sides together.** A complete debug session for an Access Denied looks like:

1. Enable the four logging settings above (`opa.log-requests`, `opa.log-responses`, `OpaHttpClient=DEBUG`, `decision_logs.console: true`).
2. Reproduce the failing `CREATE CATALOG` from the user's session.
3. In the Trino coordinator log, grep for `OpaHttpClient` near the failure timestamp. Read the request JSON: confirm `operation == "CreateCatalog"`, the catalog name, and the `groups` claim.
4. In the OPA pod log, grep for the same `query_id` or matching timestamp. Read the `result` field: confirm `allow=false` and look at OPA's own diagnostic output (if you've enabled `decision_logs.console: true` with verbose mode, the rule path that fired is included).
5. Compare. If the Trino request looks correct but OPA denied, the bug is in Rego (rule typo, wrong operation string, wrong group check). If the Trino request shows the user's `groups` claim is missing or wrong, the bug is upstream in the JWT/auth service. If you see no OPA request log entry at all for the failing query, then either OPA was never consulted (check `catalog.management=dynamic`) or the OPA plugin is not actually wired in (check `access-control.name=opa` in `access-control.properties`).

**Turn the verbose logging off when done.** `opa.log-requests=true` + `opa.log-responses=true` + `OpaHttpClient=DEBUG` produce one log entry per access-control check, and OPA is consulted for *every* SQL operation — `SelectFromColumns`, `ShowSchemas`, `FilterCatalogs`, etc. On a busy cluster this is gigabytes of logs per day and a measurable I/O hit on the coordinator. Revert all four settings (or scope DEBUG to a narrower window via your log framework) once the root cause is identified.

##### Common mistakes to avoid

- **Assuming `opa.allow-permission-management-operations=false` blocks CREATE CATALOG.** It does not. Catalog DDL goes through `checkCanCreateCatalog` / `checkCanDropCatalog`, not the permission-management path. You must write an explicit Rego rule.
- **Forgetting `catalog.management=dynamic`.** Without it, even a perfect OPA policy is irrelevant — Trino refuses the SQL at parse time and your platform admin will still see `Catalog management type must be 'dynamic'` instead of a successful CREATE.
- **Allowing all operations by default in Rego.** Always start the policy with `default allow := false`. An `allow` rule that matches everything not explicitly denied opens catalog DDL to every user.
- **Matching on `input.action.operation == "CREATE CATALOG"` (SQL text)** — wrong. The operation field uses the SPI method name in PascalCase: `"CreateCatalog"`, `"DropCatalog"`. (Same convention as `SelectFromColumns`, `RenameTable`, `CreateRole`, etc.)
- **Relying only on Trino UI / JWT-side checks.** A determined user with a valid JWT can craft a CREATE CATALOG directly against the Trino HTTP API. The OPA policy is what actually enforces the restriction at the engine.
- **Looking for `/var/log/trino/access-control.log` or setting `access-control.log=true`.** Neither exists in OSS Trino 467. OPA plugin request/response logging goes to the normal Trino server log at DEBUG level under `io.trino.plugin.opa.OpaHttpClient` — see the "Debugging: How to See What Trino Sends to OPA" subsection above.
- **Trying to `curl` OPA for past decisions.** OPA has no `/api/v1/decisions` REST endpoint. Decisions are emitted at evaluation time to stdout (`decision_logs.console: true`) or to a remote sink (`decision_logs.service`). Historical decisions exist only where you've shipped that stream.

##### Summary — the two-gate picture

| Gate | Where | What it does | If misconfigured |
|---|---|---|---|
| 1. Feature gate | `etc/config.properties` → `catalog.management=dynamic` | Enables runtime CREATE/DROP CATALOG SQL at all | CREATE CATALOG fails at parse time; OPA never consulted |
| 2. Authorization gate | OPA Rego policy → `allow` rule matching `operation in {"CreateCatalog","DropCatalog"}` and group membership | Restricts *who* may create/drop catalogs | Either over-permits (regular users can DDL) or over-denies (admins blocked) |

Both gates must be set correctly. Config enables the feature; OPA controls who uses it.

---

## 2A. MySQL connector — what's the same as PostgreSQL, what's different

The MySQL connector is the second JDBC connector you are likely to set up alongside `app_pg`. The **shape** of Section 2 carries over (catalog file layout, JDBC URL parameters live on `connection-url`, schema metadata caching, dynamic catalog management) — but several **specific parameter names and value units differ** between MySQL Connector/J and the PostgreSQL JDBC driver. Two areas where copy-pasting Section 2 examples directly into a MySQL catalog will cause production incidents:
>
> 1. **SSL/TLS property names and CA cert file format differ** — see Section 2A.1A. pgjdbc uses `ssl=true&sslmode=...&sslrootcert=<PEM>`; MySQL Connector/J uses `sslMode=...&trustCertificateKeyStoreUrl=<JKS>`. Pasting `sslmode=verify-full&sslrootcert=/etc/trino/certs/ca.crt` into a MySQL URL silently fails open.
> 2. **`socketTimeout` and `connectTimeout` units differ** — see the UNIT WARNING in 2A.1. pgjdbc uses **seconds**; MySQL Connector/J uses **milliseconds**. Pasting `socketTimeout=60` from Section 2.4 into a MySQL URL kills every query at 60ms.
>
> Additionally, **the critical pushdown and timezone differences** (next subsections) are NOT the same as PostgreSQL, and assuming they are is the #1 source of "why is my MySQL query so slow?" tickets.

### 2A.1 Catalog configuration

```properties
# etc/catalog/billing_mysql.properties
connector.name=mysql
connection-url=jdbc:mysql://billing-replica.internal:3306/billing?defaultFetchSize=1000&useCursorFetch=true&socketTimeout=60000&connectTimeout=10000
connection-user=trino_reader
connection-password=${ENV:MYSQL_PASSWORD}

# !!! CRITICAL FETCH-SIZE PARAMETER NAME DIFFERENCE !!!
# PostgreSQL pgjdbc uses `defaultRowFetchSize` (row count).
# MySQL Connector/J uses `defaultFetchSize` — and on its own it is NOT enough.
# To get actual row streaming from MySQL (instead of MySQL Connector/J
# buffering the entire result set in client memory regardless of fetch size),
# you must set BOTH:
#     defaultFetchSize=1000
#     useCursorFetch=true
# Without `useCursorFetch=true`, MySQL Connector/J's default behavior is to
# fetch the ENTIRE result set into memory in one round-trip, and `defaultFetchSize`
# is silently ignored. Pasting `defaultRowFetchSize` (the Postgres name) into a
# MySQL URL is also silently ignored.
#
# All the JDBC URL knobs from Section 2.4 apply in shape, BUT MySQL Connector/J
# uses DIFFERENT PARAMETER NAMES and DIFFERENT UNITS than the PostgreSQL JDBC driver:
#   defaultFetchSize=1000     — row count per network round-trip (pair with useCursorFetch=true)
#   useCursorFetch=true       — REQUIRED on MySQL to make defaultFetchSize actually stream rows
#   socketTimeout=60000       — fail a stuck query at the socket layer (60 SECONDS = 60000 MILLISECONDS)
#   connectTimeout=10000      — fail fast if the MySQL host is unreachable (10 SECONDS = 10000 MILLISECONDS)
#
# !!! UNIT WARNING !!! MySQL Connector/J socketTimeout and connectTimeout are in MILLISECONDS,
# NOT seconds. This is the OPPOSITE of the PostgreSQL JDBC driver (Section 2.4) where the
# same-named parameters are in SECONDS. Mixing the two units is a common — and
# production-dangerous — copy-paste error.
#
#   socketTimeout=60           ← WRONG for MySQL: 60 milliseconds = 0.06 seconds.
#                                 Immediately kills every query because no MySQL response
#                                 can possibly arrive in 60ms.
#   socketTimeout=60000        ← CORRECT for MySQL: 60 seconds.
#   connectTimeout=10          ← WRONG for MySQL: 10 milliseconds.
#   connectTimeout=10000       ← CORRECT for MySQL: 10 seconds.
#
# Default for both on MySQL Connector/J is 0 (unlimited — no timeout). The mismatch with
# pgjdbc (where the same parameters are seconds) is the #1 unit-confusion bug in
# multi-database federation setups. ALWAYS verify the connector's driver docs before
# pasting a JDBC URL across connectors.
#
# Schema metadata caching from Section 2.6 also applies — same property names.
# DEFAULT IS 0s (caching DISABLED) on the MySQL connector — same as PostgreSQL.
# To reduce cross-catalog planning latency, INCREASE this value (do NOT decrease;
# it cannot go below 0). Production-tuned values: 30s–60s.
metadata.cache-ttl=30s       # default 0s (disabled) — raise to cache MySQL schema
metadata.cache-missing=true  # also cache "table not found" lookups (default: false — "table not found" results are NOT cached by default)
#
# Per-domain sub-TTLs (all default to metadata.cache-ttl if unset) — same on MySQL:
#   metadata.schemas.cache-ttl     — schema (database) list cache
#   metadata.tables.cache-ttl      — table list and column definitions cache
#   metadata.statistics.cache-ttl  — table statistics (row counts, NDVs) cache
# Typical pattern: metadata.tables.cache-ttl=60s (schema changes infrequent),
# metadata.statistics.cache-ttl=300s (stats more stable). Reduces metadata-query
# load on the MySQL replica while keeping schema changes visible quickly.
#
# metadata.cache-maximum-size=10000 (default) — max metadata entries cached per
# catalog. For very large MySQL databases (thousands of tables), raise this if
# you observe cache churn / frequent metadata misses in a large-catalog setup.
```

Point this at a **read replica** (same rule as Postgres, Section 2.3 and 8.1). Never connect Trino to your OLTP MySQL primary.

> **Schema-namespace note — MySQL catalog schemas map to MySQL DATABASES, not a `public` schema.** A frequent copy-paste mistake from Postgres examples is writing `billing_mysql.public.invoices`. **There is no `public` schema in MySQL** — `public` is a PostgreSQL convention (every Postgres database has a `public` schema by default). In MySQL, **the schema name is the MySQL database name**. Concretely, if your MySQL replica hosts a database named `billing_db` containing a table named `invoices`, the fully-qualified Trino reference is `billing_mysql.billing_db.invoices`, NOT `billing_mysql.public.invoices`. Pasting `public` will fail with `Schema 'public' does not exist`. Use `SHOW SCHEMAS FROM billing_mysql` to list the actual MySQL databases the connector exposes — those are the valid schema names for fully-qualified table references.

#### MySQL metadata caching — `metadata.cache-ttl` default and how to flush

> **`metadata.cache-ttl` default is 0s (disabled)** in the Trino MySQL connector (OSS Trino 467).
> To cache MySQL schema and reduce cross-catalog planning latency, set:
>
> ```properties
> # etc/catalog/billing_mysql.properties
> metadata.cache-ttl=30s       # default 0s (disabled)
> metadata.cache-missing=true  # also cache "table not found" lookups (default: false — "table not found" results are NOT cached)
> ```
>
> The trade-off: schema changes (column adds, renames) take up to `cache-ttl` to be visible in Trino. Flush immediately with:
> ```sql
> CALL billing_mysql.system.flush_metadata_cache();
> ```
> Note: the MySQL connector's `flush_metadata_cache()` takes NO parameters (unlike Hive/Delta connectors which have named params).

To **change the TTL value** itself (e.g., bump it from 30s to 60s), you need a catalog reload — the same hot-reload rules as Postgres apply (see the Section 2.6 callout on `metadata.cache-ttl` not being hot-loadable). Calling `flush_metadata_cache()` only clears the in-memory cache; it does NOT re-read the properties file to pick up a new TTL value.

Source: [trino.io/docs/current/connector/mysql.html](https://trino.io/docs/current/connector/mysql.html) — "General configuration properties" section.

### 2A.1A SSL/TLS for the MySQL connector — DIFFERENT PROPERTIES from PostgreSQL

> **Critical asymmetry.** Section 2.5 documents SSL for the PostgreSQL connector using `ssl=true&sslmode=verify-full&sslrootcert=/path/to/ca.crt` — and the `sslrootcert` parameter accepts a **PEM file directly**. **The MySQL connector is different on TWO axes**:
>
> 1. **Different property names.** MySQL Connector/J uses `sslMode=...` (camelCase, single property), NOT `ssl=true&sslmode=...` (the two-property pgjdbc form).
> 2. **Different file format for the CA cert.** MySQL Connector/J requires the trust store in **JKS or PKCS#12 format** — NOT PEM. You must convert your PEM CA cert with `keytool` before MySQL Connector/J can load it.
>
> Pasting the PostgreSQL `sslrootcert=/etc/trino/certs/ca.crt` parameter into a `jdbc:mysql://...` URL silently does nothing — the parameter is unknown to MySQL Connector/J and is ignored. The connection is encrypted (if `sslMode=REQUIRED` was set) but the certificate chain is NEVER verified against your CA. **This is the single most dangerous SSL misconfiguration possible — you believe you have a verified TLS connection; you actually have MITM-vulnerable encryption with no chain validation.**

#### MySQL Connector/J `sslMode` values — the only correct way to declare SSL intent

| `sslMode` value | TLS encryption? | CA chain verification? | Hostname verification? | When to use |
|---|---|---|---|---|
| `DISABLED` | NO (plaintext) | NO | NO | Local dev only. Never production. |
| `PREFERRED` | If server supports it; **plaintext fallback** if not | NO | NO | Almost never the right answer — silently downgrades. |
| `REQUIRED` | YES | NO | NO | Stopgap. Encrypts the wire but vulnerable to MITM. |
| `VERIFY_CA` | YES | YES (verifies cert chains to your CA) | NO | Cert pinned to CA, but allows cert issued by your CA for a different host. |
| `VERIFY_IDENTITY` | YES | YES | YES (verifies cert CN/SAN matches hostname in JDBC URL) | **The production-correct mode.** Equivalent in semantics to pgjdbc's `sslmode=verify-full`. |

**Do NOT include the deprecated `useSSL=true&requireSSL=true&verifyServerCertificate=true` properties alongside `sslMode`.** Those are MySQL Connector/J 5.x-era properties; they are deprecated since 8.x and are **IGNORED when `sslMode` is set explicitly**. Engineers occasionally paste them in "for compatibility" — they do nothing on modern drivers and clutter the URL. Set `sslMode` only.

#### Minimal SSL — encrypt the wire, do NOT verify the server's certificate

```properties
# etc/catalog/billing_mysql.properties
connection-url=jdbc:mysql://billing-replica.internal:3306/billing?sslMode=REQUIRED
```

- `sslMode=REQUIRED`: encrypts the connection but does **NOT** verify the server's certificate against any CA. MITM-vulnerable. Stopgap only. The pgjdbc-equivalent is `sslmode=require`.

#### Production SSL — full certificate verification + hostname check

```properties
connection-url=jdbc:mysql://billing-replica.internal:3306/billing?sslMode=VERIFY_IDENTITY&trustCertificateKeyStoreUrl=file:///etc/trino/certs/truststore.jks&trustCertificateKeyStorePassword=changeit
```

| Parameter | What it does | Production value |
|---|---|---|
| `sslMode=VERIFY_IDENTITY` | TLS + verify cert chain against the truststore + verify the hostname in the JDBC URL matches the cert's CN/SAN. | `VERIFY_IDENTITY` |
| `trustCertificateKeyStoreUrl` | URL (with `file://` scheme) to the JKS/PKCS#12 truststore file. **NOT a PEM file path** — MySQL Connector/J cannot load PEM directly. | `file:///etc/trino/certs/truststore.jks` |
| `trustCertificateKeyStorePassword` | Password for the JKS truststore. (Default `keytool` setup uses `changeit`.) | The password you set with `keytool -storepass`. |
| `trustCertificateKeyStoreType` | Optional — `JKS` (default) or `PKCS12`. Omit unless you specifically created a PKCS#12 truststore. | (omit) |

#### Converting a PEM CA cert to a JKS truststore — the `keytool` workflow

Because MySQL Connector/J cannot load PEM directly, you must import the PEM CA cert into a JKS truststore once:

```bash
# 1. Import your PEM CA cert into a new (or existing) JKS truststore.
keytool -importcert \
  -alias MySQLCACert \
  -file /path/to/ca.pem \
  -keystore truststore.jks \
  -storepass changeit \
  -noprompt

# 2. Verify the truststore now contains the CA cert.
keytool -list -keystore truststore.jks -storepass changeit
# Should show one entry with alias "MySQLCACert" of type "trustedCertEntry".
```

The resulting `truststore.jks` is what the JDBC URL parameter `trustCertificateKeyStoreUrl=file:///...` points at. **Pick any password you want — the truststore contains only the public CA cert, no private keys — but the password is required by the JKS format.** `changeit` is the conventional placeholder; for production audit cleanliness, use a real password and store it in a Secret alongside the truststore file.

#### Mounting the JKS truststore in Kubernetes (same shape as the pgjdbc PEM mount in 2.5)

```bash
# Create a Secret from the JKS truststore file
kubectl create secret generic mysql-tls-truststore \
  --from-file=truststore.jks=./truststore.jks \
  --namespace trino
```

```yaml
# In the Trino coordinator AND worker pod specs (both need it — workers do the actual JDBC reads)
spec:
  containers:
    - name: trino
      volumeMounts:
        - name: mysql-tls-truststore
          mountPath: /etc/trino/certs
          readOnly: true
  volumes:
    - name: mysql-tls-truststore
      secret:
        secretName: mysql-tls-truststore
```

After mounting, `/etc/trino/certs/truststore.jks` is readable from every Trino pod, and `trustCertificateKeyStoreUrl=file:///etc/trino/certs/truststore.jks` resolves correctly. **Forgetting to mount on the workers (only mounting on the coordinator) is the same failure mode as in Section 2.5** — the coordinator plans the query but workers execute the JDBC reads, so workers need the truststore too.

#### Side-by-side — pgjdbc vs MySQL Connector/J SSL parameters (the asymmetry you must remember)

| Concern | PostgreSQL JDBC (pgjdbc) | MySQL Connector/J |
|---|---|---|
| Single switch to demand TLS | `ssl=true` + `sslmode=...` (two params) | `sslMode=...` (one param, camelCase) |
| Production mode (verify cert + hostname) | `sslmode=verify-full` | `sslMode=VERIFY_IDENTITY` |
| CA cert file format accepted | **PEM** (direct path via `sslrootcert=/path/to/ca.crt`) | **JKS or PKCS#12** (path via `trustCertificateKeyStoreUrl=file:///path/to/truststore.jks` + password) |
| Conversion step needed if you have PEM? | NO | YES — `keytool -importcert -file ca.pem -keystore truststore.jks` |
| Password required for the trust material? | NO (PEM has no password) | YES (`trustCertificateKeyStorePassword=...`) |
| Properties that are SILENTLY IGNORED (do not use) | (n/a) | `useSSL`, `requireSSL`, `verifyServerCertificate`, `serverSslCertificate` |

**`serverSslCertificate` warning.** Several online tutorials reference a `serverSslCertificate` JDBC parameter for MySQL — **that property does NOT exist in MySQL Connector/J.** It exists in MariaDB Connector/J only (`serverSslCert`). Pasting it into a MySQL Connector/J URL is silently ignored, and `sslMode=VERIFY_IDENTITY` will then fall back to the JVM default truststore (which does NOT contain your internal CA), causing chain verification to fail silently — your engineer believes TLS is verified; it is not.

#### Verifying SSL is actually active (on the MySQL replica)

After deploying, run a Trino query against the catalog to force a connection, then on the MySQL replica:

```sql
-- Method 1: SHOW STATUS — for the CURRENT MySQL session you are connected as.
-- Run this from a mysql client connected as trino_reader (NOT through Trino — Trino
-- does not expose SHOW STATUS results in a useful way for this check).
SHOW STATUS LIKE 'Ssl_cipher';
-- Result examples:
--   Ssl_cipher | TLS_AES_256_GCM_SHA384       <- encrypted (TLS 1.3 cipher)
--   Ssl_cipher | ECDHE-RSA-AES256-GCM-SHA384  <- encrypted (TLS 1.2 cipher)
--   Ssl_cipher | (empty)                       <- plaintext
```

> **CRITICAL — `SHOW STATUS LIKE 'Ssl_cipher'` is SESSION-SCOPED to the client running it, NOT to Trino's connection.** When you run `SHOW STATUS LIKE 'Ssl_cipher'` from a `mysql` CLI on your laptop or a jump host, you are seeing the **`mysql` client's own connection's cipher** — not Trino's connection's cipher. If the `mysql` CLI used `--ssl-mode=DISABLED` to connect, `Ssl_cipher` is empty for *that session*, which says NOTHING about whether Trino (a separate process, separate connection) is negotiating TLS. This trips up engineers who run `SHOW STATUS` from the wrong shell and conclude "Trino is plaintext" when in reality their CLI is plaintext.
>
> **To verify Trino's specific connection's cipher**, query `performance_schema.status_by_thread` joined to `performance_schema.threads`, filtered to the MySQL user Trino connects as:
>
> ```sql
> SELECT t.VARIABLE_VALUE AS Ssl_cipher
> FROM performance_schema.status_by_thread t
> JOIN performance_schema.threads th ON t.thread_id = th.thread_id
> WHERE th.PROCESSLIST_USER = '<trino_mysql_user>'   -- e.g., 'trino_reader'
>   AND t.VARIABLE_NAME = 'Ssl_cipher';
> -- Result: one row per active Trino connection, showing that connection's actual cipher.
> -- An empty/NULL VARIABLE_VALUE means THAT specific Trino connection is plaintext.
> -- A cipher string like 'TLS_AES_256_GCM_SHA384' means THAT specific Trino connection
> -- negotiated TLS 1.3.
> ```
>
> This is the **only** authoritative MySQL-side check for "is Trino actually using TLS to talk to my MySQL replica?" The `status_by_thread` table exposes per-thread session-status variables — `Ssl_cipher` is one of them. The join to `threads` filters down to the Trino user's connections specifically (filter by `PROCESSLIST_USER`; you can also filter by `PROCESSLIST_HOST` to pin down a specific Trino worker pod IP).

```sql
-- Method 2: performance_schema.threads — shows ALL connections, including Trino's,
-- with their connection type. Use this to LIST Trino connections, but do NOT use
-- CONNECTION_TYPE to infer TLS status — see the critical clarification below.
SELECT PROCESSLIST_ID, PROCESSLIST_USER, PROCESSLIST_HOST, CONNECTION_TYPE
FROM performance_schema.threads
WHERE PROCESSLIST_USER = 'trino_reader';
-- CONNECTION_TYPE column values:
--   'TCP/IP'  — the connection is a TCP socket (NOT a Unix socket). This says NOTHING
--               about whether TLS is negotiated on top of that TCP socket.
--   'SSL/TLS' — appears in some MySQL releases for compiled-in protocol switches,
--               but DOES NOT reliably indicate per-connection TLS in modern MySQL 8.x
--               — both plaintext and TLS-encrypted TCP connections commonly show
--               CONNECTION_TYPE='TCP/IP'. Use Ssl_cipher from status_by_thread (above)
--               instead — that is the authoritative per-connection TLS check.
--   'Socket'  — local Unix domain socket (will not see this for remote Trino).
```

> **CRITICAL — `CONNECTION_TYPE` in `performance_schema.threads` is NOT a reliable TLS indicator in modern MySQL.** A common engineering mistake is to query `performance_schema.threads.CONNECTION_TYPE` and conclude "if it says 'TCP/IP' then it's plaintext, if it says 'SSL/TLS' then it's encrypted." **This is wrong on MySQL 8.x.** `CONNECTION_TYPE` reports the **transport layer protocol** (TCP/IP socket vs. Unix domain socket vs. named pipe), not whether TLS is layered on top of it. **TLS-encrypted Trino connections to MySQL routinely show `CONNECTION_TYPE='TCP/IP'`** — because TLS runs ON TOP of TCP/IP, and the column reports the underlying transport. **Use `Ssl_cipher` from `performance_schema.status_by_thread` (Method 1's per-thread variant above) for the authoritative TLS check.** `CONNECTION_TYPE='TCP/IP'` alone does NOT mean plaintext. The rule is: **`Ssl_cipher` non-empty = TLS active; `Ssl_cipher` empty = plaintext.** `CONNECTION_TYPE` is for transport debugging (Unix socket vs. TCP), not for TLS verification.

> **DO NOT query `INFORMATION_SCHEMA.PROCESSLIST.SSL_TYPE`.** That column does not exist. The query fails with `ERROR 1054 (42S22): Unknown column 'SSL_TYPE' in 'field list'`. The correct tables/columns are `SHOW STATUS LIKE 'Ssl_cipher'` (CURRENT client session — NOT Trino's session) or the **`performance_schema.status_by_thread` + `performance_schema.threads` join filtered by `Ssl_cipher`** shown above (any specific Trino session). Do NOT rely on `performance_schema.threads.CONNECTION_TYPE` for TLS status — it reports transport, not TLS.

If `Ssl_cipher` is empty for `trino_reader` rows in the `status_by_thread` query above, the Trino-to-MySQL connection is plaintext despite your config — re-check the catalog file, the JDBC URL `sslMode=...` value, and that the truststore is mounted on the workers.

#### Complete production catalog example — all SSL + throughput + timeout parameters

```properties
# etc/catalog/billing_mysql.properties
connector.name=mysql
connection-url=jdbc:mysql://billing-replica.internal:3306/billing?sslMode=VERIFY_IDENTITY&trustCertificateKeyStoreUrl=file:///etc/trino/certs/truststore.jks&trustCertificateKeyStorePassword=${ENV:MYSQL_TRUSTSTORE_PASSWORD}&defaultFetchSize=1000&useCursorFetch=true&socketTimeout=60000&connectTimeout=10000
connection-user=trino_reader
connection-password=${ENV:MYSQL_PASSWORD}
```

This combines:
- **TLS** with full certificate + hostname verification (`sslMode=VERIFY_IDENTITY&trustCertificateKeyStoreUrl=...&trustCertificateKeyStorePassword=...`)
- **Throughput** (`defaultFetchSize=1000&useCursorFetch=true`) — MySQL Connector/J requires BOTH parameters to actually stream rows; `defaultFetchSize` alone is silently ignored without `useCursorFetch=true`
- **Timeouts in MILLISECONDS** (`socketTimeout=60000` = 60s, `connectTimeout=10000` = 10s) — note the unit difference from pgjdbc Section 2.5

> **PostgreSQL vs MySQL fetch-size parameter names differ — DO NOT cross-paste:**
> - PostgreSQL pgjdbc: `defaultRowFetchSize=N` (single property, row count). Works on its own.
> - MySQL Connector/J: `defaultFetchSize=N` **AND** `useCursorFetch=true` (BOTH required). Without `useCursorFetch=true`, MySQL Connector/J buffers the entire result set in client memory regardless of `defaultFetchSize`.
>
> Do not use `defaultRowFetchSize` in a MySQL connection URL — it is unknown to MySQL Connector/J and will be silently ignored. Trino will start fine, the connection will work, and you will get full result-set buffering with no warning. The symptom is OOM on Trino workers when scanning large MySQL tables.

> **Why is the truststore password sourced from an env var?** Same reason `connection-password` is — the catalog file is mounted into the Trino pod and is potentially world-readable from inside the container. Sensitive material (DB password AND JKS truststore password) should come from a Kubernetes Secret via env var, not be hardcoded in the catalog file. The Trino property-resolver supports `${ENV:VAR_NAME}` syntax for any property value.

### 2A.2 Predicate pushdown — MySQL vs PostgreSQL (the critical difference)

The MySQL connector's pushdown surface is **narrower** than the PostgreSQL connector's. The summary in Section 3 (above) makes a JDBC-wide claim about LIKE pushdown that is **PostgreSQL-only** — do not generalize it to MySQL.

#### What DOES push down to MySQL

| Predicate shape | Example | Pushes down? |
|---|---|---|
| Numeric equality | `WHERE id = 42` | YES |
| Numeric range | `WHERE amount > 100`, `BETWEEN 100 AND 500` | YES |
| Date / timestamp equality | `WHERE created_at = DATE '2026-05-01'` | YES |
| Date / timestamp range | `WHERE created_at > TIMESTAMP '2026-05-01 00:00:00'` | YES |
| NULL checks on **numeric / date** columns | `WHERE deleted_at IS NULL`, `IS NOT NULL` (where `deleted_at` is `DATETIME` / `TIMESTAMP` / numeric) | YES |
| IN-list on numeric / date | `WHERE id IN (1, 2, 3)` | YES |

#### What does NOT push down to MySQL — and silently runs as in-memory filtering on Trino workers

| Predicate shape | Example | Pushes down? | What Trino does instead |
|---|---|---|---|
| **VARCHAR / CHAR equality** | `WHERE status = 'active'` | **NO** | Trino pulls the whole table over JDBC, filters in worker memory |
| **LIKE — any pattern** | `WHERE name LIKE 'foo%'` | **NO** | Same — full JDBC pull, then in-memory filter |
| **IN-list on VARCHAR** | `WHERE status IN ('paid', 'pending')` | **NO** | Same |
| **IS NULL / IS NOT NULL on VARCHAR / CHAR** | `WHERE status IS NULL`, `WHERE name IS NOT NULL` (textual column) | **NO** | Same — the MySQL connector treats `IS NULL`/`IS NOT NULL` as a **textual predicate** on a textual column, which falls under the connector's blanket rule "any predicates on textual columns are not pushed." Trino fetches all rows, then filters for null in memory. |
| **ILIKE** | (n/a — MySQL VARCHAR is case-insensitive by default on most collations) | n/a | n/a |

> **IS NULL / IS NOT NULL pushdown follows the column type, not the operator.** On a `BIGINT` or `DATETIME` column, `IS NULL` pushes down (it lives in the first table). On a `VARCHAR` or `CHAR` column, it does NOT push down — because the official MySQL connector rule is "any predicates on textual columns are not pushed," and that rule includes NULL checks. This is the same blanket restriction that covers VARCHAR equality, LIKE, and IN-lists on text columns. If you need to scan a MySQL table for missing values in a text column at scale, pair the `IS NULL` with a pushing date / numeric predicate (same workaround as the next subsection) so MySQL ships fewer rows back.

> **CRITICAL — VARCHAR join keys break dynamic-filter pushdown for cross-catalog joins with MySQL too.** If you join Iceberg (or Postgres) to MySQL on a VARCHAR column, the IN-list that Trino's dynamic-filtering machinery derives from the build side will **NOT be pushed to MySQL** — for the exact same collation-correctness reason as static VARCHAR predicates. Pushing a `WHERE user_id IN ('a1', 'a2', ...)` derived from DF could match different rows in MySQL than in Trino because MySQL's default collation (e.g., `utf8mb4_0900_ai_ci`) is case-insensitive and accent-insensitive while Trino's VARCHAR comparison is bytewise. The MySQL connector refuses the push to avoid silent correctness bugs. Effect at runtime: Trino pulls **all rows from the MySQL table over JDBC** and applies the DF filter locally on Trino workers — exactly the failure mode you were trying to avoid with DF. **For dynamic filtering to actually push an IN-list to MySQL, the join key must be a numeric type (BIGINT, INT, DECIMAL) or a DATE/TIMESTAMP type.** If your application schema uses VARCHAR surrogate keys (e.g., string UUIDs stored as `VARCHAR(36)`), either (a) add a parallel BIGINT or UUID-typed column to join on, (b) keep the dimension data in Postgres instead of MySQL (the Postgres connector pushes VARCHAR equality by default), or (c) accept that the MySQL side will be scanned in full and constrain the load with a non-VARCHAR co-predicate (a date range, an `id BETWEEN` clause, etc.).

#### Aggregate pushdown is a SEPARATE mechanism from predicate pushdown — they can succeed or fail independently

A frequent surprise: engineers expect a query to be **either** fully pushed down **or** not pushed down at all. The MySQL connector does not work that way. Aggregate pushdown (`COUNT`, `SUM`, `AVG`, `MIN`, `MAX`, `GROUP BY`) and predicate pushdown are evaluated independently — one can succeed while the other fails.

```sql
SELECT COUNT(*)
FROM billing_mysql.billing.invoices
WHERE status = 'paid'                       -- VARCHAR predicate — does NOT push down
  AND invoice_date >= DATE '2026-01-01';    -- DATE range — DOES push down
```

What actually happens:

1. Trino splits the WHERE clause. The `invoice_date >= DATE '2026-01-01'` filter pushes down to MySQL. The `status = 'paid'` filter stays in Trino.
2. Trino then evaluates whether `COUNT(*)` can be pushed down. Because MySQL is still going to ship rows back (not a pre-aggregated count), and Trino still has to apply the `status` filter on the workers, the COUNT is computed **in Trino** on the post-filter result — not by MySQL.
3. The net effect: MySQL applies the date filter, ships the matching rows over JDBC, Trino applies the status filter, then Trino counts.

The "aggregate pushdown" optimization (where MySQL returns a single pre-computed COUNT instead of rows) only kicks in when **all** of the query's WHERE predicates also push down. If any predicate stays in Trino, the aggregate cannot be safely pushed — because MySQL doesn't know the final filtered row set.

By contrast, this query DOES push the aggregate all the way down:

```sql
SELECT COUNT(*)
FROM billing_mysql.billing.invoices
WHERE invoice_date >= DATE '2026-01-01';    -- all predicates push down → aggregate can push too
```

MySQL returns one row containing the count. Trino does no aggregation work.

**Concrete contrast — three nearly identical-looking queries, three different execution stories:**

| Query | Predicate pushdown | COUNT pushdown | What MySQL ships back over JDBC |
|---|---|---|---|
| `SELECT COUNT(*) FROM billing_mysql.billing.invoices` (no WHERE) | n/a (no predicates) | **YES — pushes to MySQL** | **1 row, ~8 bytes** (just the count integer) |
| `SELECT COUNT(*) FROM billing_mysql.billing.invoices WHERE invoice_date >= DATE '2026-01-01'` (only DATE predicate — DOES push) | YES (DATE range pushes) | **YES — pushes to MySQL** | **1 row, ~8 bytes** (MySQL applies the date filter, then computes COUNT server-side) |
| `SELECT COUNT(*) FROM billing_mysql.billing.invoices WHERE status = 'paid' AND invoice_date >= DATE '2026-01-01'` (mixed — VARCHAR does NOT push) | PARTIAL (date pushes, status stays in Trino) | **NO — stays in Trino** | **All rows matching the date filter** (could be millions); Trino applies `status = 'paid'` in memory, then counts |

The rule made concrete: COUNT (or any aggregate) can only push down when **every** WHERE predicate also pushes. The instant one predicate becomes a residual `Filter` (or `ScanFilterProject`) sitting above the `TableScan` in the plan tree, the aggregate cannot ride along — because MySQL doesn't know which rows will survive the residual filter, so it can't pre-compute a count for Trino. Trino must pull the unfiltered-by-status rows, apply the residual filter, then aggregate the survivors.

**Always verify with `EXPLAIN (TYPE DISTRIBUTED)`.** If the plan shows an `Aggregate` node above the `TableScan`, Trino is counting. If the `TableScan` node itself shows the aggregate embedded (the `aggregations` field is non-empty inside the table scan), MySQL computed the count and returned a single value. Do not assume the optimizer's behavior based on the query shape — read the plan.

This is the **single biggest behavioral surprise** when switching from the PostgreSQL connector to the MySQL connector:

- **PostgreSQL connector**: pushes **VARCHAR equality (`=`, `!=`), `IN`-lists on VARCHAR, and `IS NULL` / `IS NOT NULL` on VARCHAR by default**. **Anchored LIKE patterns** (`LIKE 'foo%'`) **may push down on PostgreSQL for standard-collation columns** — behavior is **collation-dependent and more conservative than equality pushdown**. The pushdown can be suppressed by non-default collation on the Postgres column, by ICU collation, or by `COLLATE` clauses in the query, even when the pattern shape is anchored. **Always verify with `EXPLAIN (TYPE DISTRIBUTED)` before relying on LIKE pushdown** — do not assume LIKE the way you assume equality. **VARCHAR RANGE predicates (`>`, `>=`, `<`, `<=`, `BETWEEN`) do NOT push down by default** — they require the experimental flag `postgresql.experimental.enable-string-pushdown-with-collate=true` (catalog) / session `enable_string_pushdown_with_collate` (collation-correctness risk; can disable Postgres index usage; see Section 3.3). **Do NOT generalize "VARCHAR predicates don't push down" to PostgreSQL** — that blanket claim is only accurate for range predicates on VARCHAR, not for equality, IN, or IS NULL. Describe these as the current Trino 467 default behavior.
- **MySQL connector**: **NO VARCHAR predicates push down at all** — equality, IN-lists, LIKE patterns, and IS NULL/IS NOT NULL on VARCHAR/text columns all stay in Trino memory. There is no exception, no flag to enable, no collation workaround inside the connector. This is the **key MySQL/PostgreSQL pushdown difference**.

#### Large IN-lists are silently compacted to a range — `domain-compaction-threshold`

A subtle pushdown-correctness behavior that catches engineers off-guard: when an IN-list on a numeric or date column exceeds **`domain-compaction-threshold`** (default: **256 entries** for JDBC connectors including MySQL and PostgreSQL — verified against the Trino 481 connector docs at trino.io/docs/current/connector/mysql.html and trino.io/docs/current/connector/postgresql.html), Trino compacts the IN-list into a `BETWEEN min AND max` range before pushing it to MySQL. Older docs and blog posts often quote `1000` or `32`; those are out-of-date or refer to non-JDBC connectors (Ignite/ClickHouse still default to `1000`).

```sql
-- Suppose `id` is BIGINT and the IN-list has 5000 entries.
SELECT * FROM billing_mysql.billing.invoices
WHERE id IN (1, 2, 3, ..., 5000);   -- 5000 entries > 256 threshold
```

What actually reaches MySQL:

```sql
-- Trino sends this to MySQL (NOT the original 5000-element IN-list):
SELECT ... FROM invoices WHERE id BETWEEN 1 AND 5000;
```

Implications:

- **Correctness is preserved** — Trino re-applies the original IN-list filter on its workers after MySQL returns rows. The final result is correct.
- **More rows ship over JDBC than you expect.** MySQL returns every row whose `id` is in the range `[1, 5000]`, even IDs not in your original list. If the original list was sparse (e.g., `1, 999, 5000`), MySQL ships ~5000 rows; if dense, MySQL ships ~5000 rows. Trino then filters down to the real matches.
- **The threshold is per-catalog-tunable.** Raise it per catalog in `etc/catalog/billing_mysql.properties`:
  ```properties
  domain-compaction-threshold=10000
  ```
  Or per session for a single query (use the catalog-prefixed session form for JDBC connectors):
  ```sql
  SET SESSION billing_mysql.domain_compaction_threshold = 10000;
  ```
- **When to raise it**: if your IN-list is moderately large (a few thousand) and the values are sparse across a wide id range, raising the threshold lets Trino push the full IN-list and avoid the over-fetch.
- **When NOT to raise it**: if your IN-list is enormous (tens of thousands), pushing the full list as a literal IN clause may exceed MySQL's `max_allowed_packet` or blow up query parse time on the MySQL side. The default of 256 is conservative for a reason.
- **Verify with `EXPLAIN (TYPE DISTRIBUTED)`** if your IN-list is large. The `TableScan` node's `constraint` field shows whether MySQL is receiving the full IN-list or a compacted range — and a separate `Filter` node above the scan tells you Trino is doing the residual re-filtering.

#### There is NO `mysql.experimental.enable-string-pushdown-with-collate` property

The `experimental.enable-string-pushdown-with-collate` flag from Section 3.3 is **PostgreSQL-only**. It does not exist for the MySQL connector. Adding it to `billing_mysql.properties` **may cause catalog startup failure or be ignored depending on the connector version — verify by checking Trino coordinator logs after catalog reload**. **Do not use it for MySQL.** This is a common copy-paste mistake when adopting MySQL after running with PostgreSQL.

#### How to verify a predicate is (or isn't) pushing down

The verification recipe is the same as Section 3.4:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM billing_mysql.public.invoices
WHERE status = 'paid';
```

Look at the plan tree:

- **Pushdown SUCCEEDED**: predicate is embedded inside the `TableScan` node's `constraint` field. No separate filter node above.
- **Pushdown FAILED**: a `ScanFilterProject` (or standalone `Filter`) node sits **ABOVE** the `TableScan`, with the predicate inside that filter node. This means MySQL returned the whole table and Trino is filtering in worker memory after the JDBC fetch — the slow path.

For a VARCHAR equality on MySQL, you will almost always see the second pattern. That is expected; the workaround is below.

#### Workaround — pair a non-pushing VARCHAR filter with a pushing numeric/date filter

The MySQL connector cannot push your VARCHAR filter, but it CAN push a numeric or date filter. The pattern is: **add a selective numeric or date predicate that DOES push down, so MySQL ships fewer rows back. Then Trino's in-memory VARCHAR filter operates on a small result set instead of the whole table.**

```sql
-- BAD: WHERE status = 'paid' does NOT push to MySQL.
-- MySQL ships ALL rows of `invoices` over JDBC; Trino filters in memory.
SELECT *
FROM billing_mysql.public.invoices
WHERE status = 'paid';

-- GOOD: add a date predicate that DOES push down. MySQL only ships rows from
-- the last 26 days. Trino then applies the status filter in memory on a much
-- smaller result set.
SELECT *
FROM billing_mysql.public.invoices
WHERE created_at >= DATE '2026-05-01'   -- pushes down to MySQL (date range)
  AND status = 'paid';                  -- filtered in Trino memory on smaller set
```

For any query against a MySQL table whose primary filter is a VARCHAR, add a numeric (PK or FK) or date filter alongside it. This is the single most effective MySQL federation performance technique.

#### MySQL emits 1 split per table — single-JDBC-connection scan, no worker parallelism

> **The MySQL connector emits exactly ONE split per non-partitioned table scan.** There is no partition metadata the MySQL connector knows how to translate into multiple Trino splits — unlike Iceberg (one split per Parquet file) or partition-aware JDBC sources. Concretely:
>
> - **One split = one Trino worker task = one JDBC connection = one thread** reading all rows from the MySQL table sequentially.
> - **Exactly one Trino worker** does the JDBC read no matter how large your cluster is. If you have 20 workers, 19 of them are idle for this scan.
> - **A federation query cannot leverage Trino's multi-worker parallelism for the MySQL scan stage.** All data must pass through a single JDBC connection bottleneck (typically 50K–200K rows/sec depending on row width and network).
>
> **Same single-split model as the PostgreSQL connector**, but with one further asymmetry: the PostgreSQL connector at least exposes the (experimental) `postgresql.parallelism-type` tuning knob in newer Trino releases as a potential way to parallelize a single Postgres table scan (e.g., by min/max partitioning), and Starburst Enterprise's commercial PostgreSQL connector adds `partition-column` / `partition-count`. **The MySQL connector has NO equivalent in OSS Trino 467** — neither an OSS experimental property nor a Starburst Enterprise property. For MySQL, the multiplier is always 1, always, end of story.
>
> **The worst-case shape — combine zero VARCHAR pushdown with the 1-split rule.** A large MySQL table under a text-column filter (`WHERE status = 'paid'`, `WHERE name LIKE 'foo%'`, etc.) hits BOTH limitations at once:
> - **No VARCHAR pushdown**: MySQL ships ALL rows back over JDBC because the filter cannot be applied server-side.
> - **One split, one connection**: those millions of rows stream through a single JDBC connection on a single Trino worker thread.
>
> The result: a 50-million-row MySQL table with a `WHERE status = 'active'` filter streams **all 50 million rows over one JDBC connection** before Trino can apply the status filter in worker memory. There is no parallel scan to hide the cost behind, and no server-side filter to reduce what crosses the wire. This is the **worst-case performance shape for federated MySQL queries**, and it is the reason Section 2A.5 recommends snapshotting hot MySQL tables to Iceberg if the same scan runs repeatedly. See Sections 2A.5 (parallelism options) and 4.4 (the JDBC single-split model in the PostgreSQL context — same shape, same root cause).

### 2A.3 Data type mapping — important differences from PostgreSQL

| MySQL type | Trino type | Notes |
|---|---|---|
| `INT`, `INTEGER` | `INTEGER` | |
| `BIGINT` | `BIGINT` | |
| `VARCHAR(n)`, `CHAR(n)` | `VARCHAR(n)` | |
| `TEXT`, `LONGTEXT` | `VARCHAR(max)` | Unbounded VARCHAR — large reads can blow memory |
| `DATETIME(n)` | `TIMESTAMP(n)` | **No timezone** — naive wall-clock value |
| `TIMESTAMP(n)` | `TIMESTAMP(n) WITH TIME ZONE` | **Timezone-aware** in MySQL semantics |
| `DATE` | `DATE` | |
| `TINYINT(1)` | `BOOLEAN` | MySQL's boolean convention — `TINYINT(1)` is the idiom |
| `FLOAT`, `DOUBLE` | `REAL`, `DOUBLE` | |
| `DECIMAL(p,s)` | `DECIMAL(p,s)` | |
| `JSON` | `JSON` | |

The two things to internalize:

1. **`DATETIME` is timezone-naive, `TIMESTAMP` is timezone-aware** — this is a MySQL convention that propagates straight through to the Trino type. PostgreSQL has the same split (`TIMESTAMP WITHOUT TIME ZONE` vs `TIMESTAMPTZ`), but the MySQL keywords are easy to mistake because in many other databases `TIMESTAMP` is naive.
2. **`TINYINT(1)` is MySQL's boolean.** If you see a `BOOLEAN` column in Trino but the underlying MySQL column is `TINYINT`, that is correct — the connector maps it for you.

> **CRITICAL — `CAST(naive_ts AS TIMESTAMP WITH TIME ZONE)` attaches the SESSION timezone, NOT unconditionally UTC.** This is the single most common factual slip when people describe how to "convert" a MySQL `DATETIME` (naive) into a comparable timezone-aware value for a federated join.
>
> The cast uses whatever `current_timezone()` returns for the current Trino session. It only equals UTC when the session timezone happens to be UTC. In an on-prem Trino cluster where `-Duser.timezone` may vary between nodes, or where a client has issued `SET TIME ZONE 'America/New_York'` (or the JDBC/HTTP client default differs from the cluster JVM default), the cast result can be a **different attached zone** — and the resulting `TIMESTAMP WITH TIME ZONE` will compare differently in a join even though the wall-clock value looks identical in `SELECT` output.
>
> **Safer alternatives — use these instead of bare CAST:**
> - **`naive_ts AT TIME ZONE 'UTC'`** — operator form. Attaches UTC to the naive wall-clock value. Unambiguous in simple expressions; operationally equivalent to `with_timezone` for the "treat this MySQL DATETIME as UTC" use case. In complex expressions, the operator's precedence can be surprising — wrap it in parentheses.
> - **`with_timezone(naive_ts, 'UTC')`** — function form. Takes a naive `TIMESTAMP` and a zone-name string, returns a `TIMESTAMP WITH TIME ZONE` with that zone **directly assigned**, with **no session-timezone involvement** in the assignment. Useful inside complex expressions where operator precedence of `AT TIME ZONE` is hard to reason about, or inside `CASE`/coalesce branches where the operator form needs extra parentheses. **Slightly preferred over `AT TIME ZONE` in complex expressions** because the function form is unambiguous and avoids operator-precedence surprises.
>
> **Precision distinction (subtle but operationally equivalent in practice):** when applied to a naive `TIMESTAMP` (the MySQL `DATETIME` case):
> - `with_timezone(naive_ts, 'UTC')` directly assigns UTC as the attached timezone, with no session-TZ involvement at any step. This is the most explicit, session-independent choice.
> - `naive_ts AT TIME ZONE 'UTC'` for a naive TIMESTAMP also attaches UTC. The behavior is equivalent to `with_timezone` in practice for "treat this MySQL DATETIME as UTC," but the operator form can have precedence surprises in complex expressions (e.g., when combined with arithmetic, CAST, or coalesce). Both are correct; prefer `with_timezone` in complex expressions to avoid the precedence trap.
>
> If you must use CAST, first verify the session timezone is UTC:
> ```sql
> SELECT current_timezone();   -- must return 'UTC' before you trust the CAST
> ```
> Otherwise prefer `AT TIME ZONE 'UTC'` or `with_timezone(ts, 'UTC')` — both are unaffected by session timezone and behave the same on every Trino node regardless of JVM config.

### 2A.4 Timezone behavior — the key gotcha

> **THE ONE-LINER YOU MUST INTERNALIZE (read this first, before anything else in this section):**
>
> **Changing the Trino JVM `-Duser.timezone` setting will NOT fix a `DATETIME`-vs-`TIMESTAMPTZ` join mismatch.** The fix MUST be SQL-level — use `AT TIME ZONE 'UTC'` or `with_timezone(ts, 'UTC')` in the query (or in a view that wraps the MySQL table). JVM config is NOT the lever; SQL is.
>
> Why this lives at the top of the section: when a join produces wrong rows because one side is a naive `TIMESTAMP` (MySQL `DATETIME`) and the other is `TIMESTAMP WITH TIME ZONE` (Postgres `TIMESTAMPTZ`), the first instinct of every engineer is to "fix it once at the JVM level so we don't have to touch every query." That instinct is wrong on this stack. Setting `-Duser.timezone=UTC` in `jvm.config` changes how naive values are interpreted at JDBC connection time, but it does NOT change the **type** of the column — a `DATETIME` column is still a naive `TIMESTAMP` in Trino, and joining a naive `TIMESTAMP` against a `TIMESTAMP WITH TIME ZONE` either fails type-checking or produces silently wrong results depending on the surrounding expression. The fix lives in the SQL.

MySQL's JDBC driver **mirrors the JVM's default timezone onto the MySQL session** when opening each connection. Concretely:

- If Trino's JVM is set to UTC (the typical production setup — see `-Duser.timezone=UTC` in `jvm.config`), every MySQL JDBC connection silently runs `SET time_zone = 'UTC'` at connect time.
- MySQL `TIMESTAMP` columns (timezone-aware in MySQL semantics) are read and written in UTC.
- MySQL `DATETIME` columns (timezone-naive) are read as the literal wall-clock value with no conversion applied.

#### Cross-catalog timestamp join gotcha

When you join `billing_mysql.invoices.paid_at` (MySQL `TIMESTAMP`, becomes Trino `TIMESTAMP WITH TIME ZONE`) against `app_pg.orders.completed_at` (Postgres `TIMESTAMPTZ`, also Trino `TIMESTAMP WITH TIME ZONE`), the comparison usually works correctly **if both databases store UTC**. But if your MySQL team uses `DATETIME` (naive) to store what they intend as UTC, while Postgres uses `TIMESTAMP WITHOUT TIME ZONE` for the same intent, both columns appear as Trino `TIMESTAMP` (no time zone) and the join compiles and returns "correct-looking" rows — without any timezone validation.

**Best practice**: document the timezone convention for every timestamp column in every catalog. Before relying on a federated timestamp join in production, pick one known row from each side and verify manually that the timestamps match what you expect. There is no Trino-level safety net here.

> **Changing the Trino JVM `user.timezone` setting will NOT fix a `DATETIME`-vs-`TIMESTAMPTZ` join mismatch.** The fix must be **SQL-level** — attach a timezone explicitly with `AT TIME ZONE 'UTC'` or `with_timezone(ts, 'UTC')` in the query (or in a view that wraps the MySQL table). Tweaking `-Duser.timezone=UTC` in `jvm.config` changes how naive values are interpreted at connection time, but it does not change the **type** of the column — a `DATETIME` column is still a naive `TIMESTAMP` in Trino, and joining a naive `TIMESTAMP` against a `TIMESTAMP WITH TIME ZONE` either fails type-checking or produces silently wrong results depending on the surrounding expression. JVM config is not the lever; SQL is.

### 2A.5 Connection pooling — same situation as PostgreSQL, different tool

OSS Trino 467 has **no native connection pooling for the MySQL connector either**. The PostgreSQL section 8.2 mitigations apply with one substitution: **use ProxySQL instead of PgBouncer**. ProxySQL is the MySQL-native connection pooler — it sits between Trino and MySQL exactly the way PgBouncer sits between Trino and Postgres in section 8.2A.

> **Caveat (trinodb/trino #18279):** ProxySQL's host-group-based routing doesn't map cleanly to Trino's per-schema MySQL routing. If your MySQL connector queries multiple schemas on the same host, test ProxySQL routing rules carefully before production deployment — a routing rule that works fine for a single schema can misroute or split connections in unexpected ways when Trino issues queries across schemas in the same session.

> **CRITICAL CALLOUT — Trino does NOT have Spark JDBC's parallel-read options.**
>
> If you've used Spark JDBC with `partitionColumn` / `lowerBound` / `upperBound` / `numPartitions`, you might expect similar options in the Trino MySQL connector. **They do not exist.** Trino's MySQL connector always creates **one split per non-partitioned table scan** — one JDBC connection, one worker, no parallelism. There is no per-catalog property you can add to enable parallel JDBC reads.
>
> The specific names below are **Spark JDBC options, NOT Trino MySQL connector options**:
> - `partition-column` (or `partitionColumn`)
> - `partition-num-partitions` (or `numPartitions`)
> - `partition-lower-bound` (or `lowerBound`)
> - `partition-upper-bound` (or `upperBound`)
>
> If you add any of these to `etc/catalog/billing_mysql.properties`, Trino will reject them at coordinator startup with "Configuration property '...' was not used" or a similar unknown-property error. They are **not** part of the OSS Trino 467 MySQL connector. This is a hard limitation tracked at [trinodb/trino#389](https://github.com/trinodb/trino/issues/389) — an open feature request since 2019 with no implementation in OSS.
>
> **To achieve parallel reads from MySQL data in Trino, your real options are:**
> 1. **Snapshot MySQL into Iceberg** (nightly or hourly via Spark, Trino CTAS, or a CDC pipeline). Once the data is in Iceberg on MinIO, Trino can parallelize the read across as many workers as you have. This is the production-correct path for any MySQL table you scan repeatedly.
> 2. **Pre-aggregate / denormalize on the MySQL side** so that the federation query ships fewer rows per scan. A view in MySQL that does the grouping reduces JDBC bytes shipped, and the connector will read the reduced view in one split.
> 3. **Use the MySQL connector for small dimension tables only** (rule of thumb: under ~5M rows, or any table that fits comfortably in a single-threaded scan). Single-split reads are fast enough at this scale.
> 4. **Lean on dynamic filtering** (see the next subsection) when joining a large Iceberg fact to a small MySQL dimension. Dynamic filtering means MySQL is read once (small build side), and the resulting IN-list prunes the parallelizable Iceberg side. This is the recommended pattern in this stack.

**Restating in narrative form:** the OSS Trino 467 MySQL connector does NOT support partitioned table scans. Every MySQL table scan uses a single split = single JDBC connection per query, regardless of table size. Parallel-read partitioning is supported for the Oracle JDBC connector and (separately) in Starburst Enterprise's PostgreSQL connector, but NOT for the MySQL connector in OSS Trino 467. The Spark JDBC property names listed in the callout above are not Trino properties — pasting them into the catalog file causes a startup failure, not silent acceptance.

The one-split-one-connection model from Section 4.4 also applies: a non-partitioned MySQL table produces 1 split → 1 JDBC connection per query. There is no parallel scan of a single MySQL table.

#### Dynamic filtering: the primary production lever for Iceberg-fact × MySQL-dimension joins

Because MySQL is stuck at one split per table scan, the production strategy for "huge Iceberg fact table joined to small MySQL dimension table" is **not** to try to parallelize MySQL. It is to make sure MySQL is the **build side** of the join (read once, single connection, small) and let dynamic filtering push the resulting IN-list back into the parallelizable Iceberg probe scan. This sidesteps MySQL's single-split limitation by design.

> **Beginner gloss — "build side" and "probe side" in two sentences.** A hash join in Trino has two sides:
> - **Build side** = the **smaller table** in the join. Trino reads it **fully into a hash table in memory** before the join starts. Whichever side is smaller (or has the more selective WHERE clauses) becomes the build side.
> - **Probe side** = the **larger table** being scanned. Trino **streams through it row-by-row** and **looks up each row's join key in the build-side hash table** to find matches.
>
> When the build-side scan finishes, Trino knows the complete set of join-key values that appeared in the build side. It can then **derive an IN-list (or BETWEEN range) of those join keys and push it as a filter INTO the probe-side scan** so the probe never reads rows whose join key isn't in the build side. **This push-the-build's-keys-into-the-probe-scan mechanism is dynamic filtering.**

How it works:

- MySQL is the build side (Trino reads it first, single JDBC connection, single split — fine, because the dimension table is small and the whole result fits in Trino's in-memory hash table).
- After the MySQL scan completes, Trino derives an IN-list (or BETWEEN min/max range if the IN-list exceeds `domain-compaction-threshold`) of the join-key values seen on the build side.
- Trino pushes that IN-list back to the Iceberg probe-side scan, which can then **skip entire Parquet files** whose min/max statistics don't overlap the IN-list. The huge side of the join (the probe) now reads only the files whose join keys could possibly match.

Net effect: MySQL's 1-split limitation **stops mattering** once dynamic filtering is in play. You pay for one single-threaded MySQL scan of the dimension table; you avoid scanning hundreds of millions of fact-table rows.

> **The cruel catch for MySQL specifically — even a perfect build-side IN-list doesn't help if the probe is MySQL with a VARCHAR join key.** Reverse the scenario: suppose Iceberg is the build (small filtered dimension), MySQL is the probe (large fact). Trino's dynamic filtering machinery still **generates** the IN-list from the Iceberg build side just fine. But when Trino tries to push that IN-list as a server-side filter into the MySQL probe scan, **MySQL won't apply it as a server-side filter on a VARCHAR join column** — because of the blanket VARCHAR-pushdown block described in Section 2A.2 (collation-correctness concerns). So MySQL ships **all rows of the probe table back over JDBC anyway**, and Trino applies the dynamic-filter IN-list locally in worker memory after the fetch. The build-side IN-list was perfect; the probe-side connector just refused it. This is the **fundamental reason** the strategy for MySQL federation is "make MySQL the build, never the probe" — and why a VARCHAR join key wedges you into the worst case regardless of which side MySQL is on.

**Key catalog properties for dynamic filtering** (set in `etc/catalog/billing_mysql.properties` for the MySQL side and `etc/catalog/iceberg.properties` for the Iceberg side):

| Property | Default | Effect | When to change |
|---|---|---|---|
| `dynamic-filtering.enabled` | `true` | Master switch for dynamic filtering. | Rarely needs changing — leave at `true`. |
| `<connector>.dynamic-filtering.wait-timeout` (**PROBE-side connector property** — set in the catalog of the side that *receives* the DF, never the build side. Iceberg/Hive/Delta use the connector-name-prefixed form; PostgreSQL/MySQL JDBC connectors use the **bare** form `dynamic-filtering.wait-timeout` — see Section 5.4 for the per-connector property name table.) | **20s** for JDBC connectors (MySQL, PostgreSQL), **1s** for Iceberg / Hive / Delta Lake | How long the **probe-side scan** waits before generating splits, giving the build side time to finish and publish its filter. **The probe is the catalog being filtered, not the catalog producing the filter.** | The 1-second Iceberg default is the #1 reason DF "didn't fire" in Iceberg-probe + JDBC-build patterns. For batch federation jobs where MySQL is the build, raise the **Iceberg side** to 15–30s (set `iceberg.dynamic-filtering.wait-timeout=20s` in `etc/catalog/iceberg.properties` — NOT in `billing_mysql.properties`; MySQL is the build side and does not wait). See the critical callout at the top of Section 5.4. |
| `domain-compaction-threshold` | **256** | If the IN-list derived from the build side exceeds this many entries, Trino compacts it to `BETWEEN min AND max` (which returns extra rows on the probe side but avoids huge IN clauses). | Raise to 1024+ if your dimension table regularly produces 300+ distinct join keys and you want to keep the precise IN-list pushdown. Set per-catalog in the JDBC connector's properties file. |

**Important constraint — VARCHAR join keys break this pattern on MySQL.** As described in Section 2A.2, the MySQL connector refuses to push VARCHAR predicates (including dynamic-filter IN-lists) because of collation-correctness concerns. For dynamic filtering to actually push to MySQL, **the join key must be a numeric type (BIGINT, INT, DECIMAL) or DATE/TIMESTAMP**. If your dimension uses a VARCHAR surrogate key (e.g. UUID stored as `VARCHAR(36)`), add a parallel numeric key column to join on, or keep that dimension in Postgres instead (the Postgres connector pushes VARCHAR equality by default).

**For verification**, use `EXPLAIN ANALYZE VERBOSE` on the federated query — the output shows (a) the dynamic-filter wait time and (b) the actual IN-list or BETWEEN range that was applied to the probe scan. See Section 5.3 and Section 5.4 for the full verification recipe.



**Peak JDBC connection formula for MySQL (correct form):**

```
Peak JDBC connections to MySQL ≈ concurrent_federation_queries × mysql_tables_per_query × 1
```

The **×1** is because an unpartitioned MySQL table always produces exactly 1 Trino split = 1 JDBC connection per query. So with `hardConcurrencyLimit = 10` (resource group) and 2 MySQL tables per query, peak MySQL connections = **10 × 2 × 1 = 20 connections**. There is no "splits_per_table" multiplier to include — that multiplier only applies to connectors that support parallel splits (Oracle, Iceberg), not to OSS Trino 467's MySQL or PostgreSQL connectors.

The reason engineers sometimes see "dozens of connections" to MySQL is typically **concurrent queries stacking up** (multiple users or dashboards hitting Trino simultaneously, each opening its own connection), NOT a single query opening multiple MySQL connections. If you see 60 connections to your MySQL replica, the cause is almost always 30 concurrent Trino queries each scanning 2 MySQL tables — not one query splitting into 60 parallel reads.

The standard MySQL connection-bounding stack is therefore:

1. **ProxySQL in front of MySQL** — gives Trino a small pool of long-lived connections to multiplex over.
2. **MySQL role-level connection cap** — `CREATE USER trino_reader@'%' ... WITH MAX_USER_CONNECTIONS 20;` (defense in depth).
3. **Trino resource groups** — cap concurrent queries that touch `billing_mysql` (see Section 8.2 C — same mechanism, different catalog regex).
4. **MySQL `max_execution_time` session var** — MySQL's equivalent of Postgres `statement_timeout`. **Unit is MILLISECONDS** (e.g., `SET GLOBAL max_execution_time = 300000` for a 5-minute limit — NOT `300`, which would set 300 ms and kill every query instantly). Set it on the read replica.
   > **Scope warning — `max_execution_time` applies only to SELECT statements**, not to INSERT/UPDATE/DELETE/MERGE. If you are using Trino to write back into MySQL (Section 2A.8) and you need to bound write lock duration (preventing a runaway Trino UPDATE from holding MySQL locks indefinitely), use `innodb_lock_wait_timeout` instead:
   > ```sql
   > -- MySQL server-side: bound how long a write waits to acquire a lock (default 50s)
   > SET GLOBAL innodb_lock_wait_timeout = 300;  -- 300 seconds
   > ```
   > `innodb_lock_wait_timeout` is in **SECONDS** (not milliseconds — different unit convention from `max_execution_time`). It controls how long an InnoDB write will wait for a row/table lock before erroring with `ERROR 1205 (HY000): Lock wait timeout exceeded`. For server-side cancellation of long-running write statements themselves, MySQL has no built-in equivalent of `max_execution_time` for writes — use `pt-kill` (Percona Toolkit) or a cron-driven `KILL QUERY <id>` against `INFORMATION_SCHEMA.PROCESSLIST` for write traffic.

### 2A.6 `system.query()` passthrough — same as PostgreSQL

When MySQL has a function or syntax that Trino does not expose (e.g., `CURDATE()`, `GROUP_CONCAT`, recursive CTEs with MySQL-specific syntax), use the connector's `system.query` table function to send the SQL directly to MySQL:

```sql
SELECT *
FROM TABLE(billing_mysql.system.query(
  query => 'SELECT customer_id, GROUP_CONCAT(invoice_id) AS invoice_ids
            FROM invoices
            WHERE DATE(created_at) = CURDATE()
            GROUP BY customer_id'
));
```

The query runs server-side on MySQL; Trino receives the result set as-is. Same usage patterns and same trade-offs as the PostgreSQL `system.query` passthrough — see the equivalent PostgreSQL section.

### 2A.7 One-page MySQL vs PostgreSQL cheat sheet

| Concern | PostgreSQL connector | MySQL connector |
|---|---|---|
| VARCHAR equality (`=`, `!=`) pushdown | **YES** (default) | **NO** |
| VARCHAR `IS NULL` / `IS NOT NULL` pushdown | **YES** (default) | **NO** (text column NULL checks stay in Trino) |
| Anchored LIKE `'foo%'` pushdown | **MAYBE** — pushes for standard-collation columns; collation-dependent; verify with EXPLAIN | **NO** |
| VARCHAR RANGE (`>`, `<`, `<=`, `>=`, `BETWEEN`) pushdown | **NO** by default — requires `postgresql.experimental.enable-string-pushdown-with-collate=true` (experimental — collation-correctness risk) | **NO — no equivalent flag exists for MySQL** |
| ILIKE pushdown | NO | n/a (MySQL collations are usually case-insensitive) |
| Numeric / date equality and range pushdown | YES | YES |
| IN-list pushdown | YES (numeric, date, **AND VARCHAR**) | YES (numeric, date only — **NOT VARCHAR**) |
| Native connection pooling in OSS Trino 467 | NO — use PgBouncer | NO — use **ProxySQL** |
| Per-split JDBC model | 1 split → 1 connection | 1 split → 1 connection (same) |
| Timezone-naive timestamp column | `TIMESTAMP WITHOUT TIME ZONE` | `DATETIME` |
| Timezone-aware timestamp column | `TIMESTAMPTZ` | `TIMESTAMP` (yes, the names are inverted vs Postgres intuition) |
| Boolean idiom | native `BOOLEAN` | `TINYINT(1)` |
| Passthrough function | `system.query()` | `system.query()` (identical API) |
| Server-side timeout property | `statement_timeout` (Postgres unit: milliseconds as string or duration, e.g., `'5min'` or `'300000'`) | `max_execution_time` (MySQL session var; **unit: milliseconds** — `SET GLOBAL max_execution_time = 300000` for a 5-minute limit) |
| MERGE (upsert) support | **NOT SUPPORTED in Trino 467** (the production version on this stack). PostgreSQL MERGE was added in **Trino 470** (PR #24467, Feb 2025) and at that point required the **same `merge.non-transactional-merge.enabled=true` flag as MySQL** with non-transactional semantics; transactional MERGE for PostgreSQL only arrived in **Trino 475+**. **On Trino 467, attempting `MERGE INTO app_pg.<schema>.<tbl>` throws an unsupported-operation error** — use INSERT + UPDATE as separate statements, or the snapshot-and-replace pattern. See the version-gated matrix in Section 2A.8 below. | **YES — but only with `merge.non-transactional-merge.enabled=true`** (catalog property) or `SET SESSION billing_mysql.non_transactional_merge_enabled = true` (session — note the `_enabled` suffix). Same partial-write caveat as non-transactional INSERT: a failed MERGE leaves committed rows in place. |
| Schema-name convention | `public` schema exists by default; fully-qualified is `app_pg.public.invoices` | **No `public` schema** — Trino schema name = MySQL database name (e.g., `billing_mysql.billing_db.invoices`) |

**Bottom line**: when you write a federated query against MySQL, assume **only numeric and date predicates push down**. Plan every WHERE clause around that. When in doubt, run `EXPLAIN (TYPE DISTRIBUTED)` and confirm the predicate is inside the `TableScan` constraint, not above it in a `ScanFilterProject`.

### 2A.8 MySQL DML — INSERT, UPDATE, DELETE, MERGE (with the same OLTP write-back warning as Postgres)

Same blanket guidance as Section 9.5 for Postgres: **the federation connector is for read traffic**. Writing through Trino into a live OLTP MySQL bypasses application logic, validation, and audit. Use the app's normal write path whenever possible. That said, the connector supports DML — and the MySQL-specific details differ from Postgres in important ways. Know them before you try a write.

**The full DML matrix for the MySQL JDBC connector (Trino 467):**

| Operation | Supported? | Default semantics | Caveats / how to enable |
|---|---|---|---|
| `INSERT INTO` | YES | Temporary-table-then-rename (transactional) by default | Bypass with `insert.non-transactional-insert.enabled=true` (catalog) or `SET SESSION billing_mysql.non_transactional_insert = true` (session) — faster, but partial-row failure leaves orphans, same as Postgres |
| `UPDATE` | YES | Constant assignments only — same rule as Postgres | `UPDATE t SET status = 'inactive' WHERE id = 42` works; `UPDATE t SET balance = balance + 100` fails. No workaround at the Trino layer. |
| `DELETE` | YES | Predicate must be pushdownable | `DELETE FROM t WHERE id = 42` works. **`WHERE status = 'paid'` does NOT push down (VARCHAR predicates do not push down on MySQL — Section 2A.2), and DELETE with a non-pushdown predicate fails at planning time.** Pair non-pushing VARCHAR filters with a pushdown numeric/date predicate. |
| `MERGE` | **YES on MySQL in Trino 467 — but only with `merge.non-transactional-merge.enabled=true`** | Disabled by default | See "MERGE support" subsection below. Same partial-write caveat as non-transactional INSERT. **PostgreSQL MERGE differs by Trino version — see the version-gated MERGE support matrix below.** |
| `CREATE TABLE` | YES | Standard CREATE TABLE / CTAS | |
| `DROP TABLE` | YES | Drops the underlying MySQL table | |

#### INSERT support — transactional by default, non-transactional flag for fast bulk loads

**Default behavior — transactional INSERT (safe, slower).** By default, `INSERT INTO billing_mysql.billing_db.<table> ...` uses a temporary-table-and-rename wrapper on the MySQL side: Trino writes the new rows into a temporary table, and only on successful completion of the entire INSERT does it atomically rename/swap into the target. This makes the INSERT effectively all-or-nothing — a failed INSERT leaves NO partially-inserted rows behind in the target table. The cost is a rename / data-movement step at the end, which adds latency proportional to the row count.

**Non-transactional INSERT (fast bulk mode):**

| Property type | Name | Default |
|---|---|---|
| Catalog property | `insert.non-transactional-insert.enabled` | `false` (transactional by default) |
| Session property | `SET SESSION <catalog>.non_transactional_insert = true;` | `false` |

When `non_transactional_insert=true`: Trino writes rows directly to the target table without the two-phase temporary-table-and-rename wrapper. This is faster for large bulk inserts but unsafe for failures — partially-failed inserts leave committed rows in MySQL with no automatic cleanup. Only enable this for idempotent bulk loads where you can tolerate and recover from partial writes.

> **Naming-style footgun (same trap as the MERGE flag below):** the catalog property uses **dots and hyphens** (`insert.non-transactional-insert.enabled`), but the session property uses **underscores** and drops the trailing `.enabled` (`<catalog>.non_transactional_insert`). Example: in `etc/catalog/billing_mysql.properties` you write `insert.non-transactional-insert.enabled=true`; from a Trino client you write `SET SESSION billing_mysql.non_transactional_insert = true;`. Mixing the two forms produces `Session property '<name>' does not exist.`

> ### NAMING ASYMMETRY CALLOUT — `non_transactional_insert` vs `non_transactional_merge_enabled` (READ THIS BEFORE COPY-PASTING)
>
> **The INSERT and MERGE non-transactional session properties are NOT symmetric.** The INSERT property has NO `_enabled` suffix; the MERGE property DOES have an `_enabled` suffix. This is the #1 copy-paste typo engineers make when switching from INSERT to MERGE (or back). Memorize the two pairs together:
>
> | DML | Catalog property (dots + hyphens, in `.properties` file) | Session property (underscores, in `SET SESSION`) |
> |---|---|---|
> | **INSERT** | `insert.non-transactional-insert.enabled=true` | `SET SESSION billing_mysql.non_transactional_insert = true;` **(NO `_enabled` suffix)** |
> | **MERGE** | `merge.non-transactional-merge.enabled=true` | `SET SESSION billing_mysql.non_transactional_merge_enabled = true;` **(WITH `_enabled` suffix)** |
>
> **The two specific asymmetries to watch:**
>
> 1. **Session property suffix differs.** INSERT session = `non_transactional_insert` (4 underscores total, no trailing `_enabled`). MERGE session = `non_transactional_merge_enabled` (5 underscores total, **trailing `_enabled`**). There is no underlying logic to which one gets the suffix — it is a historical artifact of when each flag was added to the connector. You must remember both.
> 2. **Catalog property prefix mirrors the DML keyword.** INSERT catalog = `insert.non-transactional-insert.enabled` (the word `insert` appears twice). MERGE catalog = `merge.non-transactional-merge.enabled` (the word `merge` appears twice). The catalog properties ARE symmetric to each other — only the session properties are asymmetric.
>
> **What goes wrong if you mix them up:**
> - `SET SESSION billing_mysql.non_transactional_insert_enabled = true;` → fails: **`Session property 'billing_mysql.non_transactional_insert_enabled' does not exist`** (you added `_enabled` to the INSERT form, which doesn't take it).
> - `SET SESSION billing_mysql.non_transactional_merge = true;` → fails: **`Session property 'billing_mysql.non_transactional_merge' does not exist`** (you dropped `_enabled` from the MERGE form, which requires it).
> - `insert.non-transactional-merge.enabled=true` in the catalog file → either ignored (Trino doesn't recognize the property) or causes catalog startup failure depending on connector version (you crossed the prefix from `insert` to `merge`).
>
> **Rule of thumb:** if you're about to type `SET SESSION <catalog>.non_transactional_<X>`, ask yourself whether `<X>` is `insert` or `merge`. If `merge`, append `_enabled`. If `insert`, stop typing — no suffix. Keep this table open in a tab when authoring DML through Trino against MySQL.

#### MERGE support — enable with the non-transactional flag

**MERGE was historically NOT supported on the MySQL JDBC connector.** Older docs, older Stack Overflow answers, and the responder's instinct may all say "MERGE is not supported on MySQL." **That is out of date.** In current Trino releases (467 included), MERGE IS supported on MySQL **when you enable the non-transactional merge flag**:

```properties
# In etc/catalog/billing_mysql.properties:
merge.non-transactional-merge.enabled=true
```

Or as a session-level override (preferred for one-off testing without a coordinator restart):

> **CRITICAL — session-property name vs. catalog-config-property name (they LOOK similar, they are DIFFERENT):**
> - **Catalog config property** (in `etc/catalog/billing_mysql.properties`): `merge.non-transactional-merge.enabled=true` — uses **hyphens** in the middle, ends in **`.enabled`** (dot-separated).
> - **Session property** (used with `SET SESSION`): `billing_mysql.non_transactional_merge_enabled` — uses **underscores** throughout, ends in **`_enabled`** (underscore, no dot).
>
> The session property name ends in `_enabled`, NOT just `non_transactional_merge`. Pasting `SET SESSION billing_mysql.non_transactional_merge = true` (without the `_enabled` suffix) fails with `Session property 'billing_mysql.non_transactional_merge' does not exist.` This is one of the most common copy-paste mistakes — the catalog property and the session property differ in BOTH separator style (dots vs. underscores) AND whether the trailing `enabled` is joined with a dot or an underscore. Always include `_enabled` at the end of the session-property form.

```sql
SET SESSION billing_mysql.non_transactional_merge_enabled = true;

-- Now MERGE works. Example: upsert computed plan_tier results from Iceberg
-- into a MySQL billing_db.tenant_billing table.
MERGE INTO billing_mysql.billing_db.tenant_billing AS target
USING (
    SELECT tenant_id, computed_plan_tier, computed_monthly_charge
    FROM iceberg.analytics.tenant_billing_computed
    WHERE compute_date = DATE '2026-05-27'
) AS source
ON target.tenant_id = source.tenant_id
WHEN MATCHED THEN
    UPDATE SET plan_tier = source.computed_plan_tier,
               monthly_charge = source.computed_monthly_charge,
               updated_at = TIMESTAMP '2026-05-27 00:00:00'
WHEN NOT MATCHED THEN
    INSERT (tenant_id, plan_tier, monthly_charge, created_at)
    VALUES (source.tenant_id, source.computed_plan_tier,
            source.computed_monthly_charge, TIMESTAMP '2026-05-27 00:00:00');
```

**This is the canonical "Iceberg → MySQL upsert" pattern**: you compute something in Iceberg (a roll-up, a tier reassignment, an end-of-month invoice line), then push the result back into the operational MySQL table with insert-new-rows + update-existing-rows semantics. Without MERGE you would need two separate statements (an INSERT for new rows and an UPDATE for existing ones), each with the constant-assignment limitation on UPDATE; MERGE keeps it atomic at the SQL level.

> **WARNING — same partial-write caveat as non-transactional INSERT.** With `merge.non-transactional-merge.enabled=true`, a failed MERGE **does NOT roll back rows already written**. If the MERGE processes 6,500 of 10,000 rows and then the network drops, the first 6,500 stay committed in MySQL. There is no automatic recovery. **Use MERGE through Trino only when the operation is idempotent** (re-running it on the full source produces the same final state regardless of where the previous attempt failed) — the canonical insert-or-update-by-primary-key MERGE shown above IS idempotent because the second run will UPDATE the rows the first run already INSERTed. Non-idempotent MERGEs (anything with `WHEN MATCHED THEN DELETE` plus state-dependent re-inserts, or expression-derived counters) are unsafe through Trino — do them through the application's MySQL connection inside a real `BEGIN ... COMMIT` block instead.

> **MERGE source-deduplication requirement — exact exception name: `MERGE_TARGET_ROW_MULTIPLE_MATCHES`.** When the MERGE source contains duplicate keys matching the same target row, Trino throws `MERGE_TARGET_ROW_MULTIPLE_MATCHES`. Engineers can search this exact exception name in Trino logs/Web UI when diagnosing MERGE failures. The ISO/IEC 9075:2016 SQL standard requires that each target row match at most ONE source row in a MERGE — this is not a Trino-specific quirk; Snowflake, Oracle, SQL Server, and Postgres 15+ all enforce the same rule (Snowflake's `ERROR_ON_NONDETERMINISTIC_MERGE` defaults to TRUE, Postgres throws `cardinality violation`). Trino enforces it via planner nodes (`AssignUniqueId` + `MarkDistinct`) before execution. The canonical fix is to dedup the source with a window function so each join key appears at most once:
>
> ```sql
> -- Dedup pattern: keep only the most recent row per customer_id
> WITH source_deduped AS (
>     SELECT *
>     FROM (
>         SELECT *,
>                ROW_NUMBER() OVER (PARTITION BY customer_id
>                                   ORDER BY updated_at DESC) AS rn
>         FROM iceberg.analytics.customer_aggregates
>         WHERE compute_date = DATE '2026-05-27'
>     )
>     WHERE rn = 1
> )
> MERGE INTO billing_mysql.billing_db.customer_summary AS target
> USING source_deduped AS source
> ON target.customer_id = source.customer_id
> WHEN MATCHED THEN UPDATE SET ...
> WHEN NOT MATCHED THEN INSERT ...;
> ```
>
> **Pre-MERGE diagnostic query — run this BEFORE your MERGE to confirm whether duplicates exist** (and which keys they're on, so you know whether to dedup or fix upstream):
>
> ```sql
> -- Run BEFORE your MERGE to verify no duplicate join keys in the source:
> SELECT customer_id, COUNT(*) AS cnt
> FROM iceberg.analytics.customer_aggregates
> WHERE compute_date = DATE '2026-05-27'
> GROUP BY customer_id
> HAVING COUNT(*) > 1
> ORDER BY cnt DESC;
> -- If this returns rows, those customer_ids will cause MERGE_TARGET_ROW_MULTIPLE_MATCHES
> -- Fix: add ROW_NUMBER() dedup before the MERGE source (pattern shown above)
> ```
>
> If the diagnostic returns zero rows, the MERGE is safe to run as-is. If it returns N rows, those exact N keys are the ones that will trip `MERGE_TARGET_ROW_MULTIPLE_MATCHES` — either dedup with the `ROW_NUMBER` pattern above or fix the upstream pipeline that's producing the duplicates (common root causes: late-arriving CDC events, overlapping watermark windows, non-unique join keys in the upstream JOIN that built the source).

**Typical use case in this stack**: an end-of-day batch job computes per-tenant billing aggregates from Iceberg event tables, then MERGEs the results into a `billing_db.tenant_billing` (or `billing_db.invoices`) table that the customer-facing app reads from. The Iceberg → MySQL direction is much more common than the reverse — MySQL is the operational truth, Iceberg is the analytics warehouse, and you push computed analytics results back into MySQL where the app can serve them via existing read paths.

**OPA still applies.** Just like for Postgres (Section 9.5), the OPA policy on the production stack typically denies DML on the `billing_mysql` catalog to all roles except a dedicated billing-writer service principal. If your MERGE fails with an authorization error before reaching MySQL, that's OPA denying it — check the policy before assuming the connector is misconfigured.

#### Version-gated MERGE support matrix — PostgreSQL vs MySQL vs Trino version

> **CRITICAL CORRECTION — do NOT claim "PostgreSQL MERGE is supported by default — transactional, safe" in Trino 467.** That claim is wrong on TWO counts: (1) PostgreSQL MERGE did not exist in the Trino JDBC connector until Trino 470 (PR #24467, merged Feb 2025), and (2) even when it landed in 470, it required the **same `merge.non-transactional-merge.enabled=true` flag as MySQL** with non-transactional semantics. **Transactional MERGE for PostgreSQL only arrived in Trino 475+.** Engineers answering questions about PostgreSQL writes on this stack (which runs **Trino 467**) MUST say "MERGE is NOT available — use INSERT + UPDATE separately" rather than claiming it works out of the box.

The following matrix maps Trino version × connector to actual MERGE support. **Read your stack's Trino version (per `prod_info.md`: Trino 467) against the leftmost column first** before quoting any MERGE capability.

| Trino version | PostgreSQL MERGE | MySQL MERGE | Notes |
|---|---|---|---|
| **Trino 467 (production on this stack)** | **NOT SUPPORTED.** Attempting `MERGE INTO app_pg.<schema>.<tbl> ...` throws an **unsupported-operation error** at plan time (the Postgres JDBC connector did not implement the `SupportsRowLevelOperations` interface for MERGE until 470). **Workaround: use INSERT + UPDATE as two separate statements, or use the snapshot-and-replace pattern** (build the target slice as a new Iceberg/staging table, then atomically swap it in). | **YES — but only with `merge.non-transactional-merge.enabled=true`** (catalog property) or `SET SESSION billing_mysql.non_transactional_merge_enabled = true` (session). Non-transactional semantics: partial failures leave committed rows. | This is the version the prod stack runs. **Default answer for any "can I MERGE into Postgres through Trino?" question on this stack is NO.** |
| **Trino 470–474** | **YES — but ONLY with `merge.non-transactional-merge.enabled=true`** (same flag as MySQL). Added in PR #24467 (Feb 2025). **Non-transactional semantics**: a failed MERGE leaves committed rows in PostgreSQL with no rollback — the same partial-write caveat as the non-transactional INSERT and MySQL MERGE behavior. **Only safe for idempotent MERGEs** (insert-or-update-by-primary-key on re-run produces the same final state). | YES — same flag, same non-transactional semantics. | Both connectors require the **same identical flag name** at this point. Catalog property: `merge.non-transactional-merge.enabled=true`. Session property: `<catalog>.non_transactional_merge_enabled = true` (note the `_enabled` suffix per the naming-style footgun above). |
| **Trino 475+** | **YES — transactional MERGE for PostgreSQL.** The flag is no longer required; MERGE is wrapped in a PostgreSQL transaction so partial failures roll back cleanly. | **Still requires `merge.non-transactional-merge.enabled=true`** — MySQL connector did NOT receive a transactional-MERGE upgrade in the same release wave. MySQL MERGE remains non-transactional in all versions where it's supported. | Asymmetric: PostgreSQL got transactional MERGE; MySQL did not. If your stack later upgrades to 475+, PostgreSQL MERGE becomes safe-by-default while MySQL MERGE retains its partial-write footgun. |

**The single sentence to remember on this stack (Trino 467):**

> "**PostgreSQL MERGE is NOT supported in Trino 467 — use INSERT + UPDATE as separate statements, or the snapshot-and-replace pattern via Iceberg staging.** MySQL MERGE IS supported in Trino 467, but only with `merge.non-transactional-merge.enabled=true` and only for idempotent operations."

**Recommended Postgres "upsert without MERGE" patterns for Trino 467:**

1. **Two-statement INSERT + UPDATE (simplest).** Run an `INSERT ... WHERE NOT EXISTS (SELECT 1 FROM target WHERE pk = source.pk)` to add new rows, then a separate `UPDATE` for existing rows. Each statement has the constant-assignment limitation on UPDATE (Section 9.5 — no expression-based SET), and each split commits independently (no cross-statement atomicity). Re-runnable / idempotent.

2. **Snapshot-and-replace via Iceberg staging.** Materialize the entire target slice in Iceberg, then write it back to a fresh Postgres staging table via CTAS, and have the application (NOT Trino) swap the staging table for the live table inside a Postgres `BEGIN ... COMMIT` block. This keeps the atomic swap in Postgres where it belongs and uses Trino only for the compute step.

3. **Do the MERGE in the application, not in Trino.** The application has a direct Postgres connection with full transactional semantics, prepared statements, and `ON CONFLICT (pk) DO UPDATE` (the native Postgres upsert syntax, which Trino's MERGE could never replicate even if it were supported because `ON CONFLICT` is a PostgreSQL-specific extension). For any production upsert, this is the correct path. Use Trino to *compute* the source data; use the app to *write* it.

> **DO NOT** try to work around the Trino-467 limitation by enabling a non-existent flag. There is no `merge.non-transactional-merge.enabled` property on the Trino 467 PostgreSQL connector — adding it to `app_pg.properties` **may cause catalog startup failure or be ignored depending on the connector version — verify by checking Trino coordinator logs after catalog reload**, and even if the catalog reloads MERGE still throws the unsupported-operation error. The flag only takes effect from Trino 470 onward. The only path forward on 467 is one of the three patterns above.

#### Transactional atomicity — same caveat as Postgres for UPDATE/DELETE

The exact same atomicity warning from Section 9.5 (Postgres) applies to MySQL: `UPDATE` / `DELETE` through the MySQL connector is **NOT wrapped in a single user-controlled MySQL transaction**. Each split (or the single JDBC split for non-partitioned MySQL tables — see Section 4.4 / 2A.5) executes its own statement. Mid-execution failure leaves the target in a **partially-modified state** with no automatic rollback. For atomicity-critical bulk mutations, **execute them directly through your application's MySQL connection** (mysql2/PyMySQL/JDBC inside a `BEGIN ... COMMIT` block), not through Trino.

#### CTAS — `CREATE TABLE ... AS SELECT` works the same way

`CREATE TABLE billing_mysql.billing_db.invoices_archive AS SELECT * FROM billing_mysql.billing_db.invoices WHERE created_at < DATE '2026-01-01'` works. The same cautions apply — Trino is not the right tool for very large MySQL-to-MySQL or Iceberg-to-MySQL CTAS (no resume-from-failure; use Spark/Flink for large jobs with checkpointing).

---

## 3. Predicate pushdown — the most important performance concept

> ### Quick checklist for large-table cross-catalog joins
>
> If you're asked "we need to join a big Postgres table to a big Iceberg table — will this survive in production?", answer with these five points, in this order. Missing any one of them is a common reason a federated join blows up at 2 AM:
>
> 1. **Dynamic filtering — name it first.** Trino derives a filter (an IN-list or min/max range) from the build side of the join at runtime and pushes it to the probe side's scan. For a "small dimension table in Postgres + huge fact table in Iceberg" join, dynamic filtering is what turns the query from "scan 500M Iceberg rows" into "scan ~5M Iceberg rows after the user-id IN-list prune." Without it, large × large cross-catalog joins do not survive. See section 5 for the full mechanism.
>    - **Companion lever: force BROADCAST join distribution when the dimension is small** (say, a 5K-row Postgres lookup joined to a billion-row Iceberg fact). `SET SESSION join_distribution_type = 'BROADCAST'` (system property — no catalog prefix here) ships the small build side to every worker instead of repartitioning both sides. This makes the DF maximally precise (each worker has the full build value set) and avoids a big repartition shuffle. For 5K-row × big-Iceberg joins, BROADCAST is almost always right and commonly gives 2–10× speedup over the default `AUTOMATIC` when the CBO mis-estimates the build size. See section 5.5.
> 2. **String-range pushdown caveat — applies to the JDBC side, NOT to Iceberg.** On the **PostgreSQL connector**: equality (`=`), `IN`-lists, `IS NULL`, `IS NOT NULL` on `CHAR`/`VARCHAR` columns push down by default in Trino 467. **Anchored LIKE patterns (`LIKE 'foo%'`) may push down on PostgreSQL for standard-collation columns — but behavior is collation-dependent and more conservative than equality pushdown** (non-default collations, ICU collations, or `COLLATE` clauses can suppress it). **Always verify with EXPLAIN before relying on LIKE pushdown** — it is not the unconditional push that equality is. On the **MySQL connector**: VARCHAR equality and ALL LIKE patterns do NOT push down (Section 2A.2). What does NOT push down on EITHER connector: **`ILIKE`** (case-insensitive — Trino pulls rows and filters in-memory) AND **byte-range predicates** (`>`, `<`, `BETWEEN` on VARCHAR/CHAR) — those still require the experimental `postgresql.experimental.enable-string-pushdown-with-collate=true` flag (PostgreSQL only; the flag does NOT exist for MySQL; see 3.3). On the **Iceberg connector**: string range predicates in WHERE work fine for partition pruning if the partition column is a string. The Iceberg-specific caveat is different — use **TIMESTAMP/DATE literals that align with the partition transform** (`day`, `hour`, `month`) so partition pruning fires, not `LIKE` or string-based date matching against a timestamp column. See section 3.7 below for the Iceberg version. If your join key or filter is a VARCHAR range on the JDBC side, plan for this.
> 3. **Cross-catalog joins always run on Trino workers.** Join pushdown only works when both tables live in the same catalog (e.g., both in `app_pg`). The instant the join crosses catalogs (`app_pg.users JOIN iceberg.events`), the join itself executes on Trino workers — neither Postgres nor Iceberg sees it. Each side's scan can still benefit from predicate pushdown and dynamic filtering, but the hash join is Trino's job. State this explicitly when discussing federated joins; engineers often assume Trino can "push the whole join to Postgres" and it cannot.
> 4. **Verify with EXPLAIN — and confirm DF actually fired at runtime with EXPLAIN ANALYZE.** Two-step verification:
>    - **`EXPLAIN (TYPE DISTRIBUTED)`** (planning-time view, does NOT run the query). The critical distinction is **`TableScan` vs. `ScanFilterProject`**:
>      - **Pushdown SUCCEEDED**: the scan appears as a `TableScan[table=app_pg:public.users, constraint=(plan = 'enterprise' AND status = 'active'), ...]` — the predicate is embedded inside the `TableScan` node's `constraint` (or `predicate`) field. **The predicate has disappeared from the plan tree** because Postgres is handling it server-side. There is no separate filter node above the scan.
>      - **Pushdown FAILED**: the scan appears as a `TableScan[table=app_pg:public.users]` with **a `ScanFilterProject` (or standalone `Filter`) node sitting ABOVE it**, with the predicate inside the `ScanFilterProject`/`Filter`. This means Postgres returned **unfiltered rows** and Trino workers are doing the filtering in memory after the JDBC fetch. This is the slow path.
>      - `dynamicFilters = {...}` annotation appears on the probe-side scan when DF was wired up at plan time.
>    - **`EXPLAIN ANALYZE`** (actually runs the query — stronger evidence): the output includes runtime operator stats. On the **probe-side scan** you will see `dynamicFilterSplitsProcessed = N` (or `Dynamic filters: N splits processed`). A non-zero value confirms dynamic filtering was actively pruning probe splits at runtime, not just appearing in the plan. If `dynamicFilterSplitsProcessed = 0` but the plan showed a `dynamicFilters = {...}` annotation, DF was planned but did not fire in time (usually `dynamic-filtering.wait-timeout` was hit — see section 5.4). For federation, `EXPLAIN ANALYZE` is the stronger verification tool; use it before declaring a federated join "production-ready."
>    - **`EXPLAIN ANALYZE VERBOSE`** (deepest diagnostic — strongest evidence) is the **canonical way to confirm whether dynamic filtering fired and how long it waited for the build side**. It surfaces (a) **dynamic-filter wait time per operator** — the actual milliseconds the probe scan blocked waiting on the build side before giving up; and (b) **the actual filter values applied by dynamic filtering** — the literal IN-list or BETWEEN min/max that was pushed to the probe scan. If you suspect DF is timing out or being compacted to a weaker range, `EXPLAIN ANALYZE VERBOSE` is the definitive answer. Use it for any federated MySQL/Postgres × Iceberg join you want to confirm is using DF correctly before signing off on production.
> 5. **Production guardrails (these are non-negotiable):**
>    - Point at a **read replica**, never the OLTP primary.
>    - **Bound the connection count from outside Trino**, because OSS Trino 467's PostgreSQL connector has no native pool (see Section 0 and 8.2). The standard pattern: put **PgBouncer** between Trino and Postgres (transaction pooling mode), set a Postgres role-level `CONNECTION LIMIT` on `trino_reader`, and cap concurrent Trino queries against the catalog via **resource groups**.
>    - Set `statement_timeout` on the Postgres replica (e.g., `5min`) so a runaway federated query cannot bloat the replica.
>
> If any of these five points is missing from a federated-join plan, the answer is "this will hurt in production." Hard requirement.

### 3.1 What predicate pushdown means in plain English

When you write:

```sql
SELECT * FROM app_pg.public.users WHERE id = 12345;
```

There are two possible execution plans:

1. **No pushdown**: Trino issues `SELECT * FROM users` to Postgres, pulls back **every row** over the network, and applies the `WHERE id = 12345` filter inside Trino workers. Catastrophic for million-row tables.
2. **Pushdown**: Trino rewrites the query and issues `SELECT * FROM users WHERE id = 12345` to Postgres. Postgres uses its index, returns one row, and Trino is done.

The Trino PostgreSQL connector does **option 2 by default** for many predicate types. **This is what makes federation viable.** Only matching rows are returned to Trino workers — not the full table.

### 3.2 What pushes down by default

As of Trino 467, the PostgreSQL connector pushes these predicate types down to Postgres for server-side execution:

| Predicate type | Pushes down? | Example |
|---|---|---|
| Equality on numeric columns | YES | `WHERE id = 12345` |
| Range on numeric columns | YES | `WHERE amount BETWEEN 100 AND 500` |
| Equality on UUID columns | YES | `WHERE tenant_id = 'a1b2c3d4-...'::uuid` |
| Equality on temporal columns | YES | `WHERE created_at = TIMESTAMP '2026-05-01 12:00:00'` |
| Range on temporal columns | YES | `WHERE created_at > TIMESTAMP '2026-05-01 00:00:00'` |
| `DATE` comparisons | YES | `WHERE order_date = DATE '2026-05-01'` |
| `IN` list on numeric / UUID | YES | `WHERE id IN (1, 2, 3, ...)` |
| `IS NULL` / `IS NOT NULL` (on **any** column type — numeric, date, **AND** text) | YES | `WHERE deleted_at IS NULL`, `WHERE email IS NULL` |
| Equality (`=`) on **VARCHAR/text/char** columns | YES | `WHERE status = 'active'` |
| **`IN` list on VARCHAR/text/char** | YES | `WHERE status IN ('active', 'pending', 'cancelled')` |
| **Anchored `LIKE` patterns** (`col LIKE 'foo%'`) | **MAYBE** — pushes down on PostgreSQL for **standard-collation columns**; behavior is **collation-dependent** and **more conservative than equality pushdown**. **Always verify with EXPLAIN.** | `WHERE email LIKE 'foo%'` — see 3.3 |
| **`ILIKE`** (case-insensitive LIKE) | NO | `WHERE email ILIKE 'A%'` — see ILIKE subsection in 3.3 |
| **String RANGE** predicates (`>`, `<`, `<=`, `>=`, `BETWEEN` on VARCHAR/text/char) | **NO** (default — collation-correctness concern) | `WHERE name BETWEEN 'a' AND 'm'` — requires experimental flag, see 3.3 |
| Function calls (`LOWER`, `SUBSTRING`, etc.) | Generally NO | `WHERE LOWER(email) = 'foo@bar'` |

> ### PostgreSQL VARCHAR pushdown — equality vs range (CRITICAL — read this before answering any pushdown question)
>
> **Memorize this distinction. The single most common WRONG statement about the PostgreSQL connector is "VARCHAR pushdown doesn't work reliably" or "VARCHAR equality filters do not always push." Both are FALSE. The correct rule is operator-specific:**
>
> - `=`, `IN`, `!=` on VARCHAR/CHAR columns -> **PUSH DOWN to PostgreSQL** (always, by default — no flags needed)
> - `<`, `>`, `<=`, `>=`, `BETWEEN` on VARCHAR/CHAR columns -> **do NOT push by default**
>   (enable with `postgresql.experimental.enable-string-pushdown-with-collate=true` for C/POSIX locale DBs only — see Section 3.3 for the correctness caveat)
> - **Dynamic filter IN-list on VARCHAR join key -> PUSHES DOWN to PostgreSQL** (the IN-list that the DF machinery derives from the build side ships to Postgres as a `WHERE varchar_col IN (...)` clause in the JDBC query — same as a static IN-list)
> - `IS NULL` / `IS NOT NULL` on VARCHAR -> **PUSH DOWN to PostgreSQL** (same as for numeric/date columns)
> - `LIKE 'foo%'` (anchored) on VARCHAR -> MAYBE (collation-dependent — verify with EXPLAIN)
> - `ILIKE` on VARCHAR -> NO (never pushes — denormalize with a `lower()` generated column)
>
> **A COMMON MISTAKE engineers (and weak AI summaries) make: saying "VARCHAR pushdown doesn't work on PostgreSQL" or "VARCHAR equality filters do not always push reliably." Both statements are WRONG. The only VARCHAR predicates that don't push by default are RANGE predicates (`<`, `>`, `BETWEEN`). Equality and IN-list ALWAYS push — including dynamic-filter IN-lists produced at runtime from the build side of a cross-catalog join. There is no "sometimes" and no "depends on the query" for VARCHAR equality pushdown on PostgreSQL — it is unconditional.**
>
> The full operator-by-operator matrix:
>
> | Operator on VARCHAR / text / char column | Pushes down by default? |
> |---|---|
> | **Equality** (`=`, `!=`) | **YES — unconditional** |
> | **Membership** (`IN (...)`) | **YES — unconditional** |
> | **Dynamic filter IN-list** (runtime, from cross-catalog join build side) | **YES — unconditional** (ships as `WHERE col IN (...)` in the JDBC query at probe time) |
> | **`IS NULL` / `IS NOT NULL`** | **YES** (pushes for text columns too — same as for numeric/date) |
> | **Range** (`<`, `>`, `<=`, `>=`, `BETWEEN`) | **NO** (collation-correctness concern — pushable only with `postgresql.experimental.enable-string-pushdown-with-collate=true` / session `enable_string_pushdown_with_collate`; has a performance trade-off, can disable Postgres index usage) |
> | **`LIKE`** (anchored, e.g., `LIKE 'foo%'`) | **MAYBE** — depends on Trino version and collation; anchored patterns on standard-collation columns often push, but **always verify with EXPLAIN** before relying on it |
> | **`ILIKE`** (case-insensitive) | **NO** — never pushes; denormalize on Postgres with a `lower()` generated column |
>
> **Numeric equality, numeric range, date/timestamp equality, date/timestamp range**: all push down unconditionally.
>
> **MySQL pushdown (for contrast)**: ZERO VARCHAR predicates push (equality, range, IN, LIKE, IS NULL on text columns all stay in Trino memory) — this is the **key MySQL/PostgreSQL difference**. See Section 2A.2 for the MySQL pushdown matrix and workarounds. **Do NOT carry the MySQL rule over to PostgreSQL** — the connectors behave differently here. The "VARCHAR doesn't push" blanket rule is correct for MySQL, NOT for PostgreSQL.
>
> **Bottom line for PostgreSQL**: when you say "VARCHAR pushdown" you must specify the operator. Equality and IN push; range does not. Saying "VARCHAR pushdown is unreliable" or "VARCHAR equality may not push" is a factual error.

> ### Large IN-list trap — `domain_compaction_threshold` (default 256) silently degrades static IN-lists to BETWEEN ranges
>
> **The most common pushdown surprise after VARCHAR**: a static `WHERE tenant_id IN (...)` or `WHERE user_id IN (...)` with **more than 256 distinct values** is **not** pushed to Postgres as a literal `IN (...)` list. Trino's `domain_compaction_threshold` (per-catalog session/config property, **default 256**) caps how many distinct values a pushed-down domain can contain before Trino **compacts the IN-list to a `BETWEEN min AND max` range** before constructing the JDBC SQL sent to Postgres. **This is the same machinery that affects dynamic-filter IN-lists in joins (Section 5.1.2) — it also applies to explicit IN-lists in your WHERE clause.**
>
> **Why this hurts in multi-tenant SaaS workloads:**
> - A query like `WHERE tenant_id IN ('uuid-1', 'uuid-2', ..., 'uuid-500')` (e.g., from a cohort-builder UI that lets users pick a list of tenant IDs, or a scheduled job that iterates over a list of customer IDs) becomes `WHERE tenant_id BETWEEN 'uuid-min' AND 'uuid-max'` in the JDBC SQL Postgres receives.
> - If your 500 tenant IDs are sparse across the UUID range, the BETWEEN matches **many more rows than the original IN-list** — Postgres returns rows for tenants you never asked for, Trino fetches them over JDBC, and then Trino applies the exact IN-list filter in-memory on its workers. You pay the network cost of all the false-positive rows.
> - The query is **still correct** (Trino re-applies the IN filter on its side), but it can be **orders of magnitude slower** than expected. A "300-tenant cohort" query that should scan 300 tenant ranges in Postgres instead scans the full range between min and max tenant IDs.
> - Common triggers: dashboards that filter by "all tenants in region X" (often 500–5000 tenants), backfill jobs that process customers in batches, A/B-experiment cohort exports, account-impersonation tools showing data for a list of users.
>
> **How to fix it — raise the threshold per session for the query:**
>
> ```sql
> -- Raise the threshold for this session before running a large-IN-list query.
> -- MUST use the catalog-name prefix (here `app_pg` — substitute your actual Postgres catalog name).
> SET SESSION app_pg.domain_compaction_threshold = 1024;
>
> -- Now run the cohort query — the full IN-list ships to Postgres as `IN (...)`.
> SELECT user_id, COUNT(*)
> FROM app_pg.public.events
> WHERE tenant_id IN ('uuid-1', 'uuid-2', ..., 'uuid-500')
> GROUP BY user_id;
> ```
>
> Cluster-wide (persistent across sessions, requires coordinator restart): add `domain-compaction-threshold=1024` to `etc/catalog/app_pg.properties`. Note the **hyphen** in the catalog config property name vs the **underscore** in the session property name — Trino convention, both forms refer to the same knob.
>
> **How to verify which form Postgres actually received** — two independent checks:
>
> 1. **Trino-side**: `EXPLAIN (TYPE DISTRIBUTED) <query>` — look for the `constraint on [tenant_id]` block under the Postgres `TableScan`. If the threshold is exceeded, you will see `tenant_id BETWEEN '<min>' AND '<max>'` instead of `tenant_id IN ('uuid-1', 'uuid-2', ...)`. (For runtime confirmation when the IN-list comes from a dynamic filter, `EXPLAIN ANALYZE VERBOSE` shows the literal applied DF values — see Section 3.4.)
>
>    **Quoting in the EXPLAIN constraint block — pay attention to value type:** the literal values inside the constraint block reflect the **Trino type** of the column being filtered. **Integer / BIGINT / numeric values appear UNQUOTED** (`tenant_id IN (1, 2, 3, 4)`, or after compaction `tenant_id BETWEEN 1 AND 9999`). **VARCHAR / UUID / DATE / TIMESTAMP values appear QUOTED** (`tenant_id IN ('uuid-aaa', 'uuid-bbb')`, or after compaction `tenant_id BETWEEN 'uuid-min' AND 'uuid-max'`). If you see what looks like a numeric column appearing quoted in EXPLAIN output (`id IN ('1', '2', '3')`), that's a sign the column is actually a VARCHAR in the Trino schema — check `DESCRIBE app_pg.public.<table>` to confirm. Mismatched expectations here (treating a VARCHAR id like a BIGINT id) are a common cause of "why is my equality predicate not pushing down" head-scratching.
> 2. **Postgres-side ground truth** — `pg_stat_activity` or the slow log (Section 3.4):
>    ```sql
>    -- On the Postgres replica, while the Trino query is running:
>    SELECT query FROM pg_stat_activity WHERE state = 'active' AND query LIKE '%tenant_id%';
>    ```
>    The `query` column shows the exact SQL the JDBC driver sent. `WHERE tenant_id IN ('uuid-1', 'uuid-2', ...)` means the full IN-list pushed. `WHERE tenant_id BETWEEN '<min>' AND '<max>'` means compaction triggered. **This is the definitive check** — Trino's EXPLAIN can occasionally be misread, but the SQL that Postgres actually parsed is unambiguous.
>
> **When to raise it, and how high:**
> - Raise to `1024` (4x default) when your typical large-IN cohort is in the 300–1000 range. This covers most multi-tenant SaaS cohort queries without risking unbounded planner cost.
> - Raise to `4096`+ only after measuring that the larger IN-list doesn't (a) blow up the JDBC query text past Postgres's `max_stack_depth` parse limit, or (b) defeat Postgres index usage (a 5000-element IN-list can plan slower than a BETWEEN scan if the values are dense — measure with `EXPLAIN ANALYZE` on the Postgres side after enabling slow-log capture).
> - **Do NOT set it globally to a very large value** — large IN-lists increase query planning cost on both Trino and Postgres. Prefer per-session (`SET SESSION app_pg.domain_compaction_threshold = ...`) for the specific cohort/backfill query that needs it.
>
> **Cross-reference**: this same knob also governs dynamic-filter IN-lists in cross-catalog joins (Section 5.1.2 and 5.4). The 256-threshold behavior is identical for both static IN-lists and DF-derived IN-lists — both get compacted to BETWEEN ranges past the threshold, and the same `SET SESSION app_pg.domain_compaction_threshold = ...` raises both. The catalog prefix must match the catalog that owns the TableScan receiving the IN-list (so for a join with the IN-list landing on the Postgres scan, use the Postgres catalog prefix; for a join with the IN-list landing on the Iceberg scan, use `iceberg.domain_compaction_threshold`).

### 3.3 What does NOT push down by default — three distinct rules, do not conflate them

There are **three separate categories** of predicates that do not push down to Postgres by default. They are commonly merged into a single "string things don't push down" rule, but the **reasons differ** and the **workarounds differ** — so they need separate handling. Use this table:

| Predicate type | Example | Why it doesn't push | Workaround |
|---|---|---|---|
| **ILIKE** (case-insensitive LIKE) | `WHERE email ILIKE 'A%'` | Not supported by the PostgreSQL connector's expression-pushdown set in Trino 467. (Simple `LIKE` prefix patterns DO push down — see the LIKE-vs-ILIKE clarification below.) | **Denormalize on the Postgres side**: add a `lower_email` generated column indexed on `lower(email)`, then push down equality on it from Trino. |
| **String ranges** (`>`, `<`, `BETWEEN` on VARCHAR/CHAR) | `WHERE name > 'M'` or `WHERE status BETWEEN 'a' AND 'z'` | **Collation differences** between Postgres and Trino could change which rows match (locale-aware vs. byte-wise sort). Pushing them silently could return the wrong rows. **Simple `LIKE 'prefix%'` IS a different case and pushes down by default** — only unbounded byte-range comparisons fall under this rule. | Enable `postgresql.experimental.enable-string-pushdown-with-collate=true` (experimental — see below for caveats). Test on a non-prod replica first. |
| **Function calls** on the column | `WHERE LOWER(email) = 'foo'` or `WHERE CAST(id AS VARCHAR) = '12345'` | Trino cannot rewrite function-based predicates for JDBC pushdown — the connector does not know how to translate arbitrary Trino expressions into Postgres SQL. **This is the true silent pushdown failure mode for type mismatches**: the cast is the function-on-column that fails to push. | **Rewrite as equality on a stored or generated column** (e.g., add a `lower_email` generated column on the Postgres table, index it, then `WHERE lower_email = 'foo'` pushes cleanly and uses the index). For the BIGINT-vs-string case, use the correctly-typed literal: `WHERE id = 12345` (BIGINT literal, no quotes) pushes down fine; `WHERE CAST(id AS VARCHAR) = '12345'` does not. |

> **Note on the BIGINT-vs-string-literal trap.** A naive write of `WHERE id = '12345'` on a BIGINT column does **NOT** silently fail to push down — it causes a **plan-time type error** (`Cannot compare BIGINT and VARCHAR`) that you see immediately, before the query even runs. The query fails outright with a clear error message; you fix it by removing the quotes. The TRUE silent failure is when an engineer "fixes" the type error by **wrapping the column in a cast** — e.g., `WHERE CAST(id AS VARCHAR) = '12345'`. The cast satisfies the type checker, the query runs, and you get correct results — but the cast is a function-on-column that the connector cannot translate to Postgres SQL, so Trino pulls the entire table over JDBC and applies the cast + filter in-memory on Trino workers. The query is correct but catastrophically slow on large tables. **The fix is never the cast; the fix is using the correctly-typed literal** (`WHERE id = 12345`).

The three rows above are independent. Enabling the string-range experimental flag does NOT help ILIKE and does NOT help function calls. Denormalizing a column does NOT help unbounded string ranges. Use the right workaround for the right cause.

#### LIKE vs ILIKE in Trino 467 — the distinction matters

> **Anchored `LIKE` MAY push down on PostgreSQL — but behavior is collation-dependent. `ILIKE` does NOT push down at all.** Older blog posts state "simple LIKE pushes down by default" — that is too strong a claim; **the correct, defensive statement is that anchored LIKE patterns may push down on standard-collation columns, but the pushdown is more conservative than equality pushdown and you must verify with EXPLAIN.**
>
> - **`LIKE` pushdown** to PostgreSQL was added in **Trino 365** and **is available in Trino 467** for anchored-prefix patterns such as `col LIKE 'foo%'` (anchored), `col LIKE 'exact_value'` (no wildcards — degenerates into equality), and other patterns the connector can rewrite. **However**, the rewrite is **collation-dependent**: if the Postgres column uses a non-default ICU collation, or if your query carries an explicit `COLLATE` clause, or if the connector cannot prove byte-wise compatibility, Trino will refuse the push and evaluate the LIKE on its workers instead. Equality pushdown does not have this caveat — only LIKE does. Treat LIKE pushdown as **best-effort**, not as a guarantee.
> - **`ILIKE` pushdown** is **NOT supported** by the PostgreSQL connector in Trino 467 — at all, in any collation. Trino pulls rows back and applies the `ILIKE` filter on its workers. This is the case-insensitivity gap — see the `ILIKE` workarounds below.
> - **Leading-wildcard `LIKE`** (`LIKE '%text%'`, `LIKE '%text'`): Trino may still include the LIKE predicate in the JDBC SQL sent to PostgreSQL, but without an anchored prefix the database cannot use a B-tree index to satisfy it — effectively resulting in a full-table scan on the Postgres side, followed by a Trino-side filter on whatever Postgres returns. For practical purposes: treat unanchored LIKE as "does not push usefully." The predicate text may appear in the pushed SQL (so `EXPLAIN` shows the WHERE clause going down) but Postgres still has to read every row to evaluate it. If this pattern is on your hot path, fix it at the schema level — add a `pg_trgm` GIN index on the column, switch to full-text search (`tsvector` + GIN), or denormalize the substring you actually filter on into its own indexed column. Verify the actual scan plan with `EXPLAIN ANALYZE` on the Postgres side, not just the Trino-side EXPLAIN.
>
> **Always verify with `EXPLAIN (TYPE DISTRIBUTED)` for your exact query** — see Section 3.4. Predicate-shape edge cases (escape characters, multi-byte characters, custom collations, ICU vs. libc collations) routinely affect whether a specific `LIKE` is rewritten cleanly. The rule **"anchored LIKE MAY push down on PostgreSQL for standard-collation columns; ILIKE does not push down at all"** is the right starting point; the EXPLAIN plan is the authoritative answer.
>
> **Actionable fix when anchored LIKE refuses to push (and you have verified with EXPLAIN that it isn't pushing):** anchored LIKE patterns (`LIKE 'foo%'`) do not push down by default on every Postgres column. To enable range and anchored-pattern pushdown for string columns, set the experimental flag:
>
> - **Catalog property** (in `etc/catalog/app_pg.properties` — bare property, no `postgresql.` prefix because the filename provides the namespace):
>   ```properties
>   postgresql.experimental.enable-string-pushdown-with-collate=true
>   ```
>   Note: in this specific case the property name **does** start with `postgresql.experimental.` — that is the *property name itself* (the `experimental` namespace is part of the canonical Trino property name), not a connector-name prefix to drop. Inside the catalog file you write it as-is. (See the Trino PostgreSQL connector docs at [trino.io/docs/current/connector/postgresql.html](https://trino.io/docs/current/connector/postgresql.html#performance).)
> - **Session property** (no coordinator restart):
>   ```sql
>   SET SESSION app_pg.enable_string_pushdown_with_collate = true;
>   ```
>   (Substitute your actual Postgres catalog name for `app_pg`.)
>
> **Warning — this is a correctness-risk flag.** Enabling it makes Trino emit a `COLLATE "C"` clause on pushed string predicates. That is correct **only for C/POSIX-locale databases** where the byte-wise sort order Trino expects matches the database's collation. On **ICU-collated columns** (Postgres 12+ with ICU collations, common on modern Postgres installs) or any column with a non-default collation, the pushed predicate may **match a different set of rows than Trino's in-memory evaluation would** — silent wrong results. Additionally, the `COLLATE "C"` clause can cause Postgres to **stop using existing indexes** built under the default collation, leading to a slower scan even when the pushdown succeeds. Test on a non-prod replica with realistic data and `EXPLAIN ANALYZE` on the Postgres side before enabling cluster-wide. **Prefer the session-level form** for case-by-case testing; only promote to the catalog property after verifying correctness for your specific Postgres locale.

#### ILIKE pushdown — explicitly NOT supported in OSS Trino 467

> **ILIKE pushdown is NOT supported by the OSS Trino 467 PostgreSQL connector.** Trino pulls the candidate rows back from Postgres over JDBC and evaluates the `ILIKE` predicate in-memory on its workers. On large tables this is the classic catastrophic-pushdown-failure shape — a full table scan over JDBC.

If you need case-insensitive matching against a Postgres column from Trino, **the safer alternatives, in preference order**, are:

1. **Denormalize on the Postgres side.** Add a `lower_email` generated column (`lower(email)`) and create a Postgres index on it. Then equality on `lower_email` from Trino pushes cleanly and uses the Postgres index — fast, deterministic, and not dependent on any experimental Trino feature. This is the production-correct fix.

   ```sql
   -- On the Postgres side (one-time setup):
   ALTER TABLE users ADD COLUMN lower_email TEXT GENERATED ALWAYS AS (lower(email)) STORED;
   CREATE INDEX idx_users_lower_email ON users (lower_email);

   -- From Trino — equality pushes cleanly, hits the new index:
   SELECT * FROM app_pg.public.users WHERE lower_email = 'foo@example.com';
   ```

2. **Use case-sensitive equality** if the application can guarantee normalized casing at write time (e.g., always store emails lowercased). Then `WHERE email = 'foo@example.com'` pushes down trivially.

3. **If you MUST use ILIKE on a small table**: accept that the predicate will not push down — Trino will pull the rows and filter in-memory. This is only acceptable when the table is small enough (a few thousand rows) AND when a co-located predicate (an indexed equality, e.g., `WHERE tenant_id = '...'`) narrows the JDBC scan first. Verify with `EXPLAIN (TYPE DISTRIBUTED)`: you will see a `ScanFilterProject` or `Filter` node above the PostgreSQL `TableScan` carrying the `ILIKE` predicate — that is the in-memory filter. For any large table, rewrite the query to use the denormalized `lower_email` approach in step 1 above.

#### String range pushdown — the experimental flag and its caveats

There is an experimental flag to enable string-range pushdown:

```properties
postgresql.experimental.enable-string-pushdown-with-collate=true
```

This adds a `COLLATE` clause to pushed-down range predicates so the comparison matches Trino's byte-wise semantics. The caveats:
- It requires a Postgres version with the right collation support.
- It **can disable Postgres index usage** in some cases (collation mismatch with the existing index — Postgres can no longer use a default-collation index for a query that demands a different collation).
- It is labeled **experimental**. **Test on a non-prod replica first.**
- Don't enable it cluster-wide just because one query is slow — first try to fix that query (often by adding a more selective non-string predicate, or by switching the predicate to an equality on a denormalized column per the LIKE workaround above).

**Session-level alternative (no coordinator restart required)**:

```sql
SET SESSION billing_pg.enable_string_pushdown_with_collate = true;
-- Now test your query with the flag enabled for this session only:
EXPLAIN ANALYZE SELECT * FROM billing_pg.public.table WHERE text_col > 'M';
```

The session property takes effect immediately for your current connection — no coordinator restart needed. Use this to test whether string pushdown helps before committing to the catalog-level property (which requires a coordinator restart). Substitute your actual Postgres catalog name (`app_pg`, `billing_pg`, etc.) for the `billing_pg.` prefix — this is a connector session property, so the catalog prefix is mandatory (see the connector-session-property rule in Section 5.4).

### 3.3A Top-N pushdown — `ORDER BY ... LIMIT N` pushes down to PostgreSQL (CRITICAL — do not miss this)

> **Top-N pushdown IS supported by the OSS Trino 467 PostgreSQL connector.** When you write `SELECT ... FROM app_pg.public.<table> ORDER BY <col> [DESC|ASC] LIMIT N`, Trino sends an `ORDER BY ... LIMIT N` clause directly to Postgres. Postgres uses the existing B-tree index on the sort column (e.g., `created_at`) and returns only N rows — typically with sub-second latency on a million-row table. Trino does NOT pull every row and sort in-memory.
>
> **This is one of the most common questions SaaS engineers ask about Postgres federation** — "if I just want the 20 most recent orders, will Trino pull all 50M rows or just the 20 I asked for?" The answer is: **just the 20**, as long as the pattern is recognized as a Top-N and pushed. This subsection tells you how to confirm it.

Top-N pushdown is **listed alongside join, limit, aggregate, and predicate pushdown** in [the Trino PostgreSQL connector pushdown section](https://trino.io/docs/current/connector/postgresql.html#pushdown), and the [Trino pushdown optimizer doc](https://trino.io/docs/current/optimizer/pushdown.html) uses a PostgreSQL example to demonstrate successful Top-N pushdown.

#### The canonical Top-N query shape

```sql
-- "Most recent 20 orders" — Top-N pattern
SELECT id, user_id, amount, created_at
FROM app_pg.public.orders
ORDER BY created_at DESC
LIMIT 20;
```

If `orders.created_at` has a B-tree index on the Postgres side (almost always true for time-series columns), Trino pushes `ORDER BY created_at DESC LIMIT 20` to Postgres. Postgres traverses the index backward, reads 20 entries, returns 20 rows. Trino's TableScan emits those 20 rows directly to the client. **No sort happens on Trino workers.**

#### EXPLAIN signature — PUSHED vs NOT PUSHED

Use `EXPLAIN (TYPE DISTRIBUTED)` to verify Top-N pushdown — the signature is **different from predicate pushdown**. Predicate pushdown shows up as a `constraint = ...` block inside the TableScan. **Top-N pushdown shows up as `sortOrder=[...]` and `limit=N` annotations inside the TableScan**, with NO separate `TopN` operator anywhere in the plan.

**PUSHED — Top-N is embedded in the TableScan (Postgres does the sort):**

```
Fragment 0 [SINGLE]
    Output[id, user_id, amount, created_at]
    └─ TableScan[table = app_pg:public.orders, sortOrder=[created_at DESC NULLS LAST], limit=20]
           Layout: [id, user_id, amount, created_at]
```

Read this signature carefully:
- The **`sortOrder=[created_at DESC NULLS LAST]`** annotation appears INSIDE the `TableScan` node.
- The **`limit=20`** annotation also appears INSIDE the `TableScan` node.
- There is **NO separate `TopN` operator** above the `TableScan`. The TableScan is the topmost data-producing node in the fragment.
- The SQL the JDBC driver actually sends to Postgres is `SELECT id, user_id, amount, created_at FROM orders ORDER BY created_at DESC LIMIT 20`. Confirm from the Postgres side via `pg_stat_activity` (Section 3.4 / 8.4) — that is the ground truth.

**NOT PUSHED — separate `TopN` operator sits ABOVE the TableScan (Trino does the sort):**

```
Fragment 0 [SINGLE]
    Output[id, user_id, amount, created_at]
    └─ TopN[topN = 20, orderBy = [created_at DESC NULLS LAST]]
           └─ TableScan[table = app_pg:public.orders]
                  Layout: [id, user_id, amount, created_at]
```

Read this signature carefully:
- A **separate `TopN[topN=20, orderBy=[...]]`** operator appears as its own node ABOVE the `TableScan`.
- The `TableScan` has **NO `sortOrder=` or `limit=` annotations** in it — just the bare table reference.
- The SQL the JDBC driver sends to Postgres is `SELECT id, user_id, amount, created_at FROM orders` — **NO `ORDER BY`, NO `LIMIT`**. Postgres returns the **entire table** over JDBC; Trino workers buffer it, sort it, then keep the top 20. On a 50M-row table this is catastrophic — multiple gigabytes of JDBC traffic and a worker-side heap sort.

#### Side-by-side contrast — predicate pushdown vs Top-N pushdown signature (the two are NOT interchangeable)

These two pushdown types appear in **different annotation fields** on the TableScan. Engineers debugging EXPLAIN frequently look for the wrong marker.

| Pushdown type | Successful pushdown signature | Where it appears |
|---|---|---|
| **Predicate** (`WHERE col = ...`, `WHERE col IN (...)`, etc.) | `constraint = (col = 'value')` or `constraint on [col]: col IN ('a','b')` | INSIDE the TableScan, in the **`constraint=`** block |
| **Top-N** (`ORDER BY col LIMIT N`) | `sortOrder=[col DESC NULLS LAST] limit=N` | INSIDE the TableScan, as **separate `sortOrder=` and `limit=`** annotations (NOT inside `constraint=`) |
| **Limit-only** (`LIMIT N` with no ORDER BY) | `limit=N` (just the limit, no sortOrder) | INSIDE the TableScan, as a **`limit=`** annotation |
| **Aggregate** (`SELECT COUNT(*) ...`, `GROUP BY ...`) | The TableScan emits already-aggregated rows; an `Aggregation[...]` node may disappear from above the scan, replaced by a scan whose layout shows the aggregated columns | Layout / projection on the TableScan + absence of upper Aggregation node |

The unifying rule is the same as for predicates: **if you see a separate operator above the TableScan that does the work (a `TopN`, a `Limit`, an `Aggregation` node), then that work is happening on Trino workers and was NOT pushed.** If the work has disappeared from the plan tree and been absorbed into the TableScan's annotations, it WAS pushed.

#### Session property — `topn_pushdown_enabled` (default: true)

The PostgreSQL connector exposes a session property to disable Top-N pushdown for debugging purposes. **Default: `true`** (Top-N pushdown is on out of the box — you do not need to enable anything).

```sql
-- Disable Top-N pushdown for the current session (useful for "is the pushdown
-- helping or hurting?" comparisons during debugging):
SET SESSION app_pg.topn_pushdown_enabled = false;

-- Re-run the query with EXPLAIN — you should now see a separate TopN node:
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.orders ORDER BY created_at DESC LIMIT 20;

-- Reset for the rest of the session:
RESET SESSION app_pg.topn_pushdown_enabled;
```

This is a **connector session property** — the `app_pg.` catalog-name prefix is mandatory (substitute your actual Postgres catalog name). Same prefix rule as `app_pg.aggregation_pushdown_enabled`, `app_pg.join_pushdown_enabled`, `app_pg.enable_string_pushdown_with_collate` — see Section 4.5 for the full connector session-property reference.

You can also disable it at the catalog level (rarely needed — only do this if you have a measured reason). In `etc/catalog/app_pg.properties`:

```properties
# In etc/catalog/app_pg.properties (requires coordinator restart):
# topn-pushdown.enabled=false
```

(Hyphen in the catalog config property name vs underscore in the session property name — Trino convention. Both forms refer to the same knob.)

#### When Top-N pushdown may NOT fire (even though the query looks like a Top-N)

The connector can recognize `ORDER BY ... LIMIT N` and push it, but the **shape of the surrounding plan** can suppress it. Common cases where you write a Top-N query and the EXPLAIN still shows a separate `TopN` operator:

1. **Top-N above a JOIN node** — `SELECT ... FROM a JOIN b ON ... ORDER BY a.col LIMIT N`. The TopN sits above the Join, the Join sits above two TableScans. Even if both TableScans are on the same Postgres catalog and the join itself pushes down, the **TopN over the join result usually does NOT push** because the connector cannot guarantee the join result row order matches what Postgres's `ORDER BY ... LIMIT` over a derived join would produce in the same way. The pushed SQL ends up doing the join in Postgres but the Top-N happens on Trino. (This is partially version-dependent — verify with EXPLAIN; do not assume it will work.)
2. **Top-N above a UNION / UNION ALL** — Trino computes each branch separately, unions in workers, then applies TopN. Same shape: separate `TopN` operator appears above the union.
3. **Top-N above an Aggregation** — `SELECT user_id, COUNT(*) FROM ... GROUP BY user_id ORDER BY COUNT(*) DESC LIMIT 10`. The Top-N is over an aggregated result. Aggregate pushdown may succeed (the GROUP BY ships to Postgres), but the Top-N over the aggregated rows is a separate decision and frequently runs on Trino. Check EXPLAIN for both — they are independent.
4. **Sort on a derived expression** — `ORDER BY LOWER(name) LIMIT 20` or `ORDER BY (price * quantity) DESC LIMIT 20`. The sort key is a function, not a bare column. The connector cannot translate arbitrary expressions for ordering, so the TopN stays on Trino workers. Workaround: store the derived value in a generated column on the Postgres side, then sort by the stored column.
5. **`ORDER BY` without `LIMIT`** — this is **not a Top-N**, it is a full sort. The connector does NOT push standalone `ORDER BY` (sorting an entire table is rarely useful through a federation layer anyway). If you need a sorted full-table extract, push it down with `system.query()` (see fallback below) or rethink the use case.
6. **`OFFSET` after the LIMIT** — `ORDER BY ... LIMIT 20 OFFSET 1000`. OFFSET pushdown is more limited than LIMIT pushdown; some plan shapes will pull rows and apply OFFSET on Trino. For paginated UIs against federated Postgres, prefer keyset pagination (`WHERE created_at < :last_seen ORDER BY created_at DESC LIMIT 20`) — that pattern pushes cleanly as a predicate + Top-N combination.
7. **Subquery / WITH clause that obscures the pattern** — if the planner restructures the query so the `ORDER BY ... LIMIT N` ends up on a derived table or CTE result that isn't directly a Postgres TableScan, the TopN cannot be pushed. Inline the subquery or rewrite to put the `ORDER BY ... LIMIT N` directly on the Postgres table reference.

**In all these cases, EXPLAIN is the authoritative answer.** Look for the `TopN` operator above the TableScan — if it's there, the sort+limit happens on Trino workers.

#### Fallback when Top-N doesn't push — `system.query()` escape hatch

If you have verified with EXPLAIN that Top-N pushdown does NOT fire for your query (a join shape, an aggregation shape, an expression sort, etc.) and the table is large enough that the in-memory sort on Trino is unacceptable, the **`system.query()` passthrough** is the production-correct fallback. It sends the SQL verbatim to Postgres, bypassing Trino's planning entirely:

```sql
-- Top-N inside a join, with Trino's planner refusing to push the TopN past the Join.
-- Send the whole shape to Postgres verbatim via system.query(), so Postgres's
-- planner does both the join and the Top-N (using the index on created_at):

SELECT *
FROM TABLE(
  app_pg.system.query(
    query => '
      SELECT o.id, o.user_id, o.amount, o.created_at, u.email
      FROM orders o
      JOIN users u ON u.id = o.user_id
      WHERE u.plan = ''enterprise''
      ORDER BY o.created_at DESC
      LIMIT 20
    '
  )
);
```

Caveats for `system.query()` (same as elsewhere in this doc):
- The query runs entirely on Postgres — Trino does no planning, no rewrite, no further optimization. You get exactly what Postgres's planner does.
- The result columns are not visible to Trino's analyzer except through the function's output — you cannot easily join the result to an Iceberg table from inside the same `system.query()` call. (You can wrap it as a derived table and join outside, but at that point Trino's planner is back in the loop and you may face the same Top-N-over-join shape.)
- Single-quote escaping inside the SQL string must use Trino's `''` doubling convention (shown above for `'enterprise'`).
- This is a passthrough — `EXPLAIN` on the outer Trino query shows only the `TableFunctionProcessor` node, not the inner Postgres plan. To see the Postgres plan, run `EXPLAIN ANALYZE` on the inner SQL directly against the Postgres replica.

See Section 2A.6 for the analogous MySQL `system.query()` recipe and Section 9 for general `system.query()` patterns.

#### Quick recap — Top-N pushdown on PostgreSQL

1. **Yes, it pushes** — Trino 467's PostgreSQL connector pushes `ORDER BY <col> [DESC|ASC] LIMIT N` to Postgres by default.
2. **EXPLAIN signature for SUCCESS**: `sortOrder=[col DESC NULLS LAST] limit=N` annotations INSIDE the `TableScan` node; no separate `TopN` operator anywhere in the plan.
3. **EXPLAIN signature for FAILURE**: a separate `TopN [topN=N, orderBy=[col DESC]]` operator sitting ABOVE a bare `TableScan` with no sortOrder/limit annotations.
4. **Different from predicate pushdown's signature** — predicates appear in the `constraint=` block; Top-N appears as `sortOrder=` and `limit=` annotations. Both live on the TableScan, but in different fields.
5. **Session property to toggle**: `SET SESSION app_pg.topn_pushdown_enabled = false` (catalog prefix mandatory; default is `true`).
6. **Doesn't push when** the plan has a `TopN` above a Join, Union, Aggregation, or when the sort key is a function/expression rather than a bare column, or when `ORDER BY` appears without `LIMIT`.
7. **Fallback when it refuses**: `app_pg.system.query(query => '...')` passthrough — sends the full SQL to Postgres verbatim, lets Postgres's planner handle the Top-N.
8. **Pairs well with keyset pagination** (`WHERE created_at < :cursor ORDER BY created_at DESC LIMIT 20`) for paginated UI shapes — predicate + Top-N both push cleanly using the same index.

### 3.4 How to verify pushdown actually happens — `EXPLAIN`

> **QUICK VISUAL REFERENCE — real Trino EXPLAIN output, two-line cheat sheet.** Before diving into the detailed examples below, this is the answer most engineers need at a glance when reading real Trino 467 EXPLAIN output:
>
> - **Pushdown SUCCEEDED:** the predicate appears **inside the `TableHandle` constraint block** (in `EXPLAIN (TYPE LOGICAL)`) or as **`constraint on [columns]` indented underneath the `TableScan` node** (in `EXPLAIN (TYPE DISTRIBUTED)`). **NO `Filter` or `ScanFilterProject` node sits above the `TableScan`.** The TableScan is the topmost node for that branch of the plan.
> - **Pushdown FAILED:** a separate **`ScanFilterProject` (or standalone `FilterProject` / `Filter`) node sits ABOVE the `TableScan`** with the predicate carried as its `filterPredicate`. The `TableScan` itself has no `constraint on` line for that predicate. The filter is being applied by Trino workers in-memory after pulling rows from Postgres.
>
> The signature lives in **vertical position of the predicate** in the plan tree, not in any keyword. Predicate **under** the TableScan = pushed. Predicate **above** the TableScan in a Filter/ScanFilterProject node = NOT pushed.

Never assume pushdown. Always verify with `EXPLAIN (TYPE DISTRIBUTED)`:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT * FROM app_pg.public.orders
WHERE order_date = DATE '2026-05-01' AND status = 'active';
```

The critical rule is **the position and shape of the filter in the plan tree, NOT just "did `ScanFilterProject` appear":**

#### Pushdown SUCCEEDED — predicate embedded inside `TableScan` constraint

When pushdown works, the predicate **disappears from the plan tree** because Postgres is going to handle it server-side. The scan node is just a `TableScan` with the predicate embedded inside its `constraint` (sometimes shown as `predicate`):

```
TableScan[table = app_pg:public.orders, constraint = (order_date = DATE '2026-05-01') AND (status = 'active')]
    Layout: [id, order_date, status, amount]
```

No `Filter` or `ScanFilterProject` node sits above it. The SQL sent to Postgres will be `SELECT id, order_date, status, amount FROM orders WHERE order_date = DATE '2026-05-01' AND status = 'active'`. Postgres uses its index and returns only matching rows.

#### Pushdown FAILED — `ScanFilterProject` (or standalone `Filter`) ABOVE the `TableScan`

When pushdown does not happen, Trino prints a `ScanFilterProject` (or a standalone `Filter`) node **sitting above the `TableScan`**. The filter inside that node is the predicate Trino is applying **in-memory inside its workers** after pulling rows back from Postgres:

```
ScanFilterProject[filterPredicate = (status LIKE 'a%')]
    TableScan[table = app_pg:public.orders]
        Layout: [id, order_date, status, amount]
```

This means **Postgres returned unfiltered rows** (all of `orders`) and Trino workers are running the filter after the JDBC fetch. For a million-row table with a selective predicate, this is the disaster case — the entire table streams over the network.

#### Summary table

| Plan shape | Meaning | What Postgres sees |
|---|---|---|
| `TableScan[..., constraint = (predicate)]` with NO node above | **Predicate pushdown SUCCEEDED.** Predicate is embedded in scan constraint; Postgres applies it server-side. | `SELECT ... FROM t WHERE <predicate>` |
| `ScanFilterProject[filterPredicate=(predicate)]` ABOVE a bare `TableScan` | **Predicate pushdown FAILED.** Trino is filtering in-memory on rows pulled from Postgres. | `SELECT ... FROM t` (unfiltered, all rows) |
| `Filter[predicate]` ABOVE any scan | **Predicate pushdown FAILED for that predicate.** Same as above — Trino is doing the filter post-fetch. | (unfiltered for that predicate) |
| `TableScan[..., sortOrder=[col DESC NULLS LAST], limit=N]` with NO `TopN` node above | **Top-N pushdown SUCCEEDED.** `ORDER BY ... LIMIT N` is embedded in the scan; Postgres uses the index on the sort column and returns only N rows. See Section 3.3A. | `SELECT ... FROM t ORDER BY <col> DESC LIMIT N` |
| `TopN[topN=N, orderBy=[col DESC]]` ABOVE a bare `TableScan` (no `sortOrder`/`limit` in TableScan) | **Top-N pushdown FAILED.** Trino pulled the entire table and is sorting in-memory on workers. Catastrophic on large tables. | `SELECT ... FROM t` (entire table, no ORDER BY, no LIMIT) |

> **Don't search EXPLAIN output for the string "FilterNode" — it won't appear.** Trino's EXPLAIN output uses `TableScan`, `ScanFilterProject` (scan + filter combined), and standalone `Filter` nodes. The visible signal that pushdown happened is: **the predicate is INSIDE the `TableScan`'s constraint AND there is no filter node above the scan**. The visible signal that pushdown failed is the opposite: **a `ScanFilterProject` or `Filter` node above the `TableScan` carrying the predicate**.

#### IMPORTANT — the real EXPLAIN output is multi-line, not the stylized one-liner above

The diagrams above (`TableScan[table = ..., constraint = (predicate)]`) are **simplified for teaching**. In actual Trino 467 `EXPLAIN (TYPE DISTRIBUTED)` output, the constraint does **not** appear inline inside the brackets after `TableScan[...]`. It appears on **separate indented lines underneath the TableScan node**, prefixed with `constraint on [columns]`. Here is what the real output looks like:

```
-- Real Trino 467 EXPLAIN (TYPE DISTRIBUTED) output (multi-line) — pushdown SUCCEEDED:
TableScan[table = app_pg:public.orders, ...]
    Layout: [id:bigint:0, status:varchar:1, order_date:date:2, amount:decimal(10,2):3]
    Estimates: {rows: ..., cpu: ..., memory: ..., network: ...}
    constraint on [status, order_date]
        status = 'active'
        order_date >= DATE '2026-05-01'
```

> **Note on reading the real format.** The teaching diagrams in the previous subsections use a simplified format with the constraint inline in brackets like `TableScan[..., constraint = (...)]`. **In real output, the constraint appears as `constraint on [columns]` on a separate indented line under the TableScan node — not inline-in-brackets.** Each predicate then appears one-per-line under that, further indented. The teaching signal is unchanged: **if the predicate appears under the TableScan as a `constraint on` entry, pushdown succeeded.** If instead you see a `ScanFilterProject` or `Filter` node sitting on the line ABOVE the TableScan with the predicate inside it, pushdown failed. The shape of the indentation tells you the answer; do not `grep` for the literal string `constraint = (` because the real output uses `constraint on [...]` followed by indented expression lines.

#### Sanity check from the Postgres side — slow log is the ground truth

Another fast sanity check: enable Postgres slow-query logging on the replica (`log_min_duration_statement=0` temporarily), run the Trino query, and look at the actual SQL Postgres received. The pushed-down version will show the WHERE clauses; the non-pushed version will show a bare `SELECT col1, col2, ... FROM orders`. **This is the definitive proof** — the Trino EXPLAIN view is occasionally ambiguous, but the SQL Postgres actually receives is not.

#### EXPLAIN ANALYZE — runtime field names to read on the TableScan node

> **WARNING**: `EXPLAIN ANALYZE` actually executes the query in full. A 30-minute slow query becomes a 30-minute diagnostic. Always run plain `EXPLAIN (TYPE DISTRIBUTED)` first to check the plan shape without running. Only use `EXPLAIN ANALYZE` when you need runtime numbers (actual row counts, bytes, filter percentages) and are willing to pay the execution cost.

`EXPLAIN ANALYZE` actually runs the query and reports per-operator runtime stats. **When reading `EXPLAIN ANALYZE` output for a Postgres-backed scan, look for these runtime fields on the TableScan node — listed in order of how directly they answer "did pushdown succeed?":**

- **`Input: N rows (size)`** vs **`Output: N rows`** — **The single most direct runtime signal that pushdown worked.** The actual format in Trino EXPLAIN ANALYZE is a per-operator block with two lines: `Input: N rows (size)` (rows the operator received from the source) and `Output: N rows` (rows that flowed out after the operator's own filtering). For a JDBC TableScan, `Input:` is **what Postgres returned over JDBC to Trino**, and `Output:` is what flowed downstream. **A large `Input → Output` reduction at the TableScan/ScanFilterProject layer means the filter was applied at the source.** Example: `Input: 50M rows → Output: 200K rows` for a Postgres TableScan with a `status = 'active'` predicate means Postgres applied the filter and only returned 200K matching rows. Conversely, if `Input:` shows a row count close to the full table size and a `ScanFilterProject` / `Filter` node above the TableScan does the filtering instead, pushdown failed — Trino fetched the entire table over JDBC and filtered locally.
- **`Physical Input`**: total bytes read from Postgres over JDBC. **If this equals (or is close to) your full table size, pushdown failed for some predicates** — Trino fetched the entire table over the wire.

> **CRITICAL — `Physical Input` is FRAMED DIFFERENTLY for Iceberg scans vs JDBC scans.** The metric name is identical in `EXPLAIN ANALYZE` output, but it represents two physically different quantities depending on the connector:
>
> - **Iceberg `TableScan`**: `Physical Input` = **compressed Parquet bytes read from object storage (MinIO)**. This is the on-disk file footprint actually fetched after partition pruning and file-skipping. The ratio between `Physical Input` (bytes) and the logical row count reflects **Parquet column compression** (dictionary encoding, RLE, Snappy/ZSTD) combined with **partition pruning and per-file min/max skipping**. For a wide-column Iceberg table, `Physical Input` can be a small fraction of the uncompressed row size — that is the whole point of columnar storage.
> - **JDBC `TableScan` (PostgreSQL, MySQL)**: `Physical Input` = **bytes received over the JDBC network connection from the database server**. This is **NOT compressed in the Parquet sense** — it is the raw row data transmitted over TCP (with whatever wire-protocol overhead the JDBC driver adds, but no columnar compression). A large `Physical Input` value means **the database sent a lot of rows or wide rows**; it is the direct indicator that predicate pushdown failed, or that the predicates that did push down were not selective enough.
>
> **The diagnostic LOGIC is identical** — in both cases, a high `Physical Input` value relative to the final query output means "too much data was read at the source." But the **framing is different**:
> - For Iceberg, "high Physical Input" means **compressed storage bytes** fetched from MinIO — fix is usually partition pruning, file skipping (min/max stats), or projection pushdown (fewer columns).
> - For JDBC, "high Physical Input" means **network bytes** received from the database — fix is predicate pushdown (push WHERE clauses down so fewer rows ship), or dynamic filtering on the probe side.
>
> Do not assume "Physical Input = 500MB" means the same thing across connectors. For an Iceberg scan, 500MB is real compressed storage I/O. For a JDBC scan, 500MB is uncompressed row data on the wire — typically several gigabytes of logical row width once decoded into Trino memory.
- **`dynamicFilterSplitsProcessed = N`** (on the operator stats for the JDBC/Iceberg TableScan) — runtime confirmation that a dynamic filter actually fired during execution. **A non-zero value confirms DF was applied.** A zero value with a dynamicFilters annotation in the plan means DF was wired up but the build side did not finish before `dynamic-filtering.wait-timeout` expired (Section 5.4).
- **`constraint on [col1, col2]`** block under the TableScan node — shows which predicates the connector translated into the source SQL / metadata scan. Presence of this block plus a small `Input:` row count is the strongest evidence of pushdown.
- **Operator timing** (CPU / Elapsed / Wall): time spent in the TableScan node. **High time relative to the overall query means the Postgres scan is the bottleneck** — either network-bound (lots of bytes streaming over JDBC) or Postgres-side computation (slow plan on the Postgres replica).

Example `EXPLAIN ANALYZE` output snippet showing **pushdown SUCCEEDED** (small `Input:` row count relative to the table, and the `constraint on` block is present under the TableScan):

```
TableScan[table = app_pg:public.orders, ...]
    Input: 52000 rows (4.51MB)
    Output: 52000 rows
    CPU: 1.23s
    constraint on [status, order_date]
        status = 'active'
        order_date >= DATE '2026-05-01'
```

In this example, the `orders` table has ~1.9M rows but the JDBC TableScan only received 52K rows — Postgres applied `status = 'active' AND order_date >= DATE '2026-05-01'` server-side via the `constraint on` block, and returned only the matching 52K rows over JDBC. **The small `Input:` row count and the presence of the `constraint on` block together are the proof.**

Contrast with **pushdown FAILED** — `Input:` would show a row count close to the full table size, and a `ScanFilterProject` / `Filter` node would sit above the TableScan in the plan applying the filter on the Trino side:

```
ScanFilterProject[filter = (status = 'active')]
    Input: 5200000 rows
    Output: 200000 rows
  TableScan[table = app_pg:public.orders, ...]
      Input: 5200000 rows (450MB)
      Output: 5200000 rows
      CPU: 2.50s
      Elapsed: 8.20s
```

**Compare TableScan `Input:` against the table's known row count**: if the query ultimately returned 200,000 rows but the Postgres TableScan's `Input:` shows `5200000 rows (450MB)`, **Trino fetched the entire table from Postgres and filtered 5.2M rows locally on a ScanFilterProject node**. That is the unambiguous signature of failed predicate pushdown — much stronger evidence than the plan tree alone, because it reflects what actually happened at runtime, not just what the planner intended.

> **NOTE — Trino's EXPLAIN ANALYZE does NOT emit a "Filtered: X%" field.** If a doc, blog post, or AI-generated example tells you to "look for a `Filtered:` line on the TableScan" — that field does not exist in Trino's EXPLAIN ANALYZE output. (It is sometimes confused with Postgres's own `EXPLAIN ANALYZE` output, which DOES have a `Filtered:` field — but that is from `psql`, not from Trino.) Use the `Input:` vs `Output:` row count comparison + the `constraint on` block + `dynamicFilterSplitsProcessed` instead. These are the real runtime signals.

> **Tip — `EXPLAIN ANALYZE VERBOSE` is the canonical dynamic-filter diagnostic**: Use `EXPLAIN ANALYZE VERBOSE <query>` to see dynamic-filter wait time and the actual filter values Trino applied — this confirms whether dynamic filtering fired and how long it waited for the build side. Specifically, `VERBOSE` surfaces:
> - **Dynamic-filter wait time per operator** — how many milliseconds the probe-side scan blocked waiting for the build side to finish before giving up and starting the scan. A wait time close to `dynamic-filtering.wait-timeout` (1s for Iceberg probes, 20s for JDBC probes — see Section 5.4) with `dynamicFilterSplitsProcessed=0` means the timeout fired and DF didn't help.
> - **Actual filter values applied by dynamic filtering** — the literal IN-list values (or BETWEEN min/max) that Trino derived from the build side and pushed to the probe scan. This is the ground-truth answer to "did DF actually push an IN-list, or did it get compacted to a range by `domain-compaction-threshold`?". If you expected an IN-list of 300 IDs but VERBOSE shows `BETWEEN 1 AND 7842`, the build side exceeded the 256-entry threshold and was compacted.
>
> `VERBOSE` also includes per-driver timing, per-operator memory, and additional internal counters. For day-to-day pushdown verification, the standard `EXPLAIN ANALYZE` plus the row-count comparison is enough — reach for `VERBOSE` whenever you need to prove **why** dynamic filtering did or didn't work, especially for federated Iceberg-probe-with-JDBC-build scenarios where wait-timeout behavior is the most common failure mode.

> **Workflow — always run plain `EXPLAIN` first.** Run plain `EXPLAIN` (or `EXPLAIN (TYPE DISTRIBUTED)`) first to inspect the query plan (join order, distribution type, dynamic filter presence) without the cost of re-executing the full query. Only use `EXPLAIN ANALYZE` once you know what to measure — it re-runs the entire query, so a 30-minute slow query becomes a 30-minute diagnostic. The two-step recipe: (1) plain `EXPLAIN` to see whether predicates are inside `TableScan` constraints and whether `dynamicFilters = {...}` annotations are present on the probe side; (2) `EXPLAIN ANALYZE` (or `EXPLAIN ANALYZE VERBOSE`) to confirm at runtime that DF fired and pushdown row counts match expectations.

> **Tip — distributed-plan EXPLAIN ANALYZE**: For deeper per-operator diagnostics (wall time breakdown, memory usage, dynamic filter wait timings), use: `EXPLAIN ANALYZE (FORMAT TEXT, TYPE DISTRIBUTED) <query>` — this shows per-operator CPU time and input distribution percentiles. Pair it with the WARNING above: the query still actually runs in full, so reserve this form for queries you are willing to pay the execution cost for.

> **Federated-query tuning callout — `dynamic-filtering.wait-timeout` and `domain-compaction-threshold`**: If `EXPLAIN ANALYZE VERBOSE` shows dynamic filtering timed out waiting for the MySQL (or Postgres) build side, check the dynamic-filter wait timeout (default **20s** for JDBC connectors, vs **1s** for Iceberg) and `domain-compaction-threshold` (default **256 entries** — larger IN-lists are compacted to `BETWEEN min AND max`) in your catalog properties file (`etc/catalog/billing_mysql.properties`). The most common federated-query failure mode is the Iceberg-probe + JDBC-build pattern hitting the 1-second Iceberg default before the JDBC build delivers — raise the Iceberg wait timeout with `iceberg.dynamic-filtering.wait-timeout=15s` inside `etc/catalog/iceberg.properties` (the `iceberg.` prefix is REQUIRED for the Iceberg connector — see Section 5.4 / official docs at trino.io/docs/current/connector/iceberg.html), OR per-session `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';` (note: SQL session property uses **underscores**, not hyphens, and the prefix is the catalog name — usually `iceberg` if your catalog file is `iceberg.properties`). The second most common is a build side that produces 300+ join-key values getting compacted to a BETWEEN range because `domain-compaction-threshold=256` — raise the per-catalog `domain-compaction-threshold` to 1024+ in the JDBC connector's properties file.

> **Federated-query diagnostic heuristic — small result + long runtime + high Physical Input = filter breakdown.** If your query returns only a few thousand rows but scans gigabytes of `Physical Input` on the Iceberg side (visible in `EXPLAIN ANALYZE` as the `Physical Input:` line on the Iceberg `TableScan` / `ScanFilterProject` operator), one of two things broke: (a) **partition pruning failed** — check that your `WHERE` clause uses a partition column (or a transform that aligns with the Iceberg partition spec — `day(occurred_at)`, `month(created_at)`, etc.); a `WHERE occurred_at >= DATE '2026-05-01'` on a `day(occurred_at)`-partitioned table will prune correctly, but `WHERE date_trunc('day', occurred_at) = DATE '2026-05-01'` typically will not because the partition transform isn't recognized in the literal. (b) **Dynamic filtering didn't fire** — check for a `DynamicFilter` annotation on the `ScanFilterProject` (or `TableScan`) node in `EXPLAIN` output; if missing, the build side is too big or the wait-timeout fired. The `dynamicFilterSplitsProcessed=0` runtime metric confirms (b); the absence of partition column in the `constraint on` block confirms (a). Fix the correct one — raising wait-timeout won't help if your WHERE never used a partition column to begin with.

> **CANONICAL PUSHDOWN CHECK per Trino docs — look for the ABSENCE of `ScanFilterProject` above the `TableScan` in PLAIN EXPLAIN.** The Trino documentation's documented signal for confirming predicate pushdown is structural and lives in the **plain `EXPLAIN` plan**, not in VERBOSE output text:
>
> - **Pushdown SUCCEEDED**: only `TableScan` appears for that branch of the plan. There is **NO** `ScanFilterProject`, `FilterProject`, or standalone `Filter` node sitting above the `TableScan`. The predicate is folded into the TableScan's constraint.
> - **Pushdown FAILED**: a `ScanFilterProject` (or `Filter`) node appears **ABOVE** the `TableScan`, carrying the predicate as its `filterPredicate`. Trino is doing the filter in-memory after fetching rows.
>
> **Do not rely on `EXPLAIN ANALYZE VERBOSE` output text format to determine this.** VERBOSE adds per-operator timing, dynamic-filter wait times, and applied filter values — extremely useful for runtime diagnosis, but it is not the documented canonical signal for the structural pushdown question. **The presence or absence of `ScanFilterProject` above `TableScan` in plain `EXPLAIN` is the documented signal.** Use plain `EXPLAIN` for the structural answer first (cheap, no execution), then escalate to `EXPLAIN ANALYZE` or `EXPLAIN ANALYZE VERBOSE` only when you need runtime confirmation.

> **`EXPLAIN ANALYZE VERBOSE` — what it adds beyond plain `EXPLAIN ANALYZE`, and the warning that comes with it.** `VERBOSE` is the deepest available diagnostic. It surfaces:
>
> - **Per-operator wall time** — wall-clock time spent in each operator (not just CPU), letting you distinguish "operator was slow" from "operator was blocked waiting on upstream data."
> - **Dynamic filter wait timings** — milliseconds the probe-side scan blocked waiting for the build-side DF before giving up.
> - **Input distribution percentiles** — p50/p95/p99 of rows processed per driver, exposing skew (e.g., one worker got 90% of the rows because of a hot join key).
> - **Actual DF values applied** — the literal IN-list or BETWEEN min/max that was pushed to the probe, so you can verify whether the IN-list got compacted to a range (`domain-compaction-threshold` exceeded) without having to read the Postgres slow log.
> - **Per-driver memory and per-operator memory** — to find OOM risk operators.
>
> **WARNING — `EXPLAIN ANALYZE` (and VERBOSE) actually run the query in full.** A 30-minute slow query takes 30 minutes to diagnose via EXPLAIN ANALYZE. Always use plain `EXPLAIN` first (planning only, no execution — completes in seconds regardless of query cost) to check the plan structure: predicate position relative to TableScan (canonical ScanFilterProject check above), join distribution (BROADCAST vs PARTITIONED on the Exchange operator), presence of `dynamicFilters = {...}` annotations on probe-side TableScans. Only escalate to EXPLAIN ANALYZE / VERBOSE when you need runtime numbers (actual row counts, bytes scanned, DF wait time in milliseconds, distribution percentiles) and are willing to pay the full execution cost.
>
> The recommended workflow is **two-step**:
> 1. **`EXPLAIN (TYPE DISTRIBUTED) <query>`** — plan-only inspection. Confirms (a) predicate pushdown structure (absence of ScanFilterProject above TableScan = success), (b) join distribution choice (REPLICATE vs REPARTITION on the Exchange operator), (c) DF wiring (`dynamicFilters = {...}` on probe-side TableScan).
> 2. **`EXPLAIN ANALYZE [VERBOSE] <query>`** — runtime confirmation. Confirms (a) actual `Input → Output` row reduction at the source (pushdown effectiveness), (b) `dynamicFilterSplitsProcessed > 0` on the probe (DF fired at runtime), (c) DF wait timings if you suspect timeout problems, (d) actual filter values to detect IN-list → BETWEEN compaction.

### 3.5 A concrete pushdown example

```sql
-- Federated query: which active users in Postgres had events in the last hour
SELECT u.email, COUNT(*) AS recent_events
FROM app_pg.public.users u
JOIN iceberg.analytics.events e ON e.user_id = u.id
WHERE u.tenant_id = '11111111-2222-3333-4444-555555555555'  -- UUID equality, pushes down
  AND u.status = 'active'                                     -- string equality, pushes down
  AND e.event_time > TIMESTAMP '2026-05-26 11:00:00'         -- timestamp range, pushes down on the Iceberg side
GROUP BY u.email;
```

What happens at runtime:

- The `users` scan in Postgres receives `WHERE tenant_id = '...' AND status = 'active'`. Postgres uses the `(tenant_id, status)` index, returns maybe 5,000 rows instead of 50 million.
- The `events` scan in Iceberg receives the timestamp predicate plus a partition prune to the relevant `day_occurred_at` partition.
- The **JOIN** itself runs on Trino workers — not in Postgres, not in Iceberg.

This is fast because both scans return small result sets. If the `tenant_id` predicate were removed, the Postgres scan would return all 50M user rows over the network, and the query would become a disaster.

### 3.6 Case study: 8M Postgres rows × 500M Iceberg event rows

This is the canonical "large × large federated join" scenario. Production stack: Iceberg `analytics.events` partitioned by `day_occurred_at`, ~500M rows in the partition we want; Postgres `app_pg.public.users`, ~8M total users; we want recent events for users that match some criterion (e.g., active enterprise-plan users). The query shape:

```sql
SELECT u.tenant_id, u.email, COUNT(*) AS event_count
FROM app_pg.public.users u
JOIN iceberg.analytics.events e ON e.user_id = u.id
WHERE u.plan = 'enterprise'                                  -- selective on Postgres side
  AND u.status = 'active'                                     -- additional pushdown
  AND e.occurred_at >= TIMESTAMP '2026-05-25 00:00:00'        -- partition prune on Iceberg
  AND e.occurred_at <  TIMESTAMP '2026-05-26 00:00:00'
GROUP BY u.tenant_id, u.email;
```

There are two ways this query can play out at runtime. **Whether you survive depends entirely on which path you trigger.**

#### Failure mode — no selective WHERE on the Postgres side

Imagine an engineer drops the `plan` / `status` filters because "we want all users":

```sql
SELECT u.tenant_id, u.email, COUNT(*) AS event_count
FROM app_pg.public.users u
JOIN iceberg.analytics.events e ON e.user_id = u.id
WHERE e.occurred_at >= TIMESTAMP '2026-05-25 00:00:00'
  AND e.occurred_at <  TIMESTAMP '2026-05-26 00:00:00'
GROUP BY u.tenant_id, u.email;
```

What happens:

1. The Postgres scan has **no predicate to push down** (the filter is only on `e.occurred_at`, which is on the Iceberg side). Trino issues `SELECT id, tenant_id, email FROM users` to Postgres.
2. **All 8M users stream over JDBC** to Trino workers — but via the JDBC single-split model (see Section 4.4 below): exactly **one split → one Trino worker task → one JDBC connection → one thread reading rows**. The bottleneck is not "20 workers each fanning out to Postgres"; it is the single JDBC reader thread on ONE worker pulling all 8M rows sequentially. The full 8M rows still bloat memory on the receiving worker and saturate the JDBC socket for the duration of the scan. The connection-pressure concern is real but smaller per query than for parallel-split connectors (e.g., Iceberg) — a single non-partitioned Postgres scan is one connection, not twenty.
3. Trino builds a hash table from 8M rows. The build side is too large to fit the **default dynamic-filter build-side threshold** (about 1000 distinct values per driver for IN-list filters; the actual property names depend on whether the join is broadcast or partitioned — see Section 5.4 for the correct `dynamic-filtering.*` and `dynamic-filtering.partitioned.*` property names. You do NOT want to push these up for a multi-million-row build side — the filter becomes too large to be useful as a probe-side IN-list).
4. **No dynamic filter is generated.** The Iceberg side scans the full day-partition: ~500M rows × all column projections needed.
5. Trino probes 500M Iceberg rows against the 8M-row hash table. Network shuffle is large; aggregation buffers spill to disk.
6. Wall time: tens of minutes to hours, often killed by `query.max-execution-time`. Postgres replica connection slots may exhaust other clients during the long scan (PgBouncer's `default_pool_size` will queue rather than reject, but the queue grows).

#### Success mode — selective WHERE on Postgres + dynamic filtering to Iceberg

The query at the top of this case study (with `plan = 'enterprise' AND status = 'active'`) plays out very differently:

1. **Predicate pushdown on the Postgres side.** `WHERE plan = 'enterprise' AND status = 'active'` is sent to Postgres via JDBC: `SELECT id, tenant_id, email FROM users WHERE plan = 'enterprise' AND status = 'active'`. Postgres uses the `(plan, status)` index and returns ~50,000 rows instead of 8M.
2. **Build side is now small.** 50K rows fit easily into the hash table; the dynamic-filter build-side threshold is reached and Trino derives an IN-list filter (or a min/max range, depending on key distribution) of the ~50K user IDs.
3. **Dynamic filter pushes to the Iceberg scan.** The `events` scan in Iceberg now receives effectively `WHERE occurred_at >= ... AND occurred_at < ... AND user_id IN (id1, id2, ..., id50000)` as additional pruning constraints. Iceberg's manifest-level min/max stats on `user_id` (if `user_id` is sorted within files or correlates with file layout) prune entire Parquet files; for the files that DO have matching `user_id` values, only those row groups are read.
4. **Probe-side input drops dramatically.** Instead of 500M event rows, the scan returns maybe 5–10M rows that could plausibly join. The join completes in seconds.
5. Aggregation runs across the matched rows. Final result: ~50K group rows.
6. Wall time: a few seconds to a couple of minutes, depending on Iceberg file layout and event volume per user.

The difference between failure and success is **a single selective WHERE on the Postgres side** that (a) keeps the build side under the dynamic-filter threshold and (b) gives Trino a small enough IN-list to push to Iceberg.

#### What `EXPLAIN (TYPE DISTRIBUTED)` shows for each mode

**Failure mode** (no Postgres WHERE) — the Postgres side scans without a filter (just a bare `TableScan` with no constraint), and no dynamic filter appears on the Iceberg probe side:

```
Fragment 1 [SOURCE]
    TableScan[table = app_pg:public.users]
        Layout: [id, tenant_id, email]
        # NO constraint line — full table scan; ALL 8M rows stream over JDBC

Fragment 2 [SOURCE]
    TableScan[table = iceberg:analytics.events,
              constraint = (occurred_at >= TIMESTAMP '2026-05-25 00:00:00')
                       AND (occurred_at <  TIMESTAMP '2026-05-26 00:00:00')]
        Layout: [user_id, occurred_at]
        # NO dynamicFilters annotation — DF did not fire (build side too big)
```

**Success mode** (with selective Postgres WHERE) — both sides show pushed-down predicates embedded in `TableScan` constraints, AND the Iceberg probe-side scan shows a dynamic filter:

```
Fragment 1 [SOURCE]
    TableScan[table = app_pg:public.users,
              constraint = (plan = VARCHAR 'enterprise') AND (status = VARCHAR 'active')]
        Layout: [id, tenant_id, email]
        # ^ predicates embedded INSIDE the TableScan constraint; no Filter node
        #   above — pushdown SUCCEEDED. Postgres applies the filter server-side.

Fragment 2 [SOURCE]
    TableScan[table = iceberg:analytics.events,
              constraint = (occurred_at >= TIMESTAMP '2026-05-25 00:00:00')
                       AND (occurred_at <  TIMESTAMP '2026-05-26 00:00:00')]
        Layout: [user_id, occurred_at]
        dynamicFilters = {user_id = #df_users_id_0}
        # ^ this is dynamic filtering firing on the Iceberg PROBE side
        #   (the probe scan is the side RECEIVING the DF — Postgres dimension
        #   is the build, Iceberg fact is the probe). At runtime, EXPLAIN
        #   ANALYZE will show dynamicFilterSplitsProcessed > 0 on THIS node.
```

The presence of the `dynamicFilters = {...}` line on the **probe-side Iceberg scan** is the visible confirmation that DF did its job. Without it, the join is reading every row in the partition. If you instead see a `ScanFilterProject` or `Filter` node ABOVE a `TableScan` carrying the timestamp predicate, that means the timestamp filter did NOT push down to Iceberg — go fix that first.

To also verify on the Postgres side (Trino → Postgres), tail the Postgres replica's slow log (`log_min_duration_statement=0`) — you should see the dynamic-filter IN-list appear in the SQL Postgres receives **on Trino-to-Postgres dynamic filtering** (when the join direction makes Postgres the probe side), in the form `WHERE id IN (1, 2, ..., 50000)`. In the configuration at the top of this case study, Postgres is the build side so the dynamic filter pushes to Iceberg, not Postgres.

#### The takeaway

A "large × large" cross-catalog join is survivable in production if and only if **at least one side has a selective WHERE that reduces it to a few tens of thousands of rows**, so that:

- That side becomes the build side.
- Dynamic filtering kicks in and pushes a small IN-list to the other side.
- The other side's scan is pruned at the partition / file / row-group level.

If neither side has such a filter, you do not have a federated-join problem — you have a "wrong tool for the job" problem. Pre-aggregate one side, materialize a dimension to Iceberg, or change the question.

### 3.7 Iceberg-side caveat: predicate shape must match the partition transform

The string-range pushdown rule in 3.3 is a **JDBC connector** rule. The Iceberg connector has a different (and frequently confused) caveat about predicate shape that affects whether **partition pruning** fires.

Iceberg partitions are typically declared with a **transform** on a column, not on the raw column. For example:

```sql
CREATE TABLE iceberg.analytics.events (
    occurred_at TIMESTAMP(6),
    ...
)
WITH (partitioning = ARRAY['day(occurred_at)']);
```

The partition value is `day(occurred_at)` — the date portion — not `occurred_at` itself. For Trino's planner to prune partitions, the WHERE clause must use a predicate shape Trino can evaluate against the transform. Concretely:

- **Good (prunes correctly)** — use a TIMESTAMP/DATE literal that matches the granularity of the transform:
  ```sql
  WHERE occurred_at >= TIMESTAMP '2026-05-01 00:00:00'
    AND occurred_at <  TIMESTAMP '2026-05-02 00:00:00'
  ```
  Trino evaluates `day(TIMESTAMP '2026-05-01 00:00:00') = DATE '2026-05-01'`, identifies the matching partition, and prunes all others.

- **Bad (forces full scan)** — string-based date matching against the timestamp column:
  ```sql
  WHERE CAST(occurred_at AS VARCHAR) LIKE '2026-05-01%'  -- prevents pruning
  WHERE date_format(occurred_at, '%Y-%m-%d') = '2026-05-01'  -- prevents pruning
  ```
  These wrap `occurred_at` in a function, which Trino cannot peer through to apply the partition transform. Every partition gets scanned.

- **Also bad** — using a literal at the wrong granularity:
  ```sql
  -- Partitioning is day(occurred_at) but the literal is hour-level:
  WHERE occurred_at = TIMESTAMP '2026-05-01 14:23:45'  -- works, but only matches one row in one partition
  ```
  That one works — it just narrows aggressively. The real failure is when the predicate is fundamentally not pruneable, like a function call on the partition column.

The official Trino documentation on this is the blog post "Just the right time date predicates with Iceberg" — bookmark it. Verify partition pruning fired by checking `EXPLAIN ANALYZE` output for the Iceberg TableScan's `Input: N rows (size)` line (verbatim format — see Section 3.4) against the table's total row count, or by reading `EXPLAIN (TYPE DISTRIBUTED)` for the number of splits scanned in the Iceberg `ScanFilterProject` node.

**To restate the distinction one more time, because it gets confused:**

| Connector | The pushdown caveat to worry about |
|---|---|
| PostgreSQL (and MySQL, SQL Server) | Equality, IN-lists, and **simple `LIKE 'prefix%'` patterns push down** (LIKE pushdown was added in Trino 365 and is supported in Trino 467). `ILIKE` does **NOT** push down — case-insensitive search returns rows over JDBC and filters in-memory. String **range** predicates (`>`, `<`, `BETWEEN` on VARCHAR/CHAR) also do NOT push down by default; enable them only with the experimental `postgresql.experimental.enable-string-pushdown-with-collate=true` flag. |
| Iceberg | Predicate must use literals matching the **partition transform** (TIMESTAMP/DATE for `day(col)`/`hour(col)`/`month(col)` transforms). Wrapping the partition column in a function or doing string-based date matching prevents partition pruning. |

---

## 4. Cross-catalog joins — the limitation you must understand

### 4.1 The rule

**Join pushdown is intra-catalog only.** The PostgreSQL connector's join pushdown only fires when both tables being joined live in the **same PostgreSQL catalog** (e.g., `app_pg.public.users` JOIN `app_pg.public.orders`). In that case Trino can rewrite the join into a single SQL statement and send it to Postgres, which executes the join server-side using its own indexes and join algorithms.

**Cross-catalog joins always execute on Trino workers.** The moment the join crosses catalogs (e.g., `app_pg.public.users` JOIN `iceberg.analytics.events`), the join itself **always** runs inside Trino — Postgres doesn't know what an Iceberg table is, and Iceberg doesn't know what a Postgres table is. There is no "cross-catalog join pushdown" feature, and there cannot be: the two storage engines do not share an execution model.

#### Controlling intra-catalog join pushdown via session properties

For intra-catalog joins (both tables in the same Postgres catalog), Trino exposes two **real** OSS Trino 467 session properties to control join pushdown behavior. Both require the `<catalog>.` prefix (see Section 5.4):

```sql
-- Disable join pushdown for a specific query (useful for debugging):
SET SESSION billing_pg.join_pushdown_enabled = false;

-- Control strategy — AUTOMATIC (default) or EAGER:
SET SESSION billing_pg.join_pushdown_strategy = 'EAGER';
```

| Session property | Default | What it controls |
|---|---|---|
| `<catalog>.join_pushdown_enabled` | `true` | Whether Trino can push intra-catalog joins down to Postgres. Set to `false` to force the join to run on Trino workers instead (useful for debugging or when the Postgres planner makes bad choices). |
| `<catalog>.join_pushdown_strategy` | `AUTOMATIC` | `AUTOMATIC` — push down only when Trino estimates it's beneficial. `EAGER` — push down whenever structurally possible, even if the cost model isn't confident. Use `EAGER` when you know the join is intra-catalog and Postgres has good indexes. |

> **`AUTOMATIC` is cost-based — it relies on Postgres table statistics, which Trino's PostgreSQL connector CAN read from `pg_stats` (see Section 4.1A below).** The default `AUTOMATIC` strategy asks Trino's **CBO (cost-based optimizer — the part of Trino's query planner that uses table/column statistics to decide join order, build/probe sides, and broadcast vs partitioned distribution)** whether pushdown is cheaper than executing the join on Trino workers. The PostgreSQL connector retrieves table and column statistics — including NDV (distinct value counts) and null fractions — from Postgres's `pg_stats` view via JDBC metadata queries, but only if **native PostgreSQL `ANALYZE` has been run on the Postgres database itself**. Without that, `pg_stats` is empty for the column and the CBO sees no NDV — at which point it may decline to push down a join even when both tables live in the same Postgres catalog. If you observe an intra-catalog join inexplicably running on Trino workers instead of being pushed to Postgres, two fixes:
> 1. **Run native PostgreSQL `ANALYZE` on the PRIMARY** (e.g., `ANALYZE billing.invoices;` from psql connected to the primary — NOT the read replica, which is a read-only hot standby and rejects `ANALYZE` with `cannot execute ANALYZE in a read-only transaction`; see Section 4.1A). This populates `pg_statistic` / `pg_stats` on the primary; the rows replicate via WAL to the streaming standby that Trino reads from. The Trino PostgreSQL connector then reads those statistics on its next planning pass (subject to metadata cache TTL — see Section 2.6) and the CBO sees realistic row counts AND per-column NDVs, becoming much more likely to choose pushdown. **Do NOT** run `ANALYZE billing_pg.billing.invoices` from inside Trino — `ANALYZE` is not supported by the PostgreSQL connector (see Section 4.1A); it must be run natively in Postgres on the primary.
> 2. **Bypass the cost model with `SET SESSION billing_pg.join_pushdown_strategy = 'EAGER';`** — pushes down whenever structurally possible, no statistics required. Use `EAGER` when you know the join is intra-catalog AND Postgres has indexes on the join keys; the trade-off is that EAGER can occasionally pick a bad plan when Postgres is missing an index and the join becomes a Cartesian-like nested loop on the Postgres side.

**IMPORTANT**: These session properties apply **only to intra-catalog joins** (both tables in the same Postgres catalog). For cross-catalog joins (e.g., `billing_pg` + Iceberg), there is no session property to enable join pushdown — it structurally cannot happen regardless of any setting.

To see all available session properties for a Postgres catalog:

```sql
SHOW SESSION LIKE 'billing_pg.%';
```

#### EXPLAIN signature — was the intra-catalog join pushed to Postgres? (CRITICAL — same shape as predicate / Top-N pushdown verification)

Just like predicate pushdown and Top-N pushdown, **never assume** intra-catalog join pushdown fired. Always verify with `EXPLAIN (TYPE DISTRIBUTED)`. The signature lives in the **plan tree shape**, not in any keyword:

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT u.id, u.email, o.amount
FROM app_pg.public.users u
JOIN app_pg.public.orders o ON o.user_id = u.id
WHERE u.tenant_id = 42;
```

**Join pushdown SUCCEEDED — both tables collapse into ONE TableScan node (no `InnerJoin` / `HashJoin` operator in the plan).** The PostgreSQL connector rewrites the entire join into a single SQL statement (`SELECT ... FROM users u JOIN orders o ON o.user_id = u.id WHERE u.tenant_id = 42`) and sends it to Postgres. Postgres returns already-joined rows. In the EXPLAIN tree you see:

```
Output
└── TableScan[app_pg:Query[SELECT ... FROM users u INNER JOIN orders o ON ... WHERE ...]]
    constraint: tenant_id = 42
```

The diagnostic markers: (a) the `TableScan` node's table handle is a **synthetic query handle** (often shown as `app_pg:Query[...]` or with the rewritten SQL visible), (b) **NO `InnerJoin`, `HashJoin`, or `LookupJoin` operator** appears anywhere in the plan, (c) the projected columns include columns from **both** original Postgres tables, (d) on the Postgres side, `pg_stat_activity` will show a single SQL statement with both tables JOINed.

**Join pushdown FAILED (or did not fire) — separate `InnerJoin` / `HashJoin` operator above two distinct `TableScan` nodes.** The query plan looks like a normal Trino join: Postgres returns each table's rows independently, Trino workers do the hash join. The plan tree:

```
Output
└── InnerJoin[user_id = id][Distribution: REPLICATED or PARTITIONED]
    ├── TableScan[app_pg.public.users]
    │   constraint: tenant_id = 42
    └── TableScan[app_pg.public.orders]
```

Two TableScans, one InnerJoin node above them, columns split by source table. This is the **default failure mode** when (a) statistics are missing on the Postgres side and `join_pushdown_strategy=AUTOMATIC` decides not to push, (b) the join has unusual structure (non-equi-join, complex `ON` clause with functions), or (c) the session property `join_pushdown_enabled` is `false`.

**Cross-catalog join — ALWAYS this shape, no exceptions.** A join between `app_pg.public.users` and `iceberg.analytics.events` ALWAYS plans as two separate TableScans (one per catalog) with an `InnerJoin` / `HashJoin` node above them — because the two storage engines do not share an execution model, the join is always executed by Trino workers. No session property changes this. The cross-catalog plan looks identical to the "join pushdown failed" intra-catalog plan above, but the two TableScans come from different catalogs.

**Side-by-side diagnostic table:**

| Plan shape | Join location | What `pg_stat_activity` shows |
|---|---|---|
| One `TableScan` with synthetic query handle, NO Join operator | Postgres (intra-catalog pushdown succeeded) | Single SQL statement containing both tables `JOIN`ed |
| Two `TableScan` nodes under an `InnerJoin` / `HashJoin`, both from the SAME Postgres catalog | Trino workers (intra-catalog pushdown did not fire — check stats, check `join_pushdown_enabled`, try `EAGER` strategy) | Two separate SQL statements, one per table, no JOIN in either |
| Two `TableScan` nodes under an `InnerJoin` / `HashJoin`, from DIFFERENT catalogs (one Postgres, one Iceberg) | Trino workers (cross-catalog — always this way) | One SQL statement against Postgres (just the Postgres-side scan with its own WHERE predicates) |

**Verifying intra-catalog pushdown via Postgres-side tooling.** The absolute ground truth is what Postgres actually receives. Enable `log_min_duration_statement = 0` temporarily on the read replica (or query `pg_stat_activity` during execution), run your query, and look at the SQL Postgres executed. If you see one statement with `... FROM users INNER JOIN orders ON ...`, the join pushed. If you see two separate `SELECT ... FROM users ...` and `SELECT ... FROM orders ...` statements (issued near-simultaneously from the same Trino query), the join did not push and Trino is doing the hash join in memory.

#### Why intra-catalog join pushdown sometimes silently doesn't fire (debugging checklist)

If you expect intra-catalog join pushdown but EXPLAIN shows two TableScans under an `InnerJoin`, run through these four causes in order:

1. **Missing Postgres statistics — AUTOMATIC strategy's most common silent miss.** Without `pg_stats` rows for the join columns (NDV, null fraction), Trino's CBO has no basis for estimating that the join is cheaper inside Postgres than on Trino workers. Run `ANALYZE billing.users; ANALYZE billing.orders;` on the Postgres primary (see Section 4.1A — must be on the primary, not the replica). Then flush Trino's metadata cache (`CALL app_pg.system.flush_metadata_cache();`) and re-run the EXPLAIN.

2. **`join_pushdown_strategy = AUTOMATIC` is being too conservative.** Even with stats, the cost model can decline pushdown for joins it judges marginal. Bypass it with `SET SESSION billing_pg.join_pushdown_strategy = 'EAGER';` — this pushes whenever structurally possible, with no statistics required. EAGER is the right answer when you KNOW both tables are in the same Postgres catalog AND Postgres has indexes on the join keys.

3. **Non-equi-join or function in the `ON` clause.** Joins with `ON a.x = b.y` push down; joins with `ON a.x = LOWER(b.y)` or `ON a.x < b.y` typically do not (the connector cannot guarantee Postgres has matching execution semantics for the function/operator). Restructure to an equi-join if possible.

4. **`join_pushdown_enabled = false` somewhere.** Check session state (`SHOW SESSION LIKE 'billing_pg.join_pushdown%';`) and the catalog config file (`etc/catalog/billing_pg.properties` — look for `join-pushdown.enabled=false`). The default is `true` for the PostgreSQL connector in Trino 467, but a previous operator may have explicitly disabled it.

> **Catalog-file property name — hyphens, NOT underscores.** Like every other connector property, the catalog `.properties` file form uses **hyphens** while the session-property form uses **underscores**. The two refer to the same knob in different contexts:
>
> | Where | Property name | Example |
> |---|---|---|
> | `etc/catalog/<catalog>.properties` (cluster default, requires restart) | `join-pushdown.enabled` | `join-pushdown.enabled=true` |
> | `SET SESSION` (per-session, no restart) | `<catalog>.join_pushdown_enabled` | `SET SESSION billing_pg.join_pushdown_enabled = false;` |
> | `etc/catalog/<catalog>.properties` (cluster default, requires restart) | `join-pushdown.strategy` | `join-pushdown.strategy=EAGER` |
> | `SET SESSION` (per-session, no restart) | `<catalog>.join_pushdown_strategy` | `SET SESSION billing_pg.join_pushdown_strategy = 'EAGER';` |
>
> Same hyphen-vs-underscore footgun as `domain-compaction-threshold` / `domain_compaction_threshold` and `aggregation-pushdown.enabled` / `aggregation_pushdown_enabled` (see Section 3.3A and Section 4.5). Pasting `join_pushdown.enabled=true` (underscore + dot) into the catalog file is silently ignored — the connector loads the file, never sees the property it expected, and falls back to the default.

**Why this matters for the "should I just ingest to Iceberg?" question.** This is the underlying reason why moving a frequently-joined table from Postgres into Iceberg often yields a large speedup:

- **Before** (federated, cross-catalog join): each Postgres row is pulled over JDBC as a row-by-row JDBC fetch (row-oriented network protocol, no columnar batching), then joined on Trino workers. Dynamic filtering helps but only after the build side completes; you still pay JDBC serialization overhead, Postgres connection pressure (remember: no Trino-side pool in OSS 467 — bounded only by PgBouncer / role-level CONNECTION LIMIT / resource groups, see Section 8.2), and lack of columnar I/O on the Postgres side.
- **After** (both tables in Iceberg, intra-catalog join in the `iceberg` catalog): the scan is columnar (Parquet), reads only the projected columns, can leverage Iceberg manifest min/max pruning, can be broadcast across workers efficiently, and benefits from the CBO's join reordering when ANALYZE stats are present.

So when someone asks "if my federated join is slow, will ingesting the Postgres table into Iceberg help?" — yes, often dramatically, and the structural reason is: (a) JDBC row-by-row fetch becomes columnar Parquet scan, (b) the join can now be a broadcast join with intra-Iceberg-catalog optimizations, and (c) the CBO can plan it properly because both sides have NDV stats from `ANALYZE`. Nothing about that requires "cross-catalog join pushdown" to exist — it doesn't, and won't.

### 4.1A How Trino's CBO gets statistics for PostgreSQL-connector tables — read this carefully

> **CRITICAL — common misconception**: "Trino's CBO can't get NDV or distribution statistics from Postgres, so it always guesses for federation joins." **This is wrong.** The Trino PostgreSQL connector **CAN and DOES retrieve table and column statistics from PostgreSQL**, including NDV (distinct value counts) and null fractions — the connector reads them from `pg_stats` via JDBC metadata queries. The catch is that you must run **native PostgreSQL `ANALYZE`** on the Postgres database first to populate `pg_stats`, and Trino's `ANALYZE TABLE` command does NOT work on PostgreSQL connector tables. This section explains exactly what works, what doesn't, and how to verify.

#### The official behavior

Per the Trino documentation ([trino.io/docs/current/connector/postgresql.html](https://trino.io/docs/current/connector/postgresql.html), "Table statistics" section): **"The PostgreSQL connector can use table and column statistics for cost based optimizations to improve query processing performance. The statistics are collected by PostgreSQL and retrieved by the connector."**

What this means in practice:

- **PostgreSQL collects statistics** when its own `ANALYZE` command runs (either auto-triggered by `autovacuum` or manually by a DBA). The collected statistics live in `pg_statistic` (the internal table) and are exposed via the `pg_stats` view.
- **The Trino PostgreSQL connector retrieves** those statistics on demand — it queries `pg_stats` (and related Postgres catalog tables like `pg_class.reltuples` for total row counts) over JDBC during query planning. The connector translates the retrieved values into Trino's internal `TableStatistics` / `ColumnStatistics` objects so the CBO can use them.
- **What gets retrieved**: total row count, per-column NDV (distinct value count from `pg_stats.n_distinct`), per-column null fraction (`pg_stats.null_frac`), and possibly low/high values. **Histograms in `pg_stats.histogram_bounds` are NOT consumed by the Trino connector** as of OSS Trino 467 — only the scalar summary fields (NDV, null fraction, row count) influence Trino's CBO. This is still a major improvement over "no stats at all."
- **Metadata cache interaction**: if you have `metadata.cache-ttl > 0` in the catalog file (see Section 2.6), statistics may also be cached for that TTL. After running Postgres-side `ANALYZE`, you can run `CALL app_pg.system.flush_metadata_cache();` to force Trino to re-fetch fresh stats on the next query, rather than waiting for the TTL to expire.

#### The three ANALYZE situations — keep these straight

This is the most-confused part of CBO + federation. There are three different `ANALYZE` commands in play, each with a different scope and a different effect. Memorize this table:

| Command | Where you run it | What it does | Effect on Trino's CBO |
|---|---|---|---|
| `ANALYZE iceberg.analytics.events;` (Trino, Iceberg table) | Trino CLI / any Trino client | Writes a **Puffin file** with NDV sketches (specifically **`apache-datasketches-theta-v1`** Theta-sketch blobs) next to the table's metadata in MinIO. See resource 23 for details. | **Trino CBO gets NDV** for the Iceberg table. Crucial for join ordering on Iceberg tables. |

> **Sketch-type clarification (Iceberg connector specifically uses Theta sketches, not HLL).** For Iceberg tables, Trino writes **`apache-datasketches-theta-v1`** Puffin blobs (Theta sketches from Apache DataSketches). The broader Trino ecosystem also uses **HLL** (HyperLogLog) sketches in other places — e.g., the Hive connector's column-stats storage, and Trino's built-in `approx_distinct()` SQL function — but the **Iceberg connector specifically uses Theta** for the Puffin NDV blobs written by `ANALYZE iceberg.<schema>.<table>`. When someone asks "what kind of sketch does Iceberg `ANALYZE` write?", the correct answer is **Theta**, not "Theta or HLL." Practical implication: you don't choose between them on the Iceberg side — Trino picks Theta automatically. (See resource 23 for the Puffin file layout and how to inspect the blobs.)
| `ANALYZE billing.invoices;` (psql, native Postgres) | A psql session connected to the **PRIMARY** (a streaming hot standby is read-only and will reject `ANALYZE`; see Section 4.1A) | Postgres scans the table on the primary, computes NDV / null fraction / histograms / MCVs, writes them to `pg_statistic`. `pg_statistic` is a regular heap table and replicates via WAL to the hot standby Trino reads from. | **Trino CBO gets NDV and null fractions** for the Postgres table — the connector reads `pg_stats` from the replica next time the table is planned (subject to metadata cache TTL). This is the correct way to give the CBO statistics for federated Postgres tables. |
| `ANALYZE app_pg.public.users;` (Trino, PostgreSQL connector table) | Trino CLI / any Trino client | **NOT SUPPORTED.** The PostgreSQL connector does NOT implement Trino's `ANALYZE` statement. Trino will fail with a parser/connector error such as `Catalog 'app_pg' does not support analyze` or similar. | **No effect.** Do not rely on it. |

**The mental shortcut:** Trino's `ANALYZE` only works on connectors that own their data files (Iceberg, Hive, Delta Lake). For JDBC connectors that delegate to a separate database engine (PostgreSQL, MySQL, SQL Server, Oracle), Trino does not own the statistics layer — the underlying database does. To give the CBO statistics for those connector tables, you run the database engine's native ANALYZE.

#### Putting it together — concrete recipe for "make federation queries fast"

The full pipeline to give Trino's CBO accurate statistics for a federated PostgreSQL table:

1. **DBA runs native ANALYZE on the Postgres PRIMARY** (or relies on `autovacuum_analyze` if the table changes frequently):
   ```sql
   -- Run this in psql connected to the PRIMARY (NOT the read replica, NOT through Trino):
   ANALYZE billing.invoices;
   -- For a quick check that stats are now populated, query the replica
   -- after WAL has shipped (SELECT works fine on a hot standby):
   SELECT attname, n_distinct, null_frac
   FROM pg_stats
   WHERE schemaname = 'billing' AND tablename = 'invoices';
   ```

   > **IMPORTANT — `ANALYZE` belongs on the PRIMARY. DO NOT run `ANALYZE` on a hot standby — it will fail.** PostgreSQL hot standbys (the standard streaming-replication read-replica topology used by Trino federation deployments per Section 2.3) are **read-only during recovery**. Per the official PostgreSQL hot-standby documentation, `ANALYZE` is among the maintenance commands explicitly **not accepted** while the replica is in recovery mode. Attempting `ANALYZE billing.invoices;` against a hot standby errors out with `ERROR: cannot execute ANALYZE in a read-only transaction` (or a similar "cannot execute in recovery" message). The correct topology is:
   >
   > - **`pg_statistic` (the underlying catalog table behind the `pg_stats` view) IS a regular heap table and IS replicated via WAL.** When you run `ANALYZE` on the **primary**, Postgres writes the resulting tuples into `pg_statistic`, those writes flow through the WAL stream, and the standby replays them. After WAL has caught up, the **replica's** `pg_stats` reflects the primary's most recent ANALYZE. The Trino PostgreSQL connector then reads those statistics on its next planning pass (subject to metadata cache TTL — see Section 2.6).
   > - **The safe rule for federation against a streaming read replica: run `ANALYZE` on the primary; let WAL propagate `pg_statistic` to the replica.** Schedule the ANALYZE job (cron, pg_cron, or rely on the primary's `autovacuum_analyze`) on the **primary**, not the replica. Trino's JDBC reads `pg_stats` from the replica, but those stats arrived there via WAL replay of writes the primary made.
   >
   > **If Trino still sees stale or NULL stats after you ANALYZE'd the primary, here is the diagnostic flow — do NOT reach for "run ANALYZE on the replica," that path is closed:**
   >
   > 1. **Check replication lag on the replica.** If the standby is behind, the WAL containing the new `pg_statistic` tuples may not have replayed yet.
   >    ```sql
   >    -- Run on the REPLICA:
   >    SELECT now() - pg_last_xact_replay_timestamp() AS replay_lag;
   >    ```
   >    A lag of seconds is normal; minutes or hours means replication is stalled — fix that first.
   > 2. **Flush Trino's metadata cache** so the new stats are picked up on the next planning pass (only required if `metadata.cache-ttl > 0s`; see Section 2.6):
   >    ```sql
   >    CALL app_pg.system.flush_metadata_cache();
   >    ```
   > 3. **Verify the stats actually arrived on the replica.** `SELECT` is allowed on a hot standby (read-only does not block reads), so this works:
   >    ```sql
   >    -- Run on the REPLICA — SELECT-only, safe on a hot standby:
   >    SELECT attname, n_distinct, null_frac
   >    FROM pg_stats
   >    WHERE schemaname = 'billing' AND tablename = 'invoices';
   >    ```
   >    If `n_distinct` and `null_frac` are populated here, the stats reached the replica — any remaining "no stats" symptom on the Trino side is a metadata-cache issue, not a Postgres issue.
   > 4. **If stats are still missing or unhelpful, raise `default_statistics_target` per column on the PRIMARY** (the default `100` is sometimes too low for skewed high-cardinality columns):
   >    ```sql
   >    -- On the PRIMARY:
   >    ALTER TABLE billing.invoices ALTER COLUMN tenant_id SET STATISTICS 300;
   >    ANALYZE billing.invoices;
   >    -- WAL ships the richer pg_statistic rows to the replica;
   >    -- Trino's next planning pass (after metadata-cache flush) sees them.
   >    ```
   >
   > **Special case — logical replication.** If the replica behind Trino is a **logical** replica rather than a physical (streaming) one, the rules change: logical replication replicates user-table data but **does NOT replicate system catalogs like `pg_statistic`**. On a logical replica that is in normal (read-write) operation (not recovery), you would need to ANALYZE the replica locally — but a logical-replica subscriber is a fully-writable Postgres instance, so `ANALYZE` succeeds there. **The "ANALYZE on the replica" pattern is ONLY valid for a logical/writable subscriber, never for a streaming/physical hot standby.** The default and recommended topology for Trino federation in this stack is a streaming hot standby (Section 2.3) — assume the primary-side rule unless your DBA has explicitly told you the Trino-facing Postgres is a logical-replication subscriber.
2. **Optionally flush Trino's metadata cache** so the new stats are picked up immediately (only needed if `metadata.cache-ttl > 0`):
   ```sql
   CALL app_pg.system.flush_metadata_cache();
   ```
3. **Verify Trino's CBO now sees the stats** with `SHOW STATS`:
   ```sql
   SHOW STATS FOR app_pg.billing.invoices;
   -- distinct_values_count should now be populated for analyzed columns,
   -- not NULL. nulls_fraction should also be populated.
   ```
4. **Re-run the federation query and inspect EXPLAIN** — the `Estimates: {rows: N, ...}` annotations on the Postgres-side scan should now reflect realistic per-predicate cardinality, not the heuristic default.

#### What `SHOW STATS FOR app_pg.<schema>.<table>` actually returns

Same format as Iceberg — Trino's `SHOW STATS` is connector-agnostic and reports whatever the underlying connector's metadata layer provides:

```
 column_name | data_size | distinct_values_count | nulls_fraction | row_count | low_value | high_value
-------------+-----------+-----------------------+----------------+-----------+-----------+-----------
 invoice_id  |   NULL    |       1.0E6           |     0.0        |   1.0E6   |     1     |  1000000
 tenant_id   |   NULL    |       2.5E2           |     0.0        |   1.0E6   |     1     |    250
 status      |   NULL    |       4.0E0           |     0.0        |   1.0E6   |   NULL    |   NULL
 ...
 NULL        |   NULL    |        NULL           |     NULL       |   1.0E6   |   NULL    |   NULL
```

- **`data_size`** is typically NULL for PostgreSQL connector — Trino does not compute physical byte sizes from Postgres metadata (Iceberg can because it knows file sizes; Postgres exposes per-table size but not per-column).
- **`distinct_values_count`** is populated from `pg_stats.n_distinct` after native ANALYZE has run on Postgres.
- **`nulls_fraction`** is populated from `pg_stats.null_frac`.
- **`row_count`** comes from `pg_class.reltuples` — note this is an **estimate** updated by ANALYZE/VACUUM, not a live row count. It can be stale if ANALYZE has not been run recently on a write-heavy table.

If `distinct_values_count` is NULL for the join-key columns even after running native Postgres ANALYZE, the most likely causes are: (a) the metadata cache is still serving stale "no stats" results — flush it (Section 2.6); (b) Postgres `default_statistics_target` is set very low or ANALYZE ran on a sampled subset that produced no distinct estimate; (c) the column has a Postgres type the connector doesn't map statistics for (rare — most common types are supported).

#### Why the misconception persists ("Postgres connector has no stats")

Three reasons engineers commonly state this incorrectly:

1. **Confusion with Trino's `ANALYZE` not working on the connector.** Engineers try `ANALYZE app_pg.public.users` in Trino, see it fail, and conclude "the connector has no stats." It is actually the inverse — Trino can't write stats for Postgres connector tables because the source database owns that layer; Trino reads stats from the source database instead.
2. **Stale or never-run native ANALYZE on the Postgres side.** If the Postgres PRIMARY was set up with `autovacuum = off` for some reason, or the DBA never ran `ANALYZE` after the initial table creation, `pg_stats` is empty on the primary, the empty state replicates to the standby via WAL, and Trino's CBO sees nothing. The fix is to run native ANALYZE **on the primary** (not the replica — see Section 4.1A on why ANALYZE cannot run on a hot standby), not to "configure Trino differently."
3. **Conflation with cross-catalog join pushdown limitations.** Cross-catalog joins always run on Trino workers (Section 4.1), so even with perfect stats on both sides the join itself is not pushed down. People conflate "join pushdown doesn't happen" with "no statistics" — they are independent issues. With good stats on both sides, the cross-catalog join still runs on Trino workers, but the CBO chooses the right build/probe sides, broadcast vs. partitioned, and join order — exactly the wins resource 23 describes for Iceberg.

#### Summary — the rule

- **PostgreSQL connector statistics for the CBO are real and useful, but you must run native Postgres `ANALYZE` to populate them.** The connector reads them from `pg_stats` automatically once they exist.
- **Trino's `ANALYZE` command does NOT work on PostgreSQL connector tables.** Don't try it — and don't conclude from its failure that "Postgres tables have no statistics."
- **`SHOW STATS FOR <pg_catalog>.<schema>.<table>` is the verification tool** — same as for Iceberg, but the values come from `pg_stats` instead of Puffin files.
- **Statistics flow into the CBO regardless of cross-catalog limitations** — having good stats on the Postgres side improves intra-catalog join pushdown decisions, build/probe selection on cross-catalog joins executed by Trino workers, and broadcast vs. partitioned choice. They do not, by themselves, enable cross-catalog join pushdown (which doesn't exist).

#### 4.1B Stats-hygiene checklist for cross-catalog joins — both sides must have stats

For the CBO to choose the right join distribution (BROADCAST vs PARTITIONED — see Section 5.5.1) and the right build/probe assignment on a cross-catalog join, **both sides need statistics**. Missing stats on either side push the CBO into the no-stats fallback (PARTITIONED join, often the wrong choice for small-dim × large-fact). Use this checklist:

- **Postgres side** (on the PRIMARY — `ANALYZE` cannot run on a streaming hot standby; see Section 4.1A):
  ```sql
  -- Run on the PRIMARY as a Postgres superuser or table owner:
  ANALYZE public.tenants;
  -- pg_statistic is a regular heap table and IS replicated via WAL,
  -- so the stats arrive on the replica that Trino reads from.
  ```
  Then verify in Trino:
  ```sql
  SHOW STATS FOR app_pg.public.tenants;
  ```
  Expected: `row_count`, `distinct_values_count`, and `nulls_fraction` are populated (not NULL) for the columns you join and filter on. If they are still NULL: check replication lag on the replica, then flush the Trino metadata cache (`CALL app_pg.system.flush_metadata_cache();`) — see the diagnostic flow in Section 4.1A.

- **Iceberg side** (run from Trino):
  ```sql
  -- Targeted ANALYZE for the columns that matter (join keys + predicate keys)
  ANALYZE iceberg.analytics.events
    WITH (columns = ARRAY['tenant_id', 'event_ts', 'event_type']);
  ```
  Then verify:
  ```sql
  SHOW STATS FOR iceberg.analytics.events;
  ```
  Expected: `distinct_values_count` is non-NULL for the listed columns; `row_count` populated at the table level. (See resource 23 for Iceberg-side ANALYZE details, Puffin file storage, and refresh cadence.)

- **Re-run when either side changes materially.** Postgres: autovacuum usually handles this, but a bulk load may need an explicit `ANALYZE`. Iceberg: re-run `ANALYZE iceberg...` after large ingestions or schema changes.

If after both `ANALYZE` runs you still see PARTITIONED on a small-dim join in EXPLAIN, raise `join_max_broadcast_table_size` (Section 5.5.1) or force `join_distribution_type = 'BROADCAST'` explicitly.

> **Diagnostic technique — `join_distribution_type` session override when stats look correct.** If `SHOW STATS FOR ...` returns populated `distinct_values_count` and `row_count` on both sides (so stats are NOT the issue) but the CBO still picks a partitioned join when you expected broadcast, force broadcast for the current query as a diagnostic:
>
> ```sql
> SET SESSION join_distribution_type = 'BROADCAST';
> -- run your query
> SELECT ... FROM iceberg.analytics.events e JOIN app_pg.public.tenants t ON ...;
> -- then reset
> RESET SESSION join_distribution_type;
> ```
>
> This overrides the CBO's join-distribution decision for the rest of the session. Useful as a **per-query diagnostic**: if BROADCAST measurably improves performance, the root cause was a bad CBO estimate (likely `join_max_broadcast_table_size` set too low for your build size, or a stale `row_count` that's bigger than reality), NOT a data-shape problem. Once you've confirmed BROADCAST is better, fix the root cause (raise the threshold, re-`ANALYZE`, flush metadata cache) rather than leaving the override in place.
>
> **Do not leave `join_distribution_type = 'BROADCAST'` set permanently in a session profile or default catalog properties.** Broadcasting a table that is actually large will OOM workers — every worker needs a complete copy of the build side. The override is a per-query lever, not a global setting.

#### 4.1C MySQL column-stats — the first-column-of-index rule (CRITICAL when the join key is not indexed)

The MySQL connector's statistics retrieval has **one quirk that does not exist on the Postgres connector** and that frequently causes `SHOW STATS FOR billing_mysql.<schema>.<table>` to return NULL for `distinct_values_count` even after a successful native `ANALYZE TABLE` on the MySQL side.

**The rule (verbatim from the Trino MySQL connector docs):** the MySQL JDBC connector returns column-level NDV (`distinct_values_count`) **ONLY for columns that are the FIRST COLUMN of some index in MySQL**. The connector reads NDV from `INFORMATION_SCHEMA.STATISTICS` (the MySQL index-statistics view), and MySQL itself only computes `CARDINALITY` for the leading column of each index. Columns that are not the first column of any index — even after a full `ANALYZE TABLE` — have no NDV stored, so the connector returns NULL.

**Worked example** — a MySQL `invoices` table with these indexes:

```sql
-- On the MySQL replica:
SHOW INDEXES FROM billing_db.invoices;
-- Result (paraphrased):
--   Index name        Columns
--   PRIMARY           (invoice_id)
--   idx_tenant_date   (tenant_id, invoice_date)
--   idx_status        (status)
```

| Column | Is first column of an index? | `distinct_values_count` in `SHOW STATS` after `ANALYZE TABLE billing_db.invoices`? |
|---|---|---|
| `invoice_id` | YES (PRIMARY) | **Populated** |
| `tenant_id` | YES (idx_tenant_date) | **Populated** |
| `invoice_date` | NO (second column of idx_tenant_date) | **NULL** — even after ANALYZE |
| `status` | YES (idx_status) | **Populated** |
| `plan_tier` | NO (not in any index) | **NULL** — even after ANALYZE |
| `amount` | NO | **NULL** |

**The symptom**: you ran `ANALYZE TABLE billing_db.invoices` on MySQL, you verified `pg_stats`-equivalent (`INFORMATION_SCHEMA.STATISTICS` and `INFORMATION_SCHEMA.TABLES`) shows updated values, the Trino metadata cache was flushed — yet `SHOW STATS FOR billing_mysql.billing_db.invoices` still shows `NULL` in the `distinct_values_count` column for your join key `plan_tier`. The Trino CBO then has no NDV for `plan_tier`, picks the wrong build/probe orientation, and your cross-catalog join runs PARTITIONED when it should have been BROADCAST.

**The fix — MySQL 8.0+ histograms (the workaround for non-indexed join keys):**

MySQL 8.0 introduced histogram statistics that are **independent of index structure**. Histograms are computed and stored separately from index cardinality, so they populate NDV for any column you ask for — indexed or not. The connector reads them and surfaces them via `SHOW STATS`.

```sql
-- On the MySQL replica (NOT through Trino — Trino's ANALYZE doesn't work
-- on JDBC connectors; see Section 4.1A):
ANALYZE TABLE billing_db.invoices UPDATE HISTOGRAM ON plan_tier;
ANALYZE TABLE billing_db.invoices UPDATE HISTOGRAM ON amount, invoice_date;

-- Verify the histogram was created (MySQL side):
SELECT *
FROM INFORMATION_SCHEMA.COLUMN_STATISTICS
WHERE SCHEMA_NAME = 'billing_db' AND TABLE_NAME = 'invoices';
-- Should show one row per analyzed column with the histogram JSON.
```

Then flush Trino's metadata cache and re-check:

```sql
-- Trino side:
CALL billing_mysql.system.flush_metadata_cache();
SHOW STATS FOR billing_mysql.billing_db.invoices;
-- distinct_values_count should now be populated for plan_tier.
```

**MySQL histogram tuning knob:** `UPDATE HISTOGRAM ON col WITH 256 BUCKETS` controls the histogram bucket count (default is 100, max 1024). For high-cardinality VARCHAR join keys (e.g., 50K distinct plan tiers), more buckets give a more accurate NDV but cost more storage in `mysql.column_stats`. For typical analytics join keys (≤ 1000 distinct values), the default is fine.

**Practical debugging note: "if `SHOW STATS FOR` still shows NULL after native `ANALYZE TABLE` on MySQL, check whether the join key is the first column of some MySQL index."** This is the single most common reason CBO stats look broken for the MySQL connector. The fix is one of:

1. **Use MySQL 8.0+ histograms** (`UPDATE HISTOGRAM ON <col>`) for the affected column — preferred, no schema change.
2. **Add an index whose first column is the join key** — only if the OLTP team agrees (an index has write cost and an OLTP-side maintenance burden).
3. **Force `join_distribution_type = 'BROADCAST'` per session** as an immediate workaround while you decide on the longer-term fix — see Section 5.5.

**Postgres does NOT have this restriction.** The PostgreSQL connector reads NDV from `pg_stats.n_distinct`, which Postgres `ANALYZE` populates for **every column** (or every column listed in `pg_statistic`, after running per-column `ANALYZE` or default-statistics-target sampling). There is no "first column of an index" rule on the Postgres side. This is one more reason engineers coming from the PostgreSQL connector are surprised when they switch to MySQL and find that `SHOW STATS` returns NULL despite having run native ANALYZE — the connector behavior differs because the underlying database's statistics model differs.

**Stats quality summary across the three connectors you'll touch on this stack:**

| Connector | Stats granularity | What you need to do |
|---|---|---|
| Iceberg | Per-column NDV from Puffin files; per-table row count from metadata | Run Trino `ANALYZE iceberg.<schema>.<table> WITH (columns = ARRAY[...])`. Re-run after large ingest. |
| PostgreSQL JDBC | Per-column NDV and null fraction from `pg_stats` | Run native Postgres `ANALYZE` on the **primary** — `pg_statistic` replicates to the hot-standby replica via WAL (see Section 4.1A; a streaming hot standby rejects `ANALYZE` itself). Primary-side autovacuum handles steady-state. Histograms in `pg_stats.histogram_bounds` are NOT consumed by the connector. |
| MySQL JDBC | Per-column NDV ONLY for first-column-of-index; **histograms cover the rest** | Run native MySQL `ANALYZE TABLE` for index cardinality, AND `ANALYZE TABLE ... UPDATE HISTOGRAM ON col` for any join key that is not the first column of an index. |

### 4.2 What this means in practice

For a cross-catalog join:

1. Each side's scan is planned independently. Each side can have **predicate pushdown** applied (per Section 3).
2. Each side returns its filtered result set to Trino workers.
3. Trino workers build a hash table on one side (the **build side**, usually the smaller one) and stream the other side through it (the **probe side**).
4. The join result emerges from Trino workers.

So the cost of a cross-catalog join is dominated by **how many rows each side returns after its local predicates**. If each side is small, the join is fast. If either side dumps millions of unfiltered rows over the wire, the join will be painful.

### 4.3 Rule of thumb: smaller, more-selective side drives the join

Make sure the join uses a **highly selective predicate on at least one side**. If you can constrain the Iceberg side to a single day's partition (cheap, scans almost nothing) and the Postgres side to a single tenant (cheap, uses an index), the join's data movement is bounded by the smaller of those two result sets. That's a survivable cross-catalog join even on million-row source tables.

If both sides are unconstrained, no — you want to ingest one side into the other store and do it locally.

### 4.4 The JDBC single-split model — why Postgres scans are fundamentally NOT parallel like Iceberg

> **This is the most-confused detail about JDBC connector performance.** Engineers coming from Iceberg-only experience assume "more workers = faster scans" applies everywhere. It does NOT apply to JDBC connectors on non-partitioned tables.

**For a standard non-partitioned Postgres table, Trino creates exactly ONE split for the entire table.** One split → one Trino worker task → one JDBC connection → one thread reading rows. **That is the entire parallelism for the scan.** Adding more Trino workers does NOT speed up a single non-partitioned Postgres table scan — only one worker is doing the JDBC read no matter how many workers the cluster has.

This is **fundamentally different from Iceberg**, where Trino creates **one split per Parquet file** (or per row-group with `read.split.target-size` set appropriately) and reads all splits in parallel across workers.

#### Concrete contrast — 10GB table, same data, two connectors

| Connector | Splits Trino creates | Concurrent reader tasks | Effective parallelism on a 20-worker cluster |
|---|---|---|---|
| **Iceberg** (10GB table, 80 Parquet files) | **80 splits** (one per file) | Up to 80 concurrent JDBC-equivalent reads | All 20 workers each handling ~4 splits in parallel — true parallel scan |
| **PostgreSQL** (10GB non-partitioned table) | **1 split** (the entire table) | **1** reader task | 1 worker, 1 JDBC connection, 1 thread — 19 other workers idle for this scan |

This is why even with PgBouncer, dynamic filtering, and read replicas, a federated query that scans a multi-million-row Postgres table without a selective predicate is bounded by **JDBC throughput on a single thread**, typically **50K–200K rows/second per JDBC connection** depending on row width, network, and Postgres replica speed. A 10M-row scan at 100K rows/sec is **~100 seconds**, single-threaded, with no way to add workers to speed it up.

### Parallelism for Postgres Table Scans: The OSS Trino Limitation

**OSS Trino 467 does NOT support parallel/sharded JDBC reads of a single Postgres table.** There is no `partition-column`, `partition-count`, or equivalent property in the OSS PostgreSQL connector. The GitHub issue requesting this feature (trinodb/trino#389, opened 2019) remains unimplemented in OSS.

The `partition-column` and `partition-count` properties appear in Starburst Enterprise documentation (Starburst's commercial Trino distribution). They are NOT available in open-source Trino 467.

**What you can do in OSS Trino 467:**

1. **Rely on Postgres-side partition pruning (server-side, single JDBC stream):**
   When you query a Postgres declarative-partitioned table with a selective predicate, Postgres prunes child partitions server-side and returns fewer rows over the single JDBC connection. Trino benefits from less data in transit but still reads through one JDBC connection on one worker. No additional configuration needed.

2. **Push down selective predicates (most impactful):**
   Ensure your WHERE clause predicates push down to Postgres (see predicate pushdown section). A highly selective pushed-down predicate reduces rows at source — often more effective than parallelism.

3. **Ingest to Iceberg for analytical parallelism (recommended long-term):**
   For tables that need true parallel analytical reads, replicate Postgres data to Iceberg (via Spark batch or Debezium CDC). Each Iceberg Parquet file becomes a split — 100 files = 100 parallel worker reads across the cluster. This is the production-grade approach for large analytical workloads on this stack.

**OSS vs Starburst callout — properties that do NOT exist in OSS Trino 467:**
- `partition-column` / `partition-count` — Starburst Enterprise only
- `connection-pool.enabled` / `connection-pool.max-size` — Starburst Enterprise only (see connection pool section)

If you encounter documentation or blog posts mentioning these properties, verify whether the source is trino.io (OSS) or starburst.io (Enterprise) before applying to your OSS cluster.

> **Connection-multiplier warning — if you DO use `partition-column` / `partition-count` (e.g., on Starburst, or if OSS support lands in a future Trino release):** these catalog properties make Trino issue **N parallel JDBC queries** to Postgres, one per partition shard. A catalog with `partition-column=id` and `partition-count=8` causes a **single federated query** against an 8-partition table to **open 8 simultaneous Postgres connections** instead of 1 (one shard query per range), each consuming one slot in PgBouncer's pool and one slot under the role's `CONNECTION LIMIT`.
>
> **MySQL note**: even in Starburst Enterprise, `partition-column` / `partition-count` are not implemented for the MySQL connector — parallel JDBC split support exists for Oracle and (in Starburst) for PostgreSQL, but **not for MySQL**. For MySQL the multiplier is **always 1** regardless of Trino distribution. So the formula below applies to Postgres-on-Starburst hypotheticals; the MySQL-specific form is `peak_mysql_connections = max_concurrent_queries × mysql_tables_per_query × 1` (see Section 2A.5).
>
> **Sizing implication for the four-layer connection budget (Section 8.2 sizing table):**
>
> ```
> peak_postgres_connections = max_concurrent_queries × postgres_tables_per_query × partition_count
> ```
>
> Concrete example: with `hardConcurrencyLimit = 10` (resource group), an average federated query scanning 2 Postgres tables, and `partition-count = 8` on those tables, peak connections from Trino can reach `10 × 2 × 8 = 160`. If PgBouncer's `default_pool_size` is set to 50 (the example in Section 8.2's worked example), 110 queries' worth of shard scans queue against the pooler — query latency spikes, and the Postgres role's `CONNECTION LIMIT` is likely to be exceeded.
>
> **What to do when `partition-count > 1`:**
> 1. **Raise `default_pool_size`** on PgBouncer to cover `max_concurrent_queries × max_tables_per_query × partition_count`, OR
> 2. **Lower `partition-count`** to a value that fits within your existing connection budget, OR
> 3. **Lower `hardConcurrencyLimit`** on the Trino federation resource group so the multiplication produces a number that fits, AND
> 4. **Raise the Postgres role `CONNECTION LIMIT`** (`ALTER ROLE trino_reader CONNECTION LIMIT N`) to match the new PgBouncer pool size, so the role-cap doesn't become the bottleneck instead.
>
> The OSS-Trino-467 stack does not expose these properties, so this multiplier only applies if you migrate to Starburst or a future OSS version that adds JDBC parallel splits. **For OSS Trino 467 today the multiplier is 1** — every non-partitioned Postgres scan opens exactly one JDBC connection (Section 4.4), making connection sizing simpler.

### 4.5 Complete PostgreSQL connector session properties reference (OSS Trino 467)

Use `SHOW SESSION LIKE 'billing_pg.%'` to see all properties available on your cluster. The full list of real OSS Trino 467 PostgreSQL connector session properties (with `<catalog>.` prefix required):

| Session property (with catalog prefix) | Default | What it controls | When to use |
|---|---|---|---|
| `<catalog>.domain_compaction_threshold` | `256` | Max distinct values in an IN-list before Trino compacts to BETWEEN range before sending to Postgres | Raise to 1024+ when build side has 300–1000 distinct keys and you're seeing BETWEEN in Postgres slow log |
| `<catalog>.enable_string_pushdown_with_collate` | `false` | Enables **range predicates** (`>`, `<`, `BETWEEN`) on VARCHAR/CHAR columns to push down to Postgres (experimental — collation risk). Does NOT affect `LIKE` (already pushes down for simple patterns in Trino 467) or `ILIKE` (still does not push down even with this flag). | Enable to test whether string range predicates reach Postgres; verify with EXPLAIN first |
| `<catalog>.dynamic_filtering_wait_timeout` | `20s` (PostgreSQL & MySQL JDBC); **`1s`** for Iceberg / Hive / Delta Lake — see DF-defaults table in Section 5.4 | How long Trino waits for a dynamic filter to arrive before launching the probe scan. **NOT a query killer** — when it fires, the scan launches without the DF (potentially much larger), but the query proceeds. | Raise to `30s`–`60s` if build side is slow and probe scan launches before DF is ready. For Iceberg probes, raise from the `1s` default to `15s`+ for batch jobs. |
| `<catalog>.join_pushdown_enabled` | `true` | Whether intra-catalog joins can be pushed down to Postgres (executes join server-side in Postgres) | Set `false` to force join onto Trino workers for debugging; only affects intra-catalog joins |
| `<catalog>.join_pushdown_strategy` | `AUTOMATIC` | `AUTOMATIC` — push down when cost model says beneficial; `EAGER` — push down whenever structurally possible | Use `EAGER` when you know both tables are in the same catalog and Postgres has good indexes |
| `<catalog>.topn_pushdown_enabled` | `true` | Whether `ORDER BY <col> [DESC\|ASC] LIMIT N` patterns are pushed down to Postgres (Postgres uses the index on the sort column and returns only N rows). EXPLAIN signature when pushed: `sortOrder=[col DESC NULLS LAST] limit=N` INSIDE the TableScan with NO separate TopN operator above. EXPLAIN signature when NOT pushed: a separate `TopN [topN=N, orderBy=[...]]` operator sitting ABOVE a bare TableScan. | Default `true` is correct for almost all production use. Set `false` only to debug a query that you suspect is being mis-planned because of TopN pushdown. See Section 3.3A for full details and the `system.query()` fallback when TopN refuses to push (e.g., TopN over a Join, Union, Aggregation, or expression sort key). |
| `<catalog>.aggregation_pushdown_enabled` | `true` | Whether `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`, `GROUP BY` push down to Postgres. Note: aggregate pushdown only fires when ALL of the query's WHERE predicates also push down (see Section 2A.2 for the MySQL parallel — same rule applies to PostgreSQL). **Session property form**: `aggregation_pushdown_enabled` (underscores, catalog-prefixed). **Catalog file property form**: `aggregation-pushdown.enabled=true` (hyphens, dot before `enabled`, no `postgresql.` prefix — it's a base JDBC property). These are different names for the same knob in different contexts; pasting `aggregation_pushdown_enabled=true` (underscores) into the catalog `.properties` file is silently ignored. Same hyphen-vs-underscore convention as `domain-compaction-threshold` / `domain_compaction_threshold` and `join-pushdown.enabled` / `join_pushdown_enabled`. | Default `true` is correct. Set `false` to force aggregation onto Trino workers for debugging. |
| `<catalog>.unsupported_type_handling` | `IGNORE` | What to do when Trino encounters a Postgres type it doesn't natively map (e.g., custom domains, geometric types like POLYGON): `IGNORE` (skip column silently) or `CONVERT_TO_VARCHAR` (read as string). **NOTE: PostgreSQL ENUM types are NOT routed through this setting — they map natively to Trino `VARCHAR` with no configuration required.** This setting only applies to truly unsupported types (geometric, custom domains, etc.). | Set `CONVERT_TO_VARCHAR` when you need to read columns with genuinely unsupported Postgres-specific types. For ENUMs: no config needed, they already appear as VARCHAR. |
| `<catalog>.array_mapping` | `DISABLED` | How to map Postgres array columns. Three valid values: **`DISABLED`** (default — arrays silently omitted from results, no error); **`AS_ARRAY`** (map to typed Trino ARRAY, e.g. `TEXT[]` → `ARRAY<VARCHAR>`, `INTEGER[]` → `ARRAY<INTEGER>`, `BIGINT[]` → `ARRAY<BIGINT>` — element type is preserved, NOT widened); **`AS_JSON`** (Postgres arrays come through as Trino `JSON` — i.e. a VARCHAR JSON representation like `[1,2,3]`). **`AS_JSON` is the workaround for multi-dimensional arrays** (`INTEGER[][]`, `TEXT[][]`) that cannot be represented as flat Trino ARRAY types under `AS_ARRAY`. For 1-D arrays prefer `AS_ARRAY` (typed, lets you use `element_at()`, `cardinality()`, `contains()` directly); use `AS_JSON` only when you need multi-dim array support or want a JSON string representation. **Session property form**: `array_mapping` (underscores). **Catalog file property form**: `postgresql.array-mapping` (prefixed, hyphens). These are different names for the same setting in different contexts. | Enable `AS_ARRAY` for 1-D arrays; switch to `AS_JSON` only if you have multi-dimensional array columns or want the raw JSON string |
| `<catalog>.non_transactional_insert` | `false` | Allow INSERT INTO a Postgres table without a wrapping transaction (faster for bulk loads, unsafe for failures mid-load) | Use for bulk Postgres-to-Postgres copies where partial insert on failure is acceptable |
| `<catalog>.non_transactional_merge_enabled` | `false` | Allow MERGE operations without wrapping transaction | Similar to non_transactional_insert but for MERGE; rarely needed for read-only federation use |

**What does NOT exist as session properties in OSS Trino 467** (common sources of confusion):

| Property people try to SET SESSION | Reality |
|---|---|
| `<catalog>.fetch_size` / `<catalog>.socket_timeout` | JDBC URL parameters in `etc/catalog/<catalog>.properties` (`connection-url=jdbc:postgresql://...?defaultRowFetchSize=1000&socketTimeout=60`). Not session-settable. Require coordinator restart. |
| `<catalog>.partition_column` / `<catalog>.partition_count` | **Starburst Enterprise only**. Do not exist in OSS Trino 467. `SET SESSION billing_pg.partition_column = 'id'` → "Unknown session property." |
| `<catalog>.connection_pool_enabled` | **Starburst Enterprise only**. Use PgBouncer as the connection pool (see Section 8.2). |
| `join_pushdown_enabled` (bare, without catalog prefix) | Fails with "Session property 'join_pushdown_enabled' does not exist." The catalog prefix is **mandatory** for all connector session properties. |

**Quick reference for the most commonly needed session properties:**
```sql
-- raise IN-list threshold (most common tuning need):
SET SESSION billing_pg.domain_compaction_threshold = 1024;

-- disable intra-catalog join pushdown for debugging:
SET SESSION billing_pg.join_pushdown_enabled = false;

-- use eager join pushdown strategy:
SET SESSION billing_pg.join_pushdown_strategy = 'EAGER';

-- wait longer for dynamic filter before scanning Postgres:
SET SESSION billing_pg.dynamic_filtering_wait_timeout = '45s';

-- enable string RANGE pushdown (experimental — note: simple LIKE prefix patterns already push down without this; flag only affects >, <, BETWEEN on VARCHAR/CHAR; ILIKE never pushes down):
SET SESSION billing_pg.enable_string_pushdown_with_collate = true;
```

### 4.6 Cross-catalog consistency semantics — Iceberg snapshot vs Postgres MVCC

A cross-catalog query (e.g., `iceberg.analytics.events JOIN app_pg.public.tenants`) reads from **two storage systems with completely different consistency models** in the same query. Trino has no protocol to coordinate snapshots across catalogs, so you need to understand the gap and design around it.

**The core guarantee — and what's missing:**

- **Iceberg side**: Trino reads a **fixed snapshot at plan time**. The snapshot ID is captured when the query starts and is immutable for the entire query duration. Concurrent commits to the Iceberg table do NOT affect what this query sees. This is Iceberg's snapshot-isolation guarantee.
- **Postgres side**: The JDBC connector opens a connection, issues a single `SELECT` for each split, and streams rows back via a JDBC cursor. Under PostgreSQL's default **`READ COMMITTED`** isolation, **a single `SELECT` statement uses one snapshot taken when the statement begins** — every subsequent `FETCH` from that cursor reads from the same snapshot, regardless of how long the scan takes. **There is no Trino-side knob to change the isolation level.** What this means: for a single uninterrupted scan of a non-partitioned Postgres table (the OSS Trino 467 default — see Section 4.4), the Postgres side IS internally consistent for the duration of that one scan. The consistency gap is **across catalogs** (Iceberg snapshot ≠ Postgres snapshot), not within the Postgres scan itself.
- **No cross-catalog coordination**: Trino has **no protocol** to coordinate snapshot IDs across catalogs. The Iceberg snapshot and the Postgres MVCC state are not synchronized in any way. You cannot ask Trino to "freeze both sides at time T."

**Concrete risks during a long-running federated query — the real failure modes:**

The risk is NOT that a single uninterrupted Postgres scan sees mid-scan writes (it does not, per the cursor-snapshot rule above). The risk is that the Iceberg snapshot and the Postgres snapshot were taken at **different wall-clock times**, and a couple of execution patterns can also produce multiple Postgres snapshots within one Trino query:

- **Cross-catalog skew (the primary risk, always present)**: Iceberg's snapshot is pinned at Trino plan time; the Postgres `SELECT` snapshot is taken when the worker opens its JDBC cursor — which can be seconds later (after Trino schedules the task, dispatches it to a worker, and the JDBC driver establishes the connection). Rows committed to Postgres in that gap appear on the Postgres side but the Iceberg side is frozen to an earlier moment. The join can return rows whose dimension lookup reflects a state that did not yet exist when the fact-table snapshot was pinned.
- **Fault-tolerant execution task retries (`retry-policy=TASK`)**: if a worker task scanning Postgres fails (OOM, node eviction, network blip) and Trino retries it, the **retry opens a new JDBC connection and issues a new `SELECT` — which takes a new `READ COMMITTED` snapshot**. Rows committed to Postgres between the original attempt and the retry are now visible to the retried task but were not visible to any earlier-completed tasks in the same query. This is the most realistic source of mid-query Postgres inconsistency in production. If you run `retry-policy=TASK` (Section 7 / Section on FTE), assume the Postgres scan can see post-query-start writes after a retry.
- **Multi-split parallel reads (only applies if you've enabled `partition-column` / `partition-count` — NOT available in OSS Trino 467, but possible on Starburst or future OSS releases)**: each shard is read by a different worker over a separate JDBC connection. Each connection opens its `SELECT` at a different wall-clock time, so **each shard has its own `READ COMMITTED` snapshot**. Rows inserted between the first and last worker opening their cursors can appear in some shards' results but not others.
- **Tenant row updated AFTER the Iceberg snapshot but BEFORE the Postgres SELECT starts**: a tenant row whose `plan_tier` is updated from `'pro'` to `'enterprise'` between Iceberg-plan-time and Postgres-cursor-open will join with the new value, even though the events being joined to it were captured under the old plan tier.

A correctly written **single-shot, non-retried, non-partitioned** federated query against an OSS Trino 467 cluster has exactly **one** Postgres snapshot (one cursor, one statement). The remaining inconsistency surface is the cross-catalog skew plus retry/multi-split amplification — not per-fetch or per-batch snapshot drift inside a single cursor.

**Mitigations — pick the one that fits your freshness vs consistency requirement:**

| Situation | Mitigation |
|---|---|
| Dim table changes infrequently (e.g., once a day) | Accept the narrow inconsistency window. The probability of an update landing exactly during your query is small; for most analytics this is the right tradeoff. |
| Dim table changes frequently, consistency is critical | Materialize the Postgres dim into Iceberg on a **5–15 min cadence** (Spark or dbt micro-batch). Both sides of the join now live in Iceberg, both pin to snapshots at plan time — full snapshot isolation across the whole query. |
| Need the Iceberg side pinned to a specific wall time (audit reconciliation, reproducible report) | Use Iceberg time travel: `SELECT ... FROM iceberg_table FOR SYSTEM_TIME AS OF TIMESTAMP '...'`. Pins the Iceberg scan to a chosen snapshot. |
| Customer-facing analytics where users may see anomalies | **Materialize the join result nightly** into an Iceberg result table; customers query that table. Single-snapshot, no cross-catalog gap visible to the user. |

**Iceberg `FOR SYSTEM_TIME AS OF` — narrow the inconsistency window:**

If you cannot fully materialize the Postgres side into Iceberg, you can at least pin the Iceberg side to a slightly earlier wall time. This reduces (does not eliminate) the timing skew because the Iceberg side becomes deterministically aligned with a known instant, and the Postgres side will have had a few minutes to settle.

```sql
-- Pin the Iceberg scan to 15 minutes ago to reduce the inconsistency window:
SELECT e.event_type, t.plan_tier
FROM iceberg.analytics.events
     FOR SYSTEM_TIME AS OF (CURRENT_TIMESTAMP - INTERVAL '15' MINUTE) AS e
JOIN app_pg.public.tenants t
  ON e.tenant_id = t.id;
```

**Important caveat:** `FOR SYSTEM_TIME AS OF` only controls **which Iceberg snapshot is used**. It does NOT pin the Postgres side — the Postgres `SELECT` still takes its `READ COMMITTED` snapshot when the worker opens the JDBC cursor at query execution time. The Postgres reads are not deferred or rewound. So this technique reduces the inconsistency surface area (by giving the Postgres side time to quiesce before Iceberg's pinned snapshot) but does not provide cross-catalog snapshot isolation. For full isolation, the only answer is "both tables in Iceberg."

> **Trino syntax note — `FOR TIMESTAMP AS OF` vs `FOR SYSTEM_TIME AS OF`:** The canonical Trino time-travel form is `FOR TIMESTAMP AS OF <timestamp>` (and `FOR VERSION AS OF <snapshot_id>` for pinning to a specific Iceberg snapshot ID). Some documentation and other engines use `FOR SYSTEM_TIME AS OF` (the SQL-standard alias). Trino accepts **both forms** for the Iceberg connector, but `FOR TIMESTAMP AS OF` is the documented canonical form — prefer it in new code.
>
> Use `FOR VERSION AS OF <snapshot_id>` (a specific Iceberg snapshot ID) when you need **fully deterministic reproducibility** — timestamp-based travel can resolve differently if snapshots are expired and cleaned up between runs (the snapshot that was current at that timestamp may no longer exist, in which case the query errors out or — depending on engine behavior — silently resolves to a different snapshot). For audit / regulatory reproducibility where the exact same byte-for-byte result must be reproducible months later, pin a snapshot ID and reference it explicitly.

> **Postgres MVCC nuance — what `READ COMMITTED` actually guarantees for a Trino federated read:** Within a single PostgreSQL `SELECT` statement, the snapshot is taken **once at statement start** and every cursor `FETCH` reads from that same snapshot — this is fundamental PostgreSQL MVCC behavior, not a JDBC-driver feature, and it applies to the Trino JDBC connector's normal scan path. So a **single, uninterrupted, non-partitioned** Trino scan of a Postgres table (the OSS Trino 467 default — one split, one JDBC connection, one `SELECT`) sees a consistent point-in-time snapshot for the whole scan, even if the scan takes minutes. The practical inconsistency cases are: **(a)** the cross-catalog skew between when Trino pins the Iceberg snapshot and when the Postgres `SELECT` opens its cursor (typically a few seconds, but observable under heavy concurrent OLTP writes); **(b)** **fault-tolerant execution** (`retry-policy=TASK`) — a retried task opens a brand-new JDBC connection and a brand-new `SELECT` with a fresh snapshot, so post-original-attempt commits become visible to the retry; **(c)** **multi-split parallel JDBC reads** (Starburst's `partition-column`, or a future OSS feature) — each split is a separate `SELECT` on a separate connection, each with its own start-time snapshot. If any of these matter for your use case, the right fix is the same as the cross-catalog answer: materialize the Postgres table into Iceberg on a regular cadence so the entire query runs against one snapshot.

**Summary — what to tell the SaaS engineer asking "is my federated query consistent?":**

1. Iceberg side: snapshot-consistent for the whole query (pinned at plan time).
2. Postgres side: each `SELECT` statement gets ONE `READ COMMITTED` snapshot taken at statement start; all cursor fetches in that statement read from that one snapshot. A single uninterrupted non-partitioned scan is internally consistent.
3. The real inconsistency sources are: (a) cross-catalog skew (Iceberg pinned at plan time vs Postgres `SELECT` opened later at execution time), (b) **fault-tolerant execution task retries** (each retry opens a new `SELECT` with a new snapshot — assume mid-query writes can become visible if FTE is enabled), (c) multi-split parallel reads (not in OSS Trino 467, but possible on Starburst).
4. No cross-catalog coordination exists in Trino.
5. If the gap matters: materialize the Postgres dim into Iceberg on a regular cadence (5–15 min), or pre-compute the join result. These mitigations also defend against retry-induced inconsistency.
6. `FOR SYSTEM_TIME AS OF` narrows the Iceberg-side timing but does not eliminate the gap.

---

### 4.7 Iceberg time travel + live PostgreSQL — joining a historical snapshot to a live OLTP table

A very common audit / reconciliation pattern: "show me what the user_events table looked like three months ago, joined to the **current** accounts table in Postgres." This works in one Trino query — but it has four sharp edges that you must know before relying on it in production.

#### a) Correct Trino syntax for Iceberg time travel

Trino supports two time-travel forms on Iceberg tables. **Prefer `FOR VERSION AS OF` for audits** — it pins an exact, reproducible snapshot ID. `FOR TIMESTAMP AS OF` is convenient for ad-hoc questions but is less stable across snapshot-expiry runs.

```sql
-- FOR VERSION AS OF (preferred for audits — exact, reproducible)
SELECT e.event_type, a.plan_tier, a.email
FROM iceberg.analytics.user_events FOR VERSION AS OF 4823511203987654321 AS e
JOIN app_pg.public.accounts AS a ON e.user_id = a.user_id
WHERE e.tenant_id = 'customer-123';

-- FOR TIMESTAMP AS OF (resolves to latest snapshot with committed_at <= T)
SELECT e.event_type, a.plan_tier, a.email
FROM iceberg.analytics.user_events
     FOR TIMESTAMP AS OF TIMESTAMP '2026-02-27 00:00:00 UTC' AS e
JOIN app_pg.public.accounts AS a ON e.user_id = a.user_id
WHERE e.tenant_id = 'customer-123';
```

The Postgres side (`app_pg.public.accounts`) is **not** time-traveled — its `SELECT` takes a fresh `READ COMMITTED` snapshot at the moment the worker opens its JDBC cursor at execution time, so you see roughly-current account state (subject to the cross-catalog skew and retry caveats in Section 4.6). Only the Iceberg side is pinned to the historical snapshot. This is intentional for the "historical events vs current account state" pattern.

**To find the exact snapshot ID for "three months ago"**, query the snapshots metadata table:

```sql
SELECT snapshot_id, committed_at
FROM iceberg.analytics."user_events$snapshots"
WHERE committed_at <= TIMESTAMP '2026-02-27 23:59:59 UTC'
ORDER BY committed_at DESC
LIMIT 1;
```

Copy the returned `snapshot_id` and plug it into the `FOR VERSION AS OF` form. This converts a fragile timestamp into a stable, named anchor that won't drift if upstream commits land out of order.

> **Why the double-quotes around `"user_events$snapshots"`.** Iceberg metadata tables in Trino are exposed as virtual sibling tables whose names contain a literal `$` character — `<table>$snapshots`, `<table>$files`, `<table>$manifests`, `<table>$history`, `<table>$partitions`, `<table>$refs`. `$` is **not** a valid character in an unquoted SQL identifier in Trino, so referencing the metadata table without quotes (`SELECT ... FROM iceberg.analytics.user_events$snapshots`) raises a parser error like `mismatched input '$'`. You **must** wrap the table-name portion in double quotes — `"user_events$snapshots"` — to tell the parser to treat it as a delimited identifier. The catalog and schema parts are normal identifiers and do not need quoting; only the `<table>$<metadata>` portion does. The same rule applies to every Iceberg metadata table, every CTE alias that references one, and every `SHOW STATS FOR "table$partitions"`-style call.

#### b) Predicate pushdown and dynamic filtering still work with time travel

Time travel does NOT disable the Iceberg connector's normal optimizations:

- The snapshot ID is resolved at **plan time**. Once resolved, the Iceberg scan proceeds with the **same partition pruning, file-level min/max stats, and manifest filtering** as a non-time-travel query. The only difference is which manifest list it reads from.
- **Dynamic filtering still fires.** When the build side (e.g., `app_pg.public.accounts` filtered to `customer-123`) produces an IN-list of `user_id` values, that IN-list still pushes to the Iceberg probe scan and prunes Parquet files via min/max stats during execution.
- The cross-catalog join itself still executes on Trino workers (Rule 4.1 — there is no cross-catalog pushdown, and time travel doesn't change that).
- WHERE predicates on the time-traveled scan still push down — `WHERE e.tenant_id = 'customer-123'` still becomes partition pruning + file skipping against the historical snapshot's manifest list, not a full-table scan of the historical data.

In short: a time-traveled Iceberg scan is just as efficient as a live Iceberg scan, **provided the snapshot still exists** (see (c) below).

#### c) CRITICAL — snapshot expiration risk is the #1 failure mode

This is where most time-travel-in-federation queries break in production:

- **`FOR TIMESTAMP AS OF` FAILS with an error if the target snapshot has been expired by `expire_snapshots`.** It does NOT silently fall back to a later snapshot. The query errors out at plan time with a message like `No version history table ... at or before <timestamp>`.
- **`FOR VERSION AS OF` ALSO FAILS if the specific snapshot ID no longer exists** (snapshot was expired and physically removed from metadata).
- For audit reports requiring multi-month or multi-year time travel, **check your snapshot retention policy first**. Many default `expire_snapshots` configs retain only **7 days** of snapshots (some configs only 5 days). After expiry, you cannot time-travel to those snapshots — the data files may also be physically deleted by the next orphan-file cleanup run.
- **Trino does NOT have a built-in way to "un-expire" a snapshot.** Once `expire_snapshots` has run, the snapshot is gone. The only recovery is restoring from object-store versioning (e.g., S3 versioning), which is operationally painful.

**Recommended pattern for long-lived audit anchors — create a named branch or tag at the audit-relevant snapshot BEFORE `expire_snapshots` runs:**

```sql
-- Pin a snapshot for audit BEFORE expiry removes it:
ALTER TABLE iceberg.analytics.user_events
  CREATE TAG audit_2026_q1 AS OF VERSION 4823511203987654321;

-- Then query via the tag — survives snapshot expiry indefinitely:
SELECT ... FROM iceberg.analytics.user_events FOR VERSION AS OF 'audit_2026_q1';
```

Tags (and branches) pin the underlying snapshot from being expired. `expire_snapshots` honors all tag/branch references and will NOT delete a snapshot that has a live tag pointing at it. This is the production-correct pattern for "we need to be able to reproduce the Q1 audit report any time in the next 7 years for SOX compliance."

For SaaS apps with regulated retention windows (HIPAA, SOX, GDPR), the operational workflow is:

1. At the end of each quarter (or end of each retention boundary), run an `ALTER TABLE ... CREATE TAG q<n>_<year>_audit AS OF VERSION <current_snapshot_id>;` against each Iceberg table that participates in audits.
2. Configure `expire_snapshots` with its normal retention (e.g., 7 days) — tagged snapshots are exempt and survive.
3. Audit queries always reference the named tag (e.g., `FOR VERSION AS OF 'q1_2026_audit'`), never a raw timestamp or snapshot ID.

#### d) `domain_compaction_threshold` and large build-side IN-lists

When the build side (e.g., Postgres `accounts` filtered for a tenant) produces many matching rows, the dynamic-filter IN-list pushed to the Iceberg probe scan can have **tens of thousands of values**. Trino has a session knob — `domain_compaction_threshold`, default **256** — that controls how big an IN-list can grow before Trino **compacts it down to a `BETWEEN min/max` range** for transmission to the probe side.

Why this matters for federation + time travel:

- For the **Iceberg probe direction**: a compacted BETWEEN range still enables **file-level min/max pruning** against the Iceberg manifest stats. So compaction is "still useful" — it just degrades from "skip files matching no IN-list value" to "skip files whose min/max range doesn't overlap [global_min, global_max]." This is a real loss of selectivity on join keys with wide value spread (e.g., random UUIDs).
- For the **PostgreSQL probe direction** (less common — usually Postgres is the build side): a compacted BETWEEN on a surrogate integer key still works well if Postgres has a btree index. On a VARCHAR key, BETWEEN may not prune effectively (and string-range pushdown is off by default — see Section 3.3).

**Diagnostic — if `EXPLAIN ANALYZE` shows the Iceberg side scanning many more files than you expected even with DF active**, raise `domain_compaction_threshold` to keep the full IN-list intact. The session property is **connector-scoped — it must carry the catalog prefix of whichever catalog owns the SCAN you want to keep the IN-list for** (the side receiving the DF):

```sql
-- Iceberg is the probe (receiving the DF) — raise the threshold on the Iceberg catalog:
SET SESSION iceberg.domain_compaction_threshold = 1000;

-- If Postgres is the probe instead, set it on the Postgres catalog:
SET SESSION app_pg.domain_compaction_threshold = 1000;

-- NOTE: a bare `SET SESSION domain_compaction_threshold = ...` (no catalog prefix) FAILS
-- with "Session property 'domain_compaction_threshold' does not exist" — connector
-- properties always require the `<catalog>.` prefix. See Section 5.4.
```

The trade-off: a larger IN-list takes more memory and is slower to serialize across worker boundaries. For most federation cases with build sides under a few thousand rows, `1000` is a sweet spot.

#### e) Dynamic-filter wait-timeout asymmetry — the Iceberg-probe-side 1s default trap

This catches almost every federated-query author who hasn't read Section 5.2:

- For a **Postgres-build x Iceberg-probe** join (e.g., Postgres `accounts` filtered for one tenant, then joined to time-traveled `user_events`):
  - The probe-side wait timeout that matters is in the **Iceberg catalog** (`etc/catalog/iceberg.properties`)
  - The Iceberg default is **`iceberg.dynamic-filtering.wait-timeout=1s`** — extremely short (note the required `iceberg.` prefix in the catalog properties file)
  - The Postgres build-side scan typically takes **several seconds** (JDBC fetch latency, network, single-split sequential scan)
  - Result: the Iceberg probe scan starts **without the dynamic filter** (DF arrives too late), and you see full-snapshot scans even though DF was correctly planned.
- Fix: raise the Iceberg-side wait timeout — **in the Iceberg catalog file, NOT the PostgreSQL catalog file** (this is a probe-side property):

```properties
# etc/catalog/iceberg.properties — increase to give the Postgres build side time to ship the DF
# CRITICAL: the `iceberg.` prefix is REQUIRED. Writing the bare form
# `dynamic-filtering.wait-timeout=20s` (no prefix) is SILENTLY IGNORED by the Iceberg connector.
iceberg.dynamic-filtering.wait-timeout=20s
```

Or per-session: `SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';` (note: SQL session form uses **underscores** in the property name, not hyphens; prefix is the **catalog name** — `iceberg` if your catalog file is `iceberg.properties`).

> **Connector-property prefix rule (a common beginner trap):** Most connector-specific properties in a catalog `.properties` file require the **connector name** as a prefix — e.g., `iceberg.dynamic-filtering.wait-timeout`, `iceberg.file-format`, `iceberg.compression-codec`, `hive.dynamic-filtering.wait-timeout`, `delta.dynamic-filtering.wait-timeout`. **Without the prefix, the property is silently ignored** (Trino does not error — it just doesn't apply the setting). The PostgreSQL/MySQL JDBC connectors are an exception: they expose `dynamic-filtering.wait-timeout` as a **bare** property (no `postgresql.` / `mysql.` prefix) because it comes from the general JDBC base config. Per the Trino 481 docs (trino.io/docs/current/connector/iceberg.html), the Iceberg property is literally `iceberg.dynamic-filtering.wait-timeout`. When in doubt, check the connector's official property table.

**Common mistake:** setting `dynamic-filtering.wait-timeout` in the `app_pg` (PostgreSQL) catalog file because "the Postgres side is the slow one." This is wrong — the timeout property must live on the **probe side** (the side waiting to receive the filter). For a Postgres-build x Iceberg-probe join, Iceberg is the probe, so the property must be in `iceberg.properties` (with the `iceberg.` prefix). See Section 5.2 for the full direction-dependent treatment.

---

## 5. Dynamic filtering — the optimization that makes cross-catalog joins survivable

### 5.1 What it is

**Dynamic filtering** is a runtime optimization that Trino applies to joins. When Trino builds the hash table on one side of a join, it inspects the actual join-key values it saw, derives a compact filter (typically an `IN`-list of values or a min/max range), and **pushes that newly-derived filter to the other side's scan** while it's still reading. This dramatically reduces how many rows the other side has to return.

For cross-catalog joins between Iceberg and Postgres, dynamic filtering is what turns a query like "join 5,000 user rows in Postgres to 200 million events in Iceberg" from a disaster into a few seconds. The filter derived from the build side (say, 5,000 user IDs) gets pushed into the Iceberg side as `WHERE user_id IN (...)`, which both prunes Iceberg files and reduces the rows streamed back.

#### 5.1.1 CRITICAL — Build/probe direction rule (this is the #1 mental-model error)

> **THE RULE in one line:** the CBO always picks the **SMALLER** table as the **BUILD** side. The dynamic filter is **GENERATED FROM the build side's hash table** and **PUSHED INTO the PROBE side's scan** (the larger table) to prune splits/files before they are read. **DF always flows small → large, not the other way around.**

This is the most-confused detail about DF in cross-catalog federation, and getting it backwards leads to setting timeouts on the wrong catalog, raising thresholds on the wrong connector, and "fixing" the wrong side of the join. Internalize this picture before reading anything else in Section 5:

1. **CBO chooses build side = smaller table.** Hash join needs an in-memory hash table on one side. Smaller = less memory = faster build = chosen as build.
2. **Trino scans build side to completion.** Reads every row, hashes the join key, accumulates the actual distinct join-key values seen.
3. **Trino derives DF from those build-side values.** An IN-list of distinct join keys (or, if too many, a `BETWEEN min AND max` range — see Section 5.4 and the `domain-compaction-threshold` note below).
4. **DF is pushed INTO the probe-side scan.** The probe is the **larger** table. The DF arrives at the probe connector and prunes which files/splits/rows the probe actually has to read.

##### Worked example A — the canonical SaaS shape (small Postgres dimension × large Iceberg fact)

Setup:
- `app_pg.public.customers` — **50,000 rows** (Postgres dimension table, ~10 MB after column pruning)
- `iceberg.analytics.events` — **500,000,000 rows** (Iceberg fact table, ~2 TB across thousands of Parquet files)
- Join: `events.customer_id = customers.id`, filtered to `WHERE customers.plan_tier = 'enterprise'` (say, ~5,000 surviving customer rows)

What happens:
1. CBO sees Postgres `customers` is dramatically smaller → **Postgres `customers` = BUILD side**
2. Trino reads Postgres `customers` (with the `plan_tier = 'enterprise'` predicate pushed down), gets 5,000 `id` values, builds a hash table
3. Trino derives DF = `customer_id IN (uuid1, uuid2, ..., uuid5000)`
4. **DF is pushed FROM Postgres going INTO Iceberg.** The Iceberg `events` probe scan receives the IN-list and uses it to skip Parquet files whose `customer_id` min/max stats don't overlap the IN-list. Only matching files/row-groups are read.
5. Iceberg scans ~5 million rows instead of 500 million — a 100× reduction in I/O.

**Direction of DF flow: Postgres (small, build) → Iceberg (large, probe).** The IN-list filter ORIGINATES from Postgres and FLOWS TO Iceberg. Iceberg is the one receiving the help.

##### Worked example B — the reverse case (small Iceberg dimension × large Postgres fact, rarer)

Setup:
- `iceberg.reference.tags` — **2,000 rows** (small Iceberg dimension)
- `app_pg.public.events_archive` — **80,000,000 rows** (large Postgres-resident fact)
- Join: `events_archive.tag_id = tags.id` filtered to `WHERE tags.category = 'priority'` (say, 50 surviving tag rows)

What happens:
1. CBO sees Iceberg `tags` is much smaller → **Iceberg `tags` = BUILD side**
2. Trino reads Iceberg `tags`, gets 50 `id` values, builds a hash table
3. Trino derives DF = `tag_id IN (1, 5, 17, ..., 8842)`
4. **DF is pushed FROM Iceberg going INTO Postgres.** The Postgres JDBC query Trino issues becomes `SELECT ... FROM events_archive WHERE tag_id IN (1, 5, ..., 8842)`. Postgres applies it server-side using an index on `tag_id`.
5. Postgres returns ~few hundred thousand rows instead of 80 million.

**Direction of DF flow: Iceberg (small, build) → Postgres (large, probe).** This is the case where Postgres ACTUALLY RECEIVES an IN-list pushed from the Iceberg build side. This is also the case where `postgresql.dynamic-filtering.wait-timeout` (the JDBC probe-side timeout, default 20s) is the relevant property — Postgres is the probe here, so the wait-timeout on the Postgres catalog actually matters. (In Example A, Postgres is the build, so its wait-timeout setting is IRRELEVANT — see Section 5.2 and 5.4 for the full treatment.)

##### COMMON MISTAKE — the directional inversion that breaks mental models

> **WRONG**: "Trino pushes a filter from `events` down to `customers` so that Postgres only fetches the matching customers."
>
> **RIGHT**: "Trino pushes a filter from `customers` (the small build side) into `events` (the large probe side) so that Iceberg only reads the matching events."
>
> The dynamic filter does **NOT** originate from the larger table and push down to the smaller one. It **always** originates from the **BUILD side (smaller table after filtering)** and prunes the **PROBE side (larger table)**. The whole point of DF is to use the small side's actual observed values to skip work on the large side — pushing a filter from large to small would be backwards and pointless (you'd be asking the small side to skip rows it was going to scan anyway in a millisecond).
>
> If you find yourself thinking "the events table will push a customer_id filter down to Postgres," stop. **Postgres is the build side — it does not receive a DF. It produces one.** Postgres reads all 5,000 enterprise customers (using whatever predicate you supplied in the SQL, which IS pushed down via Section 3 predicate pushdown — but predicate pushdown is a different, planning-time mechanism), hashes them, and Trino ships the resulting IN-list TO Iceberg.

##### Quick lookup table

| Topology | Build (smaller) | Probe (larger) | DF flow direction | Where `dynamicFilterSplitsProcessed > 0` appears |
|---|---|---|---|---|
| 50M-row Postgres customers × 500M-row Iceberg events (after filter, Postgres = small) | Postgres `customers` | Iceberg `events` | Postgres → Iceberg | Iceberg `TableScan` |
| 2K-row Iceberg tags × 80M-row Postgres archive | Iceberg `tags` | Postgres `events_archive` | Iceberg → Postgres | Postgres `TableScan` |
| Same-catalog Iceberg dim × Iceberg fact | Smaller Iceberg table | Larger Iceberg table | small → large (within Iceberg) | Larger-table `TableScan` |

Now you can read the rest of Section 5 with the right mental model. Every reference to "build side" means the smaller table whose hash table generates the DF; every reference to "probe side" means the larger table that receives the DF and uses it to prune its scan.

#### 5.1.1A CRITICAL — which JOIN TYPES support dynamic filtering, and which JOIN PREDICATES it derives

Dynamic filtering does **not** work for every join shape. Two factual claims here are commonly misstated; getting them wrong leads engineers to rewrite queries in ways that disable the very optimization they wanted to enable.

**Supported join types** (per [trino.io/docs/current/admin/dynamic-filtering.html](https://trino.io/docs/current/admin/dynamic-filtering.html)):

| Join type | Dynamic filtering? | Why |
|---|---|---|
| **`INNER JOIN`** | **YES** | The probe side can safely drop rows that have no match on the build side — exactly what DF enables. |
| **`RIGHT JOIN`** (which Trino executes as a RIGHT INNER on the build/probe assignment) | **YES** | Same logic — the side flagged "right" becomes the probe and can drop unmatched rows. |
| `LEFT OUTER JOIN` (`LEFT JOIN`) | **NO** | A LEFT join must return EVERY row from the left side regardless of whether it matches the right side. Pruning the left side based on a build-side filter would drop rows the query is required to return. DF is unsafe and Trino does not apply it. |
| `FULL OUTER JOIN` | **NO** | Both sides must return all rows; DF would drop required rows. Trino does not apply DF. |
| `CROSS JOIN` / cartesian | **NO** | No join key to derive a filter from. |
| Semi-join (`WHERE x IN (SELECT ...)`) | **YES** | Same shape as INNER for DF purposes. |

> **WRONG — do NOT recommend rewriting INNER JOIN to LEFT JOIN as a way to "enable" dynamic filtering.** Rewriting in that direction **disables** DF entirely (LEFT and FULL OUTER joins do not support it). If the engineer's INNER JOIN already has DF wired up, switching to LEFT JOIN to "expand" results will silently lose the runtime pruning and the probe scan will read everything. If DF is not firing on an INNER JOIN, the cause is one of: (a) wait-timeout fired before build delivered (Section 5.3 / 5.4), (b) build side exceeded the per-driver row cap and DF generation gave up (raise `enable_large_dynamic_filters`), (c) IN-list got compacted to BETWEEN by `domain_compaction_threshold` (Section 5.1.2), (d) join key is VARCHAR and the probe is MySQL (Section 2A.2). The fix is to address whichever of (a)–(d) is firing, NOT to rewrite the join type.

**Supported join predicates** (the `ON` clause shape). This is the second commonly-misstated claim — **dynamic filtering is NOT restricted to equality predicates:**

| Predicate shape on the join key | DF derived? | What gets pushed |
|---|---|---|
| `ON a.id = b.id` (equality) | **YES** | An IN-list of the build-side values (compacts to BETWEEN past `domain-compaction-threshold`). |
| `ON a.id IS NOT DISTINCT FROM b.id` (null-safe equality) | **YES** | Same as equality. |
| `ON a.id < b.id`, `<=`, `>`, `>=` (range / inequality) | **YES, for INNER and RIGHT joins** | A min/max range filter derived from the build-side values. **Per the official Trino DF admin doc, inequality predicates DO trigger dynamic filtering for INNER and RIGHT joins** — this is a frequently-misstated fact. |
| `ON LOWER(a.name) = b.name` (function in ON clause) | NO | Trino cannot derive a clean filter because the join key is a derived expression. |
| `ON a.x = b.x AND a.y = b.y` (compound equi-join) | YES (per key) | Trino derives separate DFs per key column. |

> **WRONG — "dynamic filtering only works on equality (`=`) joins."** This is a common misconception that the Trino docs explicitly contradict. **Inequality predicates (`<`, `<=`, `>`, `>=`, `IS NOT DISTINCT FROM`) on the join key DO trigger dynamic filtering for INNER and RIGHT joins.** Trino derives a min/max range from the build-side values and pushes that range filter to the probe side. So a join like `ON events.event_ts >= windows.start_ts AND events.event_ts < windows.end_ts` (a "between two timestamp boundaries" range join) does benefit from DF — Trino derives `events.event_ts BETWEEN min(windows.start_ts) AND max(windows.end_ts)` from the build side and applies it to the events probe scan. The reduction is range-form (less selective than an IN-list) but still meaningful for partition-pruning on Iceberg or index range-scans on Postgres.
>
> The narrower true statement is: **functions inside the ON clause** (`ON LOWER(a.name) = b.name`, `ON a.x = b.x + 1`) prevent DF — because Trino cannot push a clean derived predicate to the probe scan when the join key on either side is a computed expression. **It is the function in the ON clause that disables DF, NOT the inequality.**

**Disabling DF for debugging:** when investigating "is dynamic filtering changing my query plan?", you can switch it off per query and re-run:

```sql
-- System session property (NO catalog prefix; this one is system-level).
SET SESSION enable_dynamic_filtering = false;

-- Then run the query and compare EXPLAIN ANALYZE.
-- Re-enable when done:
SET SESSION enable_dynamic_filtering = true;
```

Use this **temporarily** to isolate whether DF is the cause of unexpected EXPLAIN output, slow probe scans, or a plan that looks different from what you expected. **Do NOT leave it off in production** — DF is the optimization that makes federated joins survivable; disabling it cluster-wide reverts to scanning the full probe side on every join.

> **`enable_dynamic_filtering` is a system session property — bare form (no catalog prefix).** Unlike `<catalog>.dynamic_filtering_wait_timeout` (which IS per-catalog and requires the catalog prefix), the master on/off switch lives at the system level. The matching config-file form in `etc/config.properties` is `enable-dynamic-filtering=true` (default). The session form uses underscores (`enable_dynamic_filtering`).

#### 5.1.2 `domain-compaction-threshold` — when a precise IN-list silently becomes a BETWEEN range

A dynamic filter is born as a precise **IN-list** of the actual join-key values seen on the build side. But that IN-list can be **compacted** into a `BETWEEN min AND max` range filter before pushdown, and the compaction is what catches engineers off-guard during diagnosis.

**The rule**: when the dynamic-filter IN-list exceeds **`domain-compaction-threshold`** (default **256**), Trino collapses it into `WHERE join_key BETWEEN min AND max`. The IN-list ceases to exist; what hits the probe-side connector is a range predicate.

In one diagram:

```
Build side produces:          Compaction (if > 256):           Probe side receives:
WHERE id IN (...300 IDs...)   --domain-compaction-threshold-->  WHERE id BETWEEN 142 AND 8915
                                                                 (the min and max of those 300 IDs;
                                                                  every value in between is now
                                                                  "included" by the range)
```

**Why this matters for cross-catalog correctness AND performance:**

- **A range filter is much weaker than an IN-list.** If your 300 build-side IDs were `{142, 199, 251, ..., 8915}` (sparse across a wide range), the IN-list would let the probe skip everything not in the set. The BETWEEN keeps every row from 142 through 8915 — including the thousands of IDs you didn't actually want. For Iceberg, the BETWEEN still helps with file-level pruning (manifest min/max stats); for Postgres, it still lets an index range scan work. But row-level selectivity collapses.

- **For VARCHAR join keys on PostgreSQL, BETWEEN COLLIDES with the VARCHAR range-pushdown limitation (Section 3.3 / 3A.2).** A range predicate on a string-type column does NOT push to PostgreSQL by default — the PostgreSQL connector refuses string range pushdown because of collation-correctness concerns (Trino's bytewise VARCHAR comparison can disagree with Postgres's locale-aware collation, silently matching different rows). So the directional consequence is:
  - **Build-side IN-list on VARCHAR ≤ 256 distinct values**: pushes fine as `WHERE col IN ('a','b',...)` — VARCHAR equality / IN-list pushdown is unconditional on PostgreSQL.
  - **Build-side IN-list on VARCHAR > 256 distinct values**: compacted to `BETWEEN 'a' AND 'z'`, which is a RANGE predicate — does NOT push to PostgreSQL. The Postgres scan runs unfiltered, all matching-after-DF filtering happens on Trino workers after the JDBC fetch.
  - For numeric / date join keys, BETWEEN pushes fine (numeric ranges have no collation issue). The collision is VARCHAR-specific.

- **For Iceberg probes, BETWEEN still works** (file-level min/max pruning is range-friendly), but the per-row selectivity inside surviving files is weaker.

**The two tuning levers when compaction is hurting you:**

1. **`domain_compaction_threshold`** (per-catalog session property; `domain-compaction-threshold` catalog config property) — raise to keep the IN-list intact past 256. Connector property — must use the catalog-name prefix. Per-query escape hatch:

   ```sql
   -- Per-query: keep IN-lists up to 2000 entries before compaction.
   -- Replace 'postgresql' with your actual catalog name.
   SET SESSION postgresql.domain_compaction_threshold = 2000;
   ```

   Or in the catalog properties file (cluster-wide for that catalog):

   ```properties
   # etc/catalog/app_pg.properties
   domain-compaction-threshold=2000
   ```

   Cost: larger IN-lists are bigger to ship between coordinator/workers and to embed into the SQL sent to Postgres; very large IN-lists (10K+) can trigger Postgres planner pathologies. Sweet spot is usually 1024-2048 for federation workloads.

2. **`enable_large_dynamic_filters`** (system session property, no catalog prefix) — separate from compaction; this controls whether Trino bothers generating a DF at all when the build side is very large. By default, build sides past a certain row count cause Trino to give up on DF entirely (no IN-list, no BETWEEN — just nothing). Enabling this allows DF generation even for very large build sides that would normally be skipped:

   ```sql
   SET SESSION enable_large_dynamic_filters = true;
   ```

   Use when the build side is in the millions of rows and you're seeing no DF at all on the probe-side EXPLAIN. Cost: more coordinator memory used to track DF state.

**Diagnostic signature**: in `EXPLAIN ANALYZE VERBOSE`, the actual filter values applied to the probe scan are surfaced. If you expected an IN-list of, say, 300 IDs but VERBOSE shows `dynamicFilters = {customer_id BETWEEN 142 AND 8915}`, the build side exceeded `domain-compaction-threshold=256` and was compacted. Raise the threshold OR accept the BETWEEN form OR rewrite the query to make the build side smaller (more selective WHERE). For the full three-knob picture (coordinator-side DF generation limits, JDBC connector-side compaction, and large-build opt-in), see Section 5.4.

> **Predicate pushdown vs. dynamic filtering — one is planning-time, one is runtime.** Engineers new to Trino routinely conflate the two. They are independent mechanisms that often fire on the same query and are complementary:
>
> - **Predicate pushdown is a planning-time mechanism.** Trino encodes the literal WHERE-clause predicates (the ones you typed in your SQL — `WHERE plan = 'enterprise'`, `WHERE created_at > '2026-05-01'`) **into the TableScan node at plan time** and sends them to the connector **before any data is read**. The Postgres connector translates them into the SQL it issues over JDBC; the Iceberg connector uses them for partition pruning and Parquet min/max file skipping. The signal in `EXPLAIN`: the predicate appears inside the `TableScan` node's constraint. (Section 3 covers this in depth.)
> - **Dynamic filtering is a runtime mechanism.** Trino extracts join-key values from the **build side at execution time** (after the build-side scan returns rows), derives a compact IN-list or range, and sends it to the **probe-side scan as a runtime filter**. The probe-side connector applies it as an additional WHERE clause — for JDBC connectors that means adding `AND user_id IN (1, 2, ..., 5000)` to the SQL when it opens the JDBC connection to Postgres/MySQL; for Iceberg it means consulting the filter during split generation and skipping Parquet files whose min/max stats don't overlap. The signal in `EXPLAIN`: a `dynamicFilters = {...}` annotation on the probe-side TableScan; the signal in `EXPLAIN ANALYZE`: a non-zero `dynamicFilterSplitsProcessed`.
>
> Both can fire on the same query — and frequently should. A federated query like `SELECT ... FROM iceberg.events e JOIN app_pg.users u ON e.user_id = u.id WHERE u.plan = 'enterprise' AND e.event_date = DATE '2026-05-20'` ideally has **predicate pushdown** narrowing the Postgres scan (`WHERE plan = 'enterprise'`) and the Iceberg scan (`WHERE event_date = ...`) at planning time, AND **dynamic filtering** narrowing the Iceberg scan further at runtime (after the small filtered users build completes, push `user_id IN (...)` down to Iceberg). The two are not alternatives; missing either leaves performance on the table.

### 5.2 The direction matters

> **Critical asymmetry — `dynamic-filtering.wait-timeout` is a PROBE-side property; it lives on the catalog *receiving* the DF, not producing it:**
>
> For an Iceberg-fact x MySQL-dimension join (MySQL is the build side, Iceberg is the probe side):
> - Trino reads MySQL FIRST to get the dimension rows (build side)
> - Then it uses those join keys to filter the Iceberg scan (probe side)
> - The `dynamic-filtering.wait-timeout` that matters is in the **Iceberg catalog** (the probe side — `etc/catalog/iceberg.properties`), NOT the MySQL catalog
> - Default for Iceberg connector: **1 second** (very short — MySQL rarely finishes in 1s, so this is almost always the binding constraint)
> - Default for JDBC connectors (MySQL, PostgreSQL): **20 seconds** (only relevant when JDBC is the probe side, not the build side)
>
> For reliable dynamic filtering on Iceberg-fact x MySQL-dimension queries, increase the **Iceberg** catalog's wait-timeout:
> ```properties
> # etc/catalog/iceberg.properties — Iceberg is the PROBE, so the timeout lives here.
> # The `iceberg.` prefix is REQUIRED — without it, the property is silently ignored.
> iceberg.dynamic-filtering.wait-timeout=20s   # default 1s — increase to match JDBC
> ```
>
> Or per-session: `SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '20s';` (assuming your Iceberg catalog file is `etc/catalog/iceberg_catalog.properties`; note the underscores in the session-property form).
>
> **Setting `dynamic-filtering.wait-timeout` in the MySQL/Postgres catalog file when JDBC is the build side has ZERO effect** — the build side does not wait for a filter; it publishes one. Only the probe-side catalog's timeout matters. (If you instead set `dynamic-filtering.wait-timeout = 45s` in `app_pg.properties` thinking you're "giving Postgres more time," nothing happens; the Iceberg-probe default of 1s still wins and DF still misses.) The JDBC catalog's wait-timeout setting only governs scans on its own catalog **when JDBC is itself the probe** — i.e., when something else is building a DF for a JDBC scan (rare; covered in Section 5.6).
>
> **Catalog name vs connector name (do not confuse them).** The prefix in `SET SESSION` is always your **catalog name** (the filename in `etc/catalog/`, without `.properties`), **not** the connector type. If your Iceberg catalog file is `etc/catalog/iceberg_catalog.properties`, use:
> ```sql
> SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '20s';
> ```
> Not `iceberg.dynamic_filtering_wait_timeout` — that would be the **connector name** (the value of `connector.name=iceberg` inside the properties file), which Trino rejects with `Session property 'iceberg.dynamic_filtering_wait_timeout' does not exist` unless you happen to have named the catalog file `iceberg.properties`. The reason `SET SESSION iceberg.xxx` examples "work" in many blog posts is purely convention: the catalog file is often named `iceberg.properties` and the catalog name coincidentally equals the connector name. In production, name your catalog files for environment / use case (`iceberg_prod`, `iceberg_analytics`, `iceberg_catalog`) and **always use the actual catalog name as the SET SESSION prefix**. Verify with `SHOW CATALOGS;`.

Dynamic filtering flows from the **build side** to the **probe side**. The build side is usually the smaller side of the join. So for a query like:

```sql
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.users u ON e.user_id = u.id
WHERE u.tenant_id = '...'
```

If Trino picks `users` as the build side (small, after tenant filter), it builds a hash on `u.id`, derives an IN-filter of user IDs, and pushes that to the `events` scan in Iceberg. Iceberg can use it for partition / file pruning if `user_id` correlates with file layout. This is exactly the desired plan.

For Trino-to-Postgres dynamic filtering, the IN-list is sent as part of the SQL pushed to Postgres — the Postgres scan receives `WHERE user_id IN (1, 2, ..., 5000)` and can use an index. If the build side is small enough (< ~1000 values by default; configurable), this is extremely effective.

### 5.3 How to confirm dynamic filtering ran

> ### Diagnostic card — "EXPLAIN shows `dynamicFilters = {...}` but EXPLAIN ANALYZE shows `dynamicFilterSplitsProcessed = 0`"
>
> This is the single most common dynamic-filtering symptom in federated `Iceberg fact × Postgres dim` joins. The plan annotation proves DF was **wired up**; the zero runtime metric proves DF **did not fire in time**. The cause is almost always the **probe-side wait-timeout** firing before the build side (Postgres) finished publishing its filter.
>
> | Item | Value / signal |
> |---|---|
> | **Property name** | `dynamic-filtering.wait-timeout` (sometimes called the "DF waiting timeout") |
> | **Where it lives** | **Probe-side connector catalog** — `etc/catalog/iceberg.properties` for the canonical case (NOT `etc/config.properties`, NOT the Postgres build-side catalog). See Section 5.4 for the full prefix rules. |
> | **Default for Iceberg / Hive / Delta (probe = lakehouse)** | **1 second** — the binding constraint in almost every "Postgres dim × Iceberg fact" join. |
> | **Default for PostgreSQL / MySQL / SQL Server JDBC (probe = JDBC, rarer)** | **20 seconds** |
> | **What happens when it fires** | The probe scan launches **without** the dynamic filter. Iceberg reads files that would have been pruned (or Postgres receives only the original static `WHERE` clauses, not the DF-derived `IN (...)`). The query is NOT cancelled — it just runs slower because pruning didn't happen. |
> | **How it shows up in EXPLAIN** | `dynamicFilters = {df_user_id_0 = ...}` annotation IS present on the probe-side `TableScan` — the optimizer wired it up. |
> | **How it shows up in EXPLAIN ANALYZE** | `dynamicFilterSplitsProcessed = 0` on the probe-side `TableScan` — the runtime metric proves no splits were pruned by the DF. Often paired with `Physical Input:` matching the full table size (no file/row pruning happened). |
> | **How to definitively confirm it was the timeout** | Run `EXPLAIN ANALYZE VERBOSE <query>`. The probe operator stats include a **dynamic-filter wait time** field — a wait time at or near the timeout default (1s for Iceberg, 20s for JDBC) with `dynamicFilterSplitsProcessed = 0` is the smoking gun. |
> | **When to raise it** | Postgres build side is consistently slow (e.g., complex aggregation, secondary-index lookup, slow replica) **AND** the DF would save significant Iceberg I/O. Batch jobs benefit most; raise to `15s`–`60s` for the Iceberg probe. |
> | **How to raise it (config file — persistent, all queries)** | In `etc/catalog/iceberg.properties` on the coordinator (NOT `etc/config.properties` — this is a per-connector catalog property, not a system property): `iceberg.dynamic-filtering.wait-timeout=15s`. **The `iceberg.` prefix is REQUIRED** for the Iceberg connector — bare `dynamic-filtering.wait-timeout=15s` is silently ignored. For JDBC catalogs, the bare form `dynamic-filtering.wait-timeout=30s` is correct (no prefix). See Section 5.4 for the full per-connector table. |
> | **How to raise it (per-query — preferred when only some queries need it)** | `SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '15s';` — the prefix is your **catalog name** (filename in `etc/catalog/` without `.properties`), the property name uses **underscores**. The session form is preferred over cluster-wide changes when only batch jobs benefit. |
> | **Warning — do not raise cluster-wide unless most queries benefit** | Raising the wait-timeout adds that many seconds of latency to **every** query that hits the timeout (i.e., every query where DF doesn't fire). For interactive query workloads (sub-second SLOs), keep the 1s Iceberg default and use the per-session form for the specific batch jobs that need more wait time. |
> | **Warning — raising the build-side catalog's wait-timeout does NOTHING** | The wait-timeout is a probe-side property. Setting `dynamic-filtering.wait-timeout=45s` in `app_pg.properties` when Postgres is the build side has **zero effect** — the build side doesn't wait, it publishes. Only the probe (Iceberg in the canonical case) waits. See the critical callout at the start of Section 5.4. |
> | **Companion knob — try this first if DF is "set up but useless"** | Add a more selective `WHERE` to the build side to reduce build cardinality below `domain-compaction-threshold` (default 256). A small build delivers fast and avoids IN-list → BETWEEN compaction. Often a better fix than raising the timeout. |
> | **Companion knob — `enable_large_dynamic_filters`** | If the build side is in the millions of rows and Trino is skipping DF generation entirely (no `dynamicFilters` annotation in EXPLAIN at all), `SET SESSION enable_large_dynamic_filters = true;` re-enables DF for large builds. This is a different failure mode than the timeout — see Section 5.4. |
>
> **Quick decision tree when you see `dynamicFilterSplitsProcessed = 0`:**
> 1. Is `dynamicFilters = {...}` present in the EXPLAIN plan? If NO → DF was never generated; check `enable_large_dynamic_filters` and build-side stats (Section 5.4). If YES → continue.
> 2. Is the probe Iceberg / Hive / Delta? If YES → the 1s wait-timeout almost certainly fired. Run `EXPLAIN ANALYZE VERBOSE` to confirm wait time, then either (a) add a more selective build-side WHERE, or (b) `SET SESSION <iceberg_catalog>.dynamic_filtering_wait_timeout = '15s';` for this query.
> 3. Is the probe JDBC (Postgres/MySQL)? If YES → the 20s default is usually sufficient; check `domain-compaction-threshold` (Section 5.4) instead — the DF may have been compacted to a BETWEEN range that doesn't push to a VARCHAR column (the more common JDBC failure mode).
>
> Cross-reference: full timeout property semantics, defaults table, prefix rules, and per-session forms in Section 5.4. JDBC vs Iceberg probe-side mechanism differences (why `dynamicFilterSplitsProcessed=1` on JDBC does NOT mean "DF failed") in the JDBC-vs-Iceberg subsection just below.

There are three increasingly conclusive ways to verify DF, in order of strength:

1. **`EXPLAIN (TYPE DISTRIBUTED)`** — *plan-time only, fastest.* Shows that DF *could* fire: look for a `dynamicFilters = {df_user_id_0 = ...}` annotation on the **probe-side scan** node. This proves the optimizer wired up DF; it does **not** prove DF actually pruned anything at runtime (e.g., the build side could have been slow and the probe could have started without it).

2. **`EXPLAIN ANALYZE <query>`** — *actually runs the query, strongest single-shot verification.* In the runtime output, the **probe-side scan** reports `dynamicFilterSplitsProcessed = N`. A **non-zero `N`** confirms dynamic filtering was actively pruning splits during execution. If `N = 0` while the plan annotation was present, the DF was set up but did not fire in time — usually because the build side blew past the wait-timeout for that connector. **The default differs by connector family**: Iceberg / Hive / Delta Lake = **1 second**; PostgreSQL / MySQL / SQL Server JDBC = **20 seconds** (see DF-defaults table in Section 5.4). For the common "Iceberg probe + JDBC build" pattern, the 1-second Iceberg default is the most likely reason DF "didn't fire." See 5.4 for how to raise these. Use `EXPLAIN ANALYZE` whenever you need to *prove* a federated join is using DF before sending it to production.

   > **To verify DF fired at runtime, compare `Input: N rows` to `Output: N rows` on the probe-side TableScan / ScanFilterProject operator.** A large reduction (e.g., `Input: 50M rows → Output: 200K rows`) means the dynamic filter (or static predicate) was applied at the source. Also check `dynamicFilterSplitsProcessed` in the operator stats — a non-zero value confirms DF fired. **There is no `Filtered: X%` field in Trino's EXPLAIN ANALYZE** — that field is from psql's own EXPLAIN, not Trino. See Section 3.4 for the full list of real EXPLAIN ANALYZE fields.

3. **Trino UI (`/ui/query.html?<query_id>`)** — under the query's operator stats, the "Dynamic filters" panel shows how many DFs were generated, how many input rows each one filtered out on each scan, and the timing. Easiest to read after a query has already run; pairs well with `EXPLAIN ANALYZE` for incident investigations.

#### CRITICAL — `dynamicFilterSplitsProcessed` appears on the PROBE side, NOT the build side

This is the single most-confused detail about dynamic filtering. **The metric appears on the side that RECEIVES the filter (probe), not the side that PRODUCES it (build).**

| Join shape | Build side (produces DF) | Probe side (receives DF) | Where `dynamicFilterSplitsProcessed` appears |
|---|---|---|---|
| **Small Postgres dimension × big Iceberg fact** (the canonical federation pattern) | Postgres `users` (small, filtered) | Iceberg `events` (big fact) | On the **Iceberg `TableScan`** node — NOT on the Postgres node. |
| **Reversed: big Iceberg × small Postgres lookup** (rarer) | Iceberg (filtered) | Postgres scan | On the **Postgres `TableScan`** node. |
| **Both sides in same catalog (intra-catalog)** | Smaller side | Larger side | On the larger side's `TableScan`. |

The mental model: Trino builds the hash table from the build side. Once it knows the actual join-key values it saw, it derives an IN-list (or range) and **sends it to the probe-side scan** as additional pruning. The probe-side scan reports how many of its splits it skipped thanks to that filter — that's `dynamicFilterSplitsProcessed`. The build side never reports this metric because the build side does not receive a DF; it produces one.

> **The DF mechanism is identical for same-catalog and cross-catalog joins.** Trino **always** runs the join itself on its own workers (Section 4.1), **always** derives the dynamic filter from the build side at runtime, and **always** pushes it to the probe connector. There is no "special cross-catalog DF mode" vs "intra-catalog DF mode" — DF works the same whether you are joining `iceberg.events × iceberg.users` (same catalog) or `iceberg.events × app_pg.users` (cross-catalog). What differs is **only the probe connector's support for DF** (which determines what gets pruned and how — file splits for Iceberg, IN-list embedded in SQL for JDBC, etc. — see the JDBC vs Iceberg mechanism table below). Catalog co-location is not the lever; the probe-side connector's DF implementation is. Do not assume DF behaves "better" for same-catalog joins or "worse" for cross-catalog — the wiring, wait-timeout property, and `dynamicFilterSplitsProcessed` metric are identical.

**For the typical "Postgres dimension × Iceberg fact" federated join**, look for `dynamicFilterSplitsProcessed > 0` on the **Iceberg scan** (the probe side that benefits from pruning). Looking for it on the Postgres scan will always show zero and lead you to the wrong conclusion.

If `EXPLAIN ANALYZE` shows `dynamicFilterSplitsProcessed = 0` on the probe side, the fix is usually one of:
- Add a more selective WHERE on the build side, so it produces a small enough IN-list (under `domain-compaction-threshold` = 256 by default).
- Raise the per-catalog wait-timeout (e.g. `SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '15s'` for the Iceberg-probe case — note the mandatory **catalog-name** prefix, NOT the connector name; replace `iceberg_catalog` with whatever your catalog file is actually named) if the build side is consistently slow.
- For build sides in the millions, set `enable_large_dynamic_filters = true`.
- Rethink which side should drive the join (CBO may have picked the wrong build side — run `ANALYZE` on both Iceberg sides; see resource 23).

> **Run `ANALYZE TABLE` on Iceberg tables to fix CBO join ordering on federated joins.** When the CBO has bad NDV (number-of-distinct-values) estimates for an Iceberg table, it may pick the wrong build/probe sides — for example, choosing the **large Iceberg fact table** as the build side instead of the small Postgres/MySQL dimension. That inverts the dynamic-filtering direction (now DF flows large → small, useless) and forces a huge in-memory hash table. To fix, run `ANALYZE TABLE iceberg_catalog.schema.events;` via Trino. This populates Iceberg statistics (NDV histograms, row counts, null fractions; stored as Puffin files alongside the table data per the Iceberg spec). The CBO uses those stats to:
>
> 1. Correctly estimate Iceberg row counts after WHERE-clause filtering.
> 2. Pick the **smaller filtered side as the build** (which is what you want — small Postgres/MySQL dim becomes build, large Iceberg fact becomes probe).
> 3. Generate a tight DF that prunes Iceberg files at split-generation time.
>
> Rerun ANALYZE periodically (after large data appends or partition changes) — Iceberg stats are NOT auto-refreshed on writes. **For Postgres**, the equivalent mechanism is server-side `ANALYZE my_table;` in psql (populates `pg_statistic`), which Trino's PostgreSQL connector consumes via JDBC metadata. Running `ANALYZE TABLE app_pg.schema.users;` via Trino is a **no-op for Postgres** — you must run ANALYZE on the Postgres side directly. See resource 23 for the full CBO / statistics treatment.

> **Format note — `dynamicFilterSplitsProcessed` is a SINGLE integer, NOT a fraction.** The actual metric format in `EXPLAIN ANALYZE` / OperatorStats output is `dynamicFilterSplitsProcessed=185` — a single cumulative count of splits that were skipped/processed with the dynamic filter applied. It is **NOT** rendered as a fraction like `"185/200"` (which would imply "185 of 200 splits"). If a doc or blog snippet shows a slash, that is a misreading — the canonical Trino output is one integer. To compute "what percentage of splits were filtered," cross-reference the total split count from the same TableScan node (visible in the distributed plan / operator stats); Trino does not pre-compute the ratio for you.
>
> **JDBC probe-side behavior differs from Iceberg probe-side.** For the typical "Postgres dimension × Iceberg fact" pattern, the metric counts **Parquet file splits skipped** on the Iceberg side, which is the headline number you want. For the **reverse direction** ("Iceberg fact × Postgres dim/fact" where the Postgres scan is the probe) the mechanism is different — see the next subsection on JDBC vs Iceberg DF semantics.

#### JDBC probe-side dynamic filtering vs Iceberg probe-side — same metric name, different mechanism

When dynamic filtering pushes into a **JDBC connector** (PostgreSQL, MySQL) on the probe side, the underlying mechanism is fundamentally different from the Iceberg probe case. The `dynamicFilterSplitsProcessed` metric still appears, but it counts something different — do not interpret the two cases identically.

| Probe side | What DF actually does | What `dynamicFilterSplitsProcessed` counts on the probe TableScan |
|---|---|---|
| **Iceberg** (the canonical pattern) | DF **prunes Parquet file splits** at split-generation time — the planner consults the DF and skips files whose min/max stats fall outside the IN-list / range. Rows in skipped files are never read. | The number of **Parquet file splits** that were skipped or processed with the dynamic filter applied. Higher = more file-level pruning happened. |
| **JDBC** (PostgreSQL, MySQL) | DF is **embedded as an IN-list (or BETWEEN range) into the SQL WHERE clause** that Trino sends to Postgres/MySQL. The downstream engine evaluates the filter **server-side** as part of its own query plan (index scan, seq scan with filter, etc.). There are no "Parquet file splits" — the JDBC connector typically emits one split per scanned table (Section 4.4). | The number of **SQL query invocations** the connector issued with the DF applied. For a typical single-split JDBC scan, this is `1` per scanned Postgres table, NOT a count of files skipped. The metric does not mean "N file splits pruned" because JDBC has no file splits in the Parquet sense. |

**What this means in practice:**

- For an **Iceberg probe** scan, a high `dynamicFilterSplitsProcessed` value (e.g., 185) directly tells you "185 Parquet file splits were affected by the DF" — a meaningful pruning metric you can multiply against average split size to estimate bytes saved.
- For a **JDBC probe** scan, `dynamicFilterSplitsProcessed=1` is NOT a sign that DF failed. It means "1 SQL query invocation went out with the DF embedded." The DF still reduced data returned (Postgres applied the IN-list / BETWEEN server-side), but you cannot read pruning effectiveness from this metric alone. To verify the JDBC DF actually pruned rows, look instead at:
  - **The Postgres slow log** — the SQL sent should contain an explicit `WHERE ... IN (...)` or `BETWEEN ... AND ...` clause derived from the DF. If you only see the original WHERE without the DF predicate, DF did not push into the SQL (timeout, compaction, or version too old).
  - **`Input:` vs `Output:` row counts on the JDBC TableScan node** in `EXPLAIN ANALYZE` — a much smaller `Input:` than the table's full row count, or a large `Input → Output` reduction, is the runtime row-filtering signal that works uniformly across connectors (Section 3.4). Trino does NOT emit a `Filtered: X%` field — use the row-count comparison instead.
  - **`Input:` row count on the JDBC TableScan** vs the table's total row count — a lower-than-full count proves Postgres returned fewer rows because the DF was embedded server-side.

The mental model: for Iceberg, DF is a **file-pruning** optimization measured in splits. For JDBC, DF is a **predicate-pushdown** optimization measured in returned rows. Same Trino feature, two different mechanisms — interpret the metrics accordingly.

### 5.4 Dynamic filtering tuning knobs (Trino 467)

There are three settings you should know about. The defaults are reasonable for most workloads, but understanding them is what differentiates "dynamic filtering kicked in" from "dynamic filtering kicked in but became useless."

> ### CRITICAL CALLOUT — `dynamic-filtering.wait-timeout` is a PROBE-SIDE connector property
>
> This is the single most-misset DF property in production. **`dynamic-filtering.wait-timeout` controls how long the probe-side scan waits before generating splits, giving the build side time to finish and publish its filter.** It belongs to the **PROBE-side** connector — the catalog that is *receiving* the dynamic filter, not the one producing it.
>
> **For Iceberg-probe × JDBC-build joins** (the canonical case — e.g., Iceberg `events` table × PostgreSQL/MySQL `accounts` table where the JDBC dimension is small and Iceberg is the giant fact):
> - Set in the **Iceberg catalog** (`etc/catalog/iceberg.properties`)
> - Default: **1 second** — this is almost always the binding constraint
> - Recommended (config file): `iceberg.dynamic-filtering.wait-timeout = 20s` (the `iceberg.` prefix is REQUIRED — the bare form is silently ignored)
> - The JDBC catalog's timeout setting is **irrelevant here** — PostgreSQL/MySQL is the build side, it doesn't wait for a filter; it publishes one.
>
> **For JDBC-probe × Iceberg-build joins** (less common — the JDBC table is the larger one and is being filtered by an Iceberg-derived DF):
> - Set in the **JDBC catalog** (`etc/catalog/app_pg.properties` or `etc/catalog/billing_mysql.properties`)
> - Default: **20 seconds**
> - Config file form (JDBC connectors): `dynamic-filtering.wait-timeout = 45s` (bare — no `postgresql.` / `mysql.` prefix)
> - Usually sufficient; increase to 45-60s only if the Iceberg build side is large
>
> **Common mistake — DO NOT do this**: Setting `dynamic-filtering.wait-timeout = 45s` in `app_pg.properties` (PostgreSQL catalog) when **Iceberg is the probe side**. This has NO EFFECT — PostgreSQL is the build side in that topology and does not wait for a filter; it publishes one. **Only the probe-side catalog's timeout matters.**
>
> Per-session form (run before your query):
> ```sql
> -- For Iceberg-probe topology (most common):
> -- Session-property name uses UNDERSCORES (dynamic_filtering_wait_timeout),
> -- NOT hyphens. Catalog-name prefix (filename in etc/catalog/ without .properties).
> SET SESSION iceberg.dynamic_filtering_wait_timeout = '20s';
>
> -- NOT: SET SESSION app_pg.dynamic_filtering_wait_timeout = '20s'
> -- (has no effect when PG is build side — PG isn't waiting for anything)
> ```
>
> **How to identify which catalog is the probe**: in `EXPLAIN (TYPE DISTRIBUTED)` / `EXPLAIN ANALYZE`, the `TableScan` operator that shows `dynamicFilters = {...}` and reports `dynamicFilterSplitsProcessed = N` is the probe — that is the side that *consumed* the DF. Tune the wait-timeout on **that** connector's catalog, never the other one.

#### `dynamic-filtering.wait-timeout` — how long the probe waits for the build

When a join executes, Trino must start the probe-side scan eventually. If the build side is still collecting values (because the build-side scan is slow — e.g., a slow Postgres replica), Trino has two choices: wait for the build to finish so the dynamic filter is complete, or start the probe scan now without (or with a partial) dynamic filter.

`dynamic-filtering.wait-timeout` is the upper bound on how long Trino waits before launching the probe scan even if the dynamic filter isn't ready yet.

- **Defaults differ by connector family — there is NO single Trino-wide default**. This is the single most-confused fact about DF wait-timeouts and has caused production regressions. The defaults per the official Trino connector docs:

| Connector family | Session property | Default `dynamic_filtering_wait_timeout` |
|---|---|---|
| **MySQL** ([trino.io/docs/current/connector/mysql.html](https://trino.io/docs/current/connector/mysql.html)) | `<catalog>.dynamic_filtering_wait_timeout` | **20 seconds** |
| **PostgreSQL** ([trino.io/docs/current/connector/postgresql.html](https://trino.io/docs/current/connector/postgresql.html)) | `<catalog>.dynamic_filtering_wait_timeout` | **20 seconds** |
| **SQL Server** | `<catalog>.dynamic_filtering_wait_timeout` | **20 seconds** |
| **Iceberg** ([trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html), config-file property is the **prefixed** form `iceberg.dynamic-filtering.wait-timeout` inside `etc/catalog/iceberg.properties` — the `iceberg.` prefix IS REQUIRED; the bare form `dynamic-filtering.wait-timeout` is silently ignored by the Iceberg connector) | `<iceberg_catalog_name>.dynamic_filtering_wait_timeout` (where `<iceberg_catalog_name>` is the filename in `etc/catalog/` without `.properties`) | **1 second** |
| **Hive** | `<hive_catalog_name>.dynamic_filtering_wait_timeout` | **1 second** |
| **Delta Lake** | `<delta_catalog_name>.dynamic_filtering_wait_timeout` | **1 second** |

  Mnemonic: **JDBC connectors wait 20s, object-store connectors wait 1s** (Iceberg / Hive / Delta inherit the lakehouse-style "go fast, don't block on DF if it isn't ready" default).

  - **Why the asymmetry?** The JDBC connectors default to 20s because launching a probe scan without DF means scanning the entire remote table over a single JDBC connection (expensive — Section 4.4). The lakehouse connectors default to 1s because Parquet scans can apply DFs lazily during split generation, and waiting more than 1s adds noticeable interactive-query latency for queries where DF isn't going to help anyway.
  - **What this means in practice for the "Iceberg fact x Postgres dim" pattern (the most common federation join)**: Iceberg is the probe with a **1s** default — meaning Trino will only wait 1 second for the Postgres-derived DF before launching the Iceberg scan. If your Postgres build side takes longer than 1s to deliver its values, the Iceberg scan starts without the DF and reads more files than necessary. **For batch jobs where DF is the difference between a 5-second query and a 5-minute query, raise it explicitly with `SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '15s'`** (replace `iceberg_catalog` with the actual filename of your Iceberg catalog properties file — the prefix is the **catalog name**, not the connector name).
  - **Verify on your cluster** with `SHOW SESSION LIKE '%dynamic_filtering_wait_timeout%'` and check the catalog-prefixed properties. Each catalog reports its own default; do NOT assume one connector's default applies to another.

The property semantics in all cases: maximum duration Trino will wait for dynamic filters to be collected from the build side before launching the probe-side scan. **This is NOT a query-killer** — when the timeout fires, the probe scan launches *without* the DF (so the scan is potentially much larger), but the query is not cancelled. The query still runs to completion, just slower.

> **To tune the wait-timeout without a Trino coordinator restart, use the catalog session property form:**
>
> ```sql
> -- Replace 'iceberg_catalog' with YOUR actual Iceberg catalog filename (without .properties).
> -- The prefix is the CATALOG NAME, not the connector name.
> SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '5s';
> -- or for a MySQL catalog named billing_mysql:
> SET SESSION billing_mysql.dynamic_filtering_wait_timeout = '5s';
> ```
>
> Note: the catalog-prefixed form is required; the bare `SET SESSION dynamic_filtering_wait_timeout` will error. **And the prefix is your catalog name (filename in `etc/catalog/`), not the connector type** — `SET SESSION iceberg.xxx` only works if the catalog file is literally named `iceberg.properties`.
>
> **CRITICAL — tune the PROBE-side connector's wait-timeout, NOT the build side.** The wait-timeout session property belongs to the **probe-side connector** (the large table being scanned), because it controls how long the *probe* waits for the build to deliver a dynamic filter before launching its own scan. Picking the wrong catalog has no effect.
>
> - If **MySQL is the probe side** (e.g., 50M-row `billing_mysql.invoices` table filtered by a small Postgres-derived IN-list), tune `SET SESSION billing_mysql.dynamic_filtering_wait_timeout = '30s'`. The Postgres build side's `app_pg.dynamic_filtering_wait_timeout` is **irrelevant here** — Postgres isn't waiting for anything; it's producing the build values.
> - If **Iceberg is the probe side** (e.g., 500M-row `iceberg_catalog.analytics.events` filtered by a Postgres-derived user-id list — the most common case), tune `SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '30s'` (where `iceberg_catalog` is the actual filename of your Iceberg catalog properties file — the **catalog name**, not the connector name `iceberg`). The Postgres build-side wait-timeout has no effect on whether Iceberg waits.
> - If **Postgres is the probe side** (rare — usually only when Postgres is the larger of the two), tune `SET SESSION app_pg.dynamic_filtering_wait_timeout = '30s'`.
>
> **Identifying which side is the probe**: in `EXPLAIN (TYPE DISTRIBUTED)`, the table under the join's right input is the probe (build is on the left). In `EXPLAIN ANALYZE`, the `TableScan` operator that shows `dynamicFilters = {...}` and `dynamicFilterSplitsProcessed = N` is the probe — that's the side that consumed the DF. Tune the wait-timeout on **that** connector's catalog, not the other one.
- **Effect of timing out**: probe scan starts without the DF; rows that would have been filtered are read off MinIO / sent over JDBC anyway; the DF is applied later in the operator pipeline but the I/O savings are lost.
- **When to raise it**: if the build side is consistently slow (slow Postgres replica, big aggregation feeding the build), and EXPLAIN ANALYZE shows the probe scan finished without DF having fired. The JDBC `20s` default is generous; the **Iceberg `1s` default is the more common culprit** (see DF-defaults table above) because the Iceberg probe walks away after just 1 second if the Postgres build hasn't delivered yet. For batch jobs against Iceberg probes, raising to `15s`–`60s` is the standard fix; for JDBC probes, `30s`–`60s` covers known-slow build sides. Conversely, for interactive workloads where the build is small, **lowering** to `5s` (from JDBC defaults) is a common pattern to avoid latency tax when DF cannot help. Do not exceed the per-query SLO budget.
- **When to lower it**: if interactive queries are bottlenecked waiting on a build side that doesn't materially benefit the probe (rare).

How to set it — this is a **catalog session property**, so you MUST use the catalog prefix:

```sql
-- Iceberg probe side (most common — Postgres dimension building DF for Iceberg fact scan).
-- IMPORTANT: 'iceberg_catalog' is a CATALOG NAME placeholder (the filename of your
-- Iceberg catalog properties file in etc/catalog/, without .properties). Substitute
-- your actual catalog name. The prefix is NEVER the connector type 'iceberg' unless
-- your catalog file is literally named iceberg.properties.
SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '15s';

-- PostgreSQL probe side (rarer — when Iceberg/another source is building DF for a Postgres scan):
SET SESSION app_pg.dynamic_filtering_wait_timeout = '30s';
```

> **Bare `SET SESSION dynamic_filtering_wait_timeout = '15s'` does NOT work.** Without the catalog prefix, Trino returns `Session property 'dynamic_filtering_wait_timeout' does not exist` because this is a per-catalog property, not a system property. Always prefix with the **actual catalog name** (`iceberg_catalog.`, `app_pg.`, etc.) — that is the filename in `etc/catalog/` without `.properties`, NOT the connector type. Verify with `SHOW CATALOGS;`.

> **Session property uses underscores; config file property uses hyphens.** The session property is `<catalog_name>.dynamic_filtering_wait_timeout` (underscores in the property name after the **catalog-name** prefix — e.g., `iceberg.dynamic_filtering_wait_timeout` if your catalog file is named `iceberg.properties`), but the config-file form inside the catalog's properties file uses hyphens. **For Iceberg/Hive/Delta the config-file line must include the connector-name prefix**: `iceberg.dynamic-filtering.wait-timeout=15s` inside `etc/catalog/iceberg.properties` (the `iceberg.` prefix is required; bare `dynamic-filtering.wait-timeout=15s` is silently ignored by the Iceberg connector). For PostgreSQL/MySQL JDBC connectors the config-file line is the **bare** form `dynamic-filtering.wait-timeout=30s` (JDBC base config — no prefix). Mixing forms is a common footgun: `SET SESSION iceberg.dynamic-filtering.wait-timeout` (hyphens in a SET SESSION) is rejected, as is `dynamic_filtering_wait_timeout=15s` (underscores in a config file). **And remember**: the SET SESSION prefix is always the **catalog name** (filename in `etc/catalog/` without `.properties`), never the connector type.

> **Dynamic filter pushdown also works into JDBC connectors (Postgres, MySQL) since Trino 392 (PR [#13334](https://github.com/trinodb/trino/pull/13334)) — the probe side can be a JDBC source, not just Iceberg.** Before Trino 392, dynamic filtering only pruned splits on lakehouse-style probe sources (Iceberg, Hive, Delta). Since 392, the JDBC connector accepts dynamic filters from the build side and injects them into the SQL it sends to Postgres (as an IN-list or BETWEEN range, subject to `domain-compaction-threshold` — see Section 5.4 below). This means the "Iceberg fact × Postgres dim" pattern AND the reverse "Postgres fact × Iceberg dim" pattern both benefit from DF pruning, as long as you're on Trino 392+.

Or as a coordinator-wide default in the per-catalog properties file:

```
# In etc/catalog/iceberg.properties:
# The `iceberg.` prefix IS REQUIRED. Bare `dynamic-filtering.wait-timeout=15s` is
# silently ignored by the Iceberg connector — Trino will not error, just won't apply the value.
iceberg.dynamic-filtering.wait-timeout=15s
```

> **Catalog `.properties` file prefix rules — depends on the connector.** Connector-specific properties in `etc/catalog/<name>.properties` require the **connector-name prefix** for lakehouse connectors (Iceberg, Hive, Delta), but JDBC connectors (PostgreSQL, MySQL, SQL Server) expose `dynamic-filtering.wait-timeout` as a **bare** property because it comes from the general JDBC base config. **Without the required prefix, the property is silently ignored** — that is the #1 reason a `dynamic-filtering.wait-timeout` setting "had no effect." Inside a SQL session you use the **catalog-name-prefixed** session-property form with underscores (`SET SESSION iceberg.dynamic_filtering_wait_timeout = '15s';` if your catalog file is `iceberg.properties`). Side-by-side:
>
> | Where it goes | Correct line | Reason |
> |---|---|---|
> | `etc/catalog/iceberg.properties` (lakehouse) | `iceberg.dynamic-filtering.wait-timeout=15s` | Iceberg connector property table requires the `iceberg.` prefix. Bare form silently ignored. |
> | `etc/catalog/hive.properties` (lakehouse) | `hive.dynamic-filtering.wait-timeout=15s` | Same rule — `hive.` prefix required. |
> | `etc/catalog/delta.properties` (lakehouse) | `delta.dynamic-filtering.wait-timeout=15s` | Same rule — `delta.` prefix required. |
> | `etc/catalog/app_pg.properties` (PostgreSQL JDBC) | `dynamic-filtering.wait-timeout=30s` | JDBC connectors use the **bare** form (comes from JDBC base config). |
> | `etc/catalog/billing_mysql.properties` (MySQL JDBC) | `dynamic-filtering.wait-timeout=30s` | Same as PostgreSQL — bare form, no `mysql.` prefix. |
> | SQL session (per query) | `SET SESSION iceberg.dynamic_filtering_wait_timeout = '15s';` | Catalog-name prefix (filename without `.properties`) + **underscores** in the property name. |
>
> **How to verify the property took effect**: run `SHOW SESSION LIKE '%dynamic_filtering_wait_timeout%';` after a query. Each catalog reports its current value. If your catalog still shows the connector default after editing the properties file, you likely missed the prefix.

##### Per-connector wait-timeout property forms with verified defaults

Use these per-connector property forms in each catalog's properties file:

```properties
# In etc/catalog/iceberg.properties — connector-name prefix REQUIRED for Iceberg:
iceberg.dynamic-filtering.wait-timeout=15s         # default: 1s — RAISE for batch jobs (Iceberg ships with 1s default)

# In etc/catalog/app_pg.properties — JDBC connectors use the BARE form (no prefix):
dynamic-filtering.wait-timeout=30s                 # default: 20s — raise only if build side known-slow

# In etc/catalog/billing_mysql.properties — same bare form for MySQL JDBC:
dynamic-filtering.wait-timeout=30s                 # default: 20s — same as PostgreSQL
```

> **CRITICAL prefix rule — depends on the connector.** For **Iceberg / Hive / Delta** (lakehouse connectors), the `dynamic-filtering.wait-timeout` property requires the connector-name prefix in `etc/catalog/<name>.properties` — `iceberg.dynamic-filtering.wait-timeout`, `hive.dynamic-filtering.wait-timeout`, `delta.dynamic-filtering.wait-timeout`. **The bare form `dynamic-filtering.wait-timeout=15s` inside an Iceberg catalog file is SILENTLY IGNORED** — Trino does not error, it simply does not apply the setting. For **PostgreSQL / MySQL / SQL Server JDBC** connectors, the property is expressed as the **bare** `dynamic-filtering.wait-timeout=30s` (no `postgresql.` / `mysql.` prefix) because it comes from the JDBC base configuration that all JDBC connectors inherit. (Inside a SQL session: `SET SESSION <catalog_name>.dynamic_filtering_wait_timeout = '15s';` — catalog-name prefix, underscores in the property name regardless of connector type.)

> **These are per-connector properties set in each catalog's properties file.** The defaults are NOT uniform: Iceberg / Hive / Delta = **1 second** (lakehouse style — go fast), and PostgreSQL / MySQL / SQL Server JDBC = **20 seconds** (give the slow JDBC build side a chance). **The Iceberg 1-second default is the most common reason a federated "Iceberg fact × Postgres dim" join shows `dynamicFilterSplitsProcessed=0`** — the Postgres build side takes more than 1s to deliver, and Iceberg has already started its scan unfiltered. The fix is to raise the wait-timeout explicitly: in `etc/catalog/iceberg.properties` use the prefixed form `iceberg.dynamic-filtering.wait-timeout=15s` (the prefix is REQUIRED — the bare form is silently ignored); per-session use `SET SESSION iceberg.dynamic_filtering_wait_timeout = '15s';` (assuming the catalog name is `iceberg`; underscores, not hyphens, in the session-property form).

#### When does the IN-list degrade to a range filter? — three SEPARATE knobs

A dynamic filter starts life as an exact `IN`-list of values seen on the build side. **The IN-list can degrade into a `[min, max]` range filter at TWO independent stages** (and you tune each with different property names — do NOT conflate them):

##### Stage 1 — Coordinator/driver side (controls what Trino GENERATES)

These thresholds determine when Trino's driver decides to switch from an IN-list dynamic filter to a `BETWEEN` range filter while building the DF in memory.

> **CRITICAL — these are NOT bare property names.** The Trino dynamic filtering admin doc ([trino.io/docs/current/admin/dynamic-filtering.html](https://trino.io/docs/current/admin/dynamic-filtering.html)) lists these properties with the **`dynamic-filtering.` prefix**, and there are **separate variants for broadcast vs partitioned joins**. Adding bare `max-distinct-values-per-driver = 1000` to a coordinator config file causes Trino to reject the config at startup with `Configuration property 'max-distinct-values-per-driver' was not used`. **Always use the full namespaced property name** in `config.properties`.
>
> The variants are:
>
> | Full property name (use this in config files) | Applies when... |
> |---|---|
> | `dynamic-filtering.max-distinct-values-per-driver` | Build side is **NOT partitioned** on join keys (broadcast join, or fault-tolerant execution). |
> | `dynamic-filtering.partitioned.max-distinct-values-per-driver` | Build side **IS partitioned** on join keys (regular partitioned/hash join — the common large-join case). |
> | `dynamic-filtering.max-size-per-driver` | Broadcast/non-partitioned, byte-size threshold. |
> | `dynamic-filtering.partitioned.max-size-per-driver` | Partitioned, byte-size threshold. |
> | `dynamic-filtering.range-row-limit-per-driver` | Broadcast/non-partitioned, range-filter row cap. |
> | `dynamic-filtering.partitioned.range-row-limit-per-driver` | Partitioned, range-filter row cap. |
>
> **Pick the variant that matches your join distribution.** For "small Postgres dimension × large Iceberg fact" with `join_distribution_type = 'BROADCAST'` (Section 5.5), tune the **`dynamic-filtering.*`** (non-partitioned) variant. For the default `AUTOMATIC` / `PARTITIONED` shape of large × large joins, tune the **`dynamic-filtering.partitioned.*`** variant.
>
> **Defaults**: the Trino docs page lists these properties without inline numeric defaults; the historically-quoted "~1000 distinct values per driver" rule of thumb applies broadly but the **exact default may differ by variant** (broadcast vs partitioned) and by Trino release. Do NOT hardcode a number based on this doc — always look up the current default on the trino.io admin page for your Trino version, OR query the live cluster with `SHOW SESSION LIKE '%dynamic_filtering%'` (session-property surface) and `EXPLAIN ANALYZE` on a representative join (look for the actual IN-list size vs the build-side distinct-value count to see where the cutoff sits in practice).
>
> **Do NOT add bare property names to `etc/config.properties`.** Bare `max-distinct-values-per-driver = ...` or `max-size-per-driver = ...` fail Trino startup with "configuration property not used." Same trap as the bogus `connection-pool.*` properties in Section 0 — Trino does not silently accept them, it refuses to start.
>
> **Alternative current naming — `small` / `large` variants.** Some Trino releases (and the trino.io admin doc for recent versions) document the per-driver DF size limits under the names **`dynamic-filtering.small.max-distinct-values-per-driver`** and **`dynamic-filtering.large.max-distinct-values-per-driver`** — `small` corresponds to the broadcast/non-partitioned-build case (small build side, full IN-list shipped to every worker) and `large` corresponds to the partitioned-build case (large build side, per-worker partial IN-lists merged). Treat these as the canonically correct current forms to use in new config:
>
> ```properties
> # In etc/config.properties on the coordinator — the current correct forms:
> dynamic-filtering.small.max-distinct-values-per-driver=1000
> dynamic-filtering.large.max-distinct-values-per-driver=100
> ```
>
> **DEPRECATION NOTE**: The older `dynamic-filtering.small-broadcast.*` and `dynamic-filtering.large-broadcast.*` property names were deprecated in Trino 420 (Jun 2023) and removed in Trino 480 (Mar 2026). They still work in Trino 467 but emit deprecation warnings in coordinator logs. Use the forms above (`dynamic-filtering.small.*` / `dynamic-filtering.large.*`). If you also see references to the unqualified `dynamic-filtering.max-distinct-values-per-driver` / `dynamic-filtering.partitioned.max-distinct-values-per-driver` forms in older docs and blog posts, those map to `small` / `large` respectively in the newer naming — same semantics, different prefix. Always cross-check against trino.io for your exact Trino version before deploying.

1. **`dynamic-filtering.max-distinct-values-per-driver`** / **`dynamic-filtering.partitioned.max-distinct-values-per-driver`** — If the build side produces more than this many distinct join-key values **per driver**, Trino switches the dynamic filter from an IN-list to a min/max range filter (`BETWEEN`). This is the most common reason an IN-list silently becomes a range — the build side simply had more distinct keys per driver than the cutoff. The historical rule of thumb is "around 1000 for non-partitioned; smaller for partitioned" but **verify against trino.io/docs/current/admin/dynamic-filtering.html for your exact Trino version**. Choose the broadcast vs partitioned variant based on the join shape.
2. **`dynamic-filtering.max-size-per-driver`** / **`dynamic-filtering.partitioned.max-size-per-driver`** — If the total byte size of the collected values exceeds this limit, Trino also switches to a range filter. This catches the case where the count is low but each value is large (e.g., long string keys, full UUIDs as text).

##### Canonical property names — the `small.*` / `small-partitioned.*` family (Trino admin doc)

The Trino admin doc at [trino.io/docs/current/admin/dynamic-filtering.html](https://trino.io/docs/current/admin/dynamic-filtering.html) documents the per-driver DF size limits under the **`dynamic-filtering.small.*`** (broadcast/non-partitioned build) and **`dynamic-filtering.small-partitioned.*`** (partitioned build) families. These are the real, canonical property names that control whether DF fires based on build-side size — **there is NO property named `dynamic-filtering.small-join.estimated-size-in-bytes`** (that name appears in some incorrect blog posts and AI-generated docs; if you see it referenced, it is fabricated). The real properties are:

| Property | What it controls |
|---|---|
| `dynamic-filtering.small.max-distinct-values-per-driver` | Max distinct values in the IN-list per driver before DF falls back to a min/max range. Broadcast/non-partitioned build. |
| `dynamic-filtering.small.max-size-per-driver` | Max bytes the IN-list can occupy per driver. Broadcast/non-partitioned build. |
| `dynamic-filtering.small.range-row-limit-per-driver` | Row count threshold above which Trino falls back to a range filter (instead of exact IN-list). Broadcast/non-partitioned build. |
| `dynamic-filtering.small-partitioned.max-distinct-values-per-driver` | Equivalent of `small.max-distinct-values-per-driver` for partitioned joins. |
| `dynamic-filtering.small-partitioned.max-size-per-driver` | Equivalent of `small.max-size-per-driver` for partitioned joins. |
| `dynamic-filtering.small-partitioned.range-row-limit-per-driver` | Equivalent of `small.range-row-limit-per-driver` for partitioned joins. |
| `enable-large-dynamic-filters` (config) / `enable_large_dynamic_filters` (session) | Enables larger thresholds (the `large.*` / `large-partitioned.*` families) so big dimension tables can still produce a DF instead of giving up. Off by default — turn on for builds in the millions of rows. |

**Trino's DF selection logic** (worth memorizing): the planner uses an **IN-list up to `max-distinct-values` or `max-size`** limits, and **falls back to a min/max range filter when `range-row-limit` is exceeded**. The fallback is a degradation in selectivity (range > IN-list precision) but still useful for file/partition pruning on the probe side.

> **Range fallback is graceful degradation, NOT total DF failure.** When the number of distinct join-key values exceeds `dynamic-filtering.small.range-row-limit-per-driver` (or the `small-partitioned.*` equivalent), Trino falls back to a **min/max range filter (BETWEEN predicate)** rather than an exact IN-list. **This BETWEEN still pushes to MySQL/PostgreSQL as a range predicate on the join key** — so DF still provides value: it narrows the probe scan to within the observed min/max of the build side. For a build side that produces user IDs in the range `[10042, 10097]`, the probe side receives `WHERE user_id BETWEEN 10042 AND 10097` instead of `WHERE user_id IN (10042, 10051, ..., 10097)`. The JDBC connector will still use an index range scan; Iceberg will still skip files whose stats fall outside the range. **It is NOT "DF failed and the probe scans everything"** — that only happens when DF generation gives up entirely (build side past `enable-large-dynamic-filters` cap, or `wait-timeout` exceeded before build finishes). Range fallback is the middle ground between "exact IN-list" and "no filter at all."

##### Stage 2 — JDBC connector side (controls what Postgres ACTUALLY RECEIVES)

Even if Trino kept the dynamic filter (a **dynamic filter** is a runtime list of values from the build side of a join, pushed to the probe scan to skip rows early) as an IN-list internally (Stage 1 limits not hit), the JDBC connector has a **separate compaction step** before sending SQL to Postgres:

3. **`domain-compaction-threshold`** (default: **`256`**) — If the IN-list produced by dynamic filtering exceeds this many distinct values, the **PostgreSQL connector compacts it to a min/max `BETWEEN` range** before sending the SQL to Postgres. **This is why you might see `BETWEEN` in the Postgres query log even when the Stage-1 `dynamic-filtering.[partitioned.]max-distinct-values-per-driver` limit (~1000 for non-partitioned, smaller for partitioned — see Stage 1 above) has not yet been hit** — the connector did the compaction on its own side, after Trino's coordinator generated a perfectly fine IN-list of, say, 400 values. Note: `domain-compaction-threshold` is a **per-connector catalog property** (lives in `etc/catalog/<catalog>.properties`), NOT a coordinator-level config property — do not put it in `etc/config.properties`.

To see the **raw IN-list** in Postgres logs (not the compacted BETWEEN), raise this threshold in your PostgreSQL catalog properties file:

```properties
# In etc/catalog/app_pg.properties — raise to preserve large IN-lists when sent to Postgres:
domain-compaction-threshold=10000
```

##### Quick summary — three independent knobs

| Property (FULL name — do NOT use bare form) | Where it acts | Default | What it controls |
|---|---|---|---|
| `dynamic-filtering.max-distinct-values-per-driver` (broadcast / non-partitioned build) **OR** `dynamic-filtering.partitioned.max-distinct-values-per-driver` (partitioned build) | Coordinator / driver side | See trino.io/docs/current/admin/dynamic-filtering.html — the value differs per variant and per Trino release; rule of thumb ~1000 for non-partitioned. Do NOT hardcode. | If build produces more distinct values per driver, switch DF from IN-list to range. Controls what Trino **generates** internally. **Bare `max-distinct-values-per-driver` without the `dynamic-filtering.` prefix is NOT a valid config property** — Trino rejects it at startup. |
| `dynamic-filtering.max-size-per-driver` / `dynamic-filtering.partitioned.max-size-per-driver` | Coordinator / driver side | (size-based, see admin doc) | If total byte size of collected values exceeds this, switch to range. Same generation-side limit as above, but size-based. Same warning: full prefix required. |
| `domain-compaction-threshold` (per-connector catalog property, e.g., `app_pg`) | JDBC connector side (PostgreSQL/MySQL/etc.) | `256` | If the IN-list to push down exceeds this, compact it to `BETWEEN` before sending SQL to Postgres. Controls what Postgres **actually receives**. This is a **per-catalog connector property** (lives in the connector catalog `.properties` file, not in `etc/config.properties`); the matching session property is `<catalog>.domain_compaction_threshold` — see the SET SESSION example below. |

- **Why this distinction matters**: a range filter is much weaker than an IN-list. `WHERE user_id IN (1, 5, 17, 42)` prunes everything not in that set. `WHERE user_id BETWEEN 1 AND 42` keeps every row in the range, including the 38 row values you didn't actually want. For Iceberg, range filters still help with file pruning if data is sorted by the key — Iceberg uses **Parquet file min/max statistics** (stored in each Parquet file's footer; Trino uses these to skip entire files without reading them) to decide which files overlap the range and which can be skipped. For Postgres, range filters still help with index range scans. But the row-level pruning is much weaker.
- **Symptom of compaction**: the EXPLAIN shows `dynamicFilters = {user_id BETWEEN ... AND ...}` instead of `dynamicFilters = {user_id IN (...)}` on the **`TableScan` node** (the EXPLAIN output node showing what Trino reads from a source table — its `constraint` field exposes the predicates Trino pushed into the source). Probe-side rows-after-DF count is much higher than expected. If you see this with a build side of only ~300 rows, the cause is the JDBC connector's **`domain-compaction-threshold=256`** (per-catalog, default), NOT the coordinator's **`dynamic-filtering.[partitioned.]max-distinct-values-per-driver`** (which would only trigger past ~1000 distinct values per driver for non-partitioned, smaller for partitioned). **Raise the right knob for the symptom**: bump `domain-compaction-threshold` in `etc/catalog/app_pg.properties` (or per-session `SET SESSION app_pg.domain_compaction_threshold = ...`), not the coordinator-side property.

You can also raise `domain_compaction_threshold` per session for queries where you know the IN-list will be large but still want exact filtering pushed to Postgres:

```sql
-- CORRECT — connector session property requires the <catalog>. prefix.
-- Replace `app_pg` with the actual Postgres catalog name on your cluster.
SET SESSION app_pg.domain_compaction_threshold = 1024;

-- WRONG — bare form fails with "Session property 'domain_compaction_threshold' does not exist".
-- SET SESSION domain_compaction_threshold = 1024;
```

> **Rule: connector session properties require the `<catalog>.` prefix.** Any session property that controls a connector behavior (`domain_compaction_threshold`, `dynamic_filtering_wait_timeout`, `join_pushdown_enabled`, `join_pushdown_strategy`, `enable_string_pushdown_with_collate`, `unsupported_type_handling`, etc.) **MUST be set with the catalog name as a prefix**: `SET SESSION app_pg.<property> = <value>` (replace `app_pg` with your actual catalog name). Bare `SET SESSION <property> = <value>` (without the catalog prefix) only works for **system-level properties** like `join_distribution_type`, `query_max_execution_time`, `query_max_run_time`, `enable_large_dynamic_filters`, `redistribute_writes`. For connector properties, Trino rejects the bare form with `Session property '<property>' does not exist.` This is one of the most common federation footguns — apply the rule to every `SET SESSION` example you paste from blog posts.
>
> **NOTE on OSS Trino 467 vs Starburst**: `partition_column` and `partition_count` do NOT exist as session properties in OSS Trino 467 (they appear only in Starburst Enterprise docs). The properties listed above (`join_pushdown_enabled`, `domain_compaction_threshold`, etc.) are real OSS Trino 467 properties verifiable via `SHOW SESSION LIKE '<catalog>.%'`.

The cost is wire size: a larger IN-list is bigger to ship between coordinator and workers, and (for the JDBC case) bigger to embed into the SQL sent to Postgres. Postgres has its own internal limits on IN-list sizes — pushing the IN-list to 10s of thousands risks query planner pathologies on the Postgres side.

#### `enable_large_dynamic_filters` — opt-in for larger build sides

By default Trino caps the build-side rows it will use to build a dynamic filter — past that cap, no DF is generated at all (separate from compaction; this is "DF generation gives up"). For build sides in the millions of rows, set:

```sql
SET SESSION enable_large_dynamic_filters = true;
```

This raises the build-side row limit so larger builds still produce a DF (often range-form after compaction). Useful for "medium dimension × big fact" patterns (say, 500K-row dimension joined to 500M-row fact). Cost: more coordinator memory used to track DF state.

#### Summary — the three knobs and when to touch them

| Setting | Default | Touch when... |
|---|---|---|
| `<iceberg_catalog_name>.dynamic_filtering_wait_timeout` (Iceberg probe — most common) | **`1s`** (NOT 20s — Iceberg default is 1 second, see Section 5.4 table) | Build side is slow (slow Postgres replica, large aggregation) and probe is launching without DF. **The 1-second default trips constantly on federation joins** because Postgres builds typically take longer than 1s. Raise to `15s`–`60s` for batch; keep at `1s` only for latency-sensitive interactive where DF likely won't help anyway. **Must use the actual catalog name (the filename in `etc/catalog/` without `.properties`) as the prefix in SET SESSION — NOT the connector type `iceberg`** (unless your catalog file is literally `iceberg.properties`). |
| `<pgcatalog>.dynamic_filtering_wait_timeout` (Postgres probe) | `20s` | Iceberg/other catalog is building DF for a Postgres scan and DF arrives too late. Rarer; usually already long enough. |
| `<mysqlcatalog>.dynamic_filtering_wait_timeout` (MySQL probe) | `20s` | Same as Postgres probe — JDBC connectors default to a generous 20s. |
| `hive.dynamic_filtering_wait_timeout` / `delta.dynamic_filtering_wait_timeout` (Hive / Delta probe) | **`1s`** | Same as Iceberg — lakehouse connectors share the 1s "don't block" default. Raise for batch. |
| `<pgcatalog>.domain_compaction_threshold` (e.g. `app_pg.domain_compaction_threshold`) | `256` | Build side has hundreds-to-thousands of distinct values and the IN-list-to-range degradation is killing probe pruning. Raise carefully. **Must use the catalog prefix in SET SESSION** — connector property, not system property. |
| `enable_large_dynamic_filters` (system property — NO catalog prefix) | `false` | Build side is in the millions and no DF is being generated at all. Turn on, accept range-form DF. This is one of the few DF-related session properties that is system-level, so bare form is correct here. |

If you remember nothing else: **a missing DF is almost always either (a) build side too slow → bumped into `wait-timeout`, or (b) build side too large → exceeded the row cap (`enable_large_dynamic_filters` needed) or got compacted to a range (`domain_compaction_threshold`)**.

### 5.5 Broadcast vs partitioned join — interaction with dynamic filtering

The join distribution type changes how effective dynamic filtering is.

- **Broadcast join** (`SET SESSION join_distribution_type = 'BROADCAST'` or per-query): the build side is sent to every worker; every worker has the full hash table; every worker can therefore generate a **per-value DF** with the full build-side value set. DF is at its most precise.
- **Partitioned (hash / repartitioned) join** (`'PARTITIONED'`): both sides are hash-partitioned across workers; each worker has only its slice of the build side and generates a DF from that slice. The coordinator then **merges** the per-worker DFs before pushing to the probe scan. Merging works for IN-lists (union) and ranges (min-of-mins, max-of-maxes), but the result is usually weaker than the broadcast case — and for highly skewed keys the merged range may collapse to nearly the full domain.

Practical rule: for **federated joins with small-to-medium build sides** (think: filtered Postgres rows fanning out to Iceberg), prefer broadcast joins. The default is `AUTOMATIC`, which picks based on the CBO's estimate of the build-side size — see resource 23 on CBO statistics for why `ANALYZE TABLE` on the Iceberg side matters here. Force broadcast if you know the build will be small:

```sql
-- system session property — no catalog prefix
SET SESSION join_distribution_type = 'BROADCAST';
```

**Concrete: when small dim (e.g., 5K rows in Postgres) × large Iceberg fact, BROADCAST is the single most powerful lever.** Without `ANALYZE` stats on the Iceberg side, the CBO often picks `PARTITIONED` because it can't size the Iceberg side accurately, which triggers a repartition shuffle of the giant fact table for no good reason. Forcing `BROADCAST`:

- Sends the 5K-row build side to every worker (cheap — ~a few MB of network).
- Avoids any shuffle of the large Iceberg fact (huge savings).
- Maximizes DF precision (every worker has the complete build set, so the DF pushed to Iceberg is a full IN-list rather than a per-partition union).

Typical speedup observed in practice for the "5K-row Postgres lookup × 1B-row Iceberg fact" pattern: **2× to 10×** vs. the default `AUTOMATIC` when the CBO mis-estimates. Pair `BROADCAST` with selective WHERE on the Postgres side and `ANALYZE TABLE` on the Iceberg side, and the query plan is roughly as good as it can get for federation.

For very large builds where broadcast would OOM workers, partitioned is necessary and you accept the DF-precision tradeoff.

> **FAST WORKAROUND while you're fixing CBO stats — force BROADCAST at the session level.** If a production cross-catalog join is misbehaving RIGHT NOW because the MySQL/Postgres side has missing or stale stats (e.g., `SHOW STATS FOR ...` returns NULL — see Section 4.1C for the MySQL first-column-of-index trap), you do NOT need to wait for the DBA to run `ANALYZE` and the metadata cache to refresh. Just force broadcast for the affected query in your current Trino session:
>
> ```sql
> -- Force broadcast join immediately — works regardless of CBO estimates or missing stats:
> SET SESSION join_distribution_type = 'BROADCAST';
>
> -- ... run your join query (or your ad-hoc dashboard refresh) ...
> SELECT ... FROM iceberg.analytics.events e
>   JOIN billing_mysql.billing_db.invoices i ON e.invoice_id = i.invoice_id
>   WHERE i.plan_tier = 'enterprise';
>
> -- Reset when you're done (or just close the session):
> RESET SESSION join_distribution_type;
> ```
>
> **Use only when the build side is comfortably under cluster memory per worker.** Forcing BROADCAST on a multi-gigabyte build side will OOM workers. As a rough rule of thumb: if you expect the smaller side after filtering to be **< 100MB**, BROADCAST is almost always safe; **100MB–1GB**, raise `join_max_broadcast_table_size` first (Section 5.5.1) and verify with `EXPLAIN`; **> 1GB**, leave it on PARTITIONED — the repartition shuffle is the lesser evil. For the canonical "small Postgres/MySQL dimension × big Iceberg fact" pattern, BROADCAST is correct and gives 2-10× speedup when stats are missing or stale. **This is the right tactical move while you're queuing up the proper fix** (running `ANALYZE` on the slow side, adding histograms on MySQL, flushing the metadata cache) — it gets the query unstuck in seconds without waiting on the underlying database team.

> **Dynamic filtering still helps even when stats are wrong.** Dynamic filtering is **enabled by default in OSS Trino 467** (controlled by `enable_dynamic_filtering = true` and the per-connector `dynamic-filtering.wait-timeout` — defaults are connector-specific: **1s for Iceberg / Hive / Delta Lake**, **20s for PostgreSQL / MySQL / SQL Server JDBC**; see Section 5.1 / 5.4). At runtime, it derives an IN-list or range from whichever side Trino ultimately picked as the build and pushes it into the probe-side scan **even if the CBO chose a suboptimal join distribution due to bad stats**. So a cross-catalog join with missing CBO statistics is rarely a total catastrophe — DF often saves a meaningful chunk of work on the probe side by reducing the rows actually fetched, even when the join distribution itself is wrong. Combine BROADCAST forcing (above) with DF (already on by default) and most stats-broken federation joins survive long enough for you to fix the underlying ANALYZE issue.

#### 5.5.1 The broadcast threshold property — `join_max_broadcast_table_size`

When `join_distribution_type = 'AUTOMATIC'` (the default), the CBO compares the **estimated build-side size** against a configurable threshold to decide broadcast vs. partitioned. **This threshold is `join_max_broadcast_table_size` — it is the operative tuning knob, not `query.max-memory-per-node`.**

| Form | Name | Default | Where it lives |
|---|---|---|---|
| Session property | `join_max_broadcast_table_size` | **`100MB`** | `SET SESSION join_max_broadcast_table_size = '...'` |
| Config-file property | `join-max-broadcast-table-size` | **`100MB`** | `etc/config.properties` on the coordinator |

**Semantics:** maximum estimated size of the build-side table to allow a broadcast join. When the CBO estimates the build side **> this threshold**, Trino switches to a **PARTITIONED** (hash) join instead of broadcasting.

> **CLARIFICATION — the threshold compares against the ESTIMATED build-side size after column pruning and filter pushdown, NOT the raw table size on disk.** This is a frequent source of confusion. The CBO does NOT compare `100MB` against your table's full byte count in Iceberg or Postgres. It compares against the **post-pruning estimate**: the size after the optimizer has accounted for which columns the query projects, which filters push down to the source, and which rows survive those filters. Example: the `tenants` table is **60MB raw** with 20 columns and 5M rows, but your query is `SELECT id, name FROM tenants WHERE plan_tier = 'enterprise'` — only 3 columns projected, and the filter cuts to ~200K enterprise tenants. The CBO's estimate of the **build-side size at join time** might be closer to **8–10MB**, well under the 100MB default. **This is why accurate column statistics matter so much for federation:** the CBO uses per-column NDV and null fraction (from `ANALYZE`) to estimate post-filter row counts and post-projection byte sizes. Stale or missing stats inflate the estimate, push the join past the threshold unnecessarily, and you end up with REPARTITIONED on a join that should have been BROADCAST.

**Common tuning scenario** — your dimension table is, say, 200MB after filtering (a bit too large for the default), but broadcasting is still much cheaper than repartitioning a billion-row fact table:

```sql
-- Per-session: raise to 200MB so the CBO chooses BROADCAST for a 200MB build side
SET SESSION join_max_broadcast_table_size = '200MB';
```

Or cluster-wide in `etc/config.properties`:

```
join-max-broadcast-table-size=200MB
```

**Do NOT confuse with `query.max-memory-per-node`.** That property is the **per-node memory cap for any single query** (cluster-wide memory governance). It is unrelated to the broadcast-threshold decision. Raising `query.max-memory-per-node` does not change which join distribution the CBO picks — it just lets queries use more memory before being killed.

**Relationship to `join_distribution_type`:**

```sql
-- Default: CBO decides using join_max_broadcast_table_size as the cutoff
SET SESSION join_distribution_type = 'AUTOMATIC';

-- Force broadcast regardless of CBO estimate (ignores join_max_broadcast_table_size)
SET SESSION join_distribution_type = 'BROADCAST';

-- Force partitioned regardless of build size
SET SESSION join_distribution_type = 'PARTITIONED';
```

When `join_distribution_type = 'AUTOMATIC'`, the threshold applies. When forced to `BROADCAST` or `PARTITIONED`, the threshold is irrelevant — Trino obeys the override.

**AUTOMATIC's behavior when statistics are missing — the documented fallback:**

When `join_distribution_type = 'AUTOMATIC'` and no table statistics are available, the CBO cannot compute a cost. **Per the Trino docs, the CBO falls back to the `ELIMINATE_CROSS_JOINS` join-enumeration strategy** — a deterministic enumeration that prefers join orders eliminating cross products but does not attempt cost-based distribution selection. **In practice, that strategy defaults to REPARTITIONED (partitioned hash) distribution** for the join operator — not arbitrary heuristics, and not broadcast. This is the most common reason a join that should have been broadcast turns out partitioned: stats are missing on one or both sides, the CBO can't size the build, and `ELIMINATE_CROSS_JOINS` lands on REPARTITIONED.

**Practical rule: no stats = expect REPARTITIONED. Fix: run `ANALYZE` on both sides.** If you see an unexpected `RemoteExchange[REPARTITION, HASH, ...]` (or `Distribution: PARTITIONED`) on a join you believed had a small build side, the first diagnostic step is `SHOW STATS FOR <table>` on both sides — if any row shows `NULL` for `row_count` or `distinct_values_count` on the join keys, the CBO is operating blind. Run `ANALYZE TABLE <iceberg_table>` (Iceberg side) and confirm Postgres stats via `ANALYZE` on the **primary** (NOT the read replica — a streaming hot standby will reject `ANALYZE` with `cannot execute ANALYZE in a read-only transaction`; `pg_statistic` then replicates to the replica via WAL, and Trino reads it through the JDBC connector's `pg_stats` lookup — see Section 4.1A) before forcing `BROADCAST` manually.

##### What actually happens when the build side exceeds `join-max-broadcast-table-size` (100MB default) — BROADCAST vs PARTITIONED in concrete terms

This is one of the most-misunderstood transitions in Trino: people assume that when broadcast "fails" something terrible happens, or that one side is "streamed" while the other is held in memory. **Neither is correct.** Here is what the two distributions actually do:

**BROADCAST distribution (build side under 100MB by default):**
- Build side (small dimension table) is read once and **REPLICATED to every worker** — every worker gets the same complete copy of the build-side rows.
- Build side is **NOT shuffled by join key** — it goes to all workers regardless of key.
- Probe side (large fact table) is scanned locally on each worker; each worker only processes its own slice of the probe.
- **No network shuffle of the probe side** — this is the headline savings. The probe never crosses the network beyond reading its own splits.
- DF works at maximum precision: every worker has the FULL build-side value set, so the DF pushed to the probe is the complete IN-list (not a per-partition union).

**PARTITIONED (hash-shuffle) distribution (build side estimated to exceed 100MB, OR stats are missing and CBO defaults to REPARTITIONED):**
- **BOTH sides are hash-redistributed across workers by the join key.** Build side is shuffled. Probe side is also shuffled.
- Each worker ends up holding only the rows from BOTH sides whose join-key-hash falls into its assigned partition.
- **Neither side is "streamed past the other."** Both go through a redistribution shuffle. The shuffle adds network cost on both sides.
- DF still works, but each worker only sees its slice of the build-side keys; per-worker DFs are merged by the coordinator before pushing to the probe. The merged DF is usually weaker than the broadcast case, especially for IN-lists (union of slices) and ranges (min-of-mins, max-of-maxes).

**Concrete worked example — 50M-row Postgres customers × 500M-row Iceberg events with NO selective WHERE filter:**

- `app_pg.public.customers` has **50,000,000 rows** at ~200 bytes/row after column pruning = **~10 GB**.
- 10 GB is **100× the default `join-max-broadcast-table-size=100MB`**.
- CBO (assuming stats are present) sees the build estimate of 10 GB and concludes broadcast would OOM workers (every worker would need a 10 GB hash table) → **chooses PARTITIONED**.
- Plan: `RemoteExchange[REPARTITION, HASH, [customer_id]]` above the Postgres scan AND `RemoteExchange[REPARTITION, HASH, [customer_id]]` above the Iceberg scan. Both sides shuffle.
- At runtime: Trino reads all 50M Postgres rows (single-split, single JDBC connection — see Section 4.4 for why the JDBC scan can't parallelize), hash-redistributes them across workers by `customer_id`. Iceberg's 500M rows are also scanned (in parallel by file) and hash-redistributed by `customer_id`. Each worker performs its local hash join on its assigned partition.
- **This is still correct and still completes successfully.** It just adds a network shuffle step for BOTH sides, and Postgres's single-split scan becomes the throughput bottleneck (you cannot parallelize a Postgres-connector scan in OSS Trino 467 — Section 4.4).

**Implication**: PARTITIONED is not a failure mode. It's the right plan when the build side genuinely doesn't fit a broadcast budget. The two questions to ask when you see PARTITIONED on a join that you wish were BROADCAST are:

1. **Can you make the build side smaller?** A more selective WHERE filter on Postgres (e.g., `WHERE plan_tier = 'enterprise'`) might cut the 50M-row build to 200K rows = ~40 MB, well under the 100MB broadcast threshold. The CBO will then pick BROADCAST automatically.
2. **Is the build side estimate correct?** Run `SHOW STATS FOR app_pg.public.customers` — if the column NDVs are NULL or row_count is NULL, the CBO is guessing and might be over-estimating. Run `ANALYZE` on the Postgres **primary** (NOT the replica — see Section 4.1A; `pg_statistic` will propagate to the replica via WAL), flush the Trino metadata cache, and re-EXPLAIN.
3. **Is broadcast safe even though it exceeds the default?** If you genuinely can't filter the build side smaller, but your workers have enough heap (`query.max-memory-per-node` is generous and there's slack), you can raise `join_max_broadcast_table_size` to, say, `2GB` and force broadcast for the query. This trades memory for shuffle elimination — sensible when the probe side is 100× larger than the build side and the shuffle cost dominates.

If none of those help, PARTITIONED is correct. Accept it. The join will run; the cross-catalog shuffle adds latency but does not break anything. Dynamic filtering still fires through the merged-DF path described above.

> **The session property `join_reordering_strategy` (config: `join-reordering-strategy`) must be set to `AUTOMATIC` (the default in modern Trino) for the CBO to reorder joins based on statistics.** If someone has previously set it to `ELIMINATE_CROSS_JOINS` or `NONE` cluster-wide, the CBO will not pick a different join order even with perfect stats — it will execute joins in the literal order written in the SQL. Verify with `SHOW SESSION LIKE 'join_reordering_strategy'`; if the value is anything other than `AUTOMATIC`, re-enable it (`SET SESSION join_reordering_strategy = 'AUTOMATIC'`) before relying on CBO behavior for federated joins.

#### 5.5.2 Reading join distribution out of EXPLAIN — `Distribution: REPLICATED` vs `Distribution: PARTITIONED`

**The join distribution shows up on the Exchange operator above the join in EXPLAIN output**, NOT as a `Join[BROADCAST]` / `Join[PARTITIONED]` annotation on the join node itself. Use the `Distribution:` line or the `Exchange[Type=...]` block to read it.

Two views of the same information — the **stylized conceptual form** (good for documentation and teaching) and the **literal Trino 467 output format** (what you actually grep against `EXPLAIN (TYPE DISTRIBUTED)` output):

```
-- Broadcast join — stylized conceptual form:
Exchange[Type=REPLICATE]
    TableScan[app_pg:public.tenants]
-- The key marker is REPLICATE / "Distribution: REPLICATED" on the Exchange feeding the build side.

-- Broadcast join — verbatim Trino 467 output (what real EXPLAIN prints):
RemoteExchange[REPLICATE, BROADCAST, []]
    TableScan[app_pg:public.tenants, ...]

-- Partitioned (hash) join — stylized conceptual form:
Exchange[Type=REPARTITION]
    TableScan[app_pg:public.tenants]
-- Or equivalently rendered as "Distribution: PARTITIONED" on the Exchange above the join.

-- Partitioned (hash) join — verbatim Trino 467 output:
RemoteExchange[REPARTITION, HASH, [tenant_id]]
    TableScan[app_pg:public.tenants, ...]
```

**Use the literal forms when grepping real EXPLAIN output.** The stylized `Distribution: REPLICATED` / `Distribution: PARTITIONED` and `Exchange[Type=...]` notations are conceptual descriptions for documentation purposes. Real Trino 467 `EXPLAIN (TYPE DISTRIBUTED)` output emits `RemoteExchange[REPLICATE, BROADCAST, []]` for the broadcast case and `RemoteExchange[REPARTITION, HASH, [<join_key_cols>]]` for the partitioned case — these are the strings that will actually match against your captured plans. Grep for `REPLICATE` and `REPARTITION` first; both forms (stylized and literal) carry those tokens.

**How to read this in practice:**

```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ...
FROM iceberg.analytics.events e
JOIN app_pg.public.tenants t ON e.tenant_id = t.id;
```

Walk down to the `InnerJoin` (or `LeftJoin`/etc.) node and look at the Exchange feeding its build (right) side:
- **`Exchange[Type=REPLICATE]`** / **`Distribution: REPLICATED`** → broadcast join (the build side is copied to every worker).
- **`Exchange[Type=REPARTITION]`** / **`Distribution: PARTITIONED`** → partitioned/hash join (both sides shuffled on the join key).

If you see `REPLICATE` on the build-side Exchange, the CBO concluded the build was below `join_max_broadcast_table_size` (or `join_distribution_type` was forced to `BROADCAST`). If you see `REPARTITION`, either the build estimate exceeded the threshold, the type was forced to `PARTITIONED`, or stats are missing/wrong (run `ANALYZE` to fix).

There is **no `Join[BROADCAST]` or `Join[PARTITIONED]` token** in real Trino EXPLAIN output — if you see that in an answer or blog post, it's a fabrication. Read the **Exchange / Distribution** line instead.

#### 5.5.3 Full broadcast-join EXPLAIN plan tree — what the probe side does (and does NOT) show

The single most common fabrication when describing broadcast-join EXPLAIN output is to put a `RemoteExchange[REPARTITION, HASH, [<join_key>]]` above the probe-side (large Iceberg) scan with a comment like "no shuffle in broadcast mode." **That is self-contradictory and wrong.** `REPARTITION, HASH` IS a network shuffle by the join key — that is exactly the behavior broadcast mode is designed to avoid. In a correct broadcast join, **the probe side has NO repartition exchange above its scan**; each worker reads its own local slice of the probe table directly.

**Correct broadcast-join plan tree (verbatim Trino 467 `EXPLAIN (TYPE DISTRIBUTED)` shape):**

```
-- Query:
-- SELECT t.tenant_name, COUNT(*) AS n
-- FROM iceberg.analytics.events e          -- probe (large fact, ~500M rows)
-- JOIN app_pg.public.tenants t             -- build (small dim, ~5K rows after WHERE)
--   ON e.tenant_id = t.id
-- WHERE t.plan_tier = 'enterprise'
-- GROUP BY t.tenant_name;

Fragment 0 [SINGLE]   -- runs on the coordinator: final aggregate + result collection
    Output[...]
        Aggregate(FINAL)[tenant_name]
            RemoteExchange[GATHER]                              -- coordinator collects partial aggregates
                Aggregate(PARTIAL)[tenant_name]
                    InnerJoin[e.tenant_id = t.id]               -- the hash join runs here, on every worker
                        TableScan[iceberg:analytics.events]     -- PROBE side: NO exchange above it.
                            Layout: [tenant_id, event_type]     --   Each worker scans its OWN local splits.
                            dynamicFilters = {tenant_id = #df0} --   DF arrives from the build side at runtime.
                        LocalExchange[HASH][$hashvalue]         -- in-worker rehash for the in-memory hash table
                            RemoteExchange[REPLICATE, BROADCAST, []]   -- BUILD side: replicated to EVERY worker
                                TableScan[app_pg:public.tenants, constraint = (plan_tier = 'enterprise')]
                                    Layout: [id, tenant_name, plan_tier]
```

**What to look for, line by line:**

| Plan node | Meaning |
|---|---|
| `RemoteExchange[REPLICATE, BROADCAST, []]` above the **build** (small Postgres `tenants`) scan | **The headline broadcast marker.** The small build side is sent in full to every worker. The `[]` (empty key list) confirms it is NOT being hash-partitioned — it goes to all workers regardless of key value. |
| **NO `RemoteExchange[REPARTITION, ...]` above the probe** (large Iceberg `events`) scan | **This is the entire point of broadcast mode.** The large probe table is not shuffled — each worker reads its own local file splits directly. If you see `RemoteExchange[REPARTITION, HASH, ...]` above the probe scan, **the join is NOT broadcast; it is PARTITIONED** (and someone has mislabeled the example). |
| `dynamicFilters = {tenant_id = #df0}` on the probe TableScan | DF arrived from the (now-completed) build side and is pruning probe-side files at the manifest level before they are read off MinIO. |
| `LocalExchange[HASH]` between the broadcasted build and the join operator | **Local** to each worker (no network) — Trino redistributes the broadcasted build rows across local driver threads to build the in-memory hash table in parallel. This is NOT a network shuffle; it lives inside one JVM. |
| `RemoteExchange[GATHER]` at the top, feeding the final aggregate on the coordinator | The only `RemoteExchange` other than the build-side REPLICATE. The coordinator collects partial aggregates from workers for the final GROUP BY. This is normal and unrelated to join distribution. |

**Contrast: full PARTITIONED plan (BOTH sides have REPARTITION above their scans):**

```
Fragment 0 [SINGLE]
    Output[...]
        Aggregate(FINAL)[tenant_name]
            RemoteExchange[GATHER]
                Aggregate(PARTIAL)[tenant_name]
                    InnerJoin[e.tenant_id = t.id]
                        RemoteExchange[REPARTITION, HASH, [tenant_id]]    -- PROBE shuffled by join key
                            TableScan[iceberg:analytics.events]
                                dynamicFilters = {tenant_id = #df0}
                        LocalExchange[HASH]
                            RemoteExchange[REPARTITION, HASH, [id]]       -- BUILD also shuffled by join key
                                TableScan[app_pg:public.tenants, constraint = (plan_tier = 'enterprise')]
```

**The diagnostic rule:** look at the number of `RemoteExchange` nodes containing `REPARTITION` or `REPLICATE`:
- **Broadcast** = exactly **ONE** `RemoteExchange[REPLICATE, BROADCAST, []]` (over the build), plus a top-level `RemoteExchange[GATHER]` for result collection. The probe scan is bare.
- **Partitioned** = **TWO** `RemoteExchange[REPARTITION, HASH, [<key>]]` nodes (one per side), plus a top-level `RemoteExchange[GATHER]`. Both sides shuffle.

**Why this matters in practice.** If you mis-read a partitioned plan as broadcast (or vice versa), you'll chase the wrong tuning lever. Seeing `REPARTITION, HASH` over the Iceberg probe means the join is partitioned and you should investigate why (stats missing? build estimate exceeded `join_max_broadcast_table_size`? `join_distribution_type` forced to PARTITIONED?). Seeing only `REPLICATE, BROADCAST` over the build and a bare probe means broadcast is working — and any remaining slowness is in DF wait-timeout, probe-side file pruning, or coordinator gather, not in the join distribution choice.

### 5.6 Dynamic filtering with Postgres-partitioned probe tables

When Trino's Postgres-connector scan is the **probe side** (receiving the dynamic filter), and the Postgres table is declaratively partitioned, dynamic filtering can trigger **Postgres partition pruning server-side**. This compounds two independent optimizations:

1. **Dynamic filter push-to-probe**: Trino derives the IN-list or range from the build side (e.g., an Iceberg dimension after filtering) and pushes it to the Postgres JDBC query.
2. **Postgres partition pruning**: If the pushed predicate constrains the Postgres partition key (e.g., `WHERE created_at IN (...)` on a monthly-partitioned table, or a DF range `WHERE created_at BETWEEN ... AND ...`), Postgres's query planner prunes the irrelevant child partitions before scanning.

**Example — Iceberg dimension × PG-partitioned events:**

```sql
-- events is monthly-partitioned by created_at in Postgres
-- tags is a small Iceberg table (a few thousand rows)
SELECT e.event_type, COUNT(*) AS cnt
FROM app_pg.public.events e
JOIN iceberg.analytics.tags t ON t.event_date = CAST(e.created_at AS DATE)
WHERE t.campaign_id = 'spring-2026'
```

If Trino builds on `tags` (small after the campaign filter, say 30 distinct dates):
- DF derives a list of 30 dates (e.g., `2026-03-01` through `2026-03-30`)
- Trino pushes `WHERE created_at >= '2026-03-01' AND created_at <= '2026-03-30'` (or an IN-list of dates) to the Postgres JDBC query
- Postgres sees the constraint on `created_at`, its partition planner prunes to only the `events_2026_03` child partition
- Trino scans 1/12th of the table (or less) instead of all 400M rows

**How to verify this is working:**

```sql
EXPLAIN ANALYZE
SELECT e.event_type, COUNT(*)
FROM app_pg.public.events e
JOIN iceberg.analytics.tags t ON t.event_date = CAST(e.created_at AS DATE)
WHERE t.campaign_id = 'spring-2026'
GROUP BY e.event_type;
```

Look for on the Postgres `events` TableScan:
- `dynamicFilterSplitsProcessed` — non-zero confirms the DF arrived in time
- `constraint on [created_at]` — shows the pushed predicate includes a date range
- Small `Input:` row count — Postgres pruned older partitions

Also verify on the Postgres replica side (most conclusive):
```sql
-- On the Postgres replica, look at the actual SQL Trino sent:
SELECT query, query_start, state, wait_event
FROM pg_stat_activity
WHERE usename = 'trino_reader'
ORDER BY query_start DESC
LIMIT 5;
```

If the query shown in `pg_stat_activity` contains `WHERE created_at >= '2026-03-01'`, the DF arrived and partition pruning fired on the Postgres side.

**When DF timing matters:** Postgres scans start as soon as the plan launches (the probe side doesn't always wait for the build side to finish). If the Iceberg build scan is slow (large tag table, cold object store), the Postgres scan may start before the DF arrives — and run without pruning. Symptoms: `dynamicFilterSplitsProcessed = 0` on the Postgres scan node in `EXPLAIN ANALYZE`, large `Input:` row count. Fix: raise the PostgreSQL connector's DF wait timeout:

```sql
SET SESSION app_pg.dynamic_filtering_wait_timeout = '30s';
```

This tells the Postgres scan to wait up to 30 seconds for the DF before launching without it.

#### 5.6.1 The reverse direction — Postgres dimension (build) × Iceberg fact (probe)

The example in 5.6 covers DF flowing **into** a Postgres scan (Postgres is the probe). The complementary — and more common — federation pattern is the opposite: **Postgres dimension as build, Iceberg fact as probe**. Dynamic filters in this direction are equally first-class and arguably the bigger win, because Iceberg's columnar storage + file-level min/max statistics make probe-side pruning extremely effective.

**The flow:**

1. Trino builds the hash table on the (small, filtered) Postgres dimension side. This collects the actual join-key values (e.g., 5,000 `tenant_id` UUIDs after `WHERE plan_tier = 'enterprise'`).
2. Trino derives a DF from those build-side values (an IN-list, or for very large builds a min/max range — see Section 5.4).
3. The DF is **pushed to the Iceberg connector at the probe scan**. The Iceberg connector applies it **server-side** during file/row-group selection:
   - **File-level pruning**: Iceberg compares the DF range/IN-list to each Parquet file's min/max stats in the manifest; files outside the range are skipped without being opened.
   - **Row-group-level pruning**: Within each opened Parquet file, row groups whose min/max stats don't overlap the DF are skipped at the row-group level.
   - **Page-level / row-level filter**: Remaining rows are filtered after decompression.

> **Iceberg applies dynamic filtering at TWO levels — file-level manifest pruning AND dynamic row filtering (DRF):**
>
> 1. **File-level manifest pruning**: Files whose min/max statistics (Iceberg manifest `lower_bounds`/`upper_bounds`) cannot overlap the DF predicate are skipped entirely — they are never opened, never read off MinIO/S3, never decompressed. This is the headline file-pruning win and the metric most engineers focus on.
>
> 2. **Dynamic row filtering (DRF)**: Within each *selected* Parquet file (the ones that survived step 1), the Iceberg connector applies the DF predicate at the **row-group and page level** before passing rows up to the join operator. Row groups and Parquet pages whose min/max statistics cannot match the DF are filtered out without producing row output. DRF is **enabled by default** in the Iceberg connector and provides an additional layer of pruning within surviving files — so a 256 MB Parquet file that wasn't pruned at the file level but only has 200 KB of matching row groups will only emit those 200 KB to the join, not the full 256 MB.
>
> **What you'll see in `EXPLAIN ANALYZE VERBOSE`**: both effects contribute to `dynamicFilterSplitsProcessed` (file-level, since splits ≈ files in Iceberg) AND to reduced `Physical Input` bytes on the Iceberg `TableScan` (combined file-level + DRF effect — the bytes that actually came off object storage after both pruning layers). If `dynamicFilterSplitsProcessed` is high but `Physical Input` is still close to the table's raw size, file-level pruning fired but DRF didn't reduce within-file bytes much (DF predicate doesn't align with row-group min/max). If `Physical Input` is dramatically reduced beyond what split-skip alone would explain, DRF is doing real work too.

**Example:**

```sql
SELECT t.tenant_name, e.event_type, COUNT(*) AS n
FROM app_pg.public.tenants t                  -- build (small, filtered)
JOIN iceberg.analytics.events e               -- probe (large fact)
  ON e.tenant_id = t.id
WHERE t.plan_tier = 'enterprise'              -- selective filter on Postgres
  AND e.event_ts >= DATE '2026-05-01'         -- partition predicate on Iceberg
GROUP BY t.tenant_name, e.event_type;
```

With dynamic filtering active:
- Trino fetches ~5,000 `tenants` rows from Postgres (build complete in milliseconds).
- DF = `tenant_id IN (<5000 UUIDs>)` pushed to the Iceberg scan.
- Iceberg manifest-level pruning skips event files where the `tenant_id` min/max range doesn't overlap the IN-list — often dropping 80%+ of files for a small-dimension lookup.
- Combined with the date partition predicate, the probe may scan only a few percent of the underlying Parquet bytes.

**How to verify (on the Iceberg-side TableScan in `EXPLAIN ANALYZE`):**
- `dynamicFilterSplitsProcessed` non-zero on the Iceberg scan node = the DF arrived in time and pruned splits.
- `Input:` rows on the Iceberg scan should be far less than the table's total row count.
- Iceberg connector metrics: `filesPlanned` (after DF) vs total files in the manifest is the headline file-pruning win.

**Tuning:** the same Trino-wide DF knobs apply (`dynamic-filtering.large-max-distinct-values-per-driver`, `enable_large_dynamic_filters`, etc. — see Section 5.4). For a small Postgres dim (under ~1K distinct keys), defaults usually keep the DF as an IN-list, which is the most precise form. For larger builds, the DF may degrade to a range — still useful for Iceberg file-level min/max pruning, but less selective.

This reverse direction is the **single highest-leverage cross-catalog pattern in this stack** — it's the reason "small Postgres dimension + huge Iceberg fact" federation queries are survivable in production at all. The DF + Iceberg's min/max pruning combine to turn what would be a full table scan into a small targeted read.

---

## 6. When to federate vs. when to ingest to Iceberg

The whole point of having Iceberg is to **not** hammer your operational databases for analytical queries. But federation is a legitimate tool, not a code smell. Use the right one for the job.

### 6.1 Federation wins when...

- **Freshness requirement exceeds your ingestion latency.** If you need data from the last 30 seconds and your Iceberg ingest job runs hourly, the only way to get that freshness is to read Postgres live.
- **Small dimension table, large fact join.** A "small" dimension here means **up to ~1M rows** (customers, tenants, users, products) in Postgres joined against tens-to-hundreds of millions of Iceberg events. This is exactly what cross-catalog joins + dynamic filtering are good at: the small side becomes the DF build, an IN-list (or range) is pushed to Iceberg, and only matching files/row-groups get scanned. (Use 1M as the consistent rule of thumb throughout this doc — older heuristics sometimes say "100K" but in practice federation comfortably handles dimensions up to ~1M rows when the join column is selectively filtered or the build-side filters cut it down further.)
- **Ad-hoc, one-off queries.** Investigating a single incident, sanity-checking a count, validating that yesterday's ingest matches Postgres' current state. No point building an ingestion pipeline for a query you'll run twice.
- **Live data sanity checks.** "Is the row in Iceberg the same as in Postgres?" comparisons (`EXCEPT` queries between catalogs) are a perfect federation use case.

### 6.2 Ingest to Iceberg wins when...

- **Repeated dashboard queries.** Pay the ingestion cost once at write time, get fast columnar Iceberg reads forever. Don't ask Postgres the same question every 30 seconds.
- **Large historical aggregations.** Iceberg is columnar with min/max stats, partition pruning, predicate pushdown into Parquet. Postgres row-store can't compete on a `SUM(amount) GROUP BY day` over 100M rows.
- **You need to isolate OLTP from analytical load.** Heavy reporting that could degrade the application's primary DB performance should not run against Postgres at all, even via a replica, if it can be served from Iceberg.
- **You need Iceberg-specific features.** Time travel (query as of yesterday's snapshot), schema evolution history, branching/tagging, governance via metadata — these only work for Iceberg-native tables.

### 6.2A Concrete signals for when to STOP federating a hot Postgres view/table and materialize into Iceberg

The general "federation vs ingest" tradeoff is in 6.1 / 6.2, but in practice the decision to migrate a specific federated query is triggered by **observable production signals**, not by abstract preference. If a federated view or table starts hitting any of the following thresholds, schedule an Iceberg materialization (Spark or dbt job) and switch the federated reference to the Iceberg table:

| Signal | Threshold | Why this means "stop federating" |
|---|---|---|
| **Postgres read-replica CPU** | Sustained **>70%** during business hours, attributable to Trino's JDBC connection (check `pg_stat_activity` for the Trino-connector user) | The federation queries are now a load problem for OLTP. Migrating to Iceberg removes the load entirely (Iceberg reads MinIO, not Postgres). |
| **Query latency vs. dashboard SLO** | Federated query latency consistently **>2s** for queries the dashboard SLO budgets at **<500ms** | The user experience is broken. Iceberg with the right partition + sort order routinely serves the same query in <500ms because of columnar scans + min/max pruning. |
| **Query volume share** | Federation queries against this Postgres table now represent **>20%** of all queries hitting that table (Trino + everything else) | Federation has stopped being a "live tail" use case and become the primary access pattern. At 20%+ share, the OLTP DB is effectively doing OLAP work — wrong tool for the job. |
| **Schema churn / migration risk** | The Postgres table's schema changes **more than once per quarter** (column additions, type changes, renames) AND downstream Iceberg jobs depend on the federated view | Every Postgres schema change risks breaking dependent Iceberg jobs without warning. Materializing into Iceberg gives you an **explicit, version-controlled schema boundary** — the ingest job is the only place schema mapping lives, and a Postgres schema change forces an explicit ingest-job update (safer than silent breakage). |
| **Freshness tolerance is loosening** | The business can tolerate **T-15min** instead of true real-time | You no longer need federation. A 15-minute Spark/dbt micro-batch into Iceberg is strictly better: faster queries, no Postgres load, snapshot-isolated reads, time travel, partition pruning. Federation is only worth its costs when sub-minute freshness is mandatory. |

**Process when you cross a threshold:**

1. Capture 1 week of event listener data (Section 6.5) for the federated queries against this table — `executionTime`, `physicalInputBytes`, query count, distinct callers.
2. Decide ingestion cadence based on freshness tolerance: hourly batch is cheapest, 15-minute micro-batch fits most SaaS dashboards, CDC streaming if sub-minute is mandatory (see 6.4).
3. Build the Iceberg table with a partition spec that matches the dominant query predicate (usually `(day(event_ts), bucket(tenant_id, N))` for multi-tenant — see `resources/05-multi-tenant-analytics.md`).
4. Run the federated and Iceberg queries side-by-side for one ingestion cycle to confirm row counts match (`EXCEPT` query is a quick check).
5. Cut over: replace the federated catalog reference in views/dashboards with the Iceberg table reference. Keep the federated path available for 1-2 weeks as a rollback option, then drop it.

**Common mistake to avoid:** Do NOT migrate purely on "feels slow." Without the event listener evidence, you may discover the slow query was actually fast on Postgres but slow because of cross-catalog network egress or a missing dynamic filter — both fixable without an ingestion pipeline. Always measure first; the migration is real engineering work and should be justified by data.

### 6.3 Decision matrix

| Situation | Federate (PG connector) | Ingest to Iceberg |
|---|---|---|
| One-off ad-hoc investigation | YES | overkill |
| Hourly executive dashboard | no | YES |
| 30-second freshness on user counts | YES (live tail) | no — too stale |
| Joining small/medium dim table (up to ~1M rows) to 100M+ events | YES (cross-catalog) | acceptable too — depends on freshness |
| Aggregating 5 years of transactions | no — Postgres will die | YES |
| "Does Iceberg match Postgres for tenant X?" reconciliation | YES (EXCEPT query) | no |
| User-facing API serving thousands of QPS | neither — that's an OLAP serving DB problem | (offline build) |

### 6.4 Ingestion latency tiers — be honest about how fresh "ingested" actually is

The "federate vs ingest" decision often hinges on freshness. "Ingestion is too slow" is not one thing — it depends entirely on **which ingestion pattern** you choose. Pick the cheapest tier that meets your freshness SLO:

| Ingestion pattern | Typical end-to-end latency | When to use it | Operational cost |
|---|---|---|---|
| **CDC streaming** (Debezium → Kafka → Iceberg via Flink / Kafka Connect Iceberg sink / Spark Structured Streaming) | **seconds to a few minutes** | You need near-real-time analytics on operational tables; you can run streaming infrastructure. | High — Kafka, Debezium connectors, streaming sink job, dedupe logic, schema evolution handling. |
| **Micro-batch Spark** (Spark Structured Streaming with 1–10 minute trigger intervals, or Airflow-orchestrated Spark batches every few minutes) | **minutes** (typically 1–10) | Sub-hour freshness without standing up Kafka; cheaper than streaming. | Medium — a long-running Spark app or scheduled mini-jobs. |
| **Nightly / hourly batch** (Spark/dbt batch job on a cron) | **hours** (1–24) | Daily reporting, executive dashboards, historical reprocessing. | Low — a single scheduled job. |

The decision flow:

- **Freshness SLO < 1 minute** → CDC streaming, or stay federated for the truly live tail (and use the hybrid pattern in section 7 for everything older).
- **Freshness SLO of a few minutes** → micro-batch ingest is usually the sweet spot; federation is a fallback only if you also need true second-level freshness.
- **Freshness SLO of hours** → batch ingest, no federation needed.
- **No predictable cadence** (one-off investigation) → just federate.

The takeaway: do not lump "batch ingestion" together as if it's always hours-stale. CDC streaming into Iceberg routinely achieves sub-minute end-to-end latency in production. The "federate vs ingest" tradeoff is really "is sub-second freshness mandatory?" — if yes, federate (or hybrid); if minutes is fine, ingest with the cheapest tier that meets the SLO.

### 6.5 Using event listener data to make the federation-vs-Iceberg decision

The decision to migrate a federated query to Iceberg ingest often requires concrete performance data — "federated query is slow" is not enough to justify ingestion pipeline investment. The **Trino event listener** (Section 8.3) and **OPA decision logs** provide exactly this evidence.

**From the event listener** (`query_completed` events), extract:
- `analysisTime` — how long the query spent in OPA policy evaluation (before planning even started)
- `planningTime` — how long the optimizer spent on the plan (includes metadata fetch from Postgres)
- `executionTime` — actual wall clock from first byte of execution to last result row
- `physicalInputBytes` / `physicalInputRows` (on the Postgres scan operator) — how many bytes Trino fetched from Postgres over JDBC

A federation query that shows `physicalInputBytes` near the full Postgres table size (despite having a WHERE clause) is a prime migration candidate — it means predicate pushdown failed and the query is doing a full table scan over JDBC.

```sql
-- Query the event listener output stored in Iceberg (if you've wired it there):
SELECT
  query_id,
  query_text,
  analysis_time_ms,
  planning_time_ms,
  execution_time_ms,
  physical_input_bytes,
  physical_input_rows
FROM iceberg.analytics.query_audit_log
WHERE created_at > NOW() - INTERVAL '24' HOUR
  AND query_text LIKE '%app_pg%'    -- federation queries
ORDER BY execution_time_ms DESC
LIMIT 20;
```

**From OPA decision logs** (`metrics.timer_rego_query_eval_ns`), identify which queries are spending significant time in OPA policy evaluation (pre-planning). If a dashboard query spends >100ms in OPA evaluation on every run, that is overhead paid on every execution — and it disappears if the data is served from Iceberg (OPA still authorizes the Iceberg query, but authorization is usually faster because there are fewer per-column masking calls for a pre-aggregated, narrower table).

**The cost-justification formula**: gather 1 week of event listener data for the federated queries you're considering migrating. Sum `physicalInputBytes` × your data transfer cost to estimate the Postgres replica network cost. Compare `executionTime` to analyst SLO. If execution time routinely exceeds the SLO (e.g., queries take 45s but dashboard users expect <10s) AND physical input bytes show full table scans, the migration case is clear. If execution time is already acceptable, keep federating.

---

## 7. The hybrid pattern: Iceberg historical + federated Postgres for live tail

This is what most production SaaS teams actually run. The idea:

- **Iceberg** holds everything older than the last hour (or last day) — fully optimized columnar storage, partition pruning, fast aggregations.
- **Postgres** (read replica, via the federation connector) provides the **live tail** — the very recent data that hasn't yet been picked up by your hourly ingestion job.
- A **Trino VIEW** stitches the two together with `UNION ALL` so user-facing dashboards see a single seamless table.

### 7.1 Example: a unified `orders_live` view

```sql
CREATE OR REPLACE VIEW analytics.orders_live AS
-- Historical: everything ingested into Iceberg (older than 1 hour)
SELECT
    id,
    tenant_id,
    customer_id,
    amount,
    status,
    created_at
FROM iceberg.analytics.orders
WHERE created_at < (current_timestamp - INTERVAL '1' HOUR)

UNION ALL

-- Live tail: the last hour, read directly from Postgres replica
SELECT
    id,
    tenant_id,
    customer_id,
    amount,
    status,
    created_at
FROM app_pg.public.orders
WHERE created_at >= (current_timestamp - INTERVAL '1' HOUR);
```

Users and BI tools query `analytics.orders_live` and get a consistent freshness guarantee (no more than ingestion-pipeline lag on history, second-level freshness on the tail). The trick:

- The Iceberg side uses partition pruning — only the latest partition is scanned.
- The Postgres side uses predicate pushdown on `created_at` (timestamp range) — only the last hour's rows are returned over JDBC.
- The cutoff (`1 hour`) **must match** the maximum lag of your ingestion pipeline. If ingest can fall an hour behind during heavy load, set the cutoff to 2 hours and accept the slight overlap (or use a watermark column).

### 7.2 Avoiding the duplicate-row trap

If your ingest runs every 30 minutes and the view cutoff is 1 hour, rows from the most recent 30 minutes can appear in **both** sides during the overlap window. Two fixes:

1. **Use the ingest watermark, not wall-clock time.** Have your ingest job write its high-water-mark timestamp to a metadata table; use that watermark as the cutoff in the view. Then there is no overlap by construction.
2. **`UNION` (distinct) instead of `UNION ALL`** — correct but expensive; deduplication costs CPU and shuffle. Only viable for small result sets.

Option 1 is the right answer for production.

### 7.3 When to invalidate the view

If your ingestion latency improves to "minutes" (you switched to Spark Structured Streaming, see resource 14), you may not need the federated tail anymore — the Iceberg side alone is fresh enough. The hybrid view is a tool for the case where ingestion can't keep up with the freshness SLO. It is not a permanent architecture.

### 7.4 Third option — CDC (Change Data Capture) with Debezium

> **Beyond "federate live" and "nightly full-refresh ingest plus a hybrid UNION ALL view," there is a third option that often beats both for production SaaS analytics: CDC.**

Instead of nightly full-refresh OR a hybrid live-tail view, you can use **Debezium** to stream every row change from Postgres (INSERT/UPDATE/DELETE) to **Kafka** in real time, then write those changes to **Iceberg** with **Spark Structured Streaming** or **Flink**. The result: Iceberg has near-real-time data (minutes of lag, not hours) **without ever querying Postgres analytically**. This eliminates the "stale data" tradeoff of nightly ingestion AND the "must keep federation working" cost of the hybrid view.

The data path:

```
Postgres (logical decoding / WAL replication slot)
   → Debezium connector (running in Kafka Connect)
   → Kafka topic (one topic per Postgres table, by convention)
   → Spark Structured Streaming job (or Flink, or Kafka Connect Iceberg sink)
   → Iceberg table (UPSERT semantics via MERGE INTO, or append-with-CDC-marker)
```

#### When CDC is the right answer

- **You need both analytical scale AND near-real-time freshness.** Sub-5-minute end-to-end lag, with full Iceberg columnar performance (partition pruning, predicate pushdown into Parquet, broadcast joins, etc.) for the analytical reads.
- **You have UPDATE or DELETE traffic** (not just inserts) — full-refresh nightly would re-read all rows every night to catch updates; CDC ships only the delta (just the changed rows since the last snapshot).
- **The table is too large for nightly full-refresh to finish in the window.** A 100M-row Postgres table with hourly updates takes hours to full-refresh; CDC streams updates continuously, so the steady-state work is proportional to change rate, not table size.
- **You want to decouple analytical reads from Postgres entirely.** Federation creates an ongoing operational dependency on Postgres availability for analytics. CDC moves the dependency to Kafka + the streaming job; once an update lands in Iceberg, queries don't need Postgres at all.

#### When CDC is overkill

- **The table is append-only** and **hourly batch ingestion is fresh enough**. A nightly or hourly `INSERT INTO iceberg.x SELECT * FROM app_pg.x WHERE id > <last_id>` is much simpler.
- **You don't already have Kafka in your stack.** Debezium requires running a Kafka Connect cluster (or Kafka Connect on K8s, e.g., Strimzi). Standing this up just for one table is a significant operational lift — go batch instead.
- **The table is < ~10M rows.** Nightly full-refresh finishes in minutes and the architecture is simpler. CDC's value emerges when the table is big enough that re-reading it is expensive.
- **You can tolerate an hour of lag.** Streaming has real operational cost (Kafka tuning, dedupe logic, schema evolution handling, exactly-once semantics, late-event handling); batch wins on simplicity if the freshness SLO allows.

#### CDC vs. the hybrid view — which to choose

| Aspect | Hybrid UNION ALL view (Section 7.1) | CDC streaming (this section) |
|---|---|---|
| Live data freshness | Second-level (real-time read from Postgres) | Sub-minute (depends on Kafka + Spark micro-batch trigger) |
| Postgres analytical load | Continuous read from the replica for the live tail | None — Postgres only does WAL replication |
| Architecture complexity | Low — one view, one connector | High — Debezium + Kafka + Spark streaming job + dedupe |
| UPDATE/DELETE handling | Naturally consistent (you read the row's current state from Postgres) | Requires MERGE INTO logic with primary key + ordering, schema evolution handling |
| Cost when query traffic spikes | Postgres replica feels the spike (federation queries hit it) | Iceberg side absorbs the spike, no Postgres impact |
| Right for | Small tables, occasional federation, "live tail under 1 hour" | Big tables, continuous analytical workload, sub-minute freshness SLO |

The decision flow:

- **Second-level freshness, small table, simple architecture** → hybrid view.
- **Minute-level freshness, big table, you already have Kafka** → CDC.
- **Hour-level freshness or larger** → just batch-ingest, no federation or CDC needed.

See resource 14 for the full Spark Structured Streaming + Iceberg CDC sink recipe (MERGE INTO with primary key, watermark handling, schema evolution). The federation-vs-CDC choice is upstream of that resource — this section just flags that CDC exists as a real third option.

### 7.5 Federated VIEWs that JOIN across Postgres and Iceberg — yes, you can; no, they do not cache

A common follow-up question after seeing the UNION ALL pattern in 7.1: "Can I just create a Trino view that JOINs Postgres and Iceberg, and have dashboards query the view instead of writing the join every time?" **Yes — Trino fully supports CREATE VIEW over federated sources**, and it is the right tool for **eliminating SQL boilerplate**. It is **not** a performance tool — every query against the view re-runs the federation. Read that distinction carefully before deploying one.

#### The view definition — JOIN across catalogs is allowed

```sql
-- A view that JOINs an Iceberg fact table to a Postgres dimension table.
-- Lives in the Trino-native `analytics` catalog (Hive Metastore-backed), NOT in Postgres or Iceberg.
CREATE OR REPLACE VIEW analytics.events_enriched AS
SELECT
    e.event_id,
    e.event_type,
    e.occurred_at,
    e.tenant_id,
    t.name           AS tenant_name,
    t.plan_tier      AS tenant_plan,
    t.region         AS tenant_region
FROM iceberg.analytics.events e
JOIN app_pg.public.tenants t
  ON t.id = e.tenant_id;
```

Dashboards and BI tools now query `SELECT ... FROM analytics.events_enriched WHERE occurred_at >= ...` and never see the cross-catalog plumbing. The view is a **named query** stored as SQL text + a resolved column schema in HMS (see Section 2.7 for view storage internals). Trino expands it inline at query time.

#### What happens at query time — re-federation, every single query

**This is the critical performance fact.** A Trino view is **not** a materialized object — it is **pure SQL substitution**. Every `SELECT ... FROM analytics.events_enriched ...` is rewritten by the optimizer to the underlying JOIN, planned from scratch, and executed federated. There is **no caching layer** between the view and its underlying sources. Concrete consequences:

- **Each query opens a fresh JDBC cursor to Postgres** — same connection pressure as if the dashboard had written the JOIN inline. Bounded by PgBouncer / role-level `CONNECTION LIMIT` / resource groups (Section 8.2), but the view itself does nothing to reduce Postgres load.
- **Each query re-scans the Iceberg side** — subject to partition pruning and DF as usual, but the view does not store any pre-computed result.
- **Each query re-does the hash join on Trino workers** — cross-catalog joins always execute on Trino workers (Section 4.1); the view does not change that.
- **`pg_stat_activity` on the replica will show one Postgres `SELECT` per query against the view** — same as if you had written the JOIN inline. Federated views are NOT a way to amortize Postgres load across queries.

If five dashboards each refresh every minute and all reference the view, Postgres gets hit five times per minute, **the view changes nothing about that**. The view eliminates SQL repetition for developers; it does not reduce work for the underlying systems.

#### When federated views ARE the right tool

- **Eliminating boilerplate** — the JOIN logic lives in one place. If you change the join key, you `CREATE OR REPLACE VIEW` once and every downstream query sees the new shape (and **grants are preserved** by `CREATE OR REPLACE VIEW` — see Section 2.7).
- **Schema contract for downstream consumers** — BI tools and dashboards select from a stable name. The view definition is the contract; the underlying tables can evolve as long as the view's output columns stay stable.
- **Centralizing security** — combine with `SECURITY DEFINER` (Section 2.7) so the view runs with the owner's identity, and downstream users only need `SELECT` on the view, not on the underlying Postgres + Iceberg tables.
- **Low query rate** — when the dashboard refreshes once an hour, "re-federate every query" is genuinely fine; the federation cost is bounded and you get the developer-ergonomics win for free.

#### When federated views are the WRONG tool — use INSERT INTO Iceberg instead

If you find any of these true, **stop using a federated view and materialize the join into an Iceberg table** (the canonical recipe is in Section 9.5 — `INSERT INTO iceberg.analytics.events_enriched SELECT ... FROM iceberg JOIN app_pg ...`):

- **The view is queried more than a few times per minute** — Postgres replica load scales linearly with view query count.
- **The Postgres dim is large enough that the federation join itself is the dashboard's latency bottleneck** — re-running the same federation every query is wasted CPU + JDBC traffic.
- **The dashboard's freshness SLO tolerates minutes-to-hours of lag** — materialize on a Spark/dbt micro-batch schedule (5–15 min) into Iceberg; both sides of the join now live in Iceberg, scans are columnar, and the join can be a fast broadcast (Section 4.1).
- **Multiple downstream dashboards run the same join** — materializing once and letting every dashboard read the materialized Iceberg table is dramatically cheaper than re-federating per dashboard per refresh.

**The mental shortcut:** views are for **developer ergonomics** (DRY, schema contract, centralized security). Materialized Iceberg tables are for **runtime efficiency** (one federation, many reads). Federated views do **NOT** sit between those two roles — they only do the ergonomics half.

#### EXPLAIN against a federated view — what to expect

Run `EXPLAIN (TYPE DISTRIBUTED) SELECT ... FROM analytics.events_enriched WHERE ...;` and the plan looks **identical to if you had inlined the JOIN by hand**. Two TableScans (one Iceberg, one Postgres), an `InnerJoin` / `HashJoin` operator above them, predicate pushdown applied per source, dynamic filtering applied if conditions allow. The view name disappears from the plan — Trino's optimizer treats it as if you had textually pasted the view definition into the query. This is the visible proof that the view is pure SQL substitution and not a separate execution layer.

#### Comparison — federated view vs UNION ALL hybrid view vs materialized Iceberg table

| Property | Federated JOIN view (this section, 7.5) | Hybrid UNION ALL view (Section 7.1) | Materialized Iceberg table (Section 9.5) |
|---|---|---|---|
| What it does | JOINs Iceberg + Postgres in one named query | Stitches "historical Iceberg + live Postgres tail" | Stores the join result physically as Iceberg files |
| Caching of results | None — re-federates every query | None — re-federates the tail every query | Yes — query reads pre-computed Iceberg files |
| Postgres load per dashboard refresh | One full federated read | One read of the live-tail window | None (until the next batch refresh) |
| Freshness | As fresh as Postgres replica | As fresh as Postgres replica (for the tail) | As fresh as the last batch refresh (minutes to hours) |
| Maintenance overhead | None — view is just SQL | None — view is just SQL | A periodic INSERT/MERGE job needs to run |
| Right for | Low-traffic dashboards, ad-hoc analyst queries, schema-contract concerns | "Live tail with seconds-of-freshness" | High-traffic dashboards, large dim tables, SLO tolerates minutes of lag |
| Wrong for | High-traffic dashboards (re-federation cost) | Large historical scans against the live tail | Anything needing real-time freshness |

#### Footgun: a view does NOT make a slow federation query fast

The single most common misconception about federated views: "I'll wrap the slow JOIN in a VIEW and queries will get faster." They will not. The view runs the same JOIN; the only thing that changes is who typed the JOIN (you, when you ran `CREATE VIEW`, instead of every dashboard developer). If your federation is slow, the answer is one of: (a) better predicate pushdown / dynamic filtering (Sections 3 and 5), (b) better Postgres indexing on the join keys, (c) raise statistics with `ANALYZE` on the Postgres primary (Section 4.1A) so the CBO picks better plans, or (d) materialize the join into an Iceberg table (Section 9.5), or (e) use Trino's built-in `CREATE MATERIALIZED VIEW` so Trino manages the storage for you (Section 7.6). A regular view, by itself, fixes none of these.

### 7.6 `CREATE MATERIALIZED VIEW` — Trino's built-in cached-view feature (Iceberg-only)

Sections 7.5 and 9.5 covered the two manual ends of the spectrum: a `CREATE VIEW` (no caching, re-federates every query) and an `INSERT INTO iceberg.<schema>.<table> SELECT ...` job (full caching, you manage the storage table). **Trino has a third option that sits between them: `CREATE MATERIALIZED VIEW`.** Syntactically it looks like a view; physically it is a real Iceberg table that Trino creates and manages on your behalf. Reads of the materialized view hit the cached Iceberg data, not the underlying federation — until you (or a scheduled job) run `REFRESH MATERIALIZED VIEW`, at which point Trino re-executes the underlying query and updates the storage table.

> **CRITICAL: in OSS Trino 467, `CREATE MATERIALIZED VIEW` is supported on the Iceberg connector only.** The catalog you target with `CREATE MATERIALIZED VIEW <catalog>.<schema>.<view_name>` must be an Iceberg catalog. You cannot create a materialized view in the PostgreSQL connector, the MySQL connector, the Hive connector, or any of the other JDBC catalogs. The underlying SELECT query, however, can JOIN across any number of catalogs (Iceberg + Postgres + MySQL all in one materialized view definition) — only the **storage** has to live in Iceberg.

#### Syntax

```sql
-- Federated materialized view: Iceberg fact × Postgres dimension, stored in Iceberg.
-- `iceberg` is the target catalog; the underlying SELECT pulls from app_pg too.
CREATE MATERIALIZED VIEW iceberg.analytics.events_enriched_mv AS
SELECT
    e.event_id,
    e.event_type,
    e.occurred_at,
    e.tenant_id,
    t.name           AS tenant_name,
    t.plan_tier      AS tenant_plan,
    t.region         AS tenant_region
FROM iceberg.analytics.events e
JOIN app_pg.public.tenants t
  ON t.id = e.tenant_id;
```

The first time you run this statement, Trino:
1. Records the materialized view definition (the SELECT text + resolved column schema) in the Iceberg metastore (Hive Metastore in this stack).
2. Creates a hidden Iceberg **storage table** under the same schema — the name is auto-generated and stored as a property on the view. From the user's perspective there is just one object (`iceberg.analytics.events_enriched_mv`); the storage table is an implementation detail.
3. Does **NOT** populate the storage table. Until you run `REFRESH MATERIALIZED VIEW`, the cached data is empty and queries against the view return zero rows (or fall back to the source query in some Trino versions — but **do not rely on fallback**; treat "freshly created MV" as "empty until refreshed").

#### Refreshing the cached data — `REFRESH MATERIALIZED VIEW`

```sql
REFRESH MATERIALIZED VIEW iceberg.analytics.events_enriched_mv;
```

This re-executes the materialized view's SELECT (which can federate across catalogs) and writes the result into the storage Iceberg table. Two refresh modes are possible:

- **Full refresh** — Trino deletes the existing data in the storage table and writes the full result of the SELECT. Always available; used when the materialized view's query shape doesn't allow incremental computation, or when the underlying source tables have non-Iceberg snapshot semantics (e.g., a federated Postgres source — Postgres doesn't expose a snapshot-id mechanism Trino can diff against).
- **Incremental refresh** — when **all source tables are Iceberg** and the query shape allows it, Trino reads only the deltas (new Iceberg snapshots since the last refresh) and appends them. Faster for large fact tables, but **not available when the SELECT joins a federated Postgres or MySQL source** — those connectors have no snapshot-id concept Trino can use for delta computation. Federated materialized views always do **full refresh**.

After a successful refresh, Trino stores the snapshot-ids of all participating Iceberg tables in the materialized view metadata. This is how the **WHEN STALE** mechanism works: a future query can be told "if the underlying Iceberg snapshots haven't advanced past the recorded values, this materialized view is fresh; otherwise it's stale."

#### Querying the materialized view — reads come from the cached Iceberg storage

```sql
-- This SELECT reads from the cached Iceberg storage table.
-- It does NOT re-execute the federated JOIN. Postgres is NOT hit.
SELECT * FROM iceberg.analytics.events_enriched_mv
WHERE occurred_at >= DATE '2026-05-01';
```

`EXPLAIN (TYPE DISTRIBUTED)` against the materialized view shows a single `TableScan` of the underlying Iceberg storage table — there is no `JOIN`, no Postgres `TableScan`, no federation. The materialized view behaves at read time like any other Iceberg table: predicate pushdown, partition pruning, and dynamic filtering all apply normally. **This is the core operational win:** dashboards that query the materialized view never touch Postgres, no matter how many times per minute they refresh.

#### When to use `CREATE MATERIALIZED VIEW` vs manual `INSERT INTO iceberg.<schema>.<table>` (Section 9.5)

Both patterns produce the same end-state — a cached Iceberg table holding the result of a federation query — but they differ in who owns the storage and refresh logic:

| Property | `CREATE MATERIALIZED VIEW` (this section, 7.6) | Manual `INSERT INTO iceberg.<schema>.<target>` (Section 9.5) |
|---|---|---|
| Storage table | Auto-created and managed by Trino | You `CREATE TABLE` the target yourself; you own its schema |
| Refresh trigger | `REFRESH MATERIALIZED VIEW` (manual SQL command, or wrap it in a scheduler) | Whatever scheduler runs your INSERT — dbt, Airflow, cron, etc. |
| Refresh logic | Full (always for federated) or incremental (Iceberg-only sources) — Trino picks | Whatever SELECT you write — full replace (CTAS or DROP+CREATE), watermarked-append (plain INSERT — append-only sources only), or DELETE+INSERT / MERGE INTO for idempotent partition replacement. **Note: Trino does NOT have an `INSERT OVERWRITE` statement; plain `INSERT INTO` always appends.** |
| Schema evolution | Re-issue `CREATE OR REPLACE MATERIALIZED VIEW` to change the SELECT — Trino re-derives the storage table schema | You `ALTER TABLE` the target to evolve schema, or rebuild it |
| dbt integration | Less natural — dbt's incremental model abstraction expects to own the target table | Native — this is exactly what a dbt incremental model compiles to |
| Best for | "I want a cached version of this federation query with the least operational ceremony" | "I want full control over refresh schedule, MERGE/incremental logic, dbt-managed transformations, multi-step pipelines" |

**Decision shortcut:** if you would otherwise be writing a one-line "every 15 minutes, fully replace the result of this SELECT" cron (the equivalent of `INSERT OVERWRITE` in other engines — note Trino itself has no `INSERT OVERWRITE` statement), `CREATE MATERIALIZED VIEW` + a scheduled `REFRESH MATERIALIZED VIEW` is the lower-ceremony choice. If you need MERGE / DELETE+INSERT / watermarked incremental / dbt-managed transformations / multi-step lineage, write the materialization yourself with `INSERT INTO` (and `DELETE` or `MERGE` for the idempotent variants) plus an external orchestrator.

#### When to use `CREATE MATERIALIZED VIEW` vs regular `CREATE VIEW` (Section 7.5)

| Property | `CREATE VIEW` (Section 7.5) | `CREATE MATERIALIZED VIEW` (this section) |
|---|---|---|
| Caching of results | None — pure SQL substitution, re-federates every query | Yes — reads hit the cached Iceberg storage table |
| Freshness | Always as fresh as the underlying sources | As fresh as the last `REFRESH MATERIALIZED VIEW` |
| Postgres load per dashboard refresh | One full federated read per query | None (until next REFRESH) |
| Operational overhead | None — view is just SQL text | Must schedule and monitor `REFRESH MATERIALIZED VIEW` |
| Works on non-Iceberg catalogs as target | Yes — view storage is in HMS regardless of underlying connectors | No — target catalog must be Iceberg |
| Right for | Low-traffic queries, schema contracts, eliminating boilerplate | High-traffic dashboards reading a federated JOIN, freshness SLO tolerates minutes |

#### Scheduling the refresh — there is no built-in scheduler in OSS Trino

`REFRESH MATERIALIZED VIEW` is a SQL command. OSS Trino has **no built-in scheduler** that fires it for you. You must run it from an external system on the cadence your freshness SLO allows. Common patterns on this stack:

- **dbt** — wrap the materialized view in a dbt model with `materialized='view'` (for the definition) and a separate operation or post-hook that issues `REFRESH MATERIALIZED VIEW ...`. Less idiomatic than dbt's own incremental materialization but works.
- **Airflow / cron** — a single-line `PythonOperator` or `BashOperator` that connects via the Trino JDBC/HTTP client and runs `REFRESH MATERIALIZED VIEW ...`.
- **A periodic Kubernetes CronJob** — same idea, container runs `trino --execute "REFRESH MATERIALIZED VIEW iceberg.analytics.events_enriched_mv"`.

Whichever you pick, monitor the refresh duration — a full refresh of a federated materialized view is exactly as expensive as the underlying federation query. If the refresh starts taking longer than the interval between refreshes, you have the same scaling problem as a manual INSERT job and the answers are the same (partition the target, switch to incremental computation in the SELECT, move heavy transformations to Spark/dbt).

#### Footgun checklist for federated materialized views

1. **The cached data is only as fresh as the last `REFRESH`.** Engineers sometimes assume "materialized view" implies "automatically kept fresh" — it does not in Trino. If nobody runs `REFRESH MATERIALIZED VIEW`, the cache becomes arbitrarily stale.
2. **Full refresh re-runs the entire federation.** A federated materialized view's refresh is **not free**. It is exactly the same Postgres load as one federated query — just amortized over many subsequent dashboard reads. The savings come from the dashboards reading the cache, not from the refresh being cheap.
3. **The storage table is real Iceberg data that consumes object-store space and accumulates snapshots.** Like any Iceberg table, it needs `optimize` / `expire_snapshots` / `remove_orphan_files` maintenance on a schedule (see resource 17). A daily-refreshed materialized view accumulates one Iceberg snapshot per refresh — left untended for months, snapshot expiration cost becomes nontrivial.
4. **`CREATE OR REPLACE MATERIALIZED VIEW` may drop and recreate the storage table.** Treat schema changes as a structural operation, not a routine edit. Make sure no other process holds a long read against the materialized view during the replace.
5. **OPA / authorization rules apply to both the view AND the storage table.** Grant SELECT on the view to your dashboard users; service principals that run `REFRESH MATERIALIZED VIEW` need INSERT/DELETE on the underlying storage table plus SELECT on every source the underlying query touches.

---

## 8. Operational guardrails (do not skip)

Federation works in production only if you treat the upstream Postgres as a shared resource with limits, not as an unlimited datasource.

### 8.1 Always point at a read replica

Already said this in 2.3, repeating because it matters: **never the OLTP primary**. Stand up a logical or streaming replica dedicated to Trino traffic. The replica can lag a few seconds without breaking anything — that lag is much smaller than your ingestion-pipeline lag, so it doesn't change the freshness story.

#### 8.1A Routing a small fraction of time-sensitive queries to the primary — use a second catalog

The replica is the right default for **every** federation query. The one exception: a small fraction of queries are time-sensitive enough that even the replica's ~1–5 second replay lag matters (e.g., "did this user's signup commit yet?", an internal admin tool that must read its own writes, an idempotency-key lookup before a write). For these, you need to read the **primary**.

> **Note: Trino has no per-query session property to route to a different JDBC URL. Separate catalogs (one per physical connection target) are the only first-class mechanism in OSS Trino 467. This is why routing time-sensitive queries to the primary requires two catalog entries — one for the replica and one for the primary.**

Concretely, this means **two separate catalog `.properties` files**, each with its own `connection-url`:

```properties
# etc/catalog/app_pg.properties — the default: replica, used by 99% of queries
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-replica.app.svc.cluster.local:5432/appdb?...
connection-user=trino_reader
connection-password=...
```

```properties
# etc/catalog/app_pg_primary.properties — the exception: primary, for the rare time-sensitive query
connector.name=postgresql
connection-url=jdbc:postgresql://app-postgres-primary.app.svc.cluster.local:5432/appdb?...
connection-user=trino_reader_primary
connection-password=...
```

The application then chooses the catalog **by name** in the SQL it submits:

```sql
-- Default: ~all federation queries
SELECT * FROM app_pg.public.users WHERE id = 123;

-- Rare time-sensitive query: read from primary
SELECT * FROM app_pg_primary.public.users WHERE id = 123;
```

Implications and guardrails:

- **The catalog name is part of the SQL.** The application code (or the dbt model, or the BI tool's query template) must explicitly write `app_pg_primary.` instead of `app_pg.` when it needs primary reads. There is no Trino-side switch like "set session route=primary" — the routing is encoded in the table reference.
- **Treat the primary catalog as scarce.** Lower the resource group `hardConcurrencyLimit` for any user/role allowed to query `app_pg_primary` (e.g., 2–3 concurrent queries) and set `statement_timeout` aggressively on the Postgres role (`ALTER ROLE trino_reader_primary SET statement_timeout = '30s'`). The whole point of the primary catalog is that very few queries use it; cap that headroom so a runaway query can't move OLTP traffic.
- **`CONNECTION LIMIT` belongs on the primary too — even tighter.** `ALTER ROLE trino_reader_primary CONNECTION LIMIT 5` (vs. e.g. 50 for the replica). The primary catalog should never hold more than a handful of connections at once.
- **Per-tenant isolation via OPA still works the same.** OPA's allow/deny decision treats `app_pg_primary` as a distinct catalog name — you can deny most principals access to it entirely and grant only the specific service accounts that need primary reads. This is the cleanest gate.
- **Cross-catalog joins between `app_pg` and `app_pg_primary` are possible but pointless.** Both physically point at the same Postgres cluster (one at the replica, one at the primary); joining `app_pg.public.users` to `app_pg_primary.public.orders` runs as a cross-catalog join (no pushdown) when a native Postgres join would do the same work in milliseconds. If the query needs both fresh and historical Postgres data in one statement, write it against `app_pg_primary` only.

For the typical SaaS shop, the right mix is `app_pg` (replica) for 95%+ of federation traffic and `app_pg_primary` for a small allowlist of operations where lag is unacceptable. Avoid the temptation to make `app_pg_primary` the default — once teams discover it exists, the volume drifts and the primary's analytical load creeps back up.

### 8.2 Bound Postgres connections from OUTSIDE Trino (there is no Trino-side pool)

> **First, re-read Section 0.** **OSS Trino 467's PostgreSQL connector has no native JDBC connection pool.** Properties named `connection-pool.enabled`, `connection-pool.max-size`, `connection-pool.max-connection-lifetime` belong to **Starburst Enterprise**, not OSS Trino — adding them to your catalog file does nothing. The feature is tracked in [trinodb/trino#15888](https://github.com/trinodb/trino/issues/15888) (open since Jan 2023).
>
> Because there is no Trino-side pool, you must bound connection count using the four mechanisms below (combine them — they layer).

**At-a-glance: the four-layer defense for OSS Trino 467 → Postgres connection control.** Each layer caps a different thing at a different point in the request path. Use them together; none is a full substitute for the others.

| Layer | What it caps | Where configured | Key config |
|---|---|---|---|
| PgBouncer | Postgres backend connections (multiplexed across many client conns) | `pgbouncer.ini` | `default_pool_size = 50` |
| Postgres role limit | Total connections from the `trino_reader` role (hard ceiling in Postgres) | `psql` (DDL on Postgres) | `ALTER ROLE trino_reader CONNECTION LIMIT 50` |
| Trino resource groups | Concurrent Trino queries against the federation workload | `etc/resource-groups.json` | `"hardConcurrencyLimit": 10` |
| `statement_timeout` | Per-statement query duration on Postgres (safety valve against runaway scans) | `psql` (role-scoped) | `ALTER ROLE trino_reader SET statement_timeout='5min'` |

The PgBouncer pool size and the Postgres role `CONNECTION LIMIT` should be set to the **same number** — that way the role limit acts as a "did anything bypass PgBouncer?" tripwire, and PgBouncer is the lever you tune. The resource-group concurrency limit + average splits/tables per query (see the JDBC connection model note in section C below) determines how many of those backend slots are actually in use at peak. Each layer is explained in full detail below.

#### A. PgBouncer in front of Postgres (the standard fix)

PgBouncer is a lightweight Postgres connection pooler. Put it between Trino and Postgres and it becomes the de-facto pool that Trino's connector lacks. Trino opens many short-lived connections to PgBouncer; PgBouncer multiplexes them onto a small, bounded set of real Postgres backend connections.

- **Mode**: use **transaction pooling** (`pool_mode = transaction`). Trino's queries are read-only and don't rely on session-level state across statements, so transaction pooling is safe and gives you the highest multiplexing factor.
- **Deployment** (on-prem k8s): run PgBouncer as a Kubernetes Deployment (with a Service in front) in the same cluster as the Postgres replica, or as a sidecar to Trino — both patterns work. A Deployment + Service is the more common pattern because multiple consumers (Trino + other internal tools) can share it.
- **Point Trino at PgBouncer, not Postgres directly — and append `prepareThreshold=0` to the JDBC URL.** In `etc/catalog/app_pg.properties`:

  ```properties
  # Before (direct to replica): jdbc:postgresql://app-postgres-replica:5432/appdb
  # After (through PgBouncer) — note prepareThreshold=0:
  connection-url=jdbc:postgresql://pgbouncer.app.svc.cluster.local:6432/appdb?prepareThreshold=0
  ```

  > **Critical caveat — WHY `prepareThreshold=0` is mandatory when PgBouncer is in transaction-pooling mode.**
  >
  > **The mechanism in one paragraph**: PostgreSQL server-side prepared statements are **connection-scoped** — when you `PREPARE` a statement, it lives inside the lifecycle of the specific Postgres backend process that received the PREPARE. PgBouncer in **transaction-pooling mode** (`pool_mode = transaction`) routes successive transactions from the same client to **potentially different Postgres backend connections**. So if a Trino JDBC client issues a PREPARE on backend connection A and PgBouncer routes the next transaction to backend connection B, Postgres returns `ERROR: prepared statement "S_1" does not exist` — backend B never saw the PREPARE.
  >
  > **The JDBC driver's default behavior triggers this**: The PostgreSQL JDBC driver caches server-side prepared statements by default (`prepareThreshold=5` — after the 5th execution of the same SQL, the driver issues `PREPARE` and reuses the prepared plan). Combined with PgBouncer transaction-pooling, this means **the failure is not immediate** — it appears only after Trino has run the same query 5+ times and the driver decides to start using prepared statements. Your federation will appear to work fine for the first few queries, then fail intermittently as the driver promotes statements to prepared form and PgBouncer reuses backends.
  >
  > **The fix — `prepareThreshold=0` in the JDBC URL**: Setting `prepareThreshold=0` disables server-side prepared statements entirely on the Trino JDBC client. Every query is sent as a **simple query string** with inline parameters instead. This adds a small overhead per query (no plan reuse) but **eliminates the prepared-statement routing error** that PgBouncer transaction-pooling otherwise produces. This is the standard, documented workaround for PgBouncer + pgjdbc in transaction mode.
  >
  > **Why not use session-pooling instead?** PgBouncer's `pool_mode = session` would solve this (each client gets a dedicated backend for the whole session) but at the cost of much lower multiplexing — you'd need almost as many backends as concurrent Trino client connections, which defeats the point of PgBouncer. Transaction-pooling + `prepareThreshold=0` is the right combination for Trino federation traffic, which is read-only and doesn't rely on session state across transactions.
  >
  > **Without the fix**: your federation will appear to work, then fail intermittently after PgBouncer reuses backends — typically the first user reports of "we get weird `prepared statement does not exist` errors a few minutes into the day" come on day 2 or 3 of running federation in production.
  >
  > **PgBouncer 1.21+ — native server-side prepared-statement support changes the story (but does not remove the safe default).**
  >
  > **PgBouncer 1.21 (released October 2023)** added **native server-side prepared-statement support** for `pool_mode = transaction`, controlled by the `max_prepared_statements` config option. When `max_prepared_statements > 0`, PgBouncer tracks PREPARE/DEALLOCATE statements per client and **transparently replays the PREPARE on whichever backend it routes the next transaction to** — eliminating the "prepared statement does not exist" failure mode that motivated `prepareThreshold=0` in the first place.
  >
  > **What this means for your `prepareThreshold=0` choice:**
  > - With **PgBouncer ≥ 1.21** AND `max_prepared_statements > 0` in `pgbouncer.ini`, `prepareThreshold=0` is **optional**. You can remove it (or leave it at the JDBC driver default of `5`) and the prepared-statement caching benefit returns — small per-query overhead savings.
  > - With **PgBouncer < 1.21**, OR **PgBouncer ≥ 1.21 but `max_prepared_statements = 0`** (the default — it must be explicitly opted into), `prepareThreshold=0` remains **mandatory**. Without it the intermittent prepared-statement failures resume.
  >
  > **Check your PgBouncer version before relying on the new behavior:**
  > ```bash
  > # From a shell on the PgBouncer pod / host:
  > pgbouncer --version
  > # Output (example): PgBouncer 1.21.0
  > ```
  > Or via the PgBouncer admin console (connect with `psql -p 6432 pgbouncer` as a user listed in `admin_users`):
  > ```
  > SHOW VERSION;
  > -- Returns the PgBouncer version string.
  > ```
  > And confirm the prepared-statement setting is actually enabled:
  > ```ini
  > # In pgbouncer.ini — explicitly opt-in (default is 0 = OFF):
  > [pgbouncer]
  > pool_mode = transaction
  > max_prepared_statements = 100   # tune to your peak unique prepared-statement count
  > ```
  > Then `SHOW CONFIG;` in the admin console to verify the live value.
  >
  > **When in doubt, keep `prepareThreshold=0`.** It is safe and compatible with **every** PgBouncer version (1.x through 1.21+) and adds only a small per-query parsing overhead on the Postgres side. The conservative production posture on this stack is: leave `prepareThreshold=0` in the JDBC URL unless you have explicitly verified both (a) PgBouncer ≥ 1.21 AND (b) `max_prepared_statements > 0` is actually set in your `pgbouncer.ini`. Removing `prepareThreshold=0` based on assumption (e.g., "we upgraded PgBouncer last quarter, it should be fine") is the kind of thing that surfaces as intermittent production breakage weeks later.

- **PgBouncer config** (`pgbouncer.ini`) — minimal example sized for a 20-worker Trino cluster:

  ```ini
  [databases]
  appdb = host=app-postgres-replica.app.svc.cluster.local port=5432 dbname=appdb

  [pgbouncer]
  listen_port = 6432
  listen_addr = 0.0.0.0
  auth_type = scram-sha-256
  auth_file = /etc/pgbouncer/userlist.txt
  pool_mode = transaction
  max_client_conn = 1000           # how many client conns PgBouncer will accept (Trino-side)
  default_pool_size = 50           # actual backend conns PgBouncer holds open to Postgres per (db,user)
  reserve_pool_size = 10
  server_idle_timeout = 600
  ```

  With `default_pool_size=50`, the Postgres replica sees at most 50 connections from `trino_reader` no matter how many concurrent client connections Trino opens. This is the bound you wanted.

- **Caveat**: prepared statements that span statements are not supported in transaction-pooling mode. Trino's JDBC traffic does not rely on these, so this is not a problem in practice — but it is something to confirm if you ever add other clients behind the same PgBouncer.

#### B. Postgres role-level connection cap (defense in depth)

Even with PgBouncer, set a hard cap on the Postgres side using `CONNECTION LIMIT` on the `trino_reader` role:

```sql
-- On the Postgres replica (or replicated from primary):
ALTER ROLE trino_reader CONNECTION LIMIT 50;
```

This is enforced by Postgres itself. If anything (PgBouncer misconfigured, a direct connection that bypasses PgBouncer, a runaway test) opens the 51st connection as `trino_reader`, Postgres rejects it. The application's own users (different role) are unaffected.

Check current usage:

```sql
SELECT count(*) FROM pg_stat_activity WHERE usename = 'trino_reader';
SELECT rolname, rolconnlimit FROM pg_roles WHERE rolname = 'trino_reader';
```

#### C. Trino resource groups — cap concurrent queries against the catalog

If too many federated queries hit Postgres at once, the most effective lever inside Trino is **resource groups**: limit how many queries can run concurrently against the federation workload. Fewer concurrent queries means fewer simultaneous Postgres connections, regardless of pooling.

This is NOT a connection pool, but it is the correct OSS-Trino lever for controlling upstream JDBC pressure.

> **ANTI-PATTERN WARNING — `"groups"` vs `"rootGroups"`**: The top-level key in `resource-groups.json` is **`"rootGroups"`**, NOT `"groups"`. Every example you write must start with `"rootGroups": [...]`. Also: every group name referenced in `"selectors"` must be defined somewhere in the `"rootGroups"` tree; an undefined group in a selector causes the selector to silently not apply.
>
> **Two common mistakes, different failure modes — know which one you have:**
> - **Top-level `"groups"` instead of `"rootGroups"`**: the coordinator **refuses to start** with a parse/validation error visible in `var/log/server.log` (something like `Unrecognized field "groups"` or `Missing required property "rootGroups"` depending on the Trino version). This is the **loud** failure mode — easy to catch because the coordinator never comes up.
> - **Selector `"group": "typo-name"` referencing a group not defined in `rootGroups`**: that **selector silently never matches**; queries fall through to the next selector in order, ultimately hitting the catch-all (or being unassigned). Coordinator starts fine. There is **no startup error and no per-query warning** — the only symptom is that queries you expected to be governed by the federation group are actually running with no concurrency cap. This is the **hard-to-debug** mode — verify every group name in `"selectors"` exactly matches a name in the `rootGroups` tree, and confirm wiring by checking each query's `Resource group` field in the Trino UI Query Details page.

> **CRITICAL — DO NOT INVENT PROPERTY NAMES. These two wrong names cause production failures:**
>
> **WRONG name 1: `maxQueuedQueries` does NOT exist.** The correct property is **`maxQueued`** (no "Queries" suffix). See the official spec at [trino.io/docs/current/admin/resource-groups.html](https://trino.io/docs/current/admin/resource-groups.html). If you put `"maxQueuedQueries": 100` in `resource-groups.json`, the **coordinator rejects the resource-groups configuration at startup** with an unrecognized-field error. There is no "maxQueuedQueries" anywhere in the Trino resource-groups schema. Always write **`"maxQueued": 100`** in JSON examples.
>
> **WRONG name 2: `http-server.max-connections` does NOT exist.** This property is sometimes suggested by engineers (and by LLMs hallucinating from generic web-server vocabulary) as a way to "limit concurrent HTTP connections to the Trino coordinator." **It is not a real Trino config property.** Putting `http-server.max-connections=1500` in `etc/config.properties` causes the **coordinator to fail startup** with `Configuration property 'http-server.max-connections' was not used`. The actual property controlling HTTP server thread capacity (which is what indirectly bounds concurrent HTTP handling) is **`http-server.threads.max`** (default 200). If you genuinely need to raise HTTP handling capacity on a busy coordinator, set `http-server.threads.max=500` in `etc/config.properties` — NOT a `max-connections` property. **The right lever for capping concurrent _queries_ (which is almost always the real intent) is resource groups (`hardConcurrencyLimit` + `maxQueued`), NOT any HTTP-layer property.** HTTP threads bound coordinator I/O concurrency; resource groups bound query concurrency. Do not mix them up.
>
> **Both wrong names share the same root cause**: engineers and LLMs invent intuitive-sounding names (the JSON field "should" be called `maxQueuedQueries` because it queues queries; the HTTP property "should" be called `max-connections` like nginx) and Trino refuses to start. **Always verify property names against trino.io official docs before adding them to any config file.**

A simple `etc/resource-groups.json` snippet:

```json
{
  "rootGroups": [
    {
      "name": "federation",
      "softMemoryLimit": "60%",
      "hardConcurrencyLimit": 30,
      "maxQueued": 200,
      "schedulingPolicy": "fair",
      "subGroups": [
        {
          "name": "queries",
          "softMemoryLimit": "30%",
          "softConcurrencyLimit": 8,
          "hardConcurrencyLimit": 10,
          "maxQueued": 100
        },
        {
          "name": "adhoc",
          "softMemoryLimit": "10%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50
        }
      ]
    }
  ],
  "selectors": [
    {
      "user": ".*",
      "queryType": "SELECT",
      "source": ".*federation.*",
      "group": "federation.queries"
    },
    {
      "user": ".*",
      "group": "federation.adhoc"
    }
  ]
}
```

> **CRITICAL — selectors must target LEAF groups**: A leaf group is a group with **no `subGroups`** of its own. Trino enforces "A resource group may have sub-groups OR may accept queries, but not both" (see [trino.io/docs/current/admin/resource-groups.html](https://trino.io/docs/current/admin/resource-groups.html)). If a selector routes to a parent group (one that has `subGroups`), Trino's behavior is **inconsistent and unsupported** — the coordinator may reject the config at load time, silently drop the routing, or fall through to a no-limit default depending on version. **Always route the catch-all to a dedicated leaf**, e.g., create a `federation.adhoc` (or `federation.global`) leaf subgroup as shown above and point the catch-all selector at it. Do **NOT** write `{ "group": "federation" }` as a catch-all when `federation` has subGroups.

**Property name reference (verify against [trino.io/docs/current/admin/resource-groups.html](https://trino.io/docs/current/admin/resource-groups.html) before adding any field):**

| JSON field | Type | Meaning |
|---|---|---|
| `softMemoryLimit` | percent or bytes | Soft cap on cluster memory used by the group. New queries are still admitted past this but throttled. |
| `softConcurrencyLimit` | int | When queries-running >= this value, the scheduler starts preferring queries in other groups. **Does not block admission.** |
| `hardConcurrencyLimit` | int | Hard cap on concurrent running queries in the group. Queries past this are queued (or rejected if `maxQueued` is also full). |
| `maxQueued` | int | Max queued queries. **NOT `maxQueuedQueries` — that name does NOT exist and breaks coordinator startup.** When both `hardConcurrencyLimit` and `maxQueued` are full, new queries are **rejected** with `Too many queued queries for group`. |
| `schedulingPolicy` | enum | `fair` (default), `weighted_fair`, `weighted`, `query_priority`. **`fifo` is not valid** — see callout below. |
| `hardCpuLimit` / `softCpuLimit` / `cpuQuotaPeriod` | duration | Optional rolling-window CPU caps. **NOT `cpuLimit`.** |

##### Richer example — three subgroups with selector routing

The single-group example above is the minimum viable shape. In production you usually want **multiple subgroups** for different query workloads (dashboards, exports, ad-hoc), each with its own concurrency limit. **Subgroups are unreachable unless a `selectors` entry routes queries to them** — without selectors that match each subgroup, all queries fall through to the catch-all (or are unassigned).

```json
{
  "rootGroups": [
    {
      "name": "federation",
      "softMemoryLimit": "60%",
      "hardConcurrencyLimit": 30,
      "maxQueued": 200,
      "schedulingPolicy": "fair",
      "subGroups": [
        {
          "name": "dashboards",
          "softMemoryLimit": "30%",
          "hardConcurrencyLimit": 15,
          "maxQueued": 100
        },
        {
          "name": "exports",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 4,
          "maxQueued": 50
        },
        {
          "name": "global",
          "softMemoryLimit": "10%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 50
        }
      ]
    }
  ],
  "selectors": [
    { "group": "federation.dashboards", "source": "dashboard-.*" },
    { "group": "federation.exports",    "source": "export-.*"    },
    { "group": "federation.global",     "source": ".*"           }
  ]
}
```

**Read carefully:**
- The `group` value in each selector uses a **dot path** (`federation.dashboards`) that traverses the `rootGroups` tree to the named subgroup.
- **Every selector — including the catch-all — MUST target a leaf group** (a group with no `subGroups`). Above, `federation.dashboards`, `federation.exports`, and `federation.global` are all leaves; the catch-all `{ ".*" → federation.global }` routes to a leaf. Routing a selector to the parent `federation` group would be invalid because `federation` has subGroups, and Trino's rule is "a group may have sub-groups OR accept queries, but not both" — the result is inconsistent or rejected routing. If you need a catch-all, **always create a dedicated leaf subgroup for it** (`global`, `adhoc`, `default`, etc.) rather than routing to the root.
- Selectors are evaluated **in file order**. The first matching selector wins. Put the most specific selectors **first** and the catch-all (`.*`) **last** — otherwise the catch-all swallows everything and the specific selectors never fire.
- **Without a `selectors` array, NO queries land in any subgroup.** They fall through to a coordinator default with no concurrency cap — your `hardConcurrencyLimit` is silently bypassed. The selectors are not optional decoration; they are the routing mechanism that connects clients to subgroups.
- The `source` field is matched against the client-supplied `X-Trino-Source` header / JDBC `source=` parameter / CLI `--source` flag. Clients MUST set this value (see "How to make the `source` regex match your queries" below).
- You can also match on `user`, `userGroup`, `queryType`, `clientTags`, `selectorPriority`. Combine fields with AND semantics (all must match).

**Hot-reload — file-based manager does NOT support it**: The file-based configuration manager (`resource-groups.configuration-manager=file`) does **NOT** hot-reload. Any change to `resource-groups.json` requires a **coordinator restart** to take effect. There is **no `resource-groups.config-refresh-period` property** — if you have seen that name elsewhere it is fabricated; the coordinator will reject the property at startup with `Unknown property` and fail to load the resource-groups config. Verify on [trino.io/docs/current/admin/resource-groups.html](https://trino.io/docs/current/admin/resource-groups.html) before adding any property to `resource-groups.properties`.

**For hot-reload without restart**, switch to the **database-based** configuration manager (`resource-groups.configuration-manager=db`) and set `resource-groups.refresh-interval` (default `1s`). The db manager polls a backing MySQL/PostgreSQL/Oracle table on that interval and applies changes to **future** queries without restarting the coordinator. Currently-running queries keep their original group. This is the only supported live-reload path in Trino OSS.

```properties
# etc/resource-groups.properties — FILE-BASED (no hot-reload; restart required on JSON change)
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

```properties
# etc/resource-groups.properties — DATABASE-BASED (live reload via resource-groups.refresh-interval)
resource-groups.configuration-manager=db
resource-groups.config-db-url=jdbc:mysql://db-host:3306/resource_groups
resource-groups.config-db-user=trino
resource-groups.config-db-password=...
resource-groups.refresh-interval=10s
```

> **Common mistake**: writing `resource-groups.config-refresh-period=10s` (or `resource-groups.refresh-period`, or `resource-groups.reload-interval`) under the file-based manager. **None of these properties exist.** The only valid live-reload property is `resource-groups.refresh-interval`, and it is recognized **only** when `resource-groups.configuration-manager=db`. To change limits on a running file-based cluster, you must restart the coordinator.

> **`schedulingPolicy` — valid values (Trino 467)**: only **`fair`** (default), **`weighted_fair`**, **`weighted`**, and **`query_priority`** are accepted. **There is NO `"fifo"` value** — if you set `"schedulingPolicy": "fifo"` the coordinator will reject the resource-groups configuration at startup. For batch ETL workloads that want "FIFO-style" submission-order processing, **`fair` IS the right choice**: within a group of equal-weight queries, `fair` runs them in submission order (first submitted, first scheduled). Engineers who want a literal "FIFO queue" are looking for `fair` under a different name. Use `weighted` / `weighted_fair` only when you have multiple sub-groups that should split scheduler attention by a non-equal weight; use `query_priority` only when clients are setting per-query priority via the `query_priority` session property.

`hardConcurrencyLimit: 10` means at most 10 federation queries run concurrently; the next 100 wait in queue; further queries are rejected. Combined with PgBouncer's `default_pool_size=50`, you have layered bounds: at most 10 concurrent queries, each typically opening 1 JDBC connection per non-partitioned Postgres table scanned (NOT one per worker — see the JDBC connection model note below), and the whole pool is capped at 50 actual Postgres backends regardless.

##### How to wire the resource groups config to the coordinator

> **CRITICAL**: The wiring properties go in a **dedicated `etc/resource-groups.properties` file**, NOT in `etc/config.properties`. This is a common mistake — putting them in `config.properties` silently has no effect.

Create `etc/resource-groups.properties` on the Trino coordinator:

```properties
resource-groups.configuration-manager=file
resource-groups.config-file=etc/resource-groups.json
```

Then restart the coordinator. The two files are completely separate:
- `etc/config.properties` — standard Trino coordinator settings (ports, memory, discovery, etc.)
- `etc/resource-groups.properties` — resource group manager configuration only

In Kubernetes, mount both as separate ConfigMap keys. A coordinator restart is required after creating or changing either file.

##### How to make the `source` regex match your queries — the missing setup step

The `source` field in the selector matches the **source name set at query submission time** — a free-form string that the client supplies when it opens a connection or submits a query. **The selector cannot match anything if no client sets the source.** You control the source via one of three mechanisms:

1. **JDBC connection URL** (most common for BI tools / app code):
   ```
   jdbc:trino://coordinator:8080/iceberg?source=federation-queries
   ```
2. **Trino CLI flag** (for analyst / ad-hoc usage):
   ```bash
   trino --server coordinator:8080 --source federation-queries
   ```
3. **HTTP header** (for the REST API / direct HTTP clients):
   ```
   X-Trino-Source: federation-queries
   ```

**If the source is not set, the selector will not match** and queries will fall through to the next selector in the file (typically a catch-all `"user": ".*"` rule that puts queries in a default group with no `hardConcurrencyLimit`). The federation queries then bypass your `hardConcurrencyLimit=10` cap entirely and Postgres connection pressure returns.

The source name does **not** have to match the regex exactly — it just needs to **satisfy the pattern**. `federation-queries`, `federation-bi-dashboard`, `analytics-federation-job` all match `.*federation.*` because the regex is anchored loosely (substring match). You can be more or less specific depending on how you want to group:

- `^federation-.*` — only matches sources that START with `federation-` (more restrictive)
- `.*federation.*` — matches any source containing `federation` anywhere (loose, what's shown above)
- `^federation-queries$` — matches exactly `federation-queries` (most restrictive)

**Operational checklist after wiring up a `source`-based selector:**
1. Confirm clients ARE setting the source (run a federation query, then check `SELECT "source" FROM system.runtime.queries WHERE query LIKE '%app_pg%' ORDER BY created DESC LIMIT 5` — `"source"` should be quoted; `source` may also be reserved depending on Trino version).
2. Verify queries are landing in the `federation` resource group by checking the Trino UI's per-query details (the "Resource group" field).
3. If queries are NOT being grouped, either the client isn't setting `source` correctly or the regex isn't matching. Fix the client first; the regex is rarely the bug.

> **Note**: `hardConcurrencyLimit` caps the number of **concurrent Trino queries** in the group, not JDBC connections directly. **JDBC connection model**: a single Trino query scanning **one non-partitioned Postgres table opens exactly 1 JDBC connection** — one split, one worker task, one connection. It is NOT one per worker. Connection count scales with `concurrent_queries × postgres_tables_per_query × splits_per_table`, NOT with worker count. The exceptions where one query opens multiple Postgres connections are: (a) the query joins multiple Postgres tables (one connection per scanned table), (b) the `partition-column` property — **Starburst Enterprise only, NOT available in OSS Trino 467** — is set so Trino splits the table into N parallel range-scans (N connections), or (c) a custom split strategy is in use. For typical single-table federation with PgBouncer `default_pool_size=50`, that ceiling supports roughly 50 concurrent federation queries before connections saturate. For tight connection-count control, combine resource groups with PgBouncer (Section 8.2A) and a Postgres role-level `CONNECTION LIMIT` (Section 8.2B). Resource groups are the Trino-side lever; PgBouncer is the network-side lever.

#### D. `statement_timeout` on the Postgres replica (also see 8.3 below)

A runaway federated query that for some reason doesn't get predicate pushdown should not be allowed to run forever. Set `statement_timeout = '5min'` in the replica's `postgresql.conf`. This kills any single statement (including those issued by Trino) that exceeds the threshold. Covered in detail in Section 8.3.

#### E. Dedicated read replica (already covered in 2.3 and 8.1)

The replica isolation already covered above means even when these bounds are hit, only analytical traffic — never the OLTP primary — is affected.

#### How to size the pieces together — worked example

A 20-worker Trino cluster, Postgres replica with `max_connections=300`, application using ~150 of those for its own readers:

| Layer | Setting | Value |
|---|---|---|
| PgBouncer | `default_pool_size` (per db,user pair) | `50` |
| Postgres role | `ALTER ROLE trino_reader CONNECTION LIMIT` | `50` (matches PgBouncer ceiling) |
| Trino resource group | `hardConcurrencyLimit` for federation queries | `10` |
| Postgres replica | `statement_timeout` | `5min` |
| Application headroom | (300 - 50) = 250, well above the 150 used | OK |

This gives you a 50-connection ceiling from Trino regardless of how many queries hit, with at most 10 concurrent federation queries, and a 5-minute backstop on any single query. Adjust the numbers, but follow this layered pattern.

#### What does NOT work (do not try these)

- **`connection-pool.enabled=true`, `connection-pool.max-size=N`, `connection-pool.max-connection-lifetime=...`** in the PostgreSQL catalog file. These are Starburst Enterprise properties. OSS Trino 467 silently ignores them.
- **`postgresql.connection-pool.*`** with a `postgresql.` prefix. Also not recognized by OSS Trino's PostgreSQL connector.
- **Hand-rolling a `connection-pool.*` property and hoping HikariCP picks it up.** OSS Trino's PostgreSQL connector does not wire HikariCP — even when the property name happens to match. The plumbing is not there.
- **The Oracle property names** (`oracle.connection-pool.max-size`) on the PostgreSQL connector. Those work for the Oracle connector only (which is the lone OSS Trino JDBC connector with native pooling as of 467). Connector prefixes are not interchangeable.

### 8.3 Set a `statement_timeout` on the Postgres replica

Add to the replica's `postgresql.conf`:

```
statement_timeout = '5min'
```

This kills any single Postgres statement (including those issued by Trino) that runs longer than 5 minutes. A rogue federated query that for some reason doesn't get predicate pushdown won't run forever and bloat the replica.

#### Verbatim error strings — know which layer killed the query

When a federated query fails with "timeout," the **first triage question** is *which* layer gave up: Postgres, the JDBC driver, or Trino itself? Each emits a distinct error string, and the layer determines the fix. Memorize these so you can grep the Trino UI / coordinator logs without reading full stack traces:

| Layer that killed it | Verbatim error string you will see | What it means | Where to look |
|---|---|---|---|
| **Postgres** (`statement_timeout` fired) | `ERROR: canceling statement due to statement timeout` | Postgres itself decided the statement ran longer than the role/cluster `statement_timeout`. The connection is alive; just this statement was cancelled. | Postgres replica logs AND the Trino query error surfaces this string verbatim in the failure reason. |
| **JDBC driver** (`socketTimeout` fired) | `java.net.SocketTimeoutException: Read timed out` | The JDBC client (Trino worker) gave up waiting for bytes from Postgres after the configured `socketTimeout` seconds (Section 2.4). Often means a hung Postgres backend, network blip, or replication stall — Postgres did not actively cancel; the client did. | Trino worker logs / query failure stack trace. |
| **Trino** (`query.max-execution-time` or `query.max-run-time` fired) | `Query exceeded maximum time limit of Xm` (where X is the configured limit, e.g., `10.00m`) | Trino's own per-query wall-clock limit kicked in. The query was cancelled cluster-wide; in-flight JDBC reads are aborted. **See the `query.max-run-time` vs `query.max-execution-time` distinction below — they bound different windows.** | Trino UI failure reason; Trino coordinator logs. |

**How to use this table during triage:**

- If you see `ERROR: canceling statement due to statement timeout` → it's the Postgres side. Either the query was genuinely too expensive for the replica (check `pg_stat_activity` history / slow log), or `statement_timeout` is set too aggressively for legitimate workloads. Raise the timeout on the replica, OR (better) fix the query so it pushes down properly (Section 3).
- If you see `java.net.SocketTimeoutException: Read timed out` → JDBC-level abort. Check (a) is Postgres actually still alive? (b) is `socketTimeout` set too low for the workload? (c) is there a network issue (PgBouncer health, k8s NetworkPolicy)? Postgres may not have logged anything at all — the cancellation was client-side.
- If you see `Query exceeded maximum time limit of Xm` → Trino's own timeout. The fix is either tune the query, raise the per-session `query_max_execution_time` (or `query_max_run_time` if the time is being spent waiting in a resource-group queue — see distinction below), or move the workload off federation entirely (it's too big to be a sane federated query — ingest to Iceberg per Section 6).

#### `query.max-run-time` vs `query.max-execution-time` — they bound DIFFERENT windows

This trips engineers up constantly when investigating "the user said the query hung for several minutes" reports. **Trino has two distinct cluster-level query-time bounds, and they are NOT interchangeable:**

- **`query.max-execution-time`** — covers **active compute time only**. It starts ticking when the query begins executing on workers; it does **NOT** include time spent waiting in a resource-group queue for a concurrency slot, and it does NOT include analysis or planning time. If a query sits in queue for 10 minutes because the `federation` resource group is at its `hardConcurrencyLimit`, that queue time does not count against `query.max-execution-time`.
- **`query.max-run-time`** — covers **total user-perceived time**: analysis + planning + queue wait + active execution. This is the wall-clock time from when the user submitted the query to when it succeeded, failed, or was killed. It is the right lever for "the user complained the query hung."

For "the user complaint of 'the query hung for several minutes,'" **`query.max-run-time` is the more accurate limit to set** — it bounds the total elapsed time the user actually experiences. `query.max-execution-time` alone does not catch the queueing scenario.

**Set both for belt-and-suspenders** — they layer:

```properties
# etc/config.properties on the coordinator
query.max-execution-time=10m   # cap on active compute time
query.max-run-time=15m         # cap on total user-perceived time (includes queue wait)
```

Or per session:

```sql
SET SESSION query_max_execution_time = '10m';
SET SESSION query_max_run_time = '15m';
```

The `query.max-run-time` setting is what you reach for when investigating "this federated query was queued behind 9 others because we set `hardConcurrencyLimit=10` and it sat for 8 minutes before even starting." Without `query.max-run-time`, the user sees an 8-minute "hang" with no cancellation, and `query.max-execution-time` never even gets armed.

**Belt-and-suspenders ordering across ALL layers**: configure all four (now five, counting Postgres) timeouts so the **innermost** (Postgres `statement_timeout`) fires first, then the JDBC `socketTimeout`, then Trino's `query.max-execution-time`, then Trino's `query.max-run-time` as the outermost cap. A typical setup:

- Postgres `statement_timeout = '5min'` (innermost — Postgres cancels the SQL statement itself)
- JDBC `socketTimeout=60` (per-read socket timeout — fires if Postgres goes silent mid-query)
- Trino `query.max-execution-time = 10m` (caps active compute time)
- Trino `query.max-run-time = 15m` (caps total user-perceived time, including queue wait)

The Postgres-side cancellation is the cleanest failure mode because it does NOT abandon the JDBC connection — only the statement is killed, the connection stays in the pool. Socket-level timeouts often discard the connection entirely, increasing reconnection churn. The two Trino-side caps catch any cases where the lower layers do not.

#### Fifth layer (optional but recommended) — Postgres `statement_timeout` on the role itself

Beyond the four layers above (which are mostly Trino-side), set a hard timeout on the Postgres read replica itself, scoped to the `trino_reader` role. Any query that runs longer than the limit is cancelled by Postgres, **even if Trino's `socketTimeout` hasn't fired yet and even if Trino's config is misconfigured**:

```sql
-- Run on the Postgres replica (permanent for the trino_reader role):
ALTER ROLE trino_reader SET statement_timeout = '300000';  -- 5 minutes in milliseconds
SELECT pg_reload_conf();
```

This is a cheap defense that works even if Trino's JDBC layer is misconfigured. It also protects the replica from other processes (not just Trino) that might run long queries under the `trino_reader` role. The role-level setting takes effect for all new sessions; existing sessions retain the prior value until they reconnect.

> **Why role-level vs `postgresql.conf`?** Setting `statement_timeout` in `postgresql.conf` applies to **every connection on the replica** — including ones from app code, replication tooling, or maintenance jobs. Setting it via `ALTER ROLE trino_reader SET statement_timeout` scopes the limit to **only Trino-originated sessions**, leaving other roles alone. For a replica that hosts mixed workloads, the role-level scope is the safer default. If the replica is dedicated to Trino, either approach is fine.

#### Sixth layer (defense in depth) — `idle_in_transaction_session_timeout` on the role

In addition to `statement_timeout`, set an idle-in-transaction guard on the `trino_reader` role:

```sql
-- On the Postgres replica:
ALTER ROLE trino_reader SET idle_in_transaction_session_timeout = '60s';
SELECT pg_reload_conf();
```

`idle_in_transaction_session_timeout = '60s'` — cancels connections that are in a transaction state with no active statement for more than 60 seconds. Useful for catching Trino sessions that left a transaction open without an active query (a rare bug, but it can happen if a Trino worker dies mid-transaction or a JDBC driver fails to issue COMMIT/ROLLBACK). Without this guard, an orphaned `idle in transaction` session holds locks and a backend slot indefinitely. The 60-second value is generous enough that legitimate slow queries on the next statement do not trip it — `statement_timeout` (5min) covers slow statements; `idle_in_transaction_session_timeout` covers the "no statement at all" gap. Layer both.

#### Manually killing a runaway federated query — `system.runtime.kill_query`

When a federated query is hammering Postgres and you need to terminate it immediately (before any of the timeouts above fire), use Trino's built-in `kill_query` procedure. This issues a cluster-wide cancellation: the coordinator marks the query as `FAILED`, in-flight worker tasks are interrupted, and the JDBC connections to Postgres are released.

```sql
-- Find the query_id from the Trino UI (/ui/) or system.runtime.queries.
-- Then kill it. The `message` parameter is OPTIONAL but recommended for audit trail.
CALL system.runtime.kill_query(
  query_id => '20260527_143012_00042_abcde',
  message => 'Runaway federation query — too much JDBC traffic'
);
```

Notes:

- The `message` parameter appears in **audit logs** (event listener `QueryCompletedEvent.failureInfo.message`) and is also shown to the killed user in their query error — they will see your message verbatim. Use a clear, attributable string so the affected engineer can self-diagnose.
- The procedure is **idempotent** for terminal-state queries — calling it on an already-FINISHED or already-FAILED query does nothing (returns successfully). Calling it on a non-existent query_id errors with `Query not found`.
- The caller needs the `kill_query` system privilege (granted via OPA / system access control). On the production stack, this typically means a SRE or on-call operator role — not application roles.
- **Prefer killing the query via Trino over killing the Postgres backend with `pg_cancel_backend()`** — the latter only cancels the current SQL on one Postgres connection, but the Trino query continues running and may immediately re-issue the same SQL on another connection.

> **Note on MySQL vs PostgreSQL cancellation:** PostgreSQL receives a CancelRequest (a separate backend-to-backend message on its own socket — pgjdbc opens a side connection to the Postgres backend specifically to deliver the cancel signal). MySQL uses `KILL QUERY <connection-id>` internally (MySQL Connector/J issues this against the same MySQL server using the connection's thread id). The result is the same (the running query stops on the database side), but the wire protocol differs — if you see different cancellation latencies between MySQL and PostgreSQL federation queries (e.g., MySQL cancels feel slightly slower because the driver must first open a fresh control connection to issue `KILL QUERY`), this is why. Both connectors implement `Statement.cancel()` in the JDBC layer, and Trino's `kill_query` procedure routes through that same `Statement.cancel()` path for both connectors.

### 8.3A Federated query timeout layers — ALL of them, outer to inner

This is the single most-asked question in federation incident triage: "we set a 5-minute timeout but the query ran for 2 hours, which layer is wrong?" Here is the **full set of timeout layers** between a user's `SELECT` and a row landing on the Postgres replica, in order from outermost (client) to innermost (the database server). **Each layer has its own default, its own configuration knob, and its own error message** — knowing which fires is half the diagnosis.

> **Mental model**: every federated query passes through ALL of these layers. Any one of them can kill the query (or the connection) independently. A "5-minute timeout" the user sees in production is typically the *first* of these to fire — and that may not be the one the engineer expected.

#### Layer 1 — Trino client abandonment timeout (`query.client.timeout`)

- **What it controls**: how long the Trino coordinator keeps a query alive when the client has stopped polling for results.
- **Default**: **5 minutes**.
- **Configure**: `query.client.timeout=10m` in `etc/config.properties` on the coordinator.
- **PROPERTY-NAME PRECISION**: the property is **`query.client.timeout`** — all **dots** between segments, no hyphens. Writing `query.client-timeout` (hyphen before `timeout`) is a common mistake; the property loads without error in some Trino versions but does nothing, leaving the default 5-minute window in place. Always use the all-dots form.
- **When it fires**: client (JDBC driver, CLI, BI tool) has not fetched a new result page within the timeout window. Common cause: the BI tool was closed, the user's browser tab refreshed, the network died.
- **Error**: query state transitions to `FAILED` in the Trino UI with `Client has not requested any data for X seconds`. From the user's side: the query just disappears.

#### Layer 2 — Trino query execution / run-time caps (`query.max-execution-time`, `query.max-run-time`)

- **What they control**: per-query wall-clock caps enforced by the coordinator. `query.max-execution-time` caps **active compute time only** (does NOT include queue wait). `query.max-run-time` caps **total elapsed time** (includes analysis, planning, queue wait, AND compute).
- **Default**: **100 days** for both — effectively unlimited unless overridden.
- **Configure cluster-wide**: `query.max-execution-time=10m`, `query.max-run-time=15m` in `etc/config.properties`.
- **Configure per session**: `SET SESSION query_max_execution_time = '10m'; SET SESSION query_max_run_time = '15m';` (these are **system-level** session properties — bare form, NO catalog prefix).
- **When it fires**: query exceeded the cap. Default 100d means **these almost never fire unless the cluster has explicitly tightened them** — but production clusters almost always do, typically to 10–30 minutes.
- **Error**: `Query exceeded maximum time limit of Xm` (where X is the configured limit) — surfaced in the Trino UI failure reason. **For the "I think Trino killed my query" complaint, this error is the smoking gun.**
- **`max-execution-time` vs `max-run-time` distinction**: see Section 8.3 above — `max-execution-time` does NOT include time spent waiting in a resource-group queue. If a query was queued for 9 minutes and then ran for 1 minute, `max-execution-time=5m` does NOT fire; `max-run-time=5m` does. For "the user complained the query hung," `max-run-time` is the more accurate lever.

> **DIAGNOSTIC TIP — discover what limits are currently active on your session before guessing.** Run `SHOW SESSION LIKE 'query_max%';` in the Trino CLI (or any SQL client connected to Trino). This lists every active session property whose name starts with `query_max` along with its **current value**, **default value**, and a short description. Use it to answer "what is `query.max-execution-time` actually set to on this cluster right now?" without grepping `etc/config.properties` on the coordinator or speculating ("probably 10-15 minutes"). Example output:
>
> ```
> trino> SHOW SESSION LIKE 'query_max%';
>          Name                 |  Value  | Default |  Type   | Description
> -----------------------------+---------+---------+---------+--------------------
>  query_max_execution_time     | 10m     | 100.00d | varchar | Maximum execution time of a query
>  query_max_planning_time      | 15m     | 10.00m  | varchar | Maximum planning time of a query
>  query_max_run_time           | 15m     | 100.00d | varchar | Maximum run time of a query
>  query_max_memory             | 50GB    | 20.00GB | varchar | Maximum amount of distributed memory a query can use
>  query_max_memory_per_node    | 5GB     | 6.71GB  | varchar | Maximum amount of memory a query can use per node
>  query_max_stage_count        | 150     | 150     | integer | Maximum number of stages a query can have
> ```
>
> Run this FIRST when diagnosing "did Trino kill my query because of a timeout, or did something else fire?" The output tells you exactly which timeouts are armed and at what value. Pair it with `SHOW SESSION LIKE '%timeout%';` to see catalog-prefixed timeouts (e.g., `app_pg.dynamic_filtering_wait_timeout`), and `SHOW SESSION LIKE '%resource_group%';` to see resource-group-related session properties. **Teach diagnosis, not speculation.**

#### Layer 2A — Trino query planning-time cap (`query.max-planning-time`)

- **What it controls**: caps the time Trino spends in the **planning phase only** — parsing SQL, semantic analysis, statistics lookup, and the cost-based optimizer's join-reordering / pushdown decisions. Planning runs on the coordinator BEFORE any worker executes anything.
- **Default**: **10 minutes**.
- **Configure cluster-wide**: `query.max-planning-time=15m` in `etc/config.properties` on the coordinator.
- **Configure per session**: `SET SESSION query_max_planning_time = '15m';` (system-level — bare form, NO catalog prefix).
- **When it fires**: planning takes longer than the cap. This is the **third Trino-level query-time cap** (alongside `max-execution-time` and `max-run-time`) and it particularly affects **federated queries** with many catalogs, wide multi-way joins, and large `IN`-list constants. CBO cost evaluation across catalogs (JDBC stats lookups, Iceberg manifest scans) can stretch planning into minutes for the worst cases.
- **Error**: `Query exceeded maximum planning time` in the Trino UI failure reason — distinct from the `Query exceeded maximum time limit` error from `max-execution-time` / `max-run-time`. If you see "maximum planning time" in the error, the query never even started execution — the fix is to simplify the plan (fewer joined catalogs per query, push pre-aggregations into Iceberg, or split the query into stages) rather than tuning execution-time limits.
- **Why federation queries hit this more often**: every JDBC catalog the planner touches triggers per-table metadata fetches and statistics queries (PgJDBC `pg_statistic` reads, MySQL `INFORMATION_SCHEMA` queries). A 7-way JOIN across `app_pg`, `billing_mysql`, and `iceberg.events` can spend 4–8 minutes just collecting stats before a single row is read. If your federated query "looks fast in the UI but takes minutes before showing any progress," planning time is the likely culprit.

#### Layer 3 — Resource group CPU / wall-time limits (`hardCpuLimit` / `softCpuLimit`)

- **What it controls**: per-resource-group cap on aggregate CPU time across all queries in the group, evaluated on a per-rolling-window basis (window length set by root-level `cpuQuotaPeriod`).
- **Default**: no limit (only fires if you configured it in `resource-groups.json`).
- **Configure**: in `etc/resource-groups.json`, add `"hardCpuLimit": "1h"` (hard cap — new queries refused admission once the rolling-window total CPU exceeds this) and `"softCpuLimit": "30m"` (soft cap — Trino throttles by reducing effective concurrency rather than rejecting queries outright).
- **When it fires**: the resource group's total CPU consumption (sum across all queries currently/recently in the group) exceeds the limit. Often used to prevent a single resource group from monopolizing the cluster.
- **Error**: query queued indefinitely with state `QUEUED` while waiting; ultimately cancelled with `Exceeded CPU limit of X`.

> **COMMON MISTAKE — `cpuLimit` is not a valid resource-group field.** Engineers frequently write `"cpuLimit": "1h"` based on intuition or stale blog posts. **There is no `cpuLimit` field in Trino resource groups.** The hard cap field is named **`hardCpuLimit`**; the soft cap is **`softCpuLimit`**. Trino silently ignores unknown JSON keys, so a typo like `cpuLimit` loads without error and provides ZERO protection. Always use `hardCpuLimit` for the hard cap and `softCpuLimit` for the soft cap, paired with a root-level `cpuQuotaPeriod` (e.g., `"cpuQuotaPeriod": "1h"`) that defines the rolling window length. See Section 5 of `05-multi-tenant-analytics.md` for the full resource-group JSON schema.

#### Layer 4 — Dynamic-filter wait-timeout (per-catalog `dynamic_filtering_wait_timeout`)

- **What it controls**: how long the probe-side scan waits for the build side to deliver a dynamic filter before launching the scan unfiltered.
- **Default**: **1 second for Iceberg / Hive / Delta**, **20 seconds for PostgreSQL / MySQL / SQL Server JDBC**. See the DF-defaults table in Section 5.4.
- **Configure in the per-catalog properties file**: for Iceberg, use the **prefixed** form `iceberg.dynamic-filtering.wait-timeout=15s` inside `etc/catalog/iceberg.properties` — the `iceberg.` prefix is REQUIRED for the Iceberg connector. (Bare `dynamic-filtering.wait-timeout=15s` is silently ignored by the Iceberg connector — no error, just no effect.) Hive uses `hive.dynamic-filtering.wait-timeout`; Delta uses `delta.dynamic-filtering.wait-timeout`. For PostgreSQL/MySQL JDBC catalogs, use the **bare** form `dynamic-filtering.wait-timeout=30s` (no `postgresql.` / `mysql.` prefix — JDBC connectors inherit this from JDBC base config).
- **Configure per session**: `SET SESSION <iceberg_catalog_name>.dynamic_filtering_wait_timeout = '15s'` (e.g., `SET SESSION iceberg_catalog.dynamic_filtering_wait_timeout = '15s'`). Catalog-prefixed (using the **catalog name** = filename in `etc/catalog/` without `.properties`), NOT system-level, and NOT the connector name `iceberg` (unless the catalog file is literally named `iceberg.properties`).
- **When it fires**: build-side scan didn't complete (and emit DF values) within the wait window.
- **CRITICAL — this is NOT a query killer.** When this timeout fires, the probe scan launches *without* the dynamic filter (which means it scans more rows than needed), but the query is not cancelled. The only symptom is "the query ran much slower than expected" and `dynamicFilterSplitsProcessed=0` in `EXPLAIN ANALYZE`. **Do NOT look for this layer if your query was cancelled — it does not cancel queries.**

#### Layer 5 — MySQL server-side statement timeout (`max_execution_time`)

- **What it controls**: per-statement cap enforced by the MySQL server. **MySQL ONLY** — does not apply to PostgreSQL (where the equivalent is `statement_timeout`).
- **Default**: **0 (unlimited)**.
- **Unit**: **MILLISECONDS** — same unit-confusion footgun as `socketTimeout`. To set a 5-minute MySQL statement timeout, use `300000`, not `300`.
- **Configure globally**: `SET GLOBAL max_execution_time = 300000;` (5 minutes) on the MySQL server.
- **Configure per session**: `SET SESSION max_execution_time = 300000;` from a MySQL client.
- **Configure per-statement**: `SELECT /*+ MAX_EXECUTION_TIME(300000) */ * FROM invoices WHERE ...` (optimizer hint — affects only the annotated query).
- **Scope**: **applies to SELECT statements ONLY.** INSERT / UPDATE / DELETE / MERGE / DDL are NOT bound by `max_execution_time` — there is no MySQL-side execution timeout for write statements. To bound write *lock wait* duration (so a Trino UPDATE that can't acquire a row lock fails fast instead of stalling indefinitely), use `SET GLOBAL innodb_lock_wait_timeout = 300;` (units: **seconds**, default 50s, error: `ERROR 1205 (HY000): Lock wait timeout exceeded`). For cancelling write statements that are *running* (not waiting on a lock), use `pt-kill` (Percona Toolkit) or a cron-driven `KILL QUERY <id>` against `INFORMATION_SCHEMA.PROCESSLIST`.
- **Error in MySQL**: `ERROR 3024 (HY000): Query execution was interrupted, maximum statement execution time exceeded`. Surfaces in Trino as a JDBC error from the connector.
- **PostgreSQL equivalent**: `statement_timeout` (per role or in `postgresql.conf`) — set in **milliseconds as a string** ("300000" or "5min"). Applies to all statements (not just SELECT).

#### Layer 6 — JDBC client socket timeouts (`socketTimeout`, `connectTimeout`)

- **What they control**: per-socket-read and connection-establishment timeouts at the JDBC driver layer inside Trino. The driver — not the DB server — gives up waiting for bytes.
- **Default**: **0 (unlimited — no timeout)** for both, on both MySQL Connector/J and PostgreSQL JDBC.
- **Unit — DIFFERENT FOR EACH DRIVER**:

| Driver | `socketTimeout` unit | `connectTimeout` unit |
|---|---|---|
| **MySQL Connector/J 8.x** | **MILLISECONDS** | **MILLISECONDS** |
| **PostgreSQL JDBC (pgjdbc)** | **SECONDS** | **SECONDS** |

  See the UNIT WARNING in Section 2A.1 — pasting `socketTimeout=60` (correct for pgjdbc = 60 seconds) into a MySQL JDBC URL gives you 60 *milliseconds*, which immediately kills every query.

- **Configure — WHERE this setting lives**: these are **JDBC URL query parameters appended to `connection-url`** inside the **per-catalog properties file on the Trino coordinator**, NOT in `etc/config.properties` and NOT a session property. The file is `etc/catalog/<catalog_name>.properties` on the coordinator (for the canonical `app_pg` catalog used throughout this resource, that file is `etc/catalog/app_pg.properties`). Example:

  ```properties
  # In etc/catalog/app_pg.properties on the Trino coordinator:
  connector.name=postgresql
  connection-url=jdbc:postgresql://replica.internal:5432/appdb?socketTimeout=60&connectTimeout=10
  connection-user=trino_reader
  connection-password=${ENV:PG_PASSWORD}
  ```

  For MySQL the equivalent file is `etc/catalog/<mysql_catalog_name>.properties` with `connector.name=mysql` and the MySQL Connector/J URL: `jdbc:mysql://replica:3306/db?socketTimeout=60000&connectTimeout=10000` (note milliseconds, not seconds). **See Section 2.4 for the complete catalog-properties-file layout, the full JDBC URL parameter table, and how to combine `socketTimeout` with `defaultRowFetchSize`, `prepareThreshold`, and SSL parameters in a single production-ready `connection-url`.** After editing the catalog file, the change takes effect either on coordinator restart, on `CREATE CATALOG ... USING ...` if dynamic catalog management is enabled (Section 2.8), or after dropping and re-adding the catalog via dynamic catalog management.
- **When it fires**: no bytes received on an active socket for the timeout window (often a hung backend, replication stall, or network blip).
- **Error in Trino**: `java.net.SocketTimeoutException: Read timed out`. The DB server may not have logged anything at all — the cancellation was client-side. (The connection is typically discarded, not returned to the pool.)

#### Layer 7 — MySQL server connection / network timeouts (`wait_timeout`, `net_read_timeout`, `net_write_timeout`)

- **What they control**: idle-connection and network-stall timeouts enforced by the MySQL server itself.
- **Defaults (MySQL)**:
  - `wait_timeout` = **28800 seconds (8 hours)** — maximum idle time before MySQL closes a non-interactive connection.
  - `net_read_timeout` = **30 seconds** — how long MySQL waits for the client to send the next packet during a query.
  - `net_write_timeout` = **60 seconds** — how long MySQL waits for the client to read the next packet of result data.
- **Configure**: `SET GLOBAL wait_timeout = 3600;` (1h) on MySQL. Persist in `my.cnf` for restart safety.
- **When they fire**: stale connections sitting in the JDBC connection pool past `wait_timeout` (MySQL closes the socket; the next use of the connection from Trino fails with `Communications link failure`); or genuinely slow client (rare for Trino, more common for misbehaving BI tools).
- **PostgreSQL equivalent**: `idle_in_transaction_session_timeout`, `tcp_keepalives_idle` (see Section 8.3 "Sixth layer" for the Postgres side).

#### Putting it together — the full chain, with typical production values

```
Layer                                          Default                  Typical prod setting
----------------------------------------------------------------------------------------------
1. Trino query.client.timeout                  5 min                    10 min
2. Trino query.max-run-time                    100 d                    15 min
   Trino query.max-execution-time              100 d                    10 min
2A. Trino query.max-planning-time              10 min                   15 min (federation)
3. Trino resource group hardCpuLimit           (no limit)               1h–4h
4. Trino dynamic_filtering_wait_timeout        1s (Iceberg) / 20s (JDBC) Iceberg raised to 15s for batch
5. MySQL max_execution_time                    0 (unlimited)            300000 (5 min, MILLIS, SELECT only)
   Postgres statement_timeout                  0 (unlimited)            '5min'
6. JDBC socketTimeout (MySQL Connector/J)      0 (unlimited)            60000 MILLIS
   JDBC socketTimeout (pgjdbc)                 0 (unlimited)            60 SECONDS
7. MySQL wait_timeout                          28800 s (8h)             3600 s (1h)
```

The general rule: **the innermost layer should fire first**. If the MySQL server cancels at 5 minutes, the JDBC socketTimeout at 60s of no data, and Trino's `query.max-execution-time` at 10 minutes — you get the cleanest behavior: MySQL cancels, the connection survives, and Trino's wrapping JDBC failure is graceful. If you reverse the order (Trino timeout fires before MySQL's), you orphan a still-running MySQL query that the replica will run to completion, wasting replica CPU.

> **WHERE each layer is configured — file-by-file quick reference** (single most-asked follow-up):
> | Layer | Configuration file on the Trino coordinator | Property form |
> |---|---|---|
> | 1. `query.client.timeout` | `etc/config.properties` | `query.client.timeout=10m` |
> | 2. `query.max-execution-time`, `query.max-run-time` | `etc/config.properties` (or per-session `SET SESSION`) | `query.max-execution-time=10m` |
> | 2A. `query.max-planning-time` | `etc/config.properties` (or per-session `SET SESSION query_max_planning_time = '15m'`) | `query.max-planning-time=15m` |
> | 3. Resource group `hardCpuLimit` / `softCpuLimit` | `etc/resource-groups.json` | JSON field inside a group definition |
> | 4. `dynamic-filtering.wait-timeout` | `etc/catalog/<catalog_name>.properties` (Iceberg/Hive/Delta: prefixed; JDBC: bare) | `iceberg.dynamic-filtering.wait-timeout=15s` |
> | 5. PG `statement_timeout` / MySQL `max_execution_time` | On the **database server** (or as `ALTER ROLE ... SET`) | DB-server config, NOT a Trino file |
> | 6. JDBC `socketTimeout`, `connectTimeout` | **`etc/catalog/<catalog_name>.properties` on the Trino coordinator** — appended as query parameters to `connection-url` | `connection-url=jdbc:postgresql://...?socketTimeout=60&connectTimeout=10` |
> | 7. MySQL `wait_timeout` etc. | On the **database server** (`my.cnf`) | DB-server config, NOT a Trino file |
>
> Layer 6 in particular trips engineers because they expect a `postgresql.socket-timeout` catalog property — there is no such property on OSS Trino 467. The setting lives **inside the JDBC URL** inside the **catalog properties file**. See Section 2.4 for the full catalog-file layout.

### 8.3B "Which timeout layer killed my query?" — diagnostic flowchart

When a federated query fails (or hangs) and you need to triage which layer is responsible, work through these checks **in order** — the layers are ordered from most-frequent culprit to least-frequent:

#### Step 1 — Check the query's final state in the Trino Web UI

Open `http://<trino-coordinator>:8080/ui/` (or your cluster's URL), find your query by ID, and look at the **state** badge:

| Final state | Meaning | Which layer? |
|---|---|---|
| `FINISHED` | Query completed successfully. If you think it "timed out," it actually completed — check the duration. | n/a (no timeout fired) |
| `FAILED` with `Query exceeded maximum time limit` | Trino's `query.max-execution-time` or `query.max-run-time` fired. | **Layer 2** |
| `FAILED` with `Query exceeded maximum planning time` | Trino's `query.max-planning-time` fired during the planning phase — query never started execution. Fix the plan, not the execution-time caps. | **Layer 2A** |
| `FAILED` with `Exceeded CPU limit` | Resource group `hardCpuLimit` exceeded (note: the field is `hardCpuLimit`, NOT `cpuLimit` — the latter is a common misnomer and does not exist). | **Layer 3** |
| `FAILED` with `Client has not requested any data` | Client polling timeout. The BI tool / app died. | **Layer 1** |
| `FAILED` with `java.net.SocketTimeoutException: Read timed out` | JDBC socketTimeout fired client-side. DB may still be running the query. | **Layer 6** |
| `FAILED` with `ERROR: canceling statement due to statement timeout` (PG) or `Query execution was interrupted, maximum statement execution time exceeded` (MySQL) | DB server killed the statement itself. | **Layer 5** |
| `FAILED` with `Communications link failure` (MySQL) or `connection has been closed` (PG) | Stale connection — the DB closed an idle pool connection. | **Layer 7** |
| `CANCELED` | Someone called `kill_query` or sent Ctrl-C in CLI. | (manual) |
| `RUNNING` (still!) and very slow | Likely DF wait-timeout fired and probe is scanning unfiltered. | **Layer 4** (but query is NOT cancelled — it's slow) |

#### Step 2 — Read the full error message in the UI

In the Trino UI, the "Query Details" page shows the **error stack** for FAILED queries. Look at the top-level message AND the cause chain — Trino's per-query-time error is short; the JDBC socket error includes a stack trace that names `java.net.SocketTimeoutException`; the MySQL/Postgres server cancellation surfaces the DB's verbatim error string somewhere in the cause chain.

#### Step 2.5 — Before re-running with EXPLAIN ANALYZE, check the Web UI Stages tab (free, no re-execution)

On the Trino Web UI query-detail page (`/ui/query.html?<query_id>`), the **Stages tab** gives you stage-level wall times from the **already-completed query** — no need to pay for an `EXPLAIN ANALYZE` re-execution just to see which stage dominated wall time. Each stage row shows total CPU time, wall time, input/output rows, and the operator type that lives in that stage. For triage-time questions like "is this slow because of the Postgres TableScan stage or the Iceberg fact scan stage?", scanning the Stages tab once is much faster than re-running a 30-minute query under `EXPLAIN ANALYZE`. Reach for the Stages tab first; only escalate to Step 3 (`EXPLAIN ANALYZE`) when you need per-operator runtime detail (DF wait time, `dynamicFilterSplitsProcessed`, Input→Output reductions) that the Stages tab does not surface.

> The Web UI Stages tab is the visual shortcut for the "wall of boxes" you'd otherwise have to read out of `EXPLAIN ANALYZE` text output. If the slow stage is obviously the Postgres TableScan stage (large wall time, large output rows), you may not even need `EXPLAIN ANALYZE` — jump straight to `pg_stat_activity` on the Postgres replica (Section 8.4) to see what SQL Trino actually sent. Use `EXPLAIN ANALYZE` when the Stages tab is ambiguous or when you specifically need `dynamicFilterSplitsProcessed` / DF wait time (which live in operator stats, not stage stats).

#### Step 3 — Run `EXPLAIN ANALYZE` to find stage-level wall time

For "the query was slow but not killed" cases (Layer 4 — DF wait fired but did not cancel), re-run the query with `EXPLAIN ANALYZE`:

```sql
EXPLAIN ANALYZE SELECT ...your query...;
```

Look at:
- **Stage-level wall time**: if the MySQL/Postgres TableScan stage ran for ~all the elapsed time, the DB is the bottleneck (predicate didn't push down, no DF applied, etc.).
- **`dynamicFilterSplitsProcessed`** on the probe-side scan: `0` with a `dynamicFilters = {...}` annotation in the plan = **Layer 4 DF wait-timeout fired**. Raise it.
- **Input vs Output rows** on each TableScan: if Input is full table size and Output is 1% of that, predicate pushdown didn't happen — the scan dragged the full table over JDBC.

#### Step 4 — Check the MySQL slow query log

If you see a JDBC socket error (Layer 6) but suspect MySQL actually received and ran the query, check the MySQL slow log:

```bash
# On the MySQL replica
tail -n 100 /var/log/mysql/mysql-slow.log
```

- **Query appears in slow log** with a long `Query_time` → MySQL received the query and was still processing it when the JDBC socket timed out. The MySQL query may still be running on the replica even though Trino has given up. Use `SHOW PROCESSLIST` to check (next step).
- **Query absent from slow log** → MySQL never received the query, or it completed faster than `long_query_time` (default 10s). The cancellation happened before MySQL got the work. Likely a JDBC connection-establishment problem or network blip.

#### Step 5 — `SHOW PROCESSLIST` on the MySQL replica

```sql
-- On the MySQL replica, as a user with PROCESS privilege:
SHOW PROCESSLIST;
-- Or filtered to the trino_reader role:
SELECT id, user, host, db, command, time, state, info
FROM information_schema.processlist
WHERE user = 'trino_reader';
```

- `Time` column shows seconds the query has been running.
- A query still active here, with `info` showing the SQL Trino sent, means MySQL is still processing it even though Trino's view says FAILED. **Manually KILL it on the MySQL side**: `KILL QUERY <id>;` — otherwise it will run to completion and waste replica resources.

#### Step 6 — If the user reported "the query hung but never errored"

Most common cause: the user gave up before any timeout fired. Defaults are very forgiving (100 days for `query.max-run-time`, unlimited for everything else). For "hang" complaints, the fix is usually to **set actual timeouts** (the typical-prod-settings column in the table above) so the query fails cleanly at a known boundary instead of running indefinitely. Without explicit timeouts, the query genuinely runs forever (or until the user manually cancels with `kill_query`).

### 8.4 Monitor what Trino is sending to Postgres

Four complementary views, each with a different retention window and a different vantage point. Use them in combination — the more recent and detailed views (Postgres `pg_stat_activity`, Trino `system.runtime.queries`) for live incident triage; the more durable views (OPA decision log, event listener output) for retrospective "what hit this catalog last week?" forensics.

#### A. From Postgres — `pg_stat_activity` (live, replica side)

```sql
SELECT pid, query_start, state, query
FROM pg_stat_activity
WHERE usename = 'trino_reader';
```

Shows the SQL Trino is currently running on the replica. Run this when investigating a slow federated query — you'll see the actual pushed-down SQL Postgres received. **Live-only**: rows disappear when the query finishes.

#### B. From Trino — `system.runtime.queries` (in-memory, last few minutes to hours)

> **`system.runtime.queries` — Actual Column Reference (Trino 467)**
>
> **This table has NO `catalog` or `schema` columns.** Using `WHERE catalog = '...'` or `WHERE schema = '...'` causes an immediate `Column 'catalog' cannot be resolved` error. This is a recurring trap because the columns *sound* like they should exist (the Trino Web UI surfaces catalog per query) — but the in-memory system table does not expose them. **Source of truth**: `QuerySystemTable.java` in the Trino codebase ([github.com/trinodb/trino](https://github.com/trinodb/trino/blob/master/core/trino-main/src/main/java/io/trino/connector/system/QuerySystemTable.java)).
>
> **Actual columns**:
>
> - `query_id` — unique query identifier (string like `20260526_143012_00042_abcde`)
> - `state` — `RUNNING`, `FINISHED`, `FAILED`, `CANCELED`
> - `"user"` — **must be double-quoted** (parser treats unquoted `user` as the `current_user` builtin, not as a column reference; you get the session user instead of the column value — a silent wrong-value bug). Quote it everywhere: `SELECT`, `WHERE`, `GROUP BY`, qualified as `q."user"`.
> - `source` — client source name (set via JDBC `?source=<name>` URL param or the `X-Trino-Source` HTTP header). Useful for "which dashboard / which BI tool ran this?" attribution.
> - `query` — the full SQL text submitted by the client
> - `resource_group_id` — which resource group ran the query. **TYPE GOTCHA**: this column is `array(varchar)`, **NOT a scalar string**. The value renders as a JSON-style array literal like `['federation', 'adhoc']` (one element per nesting level in the `rootGroups` tree), NOT as a bare string like `'federation'`. **Do NOT write `WHERE resource_group_id = 'federation'`** — that comparison fails with a type-mismatch error (`array(varchar)` vs `varchar`). To filter, use `contains(resource_group_id, 'federation')` or `cardinality(resource_group_id) > 0 AND resource_group_id[1] = 'federation'`. Easiest pattern: just `SELECT resource_group_id` and inspect the array literal in the output. Example:
>
>   ```sql
>   -- WRONG — type mismatch error
>   SELECT query_id FROM system.runtime.queries WHERE resource_group_id = 'federation';
>
>   -- RIGHT — array contains check
>   SELECT query_id, resource_group_id
>   FROM system.runtime.queries
>   WHERE contains(resource_group_id, 'federation')
>   ORDER BY created DESC LIMIT 20;
>   ```
> - `queued_time_ms`, `analysis_time_ms`, `planning_time_ms` — timing phases in milliseconds
> - `created`, `started`, `last_heartbeat`, `end` — timestamps (note: end column is literally `end`, not `completed_at`)
> - `error_type`, `error_code` — populated for `FAILED` queries
>
> **To find queries that touched a specific catalog**, you cannot filter on a `catalog` column — there is no such column. Instead, **search the SQL text**:
>
> ```sql
> SELECT query_id, "user", source, query, state, created, "end"
> FROM system.runtime.queries
> WHERE query LIKE '%app_pg%'
>   AND state = 'FINISHED'
> ORDER BY created DESC;
> ```
>
> **Caveat — `LIKE` matches can produce false positives.** A query like `SELECT * FROM iceberg.events WHERE source = 'app_pg_pipeline'` mentions the string `app_pg` in a column value, not as a catalog reference, and will match the filter spuriously. Same for queries that mention the catalog name only inside a SQL comment. **For production audit (low false-positive rate, durable, queryable past coordinator restarts), use the Trino event listener** (D below): the persisted `QueryCompletedEvent.metadata.catalog` field is catalog-keyed (not a text-search) and is the right answer for "which queries actually touched catalog X last week?"

To see all queries currently or recently touching the `app_pg` catalog, filter `system.runtime.queries` by SQL text:

```sql
-- Recent queries that referenced the app_pg catalog.
-- IMPORTANT: "user" must be DOUBLE-QUOTED — see the column reference above.
-- There is NO `catalog` column — use a LIKE on `query` to filter by catalog name.
SELECT query_id, "user", source, query, state, created, "end"
FROM system.runtime.queries
WHERE query LIKE '%app_pg%'
  AND state = 'FINISHED'
ORDER BY created DESC
LIMIT 50;
```

Also useful: the Trino UI (root path **`/ui/`** — the queries landing page; per-query detail is at `/ui/query.html?<query_id>`) per-query operator view shows the `TableScan` operator for the Postgres side with input rows (after pushdown) and elapsed wall time. If input rows is millions when you expected thousands, pushdown didn't happen. **The Web UI DOES surface catalog per query** even though the system table column does not — so for live triage by catalog, the UI is sometimes faster than the SQL view.

> **Note on `"user"` framing.** The column name on `system.runtime.queries` is `user`, but Trino's SQL parser interprets the **unquoted** identifier `user` as the `current_user` builtin in expression contexts. Writing `SELECT user FROM system.runtime.queries` does NOT error — it silently returns the session user (the caller running the SELECT) on every row, instead of the column. That is the actual failure mode: a wrong-value silent bug, not a syntax error. Per the Trino reserved-keyword table at [trino.io/docs/current/language/reserved.html](https://trino.io/docs/current/language/reserved.html), `USER` itself is non-reserved but `CURRENT_USER` is reserved — the behavior comes from `user` being treated as shorthand for `current_user`. **Always quote it as `"user"`** when selecting from `system.runtime.queries` to force column-name resolution. See also resource 18 for the same recipe.

**Retention caveat (the reason you also need C and D below):** `system.runtime.queries` is **in-memory and ephemeral** — queries are eligible for eviction once they exceed `query.min-expire-age` (default 15 min) AND when `query.max-history` (default 100) is exceeded — not strictly 15 minutes. The table is also wiped on every coordinator restart. For anything past the last few minutes to hours, it is gone. **You cannot use `system.runtime.queries` to answer "which queries hit app_pg last week?"** — the rows aren't there anymore.

#### C. OPA decision log (production stack option — captures every authz decision) — THE FIRST-LINE TOOL FOR "WHO TOUCHED app_pg LAST WEEK?"

> **TL;DR — for the question "who touched `app_pg` in the last week / month?" the OPA decision log is the correct answer on this stack — provided you have wired its output to a log shipper that persists to a durable backend. The decision log captures every authorization decision Trino made via OPA, but it is NOT durable by default; you must enable `decision_logs.console: true` (or a remote service sink) AND ship that stream to OpenSearch / Loki / ELK to make it queryable past the OPA pod's lifetime. You do NOT need to set up a Trino event listener first to answer the access-review question.**

The production stack uses **Open Policy Agent (OPA)** for Trino authorization. When configured, OPA logs **every policy evaluation** as a structured JSON record. Enable it in your OPA configuration (typically the OPA Helm chart values or `config.yaml`):

```yaml
# In OPA's config.yaml (or Helm values):
decision_logs:
  console: true   # writes a structured JSON decision record to OPA's stdout, one per evaluation
```

Each decision log entry contains:

- **Timestamp** of the evaluation
- **The full input document** — including:
  - `input.action` (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `CREATE_TABLE`, `ExecuteQuery`, etc.)
  - `input.resource` (catalog, schema, table, column being accessed — e.g., `app_pg`, `public`, `users`)
  - `input.context.identity` (user + groups — the Trino principal and their group membership)
- **Which policy rules fired** during evaluation and what each rule returned
- **The final allow/deny outcome**
- **Latency** of the policy evaluation (useful for spotting policy regressions that slow query planning — see the exact field name in the reference table below)

##### Decision log field reference — exact JSON paths

When you write OpenSearch DSL queries, Kibana filters, Loki LogQL queries, or Grafana alerts against the OPA decision log, reference fields by their **exact JSON path** in the decision-log line. The Trino OPA plugin nests `input.action.*` and `input.context.*`; OPA itself adds `decision_id` and `metrics.*` at the top level of each entry:

| Field | JSON path | Example value |
|---|---|---|
| Operation | `input.action.operation` | `"CreateCatalog"`, `"SelectFromColumns"` |
| Catalog being accessed | `input.action.resource.catalog.name` | `"app_pg"` |
| User (Trino principal) | `input.context.identity.user` | `"analyst-alice"` |
| Groups | `input.context.identity.groups` | `["engineers"]` |
| Query ID | `input.context.queryId` | `"20260526_120000_00001_xxxxx"` |
| Allow / deny | `result.allow` | `true` or `false` |
| Decision trace ID | `decision_id` | UUID string |
| Policy eval time (ns) | `metrics.timer_rego_query_eval_ns` | integer (nanoseconds) |

> **Note on the eval-time field name.** This guide sometimes uses `metrics.eval_ns` as a **shorthand**; the **actual key OPA writes** is `metrics.timer_rego_query_eval_ns`. When building a real dashboard or alert against the decision log, use the full name — the shorthand will not match. The shorthand exists only because the full name is long.

##### OPA operation names — audit-relevant subset

The Trino OPA plugin sends a fixed set of operation strings in `input.action.operation`. The full Trino 467 set is around 60 operation names (the complete list lives in `OpaAccessControl.java` in the Trino source); the table below is the **audit-relevant subset** — the operations you actually filter on in federation security dashboards. For "did anyone change a catalog?" or "who SELECTed from `app_pg`?" alerts, these eight are the ones to know:

| `input.action.operation` | What the user did in Trino |
|---|---|
| `CreateCatalog` | User ran `CREATE CATALOG` (dynamic catalog mode only — see Section 2.8) |
| `DropCatalog` | User ran `DROP CATALOG` |
| `AccessCatalog` | User's query touched a catalog (lightweight per-catalog pre-check that fires **before** any `SelectFromColumns` or table-level check — see the "AccessCatalog precedes SelectFromColumns" note below) |
| `GetRowFilters` | Trino asked OPA for any row-filter expressions to inject into the query against this table (per-principal RLS) |
| `SelectFromColumns` | User selected specific columns from a table (per-column access check — the operation that fires for every SELECT, against both the view object and each base table for DEFINER views) |
| `FilterCatalogs` | Query planner asked OPA "which catalogs is this user allowed to see?" (drives `SHOW CATALOGS`) |
| `FilterSchemas` | Query planner asked OPA "which schemas in this catalog can the user see?" (drives `SHOW SCHEMAS`) |
| `FilterTables` | Query planner asked OPA "which tables in this schema can the user see?" (drives `SHOW TABLES`) |
| `InsertIntoTable` | User ran `INSERT INTO` on a connector table |
| `ExecuteQuery` | Query execution started (one entry per query — useful as a join key against the event listener log) |
| `ImpersonateUser` | User tried to impersonate another identity (e.g., via `SET SESSION AUTHORIZATION`) — high-signal for audit |

> **These are the LITERAL operation strings.** Use them verbatim when you grep OPA decision logs, write OpenSearch filters, or build Grafana alerts. Engineers regularly miss decisions in their dashboards because they searched for "select" or "select_from_columns" instead of the literal SPI string `SelectFromColumns` (PascalCase, no underscores). The string Trino sends is the exact Java enum/method name from `OpaAccessControl.java` — case-sensitive, no spaces, no underscores. When this guide describes an OPA check informally (e.g., "the column access check"), the parenthetical names the literal SPI operation (`SelectFromColumns`) so you have a greppable string.

> **`AccessCatalog` precedes `SelectFromColumns` for every cross-catalog query — engineers searching for table-level entries will see catalog-level entries first.** For any SELECT that touches one or more catalogs (and especially for a cross-catalog join touching both `iceberg` and `app_pg`), Trino sends OPA **one `AccessCatalog` authorization request per catalog accessed**, ahead of the per-table `SelectFromColumns` requests. The `AccessCatalog` check only asks "is this principal allowed to access the catalog at all?" — it is a coarse-grained gate that fires once per catalog per query, regardless of how many tables in that catalog the query reads. The fine-grained per-table and per-column checks (`SelectFromColumns`, `GetRowFilters`, `FilterColumns`) follow it. When triaging "why was my query denied?" or building a decision-log dashboard:
>
> - **To find catalog-level decisions** (denies on the catalog gate, or "who accessed `app_pg` at all"): filter `input.action.operation = "AccessCatalog"`.
> - **To find per-table column-access decisions** (the SELECT-on-this-table check, the one most policies write rules against): filter `input.action.operation = "SelectFromColumns"`.
> - **To find row-filter injection decisions** (which row filter did OPA inject for this user × this table): filter `input.action.operation = "GetRowFilters"`.
>
> A single cross-catalog SELECT joining `iceberg.analytics.events` and `app_pg.public.users` produces (at minimum) **two `AccessCatalog` entries** (one for `iceberg`, one for `app_pg`), then **two `SelectFromColumns` entries** (one for each table), then **two `GetRowFilters` entries** (if row-filter policies are configured). Knowing the firing order saves time when reading raw decision logs — the first two entries for a federated query are almost always `AccessCatalog`, not `SelectFromColumns`.

Operations NOT in this subset (e.g., `ShowSchemas`, `ShowTables`, `CreateView`, `DropView`, `RenameTable`, etc.) still produce decision-log entries — filter on them when you need to — but the ones above are what matter most for routine federation security dashboards.

##### Durability — NOT automatic, requires external log shipping

**`decision_logs.console: true` writes to OPA's stdout — that is NOT durable on its own.** If the OPA pod restarts, the stdout buffer is gone. If you `kubectl logs` against the pod, you see only the recent retained portion (controlled by k8s log rotation, typically MB-scale per container, NOT weeks of history). **You must ship the stdout stream to an external sink to make it queryable past the OPA pod's lifetime:**

- **Fluentd / Fluent Bit / Vector sidecar** → ship to **OpenSearch** (queryable JSON via Kibana) or **Loki** (log-search via Grafana). This is the most common pattern on on-prem k8s; it reuses observability infra you likely already operate.
- **OPA remote `decision_logs.service` sink** → push decisions to a remote HTTP endpoint that persists them (your own collector, or an off-the-shelf SIEM). Set this in OPA config alongside or instead of `console: true`.
- **ELK pipeline** → Filebeat tailing the OPA container's stdout, shipping to Logstash → Elasticsearch.

```yaml
# Example OPA config — console output AND a remote service sink for durability:
decision_logs:
  console: true              # local stdout (for live tailing via kubectl logs)
  service: backend           # also push to a remote sink named "backend"
services:
  backend:
    url: https://opa-decisions.observability.svc.cluster.local/ingest
    # optionally with credentials, TLS, etc.
```

> **Do not describe the OPA decision log as "durable by default" — it is not.** Without external shipping, OPA decisions live only in container stdout and are subject to k8s log rotation, pod restarts, and the usual stdout retention limits (often just the last few MB). The decision log is durable only when you've put a shipper in front of it AND the downstream store retains long enough (30–90 days is typical for audit purposes). On THIS production stack, "the OPA decision log is queryable for the last 90 days" is true ONLY because the cluster operator wired Vector → OpenSearch (or equivalent) — verify your specific cluster has this wiring before assuming.

##### What the OPA decision log answers vs. what the Trino event listener answers

The two log streams are **complementary, not redundant**. They answer different questions:

- **OPA decision log** answers: **"WHO tried to access WHAT (catalog/schema/table/column) and was it ALLOWED?"** It captures the authorization decision — the input identity, the resource, allow/deny, and which rule fired. It does NOT include the full SQL text or runtime cost.
- **Trino query event log** (event listener — see section D below) answers: **"WHAT SQL ran and HOW EXPENSIVE was it?"** It captures the full query text, wall-clock time, bytes scanned, errors, peak memory. It does NOT include the OPA rule evaluation details.

For a complete audit trail of "who ran this expensive federation query at 2 AM and was it authorized," you need **both**. For an access review ("which users queried app_pg over the last 7 days?"), the OPA decision log alone is sufficient and is the easier of the two to query — provided the durability wiring above is in place.

##### Practical dashboards on this stack

Once the OPA decision log is shipped to OpenSearch/Loki, the high-value dashboards to build are:

- **Deny events on sensitive catalogs** — filter for `decision = deny` AND `input.resource.catalog IN (app_pg, billing, ...)`. Any deny attempt is either a misconfiguration (legitimate user got blocked) or a security incident (someone is probing what they shouldn't). Both warrant a Slack alert.
- **Catalog access patterns by user / group** — over the last 7 days, which users accessed `app_pg` and how often? Helps with capacity planning and access-review automation.
- **Policy evaluation latency** — if OPA decision latency creeps above 100 ms on a busy cluster, query planning slows down. Track p50/p95/p99 of `metrics.timer_rego_query_eval_ns` from each decision entry (this is the exact JSON key — `metrics.eval_ns` is shorthand and will not match in your log store; see the field reference table above).
- **Rule firing frequency** — which Rego rules fire most often? Hot rules are candidates for optimization (extract into a separate package, denormalize the data bundle, etc.).

**Example access-review query (OpenSearch)**: filter for `input.resource.catalog: "app_pg"` AND `input.resource.table: "users"` AND `input.action: "SelectFromColumns"` over the last 7 days — done. No Trino-side instrumentation needed for this question.

##### When OPA decision log is the best tool

Weekly access reviews, "who's using this federation catalog?" usage reports, post-incident "did this user query the OLTP replica before the incident?" forensics. It is the **first-line tool for durable federation auditing on this stack** — once you have the shipping wired up — because every authz decision Trino made is captured and the schema is uniform across all queries.

##### When it is NOT enough

It captures *authorization decisions* (catalog/schema/table/column accessed + allow/deny), NOT the **full SQL text** of every query, NOR the runtime cost/bytes-scanned. For "what was the SQL?" or "how many bytes did it scan?" forensics, fall through to D (Trino event listener) — those two log streams are complementary. The standard pattern is: **OPA decision log answers the "who and what catalog/table" questions; the Trino event listener answers the "what SQL and how expensive" questions.**

##### OPA decision logs are the AUTHORITATIVE audit trail — explicit summary

**OPA decision logs are the authoritative audit trail for federation query authorization on this stack.** Every OPA policy evaluation produces a structured log entry containing:

- **Timestamp** of the evaluation
- **The complete `input` document**:
  - `input.action` — the operation (SelectFromColumns / ExecuteQuery / CreateTable / etc.) and resource (catalog / schema / table / columns)
  - `input.context.identity` — username AND group memberships
- **Which Rego policy rules fired** and their intermediate values
- **The final allow or deny outcome**
- **Latency of the policy evaluation** (exact key: `metrics.timer_rego_query_eval_ns` — `metrics.eval_ns` is shorthand, the actual JSON key is the full name; see the field reference table above)

**Crucially: OPA decision logs are NOT durable by default.** `console: true` in OPA config writes to OPA's stdout. For durability, you MUST pipe stdout to a logging backend (Fluentd, Fluent Bit, Vector, Loki) OR configure a `decision_logs.service` remote sink:

```yaml
# OPA config
decision_logs:
  console: true   # writes to stdout — pipe to Fluentd/Loki/OpenSearch for persistence
  # OR / AND:
  service: backend
services:
  backend:
    url: https://opa-decisions.observability.svc.cluster.local/ingest
```

Without external shipping, decision records live only in the OPA container's stdout (subject to k8s log rotation, lost on pod restart) and are NOT queryable for week-or-longer audit windows.

##### Complementarity with Trino event listener logs — one-line each

- **OPA decision log answers**: *"WHO attempted to access WHAT catalog/table/column, and was it ALLOWED or DENIED?"*
- **Trino event listener log answers**: *"WHAT SQL ran, HOW LONG did it take, HOW MUCH data was scanned?"*

Together they give a complete SRE audit trail: **access decisions + query costs + outcomes**. Either alone leaves a gap.

##### Recommended dashboard — deny events on sensitive catalogs

The single highest-value alert on the OPA decision log is: **deny events on sensitive catalogs.** Build a Grafana/Kibana alert for any OPA `decision = deny` event whose `input.resource.catalog` is your internal Postgres catalog (`app_pg`, `billing`, `account`, anything holding tenant or financial data). Any deny attempt by a tenant or analyst principal targeting that catalog is either:

- **Misconfiguration** — a legitimate user got blocked, fix the policy or the request.
- **A security incident** — someone is probing what they shouldn't be able to access.

Either case warrants **immediate triage**. The deny-on-sensitive-catalog alert is the cheapest, highest-signal OPA decision log dashboard you can build on this stack.

##### Dynamic filter timeout events surface here too — correlation with the event listener

When a federation query's **dynamic filter times out** (the probe-side scan starts without the IN-list because `dynamic-filtering.wait-timeout` was hit), the symptom in the Trino event listener log is **an unusually slow cross-catalog join** — bytes-scanned and wall-clock-time both balloon, even though the SQL text and predicate shape are unchanged. Chronic timeouts on a specific federation query are a signal worth surfacing to SRE: it usually means the build side (e.g., the Postgres dimension scan) has become consistently too slow, which is itself an upstream issue (replica lag, Postgres planner regression, index loss).

**The correlation play**: when a Trino event-listener slow-query alert fires on a federation query, cross-reference it against the OPA decision log entry for that `query_id` (the event listener payload includes the query id; OPA logs include it too via Trino's correlation header). This lets you confirm:

1. The slowness was NOT caused by access-control overhead (OPA latency was normal).
2. The query WAS authorized (no deny events on the same path).
3. The slowness is therefore likely the dynamic-filter timeout / build-side slowness — go fix the Postgres replica's index or raise `<iceberg_catalog_name>.dynamic_filtering_wait_timeout` (the prefix is your actual Iceberg catalog filename, not the connector name) per Section 5.4.

Without the two log streams correlated, "this federation query got slow at 2 AM" turns into a multi-hour investigation. With them, the triage is minutes.

#### D. Trino HTTP event listener — durable query-completion events (on-prem k8s recommendation)

When you need durable, queryable history of **full query text, runtime, bytes scanned, error info** for every federation query (or every query, period), configure a **Trino event listener** to persist `QueryCompletedEvent` records. On this stack (on-prem Kubernetes, no managed cloud), the right choice is the **HTTP event listener** shipping to a local collector:

> **Persistent query monitoring on on-prem k8s**: Configure Trino's HTTP event listener to POST query completion events to a **Vector or Fluentd sidecar/Deployment**, then land them in **OpenSearch** (queryable JSON) or **Loki** (log-style search). This gives a queryable 30-day (or longer) history of every federation query. Config goes in `etc/event-listener.properties`:
>
> ```properties
> event-listener.name=http
> http-event-listener.connect-ingest-uri=http://vector-svc.observability.svc.cluster.local:8686/
> http-event-listener.log-completed=true
> http-event-listener.log-created=false
> ```
>
> Register the listener file in `etc/config.properties`:
> ```properties
> event-listener.config-files=etc/event-listener.properties
> ```
>
> The Vector/Fluentd sidecar parses the JSON event payload and ships it to OpenSearch or Loki, where you can query it with familiar log-search tools (`catalog:app_pg` filter, time-range slicer, etc.). See [trino.io/docs/current/admin/event-listeners.html](https://trino.io/docs/current/admin/event-listeners.html) and resource 18 (Section "CRITICAL — `system.runtime.*` is EPHEMERAL") for the full property reference including all four built-in listener plugins (HTTP, Kafka, MySQL, OpenLineage).

> **ANTI-PATTERN WARNING — `event-listener.type` does not exist**: The correct property is **`event-listener.name=http`** (or `=kafka`, `=mysql`, `=openlineage`). Writing `event-listener.type=http` **may cause catalog startup failure or be ignored depending on the connector version — verify by checking Trino coordinator logs after catalog reload**; the common failure mode is that Trino starts without error but never sends any events and your query history stays empty. If your event listener is not receiving events, check this property name first AND inspect the coordinator logs for "Unknown property" warnings. The pattern `event-listener.name=<plugin>` matches every other Trino plugin property (e.g., `access-control.name=opa`, `resource-groups.configuration-manager=file`).

**Alternative path for this stack**: if you already run Kafka, use the **Kafka event listener** (`event-listener.name=kafka`) to publish events to a topic and consume from there with a Spark Structured Streaming job that writes to an Iceberg observability table — then you can run normal Trino SQL against your own query history. This is a heavier operational investment than the HTTP-to-Vector route but gives you SQL-queryable history with all the usual Iceberg benefits (partition pruning, retention policies, time-travel).

**Do NOT** rely on the MySQL event listener as your primary durable store on this on-prem k8s stack — it works, but it adds an unrelated MySQL dependency where Vector→OpenSearch (or Vector→Loki) reuses observability infra you likely already operate.

#### Which monitoring tool for which question — quick decision table

| Question | Use this tool | Why |
|---|---|---|
| "What SQL is Trino running on the Postgres replica RIGHT NOW?" | Postgres `pg_stat_activity` (A) | Live view of the actual SQL Postgres received post-pushdown. |
| "Which queries are touching app_pg in the last 15 minutes?" | Trino `system.runtime.queries` (B) — remember `"user"` quoted | In-memory, includes full Trino SQL text and source/user. Ephemeral. |
| "Which users accessed app_pg over the last 7 days?" | OPA decision log (C) | Already running on this stack; durable; catalog-aware; ideal for access reviews. |
| "What was the full SQL and bytes-scanned of every federation query last month?" | Trino HTTP event listener → OpenSearch/Loki (D) | Durable history of full QueryCompletedEvent including cost metrics. Set this up once. |
| "How many federation queries failed with timeout in the last week, and what was the SQL?" | Trino event listener (D), filter by `errorCode` and `catalog` | OPA decision log captures the authz decision but not the runtime error; event listener captures both. |

#### D2. OPA batch endpoints — `opa.policy.batched-uri` and `opa.policy.batch-column-masking-uri`

> **Both batched URIs are OPT-IN performance optimizations. `opa.policy.batched-uri` LAYERS ON TOP OF the single-call `opa.policy.uri` (it covers filter-list ops only; non-filter ops still use the single endpoint). `opa.policy.batch-column-masking-uri` is a STRICT OVERRIDE of `opa.policy.column-masking-uri` — configure ONE OR THE OTHER for column masking, never both, because they are mutually exclusive (the batch URI replaces the per-column URI when set).** On a busy federation cluster, configure `batched-uri` plus the batch column-masking URI (NOT the per-column one); together they cut the per-query OPA round-trip count from O(tables × columns) down to O(1 per filter-op + 1 per masked table). For the deep policy-design discussion, see resource 05 section "OPA row-filter mode" and the "Broader batch endpoint" coverage there.

`opa.policy.batched-uri` handles **filter-list operations** — `FilterCatalogs`, `FilterSchemas`, `FilterTables`, `FilterColumns`, `FilterViews`. These are the operations where Trino has N candidate resources and asks OPA "which of these may the user see?" Without `batched-uri`, those N candidates are sent as N separate calls to `opa.policy.uri`. With `batched-uri`, they collapse into ONE call carrying an `action.filterResources` array of N entries, and OPA returns the **zero-based indices** of the permitted subset.

`opa.policy.batch-column-masking-uri` is the **batch counterpart to `opa.policy.column-masking-uri` — and it is a strict OVERRIDE, not an additive layer.** Per the [Trino OPA access control docs](https://trino.io/docs/current/security/opa-access-control.html): *"If `opa.policy.batch-column-masking-uri` is set it overrides the value of `opa.policy.column-masking-uri`."* The two are **mutually exclusive** — when `batch-column-masking-uri` is configured, Trino uses it for **all** column-masking operations and never calls `column-masking-uri`, even if `column-masking-uri` is also set in the properties file. There is **no fallback** from the batch URI to the per-column URI. Configure ONE; if you configure `batch-column-masking-uri`, the `column-masking-uri` line is silently ignored.

##### `opa.policy.batch-column-masking-uri` — input and output shapes

**Input shape**: `action.filterResources` array of `{catalogName, schemaName, tableName, columnName}` objects — one entry per column under consideration for masking on a single table. The Trino OPA plugin sends one batched request per table (not one per query), so a 40-column user table produces ONE request whose `filterResources` array has 40 column entries.

```json
{
  "input": {
    "action": {
      "operation": "GetColumnMask",
      "filterResources": [
        {"column": {"catalogName": "app_pg", "schemaName": "public", "tableName": "users", "columnName": "email"}},
        {"column": {"catalogName": "app_pg", "schemaName": "public", "tableName": "users", "columnName": "ssn"}},
        {"column": {"catalogName": "app_pg", "schemaName": "public", "tableName": "users", "columnName": "username"}}
      ]
    },
    "context": {
      "identity": {"user": "analyst-alice", "groups": ["analysts"]},
      "queryId": "20260526_142315_00042_xyz"
    }
  }
}
```

**Output shape**: an array of `{index, viewExpression}` objects — **SPARSE, indexed by position in the input `filterResources` array**. This is **consistent with the `filterResources`-in / indexed-output-out family pattern** used by `opa.policy.batched-uri` — it is NOT a divergent shape. Each element has:

- `index` — a **zero-based integer** referencing the position of the column in `action.filterResources` (the input array).
- `viewExpression` — the wrapper object whose `expression` field holds the **raw SQL** mask expression. Note the field name is `viewExpression`, NOT a bare `expression` at the top level.

**The response is SPARSE — OPA omits entries for columns that need no masking.** Just like `batched-uri` returns only the permitted indices (not a parallel array with `null` for excluded entries), `batch-column-masking-uri` returns only entries for columns that should be masked. **Missing an entry for an input column means "no masking applied" — that is correct, and is the intended way to express "this column is fine to read as-is."**

```json
[
  {"index": 0, "viewExpression": {"expression": "sha256(CAST(email AS VARCHAR))"}},
  {"index": 1, "viewExpression": {"expression": "CONCAT('***-**-', RIGHT(CAST(ssn AS VARCHAR), 4))"}}
]
```

> **Optional `identity` field on `viewExpression`:** `viewExpression` can optionally include an `identity` field — e.g., `{"expression": "sha256(CAST(email AS VARCHAR))", "identity": "admin"}`. When `identity` is set, Trino evaluates the mask expression as the specified user (useful for views that run as a different identity than the querying user — the mask body can then reference objects or run functions the querying user does not have direct privileges on). Most column-masking policies leave `identity` absent, in which case the mask is evaluated as the querying user. Set `identity` only when the mask expression itself needs elevated privileges to evaluate; for the common PII-hashing / partial-mask case shown above, omit it.

In the example above (for the three-column input `[email, ssn, username]`), OPA returned masks only for `index: 0` (email — hash it) and `index: 1` (ssn — partial mask with last 4 digits). **`index: 2` (username) is omitted entirely** — Trino interprets the missing entry as "no masking for this column" and reads `username` unmodified.

**The `expression` field is raw SQL evaluated in the column's row context** — there is no Mustache/`{{column}}` placeholder substitution. The expression references the column by its actual column name (`email`, `ssn`, etc.) as a SQL identifier, and Trino evaluates it per row at runtime. Use real Trino SQL functions and column references — `sha256(CAST(email AS VARCHAR))`, `CONCAT('***-**-', RIGHT(CAST(ssn AS VARCHAR), 4))`, `'REDACTED'` (a constant), etc. Do NOT write `sha256({{column}})` — that is not valid; Trino does not perform template substitution on the expression string.

##### Minimal correct Rego handler for `batch-column-masking-uri`

```rego
package trino

import future.keywords.contains
import future.keywords.if
import future.keywords.in

# Batch column masking handler — target of opa.policy.batch-column-masking-uri.
# Produces a SPARSE set: only emit an entry for columns that need masking.
# Missing index = no masking applied (correct).
result contains entry if {
    some i
    col := input.action.filterResources[i]
    is_pii_column(col.column.columnName)
    entry := {
        "index": i,
        "viewExpression": {
            "expression": "sha256(CAST(" || col.column.columnName || " AS VARCHAR))"
        }
    }
}

is_pii_column(name) if name in {"email", "ssn", "phone_number"}
```

Key points:

- **`result contains entry`** (set-based) is the correct Rego idiom here — NOT `result[i] := entry` (object-keyed). The OPA HTTP API serializes a set into a JSON array, which is exactly the shape Trino expects.
- **`"index": i`** is the position of the column in `input.action.filterResources` (the input array). Trino uses this to match the mask back to the corresponding input column.
- **`"viewExpression": {"expression": "..."}`** — the wrapper is `viewExpression` (not a bare `expression` at the top level), and its inner `expression` value is raw SQL. No `{{col}}` substitution — the expression directly references the column by name as a SQL identifier (we string-concatenate `col.column.columnName` into the SQL at policy-evaluation time, which is the standard way to build per-column expressions in Rego).
- **Missing an entry for a column = no masking applied.** The sparse response is correct and intended; do NOT emit `null`-valued entries to "pad out" the response.

##### Without `batch-column-masking-uri` — the per-column call explosion

If `batch-column-masking-uri` is NOT configured and `column-masking-uri` IS configured, Trino calls `opa.policy.column-masking-uri` **once per column of every referenced table** (not just the columns the query selects — see the issue #21359 note below). On a 40-column user table, that is 40 separate OPA HTTP calls per query that references the table — sequential, blocking, paid before query planning even completes. On a busy dashboard refreshing every 5 seconds for 200 users, this single missing flag turns into 16,000 OPA calls per second of pure overhead.

> **Note: per [Trino issue #21359](https://github.com/trinodb/trino/issues/21359), `column-masking-uri` is called for ALL columns of the referenced table at analysis time, NOT just the columns the query selects. A `SELECT id FROM users` query against a table with 30 columns still generates 30 OPA calls if `column-masking-uri` is configured. This makes wide tables especially expensive and is the primary motivation for `batch-column-masking-uri`** — the batch URI collapses those 30 per-column calls into a single batched request whose `filterResources` array contains all 30 column entries.

With `batch-column-masking-uri` configured, the same 40 columns become **one** OPA call per table (the `filterResources` array carries all 40 column candidates, and OPA returns a sparse list of only the masked ones). The OPA evaluation itself is cheap once batched — the win is eliminating 39 sequential HTTP round-trips, each of which would have added 1–20ms of network latency on a separate-service OPA deployment (less on a sidecar — see resource 05's pod placement section).

##### Configuration — pick the column-masking URI, configure both filter-list AND column-masking endpoints

```properties
access-control.name=opa
opa.policy.uri=http://opa-svc:8181/v1/data/trino/allow
opa.policy.batched-uri=http://opa-svc:8181/v1/data/trino/batchAllow                    # filter-list ops (FilterTables, FilterColumns, ...)
opa.policy.batch-column-masking-uri=http://opa-svc:8181/v1/data/trino/batchColumnMask  # per-table BATCH column masking — overrides per-column URI
opa.policy.row-filters-uri=http://opa-svc:8181/v1/data/trino/rowFilters
opa.policy.batch-row-filters-uri=http://opa-svc:8181/v1/data/trino/batchRowFilters     # multi-table BATCH row-filters — overrides row-filters-uri when set
# DO NOT also configure opa.policy.column-masking-uri — batch-column-masking-uri overrides it.
# If both are set, Trino silently uses ONLY the batch URI; the per-column URI is dead config.
```

##### `opa.policy.batch-row-filters-uri` — the batched variant of `row-filters-uri`

Parallel to the column-masking story (per-column URI vs batch URI), Trino's OPA plugin offers a **batched** row-filter endpoint. It is the row-filter analog of `batch-column-masking-uri`:

- **What it is**: the batched variant of `opa.policy.row-filters-uri`. Instead of one OPA HTTP call per table per query (the default `row-filters-uri` behavior), `batch-row-filters-uri` batches the row-filter requests for **all** tables touched by a single authorization phase into **one** OPA call.
- **Request shape**: the input to the batched endpoint includes a `filterResources` array (one entry per table being row-filter-checked). Each entry carries the catalog / schema / table identifiers OPA needs to evaluate the filter rule.
- **Response shape**: a map (sparse object) of per-table filter expressions. Tables that need no filter are omitted from the response; tables that need a filter return a `viewExpression` entry whose `expression` field carries the WHERE clause SQL.
- **When to use**: any production cluster with row filters configured across more than a handful of tables. A query that joins 5 tables produces 5 sequential `GetRowFilters` calls under the unbatched URI; under the batched URI, that collapses to one round-trip. On a cross-catalog dashboard query, the latency win is significant.
- **Precedence**: if `batch-row-filters-uri` is configured, **it takes precedence over `row-filters-uri`** for batch-capable operations — same strict-override behavior as `batch-column-masking-uri` over `column-masking-uri`. The unbatched URI becomes dead config when both are set; remove it to avoid confusion.
- **Rego handler shape**: mirrors the `batch-column-masking-uri` handler — iterate over `input.action.filterResources` with the `some i ... input.action.filterResources[i]` idiom, build a map keyed by index, return only entries that need a filter. See resource 05 for the full handler pattern.

Configure all three batch URIs (`batched-uri` for filter-list ops, `batch-column-masking-uri` for column masks, `batch-row-filters-uri` for row filters) on any production federation cluster. Together they reduce the per-query OPA round-trip count from O(tables × columns + tables) to O(1 per filter-op + 1 per masked table + 1 per row-filtered batch) — the difference between a dashboard refresh that adds 200ms of OPA overhead and one that adds 10ms.

`opa.policy.uri` is mandatory. `opa.policy.batched-uri` is an opt-in layer on top of it (covers filter-list ops only; non-filter ops still use the single endpoint). For column masking, pick **one** of `opa.policy.column-masking-uri` (per-column, expensive on wide tables) **or** `opa.policy.batch-column-masking-uri` (batch, recommended) — **not both**, because the batch URI overrides the per-column URI. In production, configure the batch URI.

##### How `batched-uri` and `batch-column-masking-uri` relate — different operation categories, different return contracts

It is easy to assume the two batch URIs are redundant or interchangeable. They are not — they cover different operations and have different return contracts, but both follow the same `filterResources`-in / indexed-output-out family pattern:

| URI | Operations covered | Input array element shape | Return contract |
|---|---|---|---|
| `opa.policy.batched-uri` | Filter-list ops: `FilterCatalogs`, `FilterSchemas`, `FilterTables`, `FilterColumns`, `FilterViews` | `{table: {...}}` (or `{schema: ...}`, `{catalog: ...}`, `{column: ...}` depending on the op) | **Sparse** array of zero-based **indices** of permitted candidates |
| `opa.policy.batch-column-masking-uri` | `GetColumnMask` for all columns on one table at a time | `{column: {catalogName, schemaName, tableName, columnName}}` | **Sparse** array of `{index: <int>, viewExpression: {expression: "<raw SQL>"}}` objects — omit entries for columns that need no masking |

You configure both URIs (filter-list AND batch column-masking) in production because they cover different operation categories. A common rollout sequence on a busy cluster: enable `batch-column-masking-uri` first (bigger latency win on wide tables — replaces `column-masking-uri`), then `batched-uri` (improves `SHOW SCHEMAS` / `SHOW TABLES` planning — adds onto `opa.policy.uri`), then re-measure dashboards to confirm the OPA analysis-phase tax has dropped.

> **For the full Rego handler patterns for both batch endpoints (the `some i ... input.action.filterResources[i]` idiom), see resource 05's "Minimal correct Rego batch handler" and "Parallel structure: `opa.policy.batch-column-masking-uri`" subsections.** Resource 22's role is the federation-runbook view; resource 05 carries the policy-design depth.

#### E. Three-way forensics workflow — Trino event listener + OPA decision log + Postgres `pg_stat_activity` — THE COMPLETE PATH FOR "WHY DID THIS FEDERATION QUERY RETURN THE WRONG DATA?"

> **For federation forensics — "the customer says rows are missing" or "the result is wrong for this query ID" — no single log surface tells the whole story. You need ALL THREE: (1) Trino event listener for the `queryCompleted` payload and error code, (2) OPA decision log for the authorization decisions made at analysis time, (3) Postgres `pg_stat_activity` (or the slow-query log) for the actual SQL Postgres received. The join key across all three is the Trino `queryId`. This subsection is the runbook.**

##### Why decision-log timing matters — OPA fires BEFORE any worker reads data

OPA decision log entries are written **at query analysis time**, before any worker reads data. That means:

- The OPA decision log entry exists **even if the coordinator crashes mid-execution** — the authorization decision was made and logged before the first split was dispatched.
- For a query that hits a permission denial, no `pg_stat_activity` record will ever appear (Postgres never receives the SQL — Trino refuses to plan it).
- For a query that succeeds at authorization but fails later (timeout, OOM, worker death), the OPA decision log still has the authorization record — you can definitively say "authorization passed" without ambiguity.

##### How many OPA decision log entries does ONE query produce?

A single Trino query against TWO tables (a typical Iceberg-fact × Postgres-dim cross-catalog join) produces **multiple** OPA decision log entries — not one. Plan for this when you grep:

- **One `SelectFromColumns` entry per table touched.** Two tables = two entries minimum. A join across `iceberg.analytics.events` and `app_pg.public.users` produces two `SelectFromColumns` entries, one per table.
- **One row-filter entry per table** if `opa.policy.row-filters-uri` is configured. So the same two-table join with row-filters configured produces two more entries (one `RowFilters` evaluation per table). Total so far: four entries.
- **Batched filter-list ops (`FilterTables`, `FilterSchemas`, `FilterCatalogs`, `FilterColumns`) produce one entry per batched call, not per candidate.** A `SHOW TABLES` on a schema with 50 visible tables and `opa.policy.batched-uri` configured emits ONE entry whose `input.action.filterResources` array contains all 50 candidates (and whose `result` is the indices array of permitted ones). Without `batched-uri`, the same `SHOW TABLES` emits 50 separate entries.
- **One `ExecuteQuery` entry per query** — useful as a top-level join key against the event listener log.

The practical implication: when you search OPA decision logs for `queryId = X`, expect to find **2 + N** entries on average for a two-table federation query, where N depends on whether row-filtering and column-masking are configured. Do not assume "one entry per query" — that assumption causes engineers to miss the row-filter or column-masking record they were looking for.

##### Enabling OPA's decision log (one-line requirement)

> **OPA's decision log must be enabled — set `decision_logs.console=true` in the OPA config or configure a remote decision log service endpoint (`decision_logs.service`).** Without one of these enabled, OPA evaluates policy but writes NOTHING to disk or stdout. The forensics workflow below assumes the decision log is on AND its stdout is being shipped to OpenSearch/Loki (see Section 8.4C for durability).

##### The two log SURFACES are distinct — do not conflate them

There are **two separate logging surfaces** that involve OPA in this stack. They live on different sides of the network and answer different questions:

| Log surface | Where it lives | What it captures | Where you turn it on |
|---|---|---|---|
| `opa.log-requests` | **Trino side** (the OPA plugin's HTTP client) | The raw HTTP **request body** Trino sent to OPA and the raw HTTP **response** OPA returned — useful for debugging "what did Trino actually ask OPA?" | In `etc/access-control.properties` on the Trino coordinator: `opa.log-requests=true` (also `opa.log-responses=true`) |
| OPA `decision_logs` | **OPA side** (the OPA process itself) | The structured **policy evaluation result** — full `input` document, which rules fired, intermediate values, allow/deny outcome, evaluation latency | In OPA's `config.yaml`: `decision_logs.console: true` and/or `decision_logs.service: <name>` |

**For forensics, you almost always want OPA `decision_logs`** — they carry the structured authorization decision in stable JSON, the `queryId` you can join on, and the user/groups/resource shape policy evaluators care about. `opa.log-requests` is a debugging tool for "Trino isn't sending OPA what I expected" — use it when you suspect the Trino-side plugin is misformatting the request, not for routine auditing.

##### The three-way forensics workflow — step by step

When a customer reports "my query returned the wrong data" or "data is missing from this result," run the following three steps in order. The join key across all three is **`queryId`** — pull it from the customer's complaint (UI shows it, or the API response carries `X-Trino-QueryID`) or from the event listener by `user` + time range.

**Step 1 — Trino event listener (`queryCompletedEvent`)**

Pull the `queryCompletedEvent` for the query by `queryId` (or by `user` + time range if you don't yet have the ID). The fields that matter for forensics:

- `queryId` — **use as join key into OPA logs and `pg_stat_activity` correlation**.
- `metadata.query` — the full SQL text the user submitted.
- `metadata.user` — the resolved Trino principal.
- `failureInfo.errorCode.name` — for OPA-denied queries this is `"PERMISSION_DENIED"` and OPA denied the whole query at analysis. For successful queries the `failureInfo` field is absent.
- `failureInfo.errorCode.type` — `"USER_ERROR"` for permission denials.
- `statistics.totalBytes` / `statistics.completedSplits` — runtime cost numbers; tell you whether the query actually executed or was killed before any work happened.

If `errorCode.name = "PERMISSION_DENIED"`, the data-missing story is "OPA denied the query at analysis." Skip to Step 2 to confirm which table was blocked. If the query succeeded but returned fewer rows than expected, the explanation is in Step 2 (row-filter injected) or Step 3 (predicate pushdown filtered the Postgres side).

**Step 2 — OPA decision log (authorization time)**

Filter the OPA decision log by `input.context.queryId = "<that queryId>"`. You will get **multiple entries** for one query (see "How many OPA decision log entries" above). For each entry, read:

- `input.action.operation` — `AccessCatalog`, `SelectFromColumns`, `FilterTables`, `GetRowFilters`, etc. (the literal SPI string from `OpaAccessControl.java`, PascalCase). Remember that for a cross-catalog query, the **first entries you see are `AccessCatalog`** (one per catalog), followed by the per-table `SelectFromColumns` entries — see the firing-order note in the OPA operations subsection.
- `input.action.resource.table.{catalogName, schemaName, tableName}` — **which table OPA was asked about**.
- `result.allow` (or `result` for batched calls returning indices) — `true` or `false`.
- If row-filter policies are configured AND the operation is `GetRowFilters` (the canonical SPI operation name in Trino 467's OPA plugin), the `result` field carries the **WHERE expression OPA injected** — e.g., `"tenant_id = 'acme'"`. This is the row filter that will be added to the query's SQL before pushdown decisions are made.

For the two-table cross-catalog join example, you should see entries like (in firing order):

- `AccessCatalog` on `iceberg` → `allow: true`
- `AccessCatalog` on `app_pg` → `allow: true`
- `SelectFromColumns` on `iceberg.analytics.events` → `allow: true`
- `SelectFromColumns` on `app_pg.public.users` → `allow: true`
- `GetRowFilters` on `iceberg.analytics.events` → `result: ["tenant_id = 'acme'"]` (if row-filters configured for this user)
- `GetRowFilters` on `app_pg.public.users` → `result: []` (no filter for this table)

**Step 3 — Postgres execution (`pg_stat_activity` or slow-query log)**

For the federated portion of the query, check the SQL that actually reached Postgres. Two ways:

- **Live**: `SELECT pid, usename, application_name, query, state FROM pg_stat_activity WHERE usename = 'trino_reader' AND state = 'active';` shows the JDBC query Trino is currently running on Postgres, with any WHERE clause pushed down. The `pid` field is the Postgres session identifier — use it for correlation against the Postgres logs if needed.
- **Post-mortem**: enable the Postgres slow-query log (`log_min_duration_statement = 100ms` on the replica) and grep it for the query text or the time window.

The Postgres SQL text shows you **exactly which predicates Trino pushed down** vs. which it had to evaluate on its own workers. If you expected `WHERE tenant_id = 'acme'` to push down but Postgres received an unfiltered `SELECT * FROM users`, you have a pushdown failure, not an authorization issue.

##### Decision table — what each combination of OPA + Postgres log evidence MEANS

Pin this table to your federation runbook. It is the single most useful artifact for triaging "the data is wrong" reports against federation queries:

| OPA log shows | Postgres log shows | Conclusion |
|---|---|---|
| `deny` | N/A (query blocked) | Data filtered at authorization time — OPA refused the query before Postgres ever saw it. The user got fewer rows (or zero rows / an `Access Denied` error) because policy denied a table or column. Fix: update the OPA policy or the user's group membership. |
| `allow` + row-filter injected | WHERE clause with filter | Policy worked, predicate pushed to Postgres. The filtered SQL ran server-side and Postgres returned only the permitted rows. This is the desired state. If the user complains they're seeing too few rows, the row filter is the cause — verify it matches their entitlement. |
| `allow` + row-filter injected | No WHERE clause | Policy worked but predicate not pushed — Trino filtered locally. Postgres fetched the whole table, Trino applied the `WHERE tenant_id = 'acme'` after the fact on workers. **Functionally correct, performance disaster.** Fix the pushdown gap (type mismatch, unsupported predicate shape, ILIKE on string range — see Section 3.3). |
| `allow` + no filter | Any | Authorization passed; data loss is elsewhere — check query logic (a `JOIN` that drops rows? a `LEFT JOIN` accidentally written as `INNER JOIN`?), Iceberg snapshot timing (the query resolved an older snapshot that didn't yet have the customer's rows), or Postgres replica lag (the read replica was behind primary at query time). OPA + Postgres logs are not the right tool — pivot to query-plan inspection (`EXPLAIN ANALYZE`) and Iceberg snapshot history (`SELECT * FROM iceberg.analytics."events$history"`). |

##### The join key — `input.context.queryId`

The single most important piece of this workflow is that **`input.context.queryId` in the OPA log matches `queryId` in the Trino event listener** and can be correlated to `pg_stat_activity` session via the SQL text and approximate timestamp. The Trino OPA plugin populates `input.context.queryId` on every authorization call, so every OPA decision-log entry is joinable to the event listener record for the same query. Without this join key, you would have to correlate by user + time window — error-prone on a busy cluster.

For Postgres-side correlation, `pg_stat_activity.pid` is the session ID and `pg_stat_activity.query` carries the SQL text. There is no Trino `queryId` field on the Postgres side (the JDBC connector does not propagate it), so the correlation is by SQL text + timestamp + the `trino_reader` username. For long-running queries, that is sufficient; for sub-second queries, the row may already be gone from `pg_stat_activity` (which is a live view), so the slow-query log is the better post-mortem source.

##### Worked end-to-end example — customer complains "my dashboard shows zero events"

1. Customer's request carries `X-Trino-QueryID: 20260526_142315_00042_xyz`. Pull the event listener entry for that ID.
2. Event listener shows `errorCode.name = "PERMISSION_DENIED"`, `failureInfo.message = "Access Denied: Cannot select from columns [...] in table or view iceberg.analytics.events"`. This is an OPA denial.
3. Filter OPA decision log by `input.context.queryId = "20260526_142315_00042_xyz"`. Find one `SelectFromColumns` entry on `iceberg.analytics.events` with `result.allow = false` and the rule trace showing the user's group did not include `analytics_readers`.
4. Conclusion: the customer's user is missing the `analytics_readers` group membership. Postgres logs show nothing (query never reached the federated catalog). Fix: add the user to the group via the auth service and have them retry. Total triage time: under five minutes — vs. the multi-hour investigation you would have run without the OPA decision log being queryable.

A second variant — customer complains "my report has one row, I expected one hundred":

1. Event listener shows `errorCode` absent (query succeeded), `statistics.outputRows = 1`.
2. OPA decision log shows `SelectFromColumns` on `app_pg.public.subscriptions` with `allow: true`, AND a `RowFilters` entry with `result: ["tenant_id = 'acme'"]`.
3. `pg_stat_activity` (or the slow-query log) shows the Postgres SQL Trino sent: `SELECT ... FROM subscriptions WHERE tenant_id = 'acme'` (the row filter pushed down successfully).
4. Conclusion: OPA correctly injected the tenant scope, Postgres correctly filtered to the customer's tenant — but the customer's tenant only has one matching row. The customer's expectation of 100 rows was wrong (maybe they're looking at the wrong tenant ID, or the data has not yet been ingested). Not an OPA bug, not a Trino bug, not a Postgres bug — a user-expectations bug. Five-minute triage instead of two days of "is OPA broken?"

### 8.5 Set a per-query Postgres timeout from the Trino side too

You can set a session-level statement timeout on the JDBC connection from Trino, but the simpler approach is to rely on Postgres `statement_timeout` plus Trino's own query timeouts. Belt-and-suspenders is fine — set all of them:

- Postgres `statement_timeout` (server-side, role-scoped — see Section 8.3's fifth layer)
- Trino `query.max-execution-time` cluster-wide (or `query_max_execution_time` per session) — caps active compute time only
- Trino `query.max-run-time` cluster-wide (or `query_max_run_time` per session) — caps total user-perceived time (includes queue wait, analysis, planning)

For the "user said the query hung" complaint, `query.max-run-time` is the most relevant lever — see the `query.max-run-time` vs `query.max-execution-time` subsection in Section 8.3 for the full distinction.

### 8.6 Don't expose Postgres credentials in catalog files

Always reference k8s Secrets via `${ENV:VAR}` in the catalog properties. Do not check secrets into Git. Rotate the `trino_reader` Postgres password on a schedule.

### 8.7 Grant only what's needed

The `trino_reader` Postgres role should have `CONNECT` on the database, `USAGE` on the relevant schemas, and `SELECT` on the relevant tables. No `INSERT`, no `UPDATE`, no `DELETE`. Defense in depth: even if Trino is misused, it can't modify operational data.

```sql
-- On the Postgres replica primary (the upstream of the replica):
CREATE ROLE trino_reader LOGIN PASSWORD '<strong-random>';
GRANT CONNECT ON DATABASE appdb TO trino_reader;
GRANT USAGE ON SCHEMA public TO trino_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO trino_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO trino_reader;
```

### 8.8 Graceful worker shutdown on Kubernetes — drain in-flight tasks before terminating pods

> **This matters most for password rotation via rolling restart, ConfigMap-driven catalog changes, and any planned k8s deployment rollout.** Without graceful shutdown, a `kubectl rollout restart` (or a node drain, or HPA scaling down) kills worker pods immediately — in-flight task assignments on those workers fail, often taking the parent query with them.

#### The mechanism — `SHUTTING_DOWN` state plus `preStop`

Trino workers expose an HTTP endpoint (`PUT /v1/info/state`) that puts the worker into `SHUTTING_DOWN` state. In this state:

1. The coordinator stops assigning new splits to that worker.
2. In-flight tasks on the worker drain to completion (or are reassigned).
3. Once tasks complete (or `shutdown.grace-period` elapses), the worker JVM exits cleanly.

The Kubernetes `preStop` lifecycle hook is the right place to trigger this — `preStop` runs before the SIGTERM that ends the pod's `terminationGracePeriodSeconds` countdown.

#### Worker Deployment manifest

```yaml
# In the Trino worker Deployment spec:
spec:
  template:
    spec:
      # MUST be > shutdown.grace-period below, plus a buffer.
      # 120s gives 60s grace + 60s headroom for the kill signal.
      terminationGracePeriodSeconds: 120
      containers:
        - name: trino
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - |
                    curl -s -X PUT -d '"SHUTTING_DOWN"' \
                      -H "Content-Type: application/json" \
                      http://localhost:8080/v1/info/state && \
                    sleep 60
```

#### Worker `etc/config.properties`

```properties
# Maximum time a worker waits for in-flight tasks to drain before exiting.
# Must be SHORTER than the pod's terminationGracePeriodSeconds.
shutdown.grace-period=60s
```

#### Coordinator restart is different — it kills everything

> **The coordinator does NOT have a graceful-shutdown story for in-flight queries.** When the coordinator pod restarts, **all in-flight queries are killed cluster-wide** — the coordinator holds query state, and there is no leader handoff in OSS Trino 467. For any planned coordinator restart (catalog ConfigMap update with `catalog.management=static`, JVM tuning change, Trino version upgrade), drain the user-query layer first: pause your scheduler / UI / API gateway, wait for in-flight queries to complete, then restart the coordinator. Or — for catalog changes specifically — use `catalog.management=dynamic` (Section 2.8) instead and avoid the coordinator restart entirely.

#### Recommended rolling-restart order for the cluster

If a rolling restart is unavoidable (e.g., a Trino version upgrade):

1. **Workers first**, with graceful shutdown configured as above. Roll them one at a time (or in small batches). Each worker drains its in-flight tasks before exit. The cluster keeps running with reduced capacity throughout.
2. **Coordinator last**, ideally during a low-traffic window. Accept that in-flight queries at this moment will be killed.

For password rotation specifically: prefer the **dynamic catalog management** path (Section 2.8) — DROP + CREATE via SQL — which avoids restarts entirely. Worker graceful shutdown is the right answer when you must roll pods for other reasons (image update, JVM heap change, node maintenance, etc.).

---

## 9. Common gotchas and how to handle them

### 9.1 "My query is slow even though Postgres has an index"

Almost always one of:

1. **Predicate didn't push down.** Verify with `EXPLAIN`. If it's a string range predicate, that's expected — switch to a different predicate or enable the experimental string-pushdown flag with caveats.
2. **Postgres pulled a full sequential scan** despite the index. Check `pg_stat_activity` for the actual query Trino sent; run `EXPLAIN ANALYZE` of that exact query in psql. Often the issue is collation, type cast, or statistics.
3. **PgBouncer or Postgres connection cap reached.** OSS Trino 467's PostgreSQL connector has no native pool (Section 0), so connection pressure shows up as PgBouncer queueing or `FATAL: too many connections for role "trino_reader"` from Postgres. Check `pg_stat_activity` against the role's `CONNECTION LIMIT`, check PgBouncer's `SHOW POOLS` for the **`cl_waiting`** column (the canonical PgBouncer column name for "client connections currently waiting for a server slot" — NOT `waiting_clients`, which does not exist in PgBouncer output), and consider lowering Trino's `hardConcurrencyLimit` in resource groups (Section 8.2C) or raising PgBouncer's `default_pool_size` if the replica can take it. **Do NOT** try to add `connection-pool.*` properties to the Trino catalog file — they **may cause catalog startup failure or be ignored depending on the connector version — verify by checking Trino coordinator logs after catalog reload**.

   Example PgBouncer health-check query (run via `psql -p 6432 pgbouncer` as a user listed in `admin_users`):

   ```sql
   -- Show per-pool stats; cl_waiting > 0 sustained = the pool is undersized for current Trino load.
   SHOW POOLS;
   -- Columns include: database, user, cl_active, cl_waiting, sv_active, sv_idle, sv_used, sv_tested, sv_login, maxwait.
   --   cl_waiting  = client connections currently waiting for a backend.
   --   cl_active   = client connections currently bound to a backend.
   --   maxwait     = how long (seconds) the oldest waiting client has waited.
   ```

   A reasonable Prometheus / alerting rule: alert when `cl_waiting > 0` for more than 60 seconds, or when `maxwait > 5` seconds — both indicate the pool is saturated and Trino queries are queueing on the connection side rather than executing.

### 9.2 "Cross-catalog join scans the entire Iceberg side"

Dynamic filtering didn't kick in. Either the build side is too big (over the default threshold) or Trino picked the wrong build side. Verify in the query UI's dynamic-filter section. Fix by tightening predicates on the small side so it stays small.

### 9.3 "I see UUID type mismatch errors"

Postgres `uuid` type maps to Trino's `UUID` type. Always cast literals: `WHERE tenant_id = UUID '11111111-2222-3333-4444-555555555555'` (note: in Trino syntax, that's `CAST('...' AS UUID)` or `UUID '...'`). Otherwise Trino treats the literal as a `VARCHAR` and pushdown breaks.

### 9.4 "JSONB columns and JSON filtering in federated queries"

The PostgreSQL connector maps both `json` and `jsonb` Postgres types to Trino's **`JSON`** type (not `VARCHAR`). This is confirmed in the official Trino PostgreSQL connector documentation.

**What works**: Trino's JSON functions (`json_extract_scalar()`, `json_extract()`, `json_array_length()`, etc.) operate on the `JSON` type and work correctly on JSONB-mapped columns:

```sql
-- Extract a specific key from a JSONB column (returns VARCHAR)
SELECT id, json_extract_scalar(metadata, '$.event_type') AS event_type
FROM app_pg.public.events;

-- Filter on a JSON key — works but does NOT push down to Postgres
SELECT * FROM app_pg.public.events
WHERE json_extract_scalar(metadata, '$.event_type') = 'user_login';
```

**Why predicates still don't push down**: Trino's `JSON` type does not support the ordering and equality operators that the JDBC connector requires for predicate pushdown (`DISABLE_PUSHDOWN` is applied to JSON-typed columns). This means even simple key-equality filters on JSONB columns **execute on Trino workers after fetching rows from Postgres** — so a `WHERE json_extract_scalar(...)` predicate on a 10M-row table causes a full table scan across JDBC.

**What you can't do in Trino SQL**: Postgres-native JSONB operators (`?`, `@>`, `->>`, `#>>`, etc.) are not part of the Trino language — they're Postgres extensions with no Trino equivalent. If you need to use those operators for server-side filtering:

```sql
-- Use system.query() to run native Postgres JSONB operators on the server
SELECT * FROM TABLE(app_pg.system.query(
  query => 'SELECT id, metadata FROM public.events WHERE metadata ? ''event_type'''
));
```

This sends the filter to Postgres, which executes it using its native JSONB index.

**For heavy JSONB analytics workloads**: ingest the Postgres table into Iceberg (via Spark/Iceberg CDC or full-refresh), denormalize the JSON into explicit columns, and query the Iceberg table. This avoids the JDBC scan problem entirely and benefits from columnar pruning and partition pushdown.

> **Common misconception**: "JSONB maps to VARCHAR in Trino." This was true in very early versions but is incorrect as of current Trino releases — the mapping is `jsonb` → Trino `JSON`. The JSON type is what enables `json_extract_scalar()` to work without an explicit cast. The pushdown limitation is not because the column is a string — it is because the `JSON` type does not support the comparison operators the JDBC pushdown mechanism requires.

### 9.4b PostgreSQL arrays, ENUMs, and unsupported types — complete type-mapping reference

Engineers frequently get confused about which Postgres types "just work," which require configuration, and which are silently dropped. Here is the authoritative breakdown for Trino 467:

| PostgreSQL type | Trino type | Default behavior | Configuration required? |
|---|---|---|---|
| `INTEGER`, `BIGINT`, `NUMERIC`, `TEXT`, `VARCHAR`, `BOOLEAN`, `DATE`, `UUID` | Native Trino equivalents | Works out of the box | None |
| `TIMESTAMP` (without TZ) | `TIMESTAMP(6)` (microsecond precision) | Works out of the box | None |
| `TIMESTAMPTZ` / `timestamp with time zone` | **`TIMESTAMP(6) WITH TIME ZONE`** (NOT plain `TIMESTAMP(6)` — the `WITH TIME ZONE` suffix is preserved) | Works out of the box; equality and range predicates push down | None |
| `jsonb`, `json` | Trino `JSON` | Works out of the box | None (see Section 9.4) |
| Custom **ENUM** types (e.g. `subscription_status`) | Trino `VARCHAR` | **Works out of the box — ENUM maps natively to VARCHAR, no config needed** | None |
| `TEXT[]`, `INTEGER[]`, `BIGINT[]`, `BOOLEAN[]` (1-D arrays) | Trino `ARRAY<VARCHAR>`, `ARRAY<INTEGER>`, `ARRAY<BIGINT>`, `ARRAY<BOOLEAN>` (element type is preserved — `INTEGER[]` does NOT widen to `ARRAY<BIGINT>`; only `BIGINT[]` produces `ARRAY<BIGINT>`) | **Silently omitted from results by default** (no error — columns just vanish from `SELECT *`) | Set `postgresql.array-mapping=AS_ARRAY` (typed elements) or `AS_JSON` (JSON string) in catalog file |
| Custom domains, geometric types (`POINT`, `POLYGON`, `BOX`), range types | Skipped by default (`IGNORE`) | Silently omitted | Set `postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR` to read as text strings |
| Multi-dimensional arrays (e.g. `INTEGER[][]`) | Cannot map to Trino `ARRAY<T>` (which is flat) | Silently dropped under default `DISABLED`; errors under `AS_ARRAY` because the flat ARRAY type can't represent the nested structure | **Set `postgresql.array-mapping=AS_JSON`** — the multi-dim array comes through as a Trino JSON column (e.g. `[[1,2],[3,4]]`). Parse with `json_extract` / `cast(... AS ARRAY<ARRAY<INTEGER>>)` on the Trino side. Alternative: `system.query()` with Postgres-side `unnest()` to flatten server-side. |

> **CRITICAL: ENUM ≠ unsupported type.** A common mistake: engineers see "weird string values" when querying ENUM columns and assume the ENUM is being handled by `unsupported_type_handling`. In fact, **PostgreSQL ENUM types map natively to Trino `VARCHAR`** — the text label (`'active'`, `'past_due'`, etc.) comes through as a VARCHAR string automatically. The `unsupported_type_handling` setting does NOT apply to ENUMs. If you see the ENUM value as a string, that is the correct behavior.

**Catalog file property vs. session property — these are different names:**

```properties
# In etc/catalog/app_pg.properties (requires coordinator restart):
postgresql.array-mapping=AS_ARRAY
postgresql.unsupported-type-handling=CONVERT_TO_VARCHAR
```

```sql
-- Per-session (no restart needed, underscores, no prefix in property name):
SET SESSION app_pg.array_mapping = 'AS_ARRAY';
SET SESSION app_pg.unsupported_type_handling = 'CONVERT_TO_VARCHAR';
```

The catalog file property uses the `postgresql.` prefix and hyphens (`postgresql.array-mapping`). The session property uses the `<catalog>.` prefix and underscores (`app_pg.array_mapping`). They control the same behavior but have different names depending on context.

**Diagnosing "missing columns" vs. "weird values" in federated Postgres queries:**

- **Column vanishes from `SELECT *` with no error** → Array column with default `DISABLED` mapping, OR genuinely unsupported type with `IGNORE`. Fix: enable `AS_ARRAY` for arrays, or `CONVERT_TO_VARCHAR` for unsupported types.
- **"Column not found" error when referencing by name** → Trino never saw the column in its schema (same cause as above — column was dropped during schema inference).
- **Column appears as a VARCHAR string** → ENUM (this is correct behavior) or a type mapped via `CONVERT_TO_VARCHAR`. The text label is the intended value.
- **JSONB column appears but filters don't push down** → Expected behavior; JSONB predicates evaluate on Trino workers. Use `system.query()` for server-side JSONB filtering (see Section 9.4).

### 9.5 "I want to write back to Postgres" — what works, what's limited, and what you should actually do

The Trino 467 PostgreSQL connector supports `INSERT`, `UPDATE`, `DELETE`, `CREATE TABLE`, `CREATE TABLE AS SELECT (CTAS)`, and `DROP TABLE`. **You can write — but you should not, on a live OLTP database.** The federation connector is intended for read traffic. Writing from Trino into your operational DB bypasses application logic, validation, and audit. Use the application's normal write path.

That said, you (or a teammate) will eventually try a write through Trino — for an audit log table, an ops-only utility table, or a "quick fix." Know the limitations before you do:

#### INSERT — temporary-table-then-rename by default; flag exists to bypass

**INSERT behavior**: By default, the PostgreSQL connector uses a temporary-table-then-rename approach for `INSERT` to protect against partial failures. Trino writes the new rows into a temporary table on Postgres, and only on successful completion of the entire INSERT does it rename the temporary table into the target (or otherwise atomically attach the rows). This adds latency for large inserts — proportional to the rename / data-movement cost on the Postgres side — but it means a failed INSERT leaves no partially-inserted rows behind.

To bypass this safety mechanism: set `insert.non-transactional-insert.enabled=true` in your catalog properties file:

```properties
# In etc/catalog/app_pg.properties — DANGEROUS, see warning below:
insert.non-transactional-insert.enabled=true
```

With this flag, Trino writes rows directly to the target table without the temporary-table indirection. Inserts are faster (no rename step), but:

> **WARNING**: with `insert.non-transactional-insert.enabled=true`, **a failed INSERT may leave orphan rows in the target table** — partially-completed batches are NOT rolled back. Use this flag ONLY for **append-only workloads where deduplication is handled downstream** (e.g., the consumer reads with `SELECT DISTINCT ON (...)` or uses an idempotency key to filter duplicates). For any workload where partial inserts would corrupt downstream analytics, leave the flag at its default (`false`) and accept the rename overhead.

#### Cross-catalog INSERT write-back — the canonical recipe (Iceberg → Postgres)

The most useful pattern for federated writes is **computing in Iceberg and writing the result back to Postgres in a single statement**. This is supported in OSS Trino 467 — both source and target catalogs participate, with the SELECT executing on Trino workers and the rows landing in the Postgres target via the connector's INSERT path.

```sql
-- Cross-catalog INSERT write-back (supported in OSS Trino 467):
INSERT INTO postgres_catalog.reporting.summary
SELECT
  account_id,
  COUNT(*) AS event_count,
  MAX(occurred_at) AS last_event_at
FROM iceberg_catalog.analytics.user_events
JOIN postgres_catalog.public.accounts ON user_events.account_id = accounts.id
WHERE occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY account_id;
```

**Key notes — read before copy-pasting into production:**

- **Default behavior is atomic.** Trino uses a temp-table + rename pattern internally: either all rows are written or none — **no partial writes on failure**. A query that fails mid-write leaves the target table untouched. This is the right default for any cross-catalog write whose downstream consumer cannot tolerate orphan rows.
- **`insert.non-transactional-insert.enabled=true`** (catalog property, in `etc/catalog/postgres_catalog.properties`) bypasses the temp-table pattern for **faster bulk loads**, but **allows partial writes if the query fails** — only use for **idempotent bulk loads** where re-running the same INSERT on the same source produces the same final state (e.g., the target has a unique key and you handle duplicate rejection downstream, or the workload is genuinely append-only and partial duplicates are filtered with a `SELECT DISTINCT ON (...)` reader pattern).
- **`non_transactional_insert`** is the matching session property (note: **no `_enabled` suffix** on the INSERT form — this differs from the MERGE form which IS `non_transactional_merge_enabled`). Per-session override example:
  ```sql
  SET SESSION postgres_catalog.non_transactional_insert = true;
  INSERT INTO postgres_catalog.reporting.summary SELECT ...;
  ```
- **MERGE is NOT available in Trino 467 for the PostgreSQL connector** (added in Release 470, February 5, 2025). If your write-back needs upsert semantics (insert-or-update-by-primary-key) against an existing target, you cannot use `MERGE INTO postgres_catalog....` on this stack. Use the INSERT + UPDATE two-statement workaround below (subject to the constant-assignment UPDATE limitation), or push the upsert through the application layer with PostgreSQL's native `INSERT ... ON CONFLICT (pk) DO UPDATE`.
- **OPA may deny this entire pattern.** Per Section 9.5's OPA note below, the default policy on this stack denies DML against the `app_pg` / `postgres_catalog` catalog to all roles except a dedicated writer service principal. Confirm your session is authenticated as a principal allowed to write before assuming a failure is a connector bug.
- **Use a dedicated reporting schema / writer role, not the OLTP app's read replica.** Cross-catalog write-back should target a **reporting database** (or at minimum a separate schema with a dedicated writer role) — not the live OLTP database the application reads from. Even a transactional INSERT competes for table locks, WAL bandwidth, and connection slots that the OLTP app needs.

#### UPDATE — only constant assignments are supported

Trino 467's PostgreSQL connector supports `UPDATE`, **but with a sharp limitation**: the `SET` expression must be a **constant assignment only**. You **cannot** reference the column being updated, another column, or any expression on the right-hand side of `SET`.

```sql
-- WORKS — constant literal assignments:
UPDATE app_pg.public.users SET status = 'inactive' WHERE id = 42;
UPDATE app_pg.public.users SET score = 0.95 WHERE id = 42;
UPDATE app_pg.public.users SET updated_at = TIMESTAMP '2026-05-26 00:00:00' WHERE id = 42;

-- FAILS — expression referencing the column itself:
UPDATE app_pg.public.users SET event_count = event_count + 1 WHERE id = 42;

-- FAILS — expression referencing another column:
UPDATE app_pg.public.users SET display_name = full_name WHERE id = 42;

-- FAILS — function call in SET:
UPDATE app_pg.public.users SET email = LOWER(email) WHERE id = 42;
```

If you need an expression-based UPDATE, run it directly in Postgres (psql / your app), not through Trino. There is no workaround at the Trino layer; the connector simply does not push expression-based SET clauses down.

#### DELETE — works, but only with predicates Trino can push down

`DELETE FROM app_pg.public.foo WHERE ...` is supported, but the `WHERE` predicate must be one Trino can push down to Postgres (the same predicate-pushdown rules as Section 3 apply). DELETE works best with **simple predicates on indexed columns** — e.g., `DELETE ... WHERE id = 42`, `DELETE ... WHERE tenant_id = '...' AND created_at < TIMESTAMP '...'`. Complex WHERE clauses involving subqueries, cross-catalog references, or non-pushdownable predicates may fail outright or produce surprising behavior. If in doubt, run the equivalent `SELECT ... WHERE <same predicate>` first and verify the row count matches expectations, then run the `DELETE`.

#### MERGE — **NOT supported on PostgreSQL in Trino 467** (version-gated; see Section 2A.8 for the full matrix)

> **MERGE on PostgreSQL connector was added in Trino Release 470** (February 5, 2025). In Trino 467 (this production stack), MERGE is NOT available for PostgreSQL tables. Alternatives in Trino 467: use separate INSERT + UPDATE statements, or push upsert logic to the application layer using PostgreSQL's native `INSERT ... ON CONFLICT (pk) DO UPDATE` syntax.

> **PostgreSQL MERGE is NOT available in the Trino 467 PostgreSQL connector** (the version this stack runs). Attempting `MERGE INTO app_pg.<schema>.<tbl> ...` throws an **unsupported-operation error at planning time** — the connector did not implement the row-level-operations interface for MERGE until **Trino 470** (PR #24467, merged Feb 5, 2025). **Do not claim that PostgreSQL MERGE "works by default — transactional, safe"** — that statement is wrong for THIS stack and is wrong even for Trino 470–474 (where MERGE landed but required the same `merge.non-transactional-merge.enabled=true` flag as MySQL, with non-transactional semantics). Transactional PostgreSQL MERGE only arrived in **Trino 475+**.
>
> **What this means for Trino 467 users:** if you need upsert (insert-or-update) semantics against a PostgreSQL table from Trino, you have three options, in preference order:
>
> 1. **Do the upsert in the application, not in Trino.** PostgreSQL's native `INSERT ... ON CONFLICT (pk) DO UPDATE` syntax (the canonical Postgres upsert) is available through the application's normal database connection with full transactional semantics. Use Trino to *compute* the source rows; use the app to *write* them. This is almost always the right answer.
> 2. **Two-statement INSERT + UPDATE through Trino.** Run an `INSERT ... WHERE NOT EXISTS (SELECT 1 FROM target WHERE pk = source.pk)` to add new rows, then a separate `UPDATE` for the existing matches. Each statement has the constant-assignment limitation on UPDATE (above — no expression-based SET), and there is no cross-statement transactional atomicity (each split commits independently). Re-runnable / idempotent.
>
>    **Self-contained INSERT ... WHERE NOT EXISTS example (copy-pasteable — Iceberg-computed billing snapshots → MySQL target):**
>
>    ```sql
>    -- Step 1: INSERT only the rows that don't already exist in the target.
>    -- The source subquery is named `s` so the WHERE NOT EXISTS clause can
>    -- reference its columns unambiguously. Without the explicit subquery
>    -- alias, `source.column_name` would be undefined.
>    INSERT INTO mysql_catalog.db.billing_snapshots
>    SELECT s.customer_id, s.summary_date, s.total_events
>    FROM (
>        SELECT customer_id,
>               DATE_TRUNC('day', NOW()) AS summary_date,
>               COUNT(*) AS total_events
>        FROM iceberg_catalog.analytics.events
>        WHERE DATE_TRUNC('day', occurred_at) = DATE_TRUNC('day', NOW())
>        GROUP BY customer_id
>    ) AS s
>    WHERE NOT EXISTS (
>        SELECT 1 FROM mysql_catalog.db.billing_snapshots b
>        WHERE b.customer_id = s.customer_id
>          AND b.summary_date = s.summary_date
>    );
>
>    -- Step 2: UPDATE the rows that DID already exist with the freshly
>    -- computed values. Note the constant-assignment limitation — you cannot
>    -- write `SET total_events = total_events + s.delta` in the UPDATE here.
>    -- For non-constant updates, run the UPDATE through the application's
>    -- direct MySQL/Postgres connection instead.
>    UPDATE mysql_catalog.db.billing_snapshots
>    SET total_events = 12345  -- constant value computed by the caller
>    WHERE customer_id = 42
>      AND summary_date = DATE '2026-05-27';
>    ```
>
>    **Why the subquery alias matters:** `WHERE NOT EXISTS (SELECT 1 FROM target WHERE target.pk = source.pk)` only works if `source` is a defined name in the outer query. If you write the INSERT without the explicit `AS s` alias on a subquery (or without a CTE), `source.pk` is undefined and the query fails at planning. Always either (a) wrap the source in `(SELECT ...) AS s` and reference `s.pk`, or (b) use a `WITH source AS (...)` CTE at the top and reference `source.pk`. Pick one and stay consistent within a query.
>
> 3. **Snapshot-and-replace via Iceberg staging.** Materialize the entire target slice in Iceberg, write it back to a fresh Postgres staging table via CTAS, and have the application swap the staging table for the live one inside a Postgres `BEGIN ... COMMIT` block.
>
> **Do NOT** try to enable `merge.non-transactional-merge.enabled=true` on `app_pg.properties` in Trino 467 — the property **may cause catalog startup failure or be ignored depending on the connector version — verify by checking Trino coordinator logs after catalog reload** (the connector does not recognize it until 470), and even when the catalog reloads MERGE still throws the unsupported-operation error. The flag is a 470+ feature for PostgreSQL.

#### Transactional atomicity — UPDATE/DELETE are NOT wrapped in a single user-controlled Postgres transaction

> **Transactional atomicity**: Trino `UPDATE` / `DELETE` through the PostgreSQL connector is **NOT wrapped in a single user-controlled Postgres transaction**. Each split (or the single JDBC split, for non-partitioned tables — see Section 4.4) executes its own JDBC statement against Postgres. If the Trino coordinator crashes, a worker fails, or the network drops mid-execution, the target table may be left in a **partially-updated (or partially-deleted) state** with no automatic rollback to the pre-statement snapshot.
>
> Concretely: a `DELETE FROM app_pg.public.foo WHERE tenant_id = '...'` that should remove 10,000 rows might delete the first 6,500 successfully, then fail. Postgres committed each batch as it ran; the remaining 3,500 rows stay. Re-running the DELETE finishes the job, but the in-between window is observable to other readers and is not undone automatically.
>
> **For multi-row updates where atomicity is required, execute the UPDATE directly through your application's Postgres connection** (via the app's normal ORM / connection pool inside a `BEGIN ... COMMIT` block), NOT through Trino. The Trino federation connector is designed for analytical reads — it does not provide the cross-statement transactional guarantees that a direct Postgres client (psql, libpq, JDBC under your own control) gives you.
>
> If you must run a bulk mutation via Trino for ergonomic reasons, restrict it to **idempotent operations** (e.g., `UPDATE ... SET status = 'inactive' WHERE id = 42` is safe to re-run; `UPDATE ... SET balance = balance + 100` is NOT — and the Trino connector rejects it anyway per the constant-assignment rule above). Idempotence is your only safety net when partial failure can happen.

#### OPA can (and in this stack, probably should) deny writes at the policy layer

The production stack uses **Open Policy Agent (OPA)** for Trino authorization. OPA can be configured to **deny all DML (`INSERT` / `UPDATE` / `DELETE` / `MERGE` / `CREATE TABLE` / `DROP TABLE`) against the `app_pg` catalog** at the policy level, even if the connector technically supports them. This is a defense-in-depth control that prevents accidental or unauthorized writes through Trino even if someone has the underlying Postgres `GRANT`.

**Before attempting any write through the connector, check the cluster's OPA policy** — if a write-deny rule is in place on the `app_pg` catalog, your `INSERT` / `UPDATE` / `DELETE` / `CTAS` will be rejected at the Trino layer before it ever reaches Postgres, with an authorization error rather than a connector error. This is the intended, recommended posture for a federated OLTP read replica.

In this stack, the conventional policy is: `iceberg.*` catalog is read-write to ETL roles, `app_pg.*` catalog is **read-only to all roles** (including admins), with writes only allowed via the application's own connection pool to Postgres. Confirm the active OPA rules before debugging "why doesn't my write work?" — the answer is usually "policy is denying it on purpose."

#### Cross-catalog CTAS: writing Postgres data into Iceberg — and HMS's role

A common federation pattern is to **materialize a Postgres table (or a filtered slice of one) into Iceberg** for repeated analytical use. The syntax is straightforward:

```sql
-- CTAS from Postgres into Iceberg:
CREATE TABLE iceberg.analytics.users_snapshot
WITH (
    partitioning = ARRAY['bucket(tenant_id, 16)'],
    format = 'PARQUET'
) AS
SELECT id, tenant_id, email, plan, status, created_at
FROM app_pg.public.users
WHERE plan IN ('enterprise', 'pro');
```

This reads from Postgres (with predicate pushdown for the `WHERE plan IN (...)`) and writes the result as a new Iceberg table backed by Parquet files on MinIO, with metadata registered in **Hive Metastore (HMS)**.

**HMS is involved at BOTH key moments of the CTAS lifecycle — not just at commit time:**

1. **At query start (before the SELECT runs).** HMS is called to register the new Iceberg table (or to check that the table name does not already exist). If HMS is down at this point, **CTAS fails immediately** before Trino reads even one row from Postgres. No data files are written to MinIO; no orphans are created. The query just errors out.

2. **At commit (after the SELECT completes and Parquet files are written to MinIO).** HMS performs the **atomic metadata pointer swap** — it updates the table's `metadata_location` to point at the new metadata JSON file in MinIO. This is what makes the new table visible to readers. If HMS goes down **mid-query after the table was already registered at step 1 but before the commit at step 2**, the SELECT may complete and Parquet files may be flushed to MinIO, but the **commit fails** — leaving **orphan data files in MinIO** with no metadata pointer to them. These orphans take up storage but are invisible to queries; they have to be cleaned up via the Iceberg `remove_orphan_files` procedure (see resource 17 on Iceberg maintenance for full details). In Trino 467, the correct syntax is:

```sql
-- =====================================================================
-- TRINO 467 — cleaning up orphans from a failed CTAS
-- =====================================================================
-- The Trino signature is `ALTER TABLE ... EXECUTE remove_orphan_files(...)`.
-- Trino does NOT expose `CALL iceberg.system.remove_orphan_files(...)`.
-- Trino enforces a 7-day MINIMUM on retention_threshold (catalog property
-- `iceberg.remove-orphan-files.min-retention`, default '7d'). Shorter
-- values are rejected with "Retention specified (X.XXd) is shorter than
-- the minimum retention configured in the system (7.00d)".
-- Trino does NOT support a `dry_run` parameter on this procedure — see
-- the Spark preview block below if you need to preview before deleting.

ALTER TABLE iceberg.analytics.historical_invoices
EXECUTE remove_orphan_files(retention_threshold => '7d');

-- =====================================================================
-- SPARK — preview first with dry_run (Spark only — Trino has no dry_run)
-- =====================================================================
-- BEFORE the Trino ALTER TABLE above, run this from Spark to see exactly
-- which files would be deleted. Orphan-file removal is irreversible — once
-- the bytes are gone from MinIO, you cannot recover the failed CTAS's
-- partial output for forensic analysis.
CALL iceberg.system.remove_orphan_files(
  table   => 'analytics.historical_invoices',
  dry_run => true              -- returns the list of candidate files, deletes nothing
);

-- If the dry-run list looks correct, run the actual deletion (Spark form
-- avoids Trino's 7-day floor when GDPR-urgent — but for routine post-CTAS
-- cleanup, the 7-day floor is exactly the safety margin you want):
-- CALL iceberg.system.remove_orphan_files(
--   table      => 'analytics.historical_invoices',
--   older_than => current_timestamp - interval '7' day
-- );
```

**IMPORTANT signature differences (both engines run the same underlying Iceberg operation, but the SQL surfaces differ):**

| Aspect | Trino 467 | Spark |
|---|---|---|
| Statement form | `ALTER TABLE ... EXECUTE remove_orphan_files(...)` | `CALL iceberg.system.remove_orphan_files(...)` |
| Table parameter | Implied by `ALTER TABLE iceberg.<schema>.<table>` | Explicit `table => 'schema.table'` named arg |
| Age cutoff | `retention_threshold => '7d'` (duration string) | `older_than => <timestamp>` (absolute timestamp) |
| Minimum-retention floor | **7 days enforced** (`iceberg.remove-orphan-files.min-retention`, default `'7d'`) | No floor |
| Dry-run preview | **Not supported** | `dry_run => true` |
| Concurrency knob | Not exposed | `max_concurrent_deletes => <int>` |

**Pasting the Spark CALL form into a Trino session returns "procedure not registered: iceberg.system.remove_orphan_files".** This is one of the most common copy-paste errors when adopting Trino after using Spark for Iceberg maintenance — Trino simply does not register the CALL procedure for `remove_orphan_files` (or for any of `rewrite_data_files`, `expire_snapshots`, `rewrite_manifests` — all four routine maintenance procedures use `ALTER TABLE ... EXECUTE` in Trino, not CALL).

The takeaway: **HMS is not "only needed at commit time" for cross-catalog CTAS** — it is on the critical path at query start (table registration) AND at commit (pointer swap). HMS availability matters throughout the query lifetime, not just at the end. Monitor HMS as a Tier-0 dependency for any write workload that lands in Iceberg, including federated CTAS.

For very large CTAS operations from Postgres (e.g., snapshotting an 8M-row table), prefer to **avoid running this from Trino at all** — use a dedicated Spark or Flink job with proper checkpointing and idempotent commit semantics. Trino CTAS works but has no built-in resume-from-failure: if the SELECT fails halfway through, you start over from scratch (and clean up any orphan files from the partial write).

#### Federated `INSERT INTO iceberg SELECT FROM postgres` — appending to an EXISTING Iceberg table

CTAS creates a **new** Iceberg table from a Postgres source. For most real production workloads — incremental cache refreshes, periodic snapshots, append-only ingestion — you instead want to **append** new rows to an **already-existing** Iceberg table. The syntax is `INSERT INTO`, and the lifecycle behavior is meaningfully different from CTAS in ways that matter for failure recovery.

```sql
-- Append new Postgres rows into an EXISTING Iceberg table.
-- Pattern: incremental ingestion using a high-watermark filter.
INSERT INTO iceberg.analytics.users_snapshot (id, tenant_id, email, plan, status, created_at)
SELECT id, tenant_id, email, plan, status, created_at
FROM app_pg.public.users
WHERE created_at > TIMESTAMP '2026-05-26 00:00:00'   -- high-watermark from last run
  AND created_at <= TIMESTAMP '2026-05-27 00:00:00';
```

**Why prefer INSERT over CTAS in many cases:**

- **Appends to an existing table** — preserves the table's existing partition layout, statistics, snapshot history, and downstream consumers' SELECT queries. CTAS requires you to drop and recreate, which breaks any queries / views / dashboards that refer to the table by name during the rebuild window.
- **Incremental refresh pattern works naturally** — you keep a high-watermark (max `created_at` or max `id`) from the previous run and INSERT only the new rows. CTAS forces a full re-snapshot each run.
- **Iceberg snapshot history is preserved** — each INSERT creates a new Iceberg snapshot you can time-travel to (`FOR VERSION AS OF` / `FOR TIMESTAMP AS OF`). CTAS resets the table's snapshot lineage at every refresh.
- **Downstream readers see atomic version transitions** — readers running concurrent SELECTs against the table see either the pre-INSERT snapshot or the post-INSERT snapshot, never a half-loaded state (see "data visibility only at commit" below).

**The lifecycle — HMS registration vs data visibility:**

1. **At query start (before any Postgres rows are read):** Trino calls HMS to **register the new snapshot's intent** — partition metadata, file layout, target column schema are set up against the existing table. **No new data files exist in MinIO yet, no readers see anything new.** If HMS is unreachable at this step, the INSERT **fails immediately** before any Postgres reads happen — clean failure, nothing to clean up.

2. **During the SELECT (rows flow from Postgres through Trino workers to MinIO):** Parquet files are written to MinIO under a staging path. **These files are invisible to readers** — Iceberg readers consult the manifest list pointed at by the current `metadata_location`, which still references the **pre-INSERT** snapshot. Even though bytes are landing in MinIO, no reader can see them. This is the **atomic write guarantee**: no partial-row visibility is possible during the INSERT.

3. **At commit (after the SELECT completes successfully):** Trino calls HMS to atomically swap the table's `metadata_location` pointer to a new metadata JSON that includes the just-written manifest. **This is the moment new rows become visible.** All concurrent readers see the new snapshot on their next query. The transition is instant and atomic — Iceberg's metadata-pointer commit is a single HMS update.

**Failure and rollback behavior — what to actually expect:**

- **SELECT phase failure (Postgres goes away, Trino worker OOMs, network drops mid-read):** The commit at step 3 never happens. The metadata pointer is not updated. Readers continue to see the pre-INSERT snapshot. **However**, the **Parquet files that were already written to MinIO during step 2 remain on disk** — they are **orphan files** because no manifest references them. These take up MinIO storage but are completely invisible to queries. Clean them up with the same `ALTER TABLE ... EXECUTE remove_orphan_files(retention_threshold => '7d')` procedure shown in the CTAS section above. The default 7-day retention floor exists specifically to prevent races where a slow concurrent reader still has the old metadata loaded.
- **HMS commit failure at step 3 (HMS is up at query start, dies before commit):** Same outcome — pre-INSERT snapshot remains the visible state, orphan files remain in MinIO. The query reports the HMS error; safe to retry from a clean slate (the retry will produce a new set of files; the orphans from the failed first attempt need cleanup).
- **No partial commit possible.** Unlike a Postgres INSERT where partial-row writes can happen if the connection dies mid-statement, Iceberg's commit is metadata-pointer-only. Either all the new rows are visible (commit succeeded) or none are (commit did not happen). There is **no in-between state** that downstream readers can observe.
- **Re-running an INSERT after failure: append semantics matter.** **Plain `INSERT INTO` in Trino always APPENDS rows — it never overwrites the partition, even if your WHERE clause matches only a single partition.** This means a naive re-run after a partially-failed INSERT can produce duplicate rows in the target if the commit at step 3 actually succeeded on a prior attempt and you re-run anyway (or if the source picks up overlapping rows on the second attempt). True idempotent partition replacement requires one of the two patterns shown below ("Idempotent re-runs" section) — `DELETE FROM ... WHERE date_col = X` immediately followed by `INSERT INTO ... WHERE date_col = X`, **or** `MERGE INTO`. If your INSERT is bounded by a high-watermark filter (`WHERE created_at > '...' AND created_at <= '...'`) AND you have first confirmed the prior attempt did NOT commit (no new snapshot exists past the prior watermark), re-running produces the same logical result — just possibly more orphan files to clean. If the filter is non-deterministic (e.g., depends on `NOW()` or relies on the source not being modified between attempts), retry-safety needs more care.

**Column type matching — Postgres types must be compatible with Iceberg types at INSERT time:**

The target Iceberg table's column types are fixed by its current schema. The Postgres source column types must be **compatible** with the corresponding Iceberg types — Trino does automatic upcasts (e.g., Postgres `INTEGER` → Iceberg `BIGINT` is fine) but not narrowing conversions (Postgres `BIGINT` → Iceberg `INTEGER` fails at planning if any value could overflow). Common matchups to verify before the first INSERT:

| Postgres source type | Compatible Iceberg target type |
|---|---|
| `INTEGER`, `BIGINT`, `SMALLINT` | `INTEGER`, `BIGINT` (Iceberg has no smallint — use INTEGER) |
| `NUMERIC(p, s)` | `DECIMAL(p, s)` — precision/scale must match |
| `TEXT`, `VARCHAR(n)`, `CHAR(n)` | `VARCHAR` (Iceberg VARCHAR has no length cap) |
| `BOOLEAN` | `BOOLEAN` |
| `DATE` | `DATE` |
| `TIMESTAMP` (without TZ) | `TIMESTAMP(6)` — Iceberg defaults to microsecond precision |
| `TIMESTAMPTZ` | `TIMESTAMP(6) WITH TIME ZONE` |
| `UUID` | `UUID` |
| `JSONB` | `VARCHAR` (no native Iceberg JSON type — stored as serialized string; loses indexability) |
| `ARRAY[type]` | `ARRAY(type)` — element types must match |
| `BYTEA` | `VARBINARY` |
| **Postgres ENUM** | `VARCHAR` only — Iceberg has no enum type; you lose the enum constraint, but the string value transfers cleanly |

**Mismatches fail at INSERT planning time (not at runtime)**, which is the safe failure mode — you find out before any data is written. If you see "Cannot cast type X to Y" at INSERT time, fix it by either (a) casting in the SELECT (`SELECT CAST(col AS VARCHAR) ...`) or (b) altering the Iceberg target column with `ALTER TABLE iceberg.analytics.users_snapshot ALTER COLUMN <col> SET DATA TYPE <wider_type>` if the change is widening.

**Partition pruning at write time — INSERT respects the target's partitioning:**

If the target Iceberg table is partitioned (e.g., `partitioning = ARRAY['bucket(tenant_id, 16)']`), the INSERT writes one file per partition the source rows actually touch. You do **not** specify partition information in the INSERT statement — Iceberg derives the partition assignment from each row's values. **Watch out for the small-file problem**: an INSERT that writes 50 rows spread across 16 buckets writes 16 tiny Parquet files. For incremental refreshes producing very small batches, plan to periodically run `ALTER TABLE ... EXECUTE optimize` (or `rewrite_data_files`) to compact small files — see resource 17 on Iceberg maintenance.

**Idempotent re-runs and exactly-once ingestion — the canonical patterns:**

> **Critical correction:** `INSERT INTO iceberg_table SELECT ... WHERE date = X` in Trino **always APPENDS** the new rows. It does **NOT** overwrite the rows already present in partition `X`, even if the WHERE clause matches only that one partition. There is no "implicit INSERT OVERWRITE" in Trino's Iceberg connector. If you re-run the same INSERT twice, you get duplicate rows. To get true idempotent partition-replacement semantics (safe to re-run on the same window and end with the correct row set), you must use **one** of the two patterns below.

**Pattern A — DELETE + INSERT (best for full partition replacement):**

```sql
-- 1. DELETE everything currently in the target window (metadata-only delete
--    if your WHERE clause matches identity-transformed partitioning columns).
DELETE FROM iceberg.analytics.events_daily
WHERE event_date = DATE '2026-05-27';

-- 2. INSERT the fresh batch for the same window.
INSERT INTO iceberg.analytics.events_daily
SELECT id, tenant_id, event_type, payload, event_date
FROM app_pg.public.events
WHERE event_date = DATE '2026-05-27';
```

Re-running this pair produces the same final partition contents every time — the DELETE wipes any rows from the prior attempt, the INSERT writes the fresh set. The DELETE is a **metadata-only operation** when the WHERE clause aligns with identity-transformed partitioning columns (e.g., a column directly used in `partitioning = ARRAY['event_date']`), making it very fast. Caveats: the DELETE and the INSERT are **two separate Iceberg commits** — a reader between them sees an empty partition briefly. If that visibility gap matters, use Pattern B (MERGE) instead, which is single-commit.

**Pattern B — MERGE INTO (best for upserts where some rows update, some are new):**

```sql
-- Single-statement upsert: insert new rows, update changed ones, all in one commit.
MERGE INTO iceberg.analytics.users_snapshot AS t
USING (
  SELECT id, tenant_id, email, plan, status, created_at, updated_at
  FROM app_pg.public.users
  WHERE updated_at > TIMESTAMP '2026-05-26 00:00:00'
    AND updated_at <= TIMESTAMP '2026-05-27 00:00:00'
) AS s
ON t.id = s.id
WHEN MATCHED THEN UPDATE
  SET email = s.email, plan = s.plan, status = s.status, updated_at = s.updated_at
WHEN NOT MATCHED THEN INSERT (id, tenant_id, email, plan, status, created_at, updated_at)
  VALUES (s.id, s.tenant_id, s.email, s.plan, s.status, s.created_at, s.updated_at);
```

MERGE INTO is the recommended idempotent pattern when the source has UPDATEs (not just appends). It's also the recommended replacement for `INSERT OVERWRITE` per Iceberg's docs — Iceberg can replace only the affected data files rather than rewriting the entire partition, and the semantics are easier to reason about. Single Iceberg commit, no visibility gap.

> ### CRITICAL — Iceberg write mode in Trino is **merge-on-read (MoR)**, NOT copy-on-write
>
> **What actually happens when you run `MERGE INTO` or `DELETE` against an Iceberg table in Trino 467:** the connector writes **positional delete files** (small Parquet/Avro files that mark specific row positions in existing data files as deleted) and, for `MERGE`, also writes new data files for the inserted/updated rows. **It does NOT rewrite the matched Parquet data files in place.** This is the **merge-on-read** strategy: reads must merge the positional delete files with the base data files to reconstruct the current logical row set. Writes are cheap (only the changes are written); reads pay a small per-file overhead to apply the deletes.
>
> **Copy-on-write (CoW) is NOT available in Trino's Iceberg connector today.** CoW would rewrite the entire affected Parquet file with the updated row set on every MERGE/DELETE — and that mode is an **open feature request**, tracked as [trinodb/trino#17272](https://github.com/trinodb/trino/issues/17272). Do not assume you can flip a `write.merge.mode=copy-on-write` table property in Trino and get the Spark-style CoW behavior. The table property exists at the Iceberg-spec level, and Spark honors it, but **Trino's writer always writes MoR delete files regardless of the table property setting** on Trino 467. If your downstream readers absolutely require pre-merged data files (no positional deletes), you must run the compaction step below or perform the MERGE from Spark.
>
> **Compact delete files after heavy MERGE/DELETE activity — `ALTER TABLE ... EXECUTE optimize`.** Because every MERGE adds new delete files, accumulated MERGEs slowly degrade read performance — each scan has to load and apply more delete files. The fix is to run Iceberg's optimize procedure, which **rewrites the affected data files to physically remove the deleted rows and drops the now-redundant positional delete files**:
>
> ```sql
> -- Compact data files + drop positional delete files in one shot.
> ALTER TABLE iceberg.analytics.users_snapshot EXECUTE optimize;
>
> -- Optionally restrict to a file-size threshold (only rewrite small files).
> ALTER TABLE iceberg.analytics.users_snapshot EXECUTE optimize(file_size_threshold => '100MB');
> ```
>
> After `optimize`, scans no longer pay the delete-file merge cost. Schedule this as part of your Iceberg maintenance cadence — for high-churn MERGE targets, daily or per-batch is reasonable; for low-churn targets, weekly is fine. See resource 17 on Iceberg maintenance for the full cadence guidance, and pair `optimize` with `expire_snapshots` + `remove_orphan_files` so the old data files and the dropped delete files are actually freed from MinIO.
>
> **Quick recap of the MoR rules to remember:**
> 1. Trino's Iceberg connector writes **positional delete files** for MERGE and DELETE — it is **merge-on-read**, not copy-on-write.
> 2. Read performance degrades as delete files accumulate. Run `ALTER TABLE ... EXECUTE optimize` periodically to compact them away.
> 3. CoW for Iceberg writes in Trino is an open feature request ([trinodb/trino#17272](https://github.com/trinodb/trino/issues/17272)) — **not available** on Trino 467 regardless of the `write.merge.mode` table property.
> 4. Setting `write.merge.mode=copy-on-write` on the Iceberg table does not change Trino's write behavior. If you need true CoW today, run the MERGE from Spark instead.

**Pattern C — plain INSERT INTO bounded by a watermark (APPEND-ONLY sources only):**

```sql
-- ONLY use this pattern when the source table is strictly append-only
-- (no UPDATEs, no DELETEs, no late-arriving rows past the watermark).
-- This is NOT idempotent if the prior attempt's commit succeeded —
-- the caller MUST verify the watermark advanced before retrying.
WITH watermark AS (
  SELECT COALESCE(MAX(created_at), TIMESTAMP '1970-01-01 00:00:00') AS hwm
  FROM iceberg.analytics.users_snapshot
)
INSERT INTO iceberg.analytics.users_snapshot
SELECT id, tenant_id, email, plan, status, created_at
FROM app_pg.public.users, watermark
WHERE created_at > watermark.hwm
  AND created_at <= TIMESTAMP '2026-05-27 00:00:00';   -- explicit upper bound = bounded window
```

The **explicit upper bound** keeps the "window" semantics stable across retries — without it, a re-run pulls in even newer Postgres rows than the first attempt intended. Always pin the upper bound to a wall-clock-fixed timestamp the caller computes, not to `NOW()` inside the query. Crucially, **this pattern is only safe if the source is append-only AND the caller re-reads `MAX(created_at)` before each retry** — if the prior attempt committed (snapshot advanced) and the caller blindly re-runs the same SQL with a stale watermark, you get duplicates. For sources with mutations, prefer Pattern A or Pattern B.

**When INSERT is the wrong tool (use a full pipeline instead):**

- **Source table has UPDATEs or DELETEs**, not just appends. INSERT-with-watermark only catches new rows; existing-row modifications in Postgres are invisible to it. For mutable source data, use Debezium CDC (see Section 7.4) or a periodic full-refresh CTAS replacing the whole table.
- **Source row count per INSERT batch exceeds ~5M rows.** Trino has no resume-from-failure for federated INSERT — a 30-minute INSERT that fails at minute 25 restarts from zero, plus you have 25 minutes of orphan files to clean. Above this scale, use Spark or a CDC pipeline with checkpointing.
- **Strict exactly-once semantics required across multiple target tables.** Trino's INSERT is per-table atomic, not cross-table atomic. If you need "insert into A and insert into B both succeed or both roll back," materialize first into a staging table in Iceberg, then have the application do the swap inside a transaction it controls.

### 9.6 "How do I quickly disable the federation catalog?"

Remove the `etc/catalog/app_pg.properties` ConfigMap mount and roll the pods. Queries referencing `app_pg.*` will fail with "catalog not found" — that's the intended fail-safe.

---

## 10. Key terms

- **Catalog**: a Trino-side handle for one configured data source (Iceberg, Postgres, etc.). Each catalog is a single `.properties` file under `etc/catalog/`.
- **Federation**: querying multiple data sources in a single SQL statement via one engine (Trino).
- **Predicate pushdown**: rewriting a WHERE clause so the upstream system (Postgres) applies the filter, returning fewer rows over the network.
- **Join pushdown**: executing an entire JOIN inside a remote system. Only works for tables in the **same catalog** — does not work cross-catalog.
- **Dynamic filtering**: a runtime optimization where Trino derives a filter from one side of a join (after seeing the actual values) and pushes it to the other side's scan to reduce data movement.
- **Build side** / **probe side**: in a hash join, the build side is the (usually smaller) side that becomes the in-memory hash table; the probe side streams through and looks up matches.
- **Hybrid pattern (live tail)**: a UNION ALL view that joins Iceberg's historical data with a federated read of the most recent Postgres data, to deliver low-latency freshness on top of cheap columnar history.

---

## 11. Quick decision flowchart

```
Need to query Postgres + Iceberg in one statement?
      |
      v
Is it a one-off ad-hoc query?  --YES--> Just use the federation connector. Done.
      |
      NO
      v
Is freshness requirement < ingestion latency?  --YES--> Hybrid pattern (UNION ALL view).
      |                                                  Iceberg history + Postgres live tail.
      NO
      v
Is the Postgres side a small dimension table     --YES--> Cross-catalog join with dynamic
   (up to ~1M rows, ideally with a selective WHERE)?       filtering. Verify with EXPLAIN
      |                                                    and EXPLAIN ANALYZE.
      NO
      v
Both sides are large?  ---> Ingest the Postgres data into Iceberg. Federation will hurt.
```

If you remember only three things from this doc:

1. **Predicate pushdown is real and on by default for numeric/UUID/temporal/DATE — but NOT for string ranges.** Always verify with `EXPLAIN`.
2. **Cross-catalog joins always run on Trino workers; dynamic filtering is what makes them fast.** Make sure one side is small and selective.
3. **Point at a read replica, never the OLTP primary. Bound connections OUTSIDE Trino** (PgBouncer in transaction mode + Postgres role-level `CONNECTION LIMIT` + Trino resource groups; OSS Trino 467 has no native PostgreSQL connection pool), **and set a Postgres `statement_timeout`**. Otherwise federation will eventually take down your app.

---

## 12. Trino coordinator HA on k8s — what it covers and what it doesn't

This section answers the recurring question: **"Can I run our Trino coordinator pod as a Deployment with `replicas: 2` in Kubernetes so we have high availability?"**

The short answer is **no, not within a single cluster.** The longer answer is that there are two real HA patterns, and you need to pick one with eyes open about the trade-offs. This is critical for federation specifically because a coordinator failure mid-query has different cleanup semantics for Postgres JDBC sessions vs Iceberg scans vs the OPA decision log — and it is easy to assume HA exists when it does not.

### 12.1 The core constraint (one sentence, quotable)

> **OSS Trino does not natively support multiple coordinators in a single cluster — workers register against one `discovery.uri`, so running two coordinator pods in the same cluster creates split-brain worker discovery.**

Why this matters concretely:

- Every worker pod's `etc/config.properties` contains a single line: `discovery.uri=http://trino-coordinator:8080`. Workers connect to that URI on startup, announce themselves, and receive task assignments from whatever coordinator answers there.
- If you set your coordinator Deployment to `replicas: 2`, the Kubernetes Service in front of it round-robins between the two pods. **Both** coordinator pods believe they are the coordinator. Both will register the same set of workers. Both will try to assign tasks. Discovery, scheduling, and query state are not synchronized between them.
- Symptoms when people accidentally do this: queries randomly fail with "no nodes available," workers show up and disappear in `system.runtime.nodes`, distributed transactions get confused, and you cannot reproduce the failures because the SaaS app's load balancer routes each new HTTP request to a different coordinator pod with a different view of the cluster.
- This is **not** a Helm-chart or config issue you can work around. The split-brain is inherent to OSS Trino's architecture. Multi-coordinator support is a long-standing feature request — see Section 12.5 below.

**The corollary**: a "second coordinator joining the cluster" is **not** a thing in OSS Trino 467. You cannot scale a coordinator horizontally the same way you scale workers. The mental model has to be: one coordinator pod per cluster, period.

### 12.2 Two real HA patterns

If you actually need HA — meaning you want the cluster to survive an unplanned coordinator pod loss with bounded downtime — you have two options. Pick exactly one. Do not try to combine them in clever ways.

---

#### Pattern A — Two separate Trino clusters behind an external proxy (HAProxy or Envoy)

Run **two complete, independent Trino clusters**. Each cluster has its own coordinator pod and its own pool of worker pods. They share nothing — separate Hive Metastore connection? Same metastore is fine. Separate discovery? Yes. Separate worker pool? Yes, that is the point.

In front of both clusters, put a Layer 7 proxy (HAProxy or Envoy) that:

1. **Health-checks each coordinator** on `/v1/info` (HTTP GET, port 8080, expects 200 OK).
2. **Routes client traffic** to one or both clusters based on health.

Two sub-patterns:

**A.1 — Active-passive (safe default)**

The proxy sends 100% of traffic to cluster 1 (the active cluster). Cluster 2 is on standby — same configuration, same catalog mounts, idle workers. When the health check on cluster 1 fails (coordinator pod evicted, network partition, anything), the proxy fails over and routes all traffic to cluster 2.

**Behavior on failover:**
- In-flight queries on cluster 1 die (they were running there; that coordinator is gone). Clients get a connection error and must retry.
- The next query attempt lands on cluster 2's coordinator and runs cleanly on cluster 2's workers.
- No query state is migrated — there is no shared state between the two clusters.

**Minimal HAProxy backend block** (illustrative — adapt to your TLS/JWT setup):

```
backend trino_coordinators
    mode http
    balance first                            # active-passive: try the first server until it fails
    option httpchk GET /v1/info HTTP/1.1\r\nHost:\ trino
    http-check expect status 200

    server trino_a trino-a-coordinator.trino-a.svc:8080 check inter 2s fall 3 rise 2
    server trino_b trino-b-coordinator.trino-b.svc:8080 check inter 2s fall 3 rise 2 backup
```

The `backup` keyword on `server trino_b` means HAProxy only sends traffic there when `trino_a` is unhealthy. `inter 2s fall 3` means a coordinator is marked down after 3 consecutive failed health checks 2 seconds apart (so failover takes ~6 seconds). Tune to your tolerance.

**A.2 — Active-active (requires sticky sessions)**

The proxy load-balances new queries across both clusters. This doubles your query throughput when both clusters are healthy, but it **requires sticky sessions**: once a client starts a query on cluster 1, **every subsequent HTTP request for that query's lifetime** (`POST /v1/statement` → `GET /v1/statement/{queryId}/{nextUri}` polling) must go to cluster 1's coordinator. A stateless round-robin breaks running queries — the coordinator on cluster 2 has never heard of the queryId from cluster 1 and returns 404, killing the query.

In HAProxy, sticky sessions on Trino are typically done via cookie insertion or by hashing the URL path (which contains the queryId). In Envoy, this is a `consistent_hash` load balancer keyed on a header or the request URI. **Goldman Sachs publicly documented an Envoy-proxy-in-front-of-two-Trino-clusters pattern** for exactly this use case; **Arenadata's docs** show the equivalent HAProxy config.

**Cost of Pattern A**: you double your worker count. Common mitigation: keep cluster 2 smaller (say, 30% the worker count of cluster 1) as a "degraded mode" standby, and have your k8s cluster autoscaler add more worker pods to cluster 2 when failover happens. This trades a longer recovery time for lower steady-state cost.

> **Trino-native proxy alternative — Trino Gateway (`trinodb/trino-gateway`).** Instead of HAProxy or Envoy, you can put **Trino Gateway** (an official Trino-project sub-repo, formerly Lyft's Presto Gateway) in front of multiple Trino clusters. It is a JVM-based reverse proxy that understands Trino's HTTP protocol natively — it tracks the `queryId` in the URL path, routes follow-up `GET /v1/statement/{queryId}/{nextUri}` polling requests back to the cluster that originated the query (solving the sticky-session problem out of the box), and exposes admin APIs for marking clusters active/draining. On the on-prem k8s stack here, Trino Gateway is a one-deployment add-on that often replaces a hand-rolled HAProxy + cookie-stickiness configuration with less custom config. The trade-off vs. HAProxy/Envoy is that Trino Gateway is Trino-specific (you cannot reuse it for non-Trino traffic) and adds a JVM process to your platform footprint. For clusters that need Pattern A and only Trino traffic, Trino Gateway is the lower-friction choice; for clusters where the platform already runs HAProxy or Envoy for other workloads, sharing that L7 proxy and adding Trino-specific sticky-session rules is the path of least resistance. See `github.com/trinodb/trino-gateway` for the deployment guide.

---

#### Pattern B — Single coordinator + k8s Deployment + PodDisruptionBudget

If you cannot afford to double the cluster, accept the constraint and make the single-coordinator pod recover quickly. This is the more common pattern on cost-constrained on-prem k8s.

The recipe has three k8s primitives:

1. **A Deployment with `replicas: 1`** for the coordinator. (Not `replicas: 2` — re-read Section 12.1 if tempted.) k8s recreates the pod automatically if it dies.
2. **A PodDisruptionBudget** that prevents voluntary eviction (e.g., a node drain during a k8s upgrade) from killing the coordinator unless a replacement is ready.
3. **A readiness probe** on `/v1/info` so the Service does not route client traffic to a pod that is still starting up.

**Minimal PodDisruptionBudget**:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: trino-coordinator-pdb
  namespace: trino
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: trino
      component: coordinator
```

`minAvailable: 1` means **at least one coordinator pod must be available at all times for voluntary disruptions to proceed**. When a node is being drained for a planned event (upgrade, maintenance), k8s will refuse to evict the coordinator pod until a replacement is scheduled and ready. PDBs do **not** protect against involuntary disruptions (node hardware failure, OOMKill); those still take the pod down immediately.

**Readiness probe in the Deployment spec**:

```yaml
readinessProbe:
  httpGet:
    path: /v1/info
    port: 8080
  initialDelaySeconds: 30
  periodSeconds: 5
  failureThreshold: 3
```

`/v1/info` returns 200 once the coordinator has loaded all catalogs and is ready to accept queries. Until then, the k8s Service excludes the pod from its endpoint list, so the SaaS app's HTTP client gets a clean connection refusal (and can retry against the next pod once it is ready) instead of routing to a half-started coordinator that will time out.

**Graceful shutdown — the coordinator has NONE.**

> **Critical correction:** There is **no graceful-shutdown mechanism for the Trino coordinator** in OSS Trino. The graceful-shutdown API (`PUT /v1/info/state` with body `"SHUTTING_DOWN"`, controlled by the `shutdown.grace-period` config property) applies **exclusively to workers** — see [Trino's Graceful shutdown docs](https://trino.io/docs/current/admin/graceful-shutdown.html). When a coordinator pod is evicted (planned k8s rolling update, node drain, voluntary disruption, or unplanned OOMKill / node failure), **all in-flight queries die instantly** — no drain, no timeout that helps, no leader handoff. There is no Trino-side property that changes this. **Common mistake: `http-server.stop-timeout` is NOT a real Trino property.** Setting it in `etc/config.properties` is silently ignored.

What you actually have for the coordinator:

1. **`terminationGracePeriodSeconds`** on the pod spec is just the k8s-side window between SIGTERM and SIGKILL. It does NOT give the Trino coordinator any built-in ability to drain queries — Trino's coordinator does not intercept SIGTERM for query-drain purposes. The only thing it buys you is time for OS-level cleanup and in-flight HTTP responses to finish flushing.
2. **`PodDisruptionBudget`** with `minAvailable: 1` prevents k8s from voluntarily evicting the coordinator pod during planned events (node drain for upgrades, etc.) without a replacement being ready first. PDBs **limit the blast radius of voluntary disruptions** but do **NOT** protect against involuntary disruptions (node hardware failure, OOMKill).
3. **Operational drain** is the only "graceful coordinator restart" path: pause your scheduler / UI / API gateway upstream of the coordinator, **wait for in-flight queries to complete on their own** (poll `SELECT * FROM system.runtime.queries WHERE state = 'RUNNING'` until empty), **then** trigger the pod restart. This is a human-/CI-orchestrated drain, not a Trino-engine drain.

For comparison — **workers DO have a graceful shutdown:**

```properties
# In WORKER etc/config.properties (NOT the coordinator):
shutdown.grace-period=60s   # default is 2 minutes
```

Combined with a `preStop` hook that PUTs `"SHUTTING_DOWN"` to `/v1/info/state` (see Section 8.8 above), workers stop accepting new tasks and wait for in-flight tasks to complete before the JVM exits. **None of this applies to the coordinator.**

> **The `SHUTDOWN` SQL command / `PUT /v1/info/state` API behaves differently on coordinator vs worker.** On a **worker**, it triggers the graceful drain described in Section 8.8 — in-flight tasks finish, then the JVM exits. On a **coordinator**, there is no equivalent drain. Issuing `SHUTTING_DOWN` against the coordinator (or having its pod evicted by k8s) **kills all in-flight queries** the moment the coordinator process stops accepting traffic. This is a deliberate limitation in OSS Trino — the coordinator is the single source of truth for query state and there is no handoff target. For planned coordinator evictions, your only mitigations are: (a) PDB to control WHEN the eviction happens, (b) upstream traffic pause + operator-driven drain BEFORE triggering the restart. Neither is a property setting on Trino itself.

---

### 12.3 In-flight query behavior on coordinator failure (no HA)

If you are running Pattern B with a single coordinator and the coordinator pod dies unexpectedly (or you are running Pattern A and the active cluster fails over), here is exactly what happens to queries that were running at the moment of failure:

1. **In-flight queries die.** There is no resume. The coordinator holds the entire query state in memory: the parsed plan, the task graph, stage tracking, exchange buffers, and the mapping of which worker is running which task. When the coordinator pod dies, all of that state is gone. Workers cannot continue on their own — they were taking instructions from the coordinator.

2. **Clients receive a connection error.** The JDBC driver or HTTP client sees the TCP connection drop (or a polling `GET /v1/statement/.../{nextUri}` returns 502/503 from the k8s Service while the pod is being recreated). The client must retry the query from scratch.

3. **Workers detect coordinator loss via heartbeat timeout.** Workers periodically send heartbeats to the coordinator's announcement endpoint. When heartbeats fail (default heartbeat interval and timeout: ~5 minutes, configurable via discovery client settings), workers conclude the coordinator is gone. They then:

   > **The configurable worker→coordinator heartbeat property is `node-monitor.max-age` (default ~5 minutes in Trino 467). Workers detect a dead coordinator when no heartbeat has been received from it for this duration.** Set it lower (e.g., `node-monitor.max-age=60s`) in `etc/config.properties` on workers if you want faster detection of coordinator loss; the trade-off is more sensitivity to transient network blips that could cause workers to spuriously mark a healthy coordinator dead and start tearing down their tasks. The default 5-minute window is the right balance for most clusters; tune it only if your network is rock-solid and you specifically need sub-minute failover.
   - Abort all their currently-running tasks.
   - Release per-task resources: heap buffers, exchange buffers, **and JDBC connections** (see Section 12.4 below for Postgres-specific behavior).
   - Wait for a new coordinator to come up at `discovery.uri` and re-register.

4. **There is NO automatic query resume on a new coordinator pod.** Once the new coordinator starts, it has an empty query registry. The dead queryIds are not recovered. The client must re-submit the original SQL.

### 12.4 Fault-tolerant execution (FTE) — covers WORKER failures, NOT coordinator HA

This is a common point of confusion. Trino has a feature called **fault-tolerant execution** (enabled with `retry-policy=TASK` or `retry-policy=QUERY` in `etc/config.properties`). It sounds like it should give you coordinator HA. **It does not.**

What FTE actually does:

- When a **worker** task fails (worker pod OOMs, gets evicted, hardware failure), Trino retries the failed task on another worker without restarting the whole query.
- This requires an **exchange manager** so intermediate shuffle results survive worker death.
- It covers long-running ETL queries where one bad worker would otherwise kill a 4-hour job.

What FTE does **not** do:

- It does not protect against **coordinator** failure. The coordinator still holds the master query plan and the FTE retry decisions. When the coordinator dies, the query dies — FTE or not.
- It does not give you HA. Enabling `retry-policy=TASK` and `exchange-manager.name=filesystem` does nothing to keep your cluster running through a coordinator pod eviction.

If your team has been told "we enabled FTE so we're highly available" — that is wrong. FTE is a worker-resilience feature. Coordinator HA is Pattern A or Pattern B from Section 12.2.

**Prefer `retry-policy=TASK` over `retry-policy=QUERY` for federated batch queries.** Trino offers two retry policies and they behave very differently:

- `retry-policy=TASK` — when a worker task fails, Trino retries **only that task** on another worker, reusing the spooled intermediate results of the tasks that already completed. Recommended by the Trino docs for **large batch queries** (including long-running federated joins). Requires an exchange manager.
- `retry-policy=QUERY` — when any worker task fails, Trino **restarts the entire query from scratch**. The Postgres scan reopens, the Iceberg scan replans (potentially against a newer snapshot), and all earlier work is discarded. Recommended only for **many small queries** where the retry cost is low.

For the typical federation workload covered in this resource (20–30 min joins of Iceberg facts to Postgres dim tables, or 1–4 hour ETL jobs that materialize Postgres data into Iceberg), `retry-policy=TASK` is the correct choice — a single failed Postgres-scan task retries on another worker without throwing away the Iceberg side's progress. `retry-policy=QUERY` would force a fresh Postgres `SELECT` (new `READ COMMITTED` snapshot — see Section 4.6) **and** a fresh Iceberg snapshot resolution every time, amplifying the cross-catalog skew window.

**Exchange manager — do NOT use the local filesystem in production.** The Trino docs are explicit that the `filesystem` exchange manager pointed at a local directory is intended for **standalone, non-production clusters only**. On a distributed cluster (i.e., anything with more than one worker), the local-directory exchange only works if the directory is a network-shared mount accessible from every worker pod with identical paths. A per-pod `emptyDir` or a non-shared PVC will silently lose intermediate results when a task retries on a different worker — defeating the entire point of FTE. For this resource's stack, point the exchange manager at **MinIO via the S3-compatible exchange** (`exchange.s3.region`, `exchange.s3.endpoint`, an `exchange-manager-storage` bucket). Example:

```properties
# etc/exchange-manager.properties (on coordinator + all workers)
exchange-manager.name=filesystem
exchange.base-directories=s3://trino-exchange/
exchange.s3.region=us-east-1
exchange.s3.endpoint=http://minio.minio.svc.cluster.local:9000
exchange.s3.path-style-access=true
exchange.s3.aws-access-key=...
exchange.s3.aws-secret-key=...
```

This gives you durable, shared, multi-worker-visible spooling — what FTE actually requires. The PostgreSQL and Iceberg connectors both support FTE with any retry policy, so no per-connector changes are needed once the exchange manager is wired up correctly.

### 12.5 Federation-specific behavior on coordinator failure

For this stack — Iceberg via Trino, Postgres via the JDBC connector, OPA for authorization — here is what happens to each subsystem when the coordinator dies mid-query:

**Postgres JDBC connections (`app_pg` catalog)**:

- Workers were holding open JDBC connections to Postgres, executing the pushed-down SQL.
- On heartbeat timeout, workers abort their JDBC tasks by calling `Statement.cancel()` on the active statement, then `Connection.close()` to return the connection to the worker-local pool (or close it outright if the pool is being torn down).
- Postgres sees this on its end: the session goes from `active` to `idle in transaction` to gone. `pg_stat_activity` shows the aborted sessions disappearing within the `tcp_keepalives_idle` window (usually a few minutes if not tuned, faster if you set `tcp_keepalives_idle=60` on the Postgres role).
- **No orphaned Postgres sessions** in the steady-state — but if your `tcp_keepalives_idle` is not configured and the network drops uncleanly, you can occasionally see stuck `idle in transaction` sessions that need `pg_terminate_backend()` manually. This is the same gotcha covered in Section 8 for connection hygiene.

**Iceberg scans**:

- Workers were reading data files (Parquet) from MinIO based on a snapshot resolved at query planning time.
- On heartbeat timeout, workers abort their split-reading tasks — the in-progress HTTP reads to MinIO are torn down by the JVM.
- **The Iceberg snapshot itself is not affected.** A snapshot is an immutable pointer in the Hive Metastore + a metadata.json file. The failed query did not modify it.
- A retry of the same SQL **may see a different snapshot** if commits to the table happened in the interval between the original query and the retry. This is normal Iceberg snapshot-isolation behavior. If the retry returns slightly more rows than the original would have, that is the cause — not a bug.

**OPA decision log**:

- OPA was consulted at query **analysis time**, before any tasks were dispatched. The authorization decision (allow/deny) is already in the OPA decision log by the time the coordinator starts handing tasks to workers.
- When the coordinator dies, the decision log entry **still exists** — it was written when OPA returned its response, not when the query completed.
- This means: even if the query ultimately fails due to coordinator loss, you have an audit trail showing "user X was authorized to read table Y at time T." The audit story is preserved across coordinator failures. (Cross-reference: Section 8.4 covers OPA decision logs in detail, and Section 8.5 covers the Trino event listener which is where query-completion events would be lost — those events are emitted by the coordinator on query end, so a coordinator that dies mid-query never emits the completion event.)

### 12.6 Future roadmap

Multi-coordinator support **inside one cluster** is tracked in **trinodb/trino issue #391** (opened in 2019, still open as of Trino 467). The proposed design involves a dispatcher layer in front of multiple coordinators, with shared state in a backing store. **It has not shipped.** Do not plan for it in your architecture. Check the issue status before any roadmap discussion that assumes this exists.

Until issue #391 ships, the answer to "how do we get coordinator HA on OSS Trino" is **Pattern A or Pattern B from Section 12.2**. There is no third option in OSS.

### 12.7 Quick summary

| Question | Answer |
|---|---|
| Can I set `replicas: 2` on my Trino coordinator Deployment? | **No.** Split-brain worker discovery. |
| What if I want HA anyway? | Pattern A (two clusters + HAProxy/Envoy) or Pattern B (single coordinator + PDB + readiness probe + operator-driven drain). **Note: there is no Trino-side "graceful shutdown" for the coordinator — `shutdown.grace-period` and the `/v1/info/state` API are worker-only. Coordinator evictions always kill in-flight queries.** |
| Does fault-tolerant execution give me coordinator HA? | **No.** FTE is for worker failures only. |
| What happens to in-flight queries when the coordinator dies? | They die. No resume. Clients must retry. |
| Do orphaned Postgres connections leak? | No, in steady state — workers cancel and close via heartbeat timeout. Tune `tcp_keepalives_idle` for faster cleanup. |
| Will a retry see the same Iceberg data? | Maybe not — Iceberg snapshot may have advanced. Normal snapshot-isolation behavior. |
| Is the OPA audit log preserved? | Yes. OPA is consulted at analysis time; the decision entry exists before the query runs. |
| Is multi-coordinator coming? | Tracked in trinodb/trino #391 since 2019. Not in 467. Check before relying on it. |
