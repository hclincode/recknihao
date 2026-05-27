# Iter105 Q2 — Answer

**Question**: We've been running our Postgres-to-Iceberg sync job for about two months now. It's a nightly job that reads from our main Postgres database and writes to Iceberg. The job works fine most nights, but we noticed that when a customer does a bulk import — like they upload a CSV with 500,000 records — our production Postgres gets really sluggish for a few hours while the sync job is running at the same time. I'm guessing the Spark job that reads from Postgres is hammering the database with a big sequential scan. Is there a way to run these ingestion jobs without affecting production query performance? We can't just schedule them at 3am because customers are in different time zones and bulk imports can happen any time.

---

## Answer

The fix is to **read from a Postgres read replica instead of the primary**. When Spark scans your primary, it competes directly with your app's INSERT/UPDATE/SELECT traffic for CPU and I/O. A read replica is purpose-built for analytical reads and places zero load on the primary. With the right configuration, your sync jobs run smoothly even while customers are doing bulk imports.

There are three additional risks to handle when reading from a replica that can trip you up.

---

## Part 1: Point Spark at the Read Replica

Change your JDBC URL from the primary to the replica:

```python
# Before (hammers production):
PG_URL = "jdbc:postgresql://pg-primary.internal:5432/app"

# After (zero impact on production):
PG_URL = "jdbc:postgresql://pg-replica.internal:5432/app"

PG_PROPS = {
    "user":              "spark_reader",
    "password":          "...",
    "driver":            "org.postgresql.Driver",
    "pushDownPredicate": "true",    # WHERE clauses run on Postgres, not pulled to Spark
    "fetchsize":         "10000",   # stream in batches — prevents executor OOM
    # Safety nets: kill stalled connections before they block primary VACUUM
    "options": "-c statement_timeout=14400000 -c idle_in_transaction_session_timeout=900000",
}

df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE updated_at > '{last_watermark}') sub",
    properties=PG_PROPS,
    column="id",
    lowerBound=min_id,
    upperBound=max_id,
    numPartitions=16,  # see Part 3 for how to size this
)
```

With this change, customer bulk imports hit the primary; Spark hits the replica. They no longer compete.

---

## Part 2: Handle Replica Lag — Don't Miss Rows

A replica always lags behind the primary by seconds to minutes. If the replica is 5 minutes behind when your sync runs, you'll miss rows that landed on the primary 4 minutes ago. Silent data loss.

**Fix: check replica lag and cap your watermark window.**

```python
from datetime import datetime, timedelta

# Check how far behind the replica is RIGHT NOW
# CRITICAL: pg_last_xact_replay_timestamp() returns NULL on the primary —
# you must run this against the REPLICA URL
lag_df = spark.read.jdbc(
    url=PG_URL,  # replica URL
    table="(SELECT pg_last_xact_replay_timestamp() AS replay_ts) t",
    properties=PG_PROPS,
)
replay_ts = lag_df.collect()[0].replay_ts

# Set LAG_BUFFER = 2x your observed P99 replica lag
# (Check your monitoring for the worst lag in the past 7 days)
# Healthy replicas: P99 is usually 5-30 min; use 15-20 min buffer
LAG_BUFFER = timedelta(minutes=15)

last_watermark = "2026-05-24 12:00:00"  # from your state file
safe_upper = min(datetime.utcnow(), replay_ts - LAG_BUFFER)

df = spark.read.jdbc(
    url=PG_URL,
    table=f"""(SELECT * FROM events
               WHERE updated_at > '{last_watermark}'
               AND   updated_at <= '{safe_upper}') sub""",
    properties=PG_PROPS,
    column="id",
    lowerBound=min_id,
    upperBound=max_id,
    numPartitions=16,
)
```

The next run picks up rows in the 5–15 minute window that were held back by the buffer. Your data is complete; it's just delayed by `LAG_BUFFER`. This is the standard production approach.

---

## Part 3: Replica-Specific Risk — WAL Apply Conflicts Kill Long Spark Reads

This is the #1 production surprise when pointing Spark at a Postgres replica for large reads. A 2–4 hour Spark read **can be killed by the replica itself**.

**What happens:**
1. Spark opens a JDBC connection and starts reading your events table.
2. While Spark is reading, the Postgres primary performs a VACUUM (normal background maintenance).
3. The VACUUM's WAL record arrives at the replica. WAL apply needs a lock that conflicts with Spark's open read.
4. The replica waits. After `max_standby_streaming_delay` seconds (Postgres default: **30 seconds**), the replica cancels Spark's query and resumes WAL apply.
5. Your Spark job fails with:
   ```
   ERROR: canceling statement due to conflict with recovery
   DETAIL: User query might have needed to see row versions that must be removed.
   ```

**Fix: enable `hot_standby_feedback` on the replica** for the duration of the job.

