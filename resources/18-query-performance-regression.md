# Query Performance Regression Diagnosis

A guide for SaaS engineers and oncall members investigating why analytics queries suddenly got slower on the Trino 467 + Iceberg + MinIO stack.

---

## Quick Reference: Key Terms (EXPLAIN ANALYZE vocabulary)

When you read Trino's EXPLAIN ANALYZE output, you'll hit these terms. Definitions you can use as a runtime crib sheet:

| Term | One-line meaning |
|---|---|
| **Fragment** | A unit of parallelism in Trino; a query compiles into fragments that run in parallel (e.g., `Fragment 0` = coordinator output, `Fragment 1` = source scan, `Fragment 2` = aggregation). |
| **Exchange** | Operator that moves data between fragments/workers. `RemoteExchange` crosses the network between workers; `LocalExchange` stays inside one worker (cheap). |
| **REPARTITION** | Exchange type that **hash-distributes rows by a key** (used for GROUP BY and distributed/hash joins) — every row goes to exactly one downstream worker chosen by hash(key). |
| **REPLICATE** | Exchange type that **copies all rows to every worker** (used for broadcast joins) — fast when the replicated side is small, OOM risk when it's not. |
| **CPU time** | Compute-only time (excludes waits). When CPU ≈ Scheduled, the operator is **compute-bound** (more cores would help). |
| **Scheduled time** | Wall-clock time for the operator including waits. When Scheduled >> CPU, the operator is **I/O-bound or network-bound** (waiting on data or downstream consumers). |
| **Blocked Input / Blocked Output** | Time waiting on upstream/downstream operators. Blocked Input = waiting for data from upstream; Blocked Output = downstream consumer is slow. |

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

### `EXPLAIN TYPE IO` and `EXPLAIN TYPE VALIDATE` — the two other EXPLAIN variants you should know

