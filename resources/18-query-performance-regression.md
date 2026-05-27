# Query Performance Regression Diagnosis

A guide for SaaS engineers and oncall members investigating why analytics queries suddenly got slower on the Trino 467 + Iceberg + MinIO stack.

---

## Triage priority order

When someone reports "queries are slow," work through these in order — each step takes 1–5 minutes and the answer in step 1 often makes the later steps irrelevant:

1. **Is it a concurrency spike?** — Are more queries running simultaneously than normal?
2. **Is it a specific query or all queries?** — Isolated regression vs. cluster-wide degradation.
3. **Did partition pruning break?** — Are you scanning more files than before?
4. **Is there partition skew?** — Is one partition carrying most of the data?
5. **Did the data model change?** — New joins, wider tables, missing filters?
6. **Are there too many small files?** — Compaction fell behind?

---

## Step 1: Check the Trino UI for concurrency

Open `http://trino-coordinator:8080/ui/queries`.

**Normal**: 5–20 concurrent queries, each completing in seconds.

**Abnormal signs:**
- **Queued queries**: "Queued" count > 0 means workers are saturated. Queries wait instead of running.
- **Long-running queries**: Any query > 2 minutes is a candidate for investigation.
- **Memory pressure**: Worker GC time > 20% of wall time in task detail view.

### Concurrency as the root cause

Each Trino worker has a fixed CPU and memory budget. If 50 dashboards all refresh at 9:00 AM simultaneously, the cluster serializes: each query gets less CPU, each takes longer, everyone complains about slowness.

**How to identify**: Look at the Trino UI query list sorted by start time. If many queries started within the same 60-second window, concurrency is the cause.

**Fixes:**
- Stagger dashboard refresh times (Metabase, Superset schedule settings).
- Set per-user resource group limits (see `05-multi-tenant-analytics.md`, resource groups section).
- Cache common aggregations in a pre-computed rollup table so 50 dashboards query a 10-row result instead of scanning the fact table.

### Query frequency as the root cause

A query that runs every 30 seconds for a live dashboard is 2,880 queries per day. If that query scans 1 GB each time, it's 2.8 TB of unnecessary I/O per day and constant worker load.

**How to identify**: In the Trino UI, look for the same query text repeating on a short interval. Or look at query history (`SELECT query, count(*) FROM system.runtime.queries GROUP BY query ORDER BY count(*) DESC LIMIT 10`).

**Fixes:**
- Cache the query result in your application layer (Redis, Memcached) for 60–300 seconds.
- Build a pre-aggregated table that refreshes every 5 minutes instead of querying the raw fact table live.
- Use Trino's `query.max-execution-time` limit to fail fast instead of hanging.

---

## Finding expensive queries on Trino 467 (verified SQL recipes)

Before tuning anything, you need to know which queries are actually costing you the most CPU and I/O. Trino 467 exposes per-query telemetry through two system tables that you must JOIN together to get a useful view. The schema is strict — using the wrong column names is the single most common mistake in these recipes.

### The two source tables (Trino 467 schema)

**`system.runtime.queries`** — one row per query, holds the SQL text and lifecycle metadata.

