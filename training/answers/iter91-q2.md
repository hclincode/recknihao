# Iter91 Q2 — Answer

**Question**: What happens to the Debezium CDC pipeline when someone runs ALTER TABLE on Postgres — adds a column, drops one, or renames one?

---

## Answer

## How Debezium detects schema changes

Debezium detects schema changes automatically through the Postgres WAL (write-ahead log). When an engineer runs `ALTER TABLE`, Postgres emits a **relation message** in the WAL describing the table's new column layout. Debezium reads this and learns about the change. No configuration or manual intervention on the Debezium side is needed for detection.

However, Debezium does NOT re-emit historical rows with the new schema. It only starts including the new field in change events that occur *after* the `ALTER TABLE` commit.

## The three schema-change cases

### Case 1: ADD COLUMN

**What Debezium does:** Detects the new column via the WAL relation message and starts emitting it in new change events. Old Kafka messages never have the new field — it's absent.

**What you must do** depends on your Debezium sink:

**If using debezium-server-iceberg standalone sink:**
- Set `debezium.sink.iceberg.allow-field-addition=true` (enabled by default).
- The sink automatically detects the new field and runs `ALTER TABLE ... ADD COLUMN` on Iceberg.
- No manual action required.

**If using Spark Structured Streaming (Kafka → Spark → Iceberg):**
- The `allow-field-addition` property does NOT apply — it's specific to the standalone sink. Spark will silently ignore it.
- You must run a manual three-step sequence:
  1. The Spark consumer will error when it hits the new field in a Kafka message (Iceberg schema doesn't have it yet).
  2. **Pause** the Spark Structured Streaming consumer.
  3. Run: `ALTER TABLE iceberg.analytics.events ADD COLUMN device_os VARCHAR` — metadata-only, completes in milliseconds.
  4. **Resume** the consumer. (Do NOT restart Debezium — it kept publishing while you paused Spark.)

**What happens in Iceberg:** Old Parquet files automatically return **NULL** for the new column on any query — no rewrite needed. This is Iceberg's foundational schema-evolution guarantee.

### Case 2: DROP COLUMN

**What Debezium does:** Detects the column is gone via the WAL relation message and stops emitting it in new events. Old Kafka messages still have the column.

**What you must do:**
1. Decide if downstream consumers (dashboards, dbt models, analysts) still reference the old column.
2. If yes — leave the Iceberg column in place. Queries will see NULLs for all new rows arriving after the Postgres drop.
3. If no — run `ALTER TABLE iceberg.analytics.events DROP COLUMN legacy_score` (metadata-only). Coordinate with downstream teams first.

**Why Iceberg doesn't auto-drop:** Iceberg tracks columns by internal IDs, not names. Dropping is a schema-level decision that could break downstream consumers — explicit DDL prevents accidental data loss from silent changes.

### Case 3: RENAME COLUMN

**What Debezium does:** Sees the old column gone and a new column appear (via two WAL relation messages at rename commit). From Debezium's perspective this looks like "drop old column, add new column."

**What you must do:**
- Run `ALTER TABLE iceberg.analytics.events RENAME COLUMN old_name TO new_name` in Iceberg.
- Iceberg's rename is **metadata-only** because it tracks columns by internal ID. Old Parquet files continue to work correctly with the new column name.

**If you end up with both names:** Drop the unused old column after confirming the rename is complete everywhere.

## Safety practices for production

**Before any schema change in Postgres:**

1. **Run a preflight check** comparing the Postgres schema to your Iceberg schema:
   ```sql
   -- Check Postgres columns
   SELECT column_name, data_type FROM information_schema.columns
   WHERE table_name = 'events' AND table_schema = 'public' ORDER BY 1;
   
   -- Check Iceberg columns (Trino)
   DESCRIBE iceberg.analytics.events;
   ```
   Alert on any mismatch before the ingestion job fails.

2. **For Spark consumers:** Add error handling that pauses on schema-mismatch so you have time to ALTER the Iceberg table before resuming.

3. **Coordinate with downstream teams:** Before dropping a column, verify no dashboards or queries still reference it.

## Is your pipeline safe?

**Yes, with one caveat:**

- **debezium-server-iceberg standalone sink:** Schema changes flow automatically. No manual intervention needed once `allow-field-addition=true` is set.
- **Spark Structured Streaming consumer:** You need monitoring and a documented pause/ALTER/resume procedure. Once that's in place, you're safe.

The biggest risk is **not knowing which scenario you're in**. Check your Debezium sink config: if you see `debezium.sink.iceberg.*` properties, you're on the standalone sink. If your code is Spark reading Kafka and merging into Iceberg, you own the ALTER TABLE step manually.
