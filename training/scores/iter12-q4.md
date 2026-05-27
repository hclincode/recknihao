# Iter 12 Q4 — Users table upsert: handling rows that get updated not just inserted

## Question summary
The engineer has a `users` table in Postgres that gets constant updates (name changes, plan upgrades, email changes). Their incremental Spark job only appends new rows, resulting in 10 rows per `user_id`. They need to know how to handle a mutable dimension table properly.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 2 | Two verifiable factual errors. (1) The DataFrame merge API shown — `df.writeTo(...).whenMatched().updateAll().whenNotMatched().insertAll().merge()` — is not valid syntax for Spark 3.x with Iceberg 1.5.2. The correct approach for the production stack (Spark 3 + Iceberg 1.5.2) is SQL `MERGE INTO` via `spark.sql()`, not the `writeTo()` chain. The `writeTo()` builder API gained `mergeInto()` only in PySpark 4.0, which is not the production version. More critically, the chain as written omits the join condition entirely — there is no call establishing which column to match on (e.g., `user_id = user_id`), making the code fragment non-runnable. (2) `DISTINCT ON (user_id)` is PostgreSQL syntax, not standard SQL and not supported in Trino 467. Confirmed via official Trino GitHub discussion (#17261): "DISTINCT ON is missing." The correct Trino workaround is `ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC)` filtered to row 1. An engineer who copies either code block into the production stack will get a syntax error. |
| Beginner clarity | 4 | The high-level framing is good: three clear options (full refresh, upsert, CDC), plain-English description of each, and the watermark concept is explained. The `DISTINCT ON` workaround block is readable — unfortunately it is also invalid. The MERGE concept is introduced without explaining why a JOIN condition is required, which leaves a beginner who has never seen SQL MERGE without the conceptual model needed to debug or adapt it. |
| Practical applicability | 2 | The engineer cannot use either the merge code block or the `DISTINCT ON` query in the production stack without hitting syntax errors. The full-refresh option (`createOrReplace()`) is actionable for a small users table but the answer does not surface the critical warning (from `resources/13-postgres-to-iceberg-ingestion.md`) that `createOrReplace()` drops and rebuilds the entire table — any in-flight readers see a briefly empty table. For a users table powering dashboards this matters. The CDC option is correctly marked "advanced" but gives no actionable starting point. |
| Completeness | 3 | The answer addresses the core question (three approaches for mutable tables) and the interim workaround angle. It omits: (1) the correct Trino `MERGE INTO` or Spark `spark.sql("MERGE INTO ...")` syntax with a working join condition; (2) the Trino-compatible dedup workaround using `ROW_NUMBER()`; (3) any note that Pattern B from the ingestion resource (`overwritePartitions()` with a deterministic window) is NOT a solution for a dimension table with arbitrary updates — overwrite works for partitioned fact tables, not for a single-partition users dimension; (4) soft-delete vs hard-delete distinction for the CDC option. |
| **Average** | **2.75** | |

## Topic updated

**Topic**: Postgres-to-Iceberg ingestion: full refresh, incremental, CDC, JSONB handling

- Prior avg: 3.65 (5 questions)
- New score this question: 2.75
- New running avg: (4.50 + 3.50 + 3.25 + 3.25 + 3.75 + 2.75) / 6 = **3.50**
- Status: NEEDS WORK — running average has dropped to exactly the pass threshold. The topic is at risk of falling below 3.5 if the next question in this area produces another below-average score.

## Key finding

Both code blocks in the upsert option are non-functional on the production stack. The Spark DataFrame merge API shown (`df.writeTo(...).whenMatched()...merge()`) is missing the join condition and uses an API that doesn't exist in Spark 3.x + Iceberg 1.5.2. The SQL fallback for viewing current state uses `DISTINCT ON`, which is a PostgreSQL extension that Trino 467 does not support. An engineer following this answer would hit syntax errors on both paths.

## Resource gap

`resources/13-postgres-to-iceberg-ingestion.md` needs a dedicated **"Handling mutable dimension tables (upsert pattern)"** section that covers:

1. **The correct Spark merge syntax for Iceberg 1.5.2 + Spark 3.x** — use `spark.sql()` with SQL `MERGE INTO`, not the DataFrame writeTo chain. The writeTo-based `mergeInto()` builder requires PySpark 4.0+, which is not the production Spark version. Example:

```python
# Register the incoming DataFrame as a temp view
df.createOrReplaceTempView("users_updates")

spark.sql("""
  MERGE INTO iceberg.analytics.users AS t
  USING users_updates AS s
  ON t.user_id = s.user_id
  WHEN MATCHED THEN UPDATE SET
    t.name = s.name,
    t.email = s.email,
    t.plan = s.plan,
    t.updated_at = s.updated_at
  WHEN NOT MATCHED THEN INSERT *
""")
```

2. **The Trino-compatible dedup query** for engineers stuck with existing duplicates — `DISTINCT ON` is PostgreSQL syntax and does not work in Trino 467. The correct Trino pattern is:

```sql
WITH ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY updated_at DESC) AS rn
  FROM iceberg.analytics.users
)
SELECT user_id, name, email, plan, updated_at
FROM ranked
WHERE rn = 1;
```

3. **`createOrReplace()` warning for dimension tables** — note that it drops and recreates the entire table, causing a brief window where the table appears empty to concurrent readers. Acceptable for nightly batch if readers tolerate it; not acceptable if the table is queried continuously.

4. **Why `overwritePartitions()` does not solve this problem** — that tool is for partition-scoped idempotent reloads of time-partitioned fact tables, not for dimension tables where updates span all rows regardless of partition.