> **One-sentence summary:** `EXPLAIN (TYPE DISTRIBUTED)` is the everyday plan-only inspector you already know; **`EXPLAIN (TYPE IO, FORMAT JSON)`** answers "which tables/columns/partitions will this query touch and what predicates will hit them" (impact analysis without running the query); **`EXPLAIN (TYPE VALIDATE)`** answers "does this query parse and resolve against the catalog without executing" (a cheap pre-flight check). **Verified against [Trino EXPLAIN docs](https://trino.io/docs/current/sql/explain.html).**

The full set of `EXPLAIN TYPE` modes in Trino 467:

| Type | What it does | When to reach for it |
|---|---|---|
| `TYPE LOGICAL` | Single-fragment plan tree (pre-distribution). Concise but doesn't show exchange boundaries. | Quick sanity check on join order and predicate placement. |
| `TYPE DISTRIBUTED` (the everyday one) | Multi-fragment plan with exchange operators and distribution choices. Shows REPARTITION vs REPLICATE, dynamic filter wiring, predicate pushdown signatures. | Default plan-only inspection. Use 90% of the time. |
| `TYPE IO, FORMAT JSON` | JSON describing the input/output tables, columns accessed, column-level constraints (predicates pushed down), and estimated row counts per table scan. | **Impact analysis** — "what does this query touch?" Useful for change-impact review before running an unknown query on prod, for governance audits (which columns will the query read?), and for catalog observability. |
| `TYPE VALIDATE` | Returns a single boolean column `Valid`. Parses the SQL, resolves identifiers against the catalog, and confirms the query plans — without executing. Errors out on missing tables, type mismatches, or unresolvable references. | **Pre-flight check** — validate a generated SQL string (e.g., from a templating engine, BI tool, or user input) before exposing it to the cluster. Cheaper than `EXPLAIN DISTRIBUTED` because the optimizer doesn't have to produce a full plan. |

**`EXPLAIN (TYPE IO, FORMAT JSON)` — worked example.**

```sql
EXPLAIN (TYPE IO, FORMAT JSON)
SELECT tenant_id, SUM(amount)
FROM iceberg.analytics.orders
WHERE order_date BETWEEN DATE '2026-05-01' AND DATE '2026-05-31'
  AND tenant_id = 'acme'
GROUP BY tenant_id;
```

Returns a JSON object that looks (abbreviated) like:

```json
{
  "inputTableColumnInfos": [{
    "table": {
      "catalog": "iceberg",
      "schemaTable": {"schema": "analytics", "table": "orders"}
    },
    "columnConstraints": [
      {
        "columnName": "order_date",
        "type": "date",
        "domain": {
          "nullsAllowed": false,
          "ranges": [{"low": {"value": "2026-05-01", "bound": "EXACTLY"},
                      "high": {"value": "2026-05-31", "bound": "EXACTLY"}}]
        }
      },
      {
        "columnName": "tenant_id",
        "type": "varchar",
        "domain": {
          "nullsAllowed": false,
          "ranges": [{"low": {"value": "acme", "bound": "EXACTLY"},
                      "high": {"value": "acme", "bound": "EXACTLY"}}]
        }
      }
    ],
    "estimate": {"outputRowCount": 1.4E6, "outputSizeInBytes": 4.2E7}
  }],
  "outputTable": null
}
```

**Reading this output:**
- `inputTableColumnInfos[].table` — the tables this query will read. **Impact analysis: what does this query touch?** For an unknown query you've been asked to review, this is the fastest way to confirm it doesn't accidentally scan a sensitive table.
- `columnConstraints[].domain` — the predicates that Trino has resolved into ranges. **The presence of a `domain` with `EXACTLY` bounds confirms predicate pushdown** at plan time. If a predicate you wrote does NOT appear here, it didn't push down — Trino will filter on the worker side instead of asking the connector to filter.
- `estimate.outputRowCount` — CBO estimate of how many rows this table scan will produce after the predicates apply. Compare to the table's total row count to gauge selectivity.
- `outputTable` — null for `SELECT`; populated for `INSERT` / `CREATE TABLE AS` to show the write target.

**`EXPLAIN (TYPE VALIDATE)` — worked example.**

```sql
-- Valid query — returns Valid: true.
EXPLAIN (TYPE VALIDATE)
SELECT tenant_id, COUNT(*)
FROM iceberg.analytics.orders
WHERE order_date >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY tenant_id;
-- Result: a single column 'Valid' with value 'true'.

-- Invalid query — errors at validation, not execution.
EXPLAIN (TYPE VALIDATE)
SELECT tnant_id, COUNT(*)            -- typo: 'tnant_id' not 'tenant_id'
FROM iceberg.analytics.orders
GROUP BY tnant_id;
-- Result: error 'Column tnant_id cannot be resolved'.
```

**Why this is cheap.** `TYPE VALIDATE` stops after parse + identifier resolution + type checking — it does NOT produce a distributed plan, does NOT run the CBO, does NOT touch any data. On a query that takes 2 seconds to `EXPLAIN DISTRIBUTED`, `EXPLAIN VALIDATE` returns in < 50 ms.

**When to use each in practice:**

| Scenario | Reach for |
|---|---|
| "Why is this query slow?" — performance debugging | `EXPLAIN ANALYZE` (runs the query) or `EXPLAIN (TYPE DISTRIBUTED)` (plan only) |
| "Does this generated SQL even parse?" — before submitting templated SQL to the cluster | `EXPLAIN (TYPE VALIDATE)` — fastest sanity check |
| "What tables/columns does this query touch?" — impact analysis, governance, change review | `EXPLAIN (TYPE IO, FORMAT JSON)` — answers via the `inputTableColumnInfos` array |
| "Did my predicate push down?" — pushdown debugging | `EXPLAIN (TYPE DISTRIBUTED)` (look for `constraint=` on TableScan) AND/OR `EXPLAIN (TYPE IO, FORMAT JSON)` (look for `domain` ranges in `columnConstraints`) |
| "Will this query hit a sensitive column?" — pre-submit access-control review | `EXPLAIN (TYPE IO, FORMAT JSON)` — explicit list of accessed columns |

**Format options for `TYPE IO`:** the only documented format is `FORMAT JSON`. Trino does NOT support a text form for `TYPE IO` output — always write `EXPLAIN (TYPE IO, FORMAT JSON) <query>` exactly.

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

### Detecting GROUP BY skew with EXPLAIN ANALYZE VERBOSE (per-driver distribution)

Default `EXPLAIN ANALYZE` aggregates stats across all drivers per operator, which **hides skew**: one driver doing 100x the work of others looks the same as evenly-distributed work because the totals are summed. To see per-driver distribution, you need `EXPLAIN ANALYZE VERBOSE`.

```sql
EXPLAIN ANALYZE VERBOSE
SELECT tenant_id, COUNT(*) AS event_count
FROM iceberg.analytics.feature_usage
WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
GROUP BY tenant_id;
```

In the VERBOSE output, look at the **Aggregation** operator's per-driver stats — VERBOSE prints `inputRows`, `inputBytes`, `cpuTime`, and `wallTime` distributions across drivers (min / p50 / max). The telltale signs of GROUP BY skew:

| What you see | What it means |
|---|---|
| `inputRows` max ≈ 100x p50 across drivers on the Aggregation operator | One driver is processing the whale tenant; the rest finish quickly and idle. Classic whale-tenant skew. |
| `cpuTime` max >> p50 on Aggregation | Same — the skewed driver burns all the CPU; query wall time = the slowest driver's wall time. |
| `maxDriversPerTask` is low (e.g., 4) and you have skew | Even fewer drivers to spread work across. Bumping driver parallelism alone won't fix whale skew, but very low driver counts amplify the symptom. |
| Final aggregation has 1 driver but partial aggregation has N drivers | Expected — final aggregation merges partials at the coordinator. Skew problems live in the PARTIAL aggregation stage, not the FINAL. |

If the Aggregation operator's per-driver `inputRows` is roughly even (min ≈ p50 ≈ max), you do NOT have skew — go look elsewhere (compaction, partition pruning, concurrency). If max is 10-100x p50, you have skew and the fixes below apply.

### Fixes for skew

#### Fix 1 (primary fix for whale-tenant GROUP BY skew): two-level GROUP BY with a salt column

The canonical fix when one tenant dominates a GROUP BY is to **break that tenant's rows across N workers by adding a random salt**, aggregate first by `(tenant_id, salt)`, then merge the N partial results by `tenant_id`. The first aggregation distributes the whale's rows across N workers (no single worker holds them all); the second aggregation merges N partial counts per tenant, which is cheap because it's only N rows per tenant regardless of the tenant's row count.

```sql
-- Two-level GROUP BY: breaks whale-tenant skew at READ time.
-- Step 1: First-level aggregation with salt — distributes the whale across N workers.
WITH salted AS (
  SELECT
    tenant_id,
    CAST(FLOOR(RANDOM() * 8) AS BIGINT) AS salt,   -- 8 = number of worker buckets to spread across
    event_count
  FROM iceberg.analytics.feature_usage
  WHERE event_date = CURRENT_DATE - INTERVAL '1' DAY
),
partial AS (
  SELECT tenant_id, salt, COUNT(*) AS partial_count
  FROM salted
  GROUP BY tenant_id, salt                          -- N partial rows per tenant, distributed across workers
)
-- Step 2: Final aggregation merges the N partial counts per tenant. Cheap — only N rows per tenant.
SELECT tenant_id, SUM(partial_count) AS total_count
FROM partial
GROUP BY tenant_id;
```

**How to pick N (the salt cardinality):** N should roughly equal the number of Trino worker drivers available for the Aggregation stage. Too small (N=2) and you don't spread the whale enough; too large (N=1000) and the partial aggregation produces 1000 rows per tenant, which adds memory and shuffle overhead with no further skew benefit. Start with N = (number of workers × `task.concurrency`); typical values land at 8-32. Verify with `EXPLAIN ANALYZE VERBOSE` after — per-driver `inputRows` on the partial Aggregation operator should be roughly even.

**Works for SUM/COUNT/MIN/MAX (all algebraic aggregates).** For non-algebraic aggregates like `COUNT(DISTINCT col)` or `APPROX_DISTINCT`, the salt trick needs care — `SUM(partial_count)` over distinct-counts double-counts values that appear in multiple salt buckets. For exact distinct counts on whale tenants, use `approx_distinct(col)` (HyperLogLog-based, mergeable) at the partial level and merge with `approx_distinct` again at the final level, or fall back to fix 3 below (pre-aggregated rollup tables).

#### Fix 2: dedicated table for the whale tenant

For a single tenant that's persistently 100-1000x larger than others (an enterprise account, a noisy bot, etc.), the cleanest fix is to write that tenant to its own Iceberg table — `feature_usage_acme` — and route queries that filter on `tenant_id = 'acme'` to the dedicated table. The application or a thin SQL view picks the right table at query time. This trades schema complexity for fully-parallel scans on both the whale and the rest of the population. Best when there are only a handful of whales (≤5) and they're stable.

#### Fix 3: nightly pre-aggregated rollup

Build a daily rollup (one row per `tenant_id` × `event_date` × `feature_name`) via a nightly Spark job. Dashboards that ask "total events per tenant per day" then read 10K rows from the rollup instead of scanning 200M rows from the raw fact table. The whale stops being a hot path because the per-tenant rollup row is the same size regardless of how many events the tenant generated. Best for high-frequency dashboard queries where 5-15 minute staleness is acceptable. See `08-schema-design-for-analytics.md` for the rollup table pattern.

#### What about `bucket(tenant_id, N)` — does that fix GROUP BY skew? NO.

> **Critical clarification — bucket partitioning does NOT fix read-time GROUP BY skew.** A common (wrong) instinct is "we have one giant tenant, let's bucket the partition spec by `tenant_id` to spread it across files: `partitioning = ARRAY['day(event_date)', 'bucket(tenant_id, 64)']`." This does NOT solve whale-tenant GROUP BY skew, because Iceberg's `bucket()` transform **hashes each distinct value to exactly one bucket**. All rows for `tenant_id='acme'` still hash to the same bucket and still land on the same worker at GROUP BY time. The hash partitions the *set of tenants* across 64 buckets — not the rows of a single tenant.
>
> What `bucket(tenant_id, N)` actually achieves:
> - **WRITE side**: distributes write load across N buckets — useful when many tenants write concurrently and you want to spread ingestion across files (reduces small-files on writes, balances Spark task output).
> - **READ side, multi-tenant aggregation**: distributes the *scan* across workers when many tenants are queried together — e.g., a cross-tenant `GROUP BY plan_type` benefits because the 64 buckets read in parallel.
> - **READ side, whale tenant**: does NOTHING. One tenant's rows still hash to one bucket, so one worker still processes them at GROUP BY time.
>
> For the whale-tenant case, reach for **fix 1 (salt + two-level GROUP BY)**, **fix 2 (dedicated table)**, or **fix 3 (rollup)** — not bucketing.

#### Fix 4: bucket sub-partitioning when DATES are skewed (not tenants)

If the skew is on the time axis — one day has 10x the rows because of a product launch or campaign — adding a bucket sub-partition spreads each day's data across N parallel files. Here bucketing helps because the skew is in the cardinality of users-within-a-day (many users, not one whale), so `bucket(user_id, 100)` distributes them evenly:

```sql
-- Trino DDL: column-first bucket syntax.
ALTER TABLE iceberg.analytics.feature_usage
  SET PROPERTIES partitioning = ARRAY['day(event_date)', 'bucket(user_id, 100)'];
```

This splits each day's data into 100 equal buckets, enabling parallel reads when scanning a single day. Use this only when you have many users-per-day and the skew is at the day level, not when one tenant dominates.

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

### 9c. `SPILL_FAILED` error code — when spill itself runs out of disk

> **One-sentence summary:** `SPILL_FAILED` (an `INTERNAL_ERROR` subclass in Trino) means "the query needed to spill but the spill operation itself failed" — usually because the spill path's local disk is full, the path is not writable, or the per-query / per-node spill cap was exceeded. **Verified against [Trino spill-to-disk admin docs](https://trino.io/docs/current/admin/spill.html) and [Trino spilling properties](https://trino.io/docs/current/admin/properties-spilling.html).**

`SPILL_FAILED` is the failure mode you see **after** enabling `spill-enabled=true`. The query was going to OOM, Trino tried to spill it, and the spill itself failed — so the query died anyway, often with a confusing dual-symptom ("we enabled spill but it still failed!"). The root causes are operational, not configuration-level.

**The five concrete root causes (in order of frequency on this stack):**

| Root cause | Symptom | Fix |
|---|---|---|
| **Spill path's local disk is FULL** | `SPILL_FAILED: No space left on device` in the worker log; `df -h /var/trino/spill` on the worker pod shows `Use% = 100%`. | Free disk on the spill path (a previous spill session may have left orphan spill files — `ls /var/trino/spill/`). For k8s `emptyDir` volumes, the cause is usually the pod's ephemeral storage limit. Raise the ephemeral-storage request/limit on the worker pod spec, or move the spill path to a hostPath with more room. |
| **`max-spill-per-node` exceeded by aggregate spill across concurrent queries** | `SPILL_FAILED: Total spill size for node exceeds limit X bytes`; one query is fine in isolation but fails when run alongside other spilling queries (e.g., during a busy dashboard refresh window). | Raise `max-spill-per-node` (default `100GB`) if you have local disk room, or stagger the workload via session-level `query_priority` so the spilling queries don't all hit the cap at once. |
| **`query-max-spill-per-node` exceeded by a single runaway query** | `SPILL_FAILED: Query spill size for node exceeds limit X bytes`; one specific query consistently fails while others succeed. | This is usually the right behavior — the query is genuinely too large for spill on a single node. Either restructure the query (Step 9a/9b above) or raise `query-max-spill-per-node` from the default `100GB`. **Do not blindly raise both caps** — they protect concurrent queries from being starved by one runaway. |
| **60 GB disk-cap-on-pod symptom (the on-prem k8s footgun)** | `SPILL_FAILED` reliably at ~60 GB of spill per worker pod, regardless of how much `max-spill-per-node` you set; symptom matches the pod's `ephemeral-storage` limit in the Helm chart, not Trino's config. | Check `kubectl describe pod trino-worker-N | grep -A3 'ephemeral-storage'`. If the pod has `ephemeral-storage: 64Gi` and the spill path uses `emptyDir` (which counts against ephemeral-storage), Trino's spill is limited by the pod limit, not by `max-spill-per-node`. **Two fixes:** (a) raise the pod's `ephemeral-storage` limit in the Helm values, OR (b) mount the spill path as a hostPath / PVC on each worker (NOT counted against pod ephemeral-storage limits). |
| **Spill path is read-only or wrong permissions** | `SPILL_FAILED: Permission denied: /var/trino/spill/...`; usually after a Helm-chart upgrade that changed the worker pod's `securityContext.runAsUser`. | Verify the spill path is writable by the Trino process UID: `kubectl exec trino-worker-0 -- ls -la /var/trino`. The directory should be owned by the user Trino runs as (typically `trino` or UID 1000). Fix via init container that `chown`s the path, or by aligning the Helm `securityContext` with the spill path's ownership. |

**Diagnostic recipe — `SPILL_FAILED` on Trino 467:**

```bash
# Step 1: confirm the spill path's free disk on a worker pod.
kubectl exec -it trino-worker-0 -- df -h /var/trino/spill
# Look for "Avail" near zero or "Use% = 100%".

# Step 2: list any orphan spill files (Trino normally cleans them up; failures leave them behind).
kubectl exec -it trino-worker-0 -- ls -la /var/trino/spill/
# Files older than your longest-running query are probably orphans — safe to delete with the worker NOT actively spilling.

# Step 3: check the pod's ephemeral-storage limit (the most common on-prem k8s footgun).
kubectl describe pod trino-worker-0 | grep -A2 'ephemeral-storage'
# If this is set lower than max-spill-per-node, the pod limit wins.

# Step 4: check the recent spilling-query JMX counters (cluster-wide).
# trino.execution:name=SpillerStats exposes:
#   - SpillCount  -- total spill operations
#   - SpilledBytes -- bytes spilled (per node)
#   - SpillFailures -- count of SPILL_FAILED errors
# Scrape via Prometheus / JMX exporter; alert when SpillFailures > 0 over a 5-minute window.
```

**Why this matters operationally:** spill is the safety net for OOM. When spill itself fails, the query falls all the way through — Trino has no further fallback. The user sees `Query failed (SPILL_FAILED)` and you see a sad worker log. **On this stack (on-prem k8s, fixed worker pod size, no autoscale), `SPILL_FAILED` is one of the few errors you cannot solve by "running the query again later"** — the disk pressure that caused it persists until you free space or raise the limits.

**Preventive monitoring (Prometheus alerts to set up before this bites you):**

- `node_filesystem_avail_bytes{mountpoint="/var/trino/spill"} / node_filesystem_size_bytes` < 20% → page-out warning.
- `trino_execution_SpillerStats_SpillFailures` > 0 over a 5-minute window → page on the next failure.
- Pod-level `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes` > 80% on worker pods using `emptyDir` for spill → ephemeral-storage limit approaching.

---

## Step 10: Trino native file system cache (local disk caching of Parquet data blocks)

If repeated dashboard queries keep scanning the same hot partitions — the same last-7-days of events, the same tenant's data, the same dimension tables — you can reduce MinIO round-trips by enabling Trino's built-in file system data cache. This caches actual Parquet data blocks on each worker's local disk so the second and subsequent reads of the same file go to local SSD instead of MinIO.

**This is Trino's native implementation.** It does NOT require Alluxio as a separate service. The feature was added in approximately Trino 400+ and is available on Trino 467.

### What it does and when it helps

The file system cache intercepts Parquet file reads at the worker. The first time a worker reads a set of Parquet blocks from MinIO, it stores them on local disk. Subsequent queries that touch the same blocks read from the local cache — much faster than a network call to MinIO. The cache is content-addressed and evicts old data when the configured max size is reached.

**Best for:**
- Repeated dashboard queries reading the same hot partitions (e.g., last 7 days of events, a small "current state" rollup table, a frequently-joined dimension table).
- Clusters where MinIO bandwidth is the bottleneck (high-frequency refreshing dashboards saturating the network to MinIO).

**Less useful for:**
- Large ad-hoc analytical queries that scan the whole table — each query touches different partitions and the cache hit rate stays low.
- Append-only tables where each run reads new partitions that haven't been cached yet.

### Enable in the Iceberg catalog properties

Configure on the Iceberg catalog properties file on every coordinator and worker. A pod restart is required for the change to take effect:

```properties
# etc/catalog/iceberg.properties
# Enable the native file system data cache.
fs.cache.enabled=true
fs.cache.directories=/var/trino/cache
fs.cache.max-sizes=100GB
```

**IMPORTANT: `fs.cache.enabled=true` disables `iceberg.metadata-cache.enabled`.** The two cache systems are mutually exclusive — the file system cache supersedes the metadata-only cache. If you previously had `iceberg.metadata-cache.enabled=true`, removing that line (or leaving it — it will be ignored) is correct when enabling `fs.cache.enabled`. You cannot run both simultaneously; the `fs.cache` covers the broader set of I/O and makes the metadata cache redundant.

### Worker pod requirements

The file system cache writes to local disk on each Trino worker pod. For this to be fast:

- **Mount a local fast SSD** at `/var/trino/cache` on each worker pod. In Kubernetes, use an `emptyDir` volume (ephemeral, wiped on pod restart — acceptable since the cache is a read-through layer, not durable storage) or a `local` PersistentVolume backed by the node's NVMe SSD.
- **Do NOT use network-mounted storage** (NFS, MinIO-FUSE, or a PVC backed by a network storage class) for the cache path. The cache's value comes from fast local I/O; network storage makes caching slower than not caching.
- **Size `fs.cache.max-sizes` to fit on the local disk** with headroom for Trino's spill directory and OS. A typical setup: 100 GB cache on a worker with 500 GB local NVMe (leaving headroom for spill and OS).

Example Kubernetes worker pod volume spec (emptyDir):

```yaml
# Kubernetes worker pod spec — add to your Trino Helm chart values or manifest.
volumeMounts:
  - name: trino-cache
    mountPath: /var/trino/cache
volumes:
  - name: trino-cache
    emptyDir:
      sizeLimit: 120Gi   # slightly larger than fs.cache.max-sizes to give Trino headroom
```

Or a local PV for persistent SSD-backed cache (survives pod restarts, useful if the worker pod restarts frequently):

```yaml
volumeMounts:
  - name: trino-cache
    mountPath: /var/trino/cache
volumes:
  - name: trino-cache
    persistentVolumeClaim:
      claimName: trino-worker-cache-pvc   # backed by a local-storage StorageClass on the node's NVMe
```

### Mutual exclusivity with metadata cache

| Setting | When to use |
|---|---|
| `iceberg.metadata-cache.enabled=true` (metadata-only cache) | When you only want to cache Iceberg metadata (snapshot lists, manifest files) and NOT cache actual Parquet data blocks. Lower disk requirement (metadata is small). |
| `fs.cache.enabled=true` (full data cache) | When you want to cache both metadata AND Parquet data blocks for hot partitions. Requires local SSD. Disables the metadata-only cache automatically. |
| Neither | Default. Every read hits MinIO. Fine for large ad-hoc analytical workloads with low cache hit rates. |

Setting both `fs.cache.enabled=true` and `iceberg.metadata-cache.enabled=true` results in the metadata cache being silently ignored — `fs.cache` takes over. Only set `fs.cache.enabled=true` and leave out `iceberg.metadata-cache.enabled`.

### Why this wins biggest on MinIO specifically

The fs.cache payoff is bigger on a MinIO-backed stack than on, say, S3 in AWS — three reasons:

1. **Object-listing latency is the hot path on MinIO.** Every Parquet open requires a HEAD/GET round-trip for the file footer (Parquet metadata) BEFORE any data is read. On MinIO over a single-rack network, that round-trip is typically 5-15 ms per file. A query touching 500 small files spends 2.5-7 seconds just opening files before reading a byte. fs.cache caches the footer reads too, so the second run pays zero round-trip cost for the files it already has.
2. **MinIO bandwidth is finite and shared across the cluster.** Every dashboard refresh that bypasses the cache competes with ingestion and ad-hoc queries for the same NIC bandwidth on the MinIO nodes. Caching shifts read load off MinIO entirely for hot partitions.
3. **No object-store "free tier" cost concern.** On AWS, S3 GET costs ($0.0004 / 1k requests) sometimes argue against caching small files. On on-prem MinIO, every request is free (capex sunk cost) — so the only constraint is whether you have local SSD to spare on workers. If you do, caching is pure win.

The combination means fs.cache typically delivers 5-15x speedup on dashboard queries the second time they run on the same partition window, vs 2-4x on a cloud-native stack where the underlying object storage already has more aggressive caching upstream.

### Verify the cache is working

After enabling and restarting workers, run a dashboard query twice. The second run should be noticeably faster. Trino's JMX MBeans expose cache hit and miss counters that you can scrape with Prometheus to confirm cache hit rate is increasing for your hot-partition queries.

**Key JMX metric names to scrape** (under the Iceberg connector's filesystem-cache MBean tree — exact name depends on Trino release, verify in your cluster's `/v1/jmx` REST endpoint or in the Trino UI's JMX page):

| Metric | What it tells you |
|---|---|
| `trino.filesystem.cache:name=*,type=CacheStats` (`hitCount`, `missCount`, `hitRate`) | The headline cache effectiveness number — `hitRate` above ~0.7 means the cache is paying for itself; below ~0.3 means workloads aren't repeating files often enough to benefit. |
| `trino.filesystem.cache:type=Bytes` (`cacheSize`, `maxCacheSize`) | Current and max cache size on disk per worker — if `cacheSize` is at `maxCacheSize`, the cache is full and is evicting old entries (LRU). Confirms the size config is binding. |
| `trino.filesystem.cache:type=Evictions` (`evictionCount`) | How often the cache is evicting entries — high churn (thousands per minute) on a small cache means you need to size up. |
| `trino.execution.executor.OperatorStats` (`physicalInputDataSize` per query) | Cross-reference with `EXPLAIN ANALYZE`: physicalInputDataSize should drop dramatically on cache-hit reruns even though logicalInputDataSize stays the same. |

Scrape these into Prometheus, alert on `hitRate < 0.3` for the dashboards path (means caching isn't working as expected and you should investigate the queries).

If the second run is NOT faster, check:
1. The cache directory exists and is writable by the Trino process on the worker pod (`ls -la /var/trino/cache` from inside the pod).
2. The worker pods actually have local SSD mounted (not a network PVC — watch for slow first reads that indicate the "cache" is itself going over the network).
3. The queries are actually re-reading the same Parquet files (check `Physical Input:` in `EXPLAIN ANALYZE` before and after — if it drops to near-zero on the second run, caching is working).
4. The hit-rate JMX metric is actually climbing (curl the JMX REST endpoint or watch the Trino UI's JMX MBean view) — if it stays at zero, the cache isn't intercepting reads (usually a config issue — the property isn't loaded, or the path isn't writable).

### What about caching query RESULTS (not just file blocks)?

A common follow-on question: "Can Trino cache the final query results so the second identical dashboard refresh doesn't re-execute the plan at all?"

**Short answer: no, not in production-supported form on Trino 467.** Trino does NOT cache query results, query plans, or per-table compiled metadata between query executions. Every query re-plans and re-executes — even if the SQL text is byte-identical to a query that ran 100 ms ago. This is a long-standing feature request ([trinodb/trino #13115](https://github.com/trinodb/trino/issues/13115) and related) that has not been implemented as a first-class feature in open-source Trino.

There is an **experimental query results cache plugin** mentioned in some Trino developer threads, but it is NOT in the production-supported feature set on Trino 467 — there's no `query-results-cache.*` configuration in the official docs, and the consensus from Trino maintainers is that result caching is intentionally left out of the core engine (it conflicts with Trino's federated-query model where cache invalidation is hard to reason about across heterogeneous catalogs).

**What to use instead for repeated identical queries:**

- **Application-layer Redis cache** in front of Trino: hash the SQL text + tenant_id, cache the JSON results with a TTL (typically 1-5 minutes for dashboards). This is the standard SaaS pattern — Redis handles invalidation policy and keeps Trino out of the cache-coherence problem. See resource 20 for client-side patterns.
- **Pre-aggregated rollup tables** built nightly via dbt or Spark: convert the "live SUM over 90 days" query into a "SELECT FROM daily_rollup" query. The dashboard now reads a thousand pre-aggregated rows instead of a billion raw rows. This is the durable answer for any query the dashboard runs more than 10x/hour.
- **fs.cache (this section)**: caches the underlying Parquet blocks. The query still re-plans and re-executes, but the data reads complete in tens of ms instead of seconds. Best when query shapes vary slightly but always touch the same partitions.

The combination of all three (Redis at the app layer for exact-text repeats + rollup tables for known dashboard queries + fs.cache for everything else) is the standard layered approach. Do not wait for first-class result caching in Trino — it isn't coming on the 467 line.

---

## Oncall runbook summary

| Symptom | First check | Likely fix |
|---|---|---|
| All queries slow simultaneously | Trino UI — concurrent query count | Stagger refreshes, resource groups |
| One query slow, others fine | EXPLAIN ANALYZE `Physical Input:` (and `$files` / `EXPLAIN ANALYZE VERBOSE` for file count) | Add partition filter, run compaction |
| One query stuck RUNNING for hours, blocking the queue | `system.runtime.queries` JOIN `system.runtime.tasks` filtered to `state='RUNNING'` and long `running_min` | `CALL system.runtime.kill_query(query_id => '...')` — see Immediate remediation section above |
| Slow after midnight | Compaction CronJob logs | Fix the CronJob, run compaction manually |
| Slow for one tenant (whale) | Row count by tenant; confirm with `EXPLAIN ANALYZE VERBOSE` per-driver `inputRows` on Aggregation operator | **Salt + two-level GROUP BY** (Step 5 fix 1) for ad-hoc queries; dedicated table or nightly rollup for sustained workloads. Do NOT use `bucket(tenant_id, N)` — it does not fix read-time GROUP BY skew. |
| OOM errors (`EXCEEDED_LOCAL_MEMORY_LIMIT`) | `query.max-memory-per-node` hit on one worker | Narrow query scope, pre-aggregate, add partition filters. For fact-to-dim joins: `SET SESSION join_distribution_type = 'BROADCAST'`. Safety net: enable spill-to-disk (`spill-enabled=true`). See Step 9. |
| OOM errors (`EXCEEDED_DISTRIBUTED_MEMORY_LIMIT`) | `query.max-memory` cluster-wide limit hit | Same as above; or increase `query.max-memory` if query is legitimately large. See Step 9 for BROADCAST joins and spill config. |
| Slow after data model change | EXPLAIN ANALYZE `Input:` rows and `Physical Input:` bytes | Compare filter coverage before/after |
| Slow for all tenants, one table | Snapshot metadata file count | Run compaction in Spark |

---

## Key concepts

**Query concurrency**: Number of queries running simultaneously. Each additional query shares the same worker CPU and memory.

**Query frequency**: How often the same query runs. High frequency × high cost = sustained cluster load.

**Partition pruning**: Trino's ability to skip data files where the partition column value can't match the WHERE clause. Only works if you filter on a partition column.

**Partition skew**: One partition having dramatically more rows than others. Causes one worker to do most of the work while others idle. **Read-time GROUP BY skew** (one key dominates) is fixed with a salt column + two-level GROUP BY, dedicated table, or rollup — NOT with `bucket(key, N)` partitioning, because Iceberg bucketing hashes each distinct value to one bucket. See Step 5.

**Salt / two-level GROUP BY**: A SQL pattern for breaking whale-key GROUP BY skew. Add a random integer salt column (1..N), aggregate by `(key, salt)` first to distribute the whale across N workers, then SUM the partial results by `key` to get the final answer. See Step 5 fix 1.

**Small files problem**: Many tiny Parquet files (< 32 MB) accumulated from frequent small writes. Metadata overhead per file turns into minutes of I/O overhead at query time.

**Compaction**: Merging small files into larger ones (128–512 MB). Must run in Spark via `CALL iceberg.system.rewrite_data_files()`.

**Data model regression**: A query that previously hit a narrow, pre-joined table now hitting raw tables with multiple joins — often introduced by a schema migration or new feature.
