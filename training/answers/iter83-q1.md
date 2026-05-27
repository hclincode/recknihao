# Iter83 Q1 — Answer

**Question**: GDPR right-to-erasure — can Iceberg time-travel prove data was deleted? Does it survive snapshot expiry? Is it reliable for compliance?

---

## Answer

You've identified the real tension in modern compliance work: time-travel queries look like they solve GDPR audits, but snapshot maintenance can delete the evidence. Let me break down what actually happens and what you can rely on.

### How Iceberg Snapshots Enable Time-Travel Queries

Every operation on an Iceberg table creates a **snapshot** — a point-in-time version of the entire table stored as metadata. When you delete customer data, Iceberg doesn't erase the original Parquet files; it creates a **delete file** (a small marker saying "ignore these rows in those files"). The old snapshot still references those original files with the deleted rows intact.

This is why time-travel works. You can query a historical snapshot like this:

```sql
-- Query the table as it existed 30 days ago, before the deletion.

-- Spark SQL:
SELECT * FROM iceberg.analytics.events
  FOR VERSION AS OF 4823511203987654321;  -- snapshot ID

-- Trino:
SELECT * FROM iceberg.analytics."events@4823511203987654321";
```

You can also query by timestamp:

```sql
-- Trino:
SELECT * FROM iceberg.analytics.events
  FOR SYSTEM_TIME AS OF TIMESTAMP '2026-04-15 10:00:00 UTC';
```

For a GDPR audit, this looks perfect — you can prove the data existed on a specific date and that your deletion removed it. **But here's where it breaks down.**

### The Snapshot Maintenance Problem

Your maintenance jobs run `expire_snapshots` to control costs. Here's what happens:

```sql
-- Weekly cost-control maintenance
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => current_timestamp - INTERVAL '30' DAY,
  retain_last => 10
);
```

This command **physically deletes** the snapshot metadata and marks any Parquet files that *only* the expired snapshot referenced as safe to delete. Once that snapshot is expired, `SELECT FOR VERSION AS OF <that snapshot ID>` fails with "snapshot not found." **The old rows are still sitting on MinIO in those Parquet files, but you have no way to query them.**

A privacy auditor checking MinIO directly with `mc ls` would still find the files and the bytes. But your organization can no longer *query* the data to prove it existed and was deleted — the time-travel path is gone.

### Why This Matters for GDPR Right-to-Erasure

GDPR doesn't require that you be able to query historical data forever. It requires **proof of deletion**. The four-step GDPR sequence handles this correctly:

```sql
-- Step 1: Delete the rows (creates delete files)
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';

-- Step 2: Rewrite data files (merge delete files, write new files without the rows)
CALL iceberg.system.rewrite_data_files(
  table => 'analytics.events',
  where => "tenant_id = 'acme'"
);

-- Step 3: Expire snapshots IMMEDIATELY for GDPR (not 30 days later)
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => CURRENT_TIMESTAMP - INTERVAL '0' DAY,
  retain_last => 1
);

-- Step 4: Remove orphan files (sweep MinIO for strays)
CALL iceberg.system.remove_orphan_files(
  table       => 'analytics.events',
  older_than  => CURRENT_TIMESTAMP - INTERVAL '1' DAY
);
```

**The key insight**: for GDPR compliance, you don't use time-travel queries as your proof. You use Iceberg's metadata tables to prove the purge worked:

```sql
-- After completing the 4-step purge, verify:
SELECT COUNT(*) FROM iceberg.analytics."events$files"
WHERE partition.tenant_id = 'acme';
-- Expected result: 0 rows. No files contain Acme's data anymore.

SELECT COUNT(*) FROM iceberg.analytics.events
WHERE tenant_id = 'acme';
-- Expected result: 0 rows. Current snapshot has no Acme rows.
```

This is auditable and compliance-grade because it's querying Iceberg's actual metadata — what files exist and what snapshots point to them. A compliance officer can reproduce these queries, and they will get the same answer.

### The Real Tension: Cost vs. Compliance Retention

**If you run aggressive snapshot expiry (30-day retention for cost), you lose the ability to do time-travel audits beyond 30 days.** But you shouldn't be using time-travel for audits anyway.

Instead, maintain **two separate retention windows**:

1. **Query/rollback window (cost-driven, 7–30 days)**: Run your normal `expire_snapshots` with 30-day retention. This lets you time-travel and rollback recent mistakes.
2. **Compliance window (compliance-driven, on-demand)**: When a GDPR erasure request arrives, run the four-step GDPR sequence immediately with zero-day retention, and capture the metadata-table verification as your audit proof.

```sql
-- WEEKLY maintenance (normal cost control)
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => CURRENT_TIMESTAMP - INTERVAL '30' DAY,
  retain_last => 10
);

-- GDPR-triggered deletion (on-demand, NOT on weekly schedule)
DELETE FROM iceberg.analytics.events WHERE tenant_id = 'acme';
CALL iceberg.system.rewrite_data_files(table => 'analytics.events', where => "tenant_id = 'acme'");
CALL iceberg.system.expire_snapshots(
  table       => 'analytics.events',
  older_than  => CURRENT_TIMESTAMP - INTERVAL '0' DAY,
  retain_last => 1
);
CALL iceberg.system.remove_orphan_files(
  table       => 'analytics.events',
  older_than  => CURRENT_TIMESTAMP - INTERVAL '1' DAY
);
```

**Key operational rule**: Never run the zero-day aggressive expiry on the weekly schedule. That immediate expiry is only for GDPR right-to-erasure requests. Your weekly maintenance uses the 30-day window, which gives you time-travel capability while still controlling costs.

### Is Snapshot-Based Time-Travel Reliable for Compliance?

**For audit of *current* state (proving data is gone): Yes.** Use metadata tables, not time-travel.

**For audit of *historical* state (proving data existed and was then deleted): Only if you keep snapshots long enough.** A 30-day snapshot retention means you can audit deletions from the past month. If a request comes 60 days after deletion, you've already expired those snapshots — but you should have run the four-step GDPR sequence and captured the proof at the time of deletion.

**Bottom line**: Snapshot-based time-travel is a developer tool (rollback, debugging, recent audits). For compliance sign-off, use the four-step sequence with metadata-table verification. That's what auditors actually want — proof that the bytes are physically gone, not the ability to query them.
