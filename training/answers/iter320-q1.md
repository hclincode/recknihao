# Answer to Q1: NOT NULL Constraint Addition in CDC Pipeline (Iter 320)

## Why Your Debezium Pipeline Broke on a Constraint Change

The short answer: **Debezium does NOT capture constraint-only changes as events, and it should not have failed.** The pipeline failure was likely triggered by something else related to how the constraint was applied, not the constraint itself. Let me explain what actually happened and how to fix it.

### What Debezium Actually Captures

Debezium reads the Postgres write-ahead log (WAL) to capture row changes — the operations that modify data. It captures:
- **INSERTs** (new rows)
- **UPDATEs** (row changes)
- **DELETEs** (row removal)

It does **NOT** capture pure metadata operations like adding a constraint. When you run `ALTER TABLE events ADD CONSTRAINT ...`, that's a schema-only change with no row mutations underneath, so Debezium emits no events for it. The connector should continue running and streaming normally.

### Why Your Pipeline Actually Failed

Your resources mention a common troubleshooting scenario: when an engineer adds a `NOT NULL` constraint on an existing column in Postgres. Here's what probably happened:

**If you added `NOT NULL` directly to an existing column** (the pattern your question hints at):

```sql
ALTER TABLE events ALTER COLUMN some_column SET NOT NULL;
```

This statement may have **failed in Postgres itself** with an error like "column contains null values." Postgres won't let you add a NOT NULL constraint if existing rows violate it. **This failure happened before Debezium even saw it** — the ALTER statement never made it into the WAL, so Debezium is not the culprit.

However, your manual restart suggests the error appeared downstream in your CDC pipeline. Here's the likely sequence:

1. Your engineer tried to add the constraint in Postgres
2. Either the constraint addition succeeded on some rows/tables, or your application code tried to *reference* the new constraint and failed because the column definition changed slightly
3. The Spark consumer's MERGE INTO statement might have thrown a schema mismatch error if the Postgres schema changed but the Iceberg target table hadn't been updated first

### What Should Happen (The Safe Pattern)

Your resources document the **correct three-step pattern** for adding a NOT NULL constraint to a live table during CDC:

**Step 1: Add the column as nullable (if it's a new column)**
```sql
ALTER TABLE events ADD COLUMN new_col VARCHAR;
```

**Step 2: Backfill existing rows in batches** (do NOT run one giant UPDATE)
```sql
UPDATE events SET new_col = 'default_value'
WHERE new_col IS NULL AND ctid IN (
  SELECT ctid FROM events WHERE new_col IS NULL LIMIT 10000
);
-- Repeat in a loop until 0 rows updated
```

**Step 3: Add the NOT NULL constraint using the two-step safe pattern (Postgres 12+)**
```sql
ALTER TABLE events
  ADD CONSTRAINT events_new_col_nn CHECK (new_col IS NOT NULL) NOT VALID;

ALTER TABLE events VALIDATE CONSTRAINT events_new_col_nn;
```

**What happens to Debezium during this sequence:**
- **Step 1**: Debezium sees a RELATION message on the next INSERT/UPDATE and learns about the new column. New events include it (NULL for old rows).
- **Step 2**: Debezium emits normal UPDATE events (`op='u'`) for the backfilled rows. Your Spark MERGE INTO applies them like regular updates.
- **Step 3**: Debezium sees **no row events** — constraints are pure metadata. The connector continues streaming normally.

**No connector restart is needed at any step.** The constraint additions cause no WAL disruption and no schema confusion on the Debezium side.

### How to Prevent This Next Time

1. **Before adding any constraint to a live column**, check if existing rows would violate it:
   ```sql
   -- Does this column have NULLs?
   SELECT COUNT(*) FROM events WHERE some_column IS NULL;
   ```

2. **Use the safe three-step pattern above** if you're backfilling values first.

3. **Do NOT manually restart the Debezium connector after a schema change.** A restart is unnecessary and can trigger snapshot re-pulls or offset duplication, making things worse. **Restart the Spark consumer instead** (the downstream job that applies MERGE INTO) after you've updated the Iceberg table schema:
   ```bash
   kubectl scale deployment spark-events-consumer --replicas=0
   # Update Iceberg schema as needed
   ALTER TABLE iceberg.analytics.events ADD COLUMN new_col VARCHAR;
   kubectl scale deployment spark-events-consumer --replicas=1
   ```

4. **Wire up `max_slot_wal_keep_size`** in your Postgres configuration (if not already done). This prevents the #1 Debezium failure mode — replication-slot-fills-the-disk:
   ```
   # postgresql.conf
   max_slot_wal_keep_size = 50GB
   ```
   This tells Postgres to automatically invalidate a stale replication slot rather than letting the disk fill up, which would take down your application database.

### Key Takeaway

**Constraints themselves never break a CDC pipeline.** What breaks pipelines is either (a) application code trying to use a constraint that doesn't exist in the database, or (b) uncoordinated schema changes between Postgres and Iceberg without pausing the consumer. The solution is the safe three-step pattern and always updating your Iceberg target schema *before* resuming the consumer.
