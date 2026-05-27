# Iter95 Q1 — Answer

**Question**: We got a formal GDPR right-to-erasure request from an enterprise customer who's leaving us. All their data is in a shared Iceberg events table alongside our other tenants — same table, same files, just a `tenant_id` column on every row. I know I can run a `DELETE WHERE tenant_id = 'acme'` to remove their rows, but I've heard that Iceberg keeps old versions of the data around for something like "time travel," which means old files with their rows might still be sitting on disk even after the DELETE goes through. What's the actual sequence of steps I need to run to make sure their data is physically gone from storage — not just hidden from queries — and is there any risk of accidentally touching other tenants' data while doing this cleanup?

---

## Answer

## Why a Simple DELETE Isn't Enough

When you run `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'`, Iceberg creates a new snapshot with delete markers (small files that say "ignore these rows"). **The original Parquet files still exist on MinIO**, referenced by older snapshots. A privacy auditor scanning MinIO directly will still find Acme's bytes. GDPR compliance requires you to physically delete those bytes from storage — that's what the 4-step sequence below does.

## The 4-Step Purge Sequence (In This Exact Order)

Run all four steps in order. Each builds on the previous one; skipping steps leaves bytes on disk.

### Step 1: Delete the rows

```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

**What happens on disk:** Iceberg writes delete files (markers) that say "skip these rows in those Parquet files." The original data files remain on MinIO. `SELECT COUNT(*) WHERE tenant_id = 'acme'` now returns 0 (queries see the deletions), but the bytes are still there.

**Duration:** seconds

---

### Step 2: Compact and apply the deletes

```sql
-- Spark SQL syntax (recommended for GDPR work)
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => "tenant_id = 'acme'"
);
```

**Trino 467 alternative** (if you prefer not to use Spark, though less flexible):
```sql
ALTER TABLE iceberg.analytics.events EXECUTE optimize;
```

**What happens on disk:** Spark reads the affected Parquet files plus the delete markers, removes Acme's rows in memory, and writes **new** Parquet files without their data. A new snapshot now points at the new files. **The old Parquet files (with Acme's bytes still inside) remain on MinIO** because the previous snapshot still references them.

**Why Spark for GDPR:** Spark's `rewrite_data_files` procedure supports a `where` clause to scope compaction to Acme's partition only, avoiding unnecessary rewrites of other tenants' data. Trino's `EXECUTE optimize` compacts the whole table (less efficient for large multi-tenant tables). Both engines perform the same underlying Iceberg operation — just pick Spark when precision matters.

**Duration:** seconds to minutes (depends on Acme's data volume)

---

### Step 3: Expire old snapshots ← THIS STEP PHYSICALLY DELETES THE BYTES FROM MinIO

```sql
-- Spark SQL syntax (use this for GDPR urgency)
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp() - INTERVAL '0' DAY,
  retain_last  => 1
);
```

**Trino 467 alternative** (with a critical caveat):
```sql
ALTER TABLE iceberg.analytics.events
EXECUTE expire_snapshots(retention_threshold => '7d');
```

**Important Trino caveat:** Trino enforces a **7-day minimum-retention floor** by default. The Trino form will NOT immediately purge Acme's bytes — it keeps snapshots from the last 7 days. **For immediate GDPR compliance, run the Spark form instead**, which has no retention floor. This is the reason most teams use Spark for GDPR work.

**What happens on disk:** This is the critical step. The procedure walks Iceberg's metadata, identifies all snapshots older than the cutoff, and removes them. More importantly, it identifies Parquet data files that **no remaining snapshot references** and **issues DELETE calls to MinIO**, physically removing those files. Only after this step are Acme's bytes gone from storage.

**Duration:** seconds (fast — mostly metadata work)

---

### Step 4: Remove orphan files

```sql
-- Spark SQL syntax
CALL iceberg.system.remove_orphan_files(
  table       => 'analytics.events',
  older_than  => current_timestamp() - INTERVAL '1' DAY
);
```

**What are "orphan files"?** If a Spark ingestion job crashes after writing Parquet files to MinIO but before committing a new snapshot, those files are orphaned — they sit on MinIO forever, referenced by nothing. If such a job was writing Acme's data when it crashed, that orphan file still contains Acme's bytes.

**Why this step:** Step 3's `expire_snapshots` walks Iceberg's metadata tree. It can only delete files that *were* referenced by an expired snapshot. Orphan files were never committed to any snapshot, so `expire_snapshots` doesn't even know they exist. Step 4 scans MinIO directly and deletes any file not referenced by a live snapshot.

**The safety buffer:** The `older_than => current_timestamp() - INTERVAL '1' DAY` protects in-flight writes. A Spark job writing right now looks like an orphan until the commit lands; the 1-day window guarantees the commit has finished before the file is eligible for deletion. **Never set this shorter than 1 day** — you'll race in-flight writes and corrupt ingestion.

**Duration:** seconds to minutes (depends on MinIO size; it scans the table's object-storage prefix)

---

## Safety Considerations

**Risk of accidentally touching other tenants' data:**

The `WHERE tenant_id = 'acme'` filter in step 2 is crucial. It scopes compaction to only Acme's partition(s):

- **Step 1:** `DELETE ... WHERE tenant_id = 'acme'` — only deletes Acme's rows. Other tenants' rows in the same files are unaffected (row-level semantics, not file-level).
- **Step 2:** `rewrite_data_files(... where => "tenant_id = 'acme'")` — only rewrites files in Acme's partition. Other tenants' files are untouched.
- **Steps 3 & 4:** These operate on snapshot and orphan metadata only — they delete files based on whether *any* snapshot references them. With standard `(tenant_id, day)` partitioning, each file is physically isolated to one partition, so there is no cross-tenant risk.

**Bottom line:** As long as you correctly partition by `tenant_id` and step 2 includes the `where` clause, there is no realistic risk of deleting another tenant's data.

## Verification Checklist (for Compliance Sign-off)

After running all 4 steps:

```sql
-- 1. Confirm rows are gone from queries
SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme';
-- Expected: 0

-- 2. Confirm no files reference Acme's partition
SELECT file_path, record_count
FROM iceberg.analytics."events$files"
WHERE partition.tenant_id = 'acme';
-- Expected: 0 rows

-- 3. Confirm old snapshots are gone
SELECT snapshot_id, committed_at, operation
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at;
-- Expected: single row (the current post-purge snapshot)
```

Repeat for every Iceberg table holding Acme data (`events`, `users`, `orders`, `sessions`, etc.).

## Common Mistakes to Avoid

1. **Running only step 1 and verifying with `SELECT COUNT(*)`**: Queries return 0 so it looks done. The bytes are still on MinIO — just hidden. A privacy auditor will find them.

2. **Skipping step 4**: If any ingestion job crashed mid-flight while writing Acme's data, orphan files hold their bytes. Step 3 doesn't catch them.

3. **Using `DROP PARTITION` instead of `DELETE`**: `DROP PARTITION (day = '2026-05-25')` deletes **every tenant's** data for that day. Always use row-level `DELETE WHERE tenant_id = ...`.

4. **Running `expire_snapshots` with Trino for GDPR**: Trino's 7-day retention floor means Acme's bytes stay on disk for 7 more days. Use Spark with `retain_last => 1` for immediate compliance.

5. **Setting step 4's `older_than` too aggressively**: Setting it to minutes races in-flight Spark writes. Always use at least 1 day.
