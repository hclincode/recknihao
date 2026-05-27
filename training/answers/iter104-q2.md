# Iter104 Q2 — Answer

**Question**: We're about to do our first-ever sync of our main events table from Postgres into Iceberg using Spark. The table has about 300 million rows and is actively being written to by our production app around the clock. My concern is: what does a Spark job reading 300 million rows out of Postgres actually do to the production database? Does it lock tables, spike CPU, slow down our API, or cause any other issues we should worry about? And is there a safe way to run this initial load — maybe against a read replica, or with some kind of throttling — without risking an outage?

---

## Answer

Spark JDBC reads do **not** take locks or block writers. The SELECT is read-only and your production app keeps writing unimpeded. But the real risk is **CPU and disk I/O contention**: a full-table scan of 300M rows competes for buffer cache and CPU with every user-facing query. The fix is straightforward: **read from a read replica, not the primary**. With the right JDBC configuration, your production database sees zero impact.

### What Spark JDBC Actually Does

Spark issues standard `SELECT` queries against Postgres using JDBC. These reads:
- Use read-committed or serializable isolation (configurable) — no exclusive locks
- Do NOT block INSERT/UPDATE/DELETE on the primary
- Do consume significant I/O on whichever server they read from

This is why **pointing Spark at your read replica is non-negotiable** for a 300M-row table. The replica is purpose-built for analytical reads; the primary is not.

### Safe JDBC Configuration with Parallel Reads

```python
from pyspark.sql import SparkSession

spark = SparkSession.builder.appName("postgres-to-iceberg-bootstrap").getOrCreate()

# Read replica URL — NOT the primary
PG_REPLICA_URL = "jdbc:postgresql://pg-replica.internal:5432/app"

PG_PROPS = {
    "user":               "analytics_read",
    "password":           "...",
    "driver":             "org.postgresql.Driver",
    "fetchsize":          "10000",    # stream rows in batches — prevents executor OOM
    "pushDownPredicate":  "true",     # WHERE clauses run on Postgres, not pulled to Spark
}

# Full bootstrap — parallel read split on the id column
df = spark.read.jdbc(
    url=PG_REPLICA_URL,
    table="public.events",
    properties=PG_PROPS,
    partitionColumn="id",         # split the id range across parallel tasks
    lowerBound=1,
    upperBound=300_000_000,       # can be an overestimate
    numPartitions=16,             # 16 parallel JDBC connections to the replica
)

df.writeTo("iceberg.analytics.events").using("iceberg").createOrReplace()
```

**Why each setting matters:**

| Setting | Why it matters |
|---|---|
| `url` → replica | Reads never touch the primary |
| `partitionColumn` + `lowerBound`/`upperBound`/`numPartitions` | Splits 300M rows into 16 parallel ranges instead of one serial read; reduces per-connection pressure |
| `fetchsize=10000` | JDBC driver fetches 10,000 rows per round-trip instead of buffering all 300M in memory; prevents executor heap exhaustion |
| `pushDownPredicate=true` | WHERE filters execute on Postgres (indexed), not on Spark after pulling all rows |

### The `upperBound` Doesn't Cap the Read

`upperBound` is not a filter — it only controls how Spark divides the ID range into 16 chunks. If your actual max ID is 287M, use 300M as an overestimate; Spark will still read all rows. Setting it too low causes uneven partitions where the last chunk carries all the overflow rows.

### After the Bootstrap: Incremental Loads with a Watermark

The bootstrap is a one-time operation. All subsequent runs should be incremental — reading only rows changed since the last run:

```python
from datetime import datetime, timedelta

# Measure your replica's P99 lag from pg_stat_replication.replay_lag, then double it
LAG_BUFFER = timedelta(minutes=10)

last_watermark = "2026-05-24 10:00:00"   # loaded from your state file
safe_upper = datetime.now() - LAG_BUFFER  # stay behind the replica lag

df = spark.read.jdbc(
    url=PG_REPLICA_URL,
    table=f"""(SELECT * FROM events
               WHERE updated_at > '{last_watermark}'
               AND   updated_at < '{safe_upper}') AS t""",
    properties=PG_PROPS,
    partitionColumn="id",
    lowerBound=1,
    upperBound=300_000_000,
    numPartitions=16,
)

df.createOrReplaceTempView("events_delta")
spark.sql("""
    MERGE INTO iceberg.analytics.events t
    USING events_delta s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

The `LAG_BUFFER` ensures rows still in transit from primary to replica don't get missed. MERGE INTO makes re-runs safe — matched rows are updated in place (no duplicates).

### Critical Prerequisite: Index the Watermark Column

If `updated_at` is not indexed, incremental runs force a full table scan every time. Verify it exists before your first run:

```sql
-- Check on the primary (indexes replicate automatically)
SELECT indexname FROM pg_indexes
WHERE tablename = 'events' AND indexdef LIKE '%updated_at%';

-- If missing, create it without blocking production writes:
CREATE INDEX CONCURRENTLY idx_events_updated_at ON events (updated_at);
```

`CONCURRENTLY` takes longer but does not lock the table. Without this index, every incremental load scans all 300M rows.

### Impact Summary

| Scenario | Primary impact | Replica impact |
|---|---|---|
| Read from primary | CPU spike, query latency degradation, API slowdown | None |
| Read from replica (this setup) | Zero | Elevated CPU/IO — expected and acceptable |
| No `fetchsize` set | Potential OOM on Spark executors | Full result set buffered in replica memory |
| No `numPartitions` | Single slow connection, serial read | Higher per-connection pressure |

### Verification

During the job run, check your monitoring:
- **Expected**: large SELECT appears on the **replica** node
- **Problem signal**: CPU spike on the **primary** — stop the job and fix the connection URL

After the bootstrap completes, verify row counts match:
```sql
-- On Postgres primary
SELECT COUNT(*) FROM events;

-- On Iceberg via Trino
SELECT COUNT(*) FROM iceberg.analytics.events;
```
