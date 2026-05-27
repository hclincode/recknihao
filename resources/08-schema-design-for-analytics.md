# Schema Design for Analytics: Denormalization and Star Schema

> **Production note:** On your stack (Iceberg + MinIO + Trino), storage is cheap and JOINs across many tables are expensive. The schema rules from Postgres are *the opposite* of what you want here. This is the single biggest mistake teams make when migrating to a lakehouse.

---

## Quick answer

1. **Don't recreate your Postgres schema in Iceberg.** 3NF normalized schemas with lots of JOINs are slow and painful in OLAP.
2. **Use a star schema:** one big *fact table* (events, orders, sessions) plus a few small *dimension tables* (users, products, plans).
3. **Denormalize aggressively:** copy frequently-queried attributes (`plan_type`, `country`, `signup_month`) directly into the fact table at write time, even though it duplicates data.
4. **Storage on MinIO is cheap; engineer time on slow queries is expensive.** Optimize for query simplicity, not disk usage.
5. **For SaaS, start with 2–3 fact tables**: `user_events`, `subscription_changes`, `feature_usage`. Most dashboards need only these.

---

## Why normalized schemas are bad for analytics

In Postgres you probably have something like:

```
users (id, email, created_at, plan_id, country_id)
plans (id, name, monthly_price)
countries (id, name, region)
events (id, user_id, event_name, created_at)
```

A simple analytics question — "signups by plan tier, by country" — requires a 4-way JOIN:

```sql
SELECT p.name, c.name, COUNT(*)
FROM events e
JOIN users u ON u.id = e.user_id
JOIN plans p ON p.id = u.plan_id
JOIN countries c ON c.id = u.country_id
WHERE e.event_name = 'signup'
GROUP BY p.name, c.name;
```

**Why this hurts in OLAP:**
- Each JOIN is a shuffle across nodes in Trino — data has to move over the network.
- The optimizer has to estimate cardinalities for every JOIN; one bad estimate and the query takes 10x longer.
- Engineers writing SQL have to know all four tables and how they relate.
- Adding a new dashboard means rediscovering the JOIN graph each time.

---

## Star schema: the standard analytical layout

A **star schema** has one central *fact* table surrounded by smaller *dimension* tables. The fact table is huge (millions to billions of rows) and immutable. Dimensions are small (hundreds to thousands of rows) and change slowly.

```
                 +-----------+
                 |   plans   |   <- dimension
                 +-----------+
                       |
                       |
   +-----------+   +---------------------+   +------------+
   |   users   |---|     user_events     |---| countries  |
   | (dim)     |   |     (fact table)    |   | (dim)      |
   +-----------+   +---------------------+   +------------+
                       |
                       |
                 +-----------+
                 | products  |   <- dimension
                 +-----------+
```

- **Fact table** = things that happened: events, orders, page views, subscription changes. One row per event. Append-only.
- **Dimension table** = descriptions of entities: users, products, plans, countries. Lookup tables.

You still get joins, but the pattern is one fact + N small dimensions — much simpler and much faster than a snowflake of joined dimensions.

---

## Denormalization: copy attributes into the fact table

The next step beyond star schema: copy the *most-queried* dimension attributes directly into the fact table at write time.

### Before (star schema, requires JOIN)

```
user_events: (user_id, event_name, event_time)
users:       (id, plan_type, country, signup_date)
```

Query needs a JOIN to filter by plan:

```sql
SELECT COUNT(*) FROM user_events e
JOIN users u ON u.id = e.user_id
WHERE u.plan_type = 'enterprise' AND e.event_time >= current_date - INTERVAL '7' DAY;
```

### After (denormalized, no JOIN)

```
user_events: (user_id, event_name, event_time,
              plan_type, country, signup_date)   <- copied from users at write time
```

```sql
SELECT COUNT(*) FROM user_events
WHERE plan_type = 'enterprise' AND event_time >= current_date - INTERVAL '7' DAY;
```

