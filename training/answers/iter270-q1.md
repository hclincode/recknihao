# Iter270 Q1 — Syncing Changed Postgres Rows into Iceberg Without Duplicates: MERGE INTO

## Answer

Yes, Trino supports `MERGE INTO` for exactly this "update if exists, insert if new" pattern — but only when the target is an Iceberg table. You read changed rows from Postgres via federation, then MERGE INTO Iceberg handles deduplication atomically. A single query does the whole job.

### Why MERGE INTO Is the Right Tool

The alternatives — separate INSERT for new rows and UPDATE for existing — are slow, unsafe (if one fails you're in a half-updated state), and error-prone. **MERGE INTO does both operations atomically in a single commit**, so readers never see a partially-updated table.

### The MERGE INTO Syntax

```sql
MERGE INTO iceberg.analytics.customers AS target
USING (
  SELECT id, tenant_id, name, email, plan, created_at, updated_at
  FROM app_pg.public.customers
  WHERE updated_at > TIMESTAMP '2026-05-26 00:00:00'
    AND updated_at <= TIMESTAMP '2026-05-27 00:00:00'
) AS source
ON target.id = source.id
WHEN MATCHED THEN UPDATE
  SET tenant_id = source.tenant_id,
      name      = source.name,
      email     = source.email,
      plan      = source.plan,
      updated_at = source.updated_at
WHEN NOT MATCHED THEN INSERT (id, tenant_id, name, email, plan, created_at, updated_at)
  VALUES (source.id, source.tenant_id, source.name, source.email,
          source.plan, source.created_at, source.updated_at);
```

Breaking this down:
- **`MERGE INTO iceberg.analytics.customers AS target`** — the Iceberg table you are syncing data into. Iceberg is the only target Trino supports for MERGE.
- **`USING (...) AS source`** — the Postgres query reading changed rows (filtered by your `updated_at` time window).
- **`ON target.id = source.id`** — the join key. Rows matching this condition are "already exist in Iceberg."
- **`WHEN MATCHED THEN UPDATE`** — customer exists in both Postgres and Iceberg → update the Iceberg row with fresh Postgres values.
- **`WHEN NOT MATCHED THEN INSERT`** — customer exists in Postgres but not in Iceberg → insert as a new row.

### Why Plain INSERT INTO Creates Duplicates

A common mistake:

```sql
-- WRONG — always appends, creates duplicates on re-run
INSERT INTO iceberg.analytics.customers
SELECT * FROM app_pg.public.customers
WHERE updated_at > TIMESTAMP '2026-05-26 00:00:00';
```

In Trino, `INSERT INTO` **always appends rows** — it does not overwrite or deduplicate. If the job runs twice on the same window, you get two copies of every changed customer. MERGE INTO is idempotent: running it twice on the same source data produces the same final state (matched rows are updated again to the same values, no new unmatched rows to insert).

### Critical Caveat: MERGE Only Works with Iceberg as Target

You cannot MERGE into a Postgres table through Trino. MERGE is supported only when the target is an Iceberg table. Since your pattern is Postgres (operational source) → Iceberg (analytics copy), this works perfectly.

### Performance: Batch Size Matters

Every MERGE rewrites the Parquet files it touches (Iceberg's Copy-on-Write default). For incremental syncs of hundreds to thousands of rows nightly, this is fast. For very large deltas (100K+ rows scattered across many partitions), MERGE rewrites many files and may take longer. Options for large batches:
- Batch in smaller time windows (hourly instead of nightly)
- Use Spark's `overwritePartitions()` for bulk partition replacement

### Nightly Sync Pattern

```sql
-- Run at 2 AM — safe to re-run (idempotent)
MERGE INTO iceberg.analytics.customers AS t
USING (
  SELECT id, tenant_id, name, email, plan, created_at, updated_at
  FROM app_pg.public.customers
  WHERE updated_at > TIMESTAMP '2026-05-26 00:00:00'
    AND updated_at <= TIMESTAMP '2026-05-27 00:00:00'
) AS s
ON t.id = s.id
WHEN MATCHED THEN UPDATE
  SET name = s.name, email = s.email, plan = s.plan, updated_at = s.updated_at
WHEN NOT MATCHED THEN INSERT (id, tenant_id, name, email, plan, created_at, updated_at)
  VALUES (s.id, s.tenant_id, s.name, s.email, s.plan, s.created_at, s.updated_at);
```

If the job fails and reruns, MERGE handles the overlap idempotently — no duplicates, no missing data.

### Summary

| Pattern | Behavior | Safe for incremental sync? |
|---|---|---|
| Plain `INSERT INTO` | Always appends — creates duplicates on retry | No |
| `DELETE + INSERT` | Idempotent partition replacement | Yes, but two statements |
| `MERGE INTO` (Iceberg target only) | Atomic upsert — update if exists, insert if new | Yes, single statement |
