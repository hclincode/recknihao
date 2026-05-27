# Answer to Q1: Should I Normalize or Denormalize my Iceberg Tables?

## The Short Answer

**No — don't recreate your Postgres schema in Iceberg.** That's the single biggest mistake teams make when migrating to a lakehouse.

Your Postgres database forces you to normalize (break customers, orders, and line items into separate tables with foreign keys) because storage is expensive and you need to update records constantly. On your stack (Iceberg + MinIO + Trino), **storage is cheap and JOINs are expensive**. The rules flip.

Instead:
1. Use a **star schema** — one big fact table with the events/transactions, plus a few small dimension tables for lookups.
2. **Denormalize aggressively** — copy the columns you query most often directly into the fact table at write time.
3. Stop thinking about disk space; start thinking about query speed and engineer time.

## Why Your Postgres Instinct Fails on Iceberg

In Postgres, a simple question like "signups by plan tier, by country" means writing a 4-way JOIN:

```sql
SELECT p.name, c.name, COUNT(*)
FROM events e
JOIN users u ON u.id = e.user_id
JOIN plans p ON p.id = u.plan_id
JOIN countries c ON c.id = u.country_id
WHERE e.event_name = 'signup'
GROUP BY p.name, c.name;
```

**Why this hurts in your Trino + Iceberg setup:**
- Each JOIN is a **shuffle** — data has to move across the network between nodes in your Kubernetes cluster.
- Trino has to estimate cardinalities for every JOIN; one bad estimate and your query takes 10x longer.
- Your engineering team has to rediscover the join graph for every new dashboard.

The cost of a JOIN in a distributed system is completely different from a single-node Postgres. On Postgres, that query might take 50ms and your DBA considers it fine. On Trino scanning billions of rows, that same JOIN pattern takes seconds or minutes.

## Star Schema: The Standard Layout for Analytics

A **star schema** has one central fact table (huge, append-only) surrounded by smaller dimension tables (small, lookup-only).

```
                 +-----------+
                 |   plans   |   <- dimension table
                 +-----------+
                       |
                       |
   +-----------+   +---------------------+   +------------+
   |   users   |---|     user_events     |---| countries  |
   | (dim)     |   |   (fact table)      |   | (dim)      |
   +-----------+   +---------------------+   +------------+
                       |
                       |
                 +-----------+
                 | products  |   <- dimension table
                 +-----------+
```

**Fact table** = things that happened. One row per event, order, page view, or subscription change. Append-only. Becomes billions of rows over time.

**Dimension table** = descriptions of entities. One row per user, product, plan, country. Small (hundreds to thousands of rows). Changes slowly.

This is much simpler than a Postgres-style schema where every lookup table joins to others. Most of your queries in analytics are fact + 1 or 2 dimensions, not a chain.

## Denormalization: The Next Step (Copy Attributes Into the Fact Table)

Once you have star schema working, the next optimization is copying the most-queried dimension columns directly into the fact table at write time. This eliminates even those 1-2 JOINs for your most common queries.

**Before (star schema, one JOIN required):**
```
user_events:  (user_id, event_name, event_time)
users_dim:    (id, plan_type, country, signup_date)

Query:
SELECT COUNT(*) FROM user_events e
JOIN users_dim u ON u.id = e.user_id
WHERE u.plan_type = 'enterprise' AND e.event_time >= current_date - INTERVAL '7' DAY;
```

**After (denormalized, no JOIN):**
```
user_events:  (user_id, event_name, event_time, 
               plan_type, country, signup_date)   <- copied from users at write time

Query:
SELECT COUNT(*) FROM user_events
WHERE plan_type = 'enterprise' AND event_time >= current_date - INTERVAL '7' DAY;
```

No JOIN. Trino reads only the 3 columns you need (because Parquet is columnar). Iceberg skips all files outside the date range (partition pruning). Query goes from seconds to milliseconds.

**The mental shift:** if a user upgrades from `pro` to `enterprise`, the old events still show `pro`. That's correct for analytics — the question is "what plan were they on **when** they did X?" — not "what plan are they on right now?" If you ever need current values, you JOIN to the dimension at query time.

## Practical Recipe for a SaaS Product

Start with **2-3 fact tables**:

| Fact table | One row per | Columns to denormalize |
|---|---|---|
| `user_events` | event by user | `plan_type`, `country`, `signup_cohort_week`, `is_paying` |
| `subscription_changes` | plan transition | `old_plan`, `new_plan`, `country`, `industry` |
| `feature_usage` | feature interaction | `feature_category`, `plan_type` |

Plus small dimension tables: `users_dim`, `plans_dim`, `tenants_dim`, `features_dim`.

**Rule of thumb:** if a column shows up in `WHERE` or `GROUP BY` on more than 3 dashboards, copy it into the fact table.

## Why Iceberg Makes Denormalization Safe

Iceberg has schema evolution — you can add columns without rewriting data:

```sql
ALTER TABLE user_events ADD COLUMN device_type VARCHAR;
```

This is metadata-only. New rows get the column; old rows return NULL. **This means you can promote new attributes to the fact table later without a costly rewrite.** Start with a smaller denormalized schema and expand it as your dashboards grow.

## What NOT to Do

**Do not copy your Postgres 3NF schema into Iceberg unchanged.** Teams that do this end up with:
- 12 normalized tables that all need to be JOINed for any non-trivial query.
- Trino queries that are 10x slower than they should be.
- Engineers writing the same JOIN logic over and over in every dashboard.
- Six months later, realization that the schema is wrong — but now you have terabytes of data.

Instead, when migrating, treat it as a redesign. The fact tables on the lakehouse should look **nothing** like the OLTP tables they came from. Use your Spark ingestion job to flatten and denormalize on the way in.

## Concrete Example: Your Events Table

If you have Postgres like this:

```
users (id, email, plan_id, country_id, created_at)
plans (id, name, tier)
countries (id, name, region)
events (id, user_id, event_name, created_at)
```

Your Iceberg version should be:

```
user_events (
  event_id VARCHAR,
  user_id VARCHAR,
  event_name VARCHAR,
  occurred_at TIMESTAMP,
  plan_name VARCHAR,      <- denormalized
  plan_tier VARCHAR,      <- denormalized
  country VARCHAR,        <- denormalized
  region VARCHAR,         <- denormalized
  signup_cohort_week DATE <- denormalized
)
PARTITIONED BY (day(occurred_at), user_id)
```

One table. No JOINs. Fast queries. Storage is cheap; engineer time is not.
