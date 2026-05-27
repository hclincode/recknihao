# Answer to Q2: $history vs $snapshots — Which to Use for "What Did the Table Look Like at 2pm?" (Iter 332)

## The Critical Difference

**`$snapshots`** shows **every snapshot ever created** for your table — including snapshots that existed in metadata but were never the active version (e.g., snapshots from branches that were never merged, or snapshots superseded immediately before any query could read them).

**`$history`** shows the **ordered commit chain** — a linear sequence of which snapshot was the *current* one at each point in time. It captures rollbacks, branch merges, and all the actual changes readers would have seen.

## For "What Did the Table Look Like at 2pm Yesterday?"

**Use `$history`**, not `$snapshots`. Here's why:

`$history` has a `made_current_at` column showing *when each snapshot became the live version*. A rollback shows up as an older snapshot ID reappearing with a fresh `made_current_at` timestamp — so you know which snapshot readers actually saw at any given moment.

`$snapshots` shows a snapshot with a `committed_at` timestamp near 2pm, but that snapshot might never have been live — it could have been superseded immediately or exist only on an unmerged branch.

## How to Query It

```sql
-- Step 1: Find which snapshot was current at 2pm yesterday
SELECT snapshot_id, made_current_at
FROM iceberg.analytics."our_events$history"
WHERE made_current_at <= TIMESTAMP '2026-05-26 14:00:00 UTC'
ORDER BY made_current_at DESC
LIMIT 1;

-- Step 2: Query the table as it was at that snapshot
SELECT * FROM iceberg.analytics.our_events
FOR VERSION AS OF <snapshot_id>;
```

## Why This Matters: The Rollback Example

Imagine this timeline:
- 1:45 PM: Snapshot A becomes current (write succeeds)
- 1:50 PM: Bad write detected, rollback executed
- 1:51 PM: Snapshot B (older clean state) becomes current again
- 2:00 PM: You query "what did the table look like?"

`$history` shows: Snapshot A was current at 1:45, then Snapshot B became current at 1:51 — so at 2pm, readers saw Snapshot B's state. Correct answer.

`$snapshots` shows both A and B as created, but without `made_current_at`, you can't tell which one was actually live at 2pm. You might pick the wrong one.

## When to Use Each

| Use case | Table |
|---|---|
| "What did the table look like at time T?" | `$history` |
| "Does snapshot ID 12345 exist?" | `$snapshots` |
| "What operations happened recently?" (APPEND, DELETE, etc.) | `$snapshots` (has `operation` column) |
| "Walk snapshot lineage" | `$snapshots` (has `parent_id` column) |
| "Audit trail — what readers actually saw" | `$history` |

**Resources cited:** `/Users/hclin/github/recknihao/resources/17-iceberg-table-maintenance.md`
