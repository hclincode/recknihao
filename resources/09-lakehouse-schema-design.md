# Lakehouse Schema Design: Fact Tables, Dimensions, and SCDs

> **Production note:** This guide assumes your stack is Iceberg 1.5.2 tables on MinIO (S3 protocol), written by Spark and queried by Trino 467. Schema choices that "just work" in Postgres can cripple Trino. This file is the practical playbook for laying tables out on the lakehouse.
>
> **Read first:** `08-schema-design-for-analytics.md` covers the star-schema theory. This file gets concrete — exact column lists, denormalization rules, and slowly changing dimensions.

---

## Quick answer (TL;DR)

- A **fact table** has one row per event (append-only, billions of rows over time). A **dimension table** has one row per entity (users, plans — small and slowly-changing).
- Build 2–3 fact tables first: `user_events`, `subscription_changes`, `feature_usage`. Cover ~80% of dashboards.
- **Denormalize** the columns you group/filter by most often (`plan_type`, `country`, `tenant_id`) directly into the fact table. Skip ones that change often (email, display name).
- For dimensions that change over time, use **SCD Type 2** (add a new row with `valid_from`/`valid_to`) for things you need to reconstruct historically (plan changes). Use **SCD Type 1** (overwrite) for cosmetic fields (display name).
- Don't recreate your Postgres 3NF schema in Iceberg. Don't store everything as one JSON blob. Don't make UUIDs your only sort key.

---

## Fact tables vs dimension tables

### Fact table
- **What it is:** one row per *thing that happened* — an event, a transaction, a state change.
- **Examples:** `user_events`, `orders`, `page_views`, `subscription_changes`.
- **Shape:** append-only, very wide time range, eventually billions of rows.
- **Queried by:** aggregation (`COUNT`, `SUM`, `GROUP BY`) over slices of time.

### Dimension table
- **What it is:** one row per *entity* — a user, a product, a plan, a tenant.
- **Examples:** `users`, `plans`, `tenants`, `features`.
- **Shape:** changes slowly, much smaller (thousands to a few million rows).
- **Queried by:** JOIN onto a fact table to enrich rows ("which plan was this user on?").

### Why keep them separate?
- Fact tables are scanned with `WHERE event_time BETWEEN ...` and aggregated. They benefit from columnar storage and partition pruning.
- Dimension tables are looked up by primary key. They're small enough that Trino broadcasts them to every worker for fast JOINs.
- If you cram dimensions into one mega-table, you can never update a user's profile without rewriting billions of event rows.

**But "separate" doesn't mean "always JOIN at query time."** In practice you'll copy the most-frequently-queried dimension columns (like `plan_type`, `country`, `signup_cohort_week`) directly into the fact table at ingest time, so most dashboards never have to JOIN at all. This is called **denormalization**, and it's the next thing to design after you've decided which tables are facts and which are dimensions — see the "Denormalization rules" section below for what to copy and what to leave for JOINs.

---

## Practical SaaS fact tables — worked examples

### 1. `user_events` — the general event log

```
user_events (
  event_id          VARCHAR,        -- UUID, unique per event
  tenant_id         VARCHAR,        -- which customer (B2B SaaS)
  user_id           VARCHAR,        -- which user within that tenant
  event_name        VARCHAR,        -- 'signup', 'login', 'page_view', etc.
  occurred_at       TIMESTAMP(6),   -- when the event happened (event time)
  ingested_at       TIMESTAMP(6),   -- when Spark wrote it (processing time)
  plan_type         VARCHAR,        -- DENORMALIZED from users dim
  country           VARCHAR,        -- DENORMALIZED from users dim
  signup_cohort_week DATE,          -- DENORMALIZED from users dim
  properties        MAP<VARCHAR,VARCHAR>  -- flexible bag for event-specific attrs
)
PARTITIONED BY (day(occurred_at), tenant_id)
```

- **Denormalize:** `plan_type`, `country`, `signup_cohort_week` — these get grouped/filtered constantly.
- **Leave for JOIN:** user's current email, display name, profile_image_url. These change without changing reality, and you usually want the current value from the `users_dim` at query time.
- **Why `MAP<VARCHAR,VARCHAR>` for properties:** lets you store event-specific keys (`{"button":"Save","page":"/dashboard"}`) without changing the schema. Promote keys to top-level columns once you query them often.

### 2. `subscription_changes` — billing fact

