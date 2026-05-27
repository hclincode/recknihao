# Iter77 Q2 — Answer

**Question**: Iceberg events table partitioned by `day(occurred_at)` for 18 months. Want to switch to `hour(occurred_at)` for hourly dashboards. Does this rewrite history? Can old and new partitioning coexist? Can I do this without downtime?

---

## Answer

Good news on all counts: changing the partition spec does not rewrite historical data, old and new partitioning coexist transparently, and you don't need to take the table offline. This is called *partition evolution* and Iceberg was designed for it.

Here's exactly how it works and what you need to do.

### What happens when you change the partition spec

Run this in Trino (instant, zero-downtime):

```sql
ALTER TABLE iceberg.analytics.user_events
SET PROPERTIES partitioning = ARRAY['hour(occurred_at)'];
```

After this command:

1. **Old files stay exactly where they are.** The 18 months of Parquet files on MinIO remain organized by day. Iceberg does NOT rewrite them.
2. **New writes use hour-level partitioning.** Any data ingested after this change lands in hour-level Parquet files.
3. **Queries work transparently across both.** Trino understands that files have different partition specs (Iceberg tracks a `spec_id` per file) and handles both correctly in the same query.

### The critical catch: historical queries won't be faster yet

This is the part that surprises people. After changing the spec, a query for "events between 2pm and 3pm on May 20th" will still scan the entire May 20th day-level file — because that's how the old data is physically stored. The new hour-level partition spec only applies to new writes; it can't retroactively reorganize existing files.

**You'll notice:** recent data (written after the spec change) returns fast for hour-level filters. Historical data (the 18 months of day-level files) still scans full days.

### Rewriting historical data (one-time, optional but recommended)

To make historical queries fast too, rewrite the old files under the new partition spec. This is a Spark operation:

```sql
-- Run in Spark (not Trino — CALL procedures are Spark-only)
CALL iceberg.system.rewrite_data_files(
  table   => 'analytics.user_events',
  options => map(
    'target-file-size-bytes', '268435456',
    'min-input-files',        '1'
  )
);
```

This reads your existing day-level Parquet files and rewrites them as hour-level files. Expect 30–90 minutes for 18 months of data. It's safe to run while queries and ingestion continue — Iceberg's snapshot isolation means in-flight queries keep reading the old files until they finish.

After the rewrite completes, run snapshot expiry to free storage (the old day-level files still exist on MinIO until the snapshots referencing them are expired):

```sql
-- Also Spark-only
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.user_events',
  older_than  => current_timestamp - interval '30' day,
  retain_last => 10
);
```

### Timeline

| Phase | Duration | What queries see |
|---|---|---|
| After `ALTER TABLE` | Instant | New writes: fast hour-level pruning. Historical: still day-level scans. |
| During `rewrite_data_files` | 30–90 min | No change to queries (snapshot isolation). Storage temporarily doubled (old + new files). |
| After `rewrite_data_files` | Instant | All queries benefit from hour-level pruning, including historical data. |
| After `expire_snapshots` | Minutes | Storage back to normal; old day-level files deleted from MinIO. |

### Can I do this without taking the table offline?

Yes. The `ALTER TABLE` is instant and the table stays fully readable and writable throughout. The `rewrite_data_files` runs in the background — existing queries see the old layout via snapshot isolation, new queries see the new layout as soon as it completes.

### Summary

- **`ALTER TABLE SET PROPERTIES partitioning`**: changes the spec for future writes only. Zero downtime, zero data rewrite. Run it now.
- **`rewrite_data_files`**: rewrites historical files to the new spec. Run it during a low-traffic window. Required for historical queries to benefit from hour-level pruning.
- **Old and new partitioning coexist indefinitely**: queries work correctly whether or not you ever run the rewrite.
