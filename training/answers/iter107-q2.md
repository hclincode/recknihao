# Iter107 Q2 — Answer

**Question**: Our Postgres events table has 400 million rows and our nightly Spark job that loads it into Iceberg takes about 4 hours even though we already switched from full refresh to incremental. We're reading rows where updated_at is greater than our last watermark. The DBA said we should look at our JDBC connection settings because we might be bottlenecking there, but I have no idea what knobs exist or what they do. What settings actually matter for speeding up how fast Spark reads from Postgres?

---

## Answer

Four hours for an incremental load suggests at least one of these is true: the `updated_at` watermark column is unindexed (so Postgres still scans all 400M rows despite the WHERE clause), or Spark is reading over a single serial JDBC connection instead of reading in parallel. Fix those two first — everything else is secondary.

### Step 0: Verify the Watermark Index (Check This Before Touching Spark)

An incremental job with `WHERE updated_at > last_watermark` is only fast if Postgres can find those rows without scanning the whole table.

```sql
-- On the Postgres primary
SELECT indexname, indexdef
FROM pg_indexes
WHERE tablename = 'events'
  AND indexdef LIKE '%updated_at%';
```

If this returns nothing, Postgres is scanning all 400M rows, filtering in memory, and returning only the changed rows. Spark itself is fine — the 4-hour bottleneck is Postgres.

```sql
-- Fix: add the index without locking writes
CREATE INDEX CONCURRENTLY idx_events_updated_at ON events (updated_at);
```

After the index is created, your `WHERE updated_at > '2026-05-24 10:00:00'` becomes a fast B-tree range scan. This single change can drop a 4-hour incremental job to 20-30 minutes before touching any Spark settings.

---

### Setting 1: Parallel JDBC Reads (`partitionColumn`, `numPartitions`, `lowerBound`, `upperBound`)

By default, Spark JDBC opens **one connection** and reads the entire result serially through one task. With 400M rows, that serial read saturates one Postgres connection for hours while your other executor cores sit idle.

The fix: split the ID range into N slices and read them in parallel:

```python
PG_URL = "jdbc:postgresql://pg-replica.internal:5432/app"
last_ts = "2026-05-24 10:00:00"  # loaded from your state file

# First, get the ID bounds for changed rows only
bounds = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT COALESCE(MIN(id), 1) AS lo, COALESCE(MAX(id), 1) AS hi FROM events WHERE updated_at > '{last_ts}') t",
    properties=PG_PROPS,
).collect()[0]

# Main read — 16 parallel connections, each covering 1/16 of the ID range
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE updated_at > '{last_ts}') t",
    properties=PG_PROPS,
    column="id",              # numeric column to split on
    lowerBound=bounds.lo,
    upperBound=bounds.hi,
    numPartitions=16,         # 16 parallel JDBC connections
)
```

`lowerBound` and `upperBound` do NOT filter rows — they only control how Spark divides the work. Rows outside the range fold into the nearest partition. Your WHERE clause does the actual filtering.

**Choosing `numPartitions`:**

Don't hardcode 16. The right value is `min(executor_cores, postgres_connection_budget)`.

**How to size the connection budget:**

```sql
-- On the replica: find the cap
SHOW max_connections;  -- e.g., 100

-- During peak load (e.g., 10am): measure what's actually used
SELECT count(*), application_name
FROM pg_stat_activity
WHERE wait_event_type IS DISTINCT FROM 'Client'
GROUP BY application_name
ORDER BY count(*) DESC;
```

Subtract typical usage by Trino (~20), your app (~10), monitoring (~3), and keep 10% headroom. The remainder is your Spark budget.

Example with `max_connections=100`:
```
100 - 20 (Trino) - 10 (app) - 3 (monitoring) - 10 (headroom) = 57
numPartitions = min(executor_cores, 57)
```

**Common mistakes:**
- `numPartitions=200` on a 100-connection cluster → Spark grabs all slots, Trino fails with `remaining connection slots reserved`
- `numPartitions=1` (the default) → serial read, 4-hour job stays 4 hours

---

### Setting 2: Fetch Buffer Size (`fetchsize`)

The pgjdbc driver's default `fetchsize` is **0**, which means it tries to load the entire result set into executor memory at once. On 400M rows, this causes executor OOM or GC pauses.