```
subscription_changes (
  change_id         VARCHAR,
  tenant_id         VARCHAR,
  user_id           VARCHAR,
  from_plan         VARCHAR,        -- 'free', 'pro', 'enterprise'
  to_plan           VARCHAR,
  change_type       VARCHAR,        -- 'upgrade', 'downgrade', 'churn', 'new'
  changed_at        TIMESTAMP(6),
  mrr_delta_cents   BIGINT,         -- positive = expansion, negative = contraction
  prior_mrr_cents   BIGINT,
  new_mrr_cents     BIGINT,
  country           VARCHAR,        -- DENORMALIZED — for geo revenue cuts
  industry          VARCHAR         -- DENORMALIZED from tenants dim
)
PARTITIONED BY (month(changed_at))
```

- One row per plan transition. Don't try to model "current plan" here — that's what `tenants_dim` (or `users_dim`) is for.
- **Denormalize:** `country`, `industry` — revenue dashboards slice by them daily.
- **Leave for JOIN:** tenant's current ARR, contract end date — these change after the event.
- **Partition by `month`** not `day`: subscription changes are a low-volume table (one per upgrade/downgrade), and daily partitions would create thousands of tiny files.

### 3. `feature_usage` — product analytics

```
feature_usage (
  usage_id          VARCHAR,
  tenant_id         VARCHAR,
  user_id           VARCHAR,
  feature_key       VARCHAR,        -- 'export_csv', 'invite_user', 'create_dashboard'
  feature_category  VARCHAR,        -- 'collaboration', 'reporting', etc. — DENORMALIZED
  used_at           TIMESTAMP(6),
  duration_ms       INTEGER,
  success           BOOLEAN,
  plan_type         VARCHAR,        -- DENORMALIZED — "which plans use this feature?"
  is_paying         BOOLEAN         -- DENORMALIZED — converted vs trial activity
)
PARTITIONED BY (day(used_at), tenant_id)
```

- **Denormalize:** `feature_category`, `plan_type`, `is_paying` — the "who uses what" dashboards always group by these.
- **Leave for JOIN:** feature description, feature owner team, feature release date — query the `features_dim` when you need them.

---

## Denormalization rules

### Always denormalize
Columns that show up in `GROUP BY` or `WHERE` on lots of dashboards, *and* don't change after the event:
- `plan_type`, `account_tier`, `country`, `industry`, `signup_cohort_week`, `acquisition_channel`.
- Boolean flags like `is_paying`, `is_internal_user`, `is_trial`.

These are usually low-cardinality (~10–100 distinct values), which means Parquet's dictionary encoding compresses them to almost nothing. You pay no storage cost and save a JOIN.

### Never denormalize
Columns that change frequently without affecting historical truth:
- User's current email or display name (people rename themselves).
- User's current preferences/settings.
- Tenant's current ARR or contract value (those change every renewal).

If you copy them in, every change forces you to rewrite (or accept stale) fact rows.

### The update problem (a feature, not a bug)
If you denormalize `plan_type` and a user upgrades from `pro` to `enterprise`:
- All **historical events** still show `plan_type = 'pro'`.
- All **new events** show `plan_type = 'enterprise'`.

That is correct for analytics. The right question is "what plan were they on **when** they did X?" — not "what plan are they on right now?" If you ever do need "current plan," JOIN to the `users_dim` at query time:

```sql
SELECT e.event_name, COUNT(*)
FROM user_events e
JOIN users_dim u ON u.user_id = e.user_id AND u.is_current = TRUE
WHERE u.plan_type = 'enterprise'      -- current plan
  AND e.occurred_at >= current_date - INTERVAL '7' DAY
GROUP BY e.event_name;
```

---

## Slowly Changing Dimensions (SCD)

Dimension tables describe entities, but entities change over time. How you handle that change is the SCD pattern.

### SCD Type 1 — overwrite (lose history)
- When the column changes, you `UPDATE` the row. The old value is gone.
- **Use for:** cosmetic fields where history doesn't matter — display name, avatar URL, preference flags.

### SCD Type 2 — add a new row with date range (keep history)
- When the column changes, you close the old row (`valid_to = now()`, `is_current = FALSE`) and insert a new row (`valid_from = now()`, `valid_to = NULL`, `is_current = TRUE`).
- **Use for:** anything you'll later need to reconstruct historically — plan changes, account tier, sales-rep assignments.

### Concrete example: `users_dim` as SCD Type 2