`hot_standby_feedback` tells the primary "I have a long-running read, please don't vacuum those rows yet." The primary defers cleanup until the replica's query finishes.

```sql
-- On the replica, BEFORE starting the Spark job (requires superuser):
ALTER SYSTEM SET hot_standby_feedback = on;
SELECT pg_reload_conf();

-- Verify:
SHOW hot_standby_feedback;  -- should return 'on'
```

Run the Spark sync job. It will complete without cancellation.

```sql
-- On the replica, AFTER the Spark job completes:
ALTER SYSTEM SET hot_standby_feedback = off;
SELECT pg_reload_conf();
```

**Why revert?** Keeping it on permanently causes the primary to retain dead tuples and WAL segments longer, leading to primary table bloat. For a recurring nightly job, flipping it on/off is fine. If you can't automate the toggle, keeping it on permanently and monitoring primary bloat weekly is also acceptable.

**Alternative (if you can't change `hot_standby_feedback`):**
```sql
-- Unlimited delay before canceling conflicts — replica accumulates lag while Spark runs
ALTER SYSTEM SET max_standby_streaming_delay = -1;
SELECT pg_reload_conf();
-- ... run Spark job ...
ALTER SYSTEM SET max_standby_streaming_delay = '30s';
SELECT pg_reload_conf();
```

This avoids the primary bloat but causes the replica to accumulate replication lag during the entire Spark run — any other dashboards reading the replica see stale data. Prefer `hot_standby_feedback` if you have the choice.

---

## Part 4: Size numPartitions Against Your Connection Budget

`numPartitions` controls how many parallel JDBC connections Spark opens to the replica simultaneously. Too high and you starve Trino and your app. Too low and your job runs for 12 hours instead of 2.

**Sizing formula:**
```
numPartitions = min(executor_cores, replica_max_connections - reserved_for_other_services)
```

**Step 1: Find replica's connection limit**
```sql
-- On the replica
SHOW max_connections;  -- commonly 100, 200, or 500
```

**Step 2: Measure peak usage from other services**
```sql
-- On the replica during peak load (9am on a busy day)
SELECT count(*) AS active, application_name
FROM pg_stat_activity
WHERE wait_event_type IS DISTINCT FROM 'Client'
GROUP BY application_name
ORDER BY count(*) DESC;
```

**Step 3: Reserve connections for each service**

| Service | Reserve |
|---|---|
| Trino (peak query load) | 20–30 |
| Production app reads | 10 |
| Monitoring (Datadog, etc.) | 3 |
| Postgres internal (autovacuum, WAL sender) | 7 |
| Safety headroom (10%) | 10 |

**Example with `max_connections=100`:**
```
100 - 20 (Trino) - 10 (app) - 3 (monitoring) - 7 (Postgres) - 10 (headroom) = 50
numPartitions = min(executor_cores, 50)
```

**Common mistakes:**
- `numPartitions=200` on a 100-connection cluster → Spark + Trino both fail with `remaining connection slots are reserved for non-replication superuser connections`
- `numPartitions=1` → serial read, a 2-hour job takes 12 hours
- Measuring connections at 2am instead of during peak load → you allow 70 Spark connections, Trino has nothing left at 9am

---

## Complete Safe Pattern

```python
PG_REPLICA_URL = "jdbc:postgresql://pg-replica.internal:5432/app"

PG_PROPS = {
    "user": "spark_reader", "password": "...",
    "driver": "org.postgresql.Driver",
    "pushDownPredicate": "true", "fetchsize": "10000",
    "options": "-c statement_timeout=14400000 -c idle_in_transaction_session_timeout=900000",
}

# Check replica lag
replay_ts = spark.read.jdbc(
    url=PG_REPLICA_URL,
    table="(SELECT pg_last_xact_replay_timestamp() AS ts) t",
    properties=PG_PROPS,
).collect()[0].ts

safe_upper = min(datetime.utcnow(), replay_ts - timedelta(minutes=15))

# Compute numPartitions from your cluster's connection budget (fill in from measurements)
SPARK_BUDGET = 50  # max_connections minus all reserved services
EXECUTOR_CORES = 60
num_partitions = min(EXECUTOR_CORES, SPARK_BUDGET)

# Read
df = spark.read.jdbc(
    url=PG_REPLICA_URL,
    table=f"(SELECT * FROM events WHERE updated_at > '{last_watermark}' AND updated_at <= '{safe_upper}') sub",
    properties=PG_PROPS,
    column="id", lowerBound=min_id, upperBound=max_id,
    numPartitions=num_partitions,
)

# Write to Iceberg
df.writeTo("iceberg.analytics.events").append()

# Save watermark
save_watermark(safe_upper)
```

**Before deploying:** ask your DBA to enable `hot_standby_feedback = on` on the replica for the job window (or permanently), so long reads don't get cancelled by WAL conflicts.
