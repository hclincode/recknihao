# Iter 155 Q2 — Schema Design: Denormalization and Tenant Skew

## Answer

## Your denormalization decision is correct — and here's why

You've actually made the right call early, coming from a Postgres background where you'd normally avoid data duplication at all costs.

### Why denormalize `plan_type` and `country` into events

1. **JOINs are expensive at scale in Iceberg + Trino.** A 4-way JOIN that Postgres handles fine in 50ms becomes a multi-stage shuffle across your cluster. With 800M events, denormalizing these columns at write time saves you queries that would otherwise have to JOIN against a much slower distributed system.

2. **These fields don't change after the event happened.** The critical insight: if you denormalize `plan_type` and `country` at write time (capturing the state when the event occurred), you preserve the historical truth. That's actually what analytics needs.

3. **Dictionary compression makes the storage cost free.** Both `plan_type` and `country` are low-cardinality columns (probably 5–10 distinct values for plan type, a few hundred for countries). Parquet's dictionary encoding compresses these to almost nothing — you pay virtually no storage penalty.

4. **You unlock better partitioning and query skipping.** By including these columns, you can add them to sort strategies or bloom filters. Even on a day-partitioned table, having `plan_type` denormalized lets Iceberg (via `rewrite_data_files` with sorting) cluster rows by plan within each day's files — enabling file-level skipping for queries like "show me enterprise signups."

### What about the "user changed their plan" problem?

This is actually not a bug — it's the *correct* behavior for analytics:

- **Historical events show the plan the user was on when the event happened.** If tenant A upgrades from `pro` to `enterprise` on May 15, all events from May 1–14 still show `plan_type = 'pro'`. All events from May 15 onward show `plan_type = 'enterprise'`.

- **That's exactly what you want for dashboards.** The question "how many enterprise signups did we have last month?" needs to see the *plan at the time of signup*, not the user's current plan. If you showed current plan instead, someone who signed up as `free` but upgraded to `enterprise` last week would retroactively appear as an enterprise signup — which is wrong.

- **If you genuinely need "current plan," you JOIN to a dimension table at query time:**

```sql
SELECT e.event_name, COUNT(*)
FROM user_events e
JOIN users_dim u ON u.user_id = e.user_id AND u.is_current = TRUE
WHERE u.plan_type = 'enterprise'      -- current plan only
  AND e.occurred_at >= current_date - INTERVAL '7' DAY
GROUP BY e.event_name;
```

This query fetches current plan from your dimension table and joins it to events. It's one single JOIN (not four), and the dimension table is small, so it broadcasts to every worker and completes in seconds.

### The tenant skew problem you mentioned

Your mention of "biggest tenant has 10x the data of the smallest" is real and worth addressing — but it's orthogonal to denormalization. It's a **partitioning problem**:

- **Current layout:** `PARTITIONED BY (day(occurred_at), tenant_id)`
- **The issue:** Tenant A's day partition is 10x bigger than Tenant B's day partition. Files within a day aren't balanced.

**The fix is sorting, not repartitioning:**

Instead of adding `plan_type` to the partition spec (which would create partition skew across plan tiers), use Iceberg's `rewrite_data_files` with a sort strategy to physically cluster rows within each day-tenant partition:

```sql
-- Spark SQL only
CALL iceberg.system.rewrite_data_files(
  table      => 'analytics.user_events',
  strategy   => 'sort',
  sort_order => 'plan_type ASC NULLS LAST, occurred_at ASC',
  options    => map(
    'target-file-size-bytes', '268435456'  -- 256 MB
  )
);
```

After this, rows with the same `plan_type` within the same day-tenant partition cluster together on disk:
- Per-file min/max stats on `plan_type` become narrow (instead of "this file has all plan types," it says "this file has only 'pro' and 'enterprise'")
- Iceberg's file pruner can skip files that don't match your `WHERE plan_type = 'enterprise'` filter
- Queries get faster without touching your partition design

### When you'd regret denormalization

The resources identify three cases where you should **NOT** denormalize:

1. **Columns that change frequently and you need current values.** Examples: user's email, display name, current settings. If you denormalize email into every event row, every time a user changes their email you either (a) accept stale email in old events, or (b) have to backfill/rewrite old events — both bad.

2. **Columns you almost never query.** If `payment_processor` is used in 0.1% of dashboards, leave it in a dimension table and JOIN occasionally.

3. **High-cardinality columns.** If you denormalized every distinct URL as a top-level column, you'd have millions of columns and destroy compression. Keep those in a JSON fallback.

**For `plan_type` and `country` in a SaaS events table: you made the right call.** They're low-cardinality, queried constantly (every product dashboard filters or groups by plan), and immutable at event time.