```
users_dim (
  user_id      VARCHAR,
  email        VARCHAR,        -- Type 1 (overwrite — we only keep current)
  display_name VARCHAR,        -- Type 1
  plan_type    VARCHAR,        -- Type 2 — we want to reconstruct
  country      VARCHAR,        -- Type 2
  valid_from   TIMESTAMP(6),   -- when this version became true
  valid_to     TIMESTAMP(6),   -- when it stopped being true (NULL = still current)
  is_current   BOOLEAN
)
```

For user `u_123` who upgraded:

| user_id | plan_type | valid_from | valid_to | is_current |
|---|---|---|---|---|
| u_123 | pro | 2025-06-01 | 2025-11-15 | false |
| u_123 | enterprise | 2025-11-15 | NULL | true |

To find the plan a user was on at any point in time:

```sql
SELECT u.plan_type
FROM users_dim u
WHERE u.user_id = 'u_123'
  AND TIMESTAMP '2025-08-10 12:00:00' >= u.valid_from
  AND (u.valid_to IS NULL OR TIMESTAMP '2025-08-10 12:00:00' < u.valid_to);
```

To find every user's **current** state, filter `WHERE is_current = TRUE`.

**Practical note:** You can maintain SCD Type 2 via Spark `MERGE INTO` (write the close-old / insert-new logic yourself) or via dbt snapshots (dbt automates it). Two patterns:

**Option 1 — dbt snapshot (recommended for teams already using dbt):**

```sql
-- snapshots/users_snapshot.sql
{% snapshot users_snapshot %}
{{
  config(
    target_schema='analytics',
    unique_key='id',
    strategy='check',
    check_cols=['plan_name', 'country', 'account_tier']
  )
}}
SELECT id AS user_id, email, display_name, plan_name, country, account_tier
FROM {{ source('postgres', 'users') }}
{% endsnapshot %}
```

dbt adds these metadata columns automatically:
- `dbt_valid_from` — when this version became true
- `dbt_valid_to` — when it stopped (NULL = still active)
- `dbt_is_deleted` — whether the source row was deleted (dbt 1.9+)
- `dbt_scd_id` — unique ID per version row

**There is no `dbt_is_current` column.** To query current records: `WHERE dbt_valid_to IS NULL`.

**Option 2 — Spark MERGE INTO (for teams maintaining SCD2 inside their Spark ingestion job):**

```sql
-- Spark SQL — close stale rows
MERGE INTO iceberg.analytics.users_dim AS target
USING (
  SELECT id AS user_id, plan_name, country, current_timestamp() AS now
  FROM postgres_snapshot
  WHERE plan_name != target_plan  -- changed rows
) AS source
ON target.user_id = source.user_id AND target.valid_to IS NULL
WHEN MATCHED THEN UPDATE SET valid_to = source.now, is_current = false;

-- Then INSERT new rows for changed users
INSERT INTO iceberg.analytics.users_dim SELECT ..., now, NULL, true FROM changed_users;
```

---

## Pre-aggregated rollup tables (when fact tables get huge)

Once `user_events` is in the billions, even Trino on a well-partitioned table feels slow for dashboards. The fix is a **rollup table** — a smaller fact table that pre-summarizes the granular events.

```
daily_user_activity (
  activity_date  DATE,
  tenant_id      VARCHAR,
  user_id        VARCHAR,
  plan_type      VARCHAR,
  event_count    BIGINT,
  session_count  INTEGER,
  features_used  INTEGER
)
PARTITIONED BY (month(activity_date))
```

- Built nightly by a Spark job (or dbt model) that aggregates `user_events`.
- Dashboards hit this table instead of raw events → 100x smaller, much faster.
- Keep the raw `user_events` for ad-hoc deep dives.

---

## What NOT to do

### Don't recreate your Postgres 3NF schema in Iceberg
A 5-way JOIN that Postgres handles fine in 50ms (indexes, single node, cached rows) becomes a multi-stage shuffle in Trino. Flatten on ingest, not at query time.

### Don't use UUIDs as your only sort key
Iceberg's file-skipping (min/max stats per file) works on **sorted** columns. UUIDs are essentially random — every file's min/max covers the entire UUID space, so no skipping is possible. Sort fact tables by `(occurred_at, tenant_id)` and keep UUIDs as the row key only.

### Don't put all events in one JSON blob column
```
-- BAD
user_events (event_id, payload JSON)
-- payload = {"event_name":"login","user_id":"...","plan":"pro","country":"US"}
```
Every query has to read the entire JSON for every row to extract one key. Trino's `json_extract` works, but it forces full scans — no column pruning, no min/max pruning, no dictionary compression on common values. **Always promote queried fields to top-level columns.** For the practical recipe — which fields to promote, which to keep in a fallback bag, and how to migrate from a single JSON column — see the "Two-tier pattern: promoted columns + MAP / JSON fallback" section below.