No JOIN. Trino reads only 3 columns thanks to Parquet's columnar storage. Iceberg skips files outside the date range. Query goes from seconds to milliseconds.

**The trade-off:** if a user upgrades from `pro` to `enterprise`, the historical events still show `pro`. That is *usually what you want for analytics* ("what plan were they on when they did X") but it's a change of mindset. If you need current values, JOIN at query time to the users dimension.

---

## Practical recipe for a SaaS product

Start with these three fact tables in Iceberg:

| Fact table | Grain (one row per…) | Denormalized attributes to embed |
|---|---|---|
| `user_events` | one event by one user | `plan_type`, `country`, `signup_cohort_week`, `is_paying` |
| `subscription_changes` | one plan transition | `old_plan`, `new_plan`, `mrr_delta`, `customer_tier` |
| `feature_usage` | one feature interaction | `feature_name`, `feature_category`, `plan_type`, `tenant_id` |

Plus small dimension tables for things that genuinely change over time independently of events: `users`, `plans`, `tenants`, `features`.

**Rule of thumb:** if a column is in the `WHERE` or `GROUP BY` of more than 3 dashboards, copy it into the fact table.

---

## Iceberg specifics that help

- **Schema evolution.** Adding a new column to a fact table (`ALTER TABLE user_events ADD COLUMN device_type VARCHAR`) is metadata-only — Iceberg does *not* rewrite existing files. New rows have the column; old rows return NULL. This makes denormalization additions painless.
- **Hidden partitioning.** Partition by `days(event_time)` and Iceberg handles the directory layout. Queries with `WHERE event_time >= ...` automatically skip files. You never have to write `WHERE event_date = '...' AND event_time >= '...'` like in old Hive setups.
- **Partition anti-pattern: never identity-partition on a high-cardinality column.** `PARTITIONED BY (day(occurred_at), user_id)` with 1M users creates 1M partitions — metadata balloons and queries slow down from metadata overhead alone. For a secondary partition on user_id, use `bucket(user_id, 16)` (Trino syntax) or just omit the secondary partition and rely on Bloom filters or sorting for user-level lookups. `PARTITIONED BY (day(occurred_at), tenant_id)` is safe because tenant cardinality in a B2B SaaS is typically low (hundreds, not millions).
- **Column types.** Use `MAP<VARCHAR, VARCHAR>` for flexible event properties — keeps the schema clean while still letting you index frequently-used keys by promoting them to top-level columns later.

---

## What NOT to do (the #1 migration mistake)

**Do not** copy your Postgres schema into Iceberg unchanged. A team that does this gets:

- 12 tables that all need to be JOINed for any non-trivial query
- Trino queries that are 10x slower than they should be
- Engineers writing the same JOIN logic over and over
- Eventual realization that they need to rebuild as a star schema, but now with terabytes of data already in the wrong shape

**Instead:** when migrating, treat it as a redesign. The fact tables on the lakehouse should look *nothing* like the OLTP tables they came from. Use a Spark ingestion job to flatten and denormalize on the way in, and maintain the denormalized fact tables with dbt models — dbt is the right tool for keeping the schema consistent across your transformation layer.

---

## Key terms

| Term | Meaning |
|---|---|
| **Fact table** | Large, append-only table of things that happened (events, orders, sessions) |
| **Dimension table** | Small lookup table describing entities (users, products, plans) |
| **Star schema** | One fact table joined to several dimensions — the standard analytical layout |
| **Denormalization** | Deliberately duplicating data (copying dimension attributes into the fact table) to avoid JOINs |
| **Grain** | What one row of a fact table represents ("one event by one user at one moment") |
| **Schema evolution** | Iceberg's ability to add/drop/rename columns without rewriting data files |
| **Hidden partitioning** | Iceberg manages partition directory layout for you, based on column transformations |
| **3NF (Third Normal Form)** | The Postgres-style normalized schema that minimizes duplication — wrong default for analytics |
