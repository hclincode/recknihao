# Iter145 Q2 — Answer

**Question**: "Something weird happened in production. One of our developers dropped a column from a Postgres table — not added, actually dropped it — and now our Debezium pipeline seems to be behaving strangely. I don't fully understand what Debezium does when the source schema changes in ways other than adding a column. What actually happens in that case, and what should we be watching out for if someone renames a column or changes a column's data type?"

---

## How Debezium Detects Any Schema Change

Debezium does not watch Postgres for DDL statements directly. Instead, Postgres embeds an updated **WAL RELATION message** — a structural description of the table's current column layout — inline with the **first DML** (INSERT, UPDATE, or DELETE) that happens after the DDL. Debezium reads this RELATION message, updates its in-memory schema, and from that point forward emits events reflecting the new structure.

**Critical timing:** The RELATION message is only sent with the next row-level write, not at DDL commit time. If the table has no writes for an hour after a DROP, Debezium will appear not to notice the schema change during that hour. To verify immediately in non-production, force a no-op DML:

```sql
UPDATE table_name SET any_stable_column = any_stable_column WHERE id = <any_id>;
```

---

## DROP COLUMN: What Happens

When your developer dropped the column, here is what happened across each layer:

**Debezium**: On the first post-DROP DML, Debezium read the updated RELATION message and stopped including the dropped column in new events. Old events already in Kafka still contain the column — Kafka is immutable, those events don't change.

**Kafka**: Pre-drop events have the column. Post-drop events omit it entirely — it's absent from the JSON/Avro payload, not present with a null value, but completely gone:

```json
// Event BEFORE the drop (still sitting in Kafka)
{"id": 123, "name": "Alice", "legacy_score": 42}

// Event AFTER the drop (from first post-DDL DML onward)
{"id": 123, "name": "Alice"}
```

**Iceberg**: Iceberg did NOT automatically drop the column. Your Iceberg table still has `legacy_score` in its schema. Every new row written after the Postgres DROP arrives in Iceberg with NULL for `legacy_score`. No error fires — the column quietly becomes all-NULLs from the drop date forward. Old rows retain their historical values.

**What you need to do**: If you want to drop the column from Iceberg too, it's safe:

```sql
-- Trino 467
ALTER TABLE iceberg.analytics.events DROP COLUMN legacy_score;
```