---

## Two-tier pattern: promoted columns + MAP / JSON fallback

This is the standard SaaS pattern when you have an existing event source (like a Postgres `events.properties JSONB` column) and you don't know up front which fields will become hot. You promote the fields you query often to first-class typed columns and keep the rest in a fallback structure (a `MAP<VARCHAR, VARCHAR>` or the raw JSON string). It gives you the columnar/pruning benefits of typed columns for the 80% of dashboard queries that hit known fields, plus the schema flexibility of a bag for the long tail.

### Shape of the two-tier table

```
user_events (
  event_id           VARCHAR,
  tenant_id          VARCHAR,
  user_id            VARCHAR,
  event_name         VARCHAR,
  occurred_at        TIMESTAMP(6),
  -- Tier 1: promoted hot columns — typed, columnar, prunable
  plan_name          VARCHAR,
  browser_type       VARCHAR,
  country_code       VARCHAR,
  -- Tier 2: fallback for everything else (pick ONE of the two below, not both)
  properties         MAP<VARCHAR, VARCHAR>,   -- Option A: Parquet-native MAP
  properties_raw     VARCHAR                  -- Option B: raw JSON string
)
PARTITIONED BY (day(occurred_at), tenant_id)
```

Pick **MAP** if downstream queries hit lots of different fallback keys and you want simple `element_at(properties, 'key')` access. Pick **VARCHAR JSON string** if the fallback fields are queried very rarely (truly long-tail) and you want minimum write-side complexity — `json_extract_scalar(properties_raw, '$.key')` works fine for occasional access.

### MAP access — Parquet-native, NOT JSON parsing (important!)

> **`MAP<VARCHAR, VARCHAR>` in Iceberg/Parquet is a NATIVE NESTED TYPE — not a JSON string.** When Trino reads a MAP column it reads the binary Parquet MAP encoding (a pair of repeated key/value child columns) — there is no JSON parser involved per row. The correct mental model is: **"Trino reads the full MAP column and applies a key lookup per row — no JSON parsing, but also no file-level pruning for MAP keys."**

This matters because the distinction drives the right optimization advice:

