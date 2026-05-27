# Iter68 Q1 — Answer

**Question**: We sync data from Postgres into Iceberg using a Spark job that runs every hour. The job reads new rows from Postgres, transforms them, and writes them into the Iceberg table. The problem is these jobs occasionally crash partway through — maybe the cluster runs out of memory, or a network blip causes it to fail after it's already written some data but before it finishes. When the scheduler retries the job, we end up with duplicate rows in Iceberg because the partial write from the failed run is already sitting there. Right now we just delete and re-run the whole thing manually when this happens, but that's not sustainable. Is there a way to make these Spark-to-Iceberg writes safe to retry automatically, so a crashed job doesn't leave behind duplicates? What does that actually look like in practice?

---

## Answer

The problem you're describing is exactly the difference between **atomicity** (which Iceberg guarantees) and **idempotency** (which you must build into your job). Iceberg's write atomicity means a partial write that crashes before snapshot commit cannot corrupt the table — but it doesn't stop a retry from writing the same rows again. Here's how to fix it.

### Why Iceberg atomicity doesn't prevent duplicates

When a Spark write crashes, one of two things happened:

- **The snapshot committed** before the crash: data files are on MinIO and the snapshot metadata is committed. Those rows are permanently in the table. A retry writes the same rows again → duplicates.
- **The snapshot didn't commit**: data files were uploaded to MinIO but the job crashed before the snapshot commit. The table is intact — those orphan files exist on MinIO but no snapshot references them, so queries never see them. A retry writes fresh files and commits successfully.

The second case is benign. The first case — where the job succeeded at the Iceberg level but the scheduler retries it anyway — is what creates your duplicates. And `append()` has no way to detect "I already wrote these rows" — it simply appends again.

### The fix: `overwritePartitions()` with a deterministic batch window

The correct pattern is to pass the batch date as a **CLI parameter** (not derived from a mutable state file) and use `overwritePartitions()` instead of `append()`:

```python
import sys
from pyspark.sql import SparkSession
from pyspark.sql.functions import row_number
from pyspark.sql.window import Window

spark = SparkSession.builder \
    .config("spark.sql.catalog.iceberg", "org.apache.iceberg.spark.SparkCatalog") \
    .config("spark.sql.catalog.iceberg.type", "hive") \
    .config("spark.sql.catalog.iceberg.uri", "thrift://hive-metastore:9083") \
    .getOrCreate()

# Batch date comes from the scheduler — makes the job deterministic
batch_date = sys.argv[1]  # e.g., "2026-05-22"

df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM events WHERE date(occurred_at) = '{batch_date}') t",
    properties=PG_PROPS,
)

# Defensive dedup within the batch (guards against Postgres-side duplicates)
w = Window.partitionBy("event_id").orderBy(df.updated_at.desc())
df = df.withColumn("_rn", row_number().over(w)) \
       .filter("_rn = 1") \
       .drop("_rn")

# SAFE: overwrites only the partition(s) present in the DataFrame.
# Re-running for the same date reads the same rows and produces the same result.
df.writeTo("iceberg.analytics.events").overwritePartitions()
```

**Why this is idempotent**: `overwritePartitions()` atomically replaces only the partitions present in the DataFrame. Re-running for `batch_date = 2026-05-22` reads exactly the same rows from Postgres and replaces the same partition with the same data — identical result every time. No duplicates.

**Schedule your Kubernetes CronJob or Airflow task like this:**

```bash
spark-submit ingestion_job.py $(date -d yesterday +%Y-%m-%d)
```

If the pod crashes, Kubernetes restarts it with the same arguments. The retry runs the same batch date, reads the same data, and writes the same partition. No manual intervention needed.

### The critical caveat: late-arriving data

`overwritePartitions()` has one dangerous edge case: **late arrivals**. If your pipeline can receive events timestamped 3 days ago arriving today (e.g., from mobile apps that went offline), calling `overwritePartitions()` for today's batch will replace the May 20 partition only with the late rows you just received — wiping the thousands of rows already there.

If late arrivals are possible, use `MERGE INTO` instead:

```python
df.createOrReplaceTempView("events_delta")
spark.sql("""
    MERGE INTO iceberg.analytics.events AS t
    USING events_delta AS s
    ON t.event_id = s.event_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

MERGE INTO modifies only the rows matched by the join key. Existing rows not in the batch are untouched. It's also idempotent — re-running the same batch updates the same rows to the same values. The trade-off: MERGE INTO is slower than `overwritePartitions()` because it must look up existing rows.

**Rule of thumb**: use `overwritePartitions()` when your batch always covers a complete time partition (no late arrivals). Use `MERGE INTO` when late arrivals are possible or when you need a key-based upsert guarantee.

### Orphan files: the storage cleanup piece

When a write crashes before the snapshot commits, data files land on MinIO as orphans. They don't corrupt your table (no snapshot points to them), but they accumulate storage over time. Clean them up weekly:

```sql
-- Run via spark-submit (not Trino). Run in order.

-- Step 1: Compact small files into 256 MB Parquet files
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map('target-file-size-bytes', '268435456')
);

-- Step 2: Expire old snapshots so their data files become eligible for deletion
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);

-- Step 3: Delete orphan files (failed write residue)
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '3' day
);
```

The `older_than` on `remove_orphan_files` protects in-flight writes — it only removes files that have been orphaned for more than 3 days, so a write currently in progress won't be touched.

### What NOT to do

Never use `append()` for a production job that might retry:

```python
# DON'T: append() is not idempotent
df.writeTo("iceberg.analytics.events").append()
```

If the job crashes after appending and the scheduler retries, the same rows are appended again. You get 2× the rows with no error. The `append()` call itself is atomic (snapshot-level), but the job workflow is not idempotent — that's a job-level problem that Iceberg cannot fix for you.

### Summary

| Current behavior | Safe pattern |
|---|---|
| `append()` + mutable watermark → duplicates on retry | `overwritePartitions()` + batch date CLI param → idempotent |
| Manual delete + re-run on crash | Automatic scheduler retry works correctly |
| Orphan files accumulate from failed writes | Weekly `rewrite_data_files` + `expire_snapshots` + `remove_orphan_files` |

Iceberg's snapshot atomicity guarantees that a partial write cannot corrupt the table, but **idempotency is your responsibility at the job level**. Switching from `append()` to `overwritePartitions()` with a deterministic batch boundary is the change that makes automatic retries safe.
