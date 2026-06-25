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

## LEADING CANONICAL WORKED EXAMPLE — Trino vs Spark DDL for a wide denormalized event table (read this FIRST for any "how do I CREATE this table?" question)

> **This is the findable canonical answer for schema-design DDL questions on the production stack (Trino 467 + Iceberg 1.5.2 + Spark + HMS + MinIO).** Two engines, two dialects, same Iceberg table on disk. Pick the engine you're typing into and paste the matching block — do NOT mix syntaxes. Both forms have been verified against [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html), [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html), and [iceberg.apache.org/docs/1.5.1/spark-ddl/](https://iceberg.apache.org/docs/1.5.1/spark-ddl/).

**Scenario:** A SaaS engineer needs a wide, denormalized fact table for product events. ~30 columns: a handful of identifiers, a timestamp, ~20 typed "hot" columns that show up in dashboard `GROUP BY`/`WHERE` (plan_name, country_code, device_type, plan_tier, browser, referrer_source, etc.), plus a long-tail `properties` bag for event-specific keys you don't want to schema-evolve over.

### Trino 467 DDL — the canonical form (paste this when you are in the Trino query console)

```sql
-- Trino 467 + Iceberg connector. Catalog is `iceberg`; schema is `analytics`.
CREATE TABLE iceberg.analytics.user_events (
  -- Identifiers
  event_id           VARCHAR,                  -- UUID-as-string per event
  tenant_id          VARCHAR,                  -- B2B customer
  user_id            VARCHAR,                  -- user within tenant
  session_id         VARCHAR,
  -- Event shape
  event_name         VARCHAR,                  -- 'signup', 'page_view', etc.
  event_category     VARCHAR,                  -- DENORMALIZED — for dashboards
  event_source       VARCHAR,                  -- 'web', 'ios', 'android', 'api'
  occurred_at        TIMESTAMP(6),             -- event time (use for partitioning)
  ingested_at        TIMESTAMP(6),             -- when Spark wrote it
  -- Promoted "hot" columns — typed, columnar, prunable
  plan_name          VARCHAR,                  -- 'free', 'pro', 'enterprise' — DENORMALIZED
  plan_tier          VARCHAR,
  country_code       VARCHAR,                  -- 'US', 'DE', 'JP'
  region             VARCHAR,
  device_type        VARCHAR,                  -- 'desktop', 'mobile', 'tablet'
  browser            VARCHAR,
  os                 VARCHAR,
  referrer_source    VARCHAR,
  utm_campaign       VARCHAR,
  is_paying          BOOLEAN,
  is_trial           BOOLEAN,
  is_internal_user   BOOLEAN,
  -- Numeric facts
  duration_ms        INTEGER,
  page_load_ms       INTEGER,
  -- Long-tail fallback (Tier 2) — pick ONE of the two
  properties         MAP(VARCHAR, VARCHAR),    -- Parquet-native MAP — element_at(properties, 'key')
  properties_raw     VARCHAR                   -- OR keep raw JSON if rarely queried
)
WITH (
  partitioning    = ARRAY['day(occurred_at)', 'tenant_id'],
  format          = 'PARQUET',
  format_version  = 2
);
```

**Why every piece looks the way it does on Trino:**

| Piece | Trino spelling | Why |
|---|---|---|
| Map type | `MAP(VARCHAR, VARCHAR)` with **parentheses** | Per [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html), Trino's map-type literal is `MAP(K, V)`. Angle-bracket `MAP<K, V>` is Hive/Spark DDL and produces a parse error on Trino 467. |
| Partitioning | `WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'])` | Per [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html), Iceberg-connector partitioning is a table property in the `WITH` clause, expressed as an ARRAY of partition-transform **strings**. Transforms (`day(...)`, `bucket(col, N)`, `truncate(col, N)`) and identity columns (`'tenant_id'`) both go inside the same `ARRAY[...]`. |
| Bucket transform | `bucket(column, N)` — column FIRST | Trino's column-first form. Spark uses `bucket(N, column)` — see resource 10 for the Trino-vs-Spark `bucket()` argument-order footgun. |
| Format version | `format_version = 2` | Required for MERGE INTO, MoR deletes, and row-level updates. Default is 2 in recent Trino versions; set explicitly for clarity. |
| Timestamp type | `TIMESTAMP(6)` (microsecond precision) | Trino's Iceberg connector maps to `timestamp` (6) by default. |

### Spark SQL DDL — the equivalent table (paste this ONLY when you are in Spark SQL or a Spark job)

```sql
-- Spark SQL — DO NOT paste into the Trino console.
-- Same Iceberg table on disk; different DDL spelling.
CREATE TABLE iceberg.analytics.user_events (
  event_id           STRING,
  tenant_id          STRING,
  user_id            STRING,
  session_id         STRING,
  event_name         STRING,
  event_category     STRING,
  event_source       STRING,
  occurred_at        TIMESTAMP,
  ingested_at        TIMESTAMP,
  plan_name          STRING,
  plan_tier          STRING,
  country_code       STRING,
  region             STRING,
  device_type        STRING,
  browser            STRING,
  os                 STRING,
  referrer_source    STRING,
  utm_campaign       STRING,
  is_paying          BOOLEAN,
  is_trial           BOOLEAN,
  is_internal_user   BOOLEAN,
  duration_ms        INT,
  page_load_ms       INT,
  properties         MAP<STRING, STRING>,      -- Spark's angle-bracket map type
  properties_raw     STRING
)
USING iceberg
PARTITIONED BY (days(occurred_at), tenant_id)   -- Spark uses PARTITIONED BY (...)
TBLPROPERTIES (
  'format-version' = '2'
);
```

**The two DDLs produce the same Iceberg table on disk** — same partition spec, same schema, same Parquet files, same manifest layout. Both Trino and Spark will see it via Hive Metastore. The only thing that differs is the SQL spelling of the CREATE statement.

### DO-NOT-WRITE — Trino-context DDL forms that LOOK valid but PARSE-ERROR in Trino 467

> **When you are writing Trino 467 DDL, NEVER use the forms in the left column. Trino 467's SQL parser will reject them with a syntax error. These are Hive/Spark spellings that DO NOT translate.**

