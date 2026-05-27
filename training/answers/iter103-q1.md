# Iter103 Q1 — Answer

**Question**: We have an events table in Iceberg that's been running for about a year and has several billion rows. Right now it's only partitioned by date. Our queries are getting slower as we add more tenants, and someone suggested we add tenant ID as a second partition column. My question is: can we just alter the table to add that new partition column, or do we have to rewrite all the data? And if we can change the partition definition without rewriting, what actually happens to the old files that were written under the old layout — do queries break on them?

---

## Answer

### Short answer

Yes, you can change the partition spec without rewriting — Iceberg supports **partition evolution**. Old files keep their old partition spec, new writes use the new spec, and queries automatically work on both. The catch: **old data won't benefit from the new partitioning until you rewrite it.** If 95% of your table was written before the spec change, 95% of your queries won't see a speedup until you rewrite those files.

---

### What happens step-by-step

**Step 1: Alter the partition spec (fast, non-destructive)**

Run this in Trino:

```sql
ALTER TABLE iceberg.analytics.user_events
SET PROPERTIES partitioning = ARRAY['day(occurred_at)', 'tenant_id'];
```

This takes seconds and changes only metadata. Iceberg records the new partition spec alongside the old one.

**Step 2: What Iceberg does with old files**

After the ALTER completes:
- **Files written before the ALTER**: stay under the old spec (only `day(occurred_at)`). They don't move, don't get deleted, don't change.
- **Files written after the ALTER**: use the new spec (both `day(occurred_at)` and `tenant_id`).
- **Queries**: work on both, transparently. Iceberg merges results from old-spec and new-spec files.

**Step 3: Do queries break on old files? No — but they're slow**

Old files are **not broken**. Queries still read them correctly. But:

A query like `WHERE occurred_at >= ... AND tenant_id = 'acme'`:
- **Prunes on `occurred_at`** — works for old AND new files.
- **Prunes on `tenant_id`** — works ONLY for new files. Old files have no `tenant_id` in their partition metadata, so Trino must open ALL old-spec files from that date range and scan inside them for `tenant_id = 'acme'`.

**Symptom**: "I added `tenant_id` to the partition spec yesterday. New data is fast, but queries spanning the last 90 days are still slow."

This is the expected behavior. The old files can't be skipped by tenant — they predate the spec.

---

### The fix: rewrite historical data

After the ALTER, run a one-time rewrite to move all old files into the new partition structure:

```sql
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.user_events',
  options => map(
    'target-file-size-bytes', '268435456',
    'min-input-files',        '1'
  )
);
```

What this does:
- Reads every existing data file.
- Rewrites them into new Parquet files organized under the new spec (grouped by `day(occurred_at)` AND `tenant_id`).
- Commits atomically — old files are cleaned up after the new snapshot is in place.

**After the rewrite**, every file is under the new spec. `tenant_id` filtering now prunes correctly on all data.

---

### Costs and gotchas

**Time:** Rewriting a multi-billion-row table takes hours. Schedule during a quiet window (overnight, weekend).

**Storage spike:** During the rewrite, new files are written before old ones are released. Expect temporary ~2x storage usage until you run `expire_snapshots` afterward to clean up unreferenced old files.

**Don't overlap with ingestion:** Run the rewrite while ingestion is paused — concurrent commits conflict.

**Safe to query during rewrite:** Yes. Iceberg's snapshot isolation guarantees queries see a consistent state throughout.

---

### Recommended process

1. **Run the ALTER** anytime — instant, no downtime.
2. **Schedule `rewrite_data_files` during off-hours** (ingestion paused).
3. **After the rewrite**, expire old snapshots to reclaim storage:
   ```sql
   CALL iceberg.system.expire_snapshots(
     table        => 'analytics.user_events',
     older_than   => current_timestamp() - INTERVAL '7' DAY,
     retain_last  => 5
   );
   ```
4. **Verify**: run a per-tenant query and check with `EXPLAIN` that Trino reports partition pruning on both `occurred_at` and `tenant_id`.

---

### Why this matters for your SaaS scale

Right now, every per-tenant dashboard query scans all tenants' files for the date range, then filters down inside the engine. Adding `tenant_id` to the partition spec (and rewriting) lets Iceberg skip entire files that belong to other tenants at the manifest level:

- **Before**: tenant query reads all 80 tenants' files for the date, filters in engine.
- **After**: Iceberg opens only that tenant's files.

At 5 TB and 80 tenants, this typically reduces per-tenant query time from 2+ minutes to 30 seconds or less.
