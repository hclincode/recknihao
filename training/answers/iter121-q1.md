# Iter121 Q1 — Answer

**Question**: We have a table in Iceberg that gets updated constantly throughout the day — things like user session records where we go back and mark them as "converted" or "churned" after the fact. I noticed someone on our team mentioned there are two different ways Iceberg can handle updates under the hood, and that one of them can slow down reads over time while the other is safer but slower to write. We're seeing our dashboard queries get progressively slower each week even though the data volume hasn't changed much. Can you explain what the difference is between these two approaches, when each one makes sense, and how we'd know if we need to change which one we're using?

---

## Iceberg Update Strategies: Merge-on-Read vs Copy-on-Write

Your team is correct — there are two fundamentally different approaches Iceberg can use when you update rows, and they have opposite performance tradeoffs. Let me explain what's happening with your dashboard slowdown and how to pick the right strategy.

### The Two Approaches

**Merge-on-Read (MoR)** — the default on Iceberg 1.5.2

When you mark a user session record as "converted," Iceberg doesn't rewrite the original data file. Instead, it writes a tiny **delete file** — just a list of "row 42 in file_abc.parquet: delete this." The original data file stays untouched on MinIO.

**Trade-off:**
- **Writing is fast** — only a small delete file gets written, so your update completes quickly.
- **Reading gets progressively slower** — every query has to read the data file *plus* apply all the delete files on top of it. After weeks of updates, a single data file might have hundreds of delete files hanging off it, and each query must merge all of them together.

**Copy-on-Write (CoW)**

When you update a row, Iceberg rewrites the entire data file without that row, producing a brand-new file. No delete files are created.

**Trade-off:**
- **Writing is slow** — every update rewrites the whole data file, which is expensive.
- **Reading stays fast** — queries see clean data files with no delete-file overhead. No merge work needed at read time.

### Why Your Dashboards Are Getting Slower

You're experiencing the classic **Merge-on-Read slowdown**. Your table is probably running in MoR mode (the default). Each time someone goes back and marks a session as "converted," Iceberg creates a delete file. Those delete files pile up. On week 1, a query might have 10 delete files to apply. By week 4, the same data file might have 500 delete files, and Trino has to read and merge all 500 before returning your results. That's why the same query gets progressively slower even though the data volume hasn't changed.

### How to Know Which Mode You're Using

Check your table definition:

```sql
SHOW CREATE TABLE iceberg.analytics.events;
```

Look for a property called `write.delete.mode`. If you see `'merge-on-read'` (or nothing at all, since it's the default), you're in MoR. If you see `'copy-on-write'`, you're in CoW.

You can also diagnose accumulation directly by checking how many delete files are sitting on your table:

```sql
SELECT COUNT(*) AS delete_file_count
FROM iceberg.analytics."events$files"
WHERE content = 1;   -- 1 = position delete files
```

If this number is in the thousands (or tens of thousands), delete files are accumulating and killing your read performance.

### Choosing the Right Strategy for Your Workload

| Your situation | Use this mode | Why |
|---|---|---|
| **Frequent updates throughout the day** (like session states changing constantly) | Merge-on-Read (default), BUT schedule compaction | MoR lets writes stay fast. But you **must** run a nightly or hourly `rewrite_data_files` compaction job to fold the delete files back into the data files and restore read speed. |
| **Bulk updates in a maintenance window** (e.g., a 5 AM script that marks all conversions from the past day) | Copy-on-Write | CoW pushes the rewrite cost into your already-scheduled maintenance window. Readers get consistently fast scans all day. |
| **Mostly append-only, almost never update** | Copy-on-Write | No compaction overhead needed. Reads stay fast. CoW's write cost is paid rarely. |

### What You Should Do Right Now

**Step 1: Confirm you're in MoR mode and delete-file accumulation is the problem**

```sql
-- Check the mode
SHOW CREATE TABLE iceberg.analytics.events;

-- Count accumulated delete files
SELECT COUNT(*) AS position_delete_file_count
FROM iceberg.analytics."events$files"
WHERE content = 1;
```

If this count is > 1,000, that's your slowdown.

**Step 2: If you want to stay in MoR mode** (because writes need to stay fast)

Add a nightly compaction job to your scheduler. Run this via Spark (not Trino) every night after ingestion finishes:

```sql
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.events',
  options => map(
    'target-file-size-bytes', '268435456',  -- 256 MB
    'min-input-files',        '5',
    'delete-file-threshold',  '1'           -- rewrite any file with 1+ delete files
  )
);
```

This folds the accumulated delete files back into clean data files, and your queries return to baseline speed.

**Step 3: If you want to switch to CoW mode** (for predictable bulk updates)

If your "mark as converted" updates happen in controlled batches (e.g., a 3 AM job processes the whole day's updates), switch the table:

```sql
ALTER TABLE iceberg.analytics.events SET TBLPROPERTIES (
    'write.delete.mode' = 'copy-on-write'
);
```

This only affects *new* updates — it doesn't rewrite existing data. From that point forward, each update is slower (because it rewrites the data file), but queries never see delete-file overhead again. No compaction maintenance job needed for delete cleanup.

### The Real Cost: You Must Maintain Iceberg Regardless

**Neither mode is free.** MoR requires compaction jobs. CoW requires paying a write cost. The choice is really "where do I want to pay for it — on writes or on reads?"

Most SaaS teams running high-mutation fact tables (frequent UPDATEs/DELETEs) end up choosing MoR + nightly compaction because write throughput is critical and compaction is automated. For your session table, since you're going back and marking conversions after the fact, MoR + hourly or nightly compaction is probably the right fit — updates are frequent enough that CoW's per-write file rewrites would add up.