> **`system.runtime.queries` — Actual Column Reference (Trino 467)**
>
> **This table has NO `catalog` or `schema` columns.** Writing `WHERE catalog = 'app_pg'` fails with `Column 'catalog' cannot be resolved`. The columns sound like they should exist (the Trino Web UI surfaces catalog per query) but they do not exist on this in-memory system table. **Source of truth**: `QuerySystemTable.java` in the Trino codebase.
>
> **Actual columns** (verified against Trino 467):
>
> - `query_id` — unique query identifier (string like `20260526_143012_00042_abcde`)
> - `state` — `RUNNING`, `FINISHED`, `FAILED`, `CANCELED`
> - `"user"` — **must be double-quoted** (unquoted `user` is parsed as the `current_user` builtin in expression contexts and silently returns the session user instead of the column value — wrong-value bug, not a syntax error). Per [trino.io/docs/current/language/reserved.html](https://trino.io/docs/current/language/reserved.html), `USER` itself is non-reserved but `CURRENT_USER` is reserved — the behavior comes from `user` being treated as shorthand for `current_user`.
> - `source` — client source name (set via JDBC `?source=<name>` URL param or the `X-Trino-Source` HTTP header)
> - `query` — the full SQL text submitted by the client (this is the ONLY place to recover the SQL on this table — there's no separate SQL column)
> - `resource_group_id` — which resource group ran the query
> - `queued_time_ms`, `analysis_time_ms`, `planning_time_ms` — phase timings in milliseconds
> - `created`, `started`, `last_heartbeat`, `end` — timestamps (end column is literally `end`, NOT `completed_at`)
> - `error_type`, `error_code` — populated for `FAILED` queries
>
> **To find queries that touched a specific catalog**, search the SQL text (no `catalog` column exists):
>
> ```sql
> SELECT query_id, "user", source, query, state, created, "end"
> FROM system.runtime.queries
> WHERE query LIKE '%app_pg%'
>   AND state = 'FINISHED'
> ORDER BY created DESC;
> ```
>
> **Caveat — `LIKE` matches can produce false positives.** A query that mentions the catalog name in a column value or a SQL comment will match spuriously. For production audit (low false-positive rate, durable past coordinator restarts), use the Trino **event listener** — the persisted `QueryCompletedEvent.metadata.catalog` field is properly catalog-keyed (see the CRITICAL — `system.runtime.*` is EPHEMERAL block below for setup).

Notable points: the **SQL text lives only on this table** (column `query`). End time is `end` (NOT `completed_at`). **No `catalog`, no `schema`, no `peak_memory_bytes` columns exist here** — those are the three most-frequently invented column names; do not write SQL against them.

> **CRITICAL — `"user"` quoting recap.** Always write `"user"` (double-quoted) when selecting, grouping, joining, or filtering on this column — every recipe below uses the quoted form. The unquoted form returns the session-user string from the `current_user` builtin on every row instead of the table's column value; the symptom is "every row shows my name" rather than a hard error, so the bug is easy to miss.

**`system.runtime.tasks`** — one row per task per stage per worker for in-flight or recently-completed queries. Holds the byte/CPU counters. Columns:

```
physical_input_bytes, split_cpu_time_ms, processed_input_bytes,
node_id, task_id, stage_id, query_id, state,
splits, queued_splits, running_splits, completed_splits,
output_bytes, output_rows, physical_written_bytes,
created, start, last_heartbeat, end
```

Notable points: CPU time is `split_cpu_time_ms` (NOT `cpu_time_ms`). There is **no `peak_memory_bytes` column on tasks** — peak memory per query lives in JMX MBeans (`trino.execution:name=QueryManager`), not in `system.runtime.tasks`. The `query` SQL text is NOT on tasks; you must JOIN to `queries` to get it.

### Recipe 1 — Top 50 most expensive queries by bytes scanned

```sql
SELECT
  q.query_id,
  q.query,
  q."user",                                 -- "user" is a Trino reserved word — MUST be quoted
  SUM(t.physical_input_bytes) / 1e9       AS input_gb,
  SUM(t.split_cpu_time_ms) / 1000.0       AS cpu_sec,
  q.created,
  q.end
FROM system.runtime.queries q
JOIN system.runtime.tasks t ON q.query_id = t.query_id
WHERE q.state = 'FINISHED'
GROUP BY q.query_id, q.query, q."user", q.created, q.end
ORDER BY input_gb DESC
LIMIT 50;
```

This gives you the queries that pulled the most physical bytes from MinIO — usually the right ranking for "what costs us the most." Sort by `cpu_sec` instead if you suspect a CPU-bound query (heavy joins, aggregations) is the problem rather than I/O.

### Recipe 2 — Top high-frequency expensive queries (the dashboard-refresh killer)

A single 5-GB query is fine. The same 5-GB query running 200 times a day burns 1 TB of I/O daily for one dashboard. Group by query text to surface these patterns:

```sql
SELECT
  q.query,
  COUNT(*)                                              AS run_count,
  ROUND(AVG(t_agg.input_gb), 2)                         AS avg_input_gb,
  ROUND(COUNT(*) * AVG(t_agg.input_gb), 1)              AS total_gb_per_period
FROM system.runtime.queries q
JOIN (
  SELECT query_id, SUM(physical_input_bytes) / 1e9 AS input_gb
  FROM system.runtime.tasks
  GROUP BY query_id
) t_agg ON q.query_id = t_agg.query_id
WHERE q.state = 'FINISHED'
GROUP BY q.query
HAVING COUNT(*) > 10
ORDER BY total_gb_per_period DESC
LIMIT 20;
```

The `HAVING COUNT(*) > 10` filter excludes one-off ad-hoc queries; you want the *patterns* worth optimizing (e.g., a dashboard widget refreshing every 30 seconds). The `total_gb_per_period` column gives you the total work the cluster did for each query pattern over the visible window — that's the number to attack with a cache or rollup table.

### CRITICAL — `system.runtime.*` is EPHEMERAL

> **`system.runtime.queries` and `system.runtime.tasks` are in-memory views that live ONLY on the running coordinator process.** Every coordinator restart wipes them clean. The retention window is also bounded by `query.max-history` (default 100 queries) and `query.min-expire-age` (default 15 min) — queries are eligible for eviction once they exceed `query.min-expire-age` AND when `query.max-history` is exceeded, not strictly 15 minutes. There is no "6-month query history" available from `system.runtime.*`.
>
> For any historical analysis longer than a few hours — cost retrospectives, monthly tenant chargebacks, "what was that slow query last Tuesday?" forensics — you MUST configure a **Trino event listener** to persist `QueryCompletedEvent` records to durable storage. Trino ships with **four** built-in event listener plugins (verified against trino.io/docs/current/admin/event-listeners.html):
>
> - **HTTP event listener** (`event-listener.name=http`) — POSTs each `QueryCompletedEvent` as JSON to a configured HTTP endpoint. Good for shipping to an external collector (your logging stack, an internal API, a custom ingestion service).
> - **Kafka event listener** (`event-listener.name=kafka`) — publishes events to a Kafka topic. Best for high-throughput multi-coordinator setups; downstream Spark Structured Streaming consumers can land the events directly in an Iceberg observability table.
> - **MySQL event listener** (`event-listener.name=mysql`) — writes each event as a row into a MySQL database. Useful when you already operate MySQL and want SQL-queryable history without standing up Kafka.
> - **OpenLineage event listener** (`event-listener.name=openlineage`) — emits OpenLineage events for column-level lineage tracking. Useful if your org already runs Marquez or another OpenLineage backend.
>
> **There is NO built-in "file" event listener in Trino.** A common misconception is that `event-listener.name=file` ships out of the box and writes JSONL to local disk; it does not exist. The four plugins listed above are the only built-in choices. For local-disk JSONL output you would either (a) point the HTTP listener at a sidecar collector (e.g., Fluent Bit, Vector) that lands the events on disk, or (b) write a **custom event listener plugin** (`io.trino.spi.eventlistener.EventListenerFactory`) — a serious undertaking, not a config-only fix.
>
> Configure in `etc/event-listener.properties` on the coordinator (one file per listener; you can stack multiple by listing several `event-listener.config-files` paths in `config.properties`). Required for any non-trivial cost or performance retrospective work — without it, you can only see the last ~100 queries from `system.runtime.queries` before they're evicted.
>
> **CRITICAL — property prefix uses a hyphen, NOT a dot.** Each listener's properties use `<name>-event-listener.*` (hyphen), not `<name>.event-listener.*` (dot). Using the wrong delimiter causes Trino to reject the config file at startup with "configuration property not used" errors:
>
> ```properties
> # etc/http-event-listener.properties
> event-listener.name=http
> http-event-listener.connect-ingest-uri=http://audit-collector:8080/events   # hyphen, NOT http.event-listener.*
> http-event-listener.log-completed=true
> http-event-listener.log-created=false
>
> # etc/kafka-event-listener.properties
> event-listener.name=kafka
> kafka-event-listener.broker-endpoints=kafka1:9092,kafka2:9092              # NOT kafka.bootstrap.servers
> kafka-event-listener.completed-event.topic=trino-completed-queries          # NOT kafka.event-listener.topic
>
> # etc/mysql-event-listener.properties
> event-listener.name=mysql
> mysql-event-listener.db.url=jdbc:mysql://mysql-host:3306/trino_audit?user=u&password=p  # NOT mysql.event-listener.connection-url
> # NOTE: MySQL listener writes to a hard-coded table named `trino_queries` — the table name is NOT configurable.
> ```
>
> Register the listener file in `etc/config.properties`:
> ```properties
> event-listener.config-files=etc/http-event-listener.properties
> ```
>
> See the [Trino event listener docs](https://trino.io/docs/current/admin/event-listeners.html) for the full property reference. Once persisted, point your downstream pipeline at an Iceberg table (e.g., `iceberg.observability.trino_queries`) and rerun Recipes 1–2 above against the persistent table instead of `system.runtime.*`.

### Immediate remediation — kill a runaway query

Once a monitoring query identifies a single runaway (a query consuming most of cluster CPU/IO, blocking the queue, or stuck in `RUNNING` state for hours), you do not need to wait for it to finish or restart the cluster. Trino exposes a system procedure that cancels a specific query by ID:

```sql
-- Cancel a single runaway query identified from system.runtime.queries.
-- Use the query_id column value (string like '20260525_143012_00042_abcde').
CALL system.runtime.kill_query(query_id => '20260525_143012_00042_abcde');

-- Optional: include a message that will appear in the rejected query's
-- error metadata, so the user / dashboard owner understands why it died.
CALL system.runtime.kill_query(
  query_id => '20260525_143012_00042_abcde',
  message  => 'Killed by oncall — scanning entire fact table without partition filter'
);
```

**What this does:** the coordinator marks the query as `FAILED`, sends a cancel signal to every worker running the query's tasks, frees the memory and CPU slots, and unblocks any queued queries waiting for resources. The killed user sees an error in their client (the message you supplied, if any).

**What it does NOT do:** it does not blacklist the user, the SQL, or the source. The user can re-submit the same query immediately. Pair `kill_query` with a resource-group rule change (per-user concurrency cap, per-source memory limit) or a direct conversation with the dashboard owner — otherwise the same runaway re-spawns within minutes.

**Permissions:** the calling user needs the `kill_query` system privilege. In a hardened setup (the production stack uses OPA), this is typically granted only to the oncall service account or to users in an `sre-oncall` group via an OPA policy rule; regular analysts cannot kill arbitrary queries.

**Common oncall sequence:**

```sql
-- 1. Find the runaway (e.g., a query that's been RUNNING > 30 min and is scanning the most bytes).
--    NOTE: q."user" must be DOUBLE-QUOTED — `user` is a Trino reserved word; bare `user`
--    parses as the current-user keyword and the query fails with a syntax error.
SELECT
  q.query_id, q."user", q.source, q.query,
  date_diff('minute', q.started, current_timestamp) AS running_min,
  SUM(t.physical_input_bytes) / 1e9 AS gb_scanned_so_far
FROM system.runtime.queries q
JOIN system.runtime.tasks t ON q.query_id = t.query_id
WHERE q.state = 'RUNNING'
  AND q.started < current_timestamp - INTERVAL '30' MINUTE
GROUP BY q.query_id, q."user", q.source, q.query, q.started
ORDER BY gb_scanned_so_far DESC;

-- 2. Kill it.
CALL system.runtime.kill_query(
  query_id => '<query_id from step 1>',
  message  => 'Killed — exceeded 30 min runtime, scanning <N> GB without filter'
);

-- 3. Verify it's gone.
SELECT query_id, state, error_code FROM system.runtime.queries
WHERE query_id = '<query_id>';
-- state should now be 'FAILED' with an error_code indicating user-initiated cancellation.
```

This is the fastest way to restore cluster health when a single bad query is starving everyone else. Use it before reaching for cluster restart, worker scaling, or resource-group reconfiguration — those are appropriate for sustained issues, not for one bad query.

### What does "cost" mean on an on-prem stack?

Translation table for engineers used to cloud $/TB-scanned thinking:

| Cloud cost concept | On-prem (your stack) equivalent |
|---|---|
| BigQuery $/TB scanned | k8s vCPU-hours consumed by the Trino worker pods scanning that data |
| Snowflake warehouse credits | k8s RAM-GB-hours held by Trino workers (capacity reserved 24/7) |
| Auto-suspend savings | Scaling Trino workers down at night via k8s HPA (still need ≥1 for stragglers) |
| Per-user spend cap | Trino resource groups: per-tenant concurrency and memory caps |
| S3 GetObject cost | MinIO disk IOPS budget + on-prem network bandwidth between Trino and MinIO |
| Query timeout / spend brake | `query.max-execution-time`, `query.max-memory-per-node`, resource group `softMemoryLimit` |

The marginal dollar cost of one extra query on already-provisioned k8s + MinIO is effectively zero. What you actually pay is **k8s capacity reservation** (CPU/RAM the Trino pods hold) and **queueing latency** (when concurrent queries exceed worker capacity, the slow-feeling experience for everyone). Optimize for the second one: a query that's "free" but blocks 20 other queries for 5 minutes still has a real cost.

---

## Step 2: Determine if it's one query or all queries

**One specific query regressed**: Go to step 3 (file/partition analysis).

**All queries are slower**: Usually concurrency, memory pressure, or infrastructure change (new Kubernetes node, MinIO capacity, network). Check Trino worker health in the UI and verify MinIO is responding.

---

## Step 3: Run EXPLAIN ANALYZE on the slow query

```sql
EXPLAIN ANALYZE
SELECT tenant_id, COUNT(*) AS events
FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY tenant_id;
```

> **Note**: `EXPLAIN ANALYZE` **actually executes the query** to collect runtime stats — re-running a slow production query has the same resource cost as the original (full I/O, full CPU, full memory pressure on workers). For plan-only inspection without executing, use `EXPLAIN (TYPE DISTRIBUTED)` instead — it shows the fragment graph, exchange types, and join order without touching any data. Reserve `EXPLAIN ANALYZE` for queries you're willing to pay the cost of re-running (i.e., already-fast queries you want to characterize, or a slow query you're actively debugging and accept will burn cluster resources again).
>
> ```sql
> -- Plan only — cheap, does not execute the query.
> EXPLAIN (TYPE DISTRIBUTED)
> SELECT tenant_id, COUNT(*) AS events
> FROM iceberg.analytics.feature_usage
> WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
> GROUP BY tenant_id;
> ```

### What to look for

> **Field-name reality check (Trino 467).** Default `EXPLAIN ANALYZE` does **not** print a `Files:` line and does **not** have a `Wall time` field. Those names commonly show up in incorrect guides — using them in a real diagnosis will leave you searching for fields that aren't there. The actual fields on each operator are shown below.

A real Trino `EXPLAIN ANALYZE` operator block looks roughly like this (abbreviated):

```
Fragment 1 [SOURCE]
    CPU: 12.34s, Scheduled: 45.67s, Blocked: 30.12s (Input: 28.50s, Output: 1.62s)
    Input: 12500000 rows (450MB), Physical Input: 2.10GB
    ScanFilterProject[table = iceberg:analytics.feature_usage$data, ...]
        Input: 12500000 rows (450MB), Physical Input: 2.10GB
        CPU: 8.12s, Scheduled: 40.05s, Blocked: 29.80s
```

The fields you actually care about, and what each one tells you:

| Field | What it means | When it points to a problem |
|---|---|---|
| `CPU:` | Total CPU compute time across all workers for this operator | High CPU with low `Scheduled:` gap → compute-bound (heavy joins/aggregations) |
| `Scheduled:` | Total wall-clock time the operator was scheduled on workers | Use this (not "Wall time" — no such field exists) for end-to-end operator time |
| `Blocked: Input` / `Blocked: Output` | Time the operator spent waiting on upstream input or downstream output | High `Blocked: Input` → waiting on storage/upstream; high `Blocked: Output` → downstream backpressure |
| `Input:` | Logical rows and uncompressed size read by the operator | Compare to a known-good baseline; if it jumped 100x, a filter disappeared |
| `Physical Input:` | Actual bytes read from MinIO (compressed Parquet) | The right metric for "are we scanning too much from storage?" — this is where partition-pruning failures show up first |

**Compute-bound vs I/O-bound (the replacement for the old "Wall vs CPU" rule):**

- `Scheduled:` ≈ `CPU:` → **compute-bound**. Filters, joins, aggregations are the bottleneck. Look at join order, predicate pushdown, pre-aggregation.
- `Scheduled:` >> `CPU:` (e.g., 5–10x) → **I/O-bound** (worker is spending most of its scheduled time blocked, not computing). Either reading too many files, too many small files (metadata overhead), or MinIO is slow. Cross-check by looking at `Blocked: Input` and `Physical Input:`.

**Checking how many files were opened — NOT via default `EXPLAIN ANALYZE`.**

The default `EXPLAIN ANALYZE` does not surface per-split file counts. The file/manifest counters (`dataFiles`, `dataManifests`) are Iceberg split-source metrics that only appear under `EXPLAIN ANALYZE VERBOSE`. Two reliable options:

```sql
-- Option A: EXPLAIN ANALYZE VERBOSE — look in the Iceberg connector
-- split-source section for `dataFiles` and `dataManifests` counters.
EXPLAIN ANALYZE VERBOSE
SELECT tenant_id, COUNT(*) AS events
FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY tenant_id;

-- Option B: query the $files metadata table directly — works without
-- re-running the query and gives you a precise file count per partition spec.
SELECT spec_id, COUNT(*) AS file_count
FROM iceberg.analytics."feature_usage$files"
GROUP BY spec_id;
```

For day-to-day partition-pruning diagnosis, **`Physical Input:` from default `EXPLAIN ANALYZE` is usually enough**: if it shows 50 GB read for a query that should touch one day of data, pruning is broken regardless of the exact file count. Reach for `EXPLAIN ANALYZE VERBOSE` or `$files` when you specifically need to confirm a small-files problem (many files, low avg size) vs a wrong-filter problem (few files, large bytes per file).

**Interpreting `Physical Input:` for partition pruning:**

| Physical Input | What it means |
|---|---|
| ~1 day's worth × 90 (e.g., a few GB total) | Good — partition pruning working |
| ~100 GB on a query that should hit 90 days of one tenant | Bad — full table scan, partition pruning broken (filter on non-partition column?) |
| Reasonable bytes but high `Blocked: Input` and slow query | Possibly small-files problem — confirm via `$files` or `VERBOSE` |

If `Physical Input:` is much higher than expected: the WHERE clause isn't filtering on a partition column. See step 4.

---

## Step 4: Check partition pruning

### Verify the table's partition spec

```sql
SHOW CREATE TABLE iceberg.analytics.feature_usage;
```

Look for the `partitioning` clause. Example of well-partitioned table:
```
partitioning = ARRAY['day(event_date)', 'tenant_id']
```

**If there's no partitioning clause**: the table is unpartitioned. Every query scans every file. This needs a table rebuild with partitioning.

### Verify the WHERE clause uses partition columns

| Filter | Result |
|---|---|
| `WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY` | Prunes to 90 day-partitions |
| `WHERE tenant_id = 'acme'` (with tenant_id partition) | Prunes to acme files only |
| `WHERE feature_name = 'invite'` (non-partition column) | Full table scan |
| No WHERE clause | Full table scan |

**Common regression trigger**: a WHERE clause that previously used a partition column gets changed to use a derived value. Example: `WHERE DATE(event_time) = CURRENT_DATE` may not prune as well as `WHERE event_date = CURRENT_DATE` depending on how the column is typed. Check the exact column used in the filter against the partition spec.

---

## Step 5: Check for partition skew

Partition skew means one partition has far more data than others. Even with pruning working, a single oversized partition causes one Trino worker to do 100x the work of others.

### How to detect skew

```sql
-- How many rows per partition?
SELECT
  event_date,
  tenant_id,
  COUNT(*) AS row_count
FROM iceberg.analytics.feature_usage
WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
GROUP BY event_date, tenant_id
ORDER BY row_count DESC
LIMIT 20;
```

If one tenant_id has 200M rows and the others have 50K, that's 4,000x skew. All 200M rows land on one Trino worker; the others sit idle while that worker grinds.

### Fixes for skew

**If one tenant is enormous:**
- Create a dedicated table for that tenant: `feature_usage_acme`.
- Build a nightly rollup: one row per tenant/day/feature rather than one row per event.

**If dates are skewed (one day has 10x data):**
- Add a sub-partition (bucket by user_id hash): `partitioning = ARRAY['day(event_date)', 'bucket(user_id, 100)']`.
- This splits each day's data into 100 equal buckets, enabling parallel reads.

> **ENGINE NOTE — `bucket()` argument order differs between Trino and Spark SQL.** The snippet above is **Trino syntax**, where the column comes first: `bucket(column, N)`. If you run the equivalent DDL in Spark SQL, the argument order is **reversed**: `bucket(N, column)` — e.g., `PARTITIONED BY (days(event_date), bucket(100, user_id))`. Same Iceberg transform on disk; different SQL spelling. Pasting Trino's column-first form into Spark (or vice versa) gives you a parse error.

> **Partition-spec changes are NOT retroactive.** `ALTER TABLE iceberg.analytics.feature_usage SET PROPERTIES partitioning = ARRAY['day(event_date)', 'bucket(user_id, 100)']` (Trino) or the equivalent `ALTER TABLE ... SET PARTITION SPEC (...)` changes how **NEW data** is written — existing historical files keep their **old partition layout**. Queries must handle both old and new layouts simultaneously, which means partition pruning won't behave the way it would on a freshly-loaded table. Until existing data is rewritten under the new spec, the skew you were trying to fix is only fixed for newly-written data; historical partitions remain skewed.
>
> A full `CALL iceberg.system.rewrite_data_files(table => 'analytics.feature_usage')` (Spark) — which uses the **current** spec — is needed to re-layout existing data under the new spec. Until that rewrite completes, queries that scan historical data will continue to see the old layout. Note also the Trino limitation called out in resource 17: Trino's `OPTIMIZE` cannot use newly-added partition columns as predicates, so post-partition-evolution rewrites must run via Spark.

---

## Step 6: Check data model

### Query complexity as the root cause

Complex queries — many JOINs, subqueries, window functions over large datasets — take more CPU and memory than simple aggregations.

**Signs:**
- EXPLAIN ANALYZE shows many fragments with exchanges between them.
- CPU time is high (not I/O-bound).
- The query involves 3+ table JOINs.

**Fixes:**
- **Denormalize**: pre-join dimension tables into a wide fact table so queries don't join at query time. (See `08-schema-design-for-analytics.md`.)
- **Pre-aggregate**: compute the expensive aggregation nightly and store results in a rollup table. The dashboard query reads 10 rows instead of 1B.
- **Simplify the join order**: Trino's query planner is good but sometimes benefits from explicit hints; the larger table should appear first in the FROM clause.

### Missing or wrong filters

A query that used to filter `WHERE plan_type = 'enterprise'` and now doesn't — or one where the filter column changed — will scan the entire fact table instead of a slice.

**How to catch**: Compare the EXPLAIN ANALYZE `Input:` rows (and `Physical Input:` bytes) from a recent successful run vs. today's run. If `Input:` jumped from 5M to 500M rows — or `Physical Input:` jumped from 2 GB to 200 GB — a filter disappeared.

---

## Step 7: Check for small files (compaction fell behind)

If compaction jobs haven't run:
- Nightly ingestion writes 300 tiny files per day (one per micro-batch or Spark partition).
- After 30 days without compaction: 9,000 files for a 30-day range query.
- Each file open has 10–50 ms metadata overhead.
- 9,000 files × 30 ms = 4.5 minutes just opening files, before reading any data.

### Diagnose small files

```sql
-- Snapshot summary shows file count and row count per snapshot.
-- On Trino's $snapshots metadata table, file/row counts live INSIDE the
-- summary map (a map(varchar, varchar)) — NOT as top-level columns.
-- The top-level columns are: committed_at, snapshot_id, parent_id,
-- operation, manifest_list, summary.
SELECT
  snapshot_id,
  committed_at,
  operation,
  summary['total-data-files'] AS total_data_files,
  summary['added-data-files'] AS added_data_files,
  summary['total-records']    AS total_records
FROM iceberg.analytics."feature_usage$snapshots"
ORDER BY committed_at DESC
LIMIT 5;

-- If you want per-manifest file counts (added/existing/deleted), query
-- $manifests instead — that metadata table DOES expose them as columns:
SELECT
  added_data_files_count,
  existing_data_files_count,
  deleted_data_files_count
FROM iceberg.analytics."feature_usage$manifests";
```

If `total_data_files_count` (from `$manifests`) — or `summary['total-data-files']` (from `$snapshots`) — is in the tens of thousands and the table isn't huge, compaction is needed.

For more granular small-files diagnosis, use the `$files` and `$partitions` metadata tables — they expose per-file and per-partition detail that snapshot-level summaries hide:

```sql
-- File-size distribution per partition: identifies WHICH partitions have many small files,
-- which is what you actually need to know to plan a targeted compaction.
SELECT
  partition,
  count(*)                                       AS file_count,
  avg(file_size_in_bytes) / 1024 / 1024          AS avg_file_mb,
  min(file_size_in_bytes) / 1024 / 1024          AS min_file_mb,
  max(file_size_in_bytes) / 1024 / 1024          AS max_file_mb
FROM iceberg.analytics."feature_usage$files"
GROUP BY partition
ORDER BY file_count DESC
LIMIT 20;

-- $partitions gives a partition-level summary including record_count, file_count,
-- and total_size — useful for spotting both file-count skew AND row-count skew at once.
SELECT
  partition,
  record_count,
  file_count,
  total_size / 1024 / 1024 AS total_size_mb
FROM iceberg.analytics."feature_usage$partitions"
ORDER BY file_count DESC
LIMIT 20;
```

This is much more actionable than the snapshot-level `total-data-files` summary key — instead of "the whole table has 47,000 files," you see "partition `event_date=2026-04-12, tenant_id='acme'` alone has 8,200 files averaging 0.4 MB each," which tells you exactly where to point `rewrite_data_files` with a `where` clause. Pair this with the per-tenant compaction pattern in resource 17 to fix the worst offenders first without rewriting the entire table.

### Fix: run compaction

Compaction must run in Spark (not Trino):

```python
# Submit via spark-submit or Airflow DAG
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
      table => 'analytics.feature_usage',
      options => map(
        'target-file-size-bytes', '268435456',
        'min-input-files', '5'
      )
    )
""")  # Spark SQL only — does not work in Trino
```

After compaction: 9,000 files collapses to ~45 files (256 MB each for a 10 GB partition). File open overhead drops from 4.5 minutes to 2 seconds.

### Verify compaction ran

Check the maintenance schedule: is the nightly compaction Kubernetes CronJob still running? Check the job logs:

```bash
kubectl get cronjobs -n data-platform
kubectl logs -l job-name=iceberg-compaction -n data-platform --since=24h
```

If the CronJob is failing silently, queries degrade over days as small files accumulate.

---

## Step 8: Check data volume growth

Sometimes "performance regression" is actually "the table grew 3x last month." This isn't a bug — it's expected growth. But the query plan hasn't adapted.

### Detect growth

```sql
SELECT
  event_date,
  COUNT(*) AS daily_rows,
  SUM(COUNT(*)) OVER (ORDER BY event_date) AS cumulative_rows
FROM iceberg.analytics.feature_usage
WHERE event_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY event_date
ORDER BY event_date;
```

If rows per day jumped significantly (new customer, product launch, marketing campaign), the queries are doing more work — correctly. The fix is optimization, not a bug hunt:
- Pre-aggregate hot paths into rollup tables.
- Narrow time ranges in dashboard queries.
- Add caching at the application layer.

---

## Step 9: Memory pressure remediation (OOM errors)

When the symptom is `EXCEEDED_LOCAL_MEMORY_LIMIT` (a single worker ran out of its per-query memory budget) or `EXCEEDED_DISTRIBUTED_MEMORY_LIMIT` (the cluster-wide per-query memory cap was hit), you have three lever categories: **restructure the query**, **change the join distribution**, or **enable spill-to-disk as a safety net**. Try them in that order — the first two reduce peak memory; the third trades latency for not crashing.

### 9a. Change the join distribution: `join_distribution_type`

Trino's join planner picks how to route data across workers for each join. The choice is exposed as a session property you can set per-query, and it is often the cheapest fix for OOM on fact-to-dimension joins.

```sql
-- Set for the current session; applies to every join in queries that follow.
SET SESSION join_distribution_type = 'BROADCAST';

-- Let the cost-based optimizer decide based on table statistics (actual default):
SET SESSION join_distribution_type = 'AUTOMATIC';

-- Force a hash-partitioned shuffle on both sides:
SET SESSION join_distribution_type = 'PARTITIONED';
```

The three modes:

| Mode | What Trino does | Best for |
|---|---|---|
| `AUTOMATIC` (default) | Trino's cost-based optimizer (CBO) picks `BROADCAST` or `PARTITIONED` per join based on table statistics collected by `ANALYZE TABLE`. Falls back to `PARTITIONED` when stats are missing or stale. | The default for any cluster where `ANALYZE TABLE` is run regularly on Iceberg tables — let the planner choose. |
| `PARTITIONED` | Hash both sides of the join on the join key and shuffle each side across workers so matching keys land on the same worker. Every worker holds a slice of both sides. | Large-to-large joins where neither side fits in a single worker's memory. The price is a full network shuffle. Also the fallback when CBO has no stats. |
| `BROADCAST` | Send a **full copy of the build side** (the smaller table) to **every worker**. Each worker then joins its local slice of the probe side (the larger table) against the full build side in memory. No shuffle of the probe side. | Fact-to-dimension joins where the dimension fits in worker memory. Typical example: a 100K-row `tenants` dimension joined against a 300M-row `events` fact. |

**"Shouldn't Trino be smart enough to pick the right join?"** Yes — `AUTOMATIC` mode is exactly that, but it needs **table statistics** to make the right call. The CBO uses row counts, column NDV (number of distinct values), null fractions, and data sizes — all populated by running `ANALYZE TABLE iceberg.analytics.feature_usage` (and for the dimension side too). When those stats are absent or stale (e.g., you wrote a million new rows since the last ANALYZE), the optimizer can't tell which side is smaller and falls back to `PARTITIONED` even when `BROADCAST` would have been dramatically better. **First-line fix when you see an unexpected `PARTITIONED` plan on an obvious fact-to-dim join: run `ANALYZE TABLE` on both tables, then re-EXPLAIN.** Only force `'BROADCAST'` manually when stats are correct but the planner still chooses wrong (rare), or when ANALYZE isn't feasible.

**Why BROADCAST helps with OOM on fact-to-dimension joins.** Under `PARTITIONED`, every worker builds a partial hash table on the fact side and waits for the dimension shuffle — peak memory per worker scales with the fact-side hash plus its share of the dimension. Under `BROADCAST`, every worker receives the full dimension once (small, fixed memory cost), then streams its local fact partition through the join without building a fact-side hash at all. Peak memory per worker drops from "fact-side hash + dimension share" to "full dimension + streaming probe" — usually much smaller when the dimension is small.

**Concrete sizing rule of thumb:** if the smaller side fits comfortably in `query.max-memory-per-node` (e.g., a 100 MB hash table on workers with a multi-GB per-node memory budget), BROADCAST is safe and usually faster. If the smaller side is in the gigabytes and starts pushing into half of `query.max-memory-per-node`, stay on PARTITIONED — broadcasting it to every worker would blow memory on each one. Note: `query.max-memory-per-node` defaults to **20% of the JVM max heap** (not a fixed 4 GB) — on a worker with a 32 GB heap, that's ~6.4 GB; on 16 GB heap, ~3.2 GB. Check the actual value in your `etc/config.properties` (or the rendered config in the worker pod) before sizing the broadcast threshold.

**Syntax options:**

```sql
-- Session-scoped (applies to all queries in the session until UNSET or session ends):
SET SESSION join_distribution_type = 'BROADCAST';

SELECT t.name, COUNT(*) AS event_count
FROM iceberg.analytics.feature_usage f
JOIN iceberg.analytics.tenants t ON f.tenant_id = t.tenant_id
WHERE f.event_date >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY t.name;

-- To revert to default within the same session:
RESET SESSION join_distribution_type;
```

You can also set it at the user / source / catalog level via Trino session-property defaults if a specific dashboard always benefits — but session-scoped is the right starting point for ad-hoc OOM remediation.

### 9b. Spill-to-disk: the safety net when nothing else works

When you cannot restructure the query (the SQL is owned by a third-party BI tool, or the workload is legitimately too large), and `join_distribution_type` doesn't help (e.g., the OOM is in an aggregation or both join sides are large), Trino's **spill-to-disk** feature lets workers offload intermediate operator state to local disk instead of OOM-killing the query.

**What spill-to-disk does:** when a memory-hungry operator exceeds the worker's memory budget, instead of failing the query, Trino writes the operator's intermediate state (hash tables, sort buffers, aggregation accumulators) to local disk and resumes execution against the spilled data. The query completes — slower than in-memory, but it completes instead of crashing.

**Trade-off:** spilling is meaningfully slower than in-memory execution (disk I/O is orders of magnitude slower than RAM). It is a **correctness mechanism, not a performance optimization**. Use it as the safety valve for queries that would otherwise OOM-kill, not as a substitute for tuning.

**Operations that support spilling:** joins (inner and outer hash joins on the build side), aggregations (final and partial), `ORDER BY` (sort), and window functions. Not all operators support spilling — Trino logs an "operator does not support spilling" warning for unsupported cases.

**When to use spill on this stack (Trino 467 on Kubernetes, workers have local ephemeral disk):**

| Situation | Reach for spill? |
|---|---|
| Workers can autoscale horizontally and you have unused capacity | No — scale the cluster instead. Spill is for when you can't add workers. |
| On-prem k8s where worker pods can't scale on demand (fixed Helm-chart replica count, no HPA tuned for this workload) | **Yes** — spill is the right overflow valve. |
| Query can be restructured (add a partition filter, pre-aggregate, use BROADCAST) | No — fix the query first; spill is the last resort. |
| BI-tool query you don't own and can't change, repeatedly OOMs on month-end | **Yes** — enable spill so the report completes, then chase the BI team to optimize separately. |
| One-off ad-hoc analyst query that's "supposed to be slow" but should still succeed | **Yes** — let it spill and finish in 20 minutes instead of failing after 12. |

**How to enable spill (cluster-level config, requires worker restart):**

Spill must be enabled in `config.properties` on every worker node (the coordinator does not run query operators, so the coordinator config does not need it). A rolling worker restart picks up the change:

```properties
# /etc/trino/config.properties on every worker — requires worker restart.
spill-enabled=true
spiller-spill-path=/var/trino/spill
```

The `spiller-spill-path` is mandatory when `spill-enabled=true`. On Kubernetes, point this at a path backed by the pod's ephemeral local disk (an `emptyDir` volume or a hostPath mount, depending on your Helm chart). Do NOT point it at network-mounted storage (NFS, MinIO via FUSE) — spill is high-throughput sequential I/O and network-mounted disks make spill slower than just failing the query.

**Key properties to tune:**

| Property | Default | Meaning |
|---|---|---|
| `spill-enabled` | `false` | The master switch. Spilling is off by default; you must set this to `true` to enable any spilling at all. |
| `spiller-spill-path` | (none — required) | Filesystem path(s) Trino writes spilled pages to. Comma-separate multiple paths to stripe across disks (e.g., `/mnt/disk1/spill,/mnt/disk2/spill`) — Trino round-robins between them for better throughput. |
| `spill-compression-codec` | `NONE` | Compression for spilled pages. Options: `NONE`, `LZ4`, `ZSTD`. `LZ4` is usually worth it — small CPU cost for ~2x reduction in disk write volume. Use `ZSTD` for higher compression at higher CPU cost when disk bandwidth is the bottleneck. |
| `max-spill-per-node` | `100GB` | Aggregate spill across ALL queries on one node. Once hit, new spill requests fail and the query OOMs anyway. Raise if you have plenty of local disk and want a larger safety margin. |
| `query-max-spill-per-node` | `100GB` | Per-query spill limit on one node. Prevents a single runaway query from filling the spill disk and starving every other concurrent query. |

**Typical production setup on the on-prem k8s + Trino 467 stack:**

```properties
# Worker config.properties — production-ready spill config.
spill-enabled=true
spiller-spill-path=/var/trino/spill
spill-compression-codec=LZ4
max-spill-per-node=200GB
query-max-spill-per-node=50GB
```

The 50 GB per-query cap prevents one bad query from consuming all 200 GB and OOM-killing every other concurrent query when their turn to spill arrives. Size both numbers based on your actual local-disk capacity per pod — leave at least 20–30% headroom for the rest of the pod's filesystem usage.

**Verify spill is working.** After enabling and restarting workers, run a query you expect to spill and check the Trino UI's query detail view — there's a "Spilled Data Size" field per operator. If it shows non-zero bytes, spilling fired correctly. JMX MBean `trino.execution:name=SpillerStats` exposes cluster-wide spill counters for Prometheus scraping.

**Spill vs restructuring — the prioritization rule.** Always try in this order:
1. **Restructure the query**: add a partition filter, pre-aggregate, narrow the time range, denormalize. Eliminates the memory pressure entirely.
2. **Change `join_distribution_type`**: cheapest tuning knob for fact-to-dimension OOM. Session-scoped, reversible, no cluster config change.
3. **Enable spill**: cluster-level config change for the workloads that can't be restructured. Use as the safety net; don't let it become the default crutch.

On a stack where workers cannot scale horizontally on demand (the production setup here: on-prem k8s with fixed worker replica counts), spill is the **right** overflow valve for legitimately-large queries that you can't restructure away. The trade-off is real (slower) but bounded; the alternative (OOM-kill and a user-facing failure) is worse.

---

## Oncall runbook summary

| Symptom | First check | Likely fix |
|---|---|---|
| All queries slow simultaneously | Trino UI — concurrent query count | Stagger refreshes, resource groups |
| One query slow, others fine | EXPLAIN ANALYZE `Physical Input:` (and `$files` / `EXPLAIN ANALYZE VERBOSE` for file count) | Add partition filter, run compaction |
| One query stuck RUNNING for hours, blocking the queue | `system.runtime.queries` JOIN `system.runtime.tasks` filtered to `state='RUNNING'` and long `running_min` | `CALL system.runtime.kill_query(query_id => '...')` — see Immediate remediation section above |
| Slow after midnight | Compaction CronJob logs | Fix the CronJob, run compaction manually |
| Slow for one tenant | Row count by tenant | Dedicated table or nightly rollup |
| OOM errors (`EXCEEDED_LOCAL_MEMORY_LIMIT`) | `query.max-memory-per-node` hit on one worker | Narrow query scope, pre-aggregate, add partition filters. For fact-to-dim joins: `SET SESSION join_distribution_type = 'BROADCAST'`. Safety net: enable spill-to-disk (`spill-enabled=true`). See Step 9. |
| OOM errors (`EXCEEDED_DISTRIBUTED_MEMORY_LIMIT`) | `query.max-memory` cluster-wide limit hit | Same as above; or increase `query.max-memory` if query is legitimately large. See Step 9 for BROADCAST joins and spill config. |
| Slow after data model change | EXPLAIN ANALYZE `Input:` rows and `Physical Input:` bytes | Compare filter coverage before/after |
| Slow for all tenants, one table | Snapshot metadata file count | Run compaction in Spark |

---

## Key concepts

**Query concurrency**: Number of queries running simultaneously. Each additional query shares the same worker CPU and memory.

**Query frequency**: How often the same query runs. High frequency × high cost = sustained cluster load.

**Partition pruning**: Trino's ability to skip data files where the partition column value can't match the WHERE clause. Only works if you filter on a partition column.

**Partition skew**: One partition having dramatically more rows than others. Causes one worker to do most of the work while others idle.

**Small files problem**: Many tiny Parquet files (< 32 MB) accumulated from frequent small writes. Metadata overhead per file turns into minutes of I/O overhead at query time.

**Compaction**: Merging small files into larger ones (128–512 MB). Must run in Spark via `CALL iceberg.system.rewrite_data_files()`.

**Data model regression**: A query that previously hit a narrow, pre-joined table now hitting raw tables with multiple joins — often introduced by a schema migration or new feature.
