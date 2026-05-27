# Iter77 Q1 — Answer

**Question**: Spark job syncing Postgres to Iceberg has been running fine for weeks. A dev added a new nullable VARCHAR column to Postgres this morning. Did the job crash? Does Iceberg auto-pick up the new column? What happens to historical rows?

---

## Answer

Don't panic — this is almost certainly fine. What actually happened depends entirely on which ingestion pattern your Spark job uses. Let me walk you through both cases.

### First: figure out which pattern your job uses

Grep your Spark code for one of these lines:

```python
# Incremental (append) — safe by default
df.writeTo("iceberg.analytics.events").append()

# Full-refresh (create-or-replace) — different story
df.writeTo("iceberg.analytics.events").using("iceberg").createOrReplace()
```

### If you use the incremental (append) pattern

**You're fine.** Here's exactly what happened:

1. **The job did not crash.** Spark's JDBC reader saw the new column in Postgres and included it in the DataFrame automatically (assuming your job uses `SELECT *` or reads the full table).
2. **The new column was written to Iceberg.** Iceberg's schema evolution is column-name-based — it accepted the new column automatically.
3. **Old rows return NULL for the new column.** This is Iceberg's schema-evolution guarantee. When you query rows written before the column existed, Iceberg fills in NULL. No special handling needed, no mismatch, no broken queries.
4. **New rows have the real value** (or NULL if the Postgres column is nullable and wasn't populated).

**No manual action needed.** The job continued running. The only exception: if your Spark job uses an explicit column list in its JDBC query (e.g., `SELECT id, tenant_id, user_id FROM events`) rather than `SELECT *`, the new column was silently excluded. In that case, add it:

```python
df = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT id, tenant_id, user_id, new_column, updated_at FROM events WHERE updated_at > '{last_ts}') t",
    properties=PG_PROPS,
)
```

Then re-run. The new column flows through to Iceberg normally.

### If you use the full-refresh (createOrReplace) pattern

This is more dangerous. Here's what happened:

1. The job ran fine this morning. The DataFrame included the new column; `createOrReplace()` rebuilt the table with the new schema. The new column appeared in Iceberg.
2. **On the NEXT run, the column will silently disappear** — unless you update your Spark code.

Why? `createOrReplace()` drops the entire Iceberg table and rebuilds it from scratch using the Spark DataFrame's schema on every run. If your Spark code doesn't explicitly include the new column in its JDBC query, the DataFrame won't have it, and the next run will define the table without it.

**The fix**: update your Spark job's JDBC query to include the new column:

```python
df = spark.read.jdbc(
    url=PG_URL,
    table="(SELECT plan_id, name, price_cents, new_column FROM public.plans) t",
    properties=PG_PROPS,
)
df.writeTo("iceberg.analytics.plans").using("iceberg").createOrReplace()
```

**Don't bother running `ALTER TABLE` on the Iceberg side for full-refresh jobs** — it gets wiped on the next run. The Spark code IS the schema definition.

### What about historical rows?

For incremental jobs: historical rows automatically return NULL for the new column. Iceberg's schema evolution handles this with no action from you. Queries work fine.

For full-refresh jobs: the table is rebuilt from scratch on every run, so "historical rows" means "whatever Postgres has right now." No gap.

### Mental model

| Pattern | New column behavior | Historical rows | Action needed? |
|---|---|---|---|
| Incremental (`append`) | Picked up automatically if using `SELECT *` | NULL for pre-existing rows (correct) | None, unless using explicit column list |
| Full-refresh (`createOrReplace`) | Picked up this run; gone on next run if not in Spark code | Table rebuilt from scratch each run | Update Spark JDBC query |

### Prevention

Add a preflight schema check to your Spark job's startup that compares Postgres's column list to Iceberg's and alerts (or fails loudly) when they diverge. This turns a silent surprise into an explicit warning before the mismatch causes problems.
