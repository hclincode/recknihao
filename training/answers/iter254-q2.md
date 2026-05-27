# Iter254 Q2 — Query Planning Bottleneck and query.max-planning-time

## Answer

Yes, the delay you are observing before any data comes back is a real phenomenon in Trino, and your suspicion is correct: Trino splits every query into two distinct phases — **planning** (figures out how to run the query) and **execution** (actually runs it). With complex multi-catalog joins between Postgres and S3, the planning phase can take minutes before a single row is read.

## The Two Phases of a Trino Query

**Planning phase** (runs on the coordinator only, before any worker does anything):
- Parses your SQL
- Performs semantic analysis (are the table/column names valid?)
- Fetches table metadata and statistics from both Postgres and your Iceberg/data-lake catalog
- Runs the cost-based optimizer to figure out the optimal join order
- Decides which predicates can be pushed down to each system

**Execution phase** (runs on Trino workers and remote systems):
- Actually reads data from Postgres and your data lake
- Joins, filters, and aggregates results
- Returns them to your client

The delay you see before data arrives is the planning phase. Trino has not started execution yet.

## Why Federated Queries Hit This More

Every time the planner touches a Postgres catalog, it issues metadata queries to Postgres over JDBC to fetch table statistics (`pg_statistic`, `pg_stats`). For a complex join across Postgres and multiple Iceberg tables:
- Each Postgres table triggers a statistics fetch from the replica
- Each Iceberg table triggers manifest scans for cardinality estimates
- A 7-way join across multiple catalogs can spend 4–8 minutes just collecting stats before any data is read

This is particularly noticeable when `metadata.cache-ttl` is set to `0s` (the default — always fetch fresh stats) rather than caching for a few minutes.

## How to Identify Planning as the Bottleneck

### Method 1: Trino Web UI Timeline (Easiest)

Run your slow query and open the Trino Web UI at `http://<coordinator>:8080/ui/`. Find your query by ID and look at the query timeline. You will see distinct labeled phases. If there is a large gap labeled **"Planning"** before execution starts, that is your smoking gun.

### Method 2: system.runtime.queries (Programmatic)

After the query finishes or fails, query Trino's internal metrics:

```sql
SELECT query_id, planning_time_ms, analysis_time_ms
FROM system.runtime.queries
WHERE query LIKE '%your_table_name%'
ORDER BY created DESC
LIMIT 5;
```

If `planning_time_ms` is much larger than execution time, planning is the bottleneck. For example, `planning_time_ms = 120000` (2 minutes) with a 5-second execution is a clear planning problem.

Note: `system.runtime.queries` is in-memory and ephemeral — rows are evicted after ~15 minutes and on coordinator restart. Check it promptly after your query finishes.

### Method 3: Check Current Session Limits First

Before guessing, see what timeout limits are currently active:

```sql
SHOW SESSION LIKE 'query_max%';
```

This shows every `query_max*` session property with its current value, default, and description. Example output:

```
query_max_execution_time     | 10m     | 100.00d | varchar | Maximum execution time of a query
query_max_planning_time      | 15m     | 10.00m  | varchar | Maximum planning time of a query
query_max_run_time           | 15m     | 100.00d | varchar | Maximum run time of a query
```

If `query_max_planning_time` is still at its default of 10 minutes and your query is hanging for exactly 10 minutes before failing with "Query exceeded maximum planning time", you have confirmed the planning bottleneck.

## The Planning-Phase Timeout: query.max-planning-time

Yes, there is a timeout specifically for the planning phase — and it is separate from the execution timeout.

**Default**: 10 minutes.

**Set cluster-wide** (in `etc/config.properties` on the coordinator):

```properties
query.max-planning-time=15m
```

**Set per session** (in your SQL client, system-level — no catalog prefix):

```sql
SET SESSION query_max_planning_time = '5m';
```

**Error when this fires**: `Query exceeded maximum planning time` in the Trino UI failure reason — distinct from `Query exceeded maximum time limit` which comes from the execution/run-time caps. If you see "maximum planning time" in the error, the query never started execution — the fix is to simplify the plan, not to tune execution-time limits.

## Three Distinct Time Caps — Do Not Confuse Them

| Property | What it covers | Default | When to tune |
|---|---|---|---|
| `query.max-planning-time` | Planning phase ONLY (before execution starts) | 10 min | When complex joins hang before returning data |
| `query.max-execution-time` | Active compute time ONLY (not queue wait) | 100 days | When queries run too long during execution |
| `query.max-run-time` | Total wall-clock time (planning + queue wait + execution) | 100 days | When you want a user-perceived total time limit |

Important distinction for `max-execution-time` vs `max-run-time`: If a query waits 9 minutes in a resource-group queue and then executes for 1 minute, `query.max-execution-time=5m` will NOT fire (it counts only the 1-minute execution window). `query.max-run-time=5m` WILL fire (it counts the full 10 minutes from submission). For "the query hung before doing anything" complaints, `query.max-planning-time` is the right lever.

## How to Actually Fix It (Not Just Time Out Fast)

Setting `query.max-planning-time` to a lower value makes bad queries fail fast, but the real fix is to reduce planning complexity:

### 1. Enable Metadata Caching on the Postgres Catalog

If the same Postgres tables are hit repeatedly, add schema caching to the catalog properties file:

```properties
# In etc/catalog/app_pg.properties on the Trino coordinator:
metadata.cache-ttl=60s
metadata.cache-missing=true
```

Default is `0s` (always fetch fresh). This means every query re-reads statistics from Postgres over JDBC. Setting `60s` means the planner reuses cached stats for up to 60 seconds, dramatically reducing metadata fetch overhead for repeated queries.

After editing the catalog file, flush the cache manually for the current session:

```sql
CALL app_pg.system.flush_metadata_cache();
```

### 2. Reduce the Number of Joined Catalogs Per Query

Instead of one query that does a 7-way join across Postgres, MySQL, and Iceberg:
- Split into two queries: one that brings in Postgres data as a CTE or temp result, another that joins with Iceberg
- Or materialize intermediate results into Iceberg and query from there

### 3. Pre-Aggregate in Iceberg Before Joining Postgres

If you are doing `SELECT ... GROUP BY ... JOIN postgres_table`, pre-aggregate the Iceberg data in a staging table first, then join the much smaller result set with Postgres.

### 4. Run ANALYZE on Postgres to Give the Planner Good Statistics

If the planner has poor statistics, it may make expensive join-order decisions (treating large tables as small or vice versa), which compounds planning time. Run native ANALYZE on the Postgres PRIMARY:

```sql
-- On the Postgres PRIMARY (NOT the read replica — hot standbys reject ANALYZE):
ANALYZE customers;
```

Then flush Trino's metadata cache so the planner picks up the fresh statistics immediately:

```sql
CALL app_pg.system.flush_metadata_cache();
```

## Actionable Next Steps

1. Run `SHOW SESSION LIKE 'query_max%';` to see if `query_max_planning_time` is already set on your cluster.
2. Run your slow query and check the Trino UI query timeline — confirm planning is where the time is going.
3. Check `system.runtime.queries` immediately after for `planning_time_ms`.
4. Set `SET SESSION query_max_planning_time = '2m';` and re-run — if it fails with "maximum planning time" in under 2 minutes, you have confirmed the root cause.
5. Enable `metadata.cache-ttl=60s` on the Postgres catalog to reduce per-query metadata fetch overhead.
6. If planning is still slow after caching, simplify the query to reduce the number of catalogs or tables the planner must analyze.
