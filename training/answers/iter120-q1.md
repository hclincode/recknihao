# Iter120 Q1 — Answer

**Question**: We're adding a new analytics feature — a usage trend chart that needs 18 months of historical data per customer. We already have all that data in Postgres, but our Iceberg tables only go back 3 months from when we set up the pipeline. We need to load that historical data into Iceberg somehow. What's the right way to do a one-time backfill like this? I'm worried about overloading Postgres while production traffic is still hitting it, and I don't know if we should just dump CSVs or if there's a smarter way to approach it so the data lands correctly and doesn't mess up our existing partitions.

---

# Historical Data Backfill into Iceberg: A Practical Guide

You're adding a feature that needs 18 months of history, but your Iceberg pipeline only spans 3 months. This is a one-time backfill scenario — entirely different from your ongoing incremental ingestion. The key decision: **do this once correctly rather than discovering silent data loss weeks later**.

## The core problem with naive approaches

**Don't just dump CSVs.** Here's what breaks:

1. **Partition mismatches** — If you bypass your ingestion pipeline and write raw Parquet files directly to MinIO, they won't respect your partition spec. Queries won't prune correctly. Compaction can't consolidate them. You'll inherit years of slow scans.

2. **Double-counting** — If your incremental pipeline is still running (which it is, since production traffic hits Postgres), a naive full export → import risks overlapping the 3 months of existing Iceberg data with re-exported data from Postgres. You'll see duplicates or silent overwrites depending on how you land the files.

3. **Overloading Postgres** — An 18-month full table scan from a production Postgres instance while live traffic is writing to it will tank your primary. This is a read-replica workload, not a primary workload.

## The right approach: staged backfill + partition-scoped writes

Here's the pattern that works within your stack (Spark + Iceberg 1.5.2 + MinIO + Hive Metastore on Kubernetes):

### Step 1: Backfill from the Postgres read replica, not the primary

Your production Postgres likely has a read replica for analytics. Use it exclusively for the backfill — zero load on the primary.

```python
# On your Kubernetes cluster, submit this Spark job
from datetime import datetime, timedelta
import logging

PG_REPLICA_URL = "jdbc:postgresql://pg-replica:5432/your_app_db"
PG_PROPS = {
    "user": "analytics_reader",
    "password": "***",
    "driver": "org.postgresql.Driver",
    "fetchsize": "10000",  # Stream in batches, not all at once
}

ICEBERG_TABLE = "iceberg.analytics.user_events"
BATCH_DATE = "2026-05-23"  # The day you're backfilling (passed as a parameter)

# Read one day of historical data from Postgres.
df = spark.read.jdbc(
    url=PG_REPLICA_URL,
    table=f"(SELECT * FROM events WHERE date(occurred_at) = '{BATCH_DATE}') t",
    properties=PG_PROPS,
)

logging.info(f"Backfill {BATCH_DATE}: read {df.count()} rows from Postgres replica")

# Write to Iceberg using overwritePartitions() — idempotent, partition-scoped, atomic.
# If this job re-runs for the same BATCH_DATE, the partition is re-written with
# the same rows (idempotency). If the job fails mid-write, Iceberg's snapshot
# isolation means readers see either the old partition or the fully-written new
# one — never a corrupt intermediate state.
df.writeTo(ICEBERG_TABLE).overwritePartitions()

logging.info(f"Backfill {BATCH_DATE}: wrote to Iceberg partition")
```

**Why `overwritePartitions()` for backfill:**
- **Idempotent** — re-running the same `BATCH_DATE` writes the same rows. No duplicates.
- **Atomic** — queries see either the old partition or the new one, never both.
- **Partition-scoped** — only touches one day's partition, leaving everything else untouched. You can run this in parallel for multiple days without conflicts.

### Step 2: Schedule the backfill as a batch job, one day at a time

Don't try to load 18 months in a single massive job. Instead, schedule a Kubernetes CronJob or Airflow DAG that loops over the date range:

```python
from datetime import datetime, timedelta

END_DATE = datetime(2026, 5, 23)
START_DATE = datetime(2024, 11, 24)  # 18 months earlier

current = START_DATE
while current <= END_DATE:
    batch_date = current.strftime("%Y-%m-%d")
    # Submit a Spark job for this one day
    # (parallel submissions: submit 5-10 days at once for speed)
    current += timedelta(days=1)
```

**Benefits of daily granularity:**
- **Parallelizable** — you can submit 5–10 days' jobs in parallel without overwhelming Postgres or Kubernetes.
- **Restartable** — if a single day fails, re-submit that day. All prior days are already done.
- **Manageable memory** — one day's data fits comfortably in Spark executor RAM.
- **Visible progress** — you can monitor which days have landed in Iceberg and which are still pending.

### Step 3: Don't overlap with your ongoing incremental pipeline

While the backfill runs, your nightly incremental job is still pulling recent data. Both jobs can commit to the same Iceberg table — Iceberg's snapshot isolation handles conflicts automatically (one commit wins; the other retries). Just scope your incremental watermark to avoid re-processing dates the backfill already covered:

```python
# Your current pipeline watermark
CURRENT_WATERMARK = "2026-02-23 00:00:00"  # last run pulled through this timestamp

# Backfill ONLY data older than the watermark
# So backfill loop stops at Feb 22; incremental job resumes at Feb 23. No overlap.
BACKFILL_CUTOFF = CURRENT_WATERMARK - timedelta(days=1)
```

### Step 4: Handle Postgres read-replica lag carefully

```python
# Before starting the backfill, verify replica is caught up
lag_df = spark.read.jdbc(
    url=PG_REPLICA_URL,
    table="(SELECT pg_last_xact_replay_timestamp() AS replay_ts) t",
    properties=PG_PROPS,
)
replay_ts = lag_df.collect()[0].replay_ts

# Don't backfill data newer than what the replica has confirmed
MAX_BACKFILL_DATE = replay_ts.date() - timedelta(days=1)
```

## After the backfill completes

Once all 18 months are landed, run maintenance immediately:

```sql
-- Spark SQL (after last backfill day completes)

-- 1. Compact all the new small files into healthy 256MB+ Parquet files
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.user_events',
  options => map(
    'target-file-size-bytes', '268435456',
    'min-input-files', '5'
  )
);

-- 2. Expire old backfill snapshots
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.user_events',
  older_than  => current_timestamp - interval '7' day,
  retain_last => 10
);

-- 3. Rewrite manifest files (speeds up query planning)
CALL iceberg.system.rewrite_manifests(table => 'analytics.user_events');
```

## Why this avoids your original concerns

| Concern | How this approach addresses it |
|---------|------|
| **Overloading Postgres** | Use a read replica, pull one day at a time, spread over weeks. Zero impact on production writes. |
| **Data duplication** | Use `overwritePartitions()` with fixed batch dates — idempotent; re-runs replace rather than append. |
| **Partition corruption** | Spark writes atomic Iceberg snapshots. Queries see either old or fully-written new partition, never corrupted intermediates. |
| **Conflicting with ongoing ingestion** | Iceberg snapshot isolation + automatic retry handles concurrent commits. Scope incremental watermarks to avoid the backfill window. |
| **CSV hassle** | Spark writes Parquet directly into Iceberg, respecting your partition spec. Compaction works, Trino prunes correctly. No intermediate format needed. |
