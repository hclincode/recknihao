# Iter56 Q1 — Answer

**Question**: We had a customer cancel their contract and submit a GDPR "right to erasure" request, which means we're legally obligated to delete all of their event data. All our tenants share one big `events` Iceberg table partitioned by date, so their rows are scattered across many files alongside other customers' data. I know Iceberg supports DELETE FROM with a WHERE clause — will that actually remove the rows from the underlying files, or does it just mark them somehow? And I'm worried that even after a delete, we might have old backups or snapshots somewhere that still contain their data. How do we make sure their rows are really gone all the way down to the storage layer?

---

## Answer

This is a critical compliance question, and the short answer is: **a simple DELETE is not enough for GDPR.** Your deleted customer's bytes are still on MinIO (the object storage backing Iceberg) until you complete a 3-step procedure.

### Why DELETE alone doesn't work

Iceberg uses MVCC — multi-version concurrency control. When you run `DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme'`, here's what actually happens:

1. Iceberg creates a **new snapshot** (a point-in-time version) of the table
2. The new snapshot contains **delete files** — small markers that say "ignore these rows in those Parquet files"
3. The original Parquet data files containing Acme's rows **stay on MinIO unchanged**
4. Older snapshots of the table still reference the original Parquet files (without any delete markers)

So when a compliance auditor checks MinIO directly, they still find Acme's bytes sitting there. If you only run DELETE and stop, you are not GDPR-compliant — the data is hidden from queries but not physically gone.

### The correct 3-step sequence (in order)

You must complete all three steps, in this exact order. Steps 2 and 3 are Spark procedures, not Trino SQL:

**Step 1: DELETE the rows (Trino or Spark SQL)**
```sql
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
```

At this point: Acme's data is hidden from queries, but the original Parquet bytes still exist on MinIO.

**Step 2: rewrite_data_files (Spark SQL only)**
```sql
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => "tenant_id = 'acme'"
);
```

What this does: Spark reads the affected Parquet files, applies the delete files in memory, and writes new Parquet files without Acme's rows. A new snapshot now points to these new files. But the **old Parquet files still exist on MinIO** because the previous snapshot still references them.

**Step 3: expire_snapshots (Spark SQL only) — this is the step that deletes the bytes**
```sql
CALL iceberg.system.expire_snapshots(
  table        => 'analytics.events',
  older_than   => current_timestamp() - INTERVAL '0' DAY,
  retain_last  => 1
);
```

What this does: Iceberg identifies Parquet data files no longer referenced by any live snapshot and issues DELETE calls to MinIO, removing them permanently.

**Only after step 3 are Acme's bytes physically gone from MinIO.**

### Why the order matters

Always: DELETE → rewrite_data_files → expire_snapshots. If you expire snapshots before rewriting data files, snapshot expiry may delete files that newer snapshots still need, corrupting the table.

### Verification checklist

1. Run the DELETE — confirm `SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id = 'acme'` returns 0
2. Run rewrite_data_files (Spark)
3. Run expire_snapshots with aggressive retention (`older_than => current_timestamp() - interval '0' day, retain_last => 1`)
4. Verify storage layer: list the MinIO prefix for the table and confirm no Parquet files contain Acme's data

**Only after all verifications pass, sign off on the erasure request.**

### Important caveats for your setup

- **Between step 1 and step 3, the deletion is reversible.** If you deleted the wrong tenant, you can roll back to the pre-delete snapshot. After step 3, the data is permanently gone — this is what GDPR requires, so sanity-check the `tenant_id` before step 1.

- **The `older_than => current_timestamp() - interval '0' day` setting is aggressive** — it immediately expires the most recent snapshot, breaking time-travel to recent data. Use this only for GDPR hard-deletes. For routine maintenance, use `older_than => current_timestamp() - interval '7' day`.

- **If your table uses Merge-on-Read mode**, compaction via `rewrite_data_files` before snapshot expiry is important to force physical row removal before old snapshots are dropped.

### Summary

| Step | What changes | Bytes still on MinIO? |
|---|---|---|
| DELETE FROM | New snapshot with delete markers | Yes |
| + rewrite_data_files | New Parquet files without deleted rows | Yes (old files still referenced by old snapshot) |
| + expire_snapshots | Old snapshots removed, MinIO DELETEs orphaned files | **No — GDPR compliant** |