This is metadata-only (doesn't touch Parquet files). The bytes remain on MinIO in old files until compaction rewrites them. Before running this, audit all downstream consumers (Trino views, dbt models, dashboards, Spark jobs) for references to `legacy_score` — they'll error once the column is gone from the Iceberg schema.

---

## RENAME COLUMN: Postgres Does This as DROP + ADD, Not Atomic Rename

This is the most dangerous misconception. When Postgres runs `ALTER TABLE events RENAME COLUMN ab_variant TO experiment_variant`, your application code sees it as an atomic rename. But to Debezium and Iceberg, **the WAL emits a DROP of the old column and an ADD of the new column**.

**Without coordination, what happens:**

1. `ab_variant` disappears from the Iceberg schema.
2. `experiment_variant` appears as a brand-new column in Iceberg — all historical rows have NULL for it.
3. The old data stored in `ab_variant` Parquet files is effectively orphaned — still on disk but no longer referenced by name.
4. Downstream queries that expect `experiment_variant` to have historical values return NULLs for all pre-rename rows.

**The correct sequence — do the Iceberg rename FIRST:**

```sql
-- Step 1: Rename in Iceberg BEFORE the Postgres rename
-- Trino 467 or Spark SQL
ALTER TABLE iceberg.analytics.events RENAME COLUMN ab_variant TO experiment_variant;

-- Step 2: Now rename in Postgres
ALTER TABLE events RENAME COLUMN ab_variant TO experiment_variant;
```

Iceberg tracks columns by numeric field ID (not name), so the Iceberg RENAME is metadata-only and takes milliseconds. After the rename, all historical Parquet files still map correctly to `experiment_variant` via their internal field IDs. When Debezium then picks up the new name from the RELATION message, the Spark consumer's MERGE INTO correctly maps the incoming `experiment_variant` events to the Iceberg column that now has the historical data.

---

## TYPE CHANGE: The Most Dangerous Case

Type changes are the hardest because the pipeline keeps running — no crash, no alert — but data can become silently corrupted.

**What happens step by step:**

1. Developer runs `ALTER TABLE events ALTER COLUMN score TYPE BIGINT` (widening from INT).
2. Postgres embeds the new type in the next WAL RELATION message.
3. Debezium starts emitting events with `score` as BIGINT.
4. Iceberg still has `score` as INT in its schema.
5. Spark's MERGE INTO tries to write a BIGINT into an INT column → **write fails with a type-mismatch error**.

**Widening vs. narrowing vs. incompatible:**

| Change | Iceberg support | Notes |
|---|---|---|
| INT → BIGINT | Safe — allowed by Iceberg spec | Metadata-only in Iceberg; no Parquet rewrite needed |
| FLOAT → DOUBLE | Safe — allowed | Metadata-only |
| Decimal precision increase (same scale) | Safe — allowed | Metadata-only |
| BIGINT → INT (narrowing) | FORBIDDEN | Can overflow; Iceberg rejects it |
| VARCHAR(100) → VARCHAR(10) | FORBIDDEN | Can truncate; Iceberg rejects it |
| INT → VARCHAR (type category change) | FORBIDDEN | Must use multi-step migration |

**The safe handling sequence for any type change:**

```bash
# Step 1: Pause the Spark consumer
kubectl scale deployment spark-events-consumer --replicas=0
```

```sql
-- Step 2: Change the type in Postgres (after consumer is paused)
ALTER TABLE events ALTER COLUMN score TYPE BIGINT;
```

```sql
-- Step 3: Change the type in Iceberg (pick the syntax for your client)

-- Trino 467 syntax:
ALTER TABLE iceberg.analytics.events ALTER COLUMN score SET DATA TYPE BIGINT;

-- Spark SQL syntax:
ALTER TABLE iceberg.analytics.events CHANGE COLUMN score score BIGINT;
```

```bash
# Step 4: Resume the consumer
kubectl scale deployment spark-events-consumer --replicas=1
```

**For unsupported type changes** (narrowing, category changes):
1. Add a new column with the target type: `ALTER TABLE ... ADD COLUMN score_v2 VARCHAR`.
2. Run a Spark backfill job to populate `score_v2` for historical rows.
3. Update the Spark consumer to write to `score_v2` for new events.
4. After validating `score_v2` data quality, drop the old `score` column.
5. Rename `score_v2` to `score` (following the safe RENAME sequence above).

---

## Summary Table

| Postgres DDL | Debezium behavior | Iceberg impact | Action required |
|---|---|---|---|
| ADD COLUMN | Auto-detected via RELATION on next DML; new events include new column | Iceberg schema doesn't auto-update | Add column to Iceberg, update Spark consumer |
| DROP COLUMN | Auto-detected; new events omit the column | Column stays in Iceberg; new rows get NULL | Drop from Iceberg (safe, metadata-only); audit consumers |
| RENAME COLUMN | Treated as DROP + ADD (not atomic rename) | Old column gone, new column appears as all-NULLs | Rename in Iceberg FIRST, then rename in Postgres |
| WIDEN TYPE (INT→BIGINT) | New events carry wider type | Iceberg retains old type; MERGE throws type error | Pause consumer → Iceberg ALTER → resume |
| NARROW/INCOMPATIBLE TYPE | New events carry new type | Iceberg type mismatch; MERGE fails | Multi-step migration: add new column, backfill, drop old |

---

## Pre-Change Checklist for Any Production Schema Change

Before any developer makes a schema change to Postgres in production:

1. **Check what downstream consumers reference the column** — search Trino views, dbt models, Spark job configs, dashboards, and application code.
2. **For RENAME**: rename in Iceberg FIRST, then rename in Postgres.
3. **For TYPE CHANGE**: pause the Spark consumer, change Postgres, change Iceberg, resume.
4. **For DROP**: audit consumers first; Iceberg drop is safe but immediate (all consumers referencing the old column will break).
5. **Do NOT restart the Debezium connector** — it picks up schema changes automatically from RELATION messages. A restart can trigger re-snapshot and produce massive duplicates.

---

## Diagnosing the Silent NULL

If the pipeline keeps running but a column has NULL for all recent rows:

1. **Was there any DML after the DDL?** — If not, Debezium hasn't seen the RELATION message yet. Force a no-op UPDATE on the table.
2. **Is the column present in Iceberg?** — Run `DESCRIBE TABLE iceberg.analytics.events`. If the column is missing, add it.
3. **Does the Spark MERGE use explicit column lists?** — If so, add the new column to the INSERT/UPDATE column list or switch to `INSERT *` / `UPDATE SET *`.
4. **Does the Spark job narrow the DataFrame before the MERGE?** — A `df.select("col1", "col2")` call that doesn't include the new column will silently drop it before MERGE sees it.
