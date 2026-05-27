# Answer to Q2: Hard Deletes Invisible in Incremental Pipeline (Iter 336)

The hard delete problem you've identified is a **real and well-known limitation** of incremental watermark-based pipelines. Once a row is gone from the source, an `updated_at > last_watermark` filter can't see it anymore.

## Why this happens by design

None of the watermark columns (`updated_at`, `created_at`, `xmin`) can catch hard deletes:

| Watermark | Catches inserts | Catches updates | Catches hard deletes |
|---|---|---|---|
| `updated_at` | Yes | Yes (if maintained) | **No** |
| `created_at` | Yes | No | **No** |
| `xmin` | Yes | Yes | **No** |

A hard delete leaves no trace in the source for the pipeline to detect. This is the architectural boundary of watermark-based incremental pipelines — you're not missing a feature.

## Three options

**Option 1: Switch the table to soft deletes** (best for most cases)

Instead of `DELETE FROM`, use `UPDATE table SET deleted_at = now()`. This way:
- The row stays in Postgres, so your watermark picks it up on the next run
- Iceberg gets the row with `deleted_at = NULL` on first sync, then the updated row with `deleted_at` set when the deletion happens
- You can clean up physically deleted rows later using Iceberg's `DELETE WHERE deleted_at IS NOT NULL`

The resources recommend this pattern for most SaaS tables — it's operationally simpler than CDC and gives you control over when physical deletion happens (maintenance window, not scattered throughout the day).

**Option 2: Scheduled reconciliation** (for existing hard-delete tables you can't change)

Run a periodic job that compares what's in Postgres against what's in Iceberg, then deletes the orphaned rows:

```sql
-- Find rows in Iceberg but NOT in Postgres (candidates for deletion)
SELECT user_id FROM iceberg.analytics.dim_users
EXCEPT
SELECT user_id FROM postgres.public.users;
```

Then delete those orphaned rows from Iceberg. This is labor-intensive but doesn't require architecture changes. Works best for tables with low deletion rates (users table, not a messages table).

**Option 3: CDC via Debezium** (only if you need sub-minute freshness or high deletion volume)

Debezium streams actual DELETE events from Postgres's write-ahead log to Kafka. A Spark job consumes the stream and issues hard DELETEs in Iceberg within seconds of the source delete. This captures hard deletes accurately and immediately.

The tradeoff: CDC adds significant operational complexity (Debezium connector, Kafka topic, streaming consumer, exactly-once semantics). Only worth it if hard deletes happen frequently (like a messages table where users delete messages constantly) or you need true sub-5-minute freshness.

## Practical next steps

1. **Audit which tables actually do hard deletes.** Most SaaS apps do soft deletes for most things — it may be just a few tables.
2. **For tables you can change**: switching to `UPDATE ... SET deleted_at = now()` is usually a small app code change. Add a trigger to enforce it so no code path can bypass it.
3. **For tables you can't change**: run a weekly reconciliation query (Option 2) to detect and clean up orphans.
4. **If a high-mutation table makes Option 2 a bottleneck** (too many deletes to reconcile weekly), that's when you'd evaluate CDC.

Start with soft deletes + reconciliation — it's simpler and works for most SaaS workloads.

**Resources cited:** `/Users/hclin/github/recknihao/resources/13-postgres-to-iceberg-ingestion.md`
