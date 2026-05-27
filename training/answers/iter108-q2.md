# Iter108 Q2 — Answer

**Question**: Last week someone on the backend team added a new nullable column to our `subscriptions` table in Postgres. Our Spark job that incrementally loads that table into Iceberg started failing that night — the job threw a schema mismatch error because the Iceberg table didn't have the new column. We had to wake someone up at 2am to do a full reload to fix it. Is there a way to set up the ingestion pipeline so that when a column gets added to a Postgres table, the Iceberg side picks it up automatically without us having to do a manual full refresh every time? And does it matter whether we're doing incremental Spark loads vs CDC through Debezium?

---

## Answer

Your 2am wake-up call was a schema mismatch between Postgres and Iceberg — a painful but solvable problem. The resources show three distinct paths to handle schema evolution automatically, depending on which ingestion pattern you use.

### The core issue: why Iceberg didn't auto-evolve

When your backend team added a nullable column to the `subscriptions` table in Postgres, your Spark JDBC job continued reading the old column set. When it tried to write to Iceberg, the DataFrame's schema didn't match the table's schema, so the write failed. **Iceberg itself is fine with schema evolution** — it automatically handles adding columns to the table definition — but your Spark job's DataFrame-to-table write was the bottleneck.

### Solution 1: Enable automatic schema evolution (Incremental Spark + JDBC)

For incremental Spark loads reading from Postgres via JDBC, add `mergeSchema(True)` to your write step:

```python
df = spark.read.jdbc(
    url=PG_URL,
    table=f"(SELECT * FROM subscriptions WHERE updated_at > '{last_ts}') sub",
    properties=PG_PROPS,
)
df.persist()  # important: avoid re-reading Postgres twice for max watermark
df.writeTo("iceberg.analytics.subscriptions").mergeSchema(True).append()
```

**What happens:** Spark reads the latest column set from Postgres (including the new nullable column). When the write executes, `mergeSchema(True)` detects that the DataFrame schema differs from the Iceberg table schema and **automatically runs `ALTER TABLE ... ADD COLUMNS`** for any missing columns. Old Parquet files don't get rewritten — they transparently return NULL for the new column on query. Future rows populate the column; historical rows show NULL. No full reload needed.

This is exactly what you want for a nullable column — it doesn't break anything.

### Solution 2: If you're using MERGE INTO (safer for late arrivals)

If you've switched from `.append()` to MERGE INTO to handle late-arriving rows (the safer pattern for fact tables), schema evolution still works:

```python
df.createOrReplaceTempView("subscriptions_delta")
spark.sql("""
    MERGE INTO iceberg.analytics.subscriptions t
    USING subscriptions_delta s
    ON t.subscription_id = s.subscription_id
    WHEN MATCHED THEN UPDATE SET *
    WHEN NOT MATCHED THEN INSERT *
""")
```

Iceberg detects the schema mismatch during the MERGE and evolves automatically. Your `SELECT *` in the JDBC read ensures the new column is included.

### Solution 3: CDC via Debezium (different knob, same outcome)

If you switch to CDC with Debezium streaming the Postgres WAL to Kafka and into Iceberg, schema evolution is controlled by a different setting:

**Option A — debezium-server-iceberg sink:**
```properties
# in debezium-server application.properties
debezium.sink.iceberg.allow-field-addition=true
```
The Debezium sink detects when Postgres adds a column, emits it in change events (for rows modified after the ALTER TABLE), and runs `ALTER TABLE ... ADD COLUMNS` on the Iceberg side automatically. Old events lack the field — Iceberg returns NULL for them on query.

**Option B — Spark Structured Streaming consuming Debezium events from Kafka:**
The `allow-field-addition` setting is ignored here — responsibility falls on the Spark consumer. Use `mergeSchema(True)` on the write (same as Pattern 1). The standalone Debezium-to-Iceberg sink auto-evolves; a Spark consumer of Debezium events does not.

### Which pattern applies to you?

From your description (Spark job failing with schema mismatch, requiring full reload), you're on **incremental Spark + JDBC**. The fix is immediate: add `mergeSchema(True)` to your write step. Next time a column is added, the job self-heals.

### Does CDC handle schema evolution better?

Both patterns handle new nullable columns correctly. The real differences are elsewhere:

| Aspect | Incremental JDBC | CDC/Debezium |
|---|---|---|
| **New nullable columns** | Works with `mergeSchema(True)` | Works with `allow-field-addition=true` |
| **Freshness** | Same-night or daily | Real-time (seconds) |
| **Hard DELETEs** | Invisible (use soft deletes) | Captured accurately |
| **Operational complexity** | Simple: Spark + JDBC only | Higher: Kafka + debezium-server + monitoring |
| **Schema change automation** | One setting, no manual step | One setting, no manual step |

**For your immediate problem:** incremental JDBC with `mergeSchema(True)` is the right fix — simpler, cheaper, and handles schema evolution identically to CDC.

### Prevention checklist

1. Add `mergeSchema(True)` to your Spark write immediately.
2. Test it: add a test column to a dev Postgres table, run the job, verify Iceberg picks it up.
3. Consider switching to MERGE INTO instead of `.append()` — it guards against late arrivals (the other common cause of silent data loss in incremental loads).
4. Add a CI check: when a Postgres migration adds a column, run the Spark job against a staging Iceberg table and verify no schema mismatch error.