- A MAP key lookup is **fast** per row (it's a binary tree/hash on the decoded key array — not JSON tokenization).
- But MAP predicates **cannot trigger file-level pruning** — Iceberg/Parquet does **NOT collect per-key statistics for MAP columns**. The only stats kept on a MAP column are column-level null count and total size. Even if the key `debug_mode` is set on every row, Iceberg has no per-file min/max for that key's values, so `WHERE element_at(properties, 'debug_mode') = 'true'` reads every file in the partition range — there is no skipping.
- Promoting a key to a top-level column adds per-file min/max stats and therefore enables file pruning. **This is the single biggest reason to promote a key**, not raw access speed.

By contrast, `json_extract_scalar(properties_raw, '$.key')` over a JSON string column DOES involve a JSON tokenize-and-walk per row. It's measurably slower than MAP access at scan time, and it also cannot be file-pruned. So MAP > JSON string for query latency on the fallback, and promoted column > MAP for prunability.

### CRITICAL — use `element_at()`, NOT `[]`, for MAP access in Trino

The single most common newcomer footgun on MAP columns:

```sql
-- WRONG — throws "Key not present in map: debug_mode" on rows where the key is missing.
-- This breaks queries on real production data because not every event has every key.
SELECT user_id
FROM iceberg.analytics.user_events
WHERE properties['debug_mode'] = 'true';

-- CORRECT — element_at() returns NULL for missing keys; WHERE silently drops NULLs.
-- This works correctly across mixed-key data.
SELECT user_id
FROM iceberg.analytics.user_events
WHERE element_at(properties, 'debug_mode') = 'true';
```

The `[]` subscript operator on Trino MAPs is "strict" — it raises an error if the key is absent on any row in the scan, which is almost always the wrong behavior for analytical workloads on heterogeneous event data. `element_at()` is the safe lookup that returns NULL on missing keys and lets `WHERE` filter them out. Make `element_at()` the default in your team's SQL style guide; `[]` is appropriate only when you're certain the key exists on every row (e.g., querying a config table you control end-to-end).

### Working PySpark migration: JSON column → promoted columns + raw JSON fallback

Use this when you're flattening an incoming JSON column from Postgres CDC (`events.properties` JSONB) into an Iceberg table with promoted hot columns plus a raw-JSON fallback for the long tail. **Use explicit `StructType` — not a JSON-string schema** (the string form is invalid PySpark API):

```python
from pyspark.sql.functions import col, from_json
from pyspark.sql.types import StructType, StructField, StringType

# Tier 1: declare the schema for the hot fields you want promoted to top-level columns.
# Keep this list small and intentional — only fields you query often.
hot_schema = StructType([
    StructField("plan_name",    StringType()),
    StructField("browser_type", StringType()),
    StructField("country_code", StringType()),
])

# Parse the raw JSON blob with the hot-field schema. Fields not in hot_schema
# are simply not extracted by from_json — they remain in the original raw JSON
# string for the fallback tier.
parsed = df.withColumn("props_parsed", from_json(col("properties_json"), hot_schema))

flattened = (
    parsed
    # Promote the hot fields to top-level columns (typed, columnar, prunable).
    .withColumn("plan_name",    col("props_parsed.plan_name"))
    .withColumn("browser_type", col("props_parsed.browser_type"))
    .withColumn("country_code", col("props_parsed.country_code"))
    # Keep the original raw JSON string for ad-hoc access to unpromoted fields.
    # Rename to make the fallback's nature clear (it's a JSON string, not a MAP).
    .withColumnRenamed("properties_json", "properties_raw")
    .drop("props_parsed")
)

# Write to Iceberg. Hot columns land as native VARCHAR; properties_raw stays VARCHAR.
flattened.writeTo("iceberg.analytics.user_events").append()
```

For ad-hoc Trino access to unpromoted fields:

```sql
-- From Trino: extract any unpromoted field on demand via JSON parsing.
SELECT user_id, json_extract_scalar(properties_raw, '$.referrer_domain') AS referrer
FROM iceberg.analytics.user_events
WHERE occurred_at >= CURRENT_DATE - INTERVAL '7' DAY;
```

`json_extract_scalar` is slower than MAP access (it tokenizes the JSON per row) but avoids the write-side complexity of building and maintaining a residual MAP. It also cannot be file-pruned.

**Alternative — use a residual MAP instead of a JSON string fallback.** If you want MAP-style ad-hoc access from Trino (`element_at()`) for the long-tail fields, build the residual as a MAP at write time using Spark's `from_json` with a lenient `MapType` schema:

```python
from pyspark.sql.functions import col, from_json
from pyspark.sql.types import MapType, StringType

# Parse the entire blob as a string-keyed map (lenient — no field-by-field schema).
df_with_map = df.withColumn(
    "properties",
    from_json(col("properties_json"), MapType(StringType(), StringType()))
)
# Then promote the hot keys to top-level columns and keep `properties` as the MAP fallback.
```

Trade-off: MAP gives faster fallback access at query time (no JSON parsing per row) but adds Spark-side schema complexity and forces every value to a string. Pick the JSON-string fallback for the simplest write path and acceptable ad-hoc read latency; pick the MAP fallback when long-tail keys get queried regularly enough that per-row JSON parsing becomes noticeable.

### Warning — old rows return NULL for newly promoted columns

> **When you promote a new column to top-level on an existing Iceberg table, all pre-existing data files return NULL for that column** — even if the original JSON/MAP source had a value for it. This is because `ADD COLUMN` in Iceberg is a metadata-only operation: it assigns a new **unique numeric field ID** to the column, but the underlying Parquet files were written before that field ID existed. When Iceberg reads an old Parquet file, it matches data columns to table schema columns **by field ID** (NOT by column name). The old Parquet file has no column chunk with the new field ID, so the read returns NULL for that column — automatically, on every row.
>
> **This ID-based matching is the foundational mechanism that makes Iceberg schema evolution safe.** Plain Parquet (without Iceberg) falls back to name-based matching, which is fragile: rename a column and old files lose the match. Iceberg's ID-based matching means rename is also metadata-only — the schema gets a new name for the same field ID, and old files keep matching correctly. ADD COLUMN, DROP COLUMN, and RENAME COLUMN are ALL metadata-only in Iceberg because of this design. Do not assume "name-based" anywhere in Iceberg — that's the wrong mental model and leads to the wrong conclusions about safety.
>
> **ADD COLUMN is always nullable.** Iceberg's `ALTER TABLE ... ADD COLUMN col TYPE` adds the column as nullable; there is no way to ADD a NOT NULL column directly (the constraint cannot apply to historical rows that will read NULL). If you need a NOT NULL constraint, do this in three steps: (1) `ALTER TABLE ... ADD COLUMN col TYPE` (nullable), (2) backfill the column for all historical rows with a Spark `MERGE INTO` or rewrite, (3) `ALTER TABLE ... ALTER COLUMN col SET NOT NULL`. Step 3 will fail if any row still has NULL — that's the validation gate that prevents accidentally adding a constraint that the existing data violates.
>
> **DROP COLUMN is also metadata-only — no file rewrite required.** When you run `ALTER TABLE ... DROP COLUMN col`, Iceberg removes the column from the table schema (the field ID is retired). The column's bytes remain physically present in old Parquet files on storage — but at query time, Iceberg's reader uses the current schema's field IDs to project columns, and the retired field ID is simply not requested. Queries no longer see the column. The unused bytes only get physically removed if you later run `CALL system.rewrite_data_files(...)` to compact and rewrite the files. DROP COLUMN itself is instant and free.
>
> **The silent failure mode:** you add `plan_name` as a top-level column, repoint your dashboards to use the new column, and `WHERE plan_name = 'enterprise'` now silently excludes ALL historical rows (because they were written before the promotion and return NULL for `plan_name`). Dashboards lose months of historical data with no error.
>
> **Mitigation — run a one-time backfill before pointing queries at the new column:**
> 1. Use Spark to read the table including the original JSON/MAP source column.
> 2. Extract the promoted value from the JSON/MAP for old rows.
> 3. Apply via `MERGE INTO` (targeted update — works in both Spark and Trino) or `INSERT OVERWRITE` (full partition rewrite — **Spark SQL only**; this syntax does NOT exist in Trino 467). In Trino, the equivalent partition-scoped overwrite is `DELETE FROM iceberg.analytics.events WHERE <partition_predicate>` followed by `INSERT INTO ... SELECT ...` — but for backfill of historical partitions, prefer running the rewrite from Spark with `INSERT OVERWRITE` or `overwritePartitions()`.
> 4. Verify with `SELECT COUNT(*) WHERE plan_name IS NULL` against a partition you know had the field set — should be ~0 after backfill.
> 5. Only then repoint dashboards to the new top-level column.
>
> Plan the backfill BEFORE running `ADD COLUMN`. The alternative — discovering a month later that "the enterprise plan dashboard shows zero historical revenue" — is much harder to debug after the fact.

### Quick decision rule for promotion

Promote a key out of the MAP / JSON fallback when **any one** of the following is true:

- The key shows up in `GROUP BY` or `WHERE` on more than one dashboard.
- Cardinality is low enough (~10–10,000 distinct values) that Parquet dictionary encoding will compress it well.
- The key's value influences partition pruning math (e.g., `country_code` lets you write a country-bucketed rollup table).
- You want per-file min/max stats for file pruning on this key.

Keep in the fallback when:

- The key is queried rarely (engineer ad-hoc only, not in dashboards).
- The key is extremely high-cardinality (per-event IDs, full URLs) — dictionary encoding wouldn't help.
- The set of keys is open-ended and changes weekly (every promotion is a schema migration).

### Don't write tiny files in a tight loop
Each `INSERT` from Spark creates a new Parquet file. Hundreds of small files per partition kills query speed (each file has fixed open/metadata overhead). See `10-lakehouse-partitioning.md` for the compaction fix.

### Don't model "current state" inside a fact table
A fact table is **history**. The fact that a user upgraded yesterday is a row; the fact that they're now on the pro plan is the *current value of the dimension*. Mixing these makes both queries and ingest harder.

---

## Key terms

| Term | Meaning |
|---|---|
| **Fact table** | Append-only table of events/transactions. One row per thing that happened. |
| **Dimension table** | Lookup table describing entities (users, plans, tenants). Small, changes slowly. |
| **Grain** | What one row of a fact table represents (e.g., "one event by one user at one moment"). |
| **Denormalization** | Copying dimension columns into the fact table to avoid JOINs. |
| **SCD Type 1** | Slowly Changing Dimension that overwrites old values. |
| **SCD Type 2** | Slowly Changing Dimension that adds new rows with validity dates. |
| **Rollup table** | Pre-aggregated fact table built from raw events. |
| **Hidden partitioning** | Iceberg manages partition directory layout based on a partition spec; you don't write partition predicates manually. |
| **MERGE INTO** | Iceberg SQL command for upserts — used for SCD Type 2 updates. |
