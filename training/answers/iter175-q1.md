# Iter 175 Q1 — Why Trino Sends BETWEEN Instead of IN-List and How to Fix It

## Answer

You've encountered **domain compaction** — an intentional feature of Trino's JDBC connector that trades filtering precision for payload size. Here's why it happens and how to fix it.

### (1) Why Trino Switches from IN-list to BETWEEN

The degradation happens at two independent stages, each with its own threshold:

**Stage 1 — Coordinator side (what Trino generates internally):**
- **`max-distinct-values-per-driver`** (default: **1000**) — if the build side produces more than 1000 distinct values per driver, Trino switches the dynamic filter from an IN-list to a min/max range internally.
- **`max-size-per-driver`** — if the total byte size of collected values exceeds the limit, Trino also switches to a range.

**Stage 2 — JDBC connector side (what Postgres actually receives):**
- **`domain-compaction-threshold`** (default: **256**) — even if Trino kept the IN-list internally (within the coordinator's 1000-value limit), the PostgreSQL connector compacts it to `BETWEEN` before sending SQL to Postgres if the IN-list exceeds 256 distinct values.

**This is why you see BETWEEN with only ~300 build rows.** You had 300 distinct join keys, which stayed below `max-distinct-values-per-driver=1000` (coordinator kept the IN-list), but exceeded `domain-compaction-threshold=256` (JDBC connector compacted it to BETWEEN before sending to Postgres). The three thresholds are separate and fire independently.

### (2) Does BETWEEN Help Postgres?

**Yes, but weakly.** A range filter is much less precise than an IN-list:

- `WHERE user_id IN (1, 5, 17, 42)` eliminates every row except those 4 exact values.
- `WHERE user_id BETWEEN 1 AND 950` keeps all 950 rows, including the 646 you don't actually want.

For Postgres specifically: range filters can still use index range scans, which is better than a full table scan. But Postgres will read far more rows from disk/buffer cache than necessary, then filter in-engine. Compared to an exact IN-list, you may be returning 10–100× more rows over JDBC for the same join.

The answer depends heavily on how clustered your join-key values are. If your 300 build-side keys span IDs 1–950 continuously with few gaps, BETWEEN is nearly as efficient as IN. If they're sparse (e.g., IDs scattered across 1 to 1,000,000), BETWEEN is almost useless — Postgres returns the vast majority of rows.

### (3) The Three Knobs — Which One to Tune for Which Symptom

| Knob | Where it acts | Default | When to tune |
|---|---|---|---|
| `domain-compaction-threshold` | JDBC connector (Postgres catalog properties) | **256** | **Most common fix**: you see BETWEEN with hundreds of build rows. Raise to 1000–10000. |
| `max-distinct-values-per-driver` | Coordinator (cluster config) | 1000 | Rarely — only if build side has thousands of distinct keys and you want internal IN-lists above 1000. |
| `max-size-per-driver` | Coordinator (cluster config) | size-based | When IN-list is huge in bytes (long string keys, UUIDs). |

### (4) How to Preserve the IN-list — Raise `domain-compaction-threshold`

In your PostgreSQL catalog properties file:

```properties
# In etc/catalog/app_pg.properties
domain-compaction-threshold=10000
```

This tells the JDBC connector to preserve IN-lists up to 10,000 distinct values before compacting to BETWEEN. The tradeoff: larger IN-lists are bigger SQL strings sent to Postgres. Beyond ~10,000 values, Postgres's query planner itself may struggle. Test on a non-production replica first.

You can also set it per session for a specific query:
```sql
SET SESSION domain_compaction_threshold = 1024;
```

### (5) Verify with EXPLAIN and Postgres Logs

**From Trino EXPLAIN:**
```sql
EXPLAIN (TYPE DISTRIBUTED)
SELECT ... FROM iceberg.lookups.small_table l
JOIN app_pg.public.users u ON l.id = u.id;
```

On the Postgres `TableScan` node (the probe side):
- `dynamicFilters = {user_id IN (...)}` → IN-list preserved, good.
- `dynamicFilters = {user_id BETWEEN ... AND ...}` → compacted to range, consider raising `domain-compaction-threshold`.

**From Postgres (the definitive check):**

Enable logging temporarily on the replica:
```sql
SET log_min_duration_statement = 0;
SELECT pg_reload_conf();
```

Tail the logs — you'll see the exact SQL Postgres received. If it's `WHERE user_id IN (...)`, the IN-list made it through. If it's `WHERE user_id BETWEEN 100 AND 950`, compaction fired.

**From EXPLAIN ANALYZE:**

On the Postgres probe-side scan, look for:
- `Filtered: <percentage>` — non-zero means rows were eliminated at the source. If `Filtered: 0%` with a BETWEEN filter and sparse keys, the range wasn't selective.
- `dynamicFilterSplitsProcessed = N` — non-zero confirms dynamic filtering pruned splits at runtime.
