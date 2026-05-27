# Answer to Q1: Denormalize Plan Attributes into Events or Join at Query Time?

## Short answer

Denormalize `plan_tier` and `company_size` into the events table at ingest time. This is the right move for analytics. The "backfill when plans change" concern is a misunderstanding of how denormalization works — you don't backfill. Historical events keep the plan that was active when they occurred, which is exactly what you want for product analytics.

## The problem with your current federated approach

Trino federated joins between Iceberg and Postgres are slow for three reasons:

1. **JDBC overhead.** Every worker maintains its own Postgres connection. At query time, Trino fetches account rows over JDBC, merges them with Iceberg data, then cleans up. Connection management at scale is a bottleneck.

2. **Broken optimizer estimates.** Iceberg exposes per-file min/max statistics to the Trino CBO. Postgres JDBC exposes different statistics (or none). The optimizer can't make good join-order decisions when one side's cardinality is opaque — you often end up scanning millions of Postgres rows when you should be filtering Iceberg first.

3. **Repeated logic.** Every dashboard query recreates the same JOIN pattern.

## The denormalization pattern

Copy `plan_tier`, `company_size`, and `signup_date` directly into the events table when you ingest events, using the account's *current values at ingest time*:

**Before (federated join every query):**
```sql
SELECT COUNT(*) FROM user_events e
JOIN customer_accounts c ON e.user_id = c.user_id
WHERE c.plan_tier = 'enterprise';
```

**After (no join needed):**
```sql
SELECT COUNT(*) FROM user_events
WHERE plan_tier = 'enterprise';
```

**Why this works in Parquet/Iceberg:** Parquet's dictionary encoding compresses low-cardinality columns like `plan_tier` to almost nothing — storing the same value 100 million times costs barely more than storing it once. Trino reads only 3 columns from Parquet instead of joining two sources. No JDBC overhead. Queries go from seconds to milliseconds.

## Historical vs current state — the key insight

When a customer upgrades from Pro to Enterprise on May 15:
- Events from May 1–14 keep `plan_tier = 'pro'`
- Events from May 15 onward get `plan_tier = 'enterprise'`

**This is correct behavior, not a bug.** The right question for product analytics is "what plan were they on *when* they clicked this button?" not "what plan are they on right now?"

Your funnel analysis reports: "Pro-plan users completed onboarding 60% of the time; Enterprise-plan users completed it 95% of the time." This reflects what plan they were on *during* the funnel — which is what matters for product decisions.

**No backfill when plans change.** The denormalized value freezes at the moment of ingest. New events get the new plan tier; old events keep the old one. That's the design. Clean, correct, no rewrites.

## Handling "current plan" queries

Sometimes you do need "what plan is the user on *right now*?" — exec dashboards showing current ARR by plan, for example. For those queries, join at query time to a small dimension table:

```sql
-- Fast because the dimension table is small and Trino broadcasts it
SELECT e.event_name, COUNT(*)
FROM user_events e
JOIN customers_dim c ON c.user_id = e.user_id
  AND c.valid_from <= e.occurred_at
  AND (c.valid_to IS NULL OR e.occurred_at < c.valid_to)
WHERE c.plan_tier = 'enterprise'
  AND e.occurred_at >= CURRENT_DATE - INTERVAL '7' DAY
GROUP BY e.event_name;
```

This is the "as-of" join pattern — the dimension table records when each plan was active, so you can reconstruct the historical state at any point.

## The star schema pattern (recommended for your stack)

**Fact table** (append-only, partitioned by time):
```sql
user_events (
    event_id     BIGINT,
    user_id      BIGINT,
    event_name   VARCHAR,
    occurred_at  TIMESTAMP(6),
    plan_tier    VARCHAR,   -- denormalized, frozen at ingest
    company_size VARCHAR,
    signup_month VARCHAR
)
WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'])
```

**Dimension table** (SCD Type 2 — tracks plan history):
```sql
customers_dim (
    user_id    BIGINT,
    plan_tier  VARCHAR,
    valid_from TIMESTAMP(6),
    valid_to   TIMESTAMP(6),   -- NULL = currently active
    is_current BOOLEAN
)
```

When a customer upgrades, close the old row (`valid_to = upgrade_timestamp`) and insert a new row. The fact table is never rewritten — it accumulates forward-only.

## What to denormalize vs what to leave for joins

**Do denormalize:**
- `plan_tier` — low-cardinality, rarely changes, key analytics dimension
- `company_size` — stable enough, compresses well
- `signup_month` — time cohort for retention analysis, never changes
- `is_paying` — boolean, tiny, avoids common join pattern

**Don't denormalize:**
- `display_name` — can change anytime; historical events would show stale names
- `email` — PII, changes, not an analytics dimension
- Any field updated daily — creates backfill debt if you ever want the "current" value in old rows

The rule: denormalize attributes that represent the user's *state when the event happened* and that appear in GROUP BY or WHERE on multiple dashboards.

## Iceberg-specific implementation (your stack)

**At ingest time:** When Spark reads events from Postgres, broadcast-join the accounts table and copy the dimension attributes into each event row:

```python
from pyspark.sql.functions import broadcast

events_df = spark.read.format("jdbc").option("dbtable", "events")...load()
accounts_df = spark.read.format("jdbc").option("dbtable", "customer_accounts")...load()

enriched = events_df.join(
    broadcast(accounts_df.select("user_id", "plan_tier", "company_size", "signup_date")),
    on="user_id",
    how="left"
)
enriched.writeTo("iceberg.analytics.user_events").append()
```

`broadcast()` keeps the accounts join fast — Spark sends the full accounts table to every worker rather than shuffling events.

**Adding new denormalized columns later:**
```sql
ALTER TABLE iceberg.analytics.user_events ADD COLUMN feature_tier VARCHAR;
```
Metadata-only, completes in milliseconds. New rows have it; old rows return NULL. No file rewrites.

**One-time backfill for existing rows:**
If you're adding `plan_tier` to an existing events table that doesn't have it yet, run a Spark backfill before pointing dashboards at the new column. Otherwise historical rows return NULL and filter results silently exclude all history.

## Bottom line

Denormalize `plan_tier` and `company_size` at ingest time. No backfill when plans change — that's by design. Historical events keep the plan that was active when they occurred. For current-plan queries, a lightweight JOIN to a small dimension table is fast enough and more accurate. This eliminates federated join fragility, reduces query latency, and matches how star schema analytics is supposed to work.