| DO NOT WRITE (Trino context) | WRITE THIS INSTEAD (Trino 467) | Why it parse-errors on Trino |
|---|---|---|
| `MAP<VARCHAR, VARCHAR>` (angle brackets) | `MAP(VARCHAR, VARCHAR)` (parentheses) | Trino's type grammar uses parentheses for parameterized types — `ARRAY(VARCHAR)`, `MAP(K, V)`, `ROW(...)`. The angle-bracket form is Hive/Spark/Java-generic syntax. Trino's parser does not accept `<` as a type-parameter delimiter. Verified per [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html). |
| `MAP<STRING, STRING>` | `MAP(VARCHAR, VARCHAR)` | Same bug, plus `STRING` is the Spark/Hive name for the type Trino calls `VARCHAR`. Trino's parser does not recognize `STRING` as a type. |
| `PARTITIONED BY (day(occurred_at), tenant_id)` AFTER the column list | `WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'])` | Trino has no top-level `PARTITIONED BY` clause for the Iceberg connector. Partitioning is declared as the `partitioning` table property inside `WITH (...)`, and the values are **strings** (note the single quotes). Verified per [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html). |
| `USING iceberg` clause | Drop the clause; the catalog `iceberg.<schema>.<table>` already names the connector | `USING iceberg` is Spark SQL's "use this DataSource" syntax. Trino infers the connector from the catalog name in the fully-qualified table reference (`iceberg.analytics.events` → Iceberg connector). |
| `TBLPROPERTIES ('format-version' = '2', ...)` | `WITH (format_version = 2, ...)` (note: integer, no quotes; underscore not hyphen) | Trino uses `WITH (...)` for table properties; the Iceberg connector exposes them with Trino naming conventions (`format_version` underscore, integer value). Spark uses `TBLPROPERTIES` with quoted string values and dotted/hyphenated keys. |
| `STRING`, `INT`, `BIGINT` (Spark types in a Trino block) | `VARCHAR`, `INTEGER`, `BIGINT` | Trino names: `VARCHAR` for strings, `INTEGER` for 32-bit ints. `BIGINT` is the same in both. `STRING` and `INT` parse-error on Trino. |
| `bucket(64, tenant_id)` (N first) in a Trino block | `bucket(tenant_id, 64)` (column first) | Trino's `bucket()` transform takes **column first, then bucket count**. Spark's `bucket()` takes **bucket count first, then column**. Mixing them up either parse-errors (when types don't match) or silently swaps argument meanings. See resource 10. |

> **The rule, in one sentence: in Trino, every parameterized type uses PARENTHESES (`MAP(K,V)`, `ARRAY(T)`, `ROW(...)`) and every Iceberg table property goes inside the `WITH (...)` clause — including partitioning, which is an `ARRAY[...]` of transform STRINGS.**

> **Recovery procedure when you copy-paste from a Spark tutorial and Trino rejects the CREATE:** (1) Replace every `MAP<X, Y>` with `MAP(X, Y)`; (2) move `PARTITIONED BY (...)` into a `WITH (partitioning = ARRAY[...])` clause, quoting each transform/column as a string; (3) drop `USING iceberg` (the catalog name does that work); (4) rename `STRING` → `VARCHAR`, `INT` → `INTEGER`; (5) reverse `bucket(N, col)` → `bucket(col, N)`; (6) move `TBLPROPERTIES (...)` keys into the same `WITH (...)` clause using Trino property names (`format-version` → `format_version`).

---

## Common myths about lakehouse schema design — read FIRST (the load-bearing wrong claims)

> **Lead with the TRUTH, state the nuance.** These are absolutes most often stated incorrectly when porting a Postgres-style schema to Iceberg + Trino. Verified against [Iceberg evolution docs](https://iceberg.apache.org/docs/latest/evolution/), [Iceberg partition transforms](https://iceberg.apache.org/spec/#partition-transforms), and [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html).

| MYTH (commonly said wrong) | TRUTH (correct framing) |
|---|---|
| "Denormalization in the fact table means I'll have stale data when the dimension changes." | **TRUE BY DESIGN — and that's USUALLY WHAT YOU WANT for fact tables.** A fact row records the STATE AT THE TIME OF THE EVENT — the `plan_type` the user was on WHEN they clicked the button, not their current plan. Reconstructing historical reports by joining to the current dimension would actively misrepresent history. For cosmetic fields (display name, profile image) that don't matter historically, leave them in the dimension and JOIN. For business-meaningful state (plan_type, country at time of event), denormalize INTO the fact and accept the "staleness" — it's actually correctness. |
| "Fact tables should be normalized to 3NF like Postgres tables." | **NO — that breaks analytical query performance.** A 3NF fact table forces every dashboard to JOIN 4-7 dimensions, which on billions of rows turns sub-second queries into minutes. The standard analytical pattern is **star schema** (one fact, multiple small dimensions) with denormalized hot columns INTO the fact table to skip the JOIN entirely on common queries. See resource 08 for star schema theory and the "Denormalization rules" section below. |
| "I should index frequently-queried columns in Iceberg like I would in Postgres." | **NO — Iceberg has no B-tree indexes.** The lakehouse "index" equivalents are: (a) **partition transforms** (`day(occurred_at)`, `bucket(tenant_id, N)`) for coarse-grained file skipping; (b) **sort order on write** (clustering files by frequently-filtered columns so per-file min/max bounds prune well); (c) **Parquet bloom filters** for high-cardinality point lookups (write side configured via Iceberg's `write.parquet.bloom-filter-enabled.column.<col>` table property on Spark, read by Trino 467 automatically). There is no `CREATE INDEX ON fact_table (column)` — and trying to retrofit Postgres-style indexing thinking onto Iceberg causes engineers to over-partition (one partition per high-cardinality value, leading to small-files problems). |
| "UUID primary keys are fine in Iceberg — they're fine in Postgres." | **PARTIALLY TRUE — but UUIDs as the SORT key or BUCKET key cause real problems.** UUIDs are random, so files sorted by UUID have wide overlapping min/max ranges per file (no pruning possible on UUID filters). And `bucket(uuid_col, N)` hashes uniformly across N buckets, defeating any locality. UUIDs are FINE as a primary-key-like column you carry through, but NOT as the sort/cluster key for partition design. Use timestamps (`day(occurred_at)`) or low-cardinality category columns (`tenant_id`) for partitioning instead. |
| "`MAP(VARCHAR, VARCHAR)` columns let me store arbitrary properties forever without schema changes." | **TRUE FOR STORAGE, BUT QUERIES ON MAP KEYS ARE EXPENSIVE.** Accessing `properties['button_name']` in a WHERE clause cannot use partition pruning or per-file min/max (Parquet doesn't store min/max for individual map keys). Trino must scan every file's properties column and extract the key. **The pattern: use MAP for the long tail of low-frequency keys; promote any key you query 10+ times to a top-level column** (a simple schema evolution: `ALTER TABLE ADD COLUMN button_name VARCHAR` — Iceberg makes this metadata-only, no file rewrite required). See resource 17 for ADD COLUMN semantics. (Note: Trino spells the map type `MAP(VARCHAR, VARCHAR)` with parentheses — the angle-bracket form `MAP<...>` is Hive/Spark syntax and parse-errors in Trino 467.) |
| "Iceberg schema evolution will break my old data when I add a column." | **NO — `ALTER TABLE ADD COLUMN` is metadata-only and old files are read with NULL for the new column.** Iceberg uses column IDs (not names) under the hood, so adding a column writes the new column ID to the schema; old data files that don't have that column read as NULL for that column at query time. No file rewrite. Same for `DROP COLUMN` (metadata-only soft-delete) and `RENAME COLUMN` (rename by ID, files unchanged). See [Iceberg evolution docs](https://iceberg.apache.org/docs/latest/evolution/). |
| "Iceberg partition columns must be top-level columns in the schema." | **NO — Iceberg partitions are TRANSFORMS over source columns, not separate columns.** When you declare `WITH (partitioning = ARRAY['day(occurred_at)', 'tenant_id'])` in Trino (or the Spark equivalent `PARTITIONED BY (day(occurred_at), tenant_id)`), Iceberg stores `day(occurred_at)` as a derived value in the metadata — you do NOT add a separate `day` column to the schema. Queries that filter on the SOURCE column (`WHERE occurred_at BETWEEN ...`) still prune via the transform. This is different from Hive-style partitioning where you'd write a separate `year/month/day` column. See resource 10. |
| "Adding a column to an Iceberg table requires re-ingesting all the data." | **NO — `ALTER TABLE ADD COLUMN` is metadata-only.** This is one of Iceberg's biggest wins vs Hive. The new column shows up in queries immediately with NULL for old rows. Backfilling the new column from a derived value or upstream source IS a separate decision — you might run a Spark `UPDATE` to backfill, or leave NULL for historical rows. But ADD COLUMN itself does not rewrite data files. |
| "Partition evolution (changing from `month(occurred_at)` to `day(occurred_at)`) requires rewriting all historical data." | **NO — Iceberg's in-place partition evolution is metadata-only.** `ALTER TABLE iceberg.x.y SET PROPERTIES partitioning = ARRAY['day(occurred_at)']` updates the spec; **new writes** use the day spec, **old files keep their month spec**, and Trino correctly handles BOTH simultaneously at query time (per-spec-id manifests + per-spec pruning). No missing rows, no duplicates. The old data doesn't benefit from the new pruning until you (optionally) run Spark `rewrite_data_files` to convert it. See [Iceberg evolution docs](https://iceberg.apache.org/docs/latest/evolution/). |

> **Why these specific myths matter.** Each is a load-bearing claim about how schema decisions land on Iceberg vs Postgres. Stated as an absolute, they cause engineers to either over-engineer (recreating 3NF in Iceberg with JOIN-heavy schemas; trying to add B-tree indexes that don't exist) OR to confidently build dead-end designs (UUID as the sort key for partitioning; massive MAP columns expected to be queryable without scan; assuming column adds require re-ingestion and over-budgeting the schema change). **The correct discipline:** when about to say "in Iceberg, X requires Y", check (a) whether the claim is actually a Postgres rule misapplied to lakehouse, (b) [Iceberg evolution docs](https://iceberg.apache.org/docs/latest/evolution/) for what's metadata-only, (c) resources 08 (star schema), 10 (partitioning), 17 (table maintenance), and 18 (query performance) for the right shape.

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

```sql
-- Trino 467 DDL — paste directly into the Trino query console.
CREATE TABLE iceberg.analytics.user_events (
  event_id            VARCHAR,                  -- UUID, unique per event
  tenant_id           VARCHAR,                  -- which customer (B2B SaaS)
  user_id             VARCHAR,                  -- which user within that tenant
  event_name          VARCHAR,                  -- 'signup', 'login', 'page_view', etc.
  occurred_at         TIMESTAMP(6),             -- when the event happened (event time)
  ingested_at         TIMESTAMP(6),             -- when Spark wrote it (processing time)
  plan_type           VARCHAR,                  -- DENORMALIZED from users dim
  country             VARCHAR,                  -- DENORMALIZED from users dim
  signup_cohort_week  DATE,                     -- DENORMALIZED from users dim
  properties          MAP(VARCHAR, VARCHAR)     -- flexible bag for event-specific attrs
)
WITH (
  partitioning    = ARRAY['day(occurred_at)', 'tenant_id'],
  format          = 'PARQUET',
  format_version  = 2
);
```

- **Denormalize:** `plan_type`, `country`, `signup_cohort_week` — these get grouped/filtered constantly.
- **Leave for JOIN:** user's current email, display name, profile_image_url. These change without changing reality, and you usually want the current value from the `users_dim` at query time.
- **Why `MAP(VARCHAR, VARCHAR)` for properties:** lets you store event-specific keys (`{"button":"Save","page":"/dashboard"}`) without changing the schema. Promote keys to top-level columns once you query them often.

### 2. `subscription_changes` — billing fact

```sql
-- Trino 467 DDL.
CREATE TABLE iceberg.analytics.subscription_changes (
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
WITH (
  partitioning    = ARRAY['month(changed_at)'],
  format          = 'PARQUET',
  format_version  = 2
);
```

- One row per plan transition. Don't try to model "current plan" here — that's what `tenants_dim` (or `users_dim`) is for.
- **Denormalize:** `country`, `industry` — revenue dashboards slice by them daily.
- **Leave for JOIN:** tenant's current ARR, contract end date — these change after the event.
- **Partition by `month`** not `day`: subscription changes are a low-volume table (one per upgrade/downgrade), and daily partitions would create thousands of tiny files.

### 3. `feature_usage` — product analytics

```sql
-- Trino 467 DDL.
CREATE TABLE iceberg.analytics.feature_usage (
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
WITH (
  partitioning    = ARRAY['day(used_at)', 'tenant_id'],
  format          = 'PARQUET',
  format_version  = 2
);
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

**Option 1 — dbt snapshot (recommended for teams already using dbt).**

> **Findability anchor — keywords this Option-1 block answers (so a Haiku responder routing on these phrases lands here, the single source of truth, not on r10/r23/r27/r28 where only one-line forward pointers live):** "dbt snapshot", "dbt snapshots", "SCD2 strategy", "SCD Type 2", "snapshot strategy", "dbt snapshot strategy", "timestamp vs check strategy", "check strategy vs timestamp strategy", "which snapshot strategy", "snapshot strategy=timestamp", "snapshot strategy=check", "check_cols", "tracked columns dbt snapshot", "no reliable updated_at column", "snapshot has no updated_at", "dbt_valid_from", "dbt_valid_to", "dbt_scd_id", "dbt_is_deleted", "dbt snapshot metadata columns", "current rows from a dbt snapshot", "dbt_is_current does not exist", "hard delete", "hard deletes", "source row deleted", "record physically deleted in source", "row removed from source table", "snapshot freezes on last version after delete", "detect deletes in dbt snapshot", "record that a row was deleted and when", "invalidate_hard_deletes", "hard_deletes config", "hard_deletes new_record", "hard_deletes invalidate", "track deletions in SCD2", "capture deletion timestamp in snapshot".

dbt offers TWO strategies — pick exactly one per snapshot:

**1a. `strategy='timestamp'` — when the source has a reliable last-modified column (PREFERRED, more efficient).** Required config key is `updated_at='<column_name>'`. dbt compares the source row's `updated_at` value against the snapshot's last seen value for that `unique_key`; if the source is newer, the old version is closed (`dbt_valid_to` stamped) and a new row is inserted.

```sql
-- snapshots/users_snapshot.sql — timestamp strategy
{% snapshot users_snapshot %}
{{
  config(
    target_schema='analytics',
    unique_key='id',
    strategy='timestamp',
    updated_at='updated_at'   -- REQUIRED for timestamp strategy: the source-table column dbt reads to detect changes
  )
}}
SELECT id, email, display_name, plan_name, country, account_tier, updated_at   -- key column `id` is UNALIASED (matches unique_key='id')
FROM {{ source('postgres', 'users') }}
{% endsnapshot %}
```

The `updated_at` column you point at MUST be projected by the snapshot's SELECT (dbt reads it directly). Verified at [docs.getdbt.com/reference/resource-configs/strategy](https://docs.getdbt.com/reference/resource-configs/strategy) and [docs.getdbt.com/reference/resource-configs/updated_at](https://docs.getdbt.com/reference/resource-configs/updated_at).

**1b. `strategy='check'` — when the source has NO reliable last-modified column.** Required config key is `check_cols`. dbt re-hashes the listed columns each run and detects changes via hash diff. Two valid forms for `check_cols`:

```sql
-- snapshots/users_snapshot.sql — check strategy with explicit column LIST (preferred — faster)
{% snapshot users_snapshot %}
{{
  config(
    target_schema='analytics',
    unique_key='id',
    strategy='check',
    check_cols=['plan_name', 'country', 'account_tier']   -- LIST form: only these columns trigger an SCD2 update
  )
}}
SELECT id, email, display_name, plan_name, country, account_tier   -- key column `id` is UNALIASED (matches unique_key='id')
FROM {{ source('postgres', 'users') }}
{% endsnapshot %}
```

```sql
-- Same snapshot body as 1b above (SELECT id, email, display_name, plan_name, country, account_tier — key column `id` UNALIASED so unique_key='id' resolves), alternative config only — check_cols='all' STRING shorthand (use only when you want EVERY column tracked)
{{
  config(
    target_schema='analytics',
    unique_key='id',
    strategy='check',
    check_cols='all'   -- STRING shorthand: track every column in the SELECT; per dbt docs "this may be less performant"
  )
}}
```

`check_cols` accepts **either a list of column names OR the literal string `'all'`** — no other shorthand exists. Per [docs.getdbt.com/reference/resource-configs/check_cols](https://docs.getdbt.com/reference/resource-configs/check_cols): *"A list of columns within the results of your snapshot query to check for changes. Alternatively, use all columns using the `all` value (however this may be less performant)."* Prefer the explicit list — `'all'` re-hashes columns like `email`, `display_name`, etc. that you may not care about for SCD2 purposes and makes every run slower.

> **CANONICAL RULE — snapshot `unique_key` must reference a column in the snapshot's SELECT OUTPUT, NOT the raw source column name (keyword anchors: "snapshot unique_key", "unique_key column not found", "dbt snapshot key alias", "unique_key must match select output", "snapshot key vs source column", "Column 'id' not found", "compound unique_key snapshot", "unique_key list form"):** dbt's snapshot `unique_key` config (and the incremental model `unique_key` — same rule, see cross-ref below) resolves against the **compiled SELECT's output columns**, the same way every downstream `ref()` and every `dbt test` does. If your snapshot SELECT aliases the source column (`SELECT id AS user_id, ...`), the output column is `user_id` and **`unique_key='id'` will not resolve** — the run fails on first execution with a `Column 'id' not found` / `Column 'id' cannot be resolved` error from Trino (the column literally does not exist in the materialized snapshot table). Two correct fixes — pick ONE per snapshot:
>
> ```sql
> -- WRONG — unique_key references the SOURCE column, but the SELECT renames it away
> {% snapshot users_snapshot %}
> {{ config(target_schema='analytics', unique_key='id', strategy='timestamp', updated_at='updated_at') }}
> SELECT id AS user_id, email, plan_name, updated_at        -- output column is `user_id`, not `id`
> FROM {{ source('postgres', 'users') }}
> {% endsnapshot %}
> -- First `dbt snapshot --select users_snapshot` fails: "Column 'id' not found" / "cannot be resolved".
>
> -- CORRECT option A — match the alias (most common fix when downstream models prefer the renamed column):
> {% snapshot users_snapshot %}
> {{ config(target_schema='analytics', unique_key='user_id', strategy='timestamp', updated_at='updated_at') }}
> SELECT id AS user_id, email, plan_name, updated_at        -- output column `user_id` matches unique_key='user_id'
> FROM {{ source('postgres', 'users') }}
> {% endsnapshot %}
>
> -- CORRECT option B — don't alias the key column (alias OTHER columns if you must, just not the key):
> {% snapshot users_snapshot %}
> {{ config(target_schema='analytics', unique_key='id', strategy='timestamp', updated_at='updated_at') }}
> SELECT id, email, plan_name AS plan, updated_at           -- key `id` is unaliased; output column matches
> FROM {{ source('postgres', 'users') }}
> {% endsnapshot %}
>
> -- COMPOUND KEY — list form; every listed column must be in the SELECT OUTPUT:
> {% snapshot tenant_users_snapshot %}
> {{ config(target_schema='analytics', unique_key=['tenant_id', 'user_id'], strategy='timestamp', updated_at='updated_at') }}
> SELECT tenant_id, id AS user_id, email, updated_at        -- BOTH `tenant_id` AND `user_id` are in the output
> FROM {{ source('postgres', 'tenant_users') }}
> {% endsnapshot %}
> ```
>
> The compound-list form `unique_key=['col1', 'col2', ...]` is supported and is the canonical way to express a composite snapshot key (verified at [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models): *"the `unique_key` should be supplied … as a string representing a single column or a list of single-quoted column names that can be used together, for example, `['col1', 'col2', …]`"*). The same SELECT-OUTPUT rule applies to **every** listed column — `unique_key=['tenant_id', 'user_id']` fails if either `tenant_id` or `user_id` is missing from the SELECT output. **Mental model:** treat `unique_key` exactly like a downstream `SELECT <key> FROM {{ ref('users_snapshot') }}` — if that query wouldn't compile because the column was aliased away, the snapshot's `unique_key` won't resolve either. **Same rule for `incremental` models** — `unique_key='order_id'` paired with `SELECT id AS order_id, ...` works; paired with `SELECT id, ...` (no alias to `order_id`) does not. Cross-ref: incremental `unique_key` usage and the `MERGE`-key behavior are at [r27 §4.5D / §6.1](27-oracle-plsql-to-dbt-trino.md), [r28 §3 incremental config](28-complex-sql-performance-trino-dbt.md), and [r13 §incremental-strategy=merge](13-postgres-to-iceberg-ingestion.md) — all use the same SELECT-output-column rule for `unique_key`.

**Either strategy adds the SAME FOUR ALWAYS-PRESENT metadata columns automatically** (verified at [docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names](https://docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names)):

- `dbt_scd_id` — unique surrogate ID per version row (md5 hash of `unique_key` + the change-detection value)
- `dbt_updated_at` — when dbt observed/recorded this version (for `strategy='timestamp'` this mirrors the source `updated_at` value; for `strategy='check'` this is the snapshot run time)
- `dbt_valid_from` — when this version became the current row
- `dbt_valid_to` — when this version stopped being current (`NULL` = still active / currently-active version)

```sql
-- Query the CURRENTLY-ACTIVE version per unique_key — the canonical pattern
SELECT * FROM analytics.users_snapshot WHERE dbt_valid_to IS NULL;  -- 4 default cols: dbt_scd_id, dbt_updated_at, dbt_valid_from, dbt_valid_to

-- Query the version that was active at a SINGLE point-in-time instant — use the SAME :ts on BOTH bounds
-- (DO NOT compare end-of-day on one side and start-of-day on the other — asymmetric bounds can miss
--  versions that opened and closed on the same calendar day, or double-count edge versions).
SELECT * FROM analytics.users_snapshot
WHERE dbt_valid_from <= TIMESTAMP '2025-08-10 12:00:00'
  AND (dbt_valid_to IS NULL OR dbt_valid_to > TIMESTAMP '2025-08-10 12:00:00');
```

**DEFAULT vs CONDITIONAL — the one column that is NOT a default.** `dbt_is_deleted` is **NOT** one of the four always-present defaults. It is **added only when** the snapshot config sets **`hard_deletes='new_record'`** (dbt 1.9+, replaces the legacy `invalidate_hard_deletes=true`). Direct doc quote ([docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names](https://docs.getdbt.com/reference/resource-configs/snapshot_meta_column_names)): *"A string value indicating if the record has been deleted. (True if deleted, False if not deleted). Added when hard_deletes='new_record' is configured."* On a default snapshot (no `hard_deletes` config or `hard_deletes='ignore'` / `'invalidate'`), the `dbt_is_deleted` column does **NOT** exist — referencing it in a downstream query errors with `Column 'dbt_is_deleted' cannot be resolved`.

**There is no `dbt_is_current` column.** To query current records: `WHERE dbt_valid_to IS NULL`.

> **HARD DELETES — recording that a source row was physically deleted (and when).** *Keyword anchors: hard delete, source row deleted, record removed from source table, snapshot freezes on last version after a delete, detect/track deletions in a dbt snapshot, capture deletion timestamp, `invalidate_hard_deletes`, `hard_deletes`.* By DEFAULT a dbt snapshot only sees rows the source SELECT returns — when a row is **physically DELETED** from the source (e.g. an Oracle `DELETE FROM customers WHERE id=...`), it simply stops appearing, so the snapshot **freezes the last version forever with `dbt_valid_to` still NULL** (it looks permanently "current"). dbt has a built-in config to fix this — pick the behavior you want (verified at [docs.getdbt.com/reference/resource-configs/hard_deletes](https://docs.getdbt.com/reference/resource-configs/hard_deletes)):
>
> | `hard_deletes` value | What happens when a source row disappears | Use when |
> |---|---|---|
> | `'ignore'` (DEFAULT) | Nothing — the last version stays open (`dbt_valid_to` NULL) forever. You can't tell it was deleted. | You don't care about deletions. |
> | `'invalidate'` | dbt **closes** the version: stamps `dbt_valid_to` = run time, so the row is no longer "current" — but adds NO new row and NO flag. (This is the exact behavior of the legacy `invalidate_hard_deletes=true` boolean, which `hard_deletes` REPLACES in dbt 1.9+.) | You want deleted entities to drop out of the "current" set but don't need an explicit deleted-marker row. |
> | `'new_record'` | dbt **inserts a new version row** with the conditional **`dbt_is_deleted='True'`** meta column set, and `dbt_valid_from` = the deletion's observed time — so history explicitly records the deletion AND when. (This is the only mode that adds the `dbt_is_deleted` column; see the conditional-column note above.) | **Your case — "record that a deletion happened and roughly when."** |
>
> ```sql
> -- snapshots/customers_snapshot.sql — capture hard deletes as explicit deleted-marker rows
> {% snapshot customers_snapshot %}
> {{ config(
>     target_schema='analytics', unique_key='id',
>     strategy='timestamp', updated_at='updated_at',
>     hard_deletes='new_record') }}            -- <- adds dbt_is_deleted, inserts a row on delete
> SELECT id, name, plan_tier, updated_at
> FROM {{ source('oracle', 'customers') }}
> {% endsnapshot %}
>
> -- Which customers were deleted, and approximately when (dbt_valid_from of the deleted-marker row):
> SELECT id, dbt_valid_from AS deleted_at_approx
> FROM analytics.customers_snapshot
> WHERE dbt_is_deleted = 'True';            -- note: VARCHAR 'True'/'False', not a boolean
> ```
>
> **Gotchas:** (a) `dbt_is_deleted` is the **string** `'True'`/`'False'` (VARCHAR), not a SQL boolean — filter with `= 'True'`. (b) `'new_record'` only adds the column going forward; pre-existing snapshot tables need a `--full-refresh` (which DESTROYS existing history) or a manual `ALTER TABLE ... ADD COLUMN` — plan the cutover. (c) the deletion timestamp is when **dbt observed** the row missing (the snapshot run), not the exact source DELETE time — it is only as granular as your snapshot cadence. (d) on dbt ≤1.8 the only option is the legacy boolean `invalidate_hard_deletes=true` (= `'invalidate'` behavior); the `dbt_is_deleted` / `'new_record'` mode requires dbt 1.9+.

> **DO NOT WRITE** (snapshot-strategy citation-hygiene):
> - `strategy='timestamp'` with NO `updated_at='<col>'` config key — dbt errors at parse: *"snapshot 'X' is using the 'timestamp' strategy and must have an 'updated_at' configured"*. The `updated_at` key is required for timestamp strategy.
> - `strategy='check'` with NO `check_cols` config key — dbt errors at parse: *"snapshot 'X' is using the 'check' strategy and must have a 'check_cols' configured"*. The `check_cols` key is required for check strategy.
> - `check_cols=['all']` (list-wrapped string) — that asks dbt to track a column literally named `all` and silently won't detect changes on the real columns. The `all` form is a BARE STRING `'all'`, never wrapped in brackets.
> - `compare_cols`, `monitor_cols`, `watch_cols`, `track_cols` — none exist; only `check_cols` does.
> - `updated_at_field`, `last_modified_column` — none exist; the key is exactly `updated_at`.
> - `strategy='hash'` / `strategy='merge'` / `strategy='changes'` — none exist; the only built-in strategies are `timestamp` and `check`.
> - `dbt_is_current` column — does NOT exist; query current rows via `WHERE dbt_valid_to IS NULL`.
> - "`dbt_is_deleted` is one of the four default snapshot meta columns" — **FALSE.** The four ALWAYS-PRESENT defaults are `dbt_scd_id`, `dbt_updated_at`, `dbt_valid_from`, `dbt_valid_to`. `dbt_is_deleted` is **conditional** — added only when `hard_deletes='new_record'` is configured. Listing it in place of `dbt_updated_at` (a common slip) is wrong on both ends: `dbt_updated_at` IS a default; `dbt_is_deleted` is NOT.
> - Omitting `dbt_updated_at` from the default-column list — `dbt_updated_at` IS one of the four always-present defaults. Any "the four defaults are X, Y, Z, dbt_is_deleted" formulation is wrong.
> - `unique_key='<source_column_name>'` paired with a `SELECT <source_col> AS <renamed_col>, ...` body — the snapshot/incremental `unique_key` resolves against the **compiled SELECT's OUTPUT column names**, NOT the raw source-table column. `unique_key='id'` with `SELECT id AS user_id, ...` fails on first run with `Column 'id' not found` / `cannot be resolved`. Fix: either use `unique_key='user_id'` (match the alias) OR drop the alias and write `SELECT id, ...`. Same rule for compound keys — every column in `unique_key=['tenant_id', 'user_id']` must be in the SELECT output. See the canonical rule block immediately above for worked right/wrong side-by-side.

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

```sql
-- Trino 467 DDL.
CREATE TABLE iceberg.analytics.daily_user_activity (
  activity_date  DATE,
  tenant_id      VARCHAR,
  user_id        VARCHAR,
  plan_type      VARCHAR,
  event_count    BIGINT,
  session_count  INTEGER,
  features_used  INTEGER
)
WITH (
  partitioning    = ARRAY['month(activity_date)'],
  format          = 'PARQUET',
  format_version  = 2
);
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

This is the standard SaaS pattern when you have an existing event source (like a Postgres `events.properties JSONB` column) and you don't know up front which fields will become hot. You promote the fields you query often to first-class typed columns and keep the rest in a fallback structure (a `MAP(VARCHAR, VARCHAR)` or the raw JSON string). It gives you the columnar/pruning benefits of typed columns for the 80% of dashboard queries that hit known fields, plus the schema flexibility of a bag for the long tail.

### Shape of the two-tier table

```sql
-- Trino 467 DDL.
CREATE TABLE iceberg.analytics.user_events (
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
  properties         MAP(VARCHAR, VARCHAR),   -- Option A: Parquet-native MAP
  properties_raw     VARCHAR                  -- Option B: raw JSON string
)
WITH (
  partitioning    = ARRAY['day(occurred_at)', 'tenant_id'],
  format          = 'PARQUET',
  format_version  = 2
);
```

Pick **MAP** if downstream queries hit lots of different fallback keys and you want simple `element_at(properties, 'key')` access. Pick **VARCHAR JSON string** if the fallback fields are queried very rarely (truly long-tail) and you want minimum write-side complexity — `json_extract_scalar(properties_raw, '$.key')` works fine for occasional access.

### MAP access — Parquet-native, NOT JSON parsing (important!)

> **Navigation — map functions covered in this section (so you can jump straight to the right idiom):** read a single key with default → `element_at` + `COALESCE(element_at(...), <default>)`; **merge / combine / overlay two maps (e.g. defaults + tenant overrides) → `map_concat` (RIGHTMOST map wins)**; filter / transform / inspect entries without UNNEST → MAP higher-order functions (`map_filter`, `transform_values`, `transform_keys`, `map_keys`, `map_values`); export a MAP column as JSON → `CAST(map_col AS JSON)`.

> **`MAP(VARCHAR, VARCHAR)` in Iceberg/Parquet is a NATIVE NESTED TYPE — not a JSON string.** When Trino reads a MAP column it reads the binary Parquet MAP encoding (a pair of repeated key/value child columns) — there is no JSON parser involved per row. The correct mental model is: **"Trino reads the full MAP column and applies a key lookup per row — no JSON parsing, but also no file-level pruning for MAP keys."** (Trino spells the type with parentheses: `MAP(K, V)`. The angle-bracket form `MAP<K, V>` is Hive/Spark syntax and parse-errors in Trino 467 — see [trino.io/docs/current/language/types.html](https://trino.io/docs/current/language/types.html).)

This matters because the distinction drives the right optimization advice:

- A MAP key lookup is **fast** per row (it's a binary tree/hash on the decoded key array — not JSON tokenization).
- But MAP predicates **cannot trigger file-level pruning** — Iceberg/Parquet does **NOT collect per-key statistics for MAP columns**. The only stats kept on a MAP column are column-level null count and total size. Even if the key `debug_mode` is set on every row, Iceberg has no per-file min/max for that key's values, so `WHERE element_at(properties, 'debug_mode') = 'true'` reads every file in the partition range — there is no skipping.
- Promoting a key to a top-level column adds per-file min/max stats and therefore enables file pruning. **This is the single biggest reason to promote a key**, not raw access speed.

By contrast, `json_extract_scalar(properties_raw, '$.key')` over a JSON string column DOES involve a JSON tokenize-and-walk per row. It's measurably slower than MAP access at scan time, and it also cannot be file-pruned. So MAP > JSON string for query latency on the fallback, and promoted column > MAP for prunability.

### CRITICAL — use `element_at()`, NOT `[]`, for MAP access in Trino

> **Disambiguator — wrong tool for ROW columns.** If your column is a native `ROW(...)` / struct (named fields), use **dot notation** `col.field` — `element_at` is for **MAP / ARRAY only** (no `element_at(row(...), ...)` overload exists; calling it on a ROW is a Trino type error). See the **native-ROW dot-access LEADING CANONICAL** below before continuing.

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

#### Existence check on a MAP key — the CORRECT form, and a common TYPE ERROR to avoid

> **TYPE-LEVEL fact (memorize before writing any existence check on a MAP column).** On a `MAP(K, V)` column, `element_at(map_col, key)` returns the value type `V` — i.e. a **scalar** (e.g. `VARCHAR`, `BIGINT`, `DOUBLE`), NOT a collection. Verified at [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html) (`element_at(map(K, V), key) -> V`). Trino's `cardinality(x)` accepts only `ARRAY(E)` or `MAP(K, V)`, NOT scalars — verified at [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html) and [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html). Composing them produces a SQL **type error**, not a runtime NULL.

```sql
-- CORRECT — existence check on a MAP key. element_at returns NULL when the key
-- is absent; IS NOT NULL filters the present rows.
SELECT user_id
FROM iceberg.analytics.user_events
WHERE element_at(properties, 'debug_mode') IS NOT NULL;
```

```sql
-- DO NOT WRITE — cardinality(element_at(map_col, key)) is a Trino TYPE ERROR.
SELECT user_id
FROM iceberg.analytics.user_events
WHERE cardinality(element_at(properties, 'debug_mode')) > 0;
-- WHY THIS FAILS: on a MAP(VARCHAR, VARCHAR), element_at(properties, 'debug_mode')
-- returns a VARCHAR scalar (the value at that key, or NULL). cardinality() accepts
-- only ARRAY or MAP arguments — not VARCHAR (or any other scalar). The Trino
-- analyzer rejects this query with a type-mismatch error before execution.
--   Source: trino.io/docs/current/functions/map.html (element_at(map(K,V), key) -> V)
--   Source: trino.io/docs/current/functions/array.html (cardinality(x) on array/map only)
-- The correct existence check is `element_at(properties, 'debug_mode') IS NOT NULL`.
```

```sql
-- ALSO DO NOT WRITE — these adjacent "key-existence" forms have their own problems:
SELECT user_id FROM iceberg.analytics.user_events
WHERE properties['debug_mode'] IS NOT NULL;
-- WHY THIS FAILS: bracket access on a MAP raises "Key not present in map" on
-- ANY row missing the key, so the query errors before IS NOT NULL is evaluated.
-- Use element_at() for the same intent.

SELECT user_id FROM iceberg.analytics.user_events
WHERE properties['debug_mode'] IS NOT NULL;  -- (repeated for contrast — bracket = error on missing key)
```

> **EXACT key-EXISTENCE vs. value-PRESENT — they are NOT the same check.** *Keyword anchors: does a map have this key, map key exists regardless of value, contains map_keys, present-with-null-value key, key added but value null, is a key in the map, test if a map contains a key, key present even when value is NULL.*
> - **Key EXISTENCE regardless of value** → `contains(map_keys(properties), 'debug_mode')` → returns a **boolean**; TRUE whenever the key is in the map **even if that key maps to a NULL value**. `map_keys(map(K,V)) -> array(K)` lists every key; `contains(array, element) -> boolean` tests membership (both verified at [trino.io/docs/467/functions/map.html](https://trino.io/docs/467/functions/map.html) and [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html)).
> - **Value present (the quick everyday check)** → `element_at(properties, 'debug_mode') IS NOT NULL`. This is correct for the common case where keys are only ever set to non-NULL values, but it **FALSE-NEGATIVES a key that exists with a NULL value**: `element_at(m, k)` returns NULL for BOTH an absent key AND a present-key-with-NULL-value, so `IS NOT NULL` cannot tell those two apart.
> - **Rule of thumb:** if a key can legitimately be stored with a NULL value and you must still count it as "present", use `contains(map_keys(m), k)`. Otherwise `element_at(m, k) IS NOT NULL` is the fine, cheaper everyday form.
> - **If your column is a JSON STRING (VARCHAR holding JSON), not a native MAP** → the purpose-built key-existence test is `json_exists(json, 'strict $.key') -> boolean` (true if the key is present even when its value is `null`, false if absent). See [resource 13 § "check whether a JSON KEY EXISTS (presence, not just a non-null value) → json_exists"](13-postgres-to-iceberg-ingestion.md). `contains(map_keys(CAST(json AS MAP(...))), 'key')` also works but forces a full parse of the JSON into a MAP first. Pick by the column's actual TYPE: native MAP → `contains(map_keys(map_col), 'key')`; JSON string → `json_exists`.

**Mnemonic:** `element_at` on a MAP returns the **value** (a scalar). `cardinality` wants a **collection** (array or map). You can't wrap one in the other. For the everyday "is this key set to a value" check use `element_at(map_col, key) IS NOT NULL`; for **exact key existence regardless of value** (including a key mapped to NULL) use `contains(map_keys(map_col), key)`.

### LEADING CANONICAL — merge two maps with `map_concat` (RIGHTMOST map wins on key collision; the right idiom for defaults + overrides)

**Keyword anchors so the responder lands here:** merge two maps Trino, combine maps override, default settings override map, tenant overrides map, map_concat, rightmost map wins, merge maps tenant wins, overlay maps, merge map with override, union of maps Trino, merge MAP columns, combine MAP columns Trino, overlay tenant overrides onto defaults, how to merge maps in Trino, Trino merge two map columns into one, combine default map with override map.

**The rule.** When you need to combine two (or more) MAP values into one MAP — for example, overlay tenant-specific overrides on top of a default-settings map — use `map_concat`. It is **built into Trino 467** (see [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html)). On key collision, the **RIGHTMOST** (last) map wins — so **put the OVERRIDE map LAST**.

**Signature** (verbatim from the Trino docs):

```
map_concat(map1(K, V), map2(K, V), ..., mapN(K, V)) -> map(K, V)
```

**Duplicate-key rule** (verbatim from [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html)):

> *"If a key is found in multiple given maps, that key's value in the resulting map comes from the last one of those maps."*

So `map_concat(default_settings, tenant_overrides)` keeps any tenant override over the corresponding default, and `map_concat(tenant_overrides, default_settings)` does the opposite (defaults win — usually wrong).

**Worked SaaS example — overlay tenant overrides on top of default settings, per tenant.**

```sql
-- Effective settings per tenant: take the defaults, then overlay tenant overrides.
-- tenant_overrides goes LAST so its values WIN on any key both maps contain.
SELECT
  tenant_id,
  map_concat(default_settings, tenant_overrides) AS effective_settings
FROM iceberg.analytics.tenant_config;
```

Behavior per key:

- Key present in `default_settings` only -> value from `default_settings` (survives unchanged).
- Key present in `tenant_overrides` only -> value from `tenant_overrides` (added to the result).
- Key present in BOTH -> value from `tenant_overrides` (RIGHTMOST map wins — the tenant override replaces the default).

`NULL`-MAP inputs: if any argument is `NULL`, `map_concat` returns `NULL`. Wrap with `COALESCE(map_arg, MAP())` if you want to treat a NULL MAP column as an empty MAP rather than poisoning the result.

**DO NOT WRITE** (the exact wrong forms to avoid):

| Wrong form | Why it's wrong | Correct form |
|---|---|---|
| "Trino 467 has no built-in `map_concat`" / "without a built-in `map_concat`" | **FALSE** — `map_concat` is built-in and documented at [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html). Do not claim it is missing. | `map_concat(m1, m2)`. |
| "LEFT map wins on key collision" | **FALSE** — the RIGHTMOST (last) map wins per the verbatim docs quote above. | Put the OVERRIDE map LAST. |
| `m1 || m2` (using `||` as map-merge) | Trino's `||` is the string/array concatenation operator — it does NOT work on MAPs. Parse/type error. | `map_concat(m1, m2)`. |
| `map_from_entries(map_entries(m1) || map_entries(m2))` | Unnecessary (use `map_concat` directly) AND broken on key collision: `||` on two `array(row(K,V))` produces an array with DUPLICATE-key rows when both maps share a key. `map_from_entries` then **errors** on the duplicate key (Trino/Presto enforces "Duplicate map keys are not allowed" — see [duckdb/duckdb#3640](https://github.com/duckdb/duckdb/issues/3640) describing the PrestoDB behavior). | `map_concat(m1, m2)`. |
| `transform_values(m1, (k, v) -> COALESCE(element_at(m2, k), v))` as the override idiom | **Silent data bug.** This only iterates the keys of `m1` — any key present **only** in `m2` (a tenant-specific key not in defaults) is silently dropped from the result. The override surface is wrong. | `map_concat(m1, m2)` — keeps the union of keys, RIGHTMOST wins on collision. |
| `CASE WHEN ... END` ladder over keys to merge maps | Verbose, only works for a known fixed key set, and wrong shape — `map_concat` is the one-call idiom for arbitrary key sets. | `map_concat(m1, m2)`. |

**Cross-references.** For single-key reads with a default (one key at a time, not a whole-map merge), see the `COALESCE(element_at(...), <default>)` callout immediately below. For per-entry FILTER or TRANSFORM (e.g., keep only entries where the value is `true`, or rewrite every value with a lambda), see the MAP higher-order function family canonical below (`map_filter`, `transform_values`, `transform_keys`, `map_keys`, `map_values`).

#### `COALESCE(element_at(map_col, key), <default>)` — MAP lookup with a fallback value when the key is missing

**Keyword anchors so the responder lands here:** map lookup with default, fall back when key missing, default value for missing map key, element_at default, COALESCE element_at, map key default Trino, supply default for MAP key, MAP read with fallback, MAP key not present default, NULL when MAP key missing, return default when key not in map.

**The rule.** `element_at(map_col, key)` returns NULL when the key is absent — wrap in `COALESCE` to substitute a default value. This is the canonical "MAP get-with-default" idiom on Trino 467 (there is no `element_at(map, key, default)` 3-arg overload — you compose with `COALESCE`).

**Worked example:**

```sql
SELECT user_id,
       COALESCE(element_at(settings, 'theme'), 'default_theme') AS theme
FROM   iceberg.analytics.users;
-- If 'theme' is absent OR mapped to NULL, returns 'default_theme'. Otherwise returns the stored value.
```

Verified at [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html) (`element_at(map(K, V), key) -> V`, NULL on missing key) and [trino.io/docs/current/functions/conditional.html](https://trino.io/docs/current/functions/conditional.html) (`COALESCE(v1, v2, ...)` returns the first non-NULL).

**Cross-refs.** For merging two whole maps (defaults + overrides), see the `map_concat` H3 immediately above. For per-entry filter/transform without UNNEST, see the MAP higher-order function H3 immediately below.

### LEADING CANONICAL — Trino MAP higher-order functions (`map_filter` / `map_keys` / `map_values` / `transform_keys` / `transform_values`): filter and reshape a MAP IN-PLACE (no UNNEST)

> **Keyword anchors so the responder lands here:** Trino map_filter, filter map by value, filter map by key, map_keys map_values, keys where value true, transform map without unnest, map higher-order function, map HOF Trino, lambda map Trino, rebuild map with transformed values, get keys whose value is true, keep only entries matching condition map, map_filter no second argument needed, map_entries map_from_entries.

**The rule.** When you want to FILTER or RESHAPE a MAP and KEEP THE RESULT AS A MAP (one row in, one row out), use Trino's MAP higher-order functions (HOFs). UNNEST + WHERE + MAP_AGG is the WRONG shape for this — UNNEST explodes the MAP to rows. Verified at [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html) and [trino.io/docs/current/functions/lambda.html](https://trino.io/docs/current/functions/lambda.html).

| Function | Signature | What it does |
|---|---|---|
| `map_filter` | `map_filter(map(K,V), (k, v) -> boolean) -> map(K,V)` | Returns a MAP keeping only entries for which the lambda is true. Example: `map_filter(flags, (k, v) -> v = true)` -> only true-valued entries. |
| `map_keys` | `map_keys(map(K,V)) -> array(K)` | Extracts all keys as an ARRAY. |
| `map_values` | `map_values(map(K,V)) -> array(V)` | Extracts all values as an ARRAY. |
| `transform_keys` | `transform_keys(map(K,V), (k, v) -> K2) -> map(K2,V)` | Rebuilds a MAP with each key transformed by the lambda. |
| `transform_values` | `transform_values(map(K,V), (k, v) -> V2) -> map(K,V2)` | Rebuilds a MAP with each value transformed by the lambda. |
| `cardinality` | `cardinality(map(K,V)) -> bigint` | Number of entries in the MAP. |
| `element_at` | `element_at(map(K,V), key) -> V` | NULL-safe lookup — see the canonical above. |

**Worked example — get the keys of a `feature_flags MAP(VARCHAR, BOOLEAN)` whose value is `true`, WITHOUT UNNESTing:**

```sql
-- CORRECT — combine map_filter + map_keys. One row in, one ARRAY(VARCHAR) out.
SELECT user_id,
       map_keys(map_filter(feature_flags, (k, v) -> v)) AS enabled_flags
FROM iceberg.analytics.users;
-- For a MAP(VARCHAR, BOOLEAN), v is already boolean — use `(k, v) -> v` directly.
-- For a MAP(VARCHAR, VARCHAR) holding 'true'/'false', use `(k, v) -> v = 'true'`.
```

> **Per-row vs. table-wide: `map_keys()` alone returns the keys PER ROW.** *Keyword anchors: all distinct keys across rows, audit every key in a map column, distinct map keys table-wide, list every key used in a map column, all keys across all rows, account-wide list of map keys, every flag name anyone has set.* `map_keys(feature_flags)` gives the keys of **one row's** map — it does NOT roll up across rows. To list **every DISTINCT key across ALL rows** (an account-wide audit — "which flag names exist anywhere in the table"), explode then aggregate: `SELECT array_agg(DISTINCT k) FROM iceberg.analytics.users CROSS JOIN UNNEST(map_keys(feature_flags)) AS u(k);` (or `SELECT DISTINCT k` if you want one row per key instead of one array). The `CROSS JOIN UNNEST(map_keys(...))` turns each row's key-array into rows; `array_agg(DISTINCT k)` collapses them to the unique set.

**DO NOT WRITE.** (1) "Trino has no `map_filter` / no way to filter a MAP without UNNEST" — **FALSE**, `map_filter` is documented at [trino.io/docs/current/functions/map.html](https://trino.io/docs/current/functions/map.html). (2) `UNNEST(map_entries(m)) ... WHERE ... GROUP BY ... MAP_AGG(...)` JUST to filter a MAP — that explode/regroup pattern is only correct when you genuinely need ROWS (e.g. to JOIN per-entry against another table or GROUP BY across rows). For pure filter/transform of a MAP, use `map_filter` / `transform_values` directly. **When you GENUINELY need ROWS** (one row per key/value — e.g. `GROUP BY` a map key across rows, JOIN per-entry, "explode a map into rows") the canonical is `CROSS JOIN UNNEST(map_col) AS t(k, v)` — UNNEST a MAP gives **TWO** columns needing **TWO** aliases; see [resource 07 §1a — explode a MAP column into one row per (key, value)](07-analytical-query-patterns.md#1a-exploding-an-array-column-to-one-row-per-element-unnest--array-to-rows--left-join-unnest). That is the OPPOSITE direction of these HOFs (HOFs keep the map a map; UNNEST turns it into rows).

### LEADING CANONICAL — `CAST(map / array / row AS JSON)` is the right way to export a MAP column as JSON in Trino 467

> **Keyword anchors so the responder lands here:** Trino map to json, cast map as json, struct row to json, array to json, json_format, export map column as json string, map to json string API, send MAP to JSON API, Trino map JSON cast, ROW to JSON, ARRAY to JSON, MAP to JSON cast Trino 467, serialize MAP to JSON, MAP to VARCHAR JSON, json_parse map round trip.

**The one rule.** Trino's `CAST(... AS JSON)` is the direct, documented way to convert a MAP, ARRAY, or ROW into a `JSON` value. Per [trino.io/docs/current/functions/json.html](https://trino.io/docs/current/functions/json.html) verbatim: MAP can be cast when "the key type of the map is `VARCHAR` and the value type of the map is a supported type"; ARRAY when "the element type of the array is one of the supported types"; ROW when "every field type of the row is a supported type". **Do NOT believe the claim that Trino has no MAP/ARRAY/ROW → JSON cast — `CAST(... AS JSON)` works directly on all three.** (If the consumer needs a JSON object per row with **real JSON numbers** rather than stringified values, see the type-preserving `json_object(...)` note immediately after this card — a MAP cast forces one homogeneous value type and quotes mixed numerics.)

```sql
-- 1. MAP -> JSON object (requires VARCHAR keys + supported value types).
SELECT CAST(MAP(ARRAY['k1','k2'], ARRAY[1, 23]) AS JSON);
-- Result: JSON '{"k1":1,"k2":23}'

-- 2. ARRAY -> JSON array.
SELECT CAST(ARRAY[1, 2, 3] AS JSON);
-- Result: JSON '[1,2,3]'

-- 3. ROW -> JSON object (named fields become JSON keys; anonymous ROW -> JSON array).
SELECT CAST(CAST(ROW(123, 'abc', true) AS ROW(v1 BIGINT, v2 VARCHAR, v3 BOOLEAN)) AS JSON);
-- Result: JSON '{"v1":123,"v2":"abc","v3":true}'

-- 4. Get a VARCHAR JSON STRING (e.g. to send to an external API) — wrap in json_format.
SELECT json_format(CAST(properties AS JSON)) AS properties_json_text
FROM iceberg.analytics.user_events;
-- Equivalent: CAST(CAST(properties AS JSON) AS VARCHAR)

-- 5. REVERSE direction — VARCHAR JSON string -> MAP. Use json_parse first, then CAST.
SELECT CAST(json_parse(properties_raw) AS MAP(VARCHAR, VARCHAR))
FROM iceberg.analytics.user_events;
```

**THE TRAP — `CAST(map_col AS VARCHAR)` is NOT JSON.** Casting a MAP directly to VARCHAR produces Trino's internal debug rendering like `{k1=v1, k2=v2}` (equals signs, no quotes around keys, no quotes around string values). **That string is NOT valid JSON** — sending it to a downstream JSON API will cause the consumer to fail with a parse error. **Always go through `JSON` first: `json_format(CAST(map_col AS JSON))` or equivalently `CAST(CAST(map_col AS JSON) AS VARCHAR)`.** Same trap applies to ARRAY and ROW — `CAST(ARRAY[1,2] AS VARCHAR)` returns `'[1, 2]'`-style debug output, not guaranteed-canonical JSON.

#### DO-NOT-WRITE — banned MAP/ARRAY/ROW → JSON patterns

| Banned writing | Why it's wrong | Correct form |
|---|---|---|
| "Trino has no direct MAP/ARRAY/ROW → JSON cast — you have to hand-roll JSON with string concatenation." | **FALSE.** `CAST(... AS JSON)` works directly on all three per [trino.io/docs/current/functions/json.html](https://trino.io/docs/current/functions/json.html). | `CAST(my_map_col AS JSON)` — direct. Wrap in `json_format(...)` for a VARCHAR result. |
| `CAST(my_map_col AS VARCHAR)` expecting a JSON string | Returns Trino's debug form `{k1=v1, k2=v2}` — NOT valid JSON. Will fail parsers on the receiving side. | `json_format(CAST(my_map_col AS JSON))` or `CAST(CAST(my_map_col AS JSON) AS VARCHAR)`. |
| Hand-rolling JSON via string concatenation (`'{' \|\| key \|\| ':' \|\| value \|\| '}'`) | Brittle — breaks on values containing `"`, `\`, control characters, multi-byte characters; you re-implement JSON escaping wrong. | `json_format(CAST(my_map_col AS JSON))`. The engine handles all escaping. |
| Hand-rolling JSON via `string_agg(key \|\| ':' \|\| value, ',')` to assemble a JSON object | **DOUBLY WRONG.** (1) `string_agg` is PostgreSQL — **NOT a Trino function** (see §"Trino string aggregation" cross-ref below). (2) Even if it existed, string concatenation does not produce safe JSON escaping. | `json_format(CAST(my_map_col AS JSON))`. |
| `CAST(MAP(ARRAY[1, 2], ARRAY['a','b']) AS JSON)` (INTEGER keys) | Per docs, MAP → JSON cast requires `VARCHAR` keys. INTEGER keys raise a type error. | Cast keys to VARCHAR first: `CAST(MAP(ARRAY[CAST(1 AS VARCHAR), CAST(2 AS VARCHAR)], ARRAY['a','b']) AS JSON)`. |

**Cross-reference.** This is the same data-type family as the MAP/`element_at` content above (use `element_at(map_col, key)` to read individual MAP values; use `CAST(map_col AS JSON)` to export the whole MAP as JSON). For string-aggregation in Trino (which is NOT `string_agg`/`group_concat`), see [resource 27 § 7A.2A — Oracle WINDOWED LISTAGG → Trino](27-oracle-plsql-to-dbt-trino.md) and the inline note immediately below.

#### TYPE-PRESERVING JSON object per row — `json_object('k' VALUE expr, ...)` keeps numbers as real JSON numbers

> **Keyword anchors so the responder lands here:** JSON object per row, row to JSON, build JSON for an API, json_object Trino, numeric JSON not quoted, preserve number types in JSON, one JSON object per customer, emit JSON object per row, type-preserving JSON, json_object vs map to json, unquoted numbers in JSON.

**When the consumer needs REAL JSON numbers (not strings), build the object with `json_object(...)`, not a MAP cast.** Trino 467 has the SQL/JSON constructor `json_object('key' VALUE expr, ...)` (the `KEY`/`VALUE` keywords are optional — `'key' : expr` also works). It builds a JSON OBJECT **preserving each value's type**: numbers stay numeric, booleans stay `true`/`false`, strings get quoted. Per [trino.io/docs/467/functions/json.html](https://trino.io/docs/467/functions/json.html) verbatim, `SELECT json_object('x' : true, 'y' : 12e-1, 'z' : 'text')` returns `'{"x":true,"y":1.2,"z":"text"}'` — note `1.2` is an unquoted JSON number.

```sql
-- Type-PRESERVING JSON object per row (numbers stay real JSON numbers, NOT quoted strings):
SELECT customer_id,
       json_object(
         'total_orders'    VALUE COUNT(DISTINCT order_id),
         'total_spend'     VALUE SUM(amount),
         'avg_order_value' VALUE AVG(amount)
       ) AS customer_stats
FROM orders
GROUP BY customer_id;
-- -> {"total_orders":42,"total_spend":1250.50,"avg_order_value":29.77}   (unquoted numbers)

-- Equivalent colon form (KEY/VALUE keywords are optional in Trino 467):
SELECT json_object('total_orders' : COUNT(DISTINCT order_id),
                   'total_spend'  : SUM(amount)) AS customer_stats
FROM orders GROUP BY customer_id;

-- json_array(...) is the array equivalent (also type-preserving):
SELECT json_array(1, 'text', true);   -- -> [1,"text",true]
```

**THE RULE.** To emit a JSON object per row, **`json_object('k' VALUE expr, ...)` PRESERVES value types** — numbers stay numeric, booleans stay boolean. `CAST(MAP(ARRAY[keys], ARRAY[values]) AS JSON)` also produces a JSON object (it is the LEADING CANONICAL above and remains valid), **but a MAP needs ONE homogeneous value type**, so casting mixed numeric aggregates to VARCHAR first stringifies them (`total_spend` becomes `"1250.50"` — quoted). Use `json_object` when the downstream consumer (e.g. a REST/API client) needs real JSON numbers; use the MAP cast when all values share one type or string values are acceptable. Note also `CAST(ROW(...) AS JSON)` emits a JSON **array** when the ROW is anonymous (it drops the field names) — name the ROW fields, or use `json_object`, when you need a keyed object.

**Cross-reference.** The MAP→JSON cast (still valid for homogeneous values) is the LEADING CANONICAL immediately above; the reverse JSON→typed direction is the `CAST(json_parse(...) AS ROW/MAP/ARRAY)` canonical below.

### LEADING CANONICAL — get a field out of a native ROW / struct column (dot notation col.field, no CAST needed)

> **Keyword anchors so the responder lands here:** nested structure column, struct column, ROW column, get a field out of a struct, address.city, native struct field, Iceberg struct/nested column, select one field from a nested column, filter on a struct field, struct dot notation, row type field access, pull a field from a nested column, native ROW field access Trino, access ROW field, ROW(...) column dot notation, get value of a struct field, struct field SELECT Trino, native nested column field, Iceberg nested column dot access, address.state WHERE clause, project a single struct field, no CAST struct field.

**The fact in one sentence.** If a column is ALREADY typed as `ROW(...)` (a native Iceberg struct / nested column), you read its named fields with the dot field-reference operator — `col.field` — directly. **No `CAST`, no `json_parse`, no `element_at`, no `json_extract_scalar` is needed.** Per [trino.io/docs/467/language/types.html](https://trino.io/docs/467/language/types.html) verbatim: *"Named row fields are accessed with field reference operator (`.`)."* The same docs page shows the canonical form `CAST(ROW(1, 2.0) AS ROW(x BIGINT, y DOUBLE)).x` — but on a TABLE COLUMN already typed `ROW(...)` you skip the CAST and write `col.x` directly.

**Worked example — a column `address` typed `ROW(street VARCHAR, city VARCHAR, state VARCHAR, zip VARCHAR)` on an Iceberg table:**

```sql
-- CORRECT — dot notation directly on the native ROW column. No CAST, no element_at, no json_extract_scalar.
SELECT address.city,
       address.state
FROM iceberg.analytics.customers
WHERE address.state = 'CA';

-- Pull every named field out into top-level columns:
SELECT customer_id,
       address.street AS street,
       address.city   AS city,
       address.state  AS state,
       address.zip    AS zip
FROM iceberg.analytics.customers;

-- Filter + group by a struct field directly:
SELECT address.state, COUNT(*) AS customer_count
FROM iceberg.analytics.customers
WHERE address.country = 'US'
GROUP BY address.state;
```

**Field-name edge cases.**

- If a ROW field name collides with a SQL reserved keyword or contains odd characters, wrap it in double quotes: `address."zip"`, `address."order"`. The double quotes preserve the identifier; they are NOT the MAP string-key subscript (that does not exist for ROW).
- If the ROW itself is `NULL` for some rows, `row_col.field` evaluates to `NULL` for those rows (the dot does not raise; it propagates NULL). Filter or `COALESCE` if you need a sentinel.
- Field access is by NAMED FIELD, not by string-key subscript. There is no `address['city']` syntax on a ROW (that's MAP syntax and will type-error on a ROW). For ROW positional access on UNNAMED rows only, the docs allow `row_expr[1]` (1-based) — but on a NAMED ROW column the dot form is the right answer.

**DO NOT WRITE — the exact wrong forms a "nested column / struct column" question often produces:**

| Wrong form | Why it's wrong (verbatim Trino docs) | Correct form |
|---|---|---|
| `element_at(address, 'city')` | `element_at` is documented ONLY as `element_at(map(K, V), key) -> V` (and the array overload `element_at(array(E), index) -> E`) per [trino.io/docs/467/functions/map.html](https://trino.io/docs/467/functions/map.html) and [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html). **There is NO `element_at(row(...), ...)` overload.** Calling `element_at` on a ROW column produces a Trino type/analyzer error before execution — `element_at` is MAP/ARRAY only, NOT ROW. | `address.city` (dot notation on the native ROW column). |
| `json_extract_scalar(address, '$.city')` | `json_extract_scalar` requires a `JSON` or `VARCHAR` (JSON-text) input per [trino.io/docs/467/functions/json.html](https://trino.io/docs/467/functions/json.html). A ROW is neither — passing a ROW value produces a type error. JSON path syntax is the wrong tool entirely when the column is a typed struct. | `address.city`. |
| `address['city']` | Subscript with a STRING KEY (`['key']`) is MAP syntax, not ROW. On a ROW the field is accessed by NAME via the dot, not by string-key lookup. (Unnamed-ROW positional `row[1]` is legal, but for a NAMED-ROW column the dot is the right form.) | `address.city`. |
| `CAST(json_parse(address) AS ROW(street VARCHAR, city VARCHAR, ...))` then `.city` | **Wrong direction.** This path is for promoting a JSON-STRING (`VARCHAR`) column into a typed ROW. When the column is ALREADY a `ROW(...)`, there is nothing to parse — `json_parse` requires VARCHAR and will error on a ROW; the extra CAST is also unnecessary. | `address.city` directly. |
| `cast(address AS ROW(...)).city` on a column already typed `ROW(...)` | Redundant — the column is already a typed ROW; the CAST is dead work and noisy. (Only needed inside `CAST(ROW(...) AS ROW(... names ...))` literal-construction examples, not on a stored ROW column.) | `address.city`. |
| Joining `address` to a separate `address_fields` lookup table to "get the city" | The fields are ALREADY in the row as named ROW fields — no join needed. | `address.city`. |

**Cross-references.** If your column is a `VARCHAR` holding a JSON string (NOT a native ROW), use the next section's `CAST(json_parse(payload) AS ROW(...))` LEADING CANONICAL to promote it. If the column is a `MAP(VARCHAR, VARCHAR)`, use `element_at(map_col, 'key')` from the MAP canonical above. The trichotomy: native ROW → dot; JSON-text → `CAST(json_parse(...) AS ROW(...))` then dot; MAP → `element_at(map_col, 'key')`. Pick by the column's actual TYPE, not by what the data "looks like" in a sample.

#### Unpack ALL fields of a ROW column into separate columns — `(row_col).*` (no need to list each field)

> **Keyword anchors so the responder lands here:** unpack a row column, expand struct into columns, all fields of a row as columns, flatten a ROW without listing fields, (row).* expansion, struct to columns, explode a ROW into columns, project every struct field, ROW dot-star, expand all named fields of a struct, turn a ROW column into top-level columns.

**The fact in one sentence.** To explode EVERY field of a `ROW` column into its own output column **without typing each field name**, use the row-expansion form `(row_col).*` — the **parentheses around the column reference are REQUIRED**. Per [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html) verbatim: *"In the case of `row_expression.* [ AS ( column_alias [, ...] ) ]`, the `row_expression` is an arbitrary expression of type `ROW`."* The documented example is `SELECT (CAST(ROW(1, true) AS ROW(field1 bigint, field2 boolean))).*`. Without `AS (...)` aliases the original ROW field names are preserved.

```sql
-- Expand ALL fields of a ROW column into separate output columns (no need to list them):
SELECT (properties).*                 -- parentheses around the column are REQUIRED
FROM events;

-- with explicit output names:
SELECT (properties).* AS (plan, region, account_tier) FROM events;

-- access just ONE field (no parens needed):
SELECT properties.plan FROM events;
```

```sql
-- ❌ CROSS JOIN UNNEST(properties) to expand a ROW's named fields into columns -- WRONG: UNNEST expands ARRAY (into one column) or MAP (into key,value) into ROWS, NOT a single ROW's fields into columns; use (properties).* for all fields or properties.field for one — DO NOT COPY
```

**THE RULE.** To expand **ALL** fields of a `ROW` column into columns, use `(row_col).*` — **the parentheses around the column are REQUIRED**. To access a **single** field, use dot notation `row_col.field` (the LEADING CANONICAL immediately above — still correct for one field). **`UNNEST` does NOT do this:** per the docs UNNEST expands an `ARRAY` (into one column) or a `MAP` (into `key, value` columns) into ROWS — it only expands ROW fields when given an `ARRAY` of `ROW` (`UNNEST(array_of_rows)`), never a single `ROW` column's fields into columns. So "`CROSS JOIN UNNEST` a ROW column to get its fields as columns" is wrong — reach for `(row_col).*` instead.

### LEADING CANONICAL — `CAST(json_col AS ROW(...) / MAP(VARCHAR, T) / ARRAY(T))` parses a JSON column INTO a TYPED structure (the JSON → typed direction)

> **Keyword anchors (read this section FIRST when your question contains any of these):** Trino parse JSON into ROW, JSON to struct Trino, cast JSON as ROW Trino, cast JSON as MAP Trino, cast JSON as ARRAY Trino, json_parse then cast, extract typed struct from json column, deserialize JSON to typed columns Trino, JSON → ROW round trip, parse JSON column to record, materialize JSON into typed fields, `CAST(json_col AS ROW(a INT, b VARCHAR))`, `CAST(json_parse(s) AS MAP(VARCHAR, VARCHAR))`, JSON column to dbt model typed fields, JSON inbound to typed structure Trino.

> **Forward disambiguator — read this FIRST.** If your column is ALREADY typed `ROW(...)` (a native Iceberg struct / nested column), **SKIP this section** — use dot notation directly: `col.field` (see the native-ROW dot-access LEADING CANONICAL immediately above). This `CAST(json_parse(...) AS ROW(...))` path is ONLY for promoting a JSON-STRING (`VARCHAR`) column INTO a typed ROW. If the column is already a ROW, `json_parse` will error (its input must be VARCHAR) and the CAST is unnecessary work.

**The fact in one sentence.** The INVERSE of `CAST(map/array/row AS JSON)` is `CAST(<JSON value> AS ROW(...) | MAP(VARCHAR, T) | ARRAY(T))` — Trino 467 parses a JSON value directly into a typed structure with a single CAST, no UDFs required. When the source is a `VARCHAR` column holding a JSON string (the common case), wrap in `json_parse(...)` first to promote it to the `JSON` type, then CAST.

**The signature (verified at [trino.io/docs/current/functions/json.html](https://trino.io/docs/current/functions/json.html)):**
- **JSON → ROW**: *"When casting from `JSON` to `ROW`, both JSON array and JSON object are supported"*. A JSON object's keys are matched to ROW field names (case-insensitive); a JSON array's positions are matched to ROW fields in declaration order.
- **JSON → MAP**: same key restriction as the forward direction — the MAP's key type **must be `VARCHAR`**, and value types must be supported scalars (or `JSON` for mixed values).
- **JSON → ARRAY**: element type must be one of the supported scalars, or `JSON` for arrays with mixed element types.

**Worked examples (all valid Trino 467):**

```sql
-- 1. VARCHAR JSON string -> typed ROW (the most common dbt promotion pattern).
SELECT CAST(json_parse(payload) AS ROW(user_id BIGINT, email VARCHAR, active BOOLEAN)) AS user_record
FROM iceberg.analytics.events;
-- For payload = '{"user_id":42,"email":"a@b.com","active":true}',
-- user_record is the typed ROW; access via dot notation: user_record.user_id, user_record.email.

-- 2. VARCHAR JSON string -> MAP(VARCHAR, VARCHAR) (every value coerced to VARCHAR — the safe default when value types vary).
SELECT CAST(json_parse(properties_raw) AS MAP(VARCHAR, VARCHAR)) AS properties_map
FROM iceberg.analytics.events;

-- 3. VARCHAR JSON string -> ARRAY(VARCHAR).
SELECT CAST(json_parse(tags_raw) AS ARRAY(VARCHAR)) AS tags
FROM iceberg.analytics.events;

-- 4. NESTED — extract a JSON sub-path, then cast that subtree into a typed ROW.
SELECT CAST(json_extract(payload, '$.user') AS ROW(id BIGINT, email VARCHAR)) AS user_obj
FROM iceberg.analytics.events;
-- json_extract returns JSON (not VARCHAR), so no json_parse wrapper is needed here.

-- 5. MIXED value types -> cast values as JSON (the partial-cast escape hatch).
SELECT CAST(json_parse(payload) AS MAP(VARCHAR, JSON)) AS mixed_map
FROM iceberg.analytics.events;
-- Use when the JSON object's values are heterogeneous (some strings, some numbers, some objects).
```

**DO-NOT-WRITE — banned forms for the JSON → typed direction:**

| Anti-pattern | Why wrong | Fix |
|---|---|---|
| `CAST(payload AS ROW(...))` when `payload` is `VARCHAR` | Trino does NOT auto-coerce VARCHAR → JSON for the CAST-to-ROW path. Parse error or unexpected behavior. | `CAST(json_parse(payload) AS ROW(...))` — explicit `json_parse` first. |
| `CAST(json_col AS MAP(BIGINT, VARCHAR))` (non-VARCHAR keys) | Per docs, JSON → MAP **requires `VARCHAR` keys** (same restriction as the forward direction). | Use `MAP(VARCHAR, T)`. If you genuinely need typed keys, cast keys after extraction: `transform_keys(m, (k, v) -> CAST(k AS BIGINT))`. |
| Extracting field-by-field with `json_extract_scalar(payload, '$.user_id')` + `... '$.email'` + `... '$.active'` when the WHOLE struct shape is stable | Verbose, slow (re-parses the JSON N times for N fields), error-prone (one missed CAST and you get string-comparison bugs). | `CAST(json_parse(payload) AS ROW(user_id BIGINT, email VARCHAR, active BOOLEAN))` — one parse, one CAST, all fields typed in one pass. |
| Writing a Trino UDF or a Spark UDF to deserialize JSON because "Trino has no JSON → struct cast" | **FALSE.** `CAST(JSON AS ROW(...))` is documented and ships in Trino 467. UDFs are unnecessary. | The CAST examples above. |
| `CAST(json_parse(s) AS ARRAY(BIGINT))` when the JSON array contains mixed types (some numbers, some objects) | The cast errors if any element fails the target type. | `CAST(json_parse(s) AS ARRAY(JSON))` first (partial-cast escape hatch); then handle per-element CAST inside `transform(...)`. |

**Cross-references.** The forward direction (`CAST(map/array/row AS JSON)`) is the LEADING CANONICAL immediately above. The Trino JSON extraction family (`json_extract` / `json_extract_scalar` / `json_array_length` / `json_parse` / `json_format`) is at [resource 13 § Trino JSON extraction family LEADING CANONICAL](13-postgres-to-iceberg-ingestion.md) — use those when you only need ONE leaf value; reach for `CAST(... AS ROW)` when you want the WHOLE struct shape typed in one CAST. For accessing fields on the resulting ROW value, use dot notation: `user_record.user_id`, `user_record.email`. For the Spark-side equivalent (`from_json` + `schema_of_json` for full struct promotion), see [resource 13 § Spark JSONB shortcut](13-postgres-to-iceberg-ingestion.md).

#### Trino string aggregation — NO `string_agg`, NO `group_concat`

> **Keyword anchors:** Trino string_agg does not exist, string_agg not registered, group_concat Trino, concatenate rows into one string, listagg vs array_join, Trino string concatenation aggregate.

If you're about to write `string_agg(...)` (PostgreSQL / SQL Server) or `group_concat(...)` (MySQL) to assemble a JSON-shaped string or concatenate row values into a delimited list, **STOP** — neither function exists in Trino 467. Per [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html), Trino's string-aggregation surface is exactly:

- **`listagg(expr, sep) WITHIN GROUP (ORDER BY ...)`** — ANSI ordered-set aggregate. **AGGREGATE-ONLY** (no `OVER (...)` window form per the locked [resource 27 § 7A.2A canonical](27-oracle-plsql-to-dbt-trino.md)). Requires `GROUP BY` in the outer query; produces ONE row per group.
- **`array_join(array_agg(expr [ORDER BY ...]), sep)`** — the array-based equivalent; works when you need a window form via `array_agg(...) OVER (...)` over a pre-sorted CTE.

```sql
-- CORRECT — concatenate product names per order_id (one row per order).
SELECT order_id,
       listagg(product_name, ', ') WITHIN GROUP (ORDER BY product_name) AS products
FROM iceberg.analytics.order_lines
GROUP BY order_id;

-- DO NOT WRITE — string_agg is PostgreSQL, not Trino:
--   SELECT order_id, string_agg(product_name, ', ') FROM ...
-- Fails with: "Function 'string_agg' not registered".

-- DO NOT WRITE — group_concat is MySQL, not Trino:
--   SELECT order_id, group_concat(product_name SEPARATOR ', ') FROM ...
-- Fails with: "Function 'group_concat' not registered" (and the MySQL `SEPARATOR` keyword is also not parsed).
```

For the full Oracle WINDOWED `LISTAGG(...) OVER (PARTITION BY ...)` migration story (the `array_join(array_agg(...) OVER (PARTITION BY k), sep)` rewrite with the pre-sort CTE), see [resource 27 § 7A.2A — LEADING CANONICAL — Oracle WINDOWED LISTAGG → Trino](27-oracle-plsql-to-dbt-trino.md). For the cross-dialect anti-pattern row, see [resource 23 § anti-patterns table — `STRING_AGG`](23-sql-best-practices-olap.md).

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

> **Disambiguator — wrong tool for ROW columns.** If your column is a native `ROW(...)` / struct (named fields), use **dot notation** `col.field` — `json_extract_scalar` is for **JSON-string (`VARCHAR`/`JSON`) columns only** (it needs JSON-text input; a typed ROW will type-error). See the **native-ROW dot-access LEADING CANONICAL** in the ROW/struct section above.

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
> **ADD COLUMN is always nullable.** Iceberg's `ALTER TABLE ... ADD COLUMN col TYPE` adds the column as nullable; there is no way to ADD a NOT NULL column directly (the constraint cannot apply to historical rows that will read NULL).

#### SCHEMA-EVOLUTION COLUMN-TYPE-CHANGE GUARDRAIL — Trino 467 CAN widen Iceberg column types natively; Iceberg-Spark uses `ALTER COLUMN ... TYPE`, NOT `MODIFY COLUMN`

> **Read this BEFORE answering ANY question about "widen INT to BIGINT", "change column type", "promote float to double", "widen decimal precision", or "do I need Spark to change a column type" on an Iceberg table.** This guardrail exists because the iter433 Q4 confident-inaccuracy claimed **(A)** "Trino 467 does NOT expose column-type modification, must use Spark" — that is **WRONG** — and **(B)** used Spark syntax `ALTER TABLE t MODIFY COLUMN col BIGINT` — that is **WRONG** (`MODIFY COLUMN` is MySQL/Hive, not Iceberg).
>
> **Q-PATTERN matcher (top-of-section):** "How do I widen INTEGER to BIGINT in Iceberg?" / "How do I promote REAL to DOUBLE on an Iceberg column?" / "What's the SQL to widen decimal precision?" / "Can I change a column type in Trino, or do I need Spark?" — **answer with the two-engine syntax table below. Both Trino AND Spark support native Iceberg type widening. They use DIFFERENT keywords. NEVER `MODIFY COLUMN`.**
>
> **Fact 1 — Trino 467 (the production version on this stack) DOES support changing an Iceberg column's type natively.** Per [trino.io/docs/current/sql/alter-table.html](https://trino.io/docs/current/sql/alter-table.html), Trino's `ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE new_type` is the supported form. This was added in **Trino 406** (released **25 January 2023**, per [trino.io/docs/current/release/release-406.html](https://trino.io/docs/current/release/release-406.html) — release-note entry: "Add support for changing column types" for the Iceberg connector, [trinodb/trino #15515](https://github.com/trinodb/trino/pull/15515) / [#15651](https://github.com/trinodb/trino/pull/15651)). Trino 467 inherited this capability — you do NOT need to spin up Spark for safe widening.
>
> **Fact 2 — Iceberg-Spark uses `ALTER COLUMN ... TYPE`, NOT `MODIFY COLUMN`.** Per [iceberg.apache.org/docs/latest/spark-ddl/](https://iceberg.apache.org/docs/latest/spark-ddl/) the canonical Iceberg-Spark column-type-change syntax is `ALTER TABLE t ALTER COLUMN c TYPE new_type`. The Iceberg docs use exactly: `ALTER TABLE prod.db.sample ALTER COLUMN measurement TYPE double`. **`MODIFY COLUMN` is MySQL/Hive-style DDL — it is NOT Iceberg-Spark.** Pasting `ALTER TABLE t MODIFY COLUMN col BIGINT` into spark-sql against an Iceberg table produces a parser error.
>
> **Two-engine syntax table — memorize this:**
>
> | Engine | Exact column-type-change syntax | Note |
> |---|---|---|
> | **Trino 467** (Iceberg connector — `iceberg` catalog) | `ALTER TABLE iceberg.analytics.events ALTER COLUMN row_count SET DATA TYPE bigint;` | SQL-standard `SET DATA TYPE`. Supported since Trino 406 (Jan 2023). Documented at [trino.io/docs/current/sql/alter-table.html](https://trino.io/docs/current/sql/alter-table.html). |
> | **Spark 3.5 + Iceberg 1.5.2** (spark-sql / Spark Thrift / pyspark.sql) | `ALTER TABLE iceberg.analytics.events ALTER COLUMN row_count TYPE bigint;` | The Iceberg-canonical form. Documented at [iceberg.apache.org/docs/latest/spark-ddl/](https://iceberg.apache.org/docs/latest/spark-ddl/). Spark also accepts Hive-compatible `CHANGE COLUMN row_count row_count BIGINT` (column name repeated twice) — `ALTER COLUMN TYPE` is the canonical Iceberg-Spark form. |
>
> **Mnemonic:** Trino has the SQL word `SET DATA` between `COLUMN` and the type. Spark has only the SQL word `TYPE` between `COLUMN` and the type. Neither uses `MODIFY`.
>
> **Safe widenings (metadata-only, no Parquet rewrite — per [iceberg.apache.org/docs/latest/evolution/](https://iceberg.apache.org/docs/latest/evolution/) and the [Iceberg spec, schema evolution / type promotion](https://iceberg.apache.org/spec/#schema-evolution)):**
>
> | From | To | Notes |
> |---|---|---|
> | `int` (32-bit) | `long` (Iceberg `long` = Trino `bigint` = Spark `bigint`) | Pure metadata update. Existing 32-bit Parquet INT files transparently read as 64-bit at query time. |
> | `float` (32-bit, Trino/Spark `real`) | `double` (64-bit) | Pure metadata update. Existing 32-bit FLOAT Parquet files transparently read as 64-bit DOUBLE at query time. |
> | `decimal(P, S)` | `decimal(P', S)` where `P' > P`, **scale unchanged** | Pure metadata update. Scale (digits after decimal point) MUST stay the same. |
>
> **Unsafe / NOT permitted by Iceberg spec (will be rejected, OR require a multi-step add-column + backfill + drop-old migration):**
>
> | Attempt | Why it's rejected |
> |---|---|
> | `bigint` → `int` (narrowing) | Would lose data on values > 2^31. Iceberg refuses. |
> | `double` → `float` (narrowing) | Would lose precision. Iceberg refuses. |
> | `decimal(10, 4)` → `decimal(10, 2)` (scale narrowing) | Scale change rejected — Iceberg only allows precision widening at the **same** scale. |
> | `decimal(10, 2)` → `decimal(12, 4)` (scale change — even if precision also widens) | Scale must be identical. Different scales mean different stored byte interpretations. |
> | `int` → `varchar`, `bigint` → `date`, `timestamp` → `varchar`, etc. (cross-family) | Type-family change — not on the safe-promotion list. Multi-step migration required. |
> | `date` → `timestamp` | NOT on the Iceberg safe-promotion list. Multi-step migration required. |
> | `timestamp(3)` → `timestamp(6)` (precision change) | Iceberg stores timestamps at microsecond precision by default — precision is a query-engine concern, not an Iceberg storage knob. |
>
> **Worked example pair — widen `row_count INTEGER` to `BIGINT` on an Iceberg table:**
>
> From a Trino session (Trino CLI, Trino query editor, Trino JDBC client — the engineer's default on this stack):
>
> ```sql
> ALTER TABLE iceberg.analytics.events ALTER COLUMN row_count SET DATA TYPE bigint;
> ```
>
> From a Spark session (spark-sql, Spark Thrift, pyspark.sql — used for Spark Structured Streaming consumers or bulk Spark ingestion jobs that own the table):
>
> ```sql
> ALTER TABLE iceberg.analytics.events ALTER COLUMN row_count TYPE bigint;
> ```
>
> **Both forms emit the IDENTICAL metadata-only schema update to the Iceberg catalog** (a new column-type assertion against the existing Iceberg field ID; zero Parquet files are rewritten). The choice between them is purely **which client session you have open**. If you have a Trino session, use Trino. If you have a Spark session (because your ingestion or maintenance job already runs there), use Spark.
>
> **DO-NOT-WRITE (the iter433 Q4 inaccuracies — never reproduce):**
>
> 1. **"Trino 467 does NOT expose column-type modification, must use Spark."** — FALSE. Trino's Iceberg connector has supported `ALTER COLUMN ... SET DATA TYPE` since Trino 406 (January 2023, three years before production Trino 467). An engineer following this advice would needlessly spin up Spark for a Trino-native operation.
> 2. **"Trino can't change column types in Iceberg."** — FALSE (same as #1, paraphrase).
> 3. **"To widen a column on Iceberg you need to use Spark."** — FALSE (same as #1, paraphrase).
> 4. **`ALTER TABLE t MODIFY COLUMN col BIGINT`** — FALSE syntax for Iceberg on BOTH engines. `MODIFY COLUMN` is MySQL/Hive DDL. Iceberg-Spark uses `ALTER COLUMN ... TYPE`; Trino-Iceberg uses `ALTER COLUMN ... SET DATA TYPE`. Pasting `MODIFY COLUMN` into either engine against an Iceberg table produces a parser error.
> 5. **"Spark's syntax is `ALTER TABLE t MODIFY COLUMN col BIGINT`."** — FALSE. The correct Spark/Iceberg form is `ALTER TABLE t ALTER COLUMN col TYPE bigint`.
> 6. **"Use `CHANGE COLUMN col col BIGINT` in Trino."** — FALSE. `CHANGE COLUMN` is Hive-compatible and works in Spark but does NOT parse in Trino — Trino rejects it as `mismatched input 'CHANGE'`.
>
> **Sources verified:**
> - [trino.io/docs/current/sql/alter-table.html](https://trino.io/docs/current/sql/alter-table.html) — `ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE new_type` is the supported Trino form; documented example `ALTER TABLE users ALTER COLUMN id SET DATA TYPE bigint`.
> - [trino.io/docs/current/release/release-406.html](https://trino.io/docs/current/release/release-406.html) — release-note entry confirming the Iceberg connector gained `SET DATA TYPE` support in Trino 406 (Jan 2023).
> - [iceberg.apache.org/docs/latest/spark-ddl/](https://iceberg.apache.org/docs/latest/spark-ddl/) — Iceberg-Spark canonical syntax `ALTER TABLE t ALTER COLUMN c TYPE new_type`.
> - [iceberg.apache.org/docs/latest/evolution/](https://iceberg.apache.org/docs/latest/evolution/) — defines the safe widening set (int→long, float→double, decimal precision-widen-same-scale).
> - [iceberg.apache.org/spec/#schema-evolution](https://iceberg.apache.org/spec/#schema-evolution) — the spec listing of safe type promotions.

#### SCHEMA-EVOLUTION CONSTRAINT-TIGHTENING GUARDRAIL — you CANNOT tighten an existing nullable Iceberg column to NOT NULL via `ALTER COLUMN ... SET NOT NULL` on Trino 467

> **Read this BEFORE answering any question about "tightening" / "adding NOT NULL" / "enforcing not-null" on an existing Iceberg column on Trino 467.** This guardrail exists because the iter429 Q4 confident-inaccuracy recommended `ALTER COLUMN ... SET NOT NULL` as the final step of the nullable → backfill → tighten pattern — and that operation does NOT exist in Trino.
>
> **Q-PATTERN matcher (top-of-section):** "How do I tighten an existing column to NOT NULL?" / "How do I add a NOT NULL column to an Iceberg table after backfilling?" / "Can I run `ALTER COLUMN ... SET NOT NULL`?" — **answer with the four supported ops list below + the CTAS-swap / dbt-test workarounds. NEVER recommend `ALTER COLUMN ... SET NOT NULL` — it is not Trino SQL.**
>
> **Per [trino.io/docs/current/sql/alter-table.html](https://trino.io/docs/current/sql/alter-table.html), the COMPLETE list of `ALTER TABLE ... ALTER COLUMN` operations supported on Trino 467 is:**
>
> | Operation | Syntax | Direction |
> |---|---|---|
> | **SET DEFAULT** | `ALTER TABLE name ALTER COLUMN col SET DEFAULT expr` | adds/changes a default value |
> | **DROP DEFAULT** | `ALTER TABLE name ALTER COLUMN col DROP DEFAULT` | removes a default value |
> | **SET DATA TYPE** | `ALTER TABLE name ALTER COLUMN col SET DATA TYPE new_type` | changes column type (Iceberg widening only — int→long, float→double, decimal precision-widen) |
> | **DROP NOT NULL** | `ALTER TABLE name ALTER COLUMN col DROP NOT NULL` | LOOSENS NOT NULL → nullable (one-way; you cannot un-drop it via ALTER) |
>
> **There is NO `ALTER COLUMN ... SET NOT NULL` operation in Trino 467. You cannot tighten a nullable column to NOT NULL with an ALTER statement.** Per [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html), the Iceberg connector states: *"The `NOT NULL` constraint can be set on the columns, while creating tables by using the CREATE TABLE syntax"* — i.e., NOT NULL is settable **only at CREATE TABLE time**, never via ALTER.
>
> **DO-NOT-WRITE:** Never write the sentence `ALTER TABLE <name> ALTER COLUMN <col> SET NOT NULL` (or any paraphrase: "set it to NOT NULL", "tighten via ALTER COLUMN to NOT NULL", "run SET NOT NULL on the column", "make the column NOT NULL with ALTER") — **that operation does not exist in Trino 467.** An engineer who follows this advice hits a SQL parser/semantic error.
>
> **Two correct workarounds for the "nullable + backfill + tighten" pattern on this stack:**
>
> ---
>
> ### CTAS-NOT-NULL-INFERENCE GUARDRAIL — `CREATE TABLE AS SELECT` does NOT preserve, infer, or imply NOT NULL constraints
>
> **Read this BEFORE writing the CTAS-swap workaround in (a) below.** This guardrail exists because the iter430 Q1 confident-inaccuracy described the CTAS-swap as a plain `CREATE TABLE new_table AS SELECT * FROM old_table WHERE col IS NOT NULL` and CLAIMED the new table would have the column as NOT NULL — **that claim is WRONG.**
>
> **The fact you must memorize:** Trino's `CREATE TABLE AS SELECT` (CTAS) carries column **TYPES** only — it does **NOT** preserve, infer, or imply NOT NULL constraints from either the source table's schema OR from a `WHERE col IS NOT NULL` filter in the SELECT. The new table's columns are **nullable by default** no matter what the SELECT looks like.
>
> Per [trino.io/docs/current/sql/create-table-as.html](https://trino.io/docs/current/sql/create-table-as.html) and [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html): NOT NULL is settable **only** through an EXPLICIT column-list in `CREATE TABLE name (col TYPE NOT NULL, ...)`. The CTAS form `CREATE TABLE name AS SELECT ...` does not have a column-list syntax position where NOT NULL can be declared, and the SELECT clause does not carry the constraint over from source.
>
> **THE TWO-STEP RULE — to produce a NOT NULL column on the new table, you MUST use:**
>
> **Step 1.** `CREATE TABLE <new> (col1 TYPE NOT NULL, col2 TYPE, ...)` — **EXPLICIT full column-list** with `NOT NULL` declared on the tightened column(s). Note: this is `CREATE TABLE` (not `CREATE TABLE AS`).
>
> **Step 2.** `INSERT INTO <new> SELECT col1, col2, ... FROM <old>` — separate INSERT statement that copies rows. If any row has NULL in a NOT NULL column, this INSERT fails fast (the NOT NULL on the new table is the validation gate).
>
> **DO-NOT-WRITE (the iter430 Q1 inaccuracy that must not be repeated):**
>
> 1. **"`CREATE TABLE accounts_new AS SELECT * FROM accounts WHERE tier IS NOT NULL` will have `tier` as NOT NULL on the new table"** — FALSE. The new table's `tier` column is **nullable**, because CTAS does not carry over or infer the NOT NULL constraint. A later `INSERT INTO accounts_new ... VALUES (..., NULL, ...)` will succeed and put NULL into `tier`. The `WHERE tier IS NOT NULL` filter only constrains which rows are copied during CTAS — it does **not** apply NOT NULL to the destination column.
> 2. **"`CREATE TABLE AS SELECT` will have <col> as NOT NULL"** — FALSE in all forms. CTAS infers column TYPES only.
> 3. **"`CREATE TABLE AS SELECT ... WHERE col IS NOT NULL` gives NOT NULL on the new table"** — FALSE. The WHERE filter and the NOT NULL constraint are unrelated mechanisms.
> 4. **"plain CTAS preserves NOT NULL from the source table's schema"** — FALSE. CTAS does not preserve constraints; it creates a new table whose columns are nullable unless an explicit column-list with NOT NULL is supplied (and CTAS has no syntax position for that — you must use the 2-step pattern).
>
> **Worked example — the iter430 Q1 BEFORE / AFTER fix:**
>
> **BEFORE (the iter430 INACCURATE pattern — do NOT do this if you want NOT NULL):**
>
> ```sql
> -- WRONG: this creates accounts_new with tier as NULLABLE, despite the WHERE filter.
> CREATE TABLE iceberg.analytics.accounts_new AS
> SELECT * FROM iceberg.analytics.accounts
> WHERE tier IS NOT NULL;
> --                                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
> -- The WHERE filter restricts WHICH ROWS get copied — it does NOT apply a NOT NULL
> -- constraint to the destination table's `tier` column. After this runs:
> --   DESCRIBE iceberg.analytics.accounts_new;
> -- will show `tier VARCHAR` (no NOT NULL). A subsequent
> --   INSERT INTO iceberg.analytics.accounts_new VALUES (..., NULL, ...);
> -- SUCCEEDS, defeating the entire point of the swap.
> ```
>
> **AFTER (the CORRECT EXPLICIT 2-step pattern — this is the only form that actually produces NOT NULL):**
>
> ```sql
> -- Step 1: backfill the live table first so no row has a NULL tier.
> UPDATE iceberg.analytics.accounts SET tier = 'free' WHERE tier IS NULL;
> SELECT COUNT(*) FROM iceberg.analytics.accounts WHERE tier IS NULL;  -- must return 0
>
> -- Step 2: CREATE TABLE with an EXPLICIT FULL COLUMN-LIST (NOT CREATE TABLE AS SELECT).
> --         NOT NULL is declared in the column definition — the only place it can be.
> CREATE TABLE iceberg.analytics.accounts_new (
>     account_id BIGINT NOT NULL,
>     name       VARCHAR NOT NULL,
>     tier       VARCHAR NOT NULL,   -- the tightened column
>     created_at TIMESTAMP(6) WITH TIME ZONE NOT NULL,
>     plan_json  JSON
> )
> WITH (partitioning = ARRAY['bucket(account_id, 16)'], format = 'PARQUET');
>
> -- Step 3: copy rows via separate INSERT. If any row has NULL in a NOT NULL column,
> -- this INSERT fails fast — the NOT NULL on the destination is the validation gate.
> INSERT INTO iceberg.analytics.accounts_new
> SELECT account_id, name, tier, created_at, plan_json FROM iceberg.analytics.accounts;
>
> -- Step 4: atomic swap (coordinate with downstream readers; brief window).
> DROP TABLE iceberg.analytics.accounts;
> ALTER TABLE iceberg.analytics.accounts_new RENAME TO iceberg.analytics.accounts;
>
> -- VERIFY the new table has NOT NULL by inspecting the schema:
> SHOW CREATE TABLE iceberg.analytics.accounts;
> -- The output should include `tier VARCHAR NOT NULL` on the column definition line.
> -- Attempting INSERT VALUES (..., NULL, ...) into the swapped table will now fail.
> ```
>
> **Sources:**
> - [trino.io/docs/current/sql/create-table-as.html](https://trino.io/docs/current/sql/create-table-as.html) — CTAS syntax; no column-list / NOT NULL syntax position.
> - [trino.io/docs/current/sql/create-table.html](https://trino.io/docs/current/sql/create-table.html) — explicit `CREATE TABLE name (col TYPE NOT NULL, ...)` form (Step 2 above).
> - [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) — *"The `NOT NULL` constraint can be set on the columns, while creating tables by using the CREATE TABLE syntax"* (CREATE TABLE column-list only; not CTAS, not ALTER).
>
> **Q-pattern matcher addendum:** if the question is "how do I CTAS-swap to apply NOT NULL", the answer is the EXPLICIT 2-step **CREATE TABLE column-list + INSERT** pattern above — NEVER plain CTAS. If you wrote `CREATE TABLE <new> AS SELECT ... WHERE col IS NOT NULL` and called the result "NOT NULL", you wrote the iter430 inaccuracy — go back and rewrite using the 2-step form.
>
> ---
>
> **(a) CTAS-swap (heavy — full table rewrite; choose only when you need a hard storage-level constraint):**
>
> The CTAS-swap is a misnomer kept for historical familiarity — **the swap itself uses an EXPLICIT `CREATE TABLE` (with full column-list + `NOT NULL`) followed by a separate `INSERT INTO ... SELECT`, NOT a plain `CREATE TABLE AS SELECT`.** See the CTAS-NOT-NULL-INFERENCE guardrail above. The code block below uses the correct 2-step form:
>
> ```sql
> -- Step 1: backfill the nullable column on the live table (Trino UPDATE or MERGE).
> UPDATE iceberg.analytics.events
> SET tenant_id = 'unknown'
> WHERE tenant_id IS NULL;
>
> -- Verify zero NULLs before the rewrite:
> SELECT COUNT(*) FROM iceberg.analytics.events WHERE tenant_id IS NULL;
> -- must return 0
>
> -- Step 2: CREATE a NEW table with NOT NULL in the column definition (at CREATE TABLE time — the ONLY place NOT NULL can be set on Iceberg).
> CREATE TABLE iceberg.analytics.events_new (
>     event_id BIGINT NOT NULL,
>     user_id  BIGINT NOT NULL,
>     tenant_id VARCHAR NOT NULL,   -- the tightened column
>     event_ts TIMESTAMP(6) WITH TIME ZONE NOT NULL,
>     payload  JSON
> )
> WITH (partitioning = ARRAY['day(event_ts)'], format = 'PARQUET');
>
> -- Step 3: copy the backfilled rows in (fails fast if any NULL slipped through —
> -- the NOT NULL constraint on events_new is the validation gate).
> INSERT INTO iceberg.analytics.events_new
> SELECT event_id, user_id, tenant_id, event_ts, payload FROM iceberg.analytics.events;
>
> -- Step 4: atomic rename swap (drop old, rename new) — coordinate with downstream readers
> -- since this is a brief window where the table is missing/renamed.
> DROP TABLE iceberg.analytics.events;
> ALTER TABLE iceberg.analytics.events_new RENAME TO iceberg.analytics.events;
> ```
>
> Trade-off: this rewrites the entire table (every Parquet file is re-written), throws away the old snapshot/time-travel history, and requires a coordinated downstream cutover. Only do this when the storage-level NOT NULL constraint is genuinely required (regulatory, contract-with-downstream-consumer).
>
> **(b) RECOMMENDED — enforce via a dbt `not_null` test at the model layer (cheap, no rewrite, fails the run if a NULL appears):**
>
> ```yaml
> # models/schema.yml (in your dbt project)
> version: 2
>
> models:
>   - name: events
>     columns:
>       - name: tenant_id
>         tests:
>           - not_null    # built-in dbt test — fails the dbt run if any row has NULL tenant_id
>       - name: event_id
>         tests:
>           - not_null
>           - unique
> ```
>
> Then `dbt test --select events` compiles the test into a SELECT that returns the **failing rows** — for `not_null` the shape is `SELECT * FROM events WHERE tenant_id IS NULL`. **The test passes if zero rows are returned; it fails if any row comes back.** dbt evaluates pass/fail (and the `error_if` / `warn_if` thresholds, see resource 27 § 6.7A) against the **count of failing rows** in that result set — NOT a `SELECT 1 ... LIMIT 1` existence check. So a failing build (and your CI / Airflow / orchestrator) is triggered the moment any row has NULL. This gives you the **operational guarantee** of NOT NULL (any future writer that produces NULL is caught and the pipeline fails) without rewriting the table and without losing snapshot history. **This is the recommended pattern for this stack** — the column stays nullable in the Iceberg schema, but downstream contracts are enforced by dbt tests run on every refresh.
>
> The conceptual intent of "tighten the column after backfill" is preserved — the difference is **where** the enforcement lives: at the Iceberg schema level (option (a), requires a rewrite) vs at the dbt model-test level (option (b), no rewrite, run on every model build).
>
> **Sources:**
> - [trino.io/docs/current/sql/alter-table.html](https://trino.io/docs/current/sql/alter-table.html) — verbatim list of supported ALTER COLUMN operations (SET DEFAULT, DROP DEFAULT, SET DATA TYPE, DROP NOT NULL — no SET NOT NULL).
> - [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) — *"The `NOT NULL` constraint can be set on the columns, while creating tables by using the CREATE TABLE syntax"* (i.e., CREATE TABLE only — not via ALTER).
> - [docs.getdbt.com/reference/resource-properties/data-tests](https://docs.getdbt.com/reference/resource-properties/data-tests) — built-in `not_null` dbt test.
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
