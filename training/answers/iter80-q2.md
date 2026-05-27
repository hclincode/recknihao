# Iter80 Q2 — Answer

**Question**: Six months of running an Iceberg table with no maintenance jobs. What is the "small files problem"? What happens if you never run maintenance? What are the symptoms? How do you fix it?

---

## Answer

You won't get a hard crash, but query performance degrades steadily and eventually ingestion starts failing. Here's what's happening, how to detect it, and how to fix it.

### What "small files problem" means

Iceberg never modifies files in place. Every write operation creates a new Parquet file:
- A Spark ingestion job that runs every 5 minutes creates 288 new files per day per partition
- Each `UPDATE` or `DELETE` creates a separate delete file
- Each write creates a new snapshot entry in the table metadata

After six months of daily writes with no compaction, a single partition can have tens of thousands of tiny files, each maybe 1–10 MB instead of the target 128–256 MB. The "small files problem" is this accumulation of many tiny files where you should have a few large ones.

### What happens if you never run maintenance

The table won't break immediately, but you'll see this progression:

**Query planning overhead:** Trino must open and read metadata for every file in the scanned partitions. At 10 ms per file, 10,000 files = 100 seconds of planning before reading a single row. A query that should take 2 seconds now takes 3 minutes — then starts timing out.

**Storage bloat:** Old snapshots still reference the old small files. Iceberg's garbage collector won't delete files that any live snapshot references. So storage grows even when you're not writing new business data — the old files pile up unreleased.

**Ingestion failures:** Eventually the manifest files (the internal index of which Parquet files belong to each snapshot) become so large that Spark can't read them to commit a new write. Ingestion jobs start timing out.

### Symptoms to look for right now

Run this query to see your current snapshot state:

```sql
SELECT snapshot_id, committed_at, added_data_files_count, total_data_files_count
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 10;
```

Warning signs:
- `total_data_files_count` in the tens of thousands
- `added_data_files_count` = 1 on every row (every micro-batch write created exactly one tiny file)
- Hundreds of snapshot rows (you've been running 1,000+ snapshots with no expiry)

Other symptoms you may already be seeing:
- Dashboards timing out at a consistent 60-second mark (Trino query planning timeout)
- MinIO storage growing even when ingestion is paused (unreleased old files)
- `EXPLAIN ANALYZE` showing `Files: 8,000` for a simple 7-day query

### How to fix it — the four maintenance procedures

Run these in order. They're available from both Spark (CALL syntax) and Trino 467 (ALTER TABLE EXECUTE syntax):

**Step 1: Compaction** — merge small files into large ones (run nightly)

```sql
-- Spark SQL:
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB target
    'min-input-files',        '5'           -- only compact partitions with 5+ files
  )
);

-- OR Trino 467 equivalent:
ALTER TABLE iceberg.analytics.events EXECUTE optimize;
```

Run during a low-traffic window, after your ingestion job finishes. Storage temporarily goes UP (old files + new merged files coexist until step 3 cleans up).

**Step 2: Expire old snapshots** — release old files from snapshot hold (run weekly)

```sql
-- Spark SQL:
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);

-- OR Trino 467 equivalent:
ALTER TABLE iceberg.analytics.events EXECUTE expire_snapshots(retention_threshold => '30d');
```

Note: Trino enforces a minimum retention floor (`iceberg.expire-snapshots.min-retention`, default 7 days). You can't expire snapshots newer than 7 days via Trino without lowering that catalog property.

**Step 3: Remove orphan files** — physically delete unreferenced files from MinIO (run weekly after step 2)

```sql
-- Spark SQL:
CALL iceberg.system.remove_orphan_files(
  table      => 'analytics.events',
  older_than => current_timestamp - interval '3' day
);

-- OR Trino 467 equivalent:
ALTER TABLE iceberg.analytics.events EXECUTE remove_orphan_files(retention_threshold => '3d');
```

This is when storage actually drops. The 3-day window protects in-flight writes from being deleted as orphans.

**Step 4: Rewrite manifests** — compact the metadata index (run weekly)

```sql
CALL iceberg.system.rewrite_manifests(table => 'analytics.events');
```

After 1,000+ snapshots, the manifest files listing your data files become fragmented. This merges them, cutting query planning time from minutes to seconds. (No Trino equivalent — Spark only.)

### Recovery sequence for your 6-month backlog

Run steps 1–4 once manually in order. Expect compaction to take 30–90 minutes on 6 months of data. Don't run ingestion during compaction — if both try to commit to the same partition, one fails with a commit conflict.

After recovery, schedule ongoing maintenance:
- **Nightly** (after ingestion finishes): compaction
- **Weekly** (Sunday early AM): expire snapshots → remove orphan files → rewrite manifests

### One rule: don't delete what's still being written

Never set `older_than` below 1 day for `remove_orphan_files`. A Spark job that's mid-write hasn't committed its file yet — it would be deleted as an "orphan" before the commit lands, breaking the write.
