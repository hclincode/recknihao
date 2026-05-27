# Iter139 Q2 — Answer

**Question**: "We have a pipeline where Spark is writing CDC events from Debezium into an Iceberg table every few minutes, and we also have Trino serving dashboard queries against that same table at the same time. Last week we got an alert about a 'commit conflict.' I don't really understand what that means — does Iceberg have any locking mechanism, or can Spark and Trino step on each other? What actually happens at the storage level when two writers try to update the same table simultaneously?"

---

## The Short Answer: No Locks, But Writers Can Conflict — Readers Never Do

Iceberg has no table-level locks. Trino dashboard queries and Spark ingestion jobs do not block each other. However, **two writers** can conflict at the metadata commit step — and that's what your alert was. It's retryable and does not corrupt data. Here's exactly what happened.

---

## 1. Iceberg's Optimistic Concurrency Model

Every Iceberg write operates on **immutable files**. Once a Parquet file is written to MinIO, it is never modified. No reader or writer touches existing files — every operation creates new files.

The model:
- **Spark ingestion** writes new Parquet data files to MinIO. These files land immediately, but no snapshot references them yet.
- **Trino dashboard query** reads a fixed snapshot pinned when the query started. Concurrent Spark writes don't affect it.
- **A second writer** (e.g., a compaction job) also writes its own new files independently.

None of them interfere at the file level because they're all appending new files — never touching existing ones.

---

## 2. What a Commit Conflict Is: The Metadata Race

The conflict occurs at the **metadata level**, when two writers try to commit their snapshots simultaneously.

**The sequence that caused your alert:**

```
2:59 AM  Spark CDC micro-batch reads current snapshot: ID=4823511203987654321
3:00 AM  Nightly compaction job also reads current snapshot: ID=4823511203987654321
         (same base — both started from the same state)

3:01 AM  Both jobs independently write data files to MinIO:
         - CDC job writes new CDC event files
         - Compaction job writes merged/rewritten files

3:02 AM  CDC job commits first:
         → Writes new metadata file v19.metadata.json
         → Atomically updates Hive Metastore pointer: current = snapshot 4823511203987654322
         → SUCCESS

3:02 AM  Compaction job tries to commit:
         → Writes its own metadata file
         → Tries to update Hive Metastore pointer, based on old snapshot 4823511203987654321
         → Hive Metastore REJECTS: current snapshot is now 4823511203987654322, not 4823511203987654321
         → CommitFailedException — CONFLICT
```

The compaction job's commit failed because the table state changed between when it started and when it tried to commit.

---

## 3. The Atomic Operation: The Hive Metastore Pointer Swap

The atomic commit is a **single row update in the Hive Metastore** — the metadata pointer swap:

```
Before CDC commit:
  table.metadata_pointer → /metadata/v18.metadata.json
                            (snapshot ID 4823511203987654321)

CDC writes a new metadata file:
  /metadata/v19.metadata.json
  (snapshot ID 4823511203987654322, references new CDC data files)

CDC issues atomic swap in Hive Metastore:
  table.metadata_pointer = /metadata/v19.metadata.json   ← ATOMIC SWAP

After:
  table.metadata_pointer → /metadata/v19.metadata.json
                            (snapshot ID 4823511203987654322)
```

The Parquet data files on MinIO are already written before the commit. The atomic operation only moves the pointer. This is why object storage (MinIO) works — Parquet files can't be written atomically, but a single metadata pointer can.

---

## 4. Readers Are Always Isolated — Trino Is Never Blocked

Trino queries are unaffected by concurrent write conflicts:

- When a Trino query starts, it reads the current snapshot ID from Hive Metastore and pins it: "I am reading snapshot `4823511203987654321`."
- Even if Spark commits a new snapshot while the query runs, the Trino query keeps reading from its pinned snapshot.
- If a commit conflict causes Spark to retry, Trino is unaffected — it sees a consistent view of whichever snapshot it started with.

**Snapshot isolation**: every reader gets a fixed, consistent view. Readers are never blocked; concurrent writer failures don't affect query results.

---

## 5. Commit Conflict vs Data Corruption: They Are Not the Same

A commit conflict is **retryable and harmless**:
- The failed write produced new files in MinIO, but no snapshot references them — they're orphans.
- The `remove_orphan_files` maintenance job cleans them up weekly.
- No data is lost; no data is corrupted.

**Data corruption is impossible in Iceberg** because files are immutable. Once a file is written and referenced by a live snapshot, it cannot be overwritten or partially modified. Even if two writers produce duplicate rows, that's an application logic problem — not storage corruption.

---

## 6. How to Reduce Commit Conflicts

Your conflict was caused by your CDC ingestion (every few minutes) overlapping with your nightly compaction job. The fix is scheduling:

```
# Bad: overlap
2:00 AM - 4:00 AM   Spark CDC ingestion (writes every 2 minutes)
3:00 AM - 3:30 AM     ↑ Compaction starts mid-ingestion → CONFLICTS

# Better: no overlap
2:00 AM - 3:30 AM   Spark CDC ingestion
4:00 AM - 4:30 AM   Compaction (after ingestion fully closes)
```

**Additional strategies:**

**Increase micro-batch trigger interval:**
```python
# Instead of triggering every 2 minutes, trigger every 5-10 minutes
spark.readStream \
    .format("kafka") \
    ...
    .writeStream \
    .trigger(processingTime="300 seconds")   # 5 minutes
    ...
```
Fewer writes = fewer opportunities for conflicts. Iceberg recommends 60+ seconds for streaming ingestion.

**Scope compaction to cold partitions only:**
```python
# Only compact yesterday's partition and older — avoid today's hot partition
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.events',
        where   => 'day(occurred_at) < current_date',
        options => map('target-file-size-bytes', '268435456')
    )
""")
```
Today's partition is where CDC is actively writing. Excluding it from compaction eliminates the overlap entirely.

**Enable partial progress in compaction:**
```python
spark.sql("""
    CALL iceberg.system.rewrite_data_files(
        table   => 'analytics.events',
        options => map(
            'target-file-size-bytes', '268435456',
            'partial-progress.enabled', 'true'
        )
    )
""")
```
With partial progress, compaction commits one partition at a time. A conflict on one partition doesn't fail the entire job.

---

## 7. How Spark's Retry Logic Handles Conflicts

Spark's Iceberg writer automatically retries on commit conflict. The retry:
1. Reads the new current snapshot.
2. Re-evaluates the write against the updated state.
3. Tries to commit again.

If it fails 3+ times (the retry limit), the micro-batch fails and you get the alert. To increase resilience:

```python
spark.conf.set("spark.sql.iceberg.handle-timestamp-without-timezone", "true")
# Note: Iceberg retry count is configured at the catalog level, not per-query.
# Check your Spark catalog configuration for iceberg.commit.num-retries.
```

Check Spark logs for `CommitFailedException retry` to see how many retries are happening. One retry per night (compaction conflict) is fine. Repeated retries every micro-batch indicates a scheduling problem.

---

## Summary

| Question | Answer |
|---|---|
| Does Iceberg have table-level locks? | No — optimistic concurrency only |
| Can Trino readers be blocked by Spark writers? | No — snapshot isolation; readers are never blocked |
| What is a commit conflict? | Two writers read the same base snapshot, the second committer's atomic metadata swap is rejected |
| Is it data corruption? | No — retryable; orphaned files cleaned by remove_orphan_files |
| How to fix it? | Stagger compaction to after ingestion closes; exclude hot partition from compaction; increase micro-batch interval |
