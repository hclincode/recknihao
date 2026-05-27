# Answer to Q2: Snapshot-Row Null source_lsn Is Expected — and Your MERGE Needs to Handle It (Iter 333)

Yes, null `source_lsn` during Debezium's initial snapshot is completely normal and expected. This is by design — but you need to handle it explicitly in your MERGE logic or it will silently drop live CDC updates to snapshot rows.

## Why Initial Snapshot Rows Have Null LSN

When Debezium runs its initial snapshot, it reads existing rows directly from your Postgres database. These rows **did not come from the Write-Ahead Log (WAL)** — they existed before Debezium started streaming. Since LSN (Log Sequence Number) is Postgres's WAL position, snapshot rows have no WAL position to attach. The correct pattern when bootstrapping from Spark JDBC:

```python
df.withColumn("source_lsn", lit(None).cast("long"))
# bootstrap rows have no WAL LSN by definition
```

This makes bootstrap rows semantically distinct from CDC rows: null LSN means "loaded from initial snapshot, never been updated by CDC."

## Why Your Current MERGE Breaks for Snapshot Rows

Your concern is valid. In SQL, any comparison with NULL returns NULL (not true or false). So when a live CDC change arrives for a row that was loaded from the initial snapshot:

1. `WHEN MATCHED` fires (primary key matches).
2. Condition `s.source_lsn > t.source_lsn` is evaluated.
3. `t.source_lsn` is NULL (the target is a snapshot row) → `500 > NULL` evaluates to NULL.
4. NULL is falsy → the `UPDATE` does NOT fire.
5. **The live change is silently dropped** — the Iceberg row stays frozen at the snapshot version.

## The Fix: Add an IS NULL Check

Update your MERGE to allow updates when the target row has never been touched by CDC:

```sql
MERGE INTO iceberg.analytics.events t
USING events_cdc_delta s
ON t.id = s.id
WHEN MATCHED AND s.op = 'd' THEN DELETE
WHEN MATCHED AND (t.source_lsn IS NULL OR s.source_lsn > t.source_lsn) THEN UPDATE SET *
WHEN NOT MATCHED AND s.op IN ('c', 'r', 'u') THEN INSERT *
```

The guard `(t.source_lsn IS NULL OR s.source_lsn > t.source_lsn)` reads as:
- **target has no LSN yet** (initial snapshot row) → any CDC event wins
- **target has an LSN** → only newer events win (existing idempotency guard)

## How to Test This

Insert a row in Postgres before Debezium starts (it goes in via the initial snapshot with null LSN), then update that row after Debezium is streaming. Verify the update appears in Iceberg. Without the fix, the update will be silently dropped and the row stays at its snapshot value.

## Summary

- Null `source_lsn` on initial snapshot rows: **expected and correct**.
- Your MERGE dedup logic must explicitly handle null with `t.source_lsn IS NULL OR s.source_lsn > t.source_lsn`.
- Without this fix, live CDC changes to snapshot-phase rows are silently dropped — a real production correctness bug.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
