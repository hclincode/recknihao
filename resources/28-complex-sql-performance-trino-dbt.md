# Improving Complex SQL Performance on Trino with dbt

> Your dbt models — many of them just-migrated from Oracle PL/SQL ([resource 27](27-oracle-plsql-to-dbt-trino.md)) — run, but slowly. Some take 20 minutes to process what Oracle did in 2. This guide is the practical performance-tuning playbook for complex SQL on Trino 467 + Iceberg 1.5.2 driven by dbt, organized around the patterns that go wrong most often when SQL is translated from a row-engine to a parallel query engine.
>
> **Production stack assumed**: Trino 467 OSS, Iceberg 1.5.2 with Hive Metastore, MinIO via S3, on-prem Kubernetes, dbt-trino adapter.

---

## TL;DR (read these 8 sentences first)

1. **A migrated SQL query that "works" is not the same as a fast SQL query.** Naive Oracle->Trino translations almost always reproduce three Trino-hostile patterns: correlated subqueries in the SELECT list, deep CTE chains that re-evaluate, and function-wrapped partition-column predicates that defeat partition pruning.
2. **Trino CTEs are INLINED, not materialized.** `WITH x AS (SELECT ...) SELECT * FROM x JOIN x ON ...` evaluates `x` TWICE. There is NO optimization fence, NO caching of the CTE result. To materialize once, write a dbt intermediate model (`materialized='table'` or `'incremental'`) and `ref()` it.
3. **Trino has NO query result cache** (OSS Trino 467). Re-running the exact same SQL re-executes from scratch. The "cache" your dashboard appears to have is the underlying Iceberg storage table (already-aggregated rollups) — that's what dbt incremental models, materialized views ([resource 25](25-trino-materialized-views-iceberg.md)), and dashboard-side caching give you.
4. **Predicate pushdown to Iceberg is the single biggest performance lever**, and the single easiest one to accidentally break — by casting the partition column (`WHERE CAST(event_date AS varchar) = ...`), by wrapping it in arithmetic (`WHERE event_date + INTERVAL '1' DAY = ...`), or by comparing it across types. `date_trunc('day', event_ts) = DATE '...'` is **fragile, not absolutely broken** on Trino 400+: the `SimplifyDateTrunc` optimizer rule simplifies this into a naked range for identity / `day()` partition transforms (verified via [trino.io blog 2023/04/11](https://trino.io/blog/2023/04/11/date-predicates.html) + [PR #14011](https://github.com/trinodb/trino/pull/14011)), but it does NOT cover `bucket()` / `hour()` transforms, function compositions, or non-literal RHS. The defensive recommendation is still to keep partition columns naked on one side and write the explicit range form (`event_ts >= TIMESTAMP '...' AND event_ts < TIMESTAMP '...'`) — and always verify with `EXPLAIN` by inspecting the `TableScan` `constraint=` annotation.
5. **Correlated subqueries are the migration-shaped slowness champion.** Trino tries to decorrelate them into joins; when it succeeds, the EXPLAIN shows `SemiJoin` / `Join` / `Project`. When decorrelation fails, EXPLAIN shows `CorrelatedJoin` — an O(N×M) nested-loop in worker memory. **Always EXPLAIN your migrated queries and search for `CorrelatedJoin`.**
6. **Joins**: tiny dim + huge fact -> BROADCAST (default for builds under ~100MB); large + large -> PARTITIONED; cross-source -> rely on **dynamic filtering** (Trino sends build-side keys to probe side at runtime). Run `ANALYZE <table>` (Trino syntax: bare `ANALYZE`, NO `TABLE` keyword) so the optimizer has stats to pick correctly ([resource 24](24-trino-cbo-analyze.md)).
7. **dbt-specific levers**: choose `materialized='incremental'` to skip recomputing unchanged rows; partition the dbt-built Iceberg table with `properties={'partitioned_by': "ARRAY[...]"}` (dbt-trino's documented key for incremental Iceberg models — see [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs)); cluster files with `sorted_by` + run `ALTER TABLE ... EXECUTE optimize` ([resource 17](17-iceberg-table-maintenance.md)).
8. **EXPLAIN ANALYZE is the source of truth**, not folklore. `physicalInputDataSize` tells you how many bytes were read from MinIO; `CorrelatedJoin` vs `SemiJoin` tells you whether decorrelation fired; `dynamicFilterSplitsProcessed` tells you whether dynamic filtering worked; partition-prune constraint on `TableScan` tells you whether you scanned the whole table or one partition.

---

## LEADING CANONICAL WORKED EXAMPLE — dbt-trino incremental model on Iceberg (the load-bearing recipe)

> **Why this section is FIRST (above the myths table).** Iter452 broke the citation-hygiene streak on two dbt-trino incremental syntax bugs: (1) using `{% if execute %}` instead of `{% if is_incremental() %}` as the delta-filter guard, and (2) using `properties={'partitioning': ...}` instead of `properties={'partitioned_by': ...}` inside the dbt config. Both were doc-verifiable mistakes. This section is the single source of truth for the dbt-trino + Iceberg incremental recipe on Trino 467 — every other dbt-incremental block in this resource and in [resource 27](27-oracle-plsql-to-dbt-trino.md) follows this shape. **When in doubt about dbt-incremental syntax on Trino 467 + Iceberg 1.5.2, copy this block.**

### The canonical full block — append/merge incremental on Iceberg

```jinja
-- models/fct_events.sql
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='event_id',
    on_schema_change='append_new_columns',
    properties={
      'format': 'PARQUET',
      'partitioned_by': "ARRAY['day(occurred_at)']",
      'sorted_by': "ARRAY['tenant_id']",
      'format_version': 2
    }
) }}

SELECT
  event_id,
  tenant_id,
  occurred_at,
  event_type,
  payload
FROM {{ ref('stg_events') }}
{% if is_incremental() %}
  WHERE occurred_at >= (SELECT COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01') FROM {{ this }})
{% endif %}
```

### The 3-day-lookback variant for late-arriving data (pair with `merge` + `unique_key` for idempotence)

```jinja
{% if is_incremental() %}
  WHERE occurred_at >= (
    SELECT date_add('day', -3, COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01'))
    FROM {{ this }}
  )
{% endif %}
```

`incremental_strategy='merge'` + `unique_key='event_id'` makes the re-processed lookback window idempotent: matched rows update in place, unmatched rows insert. Re-running the same lookback window produces no duplicates. See [resource 27 § 6.8](27-oracle-plsql-to-dbt-trino.md) for the worked example with full reasoning and [resource 28 § 7](28-complex-sql-performance-trino-dbt.md) for the late-arriving-data pattern in depth.

### Why each line of the config is the way it is

| Line | Why it's canonical | Doc pointer |
|---|---|---|
| `materialized='incremental'` | First run does a CTAS; subsequent runs apply the delta via the incremental_strategy. | [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) |
| `incremental_strategy='merge'` | Generates Trino `MERGE INTO`; safe for re-runs of overlapping windows. | [docs.getdbt.com/reference/resource-configs/trino-configs#the-merge-strategy](https://docs.getdbt.com/reference/resource-configs/trino-configs#the-merge-strategy) |
| `unique_key='event_id'` | The MERGE join-key. Required for `merge` strategy. Use a list `['tenant_id', 'event_id']` for composite keys. | Same as above. |
| `on_schema_change='append_new_columns'` | Adds new source columns automatically on incremental runs (the safe default). | [docs.getdbt.com/docs/build/incremental-models#what-if-the-columns-of-my-incremental-model-change](https://docs.getdbt.com/docs/build/incremental-models#what-if-the-columns-of-my-incremental-model-change) |
| `properties={'partitioned_by': "ARRAY['day(occurred_at)']"}` | **`partitioned_by` (snake_case) is the dbt-trino documented properties-dict key**, NOT `partitioning`. The bare-Trino DDL form `WITH (partitioning = ARRAY[...])` uses `partitioning` without an underscore — but that's the raw-SQL surface, NOT the dbt-trino properties dict. The dbt-trino adapter translates `partitioned_by` to the underlying Trino property. | [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs) — Iceberg/Hive incremental example. |
| `sorted_by` | Iceberg writer sorts rows within each file. Sharpens Parquet min/max stats for range pushdowns. | [Trino Iceberg connector — Table properties](https://trino.io/docs/current/connector/iceberg.html) |
| `format_version: 2` | Iceberg V2 (default since the connector started supporting V2). Required for `MERGE`/row-level deletes. | [iceberg.apache.org/spec/](https://iceberg.apache.org/spec/) |
| `{% if is_incremental() %}` | **The CANONICAL incremental guard.** True ONLY when: (a) the target table already exists, AND (b) this run is NOT `--full-refresh`, AND (c) the model is configured as incremental. NOT `{% if execute %}` (see DO-NOT-WRITE below). | [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) |
| `WHERE occurred_at >= (SELECT COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01') FROM {{ this }})` | The watermark-subquery delta. `COALESCE(..., <safe_default>)` lets the very first run before the table exists work (`{{ this }}` evaluates correctly because `is_incremental()` is FALSE on first run, so this whole branch is skipped — the COALESCE is belt-and-suspenders for re-runs after manual table drops). | [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) |

### DO-NOT-WRITE — load-bearing dbt-trino incremental mistakes

These are the wrong shapes a Haiku responder must NEVER suggest in a dbt-trino + Iceberg 1.5.2 + Trino 467 context. Each row pairs the WRONG form with the RIGHT one and a doc pointer.

| WRONG (will FAIL or silently misbehave) | RIGHT (canonical) | Why / doc |
|---|---|---|
| `{% if execute %}` used as the incremental delta-filter guard | `{% if is_incremental() %}` | `execute` is True during both `dbt compile` AND `dbt run` AND `dbt build` — it is **NOT** an incremental gate. It also does NOT distinguish `--full-refresh` from a normal run, so a delta filter wrapped in `{% if execute %}` would WRONGLY filter on the first build (when `{{ this }}` is empty) AND on `--full-refresh` runs (when the entire table should be rebuilt unfiltered). `is_incremental()` is the only correct guard. [docs.getdbt.com/reference/dbt-jinja-functions/execute](https://docs.getdbt.com/reference/dbt-jinja-functions/execute) + [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models). |
| `properties={'partitioning': "ARRAY['day(event_ts)']"}` (inside a dbt-trino `config(properties=...)` block) | `properties={'partitioned_by': "ARRAY['day(event_ts)']"}` | Inside the dbt-trino `properties` dict, the documented key for partitioning is **`partitioned_by`** (snake_case). The bare-Trino raw-DDL form `CREATE TABLE ... WITH (partitioning = ARRAY[...])` DOES use `partitioning` — but that's a different surface (raw Trino DDL, NOT the dbt-trino properties dict). Pasting `partitioning` into the dbt `properties` dict either silently no-ops or errors depending on the dbt-trino version. [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs). |
| Bare `partitioning=ARRAY[...]` or `partitioned_by=ARRAY[...]` as a TOP-LEVEL `config(...)` kwarg (outside `properties=...`) | Always nest inside `properties={...}`: `properties={'partitioned_by': "ARRAY[...]"}` | The dbt-trino adapter accepts table-creation properties only through the `properties` dict. There is no top-level `partition_by` / `partitioning` / `partitioned_by` kwarg on `config()` for dbt-trino as of the current adapter version. ([starburstdata/dbt-trino issue #412](https://github.com/starburstdata/dbt-trino/issues/412) requested adding a top-level `partition_by`; the documented form remains the `properties` dict.) |
| `{% if is_incremental() %} WHERE occurred_at > MAX(occurred_at) {% endif %}` (bare aggregate in WHERE) | `{% if is_incremental() %} WHERE occurred_at >= (SELECT COALESCE(MAX(occurred_at), TIMESTAMP '1970-01-01') FROM {{ this }}) {% endif %}` | Trino (and ANSI SQL) reject aggregates in a bare `WHERE` with "aggregate function not allowed in WHERE clause." The aggregate must be wrapped in a subquery. See [resource 27 § 6.8](27-oracle-plsql-to-dbt-trino.md) and [resource 28 § 7](28-complex-sql-performance-trino-dbt.md) — full canonical-pattern guardrail. |
| `WHERE id IN (SELECT id FROM {{ this }} ...) OR occurred_at >= ...` as a delta filter | `WHERE occurred_at >= (SELECT COALESCE(MAX(occurred_at), <safe_default>) FROM {{ this }})` | The `IN`-against-target form forces a re-scan of every historic row in the target on every run, defeating the entire point of `materialized='incremental'`. The canonical delta is a single subquery-wrapped `MAX(...)` comparison. |
| `incremental_strategy='append'` paired with a lookback window | `incremental_strategy='merge'` + `unique_key='...'` + lookback | `append` will INSERT duplicate rows for already-seen events in the lookback window. `merge` matches on `unique_key` and updates in place, preserving idempotence. |
| `materialized='incremental'` without ANY `is_incremental()` filter | Always pair `materialized='incremental'` with `{% if is_incremental() %} WHERE ... {% endif %}` | Without the filter, every run scans the FULL source — you get the merge-overhead cost without the scan savings. The whole point of `incremental` is the delta filter. |

### Quick-decision cheatsheet — which guard, which key

| Question | Answer |
|---|---|
| "What's the jinja guard for the incremental delta filter?" | `{% if is_incremental() %}` — NEVER `{% if execute %}`. |
| "What's the properties-dict key for Iceberg partitioning in dbt-trino?" | `partitioned_by` (snake_case) — NEVER `partitioning` inside the dbt-trino properties dict. |
| "What about bare-Trino `CREATE TABLE ... WITH (...)`?" | That's `partitioning` (without underscore) — but that's raw Trino DDL, NOT the dbt-trino properties dict. Different surface. |
| "Can I put `partition_by='day(event_ts)'` at the top level of config()?" | NO — not currently supported by dbt-trino. Always nest inside `properties={...}`. |
| "When is `is_incremental()` False?" | First build (table doesn't exist), `--full-refresh` runs, and non-incremental models. In all those cases, the WHERE is skipped — the model rebuilds from scratch. |
| "What's the safe default in the COALESCE for the watermark?" | A value strictly LESS than any real source row's watermark. For timestamps: `TIMESTAMP '1970-01-01'`. For dates: `DATE '1970-01-01'`. For numeric watermarks: `0` or `-1`. |

---

## LEADING CANONICAL WORKED EXAMPLE — "My dbt incremental model with `incremental_strategy='merge'` used to run in 5 min, now runs in 40 min — same SQL, same row volume. What changed?" (read this FIRST for "merge model getting slower" questions)

> **This is the findable canonical answer for the merge-model-degradation question. Every claim has been verified against [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) (`$files` / `$snapshots` metadata tables, `EXECUTE optimize` parameters), [iceberg.apache.org/docs/latest/spark-procedures/](https://iceberg.apache.org/docs/latest/spark-procedures/) (`rewrite_position_delete_files` is Spark-only), and Iceberg spec (`content` column codes: 0 = DATA, 1 = POSITION_DELETES, 2 = EQUALITY_DELETES). Do NOT invent Trino procedures or parameter names — paste verbatim.**
>
> **The diagnosis pattern in one sentence.** On Iceberg format-version 2 (the prod default), each `MERGE INTO` produces **one position-delete file per affected data file**. Without periodic compaction of those delete files, the planner reads more and more delete files at MERGE plan-time, and merging the build side gets slower week-over-week even when the source delta is the same size. **This is the #1 cause of "the dbt merge model used to be fast" on this stack.** Confirmed by [trinodb/trino issue #17114](https://github.com/trinodb/trino/issues/17114) ("Read Iceberg v2 table with many delete file is very slowly").
>
> ### Step 1 — confirm position-delete files are the cause (the diagnostic query)
>
> ```sql
> -- Trino 467 — count data files vs position-delete files vs equality-delete files on the slow target table.
> -- Double-quote required: "fct_events$files" because of the $ character.
> -- The content codes are per Iceberg manifest spec (verified at iceberg.apache.org/spec/):
> --   0 = DATA (the actual rows)
> --   1 = POSITION_DELETES (row-position tombstones produced by MoR DELETE/UPDATE/MERGE)
> --   2 = EQUALITY_DELETES (predicate-based tombstones, less common in Trino-written tables)
> SELECT
>   CASE content
>     WHEN 0 THEN 'DATA'
>     WHEN 1 THEN 'POSITION_DELETES'
>     WHEN 2 THEN 'EQUALITY_DELETES'
>   END                                       AS file_type,
>   COUNT(*)                                  AS file_count,
>   ROUND(SUM(file_size_in_bytes) / 1e6, 2)   AS total_mb,
>   ROUND(AVG(file_size_in_bytes) / 1024, 2)  AS avg_kb,
>   ROUND(MIN(file_size_in_bytes) / 1024, 2)  AS min_kb,
>   ROUND(MAX(file_size_in_bytes) / 1024, 2)  AS max_kb
> FROM iceberg.analytics."fct_events$files"
> GROUP BY content
> ORDER BY file_type;
> ```
>
> **Interpret the output:**
>
> | Pattern | Verdict |
> |---|---|
> | `POSITION_DELETES file_count` is > 10% of `DATA file_count` | This is the cause. Each MERGE plan-time has to load and apply ALL these delete files to the data files they reference. Slowness grows roughly linearly with delete-file count. |
> | `POSITION_DELETES avg_kb` is < 10 KB | The delete files themselves are tiny (one row per data-file-affected). Lots of tiny delete-file opens dominate the plan time. |
> | `DATA file_count` is also growing (avg data-file size shrinking) | Compounding problem: data-file fragmentation + delete-file fragmentation together. Both need fixing. |
> | `POSITION_DELETES file_count` is near zero but model still slow | NOT this cause — investigate (a) data-file fragmentation alone (re-run with `WHERE content = 0`), (b) skew in the MERGE join key, (c) snapshot-history bloat (`$snapshots` count). See §8A.2 for join-skew diagnosis. |
>
> ### Step 2 — confirm via $snapshots that MERGE traffic is consistent with the delete-file accumulation
>
> ```sql
> -- Trino 467 — count MERGE operations over the last 30 days, by day.
> -- The `operation` column on $snapshots takes values: append, replace, overwrite, delete.
> -- A dbt incremental `merge` strategy produces `operation = 'replace'` (Iceberg's row-level update commit op).
> SELECT
>   date_trunc('day', committed_at)            AS day,
>   operation,
>   COUNT(*)                                   AS snapshot_count
> FROM iceberg.analytics."fct_events$snapshots"
> WHERE committed_at >= current_timestamp - INTERVAL '30' DAY
> GROUP BY date_trunc('day', committed_at), operation
> ORDER BY day DESC, operation;
> ```
>
> If you see `operation = 'replace'` rows every day (one per dbt run) for the past 30 days AND your diagnostic query in Step 1 shows hundreds-to-thousands of `POSITION_DELETES` files, the delete-file accumulation is consistent with the MERGE workload — confirming the diagnosis.
>
> ### Step 3 — fix on the production stack (Trino 467 + Iceberg 1.5.2)
>
> **There are TWO complementary fixes; you almost always want both, in this order:**
>
> 1. **Run Spark `rewrite_position_delete_files` to compact the delete files** — there is NO Trino-native equivalent on 467 (see DO-NOT-WRITE below for the common fab). This is the load-bearing fix.
>    ```sql
>    -- Spark SQL (NOT Trino) — runs from Spark shell or a scheduled Spark job.
>    -- Verified at iceberg.apache.org/docs/latest/spark-procedures/.
>    CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.fct_events');
>    ```
>    Schedule this as a nightly Spark job (or weekly if MERGE traffic is low). It rewrites the many small delete files into fewer larger delete files AND removes "dangling" deletes that point to data files no longer live.
>
> 2. **Then run Trino `EXECUTE optimize` to compact the data files** — Trino's `optimize` handles content=0 (DATA) files only on 467.
>    ```sql
>    -- Trino 467 — file_size_threshold default 100MB; 128MB is the SaaS-typical sweet spot.
>    ALTER TABLE iceberg.analytics.fct_events EXECUTE optimize(file_size_threshold => '128MB');
>    ```
>
> 3. **Then expire snapshots** so the now-unreferenced old data and delete files actually leave MinIO.
>    ```sql
>    -- Trino 467 — parameter name is retention_threshold (DURATION STRING), NOT older_than (that's Spark).
>    ALTER TABLE iceberg.analytics.fct_events EXECUTE expire_snapshots(retention_threshold => '7d');
>    ```
>
> **Ordering matters:** delete-file compaction FIRST (Spark) → data-file compaction (Trino) → expire snapshots (Trino). Doing expire_snapshots first wastes work because the old files are still pinned. See r17 §"the safe scheduling order" for the full rationale.
>
> ### Step 4 — prevent recurrence at the dbt model level
>
> Three optional dbt-side levers that reduce the rate at which delete files accumulate (none replaces the maintenance schedule above; they reduce its required cadence):
>
> | Lever | What it does | Where to put it |
> |---|---|---|
> | Narrow the MERGE update-set columns | `merge_update_columns=['status', 'updated_at']` (only update these cols, not all) — fewer per-row changes can let MoR consolidate more efficiently | `config(merge_update_columns=[...])` in the model |
> | Partition-aligned merge | Ensure the MERGE join-predicate includes the partition column; lets Trino prune the merge target before scanning delete files | The dbt model's source select; or `incremental_predicates=['DBT_INTERNAL_DEST.day_ts >= DATE \'...\'']` |
> | Switch to copy-on-write for the partition | `write.delete.mode = 'copy-on-write'` rewrites the whole data file on each merge (no delete files produced) — trades write cost for read cost; only choose this if delete-file accumulation is your dominant pain point | Set via `ALTER TABLE ... SET PROPERTIES write_delete_mode = 'copy-on-write'` (Trino SET PROPERTIES surface; see r17) |
>
> **Important caveat on copy-on-write switch**: it dramatically increases write amplification per MERGE — each MERGE rewrites every data file touched. Only flip if (a) delete-file accumulation has become unmanageable AND (b) your MERGE volume per run is small relative to the table.
>
> ### DO-NOT-WRITE — banned forms in the merge-model-degradation diagnosis
>
> | DO NOT write this | What is wrong | The right answer |
> |---|---|---|
> | `ALTER TABLE fct_events EXECUTE rewrite_position_delete_files` | **No such Trino EXECUTE procedure on 467.** Trino's `optimize` does NOT compact position-delete files on this version. `rewrite_position_delete_files` is **Spark-only** per iceberg.apache.org/docs/latest/spark-procedures/. | Use Spark: `CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.fct_events')`. Trino's `optimize` only handles content=0 data files; delete-file compaction must be scheduled as a Spark job. |
> | `ALTER TABLE fct_events EXECUTE optimize(rewrite_deletes => true)` | **`rewrite_deletes` is NOT a parameter of Trino's `EXECUTE optimize`.** The Trino `optimize` procedure has ONE parameter (`file_size_threshold`) per trino.io/docs/current/connector/iceberg.html. Made-up parameters fail with "invalid procedure argument". | `ALTER TABLE iceberg.analytics.fct_events EXECUTE optimize(file_size_threshold => '128MB');` to compact data files; schedule Spark `rewrite_position_delete_files` separately for delete files. |
> | `CALL iceberg.system.rewrite_position_delete_files(table => 'fct_events')` run from a **Trino** client | **`CALL ... system.<procedure>(...)` is the Spark syntax, NOT Trino.** Trino uses `ALTER TABLE ... EXECUTE <procedure>(...)`. Pasting Spark `CALL` syntax into Trino fails with `Procedure not registered`. | The Spark `CALL` form is valid only from a Spark client (spark-sql, Spark Structured Streaming foreachBatch, scheduled Spark job). There is NO Trino translation of `rewrite_position_delete_files` on 467. |
> | `ALTER TABLE fct_events EXECUTE compact_delete_files` | **No such Trino procedure.** Invented by analogy from "optimize for delete files". | Use Spark `CALL iceberg.system.rewrite_position_delete_files(table => 'analytics.fct_events')`. |
> | `SELECT * FROM iceberg.analytics."fct_events$delete_files"` | **No `$delete_files` metadata table on Trino 467.** Delete files are exposed THROUGH the `$files` metadata table via the `content` column (0/1/2). | Query `iceberg.analytics."fct_events$files" WHERE content = 1` to enumerate position-delete files. |
> | `SELECT * FROM iceberg.analytics."fct_events$position_deletes"` | **No `$position_deletes` metadata table on Trino 467.** The Trino-exposed Iceberg metadata tables are: `$snapshots`, `$history`, `$files`, `$manifests`, `$partitions`, `$refs`, `$properties`, `$entries`, `$all_entries`. | Same as above — filter `$files` by `content = 1`. |
> | `SET SESSION iceberg.merge_compaction_threshold = 100` | **No such Trino session property.** Invented from Spark/Iceberg config-style names. | There is NO session property to auto-compact delete files in Trino 467. The schedule is operator-driven (Spark cron job). |
> | "I'll fix this by running `EXECUTE optimize` from Trino more often — it'll clean up the delete files too" | **WRONG — Trino's `optimize` on 467 does NOT compact delete files**, only data files. Running it more often does NOT help with delete-file accumulation; the delete files keep piling up next to the freshly-compacted data files. | Pair Trino `optimize` (data files) with Spark `rewrite_position_delete_files` (delete files). Both procedures are needed on 467 for a fully-compacted table. |
> | `incremental_strategy='upsert'` | **No `upsert` strategy in dbt-trino.** The valid `incremental_strategy` values for dbt-trino are `append` (default), `delete+insert`, and `merge` per [docs.getdbt.com/reference/resource-configs/trino-configs](https://docs.getdbt.com/reference/resource-configs/trino-configs). `upsert` is a Snowflake/Databricks vocabulary item. | Use `incremental_strategy='merge'` with `unique_key='<col>'`. That's the dbt-trino equivalent of an upsert. |
> | "Switch all tables to copy-on-write to fix the problem" | **Overcorrection — CoW write amplification can be worse than the original MoR slowdown.** CoW rewrites entire data files per MERGE, so a 100-row merge against a 1 GB partition rewrites the full 1 GB. Only flip for tables where MERGE volume per run is small AND delete-file accumulation is the dominant pain. | Default to MoR + scheduled `rewrite_position_delete_files` (Spark) + Trino `optimize` + `expire_snapshots`. Switch specific high-MERGE tables to CoW only after measuring that the per-MERGE rewrite cost is less than the read-side delete-file overhead. |
> | "The fix is to drop and recreate the table" | **Loses all snapshot history, breaks any time-travel consumers, requires re-ingestion of the full history.** This is a last-resort blast radius. | The compact-rebuild path above (Spark `rewrite_position_delete_files` → Trino `optimize` → `expire_snapshots`) achieves the same end state (small file count, small delete-file count) without losing history. |
>
> **Why this DO-NOT-WRITE block exists:** "my MERGE model is slow" is one of the highest-frequency dbt-trino performance questions, and the temptation is to (a) invent Trino procedures by analogy from Spark names (`rewrite_position_delete_files` as if it were `EXECUTE`-able), (b) invent Trino procedure parameters by analogy from Spark CALL parameters, or (c) reach for `incremental_strategy='upsert'` from a Snowflake background. Each of these wrong answers wastes the engineer's day with parse errors and procedure-not-found errors. **On Trino 467 + Iceberg 1.5.2, delete-file compaction is Spark-only. There is no Trino EXECUTE shortcut.**
>
> ### Cross-references for the merge-model-degradation workflow
>
> - **Resource 17 §"the safe scheduling order"** — compact → expire → orphan rationale.
> - **Resource 17 §"Trino EXECUTE vs Spark CALL"** — the procedure-name + parameter-name disambiguation matrix; explicitly lists `rewrite_position_delete_files` as Spark-only.
> - **Resource 16 §"How much storage $ will running OPTIMIZE + expire_snapshots save"** — the cost-side framing of the maintenance you're scheduling.
> - **Resource 18 §"query-perf-regression triage"** — the broader oncall workflow if the MERGE-slowdown turns out NOT to be delete-file accumulation.
> - **Resource 26 §"concurrent write conflicts"** — what happens if delete-file compaction collides with a concurrent dbt run.

---

## Common myths about complex SQL performance on Trino + dbt — read FIRST

These are the absolutes most often stated incorrectly when an engineer with Postgres / Oracle / Snowflake muscle memory tries to performance-tune a dbt model on Trino 467. Each TRUTH below has been verified against the [Trino docs](https://trino.io/docs/current/), [dbt-trino docs](https://docs.getdbt.com/reference/resource-configs/trino-configs), and the cited GitHub discussions. **Lead with the TRUTH; state the nuance.**

| MYTH (commonly said wrong) | TRUTH (correct framing) | Authoritative pointer |
|---|---|---|
| "Trino CTEs are materialized — defining `WITH x AS (SELECT expensive_thing)` and referencing `x` twice computes `x` once." | **FALSE on Trino 467 — CTEs are INLINED, NOT materialized.** Trino's optimizer textually substitutes the CTE SELECT wherever the name is referenced. Referencing the same CTE 3 times runs the expensive_thing 3 times. There is no optimization fence and no result reuse. **DO NOT WRITE `WITH heavy AS (...) SELECT ... FROM heavy a JOIN heavy b ON ...` expecting heavy to run once — it runs twice.** **Doc-quoted (trino.io/docs/current/sql/select.html):** *"the SQL for the `WITH` clause will be inlined anywhere the named relation is used. This means that if the relation is used more than once and the query is non-deterministic, the results may be different each time."* Materialize once with a dbt intermediate model (`materialized='table'`) or, for the single-query case, save the result to a temp Iceberg table via `CREATE TABLE ... AS SELECT` first. See [trinodb/trino discussion #28090](https://github.com/trinodb/trino/discussions/28090) and [issue #28085](https://github.com/trinodb/trino/issues/28085). | [Trino SELECT - WITH](https://trino.io/docs/current/sql/select.html#with-clause) — *"the SQL for the WITH clause will be inlined anywhere the named relation is used"*. |
| "More CTEs = faster — breaking a query into 10 CTEs lets the optimizer plan each one separately." | **FALSE — CTE count is performance-neutral or NEGATIVE.** Each CTE is inlined into the query tree; the optimizer plans the whole tree as one. 10 CTEs and one giant subquery produce the same physical plan. CTEs are a READABILITY tool, not a performance tool. If a CTE is referenced multiple times, MORE CTEs can be WORSE (each reference inlines and re-evaluates). The performance lever is *materialization*, not *naming the subquery*. | Same as above. |
| "OSS Trino 467 caches query results — re-running the same SQL is fast." | **FALSE — OSS Trino 467 has NO query result cache.** Re-executing the same query re-reads from Iceberg/MinIO from scratch. See [trinodb/trino #20854](https://github.com/trinodb/trino/issues/20854) (open feature request). What DOES exist: (a) Iceberg connector metadata cache (table/snapshot metadata, reduces planning latency, NOT data cache), (b) the OS page cache on MinIO nodes (incidental), (c) commercial forks (Starburst) which add result caching. The standard mitigation in this stack is to MATERIALIZE the result: dbt incremental models, Trino materialized views ([resource 25](25-trino-materialized-views-iceberg.md)), or dashboard-side cache (Redis). **DO NOT advise an engineer to "just re-run the query, Trino will cache it." It won't.** | [trinodb/trino #20854](https://github.com/trinodb/trino/issues/20854) |
| "Adding more Trino workers always speeds up a slow query." | **FALSE — only true when the query is CPU-bound or scan-bound AND parallelizable.** Adding workers does NOT help when: (a) the bottleneck is a non-distributable operator (single-stage final aggregation; `CorrelatedJoin` nested-loop; ordered global sort), (b) the bottleneck is a SOURCE that can't be scanned in parallel (MySQL via JDBC = 1 split, regardless of workers — see [resource 22](22-trino-federation-postgresql.md)), (c) the bottleneck is the coordinator's planning time, (d) data is skewed so one worker holds 90% of the rows. **Always EXPLAIN ANALYZE first to find the bottleneck — don't reflexively scale out.** | [Trino tuning](https://trino.io/docs/current/admin/tuning.html) |
| "`QUALIFY ROW_NUMBER() OVER (...) = 1` is faster than the equivalent subquery + WHERE rn = 1." | **FALSE on Trino 467 — QUALIFY is a PARSE ERROR.** QUALIFY is a Snowflake/BigQuery/Databricks/Teradata extension, not in the SQL standard, NOT in Trino. The canonical Trino rewrite is `SELECT * FROM (SELECT *, row_number() OVER (PARTITION BY ... ORDER BY ...) AS rn FROM t) WHERE rn = 1`. There is no faster shape; that IS the canonical pattern. **DO NOT WRITE `QUALIFY ...` in a dbt model targeting Trino — it will fail to compile.** | [resource 23](23-sql-best-practices-olap.md) |
| "`rewrite_data_files` is the Trino procedure to compact Iceberg files." | **FALSE — `rewrite_data_files` is the SPARK procedure (`CALL iceberg.system.rewrite_data_files(...)`). On Trino 467 the equivalent is `ALTER TABLE ... EXECUTE optimize`, which honors the table's `sorted_by` property if set.** Pasting Spark `CALL` syntax into a Trino query yields `Procedure not registered`. See [resource 17 § Trino EXECUTE vs Spark CALL disambiguation](17-iceberg-table-maintenance.md). | [Trino Iceberg connector](https://trino.io/docs/current/connector/iceberg.html); [Iceberg Spark procedures](https://iceberg.apache.org/docs/latest/spark-procedures/) |
| "Wrapping a partition column in `date_trunc()` is fine — Iceberg understands the function." | **NUANCED — version-sensitive, NOT an absolute "breaks pruning" rule (refined iter424).** On modern Trino (400+, including 467), there is an optimizer rule that **DOES simplify** `date_trunc('day', event_ts) = DATE '2026-05-30'` into the equivalent naked range `event_ts >= TIMESTAMP '2026-05-30 00:00:00' AND event_ts < TIMESTAMP '2026-05-31 00:00:00'`, AFTER which **partition pruning CAN still fire** on identity-partitioned `event_ts` and on `day(event_ts)` transforms. Doc-quoted source: [trino.io/blog/2023/04/11/date-predicates.html](https://trino.io/blog/2023/04/11/date-predicates.html) — *"Trino again replaces the initial temporal filter to a filter testing whether the column event_time is within the constant timestamp range corresponding to the date used in the initial filter."* Implemented in [trinodb/trino PR #14011](https://github.com/trinodb/trino/pull/14011) ("Simplify predicates involving date_trunc"). **BUT this simplification is fragile**: it works for `date_trunc` against an identity-partitioned timestamp column or `day(event_ts)` transform, NOT guaranteed for `bucket()` / `hour()` transforms wrapped in `date_trunc`, NOT guaranteed for arbitrary function compositions (`LOWER(date_trunc(...))`, etc.), NOT guaranteed when the predicate constant is itself an expression rather than a literal. **The naked-range form** (`WHERE event_ts >= TIMESTAMP '2026-05-30 00:00:00' AND event_ts < TIMESTAMP '2026-05-31 00:00:00'`) **remains the recommended defensive practice** because it works on every Trino version and every partition transform without relying on optimizer-rule presence. **DO NOT WRITE** *"date_trunc breaks pruning"* as an absolute rule on Trino 400+; **DO WRITE** *"date_trunc-to-range simplification fires on identity / `day()` partitions in Trino 400+; it's fragile for `bucket()` / non-trivial transforms / function compositions. Use naked-range form when in doubt, and verify the actual plan with `EXPLAIN` and inspect the `TableScan` `constraint=` annotation."* | [resource 10](10-lakehouse-partitioning.md), [resource 23 § Always include the partition column in WHERE](23-sql-best-practices-olap.md), [trino.io/blog/2023/04/11/date-predicates.html](https://trino.io/blog/2023/04/11/date-predicates.html), [trinodb/trino PR #14011](https://github.com/trinodb/trino/pull/14011) |
| "Correlated subqueries are fine — Trino's optimizer handles them." | **PARTIALLY TRUE — and partially DANGEROUS.** Trino's optimizer ATTEMPTS to decorrelate correlated subqueries via the `TransformCorrelatedJoinToJoin` rule (and related rules for LIMIT, TopN, scalar subqueries). When decorrelation SUCCEEDS, the EXPLAIN shows the rewritten Join/SemiJoin and the query is fast. When decorrelation FAILS (common shapes: aggregates inside the correlated subquery referencing outer cols, correlated WHERE with non-equality conditions, complex outer-references), the EXPLAIN shows a `CorrelatedJoin` operator — a nested-loop executed in worker memory, O(N×M). **The fix is to manually rewrite as a window function or explicit JOIN — don't rely on the optimizer to always win.** Always EXPLAIN and search for `CorrelatedJoin`. | [Trino - Decorrelate subqueries (episode 7)](https://trino.io/episodes/7.html) |
| "BROADCAST joins are always faster than PARTITIONED joins." | **FALSE — only when the BUILD side fits in worker memory.** BROADCAST replicates the build to every worker (fast for small builds, OOM for large). PARTITIONED hash-shuffles BOTH sides by join key (extra shuffle, scales to TB-scale joins). The optimizer picks based on `join-max-broadcast-table-size` (100MB default) when stats are available. **If you have a 5GB dim table joining 500GB fact, BROADCAST will OOM — let Trino pick PARTITIONED.** Run `ANALYZE <table>` (Trino syntax: bare `ANALYZE`, NO `TABLE` keyword) so the optimizer can choose; see [resource 24](24-trino-cbo-analyze.md). | [resource 22 § BROADCAST vs PARTITIONED](22-trino-federation-postgresql.md) |
| "Dynamic filtering doesn't apply to my query — it's only for federated joins." | **FALSE — dynamic filtering is for INNER and RIGHT joins regardless of source.** When you join Iceberg fact x Iceberg dim, build-side keys are still sent to the probe scan at runtime to prune the probe Parquet row-groups. EXPLAIN ANALYZE VERBOSE shows `dynamicFilterSplitsProcessed` and pruned-row counts. Caveat: dynamic filtering does NOT apply to LEFT or FULL OUTER joins. | [Trino - Dynamic filtering](https://trino.io/docs/current/admin/dynamic-filtering.html) |
| "If a CTE is referenced N times in one query, I can force Trino to materialize it with a session property." | **FALSE on Trino 467 — there is no `WITH ... MATERIALIZED` syntax and no session flag to force CTE materialization.** Postgres 12+ has `WITH x AS MATERIALIZED (...)`; Trino has not implemented it (open since 2018, see [trinodb/trino issue #10](https://github.com/prestosql/presto/issues/10) and [#5878](https://github.com/prestosql/presto/issues/5878)). **DO NOT WRITE `WITH x AS MATERIALIZED (...)` in Trino — parse error.** The only way to materialize once on Trino 467 is to write the intermediate to a real (or temp) table — typically a dbt intermediate model with `materialized='table'`. | [trinodb/trino issues #10, #5878, #28090](https://github.com/trinodb/trino/discussions/28090) |

> **Why these specific myths matter.** Each is a load-bearing assumption that, if held, leads engineers to either (a) skip the actual fix (build more CTEs instead of materializing; add workers when the bottleneck is `CorrelatedJoin`; assume Trino caches the result) or (b) confidently break a working query (paste Spark `CALL` into Trino, paste QUALIFY into a dbt model, wrap partition columns in `date_trunc`). **The correct discipline: when about to claim "Trino does / doesn't / will / won't do X" about performance, run `EXPLAIN` or `EXPLAIN ANALYZE` and verify the plan shape.**

---

## 1. The performance-tuning workflow on Trino + dbt

Before changing any SQL, do these four things in order. Steps 1-2 are mandatory; skip them and you'll guess wrong.

### Step 1: Capture the EXPLAIN plan

```sql
EXPLAIN (FORMAT TEXT)
SELECT ...your slow query...;
```

Look for:

- **`TableScan` constraint** — is the partition column listed? If so, partition pruning is firing. If the `TableScan` has no constraint on the partition column, you scanned the whole table.
- **`CorrelatedJoin`** — decorrelation failed. This is almost always the #1 problem in a migrated Oracle query.
- **`Filter`** between `TableScan` and the upper plan — the filter did NOT push down. Predicate may be function-wrapped or type-mismatched.
- **`Aggregate` followed by `Exchange[REPARTITION]`** — your GROUP BY is shuffling all data. Often unavoidable for high-cardinality groups, but sometimes a sign of skew.
- **`Join` distribution** — `REPLICATED` = broadcast (small build), `REPARTITION` = partitioned (both sides shuffle).

### Step 2: Run EXPLAIN ANALYZE on a representative slice

```sql
EXPLAIN ANALYZE
SELECT ...your slow query with a small WHERE filter so it actually finishes...;
```

This adds runtime metrics to each operator. Look for:

- **`physicalInputDataSize: X.X GB`** on `TableScan` — how many bytes were actually read from MinIO. If you expected MB and got GB, partition pruning failed.
- **`Time: X.Xs (Y rows)`** per operator — where is time being spent.
- **`dynamicFilterSplitsProcessed: N`** — verifies dynamic filtering fired on a join.
- **`Output rows: N`** vs **`Input rows: N`** — selectivity at each operator. A `Filter` that reduces 1B rows to 1M rows is doing useful work; a `Filter` that reduces 1B to 999.9M is not.

### Step 3: Identify the bottleneck operator

The slow operator(s) will jump out from the EXPLAIN ANALYZE timings. Map it to the section below:

| Bottleneck shape | Section |
|---|---|
| `CorrelatedJoin` operator visible in plan | § 2 |
| `TableScan` reads all partitions despite WHERE on partition col | § 4.2 |
| Same expensive CTE referenced N times | § 3 |
| `Filter` sitting between `Aggregate` and `TableScan` | § 4.2 |
| `Join` with very large `RemoteExchange[REPLICATE]` (broadcast OOM risk) | § 5 |
| Long sequential scan when the underlying table is huge | § 6 (dbt materialization) |
| Query reruns are also slow | § 7 (materialization + dashboards) |

### Step 4: Make ONE change, re-EXPLAIN, measure

Resist the urge to make 5 changes at once. After each change, re-EXPLAIN, then EXPLAIN ANALYZE on the slice. The bottleneck should move (good) or vanish (better). If it stays in the same place, the change didn't help — revert it before trying the next.

---

## 2. Correlated subqueries — the migration slowness champion

Correlated subqueries are the SQL shape that most often slows a migrated Oracle query to a crawl on Trino. They look harmless in source, and they sometimes work fine (decorrelation succeeded), and sometimes catastrophically (decorrelation failed). Both shapes are common; you can't tell which by reading the SQL.

### 2.1 The pattern that causes the problem

```sql
-- "For each order, get the customer's most recent order amount before this one"
-- (A typical Oracle-shaped per-row lookup.)
SELECT
  o.order_id,
  o.customer_id,
  o.amount,
  (SELECT MAX(o2.amount)
     FROM orders o2
    WHERE o2.customer_id = o.customer_id
      AND o2.order_ts < o.order_ts) AS prev_max_amount
FROM orders o;
```

The inner SELECT references `o.customer_id` and `o.order_ts` from the outer query — that's the correlation. Conceptually, Oracle's row-engine ran this once per outer row. Trino tries to decorrelate it; depending on shape, it may or may not succeed.

### 2.2 EXPLAIN: did decorrelation work?

```sql
EXPLAIN
SELECT o.order_id, ..., (SELECT MAX(o2.amount) FROM orders o2 WHERE ...) FROM orders o;
```

**Success case** — the plan shows a `Join` or `SemiJoin` (decorrelation rewrote the correlation to a join):

```
... Project[...]
      Join[INNER][customer_id = customer_id, order_ts > order_ts]
        TableScan[orders]
        Aggregate[GROUP BY customer_id, ... MAX(amount)]
          TableScan[orders]
```

**Failure case** — the plan shows `CorrelatedJoin`:

```
... Project[...]
      CorrelatedJoin[...]
        TableScan[orders]
        Aggregate[MAX(amount)]
          Filter[customer_id = $0 AND order_ts < $1]
            TableScan[orders]
```

The `CorrelatedJoin` operator is the smoking gun: a nested-loop in worker memory, O(N x M) execution, no parallelism inside.

### 2.3 The manual rewrite — use a window function

The same logic expressed without correlation, as a window function:

```sql
SELECT
  order_id,
  customer_id,
  amount,
  MAX(amount) OVER (
    PARTITION BY customer_id
    ORDER BY order_ts
    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
  ) AS prev_max_amount
FROM orders;
```

One pass over the table, hash-partitioned by `customer_id`, sorted within each partition by `order_ts`, MAX accumulated incrementally. This is consistently 10x-100x faster than the correlated-subquery version when the latter fails to decorrelate.

### 2.4 Common correlated patterns and their canonical Trino rewrites

| Correlated pattern | Trino-friendly rewrite |
|---|---|
| `SELECT (SELECT MAX(b.x) FROM b WHERE b.id = a.id) FROM a` (scalar subquery in SELECT) | `SELECT ... FROM a LEFT JOIN (SELECT id, MAX(x) AS max_x FROM b GROUP BY id) b_agg ON b_agg.id = a.id` |
| `SELECT ... FROM a WHERE EXISTS (SELECT 1 FROM b WHERE b.id = a.id)` | `SELECT a.* FROM a WHERE a.id IN (SELECT id FROM b)` (Trino converts to SemiJoin) OR explicit `JOIN ... DISTINCT` |
| `SELECT ... FROM a WHERE NOT EXISTS (SELECT 1 FROM b WHERE b.id = a.id)` | `SELECT a.* FROM a LEFT JOIN b ON b.id = a.id WHERE b.id IS NULL` (anti-join) |
| `SELECT (SELECT COUNT(*) FROM b WHERE b.cid = a.cid) FROM a` | `SELECT a.*, b_cnt.cnt FROM a LEFT JOIN (SELECT cid, COUNT(*) AS cnt FROM b GROUP BY cid) b_cnt ON b_cnt.cid = a.cid` |
| Per-row "running total" via correlated `(SELECT SUM(x) FROM t t2 WHERE t2.dt <= t.dt)` | `SELECT ..., SUM(x) OVER (ORDER BY dt ROWS UNBOUNDED PRECEDING) FROM t` (window function) — for the bucketed `GROUP BY` + `SUM(COUNT(*)) OVER (...)` variant, see [resource 07 § Pattern A2 — Bucketed running total](07-analytical-query-patterns.md). **Trino GROUP BY caveat:** GROUP BY accepts only expressions or ordinals — never `AS alias` definitions and never SELECT-alias references ([trinodb/trino #16533](https://github.com/trinodb/trino/issues/16533)). |
| "Most recent N per group" via `WHERE n_rows_with_later_date < N` correlated count | `SELECT * FROM (SELECT *, row_number() OVER (PARTITION BY g ORDER BY dt DESC) rn FROM t) WHERE rn <= N` |

---

## 3. CTEs are inlined — materialize once with dbt

This is the second most common migration slowness pattern, and the one most experienced Postgres / Snowflake engineers get wrong because in those engines CTEs were either materialized by default (older Postgres) or by hint (modern Postgres). **In Trino 467, CTEs are inlined and re-evaluated.**

### 3.1 The pattern that causes the problem

```sql
-- BAD: heavy_cte is computed TWICE
WITH heavy_cte AS (
  SELECT customer_id, SUM(amount) AS total
  FROM orders
  WHERE order_date >= DATE '2026-05-01'
  GROUP BY customer_id  -- expensive: shuffles 100GB of orders
)
SELECT
  big_spenders.customer_id,
  big_spenders.total,
  small_spenders.total AS small_total
FROM heavy_cte AS big_spenders
JOIN heavy_cte AS small_spenders ON big_spenders.total > small_spenders.total * 10;
```

The CTE `heavy_cte` is referenced under two aliases in the JOIN. Trino INLINES BOTH references — it runs the GROUP BY twice, shuffles the 100GB orders table twice, etc.

### 3.2 The dbt-shaped fix — materialize the intermediate

Move `heavy_cte` to its own dbt model with `materialized='table'`:

```jinja
-- models/intermediate/int_customer_totals.sql
{{ config(
    materialized='table',
    properties={
      'format': 'PARQUET',
      'partitioned_by': "ARRAY['order_month']",
      'sorted_by': "ARRAY['customer_id']",
      'format_version': 2
    }
) }}

SELECT
  customer_id,
  date_trunc('month', order_date) AS order_month,
  SUM(amount) AS total
FROM {{ ref('stg_orders') }}
WHERE order_date >= DATE '2026-05-01'
GROUP BY customer_id, date_trunc('month', order_date)
```

Then your downstream model references it twice:

```sql
-- models/marts/big_vs_small_spenders.sql
SELECT
  big.customer_id,
  big.total,
  small.total AS small_total
FROM {{ ref('int_customer_totals') }} AS big
JOIN {{ ref('int_customer_totals') }} AS small
  ON big.total > small.total * 10;
```

Now the expensive aggregation runs ONCE during `dbt run` (when `int_customer_totals` builds), and the downstream join reads the already-materialized table.

### 3.3 When to use `ephemeral` vs `table` for the intermediate

| Intermediate referenced... | Choose |
|---|---|
| **1 time only**, lightweight | `ephemeral` (it gets inlined as a CTE — same as writing the CTE directly, but reusable) |
| **2-3 times** within a single downstream model | `table` (materialize once, read N times — the CTE-inlining problem above) |
| **Reused across multiple downstream models** | `table` or `incremental` (the cost is amortized across all consumers) |
| **Across multiple dbt runs and the cost is bounded** | `incremental` with `merge` strategy |

### 3.4 The "deep CTE chain" anti-pattern

```sql
-- A "readable" deep CTE chain that's actually slow:
WITH a AS (SELECT ... FROM source),
     b AS (SELECT ... FROM a WHERE ...),
     c AS (SELECT ... FROM b JOIN ... ON ...),
     d AS (SELECT ... FROM c GROUP BY ...),
     e AS (SELECT ... FROM d JOIN c ON ...)  -- c is referenced TWICE (in d and e), so c is inlined twice
SELECT * FROM e;
```

`c` is referenced both directly by `e` AND indirectly through `d` (which `e` joins). Trino inlines `c`'s SELECT in both places. If `c` is an expensive join, you pay for it twice. **The fix:** identify the CTEs referenced 2+ times in the dependency graph, promote each to its own dbt model with `materialized='table'` (or `ephemeral` if it's only referenced once after the split).

---

## 4. Predicate pushdown — the partition-prune predicate shape

Trino's Iceberg connector can push partition predicates into the metadata layer, skipping entire partitions without reading their data files. This is the single biggest performance lever on a partitioned Iceberg table. It's also the easiest one to accidentally defeat.

### 4.1 What works (predicate pushes, partitions prune)

```sql
-- ALL of these prune partitions on a table partitioned by day(event_ts):
WHERE event_ts >= TIMESTAMP '2026-05-30 00:00:00'
  AND event_ts <  TIMESTAMP '2026-05-31 00:00:00'

WHERE event_ts BETWEEN TIMESTAMP '2026-05-30 00:00:00'
                   AND TIMESTAMP '2026-05-30 23:59:59'

WHERE event_date = DATE '2026-05-30'    -- if partitioned by event_date

WHERE tenant_id = 42                    -- if partitioned by tenant_id

WHERE tenant_id IN (42, 43, 44)         -- IN-list partition prune
```

### 4.2 What breaks pushdown (and how to fix it)

> **VERSION-SENSITIVE NOTE on `date_trunc` (refined iter424).** On Trino 400+ (including 467), there is a `SimplifyDateTrunc` optimizer rule that DOES simplify `date_trunc('day', event_ts) = DATE '2026-05-30'` into the equivalent naked range, after which partition pruning CAN fire on identity-partitioned `event_ts` or `day(event_ts)` transforms (per [trino.io/blog/2023/04/11/date-predicates.html](https://trino.io/blog/2023/04/11/date-predicates.html) and [PR #14011](https://github.com/trinodb/trino/pull/14011)). The simplification is FRAGILE — not guaranteed for `bucket()` / non-default transforms, function compositions, or non-literal constants. The naked-range form below remains the **recommended defensive practice** because it works on every Trino version and every partition transform; verify the actual plan with `EXPLAIN` and inspect the `constraint=` annotation on the `TableScan`.

| Broken shape | Why it breaks (or doesn't, on Trino 400+) | Fix (defensive form) |
|---|---|---|
| `WHERE date_trunc('day', event_ts) = DATE '2026-05-30'` | **FRAGILE on Trino 400+** — the simplifier MAY rewrite this to the naked range and prune on identity / `day()` partitions, but it's NOT guaranteed for `bucket()` / function-compositions. Always verify with `EXPLAIN`. | `WHERE event_ts >= TIMESTAMP '2026-05-30 00:00:00' AND event_ts < TIMESTAMP '2026-05-31 00:00:00'` (works on every Trino version + every transform) |
| `WHERE CAST(event_date AS varchar) = '2026-05-30'` | Cast wraps the column. | `WHERE event_date = DATE '2026-05-30'` |
| `WHERE event_date + INTERVAL '1' DAY = DATE '2026-05-31'` | Arithmetic on partition col. | `WHERE event_date = DATE '2026-05-30'` |
| `WHERE LOWER(tenant_id) = 'tenant_42'` | Function wraps the partition col. | If `tenant_id` is already lowercase in storage, drop `LOWER`; otherwise reconsider partitioning. |
| `WHERE event_date >= '2026-05-30'` (string compared to date) | Type mismatch — Trino does NOT push when types don't match. | Use `DATE '2026-05-30'` literal. |
| `WHERE event_date >= ?` (parameter, query against a view that hides partition col) | Sometimes parameters defeat pushdown — verify with EXPLAIN. | Inline the literal where possible. |
| `WHERE event_date >= CURRENT_DATE - INTERVAL '7' DAY` | Verify in EXPLAIN — modern Trino versions evaluate this at plan time and push, but some shapes don't. | If it doesn't push, compute the literal in dbt Jinja: `{% set sd = run_started_at.strftime('%Y-%m-%d') %}` and inline. |

### 4.3 How to verify in EXPLAIN

```sql
EXPLAIN
SELECT COUNT(*) FROM iceberg.analytics.events
WHERE event_date = DATE '2026-05-30';
```

Look for the `TableScan` line. If pushdown worked:

```
TableScan[iceberg.analytics.events, constraint=event_date = DATE '2026-05-30']
```

The `constraint=...` annotation on the TableScan is the success signature. If you instead see:

```
Filter[event_date = DATE '2026-05-30']
  TableScan[iceberg.analytics.events]
```

— a separate `Filter` node sits between the projection and the scan — pushdown did NOT fire. The full table is being scanned and filtered in worker memory.

---

## 5. Join distribution — broadcast, partitioned, dynamic filtering

When you join two tables on Trino, the engine picks one of two distribution strategies:

- **BROADCAST** (`RemoteExchange[REPLICATE]`): build side (smaller) is replicated to every worker. Fast for small builds. OOMs for big builds.
- **PARTITIONED** (`RemoteExchange[REPARTITION]`): both sides hash-shuffled by join key. Scales to huge tables. Adds a network shuffle.

The optimizer picks based on the table's stats. **If you've never run `ANALYZE iceberg.analytics.events` on the joined tables, the optimizer's pick is unreliable** (Trino syntax: bare `ANALYZE`, NO `TABLE` keyword — `ANALYZE TABLE ...` is Spark/Hive and fails in Trino) — see [resource 24 — CBO / ANALYZE](24-trino-cbo-analyze.md).

### 5.1 The single-query session overrides (when you need to force it)

> **Canonical lever (verified against [trino.io/docs/current/optimizer/cost-based-optimizations.html](https://trino.io/docs/current/optimizer/cost-based-optimizations.html))** — use `SET SESSION join_distribution_type = '<value>';` BEFORE the query. Three accepted values: `'AUTOMATIC'` (default), `'PARTITIONED'`, `'BROADCAST'`. See [resource 24 § LEADING CANONICAL — How do I influence Trino's join distribution](24-trino-cbo-analyze.md) for the full three-lever block (primary `join_distribution_type`, secondary `join_max_broadcast_table_size`, tertiary `ANALYZE`).
>
> **DO-NOT-WRITE — Trino 467 has NO query-hint syntax.** Per [trinodb/trino #9498](https://github.com/trinodb/trino/issues/9498), the `/*+ ... */` form is parsed as a block comment and **silently ignored**. Never write:
> - `SELECT /*+ USE_HASH_JOIN(a,b) */ ...` (Oracle hint name) — silent no-op
> - `SELECT /*+ USE_PARTITIONED_JOIN(a,b) */ ...` (made-up hint name) — silent no-op
> - `SELECT /*+ BROADCAST(small_dim) */ ...` (Spark hint name) — silent no-op
> - `SELECT /*+ MAPJOIN(small_dim) */ ...` (Hive hint name) — silent no-op
> - Any `/*+ ANY_HINT(...) */` form
>
> Failure mode is **silent-wrong**: the query runs with the default cost-based distribution and the engineer thinks the hint applied. Use the SESSION property below instead.

```sql
-- Force BROADCAST (use only when you KNOW the build side is small):
SET SESSION join_distribution_type = 'BROADCAST';

-- Force PARTITIONED (use when stats are missing or wrong and BROADCAST OOMs):
SET SESSION join_distribution_type = 'PARTITIONED';

-- Default (let optimizer pick based on stats):
SET SESSION join_distribution_type = 'AUTOMATIC';
```

These are session-scoped, so set them at the start of a Trino client session or set per-dbt-run via the dbt profile / `pre_hook`. For the per-model case, dbt-trino allows `pre_hook` in the config:

```jinja
{{ config(
    materialized='table',
    pre_hook="SET SESSION join_distribution_type = 'PARTITIONED'"
) }}
```

### 5.2 Dynamic filtering — the runtime probe-prune

Dynamic filtering is the runtime feature that makes "small dim x huge fact" joins fast even without partitioning by the join key. At runtime, Trino collects the build-side join key values into a filter (an IN-list or min/max range), sends it to the probe-side scan, and the probe side prunes Parquet row-groups using the filter BEFORE reading them.

Verify it fired:

```sql
EXPLAIN ANALYZE VERBOSE
SELECT f.*, d.tenant_name
FROM iceberg.analytics.events f
JOIN iceberg.analytics.tenants d ON f.tenant_id = d.id
WHERE d.region = 'us-west';
```

Look in the TableScan for `events`:

```
dynamicFilterSplitsProcessed: 200 (was 5000 unfiltered)
```

That means dynamic filtering pruned 4800 of 5000 splits at runtime.

Supported shapes (verified against [Trino dynamic filtering docs](https://trino.io/docs/current/admin/dynamic-filtering.html)):

- **INNER and RIGHT joins** — supported.
- **LEFT and FULL OUTER joins** — NOT supported.
- **Equality and inequality predicates** (`=`, `<`, `<=`, `>`, `>=`, `IS NOT DISTINCT FROM`) — supported.

---

## 6. dbt-specific levers — materialization choice, partitioning, sorting

When the query you're tuning is a dbt model (not an ad-hoc), the right fix is often at the dbt-config layer, not the SQL layer.

### 6.1 Choose `materialized='incremental'` to skip unchanged work

If your model rebuilds a full fact table from yesterday's source — but only 0.1% of the rows changed — switching from `table` to `incremental` with `merge` strategy can cut the run time from hours to minutes. See [resource 27 § 6](27-oracle-plsql-to-dbt-trino.md) for the canonical worked example.

### 6.2 Partition the dbt-built Iceberg table

```jinja
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='event_id',
    properties={
      'format': 'PARQUET',
      'partitioned_by': "ARRAY['day(event_ts)']",  -- Iceberg partition transform (dbt-trino key: partitioned_by, snake_case)
      'sorted_by': "ARRAY['tenant_id']",
      'format_version': 2
    }
) }}
```

Partition by the column that dominates your downstream WHERE clauses. See [resource 10 — partitioning](10-lakehouse-partitioning.md) for the full transform options (`day(...)`, `month(...)`, `bucket(N, col)`, `truncate(N, col)`, identity).

### 6.3 Cluster files with `sorted_by` + run `optimize`

The `sorted_by` property tells Iceberg writers to sort rows within each file by the specified columns. This dramatically improves Parquet's data skipping for range predicates on the sort key — because each file's min/max statistics for the sort col have a much narrower range.

> **`ALTER TABLE ... SET PROPERTIES sorted_by = ARRAY[...]` alone ONLY governs FUTURE writes.** It is a metadata-only change. Existing data files are NOT physically re-sorted until you run `EXECUTE optimize` to rewrite them — without that second step, the file-level min/max stats stay unchanged and the pruner sees no improvement on today's data. (Reference: [trinodb/trino #26112](https://github.com/trinodb/trino/issues/26112).)

To enforce ordering across existing files (e.g., after many small incremental writes), run:

```sql
-- Trino 467: bin-packs and re-sorts to honor the table's sorted_by property.
-- This is the step that physically re-orders existing files; the ALTER ... SET PROPERTIES
-- sorted_by = ARRAY[...] step above (or in your dbt config on first build) only sets
-- the writer hint for future inserts.
ALTER TABLE iceberg.analytics.events EXECUTE optimize;
```

NOT `CALL iceberg.system.rewrite_data_files(...)` — that's the Spark syntax. See [resource 17 § Trino EXECUTE vs Spark CALL](17-iceberg-table-maintenance.md).

### 6.4 `ANALYZE` for join planning (Trino syntax — bare `ANALYZE`, NO `TABLE` keyword)

```sql
-- CORRECT Trino syntax (bare ANALYZE, NO TABLE keyword):
ANALYZE iceberg.analytics.events;
ANALYZE iceberg.analytics.tenants;
```

**`ANALYZE TABLE <t>` is Spark/Hive syntax and fails in Trino with a parser error** — see [resource 24 §4 LEADING CANONICAL STATEMENT](24-trino-cbo-analyze.md). Run after a `dbt run` that significantly changes data (e.g., post full refresh, post big incremental). The Trino optimizer uses these stats to pick join distribution, join order, and dynamic-filter thresholds.

---

## 7. Re-runs of the same query are also slow — the result-caching gap

If your dashboard fires the same SQL every time a user clicks "refresh" and each click takes 30s, you need to know: **Trino does NOT cache query results.** Every run re-reads from MinIO and re-aggregates.

Your three options on this stack:

1. **dbt incremental model + scheduled `dbt run`** — the dashboard reads the already-aggregated table. Freshness = the cron cadence (5 min, 1 hour, daily). This is the standard pattern. See [resource 27 § 5-6](27-oracle-plsql-to-dbt-trino.md).
2. **Trino materialized view (Iceberg only)** — `CREATE MATERIALIZED VIEW` + scheduled `REFRESH MATERIALIZED VIEW`. Reads hit the Iceberg storage table. Manual refresh; no auto-refresh. See [resource 25](25-trino-materialized-views-iceberg.md).
3. **Application-side cache (Redis / in-memory)** — your SaaS app caches the query result keyed by user/tenant/date. Sub-second freshness for repeated reads; you manage the invalidation.

Pick based on freshness SLO: minutes -> dbt incremental; minutes-to-hours -> Trino MV; sub-second -> Redis.

---

## 8. Worked example — a slow migrated query, optimized step by step

This is the canonical "translated-from-Oracle and slow" query shape, walked through three fixes with before/after EXPLAIN signatures.

### 8.1 The slow query (the migrated form — typical day-one output)

```sql
SELECT *
FROM events e
WHERE date_trunc('day', e.event_ts) >= CURRENT_DATE - INTERVAL '7' DAY
  AND EXISTS (
    SELECT 1
    FROM customers c
    WHERE c.id = e.customer_id
      AND c.tier = 'PREMIUM'
  );
```

Three problems wrapped in one query:

1. `SELECT *` — opens every column of a 50-column wide table.
2. `date_trunc('day', e.event_ts) >= CURRENT_DATE - INTERVAL '7' DAY` — function-wrapped partition column on the LEFT, AND a non-literal constant on the RIGHT (`CURRENT_DATE - INTERVAL '7' DAY`). The Trino 400+ `SimplifyDateTrunc` rule handles the simple `date_trunc(...) = LITERAL` shape on identity / `day()` partitions, but the `>= NON_LITERAL` shape here is fragile — in practice, `EXPLAIN` on this query shows the `Filter` operator did NOT get fused into the `TableScan` `constraint=`, so the connector scanned every partition. The defensive fix below uses the naked-range form on `event_ts` which works regardless of version. (See myth-table row "Wrapping a partition column in `date_trunc()` is fine" for the full version-sensitivity treatment.)
3. Correlated `EXISTS` on `customers` — may or may not decorrelate.

### 8.2 EXPLAIN before any fix

```
Project[*]
  CorrelatedJoin[c.id = e.customer_id, c.tier = 'PREMIUM']      <-- DECORRELATION FAILED (nested loop)
    Filter[date_trunc('day', event_ts) >= DATE '2026-05-23']    <-- FILTER NOT PUSHED
      TableScan[iceberg.analytics.events]                       <-- FULL TABLE SCAN, all 50 cols, all partitions
    Aggregate[...]
      Filter[tier = 'PREMIUM']
        TableScan[iceberg.analytics.customers]
```

EXPLAIN ANALYZE on a slice reports `physicalInputDataSize: 800 GB`. Wall clock: ~22 min.

### 8.3 Fix 1 — narrow projection

```sql
SELECT e.event_id, e.event_ts, e.customer_id, e.event_type, e.amount
FROM events e
WHERE date_trunc('day', e.event_ts) >= CURRENT_DATE - INTERVAL '7' DAY
  AND EXISTS (SELECT 1 FROM customers c WHERE c.id = e.customer_id AND c.tier = 'PREMIUM');
```

EXPLAIN: still `CorrelatedJoin`, still `Filter` not pushed, but `TableScan` now reads only 5 columns. `physicalInputDataSize: 80 GB` (-90%). Wall clock: ~7 min.

### 8.4 Fix 2 — partition-prune-friendly predicate

```sql
SELECT e.event_id, e.event_ts, e.customer_id, e.event_type, e.amount
FROM events e
WHERE e.event_ts >= CURRENT_TIMESTAMP - INTERVAL '7' DAY
  AND EXISTS (SELECT 1 FROM customers c WHERE c.id = e.customer_id AND c.tier = 'PREMIUM');
```

EXPLAIN: `TableScan` now has `constraint=event_ts >= TIMESTAMP '...'`, only 7 partitions scanned. `physicalInputDataSize: 1.2 GB` (-98.5%). Wall clock: ~90s. `CorrelatedJoin` still present.

### 8.5 Fix 3 — rewrite EXISTS as a JOIN (force decorrelation)

```sql
SELECT e.event_id, e.event_ts, e.customer_id, e.event_type, e.amount
FROM events e
JOIN (SELECT DISTINCT id FROM customers WHERE tier = 'PREMIUM') c
  ON c.id = e.customer_id
WHERE e.event_ts >= CURRENT_TIMESTAMP - INTERVAL '7' DAY;
```

(Or, equivalently, `WHERE e.customer_id IN (SELECT id FROM customers WHERE tier = 'PREMIUM')` which Trino converts to a `SemiJoin`.)

EXPLAIN: `Join[INNER]` (or `SemiJoin`) with `RemoteExchange[REPLICATE]` for the small premium-customers build side. Dynamic filtering fires on the `events` scan. `physicalInputDataSize: 1.2 GB` for events; `physicalInputDataSize: 5 MB` for customers (build side, broadcast). Wall clock: ~12s. **180x speedup over the original.**

### 8.6 Summary of the three fixes

| Fix | EXPLAIN signature change | Wall clock | Cumulative speedup |
|---|---|---|---|
| Original | `CorrelatedJoin`, full Filter+TableScan, 50-col scan | 22 min | 1x |
| Fix 1: narrow projection | 5-col scan | 7 min | 3x |
| Fix 2: naked partition predicate | `constraint=` on TableScan, 7-partition scan | 90s | 15x |
| Fix 3: EXISTS -> JOIN | `Join` (broadcast) + dynamic filter on probe | 12s | **110x** |

The first two fixes are essentially free (no architecture change). The third was the only one that required understanding what `CorrelatedJoin` means and rewriting it.

---

## 8A. Deep-dive: the 2nd-angle complex-SQL-perf patterns (added iter424)

> **Scope.** Sections 2-8 covered the canonical perf killers (correlated subqueries, CTE inlining, partition-prune predicate shape, join distribution basics). This section bulletproofs the **deeper** complex-perf patterns that frequently surface in migrated workloads but that sections 2-8 only mention briefly. Treat this as the answer template for "I have a 40-minute query, where do I even start" / "my star-join broadcasts and OOMs" / "my incremental model misses late-arriving data" questions.

### 8A.1 The deeply-nested view chain — diagnosing a 5-level chain that takes 40 minutes

**The problem shape.** A typical migrated reporting query reads from a view that selects from another view that selects from another view, often 4-6 levels deep. Each view is "just a SELECT," so the engineer assumes the chain composes for free. In practice, Trino **inlines every view textually** into the final query plan, exactly like a CTE — and the resulting plan can have 30+ joins, 10+ aggregates, and dozens of redundant scans of the same base tables.

**The five-step diagnosis recipe.**

1. **`SHOW CREATE VIEW` recursively to extract the chain.** Start at the outermost view and walk inward until you reach base tables. Note which base tables appear MULTIPLE times across the chain — those are the candidates for materialization.

   ```sql
   SHOW CREATE VIEW iceberg.analytics.v_executive_dashboard;
   -- Read the SELECT, find the inner views, repeat for each one.
   ```

2. **`EXPLAIN (FORMAT TEXT)` the outermost view.** Count three numbers:
   - **Total `TableScan` operators** — how many times the chain scans base tables. If a base table appears in 5 different `TableScan` nodes, you're scanning it 5 times.
   - **Total `Aggregate` operators** — how many GROUP BYs the plan does. Each one is an exchange + shuffle.
   - **Total `Join` operators** — how many joins. Each one is a potential broadcast/partitioned decision.

   On the canonical "40-minute 5-view chain," typical numbers are 12-20 `TableScan`, 5-8 `Aggregate`, 15-25 `Join` — far more than a SaaS engineer expects, because each view inlines fully.

3. **`EXPLAIN ANALYZE` on a tight WHERE filter that returns fast.** Find the operator with the highest `wall time`. The bottleneck is usually one of:
   - A single `TableScan` reading 100+GB because partition pruning failed somewhere deep in the chain.
   - A single `Aggregate` that hash-shuffles billions of rows.
   - A `CorrelatedJoin` from a deeply-nested correlated subquery.
   - A `Join` with `RemoteExchange[REPLICATE]` (broadcast) on a 5GB build side — close to OOM.

4. **Identify the "shared expensive subtree."** Look for the same `TableScan` (or the same expensive aggregate) appearing 2+ times in the plan. That subtree is what you materialize.

5. **Refactor view-chain into a layered dbt DAG.** Each view becomes a dbt model with an EXPLICIT materialization choice — view, table, or incremental. The layering rule:

   ```text
   Layer 1 (staging, materialized='view'):
       stg_orders, stg_customers, stg_products
       — type-clean, rename, light filter. Cheap to inline.

   Layer 2 (intermediate, materialized='table' OR 'ephemeral'):
       int_order_enriched     (orders + customers + products joined)
       int_customer_metrics   (per-customer aggregates over orders)
       — reused 3+ times downstream -> 'table'.
       — reused 1-2 times, cheap to recompute -> 'ephemeral' (still inlines).

   Layer 3 (fact, materialized='incremental'):
       fct_orders_daily       (daily rollup, partitioned by event_date)
       — large, expensive, accumulates over time -> 'incremental' with merge or append.

   Layer 4 (mart, materialized='table'):
       mart_executive_dashboard  (smaller pre-joined for dashboards)
       — daily-refreshed full rebuild (small enough), partitioned by report_date.
   ```

**The materialization-choice decision tree for chain refactor.**

| Where in the chain | Reuse pattern | Materialization |
|---|---|---|
| Source-touching, light transform | Read once, fed to one downstream layer | `view` |
| Source-touching, multiple downstream consumers (3+) | Heavy join, aggregate | `table` (or `incremental` if delta-friendly) |
| Mid-chain aggregate, reused 2-3x | Medium cost | `ephemeral` (inlined as CTE — but watch for double-evaluation on re-reference) |
| Mid-chain aggregate, reused 4+ times | Heavy aggregate | `table` (always materialize to avoid N-fold re-evaluation) |
| Mid-chain time-series with append-only delta | Daily incremental, retain history | `incremental` with `incremental_strategy='append'` |
| Mid-chain dimension with updates | SCD-1 upsert | `incremental` with `incremental_strategy='merge'` and `unique_key` |
| Final dashboard layer | Small enough for full rebuild | `table` |
| Final dashboard layer | Too big for full rebuild | `incremental` (merge or insert_overwrite by partition) |

**The canonical refactor result.** A 5-view chain that ran in 40 minutes typically refactors into a 4-layer dbt DAG that runs each layer in 1-5 minutes individually, with downstream consumers reading pre-materialized tables instead of inlined views. **The aggregate run time becomes 8-15 minutes of dbt build cost (amortized across all downstream queries), and the dashboard read becomes seconds-to-tens-of-seconds.** This is the 10x-20x speedup that's available from materialization alone — before any partition-prune or join-distribution tuning.

**DO NOT WRITE:** *"Just rewrite the views as CTEs"* — that doesn't help, since Trino CTEs are also inlined. Materialization (writing the intermediate result to a real Iceberg table) is what breaks the inlining chain.

**DO NOT WRITE:** *"Materialize every view as a table"* — over-materializing wastes storage and adds DAG runtime. Use the decision tree above to pick per-layer materialization.

---

### 8A.2 Broadcast vs partitioned join tuning for a migrated star-join (with the OOM failure mode)

**The problem shape.** A migrated star-schema query joins a large fact table to 4-8 dimension tables. Trino's CBO picks `BROADCAST` (build replicated to every worker) for each dim, EXCEPT when stats are missing or wrong — then it might pick PARTITIONED (both sides hash-shuffled by join key) or worse, pick BROADCAST on a 5GB dim and OOM the workers.

**The four diagnostic questions.**

1. **Do all source tables have stats?** Run `SHOW STATS FOR <table>` for the fact and every dim. If `row_count` shows `null` or `data_size` shows `null`, the CBO is making decisions without information — likely wrong. Fix: `ANALYZE <table>` (Trino syntax: bare `ANALYZE`, NO `TABLE` keyword — `ANALYZE TABLE ...` is Spark/Hive and fails in Trino) or rely on Iceberg's auto-collected NDV stats (depends on connector + version). See [resource 24](24-trino-cbo-analyze.md).

2. **What does `EXPLAIN` show as the `RemoteExchange` type for each join?**
   - `RemoteExchange[REPLICATE]` = BROADCAST (build replicated). Best for small builds (<100 MB by default — controlled by `join-max-broadcast-table-size`).
   - `RemoteExchange[REPARTITION]` = PARTITIONED (both sides hash-shuffled). Adds a network shuffle; scales to TB-scale joins.
   - `RemoteExchange[GATHER]` = single-stage gather to coordinator. Rare in star joins; usually a final aggregation.

3. **For each BROADCAST join, what's the BUILD-side total size?** Look at `EXPLAIN ANALYZE` and find the `TableScan` feeding the build side of the join. `Output: X rows (Y MB)`. If `Y` is > 100 MB and you're seeing OOMs on workers, the broadcast is the problem.

4. **For each PARTITIONED join, is dynamic filtering firing?** `EXPLAIN ANALYZE VERBOSE` and look for `dynamicFilterSplitsProcessed` on the probe-side `TableScan`. If 0, dynamic filtering didn't help; the probe is reading the whole table.

**The three remediation patterns.**

**Pattern A — broadcast OOMs because the build is too big.** Force the planner to use PARTITIONED for this join:

```sql
SET SESSION join_distribution_type = 'PARTITIONED';
-- or in dbt model:
{{ config(pre_hook="SET SESSION join_distribution_type = 'PARTITIONED'") }}
```

This forces every join in the query to use PARTITIONED. Heavy hammer — if some joins are legitimately broadcast-friendly, you lose that optimization for them. For per-join control, raise `join-max-broadcast-table-size` for the small dims while letting the planner pick PARTITIONED for the large one:

```sql
SET SESSION join_max_broadcast_table_size = '500MB';
-- Now dims up to 500MB will broadcast; bigger ones will partition.
```

**Pattern B — bad stats causing wrong distribution choice.** Run `ANALYZE <table>` (Trino syntax: bare `ANALYZE`, NO `TABLE` keyword) on every source:

```sql
ANALYZE iceberg.analytics.fact_orders;
ANALYZE iceberg.analytics.dim_customer;
ANALYZE iceberg.analytics.dim_product;
-- etc. for every star-schema table.
```

In dbt, schedule this as a post-hook on a "warehouse maintenance" model that runs daily:

```sql
-- models/maintenance/analyze_all.sql
{{ config(materialized='table', post_hook=[
    "ANALYZE iceberg.analytics.fact_orders",
    "ANALYZE iceberg.analytics.dim_customer",
    "ANALYZE iceberg.analytics.dim_product"
]) }}
SELECT 1 AS analyzed;
```

**Pattern C — join reordering for selectivity.** The CBO chooses join order based on stats; without stats, it joins left-to-right as written. Write joins in **selectivity order** (most selective first) to give the planner a good starting point:

```sql
-- BAD — biggest tables joined first, big intermediate result:
SELECT ...
FROM   fact_orders f                              -- 500M rows
JOIN   dim_product p ON f.product_id = p.id      -- 100K rows, 0.1% selectivity
JOIN   dim_customer c ON f.customer_id = c.id    -- 10M rows
WHERE  c.region = 'US'                            -- filters to 30%
  AND  p.category = 'BOOKS';                      -- filters to 5%

-- GOOD — apply selective filters early:
SELECT ...
FROM   (SELECT id FROM dim_product WHERE category = 'BOOKS') p   -- 5K rows
JOIN   fact_orders f ON f.product_id = p.id                       -- prunes f early
JOIN   (SELECT id FROM dim_customer WHERE region = 'US') c        -- 3M rows
       ON f.customer_id = c.id;
-- Dynamic filtering kicks in on f's TableScan, pruning Parquet row-groups by product_id.
```

The planner's `reorder_joins_max_reordered_joins` (default 9) determines how many joins it'll try to reorder. For 10+ way star joins, raise this:

```sql
SET SESSION reorder_joins_max_reordered_joins = 16;
```

**The session-level knobs reference.**

| Knob | Default | When to change |
|---|---|---|
| `join_distribution_type` | `AUTOMATIC` | Force `PARTITIONED` to debug a BROADCAST OOM; force `BROADCAST` when you KNOW the build fits. |
| `join_max_broadcast_table_size` | 100 MB | Raise to allow bigger dim broadcasts; lower to be conservative. |
| `join_reordering_strategy` | `AUTOMATIC` | Set to `ELIMINATE_CROSS_JOINS` if the CBO is making bad choices. |
| `reorder_joins_max_reordered_joins` | 9 | Raise for 10+ way star joins. |
| `enable_dynamic_filtering` | `true` | Should always be on. Turn off only for debugging. |

---

### 8A.3 Incremental-model late-arriving data and lookback windows

#### 8A.3.0 DBT-IS-INCREMENTAL-WHERE CANONICAL-PATTERN GUARDRAIL

> **Why this section exists.** The single most common AI-generated mistake when writing a dbt `is_incremental()` WHERE clause is to put a **bare aggregate** directly in the predicate — for example `WHERE load_date >= MAX(load_date)`. This is **INVALID SQL**: Trino rejects it at parse time with an error like "aggregate function not allowed in WHERE clause." Aggregates may only appear in a `SELECT` list, a `HAVING` clause, or **inside a subquery**. They are not permitted in a plain `WHERE`. Verified against [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) (Aggregate functions reference) and [docs.getdbt.com — Incremental models](https://docs.getdbt.com/docs/build/incremental-models).
>
> The second-most-common mistake is a **convoluted full-history re-scan** disguised as a delta filter — e.g., `WHERE id IN (SELECT id FROM {{this}} WHERE load_date < CURRENT_DATE) OR load_date >= ...`. That clause re-reads every historic row from the target on every run, which is the *opposite* of what incrementality is for.

**The CANONICAL is_incremental() delta filter — append/merge model:**

```sql
{% if is_incremental() %}
  WHERE load_date >= (
    SELECT COALESCE(MAX(load_date), DATE '1970-01-01')
    FROM {{ this }}
  )
{% endif %}
```

The `MAX(load_date)` **MUST be wrapped in a subquery** (the `(SELECT MAX(...) FROM {{ this }})` form). The subquery is what makes the aggregate legal inside `WHERE`. The `COALESCE(..., DATE '1970-01-01')` handles the edge case where `{{ this }}` exists but is empty (e.g., after a manual `TRUNCATE` or first-run-after-restart) so the predicate evaluates to "everything" rather than `NULL` (which would filter to zero rows).

**The CANONICAL late-arriving-data LOOKBACK variant — pair with `incremental_strategy='merge'` + `unique_key` for idempotence:**

```sql
{% if is_incremental() %}
  WHERE load_date >= (
    SELECT date_add('day', -3, COALESCE(MAX(load_date), DATE '1970-01-01'))
    FROM {{ this }}
  )
{% endif %}
```

The `date_add('day', -3, ...)` subtracts a fixed lookback window (here 3 days) from the prior watermark so late-arriving rows still get picked up. Idempotence is guaranteed by `incremental_strategy='merge'` + `unique_key`: matched rows update in place, unmatched insert — re-running the same lookback window produces no duplicates.

**DO-NOT-WRITE callout (load-bearing — both bullets are invalid SQL or anti-patterns):**

> **(i) NEVER write a bare aggregate directly in a `WHERE` clause** — for example `WHERE load_date >= MAX(load_date)`, `WHERE x > MIN(x)`, `WHERE cnt < COUNT(*)`. Aggregate functions are not allowed in `WHERE` in Trino (or any ANSI-SQL engine). They MUST be wrapped in a subquery: `WHERE load_date >= (SELECT MAX(load_date) FROM {{ this }})`. **(ii) NEVER write the convoluted full-history re-scan `WHERE id IN (SELECT id FROM {{ this }} WHERE load_date < CURRENT_DATE) OR load_date >= ...` as a delta filter.** That clause forces the model to read every historic row from the target on every run, defeating the entire purpose of `materialized='incremental'`. The canonical delta filter is a single subquery-wrapped `MAX(...)` comparison, not an IN-against-the-target.

**Q-pattern matcher.** If the question is "what does my dbt `is_incremental()` WHERE clause look like" — or any equivalent phrasing ("incremental delta filter", "watermark predicate", "scan only new rows in dbt") — the answer is `WHERE <watermark_col> >= (SELECT COALESCE(MAX(<watermark_col>), <safe_default>) FROM {{ this }})` with the subquery wrapper. NOT a bare `MAX(...)` in `WHERE`. NOT an `IN (SELECT ... FROM {{ this }} ...)` against the target.

**Worked example pair.**

```sql
-- (a) APPEND-style delta (no late arrivals expected) — pair with incremental_strategy='append'
{% if is_incremental() %}
  WHERE event_ts > (SELECT COALESCE(MAX(event_ts), TIMESTAMP '1970-01-01') FROM {{ this }})
{% endif %}

-- (b) MERGE-style delta with 3-day lookback (late arrivals expected) — pair with
--     incremental_strategy='merge' + unique_key for idempotent re-processing
{% if is_incremental() %}
  WHERE event_ts >= (
    SELECT date_add('day', -3, COALESCE(MAX(event_ts), TIMESTAMP '1970-01-01'))
    FROM {{ this }}
  )
{% endif %}
```

(a) uses a strict `>` because we trust the watermark is monotonic. (b) uses `>=` plus a lookback window to absorb late arrivals; the `merge` strategy + `unique_key` make it idempotent.

#### 8A.3.1 The lookback-window failure mode (background)

**The problem shape.** An incremental dbt model uses `is_incremental()` to filter to "new" rows: `WHERE event_ts > (SELECT MAX(event_ts) FROM {{ this }})`. But upstream events sometimes arrive HOURS or DAYS late (network retries, batch CDC catches up, mobile clients sync after being offline). The first run after the late events lands sees them, but the incremental filter (`event_ts > previous_max`) has ALREADY moved past their timestamps — so the late events are silently dropped.

**The fix: a lookback window.** Re-process the last N hours/days every run, idempotently. Pick N to match the upstream's worst-case lateness (e.g., 2 days for nightly batch CDC, 6 hours for streaming).

**The canonical incremental model with lookback:**

```sql
-- models/marts/fct_events_daily.sql
{{ config(
    materialized='incremental',
    incremental_strategy='merge',
    unique_key='event_id',
    partition_by={'field': 'event_date', 'data_type': 'date'},
    on_schema_change='fail'
) }}

SELECT
    event_id,
    event_ts,
    CAST(event_ts AS DATE) AS event_date,
    customer_id,
    event_type,
    amount
FROM   {{ ref('stg_events') }}
{% if is_incremental() %}
    -- Lookback: re-process the last 2 days every run.
    -- merge strategy + unique_key=event_id makes this IDEMPOTENT — late rows update;
    -- already-seen rows match on event_id and overwrite identically.
    WHERE event_ts >= (
        SELECT date_add('day', -2, COALESCE(MAX(event_ts), TIMESTAMP '1900-01-01'))
        FROM   {{ this }}
    )
{% endif %}
```

**Why this is idempotent.** The `incremental_strategy='merge'` with `unique_key='event_id'` generates a `MERGE INTO` SQL that:
- `WHEN MATCHED`: updates the row (no duplicate)
- `WHEN NOT MATCHED`: inserts the new row

Re-running over the same 2-day window is a no-op for already-seen events; late-arriving events get UPSERTed correctly.

**The four lookback-window failure modes to avoid.**

1. **`incremental_strategy='append'` with a lookback.** This INSERTS duplicate rows for already-seen events. Always use `merge` (or `delete+insert` / `insert_overwrite` for partition-replace patterns) when using lookback. The `append` strategy is correct only when the upstream guarantees no late arrivals AND you use a strict `event_ts > MAX` filter (no lookback).

2. **Lookback shorter than upstream worst-case lateness.** If CDC can be 72 hours late but your lookback is 24 hours, you'll still drop rows. Audit upstream: `SELECT MAX(NOW() - event_ts) FROM stg_events` and pick N to cover the long-tail.

3. **Lookback longer than necessary.** A 30-day lookback on a 500M-row table re-reads 30 days of data EVERY run, which defeats the point of incremental. Pick N to match upstream lateness, no longer.

4. **Forgetting `partition_by`** on the incremental table. Without partitioning, the `MERGE INTO` has to scan the whole table to find matching `event_id`s. With `partition_by='event_date'` AND a lookback WHERE on `event_date >= ...`, the merge only scans the lookback-window partitions. **Always partition incremental tables on the same column the lookback filters on.**

**The `insert_overwrite` alternative for partition-replace patterns.** For TRULY append-only data where you re-process whole partitions atomically (e.g., "re-run yesterday's partition"), use `incremental_strategy='insert_overwrite'` (where supported) or the equivalent dbt-trino pattern:

```sql
{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='event_date',  -- partition key, not row key
    partition_by={'field': 'event_date', 'data_type': 'date'}
) }}

SELECT * FROM {{ ref('stg_events') }}
{% if is_incremental() %}
    WHERE event_date >= CURRENT_DATE - INTERVAL '2' DAY
{% endif %}
```

This deletes the last 2 partitions and re-inserts them — atomic per partition (each partition flips to a new Iceberg snapshot), idempotent, and faster than `merge` for partition-scale rewrites.

**EXPLAIN-driven validation.** After implementing the lookback, run `EXPLAIN ANALYZE` on a sample incremental run and check:
- The `TableScan` of `stg_events` has `constraint=(event_date >= DATE '...')` (lookback predicate pushed).
- The MERGE/DELETE row counts in `EXPLAIN ANALYZE` output match the expected lookback-window size.
- `physicalInputDataSize` on the scan equals roughly N days × daily-volume (not the full table).

---

## 9. The full performance-tuning checklist for a slow dbt model

When a migrated dbt model is slow, run through this in order:

1. **`EXPLAIN <the model SQL>` — look for `CorrelatedJoin`.** Rewrite to JOIN / window function. (Section 2.)
2. **`EXPLAIN ANALYZE` on a slice — check `physicalInputDataSize` on the TableScan.** If huge, partition pruning failed. Naked the partition col in WHERE. (Section 4.)
3. **Find expensive CTEs referenced multiple times.** Promote to `materialized='table'` dbt models. (Section 3.)
4. **Replace `SELECT *` with the columns you actually use.** (Section 8.1.)
5. **`ANALYZE <table>` on the inputs.** (Trino syntax: bare `ANALYZE`, NO `TABLE` keyword.) Lets the optimizer pick join distribution correctly. ([Resource 24](24-trino-cbo-analyze.md).)
6. **Switch from `materialized='table'` to `materialized='incremental'`** if the delta is small. (Section 6.1; [resource 27 § 5](27-oracle-plsql-to-dbt-trino.md).)
7. **Add `partitioning` and `sorted_by` in dbt config** to match dominant WHERE filters. (Section 6.2-6.3, [resource 10](10-lakehouse-partitioning.md).)
8. **Schedule `ALTER TABLE ... EXECUTE optimize` on the dbt-built table** to consolidate small files from incremental runs. (Section 6.3, [resource 17](17-iceberg-table-maintenance.md).)
9. **For repeated dashboard queries**, add either a Trino materialized view ([resource 25](25-trino-materialized-views-iceberg.md)) or an app-side cache. (Section 7.)
10. **Replace exact `COUNT(DISTINCT)` with `approx_distinct()`** in non-billing contexts — typical 10-50x speedup. ([Resource 23 § 3](23-sql-best-practices-olap.md).)

---

## 10. Cross-references

- **Migrating Oracle PL/SQL to dbt + Trino:** [resource 27](27-oracle-plsql-to-dbt-trino.md) — the procedural -> declarative mindset, the Oracle->Trino SQL dialect translation table, the worked nightly-rollup example.
- **SQL best practices on Trino:** [resource 23](23-sql-best-practices-olap.md) — partition filter, approximate functions, SELECT * avoidance, QUALIFY anti-pattern.
- **Trino CBO / ANALYZE / Puffin stats:** [resource 24](24-trino-cbo-analyze.md) — running ANALYZE for join-distribution correctness.
- **Iceberg partitioning:** [resource 10](10-lakehouse-partitioning.md) — partition transforms, hidden partitioning, partition column choice.
- **Iceberg maintenance:** [resource 17](17-iceberg-table-maintenance.md) — `ALTER TABLE ... EXECUTE optimize`, sorted_by, the Trino EXECUTE vs Spark CALL disambiguation matrix.
- **Trino materialized views on Iceberg:** [resource 25](25-trino-materialized-views-iceberg.md) — dashboard-rollup caching pattern.
- **Federation pushdown reference card:** [resource 22](22-trino-federation-postgresql.md) — predicate / projection / aggregate / TopN pushdown signatures.
- **Query regression triage workflow:** [resource 18](18-query-performance-regression.md) — oncall debugging pattern for "it was fast yesterday."

---

## 11. Reference URLs verified for this resource

- Trino SELECT (WITH clause inlining): https://trino.io/docs/current/sql/select.html
- Trino dynamic filtering: https://trino.io/docs/current/admin/dynamic-filtering.html
- Trino cost-based optimizations: https://trino.io/docs/current/optimizer/cost-based-optimizations.html
- Trino EXPLAIN: https://trino.io/docs/current/sql/explain.html
- Trino EXPLAIN ANALYZE: https://trino.io/docs/current/sql/explain-analyze.html
- Trino Iceberg connector (EXECUTE optimize, sorted_by, properties): https://trino.io/docs/current/connector/iceberg.html
- Trino tuning: https://trino.io/docs/current/admin/tuning.html
- dbt-trino configurations: https://docs.getdbt.com/reference/resource-configs/trino-configs
- dbt incremental strategies: https://docs.getdbt.com/docs/build/incremental-strategy
- Iceberg Spark procedures (for the rewrite_data_files disambiguation): https://iceberg.apache.org/docs/latest/spark-procedures/
- Trino CTE materialization discussion: https://github.com/trinodb/trino/discussions/28090
- Trino query result cache request: https://github.com/trinodb/trino/issues/20854