```python
PG_PROPS = {
    "user":     "analytics_reader",
    "password": "...",
    "driver":   "org.postgresql.Driver",
    "fetchsize": "10000",   # stream 10K rows per round-trip, not all at once
    "options":  "-c statement_timeout=14400000 -c idle_in_transaction_session_timeout=900000",
}
```

**`fetchsize=10000`** streams rows in 10,000-row chunks. Memory pressure stays bounded regardless of result size. This is a one-line fix that prevents OOM crashes on large incremental windows.

**`statement_timeout=14400000`** (4 hours): kills any connection that runs longer than the expected job duration — protects the replica from a stalled Spark client holding a transaction open indefinitely.

**`idle_in_transaction_session_timeout=900000`** (15 minutes): kills idle-but-in-transaction connections from crashed executors.

---

### Setting 3: Read from a Replica (Not the Primary)

If your Spark job reads from the primary, it competes with your production app's INSERT/UPDATE/SELECT for CPU and I/O. Switch to a read replica:

```python
PG_REPLICA_URL = "jdbc:postgresql://pg-replica.internal:5432/app"
# vs.
PG_PRIMARY_URL = "jdbc:postgresql://pg-primary.internal:5432/app"  # don't use this
```

**One replica-specific risk**: For a 4-hour read, the replica may cancel your query with:
```
ERROR: canceling statement due to conflict with recovery
```

This happens because the primary ran VACUUM during your read, the WAL apply needed a lock, and after `max_standby_streaming_delay` (default 30 seconds) the replica killed your query.

**Fix**: enable `hot_standby_feedback` on the replica before your long reads:

```sql
-- On the REPLICA
ALTER SYSTEM SET hot_standby_feedback = on;
SELECT pg_reload_conf();
```

This tells the primary "don't VACUUM rows my replica is reading." Revert after the job completes if you're concerned about primary table bloat.

---

### Setting 4: Verify Predicate Pushdown

`pushDownPredicate` defaults to `true` in Spark JDBC — your `WHERE updated_at > '...'` filter should push down to Postgres automatically. Verify it:

```python
df.explain(True)
# Look for: PushedFilters: [GreaterThan(updated_at, ...)]
```

If the filter is absent from `PushedFilters`, Spark is pulling all rows and filtering in memory — likely a type-cast mismatch. Ensure the comparison types match on both sides (Postgres `timestamp` vs Spark `TimestampType`).

---

### Complete Example

```python
from pyspark.sql import SparkSession
from datetime import datetime, timedelta

spark = SparkSession.builder.appName("events-incremental").getOrCreate()

PG_URL = "jdbc:postgresql://pg-replica.internal:5432/app"
last_ts = read_watermark()  # from your state file

PG_PROPS = {
    "user": "analytics_reader",
    "password": "...",
    "driver": "org.postgresql.Driver",
    "fetchsize": "10000",
    "options": "-c statement_timeout=14400000 -c idle_in_transaction_session_timeout=900000",
}

# Get ID bounds for parallel split (only from the changed-row window)
bounds = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT COALESCE(MIN(id),1) AS lo, COALESCE(MAX(id),1) AS hi FROM events WHERE updated_at > '{last_ts}') t",
    properties=PG_PROPS,
).collect()[0]

# Parallel incremental read
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE updated_at > '{last_ts}') t",
    properties=PG_PROPS,
    column="id",
    lowerBound=bounds.lo,
    upperBound=bounds.hi,
    numPartitions=16,   # tune to min(executor_cores, connection_budget)
)

# Write to Iceberg idempotently via MERGE INTO
df.createOrReplaceTempView("events_delta")
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_delta s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")

# Advance watermark
new_ts = df.agg({"updated_at": "max"}).collect()[0][0]
write_watermark(new_ts - timedelta(minutes=15))  # LAG_BUFFER for replica lag
```

---

### Priority Order

1. **Add `updated_at` index on Postgres** — most impactful, often the sole cause of 4-hour runtimes
2. **Set `fetchsize=10000`** — one-line fix, prevents OOM
3. **Add parallel reads** with `partitionColumn`/`numPartitions` — biggest throughput gain once index exists
4. **Switch to read replica** + enable `hot_standby_feedback` for long reads
5. **Verify predicate pushdown** via `df.explain(True)` if row counts look unexpectedly high

With all five in place, a 400M-row incremental load hitting an indexed `updated_at` with 16 parallel readers typically runs in 15–30 minutes.
