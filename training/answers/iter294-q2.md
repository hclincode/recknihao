# Answer to Q2: Fact Tables vs Dimension Tables for a Wide Usage Events Table

## The core rule

A **fact table** holds one row per *thing that happened* — immutable, append-only events. A **dimension table** holds one row per *entity* — users, products, plans. Dimension tables are small, change slowly, and serve as lookups.

In your case: `user_events` is the fact table. `users_dim`, `features_dim`, and `accounts_dim` are the dimension tables.

## Why keep them separate?

If you cram all 300+ columns into one mega-table, you face a real problem: when a user upgrades their plan, do you update every historical event they ever triggered? In analytics, the answer is no — you want to know "what plan were they on *when* they did X?" — but your schema makes that impossible without duplicating or rewriting data.

Separating facts from dimensions solves this. Your fact table captures what happened (immutable). Your dimensions capture *about whom or what* — and they can change over time without touching the fact table.

## Denormalization: the key optimization

Don't keep the fact and dimension tables completely separate. The Iceberg + Trino stack on your MinIO infrastructure is built for columnar storage and JOINs are *expensive* because they shuffle data across the network.

**Copy the most-queried dimension columns directly into the fact table at write time.** This is called denormalization, and it's the opposite of what you'd do in Postgres.

### Which columns to denormalize into `user_events`:

- **Always copy:** `plan_type`, `country`, `is_paying`, `signup_cohort_week`, `account_tier`
  - These are queried in `GROUP BY` and `WHERE` across many dashboards
  - Low cardinality (~10–100 distinct values), so Parquet dictionary compression makes them nearly free to store
  - No JOIN needed, faster query

- **Never copy:** email, display_name, profile_url
  - These change frequently ("people rename themselves")
  - Copying them forces you to rewrite (or live with stale) fact rows

- **Keep in a dimension table and JOIN when needed:** feature descriptions, feature owner, company size, industry
  - Rarely queried, or queried by only one dashboard
  - Better to JOIN at query time when you actually need them

### The rule of thumb

**Promote a column out of dimensions if it appears in `WHERE` or `GROUP BY` on 3+ dashboards.** Otherwise, leave it in a dimension and JOIN when needed.

## Practical schema for your usage events

```sql
-- FACT TABLE (billions of rows, append-only)
user_events (
  event_id          VARCHAR,          -- unique ID
  tenant_id         VARCHAR,          -- customer (B2B SaaS)
  user_id           VARCHAR,          -- which user
  event_name        VARCHAR,          -- 'click', 'signup', 'page_view', etc.
  occurred_at       TIMESTAMP(6),     -- when it happened

  -- Denormalized user/account attributes (queried constantly)
  plan_type         VARCHAR,          -- copied from users_dim
  country           VARCHAR,          -- copied from users_dim
  is_paying         BOOLEAN,          -- copied from users_dim
  signup_cohort_week DATE,            -- copied from users_dim

  -- Denormalized feature attributes (queried in dashboards)
  feature_name      VARCHAR,          -- copied from features_dim
  feature_category  VARCHAR,          -- copied from features_dim

  -- Flexible bag for everything else (properties not queried often)
  properties        MAP<VARCHAR,VARCHAR>
                    -- e.g., {"browser":"Chrome","device":"mobile","page":"/dashboard"}
)
PARTITIONED BY (day(occurred_at), tenant_id)

-- DIMENSION TABLE (lookup for users)
users_dim (
  user_id          VARCHAR,
  email            VARCHAR,           -- Type 1: overwrite, don't keep history
  display_name     VARCHAR,
  plan_type        VARCHAR,           -- Type 2: SCD -- keep history of plan changes
  country          VARCHAR,           -- Type 2: SCD
  is_paying        BOOLEAN,
  valid_from       TIMESTAMP(6),      -- when this version became true
  valid_to         TIMESTAMP(6),      -- NULL = still current
  is_current       BOOLEAN
)

-- DIMENSION TABLE (lookup for features)
features_dim (
  feature_key      VARCHAR,
  feature_name     VARCHAR,
  feature_category VARCHAR,
  feature_description VARCHAR,        -- not denormalized, JOIN when needed
  owner_team       VARCHAR,
  release_date     DATE
)

-- DIMENSION TABLE (lookup for accounts/tenants)
accounts_dim (
  tenant_id        VARCHAR,
  company_name     VARCHAR,
  company_size     VARCHAR,           -- not denormalized, JOIN when needed
  industry         VARCHAR,
  region           VARCHAR,
  signup_date      DATE
)
```

## How queries change

**Before denormalization** (lots of JOINs, slow):
```sql
SELECT u.plan_type, COUNT(*) AS event_count
FROM user_events e
JOIN users_dim u ON u.user_id = e.user_id AND u.is_current = TRUE
WHERE e.occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY u.plan_type;
```

**After denormalization** (no JOIN, fast):
```sql
SELECT plan_type, COUNT(*) AS event_count
FROM user_events
WHERE occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY plan_type;
```

No JOIN. Trino reads only 2 columns. Iceberg skips partitions outside your date range. Query goes from seconds to milliseconds.

## The trade-off you need to understand

If a user upgrades from `pro` to `enterprise`, all their historical events *still show* `plan_type = 'pro'`.

This is correct. You're answering "what plan were they on when they triggered this event?" — not "what plan are they on right now?" If you need the current plan, JOIN to the `users_dim` at query time and filter `WHERE is_current = TRUE`.

## For your hundreds of columns problem

Don't promote all 300 columns. Instead:

1. **Identify the 10–20 hot columns** — the ones that appear in dashboards regularly
2. **Promote those to top-level fact table columns** — typed, columnar, prunable
3. **Keep everything else in the `properties MAP`** — flexible, doesn't bloat the schema

New columns can be added to the schema later with Iceberg's `ALTER TABLE ... ADD COLUMN` (metadata-only, no file rewrite). Once you see a key getting queried regularly, promote it from the MAP to a top-level column.

## Key takeaway

The rule is not "never denormalize" — it's "denormalize strategically." Copy the 10–20 attributes that every dashboard needs. Keep the rest in dimensions and MAP columns. This gives you the query speed of a flat table with the schema flexibility of normalized dimensions.
