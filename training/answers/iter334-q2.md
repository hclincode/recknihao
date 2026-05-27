# Answer to Q2: FOR TIMESTAMP AS OF — Timestamp-Based Time Travel in Iceberg (Iter 334)

Yes — Iceberg supports querying by timestamp directly, without looking up the snapshot ID first.

## The Syntax

```sql
SELECT *
FROM iceberg.analytics.events
FOR TIMESTAMP AS OF TIMESTAMP '2026-05-26 00:00:00 UTC'
WHERE your_conditions;
```

Replace the timestamp with whatever moment you want. This is supported natively in Trino 467.

## The Key Catch: "At or Before" Semantics

**`FOR TIMESTAMP AS OF T` does not return the table state at exactly time T.** It returns the table as it was at the **latest snapshot committed at or before time T**.

Concrete example: your nightly report job starts writing at 23:58 and finishes committing at 00:03. If you query `FOR TIMESTAMP AS OF TIMESTAMP '2026-05-26 00:00:00'`, you get the snapshot that existed before the report finished — meaning pre-report data, not the completed report. The commit that crossed midnight isn't visible.

This matters for:
- **Billing audits**: "end of day" may not capture writes that committed just after midnight
- **Compliance snapshots**: the data you see depends on when the commit completed, not when you think the write started

## When "At or Before" Is Good Enough

For most operational queries — "what did the table look like roughly yesterday at noon?" — the timestamp form is fine and much more convenient than hunting down snapshot IDs.

## When You Need Precision

If you need audit-grade accuracy — exactly what readers saw at a given moment — the more reliable approach is to use `$history` to find which snapshot was actually current at that time:

```sql
-- Step 1: Find which snapshot was current at that time
SELECT snapshot_id, made_current_at
FROM iceberg.analytics."events$history"
WHERE made_current_at <= TIMESTAMP '2026-05-26 00:00:00 UTC'
ORDER BY made_current_at DESC
LIMIT 1;

-- Step 2: Query that exact snapshot
SELECT * FROM iceberg.analytics.events
FOR VERSION AS OF <snapshot_id_from_above>;
```

`$history` tracks which snapshot was actually live for readers at each moment (including rollbacks), which is more accurate than `$snapshots.committed_at` for "what did readers actually see."

## Summary

| Use case | Syntax |
|---|---|
| Approximate time-travel (most cases) | `FOR TIMESTAMP AS OF TIMESTAMP '...'` |
| Exact audit (what readers saw at time T) | Query `$history`, then `FOR VERSION AS OF <id>` |

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
