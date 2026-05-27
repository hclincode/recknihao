# Answer to Q1: How Do I Query a Column That Changes Over Time?

## The Short Answer

You're describing a **Slowly Changing Dimension (SCD)** — a column where the value changes over time, but you need to remember what it was at any point in the past. The solution is **SCD Type 2**: instead of overwriting the old value in your nightly sync, add a new row with validity dates (`valid_from` and `valid_to`). This lets you reconstruct any user's plan at any point in history.

Instead of your current approach where the nightly sync overwrites:
```
users (user_id, plan_name)
-- nightly sync overwrites old plan
u_123 | pro        -> overwritten
u_123 | enterprise <- only this remains, history lost
```

Use SCD Type 2 in a separate dimension table:
```
users_dim (user_id, plan_name, valid_from, valid_to, is_current)
u_123 | pro        | 2025-06-01 | 2025-11-15 | false
u_123 | enterprise | 2025-11-15 | NULL       | true <- current
```

Now "who was on Pro last quarter?" becomes answerable with a simple date range query.

## Why Your Nightly Sync Breaks Analytics

Your current Postgres → Iceberg sync is applying OLTP (online transaction processing) logic to OLAP (analytical) storage:
- **Postgres is optimized for current state.** You UPDATE rows to show what's true right now.
- **Iceberg is optimized for history.** You append rows to record what happened and when.

When your Spark ingestion job overwrites the users table each night, you're losing the ability to answer historical questions. Last quarter's plan is gone forever.

## The Solution: SCD Type 2 with Validity Dates

Create a `users_dim` (dimension) table separate from your events. Track changes by closing old rows and adding new ones:

```sql
users_dim (
  user_id         VARCHAR,
  plan_name       VARCHAR,      -- Type 2: keep history
  country         VARCHAR,      -- Type 2: keep history
  email           VARCHAR,      -- Type 1: just overwrite (cosmetic)
  valid_from      TIMESTAMP(6), -- when this version became true
  valid_to        TIMESTAMP(6), -- when it stopped (NULL = current)
  is_current      BOOLEAN       -- flag for fast "current" queries
)
```

**SCD Type 1** (overwrite on change): Use for cosmetic fields like `email` or `display_name` where you only ever need the current value.

**SCD Type 2** (history with dates): Use for columns that drive business decisions — `plan_name`, `account_tier`, `country` — anything you might slice a dashboard by at a point in time.

## Querying Historical Values

Find a user's plan at a specific date:
```sql
SELECT u.plan_name
FROM users_dim u
WHERE u.user_id = 'u_123'
  AND TIMESTAMP '2025-08-10 12:00:00' >= u.valid_from
  AND (u.valid_to IS NULL OR TIMESTAMP '2025-08-10 12:00:00' < u.valid_to);
-- Returns: 'pro' (because the user was on pro from Jun 15 to Nov 15)
```

Count users who were on Pro during last quarter:
```sql
SELECT COUNT(DISTINCT user_id)
FROM users_dim
WHERE plan_name = 'pro'
  AND valid_from < TIMESTAMP '2025-10-01 00:00:00'        -- started before Q4
  AND (valid_to IS NULL OR valid_to >= TIMESTAMP '2025-07-01 00:00:00'); -- active during Q3
```

Get current plan for all users (fast):
```sql
SELECT user_id, plan_name
FROM users_dim
WHERE is_current = TRUE;
```

## Maintaining SCD Type 2 During Your Nightly Syncs

Your Spark ingestion job needs to compare the new Postgres snapshot to the current dimension and:
1. For any user where `plan_name` changed: close the old row with `valid_to = now()`, `is_current = FALSE`.
2. Insert a new row with `valid_from = now()`, `valid_to = NULL`, `is_current = TRUE`.
3. For Type 1 columns (email, display_name): just overwrite in the current row.

**The easiest way: use dbt snapshots.** dbt has built-in SCD Type 2 support via the `snapshot` materialization — it automates all the close-old-row / insert-new-row logic for you:

```sql
-- snapshots/users_snapshot.sql
{% snapshot users_snapshot %}
  SELECT
    id as user_id,
    email,
    display_name,
    plan_name,
    country,
    account_tier
  FROM {{ source('postgres', 'users') }}
{% endsnapshot %}
```

dbt automatically adds `dbt_valid_from`, `dbt_valid_to`, and `dbt_is_current` columns. Every nightly run, it compares the snapshot to the previous one, closes old rows when values change, and inserts new ones. You write zero merge logic.

## SCD Type 1 vs Type 2: Quick Decision Rule

| Column | Type | Why |
|--------|------|-----|
| User's email | Type 1 | Cosmetic. You only want current. |
| User's display name | Type 1 | Cosmetic. You only want current. |
| User's plan tier | **Type 2** | Drives revenue/churn dashboards. History matters. |
| User's country | **Type 2** | Geo slicing in dashboards. History matters. |
| User's sales rep | **Type 2** | Revenue attribution. Historical assignment matters. |
| User's "is_internal" flag | **Type 2** | Excludes internal usage. Historical flag matters. |

## Key Takeaway

Stop overwriting your users table. Create a `users_dim` dimension table, use SCD Type 2 for business-logic columns (plan, tier, country), use dbt snapshots to automate the sync logic, and query with date range predicates to reconstruct history. This is the standard pattern across all analytics systems.
