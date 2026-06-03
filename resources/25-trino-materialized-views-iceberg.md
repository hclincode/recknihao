# Trino Materialized Views on Iceberg (the dashboard-aggregation pattern)

> **Production fit (read first).** This resource targets the stack in `prod_info.md`: **Trino 467** on Kubernetes, **Iceberg connector** backed by Hive Metastore, MinIO as object store, no public cloud. Materialized views in OSS Trino 467 are supported by the **Iceberg connector only** — every claim and code sample below assumes the target catalog is your Iceberg catalog. Verified against Trino 481 official docs (`https://trino.io/docs/current/connector/iceberg.html` and `https://trino.io/docs/current/sql/create-materialized-view.html`); the materialized-view feature in 467 is the same shape with minor surface differences (e.g., `iceberg.materialized-views.hide-storage-table` was still available in 467, deprecated in later versions).

---

## TL;DR (read these 7 sentences first)

1. **`CREATE MATERIALIZED VIEW` on the Iceberg connector creates two things atomically: a view definition stored in Hive Metastore, and a hidden Iceberg "storage table" that physically holds the cached query result.** Reads of the MV hit the storage table; the federation/aggregation is **not** re-executed per read.
2. **There is NO auto-refresh.** Trino does not background-poll source tables and re-materialize anything. You must trigger `REFRESH MATERIALIZED VIEW <name>` yourself via a scheduler (cron, dbt, Airflow, k8s CronJob) — the cadence is whatever your freshness SLO allows.
3. **Refresh mode is decided automatically:** **incremental** when all source tables are Iceberg and the query shape supports it (Trino reads only deltas since the last refresh's snapshot-ids); **full** when any source is non-Iceberg (Postgres, MySQL, Hive) or the query shape is incompatible (e.g., complex window functions, recursive CTEs).
4. **Freshness is snapshot-based, not time-based.** At refresh, Trino records the source Iceberg tables' `snapshot_id` values in the MV metadata. On read, Trino compares against the *current* source snapshot_ids: if unchanged, MV is fresh; if any advanced, MV is stale.
5. **`GRACE PERIOD` controls how long a stale MV still serves cached data anyway.** Default is **infinity** (always serve cache, no fallback); set `GRACE PERIOD INTERVAL '15' MINUTE` to bound staleness. After grace period expires and sources have advanced, behavior switches to `WHEN STALE` (default `INLINE` — fall through to the underlying query; or `FAIL` — error out).
6. **For all-Iceberg sources, there's a smart-shortcut**: even past the grace period, if the connector can prove source snapshots haven't changed, it keeps serving from the storage table (no needless full re-execution). Federated MVs (any non-Iceberg source) cannot prove this and will fall through every time past grace period.
7. **Decision shortcut for the dashboard-aggregations use case:** if the underlying SELECT is a fixed-shape aggregation refreshed on a schedule and lives entirely inside Iceberg, use a Trino MV. If it has complex dbt-managed lineage / MERGE / multi-step transformations, write a dbt rollup model. If freshness SLO is sub-second and the result is small, app-side Redis is faster than either.

---

## Common myths about Trino materialized views on Iceberg — read FIRST (the load-bearing wrong claims)

These are the absolutes most often stated incorrectly about Trino 467 materialized views (Iceberg connector). Each TRUTH below has been verified against the [Trino Iceberg connector docs](https://trino.io/docs/current/connector/iceberg.html), [Trino CREATE MATERIALIZED VIEW docs](https://trino.io/docs/current/sql/create-materialized-view.html), and [Trino REFRESH MATERIALIZED VIEW docs](https://trino.io/docs/current/sql/refresh-materialized-view.html). **Lead with the TRUTH; state the nuance.**

| MYTH (commonly said wrong) | TRUTH (correct framing) | Where in this doc |
|---|---|---|
| "Trino materialized views auto-refresh in the background when source tables change." | **NO — there is NO auto-refresh, NO background poller, NO scheduler in Trino 467.** You must explicitly run `REFRESH MATERIALIZED VIEW <name>` from a cron / Airflow / k8s CronJob / dbt operation. This is verified at [trinodb/trino #18673](https://github.com/trinodb/trino/issues/18673) ("Trino currently does not support automatic refresh of materialized views") and [trinodb/trino #25366](https://github.com/trinodb/trino/issues/25366). The freshness DETECTION is automatic (snapshot-id comparison) but the refresh ACTION is manual. | [§ 2. CREATE MATERIALIZED VIEW](#2-create-materialized-view--syntax) and TL;DR #2 |
| "MVs work on any Trino connector — I can create one over a Postgres table or a Hive table." | **NO — `CREATE MATERIALIZED VIEW` works ONLY on the Iceberg connector in OSS Trino 467.** The MV's storage table must be an Iceberg table. The SELECT can FEDERATE across connectors (Postgres + Iceberg + Hive in the same query), but the MV ITSELF must be created in an Iceberg catalog. Hive connector and Postgres connector do NOT support `CREATE MATERIALIZED VIEW`. Verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html). | [§ Production fit](#) header callout |
| "`REFRESH MATERIALIZED VIEW` always does an incremental refresh — it reads only new rows." | **NO — refresh mode is DECIDED AUTOMATICALLY based on query shape and source types.** **Incremental refresh** happens ONLY when (a) ALL source tables are Iceberg, AND (b) the query shape supports it (simple SELECT + aggregations + INNER JOINs). **Full refresh** happens when any source is non-Iceberg (Postgres / MySQL / Hive) OR the query has unsupported shapes (complex window functions, recursive CTEs, certain OUTER JOINs). You cannot force incremental via syntax — Trino picks. Verified at [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html) ("REFRESH MATERIALIZED VIEW... may perform either an incremental or a full refresh"). | [§ TL;DR #3 — Refresh mode](#tldr-read-these-7-sentences-first) callout |
| "If my MV is stale, queries against it block until refresh completes." | **NO — default behavior is `WHEN STALE INLINE` which FALLS THROUGH to executing the underlying SELECT directly.** When stale + past grace period, the MV becomes effectively transparent: SELECT-from-MV runs the original query against source tables. No blocking, no refresh-on-read. The other option is `WHEN STALE FAIL` which errors out instead. There is NO `WHEN STALE REFRESH` option — that's a common misreading. Verified at [trino.io/docs/current/sql/create-materialized-view.html](https://trino.io/docs/current/sql/create-materialized-view.html). | [§ 2.1 Full Trino syntax](#21-full-trino-syntax-from-trino-481-docs) callout |
| "`GRACE PERIOD INTERVAL '0' MINUTE` means 'always check freshness and refresh if stale'." | **NO — `GRACE PERIOD '0'` means 'never serve stale data; immediately fall through to source when any source advances'.** It does NOT trigger a refresh. The freshness model is: at every query, Trino checks source snapshot-ids vs MV-stored snapshot-ids. If unchanged → serve MV. If changed → behavior depends on grace period + WHEN STALE clause. Default `GRACE PERIOD` is **infinity** (always serve cache); set a finite period to bound staleness; set `'0'` to fail-open to source on any source advance. | [§ 2.1 Full Trino syntax](#21-full-trino-syntax-from-trino-481-docs) GRACE PERIOD callout |
| "MVs with non-Iceberg sources (e.g., Postgres) just don't work in Trino 467." | **THEY WORK, with one critical caveat: Trino CANNOT detect Postgres source-table changes.** A federated MV (Iceberg storage + any non-Iceberg source like Postgres) refreshes correctly when you call `REFRESH MATERIALIZED VIEW`, but Trino has no way to compare Postgres "snapshot-ids" — so it always considers the MV STALE after any time advances past grace period (it has to assume Postgres may have changed). Practical impact: a federated MV past grace period ALWAYS falls through to the underlying SELECT — losing the cache benefit. Use federated MVs ONLY with `GRACE PERIOD INTERVAL 'N' HOUR` for long enough windows that staleness is acceptable. | [§ Federated MVs](#federated-mvs) section |
| "The MV is a view, so it doesn't need maintenance like Iceberg tables do." | **NO — the storage table backing the MV is a REAL Iceberg table.** It accumulates snapshots, manifest files, and orphan files exactly like any other Iceberg table. You MUST run `expire_snapshots`, `remove_orphan_files`, and (after frequent refreshes) `OPTIMIZE` on the storage table. The storage table name is auto-generated; find it via `SELECT * FROM iceberg.system.materialized_views WHERE name = '<your_mv_name>'` or `SHOW CREATE MATERIALIZED VIEW <name>`. See resource 17. | [§ MV storage table maintenance](#mv-storage-table-maintenance) callout |
| "I can use `OR REPLACE` and `IF NOT EXISTS` together in `CREATE MATERIALIZED VIEW`." | **NO — they're mutually exclusive.** `CREATE OR REPLACE MATERIALIZED VIEW IF NOT EXISTS ...` is a SYNTAX ERROR. Use one or the other. `OR REPLACE` drops and recreates; `IF NOT EXISTS` is a no-op when the MV exists. Verified at [trino.io/docs/current/sql/create-materialized-view.html](https://trino.io/docs/current/sql/create-materialized-view.html). | [§ 2.1 Full Trino syntax](#21-full-trino-syntax-from-trino-481-docs) |
| "`REFRESH MATERIALIZED VIEW` is async — it returns immediately and refreshes in the background." | **NO — `REFRESH MATERIALIZED VIEW` is SYNCHRONOUS and blocks until refresh completes.** A long refresh (e.g., 800M-row aggregation) will tie up a Trino query slot for minutes. For long refreshes, run them from a dedicated user/resource group, off-peak, and consider Spark for very-large rebuilds (Spark Iceberg also supports MV-equivalent patterns via INSERT OVERWRITE on a rollup table). | [§ Running refresh in production](#running-refresh-in-production) callout |
| "MV reads automatically benefit from predicate pushdown into the underlying SELECT." | **NO — when the MV is FRESH, predicates push down to the storage TABLE (the Iceberg table), not to the underlying SELECT (which never runs).** When the MV is STALE and falls through via `WHEN STALE INLINE`, predicates push into the underlying SELECT and through to the original source tables (Iceberg / Postgres / etc.). The two behaviors are different — your dashboard's `WHERE event_date = ...` works in BOTH cases, but the pushdown destination differs. Plan the MV's `partitioning` to match the most-common dashboard filters so pushdown helps the fresh path too. | [§ MV partitioning for pushdown](#mv-partitioning-for-pushdown) callout |

> **Why these specific myths matter.** Each is a load-bearing topic-specific claim about Trino MVs. Stated as an absolute, it causes engineers to either build expensive workarounds for non-problems (writing a custom polling script to check freshness when Trino does that automatically; assuming Postgres MVs are unusable when they work with a long GRACE PERIOD) OR to confidently break things (assuming auto-refresh runs in the background and never wiring up a cron, then wondering why the MV is months stale; assuming `WHEN STALE REFRESH` is a valid option and writing untested DDL). **The correct discipline:** when about to say "Trino MV does / doesn't / can / can't X", check (a) [trino.io/docs/current/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html), (b) [trino.io/docs/current/sql/create-materialized-view.html](https://trino.io/docs/current/sql/create-materialized-view.html), (c) the team's own resource 25.

---

## 1. The one-paragraph mental model

A Trino materialized view is **a regular Iceberg table dressed up as a view**. When you `SELECT * FROM iceberg.analytics.dashboard_mv`, Trino does NOT re-run the underlying SELECT — it scans the hidden Iceberg storage table that was populated the last time someone ran `REFRESH MATERIALIZED VIEW`. The storage table is a real Iceberg table living in MinIO with snapshots, manifests, Parquet files, and the same lifecycle quirks (snapshot expiration, orphan files, compaction) as any other Iceberg table you create with `CREATE TABLE`. The "view" part is just two pieces of metadata in Hive Metastore: (a) the SELECT text, and (b) the name of the storage table that backs it. **Refresh is manual, freshness is snapshot-tracked, and the whole thing is Iceberg-only.**

---

## 2. CREATE MATERIALIZED VIEW — syntax

### 2.1 Full Trino syntax (from Trino 481 docs)

```sql
CREATE [ OR REPLACE ] MATERIALIZED VIEW
[ IF NOT EXISTS ] view_name
[ GRACE PERIOD interval ]
[ WHEN STALE ( INLINE | FAIL ) ]
[ COMMENT string ]
[ WITH ( property = value, ... ) ]
AS query
```

- `OR REPLACE` and `IF NOT EXISTS` are mutually exclusive.
- `GRACE PERIOD` default: **infinity** (cache served indefinitely until manually refreshed).
- `WHEN STALE` default: **`INLINE`** — falls through to the underlying SELECT once stale + past grace. Only `INLINE` and `FAIL` are valid; there is **no** `REFRESH` option (a common misreading).
- `WITH (...)` properties are passed to the Iceberg connector to configure the **storage table** (format, partitioning, etc.).

### 2.2 Worked example — the dashboard-aggregation pattern

```sql
-- Use case: a dashboard shows "events per tenant per day for the last 30 days,"
-- runs every page-load, currently re-aggregates 800M rows each time.
-- Pre-aggregate it once an hour into a small MV; dashboard reads the MV.

CREATE MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant
  GRACE PERIOD INTERVAL '90' MINUTE
  WHEN STALE INLINE
  COMMENT 'Hourly rollup feeding the per-tenant dashboard. Owner: analytics team.'
  WITH (
    format = 'PARQUET',
    partitioning = ARRAY['event_date'],
    format_version = 2,
    sorted_by = ARRAY['tenant_id']
  ) AS
SELECT
  DATE(occurred_at)        AS event_date,
  tenant_id,
  event_type,
  COUNT(*)                 AS event_count,
  COUNT(DISTINCT user_id)  AS unique_users
FROM iceberg.analytics.events
WHERE occurred_at >= CURRENT_DATE - INTERVAL '31' DAY
GROUP BY 1, 2, 3;
```

What this gives you the moment the statement returns:

1. **A view definition** recorded in HMS with the SELECT text + resolved schema (4 columns).
2. **A storage table** auto-created in the same schema (`iceberg.analytics.<auto-generated-name>`) with the partitioning and format you specified.
3. **No data.** The storage table is empty. Reads against the MV right now will fall through to the underlying SELECT (because it's stale + the default `WHEN STALE INLINE` falls through).
4. **No scheduled refresh.** You still need to wire up a cron / k8s CronJob / dbt operation that runs `REFRESH MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant` every hour.

### 2.3 Storage-table properties — what you can configure via `WITH`

The properties in the `WITH (...)` clause configure the **hidden Iceberg storage table**, not the view. Anything you can set on `CREATE TABLE` for an Iceberg table you can set here:

| Property | Effect | Recommended default |
|---|---|---|
| `format` | File format for the storage table | `'PARQUET'` (matches the rest of your lakehouse) |
| `partitioning` | Iceberg partition spec for the storage table | Match the dominant filter on the MV (e.g., `ARRAY['event_date']` for a date-filtered dashboard) |
| `format_version` | Iceberg spec version: `1` or `2` | `2` (required for MoR features; default in modern Iceberg) |
| `sorted_by` | Iceberg sort-order for files | The second-most-common filter (after partitioning) |
| `compression_codec` | Page compression for Parquet | `'ZSTD'` (default in recent Iceberg) |
| `storage_schema` | Where the storage table lives — defaults to the view's own schema | Move to a separate `iceberg.analytics_mv_storage` schema if you want OPA grants to differ |

**Why `partitioning` matters for an MV:** queries against the MV get the same partition-pruning benefit as queries against a regular Iceberg table. A 30-day dashboard that filters by `event_date >= CURRENT_DATE - 7` will only read 7 partitions of the storage table, not the full 30.

### 2.4 Inspecting what was created

The Iceberg connector exposes the standard metadata tables on the storage table backing the MV. The MV's own metadata is visible via `SHOW CREATE MATERIALIZED VIEW` and `system.metadata.materialized_views`:

```sql
-- View definition + grace period + WHEN STALE behavior
SHOW CREATE MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant;

-- Storage table name (auto-generated; you usually don't need it)
SELECT *
FROM system.metadata.materialized_views
WHERE catalog_name = 'iceberg'
  AND schema_name  = 'analytics'
  AND name         = 'events_daily_by_tenant';

-- Storage-table properties — appended $properties metadata table
SELECT * FROM iceberg.analytics."events_daily_by_tenant$properties";

-- Snapshots of the storage table itself (one per REFRESH)
SELECT committed_at, snapshot_id, operation, summary
FROM iceberg.analytics."events_daily_by_tenant$snapshots"
ORDER BY committed_at DESC;
```

The `$snapshots` metadata of the MV's storage table is the cleanest way to answer "when did this MV last refresh?" — one snapshot per `REFRESH MATERIALIZED VIEW` call, with `operation = 'append'` for incremental refreshes and `operation = 'overwrite'` (or `delete` + `append` pair) for full refreshes.

---

## 3. REFRESH MATERIALIZED VIEW — what it actually does, and what it does NOT

### 3.1 The command

```sql
REFRESH MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant;
```

That's it. There are no parameters, no `INCREMENTAL` / `FULL` keyword, no `WAIT` flag. Trino decides incremental vs full automatically.

### 3.2 Refresh mode selection — automatic, decided per call

| Condition | Mode chosen | Why |
|---|---|---|
| All source tables are Iceberg, query shape allows delta computation | **Incremental** | Trino diffs `current_snapshot_id` vs `last-recorded snapshot_id` per source, computes the delta, appends to the storage table |
| Any source is non-Iceberg (Postgres, MySQL, Hive — i.e., a federated MV) | **Full** | Non-Iceberg sources don't expose snapshot-ids; no delta available; must delete + recompute |
| Query shape is incompatible (recursive CTEs, complex window functions, full outer joins with non-Iceberg sides) | **Full** | Trino can't prove the delta semantics are correct |

**Operational consequence:** an incremental refresh of a 200M-row table is fast (seconds to minutes if today's partition is a few million new rows). A full refresh of the same MV re-runs the entire 200M-row aggregation. **The first refresh after `CREATE MATERIALIZED VIEW` is always full** (no prior snapshot-ids to diff against).

### 3.3 What `REFRESH MATERIALIZED VIEW` does, step by step

1. **Resolves the MV's source tables and reads each one's current `snapshot_id`** from HMS metadata.
2. **Compares each source's current snapshot_id with the one recorded at last refresh.** If all unchanged → no work to do (idempotent; refresh returns quickly with no new storage-table snapshot). If some advanced → proceed.
3. **Decides incremental vs full** per the table above.
4. **Re-executes the underlying SELECT** (incremental: with delta predicates added; full: as-written) and writes the result into the **storage table**. Each refresh creates one new Iceberg snapshot on the storage table.
5. **Records the new source snapshot_ids in the MV metadata.** These become the baseline for the next freshness check.

### 3.4 What `REFRESH MATERIALIZED VIEW` does NOT do

- **It does NOT run automatically.** There is no `REFRESH INTERVAL` clause, no Trino-side scheduler, no cron daemon inside the coordinator. If your dashboard is stale, it's because nothing ran the REFRESH command.
- **It does NOT block reads of the MV.** Refresh is atomic at the Iceberg-snapshot level on the storage table — readers see either the pre-refresh snapshot or the post-refresh snapshot, never a half-written state.
- **It does NOT auto-expire old snapshots of the storage table.** Each refresh leaves a snapshot on the storage table. Two catalog properties bound this growth (see Section 6.3):
  - `iceberg.materialized-views.refresh-max-snapshots-to-expire` — at most this many old MV-storage-table snapshots are expired per refresh (default **200**).
  - `iceberg.materialized-views.refresh-snapshot-retention-period` — older than this and they become candidates (default **4 hours**).
- **It does NOT propagate source-schema changes automatically.** If a column is added to the underlying table, the MV does not pick it up until you `CREATE OR REPLACE MATERIALIZED VIEW` with the new SELECT shape.
- **It does NOT magically make slow underlying queries fast.** A full refresh is **exactly as expensive as running the underlying SELECT once**. The win is amortizing that cost across many subsequent dashboard reads, not the refresh itself being cheap.

### 3.5 Scheduling the refresh — patterns for this stack

OSS Trino has no built-in scheduler. On the on-prem k8s + dbt stack described in `prod_info.md`, the three reasonable patterns are:

| Pattern | Looks like | When to choose |
|---|---|---|
| **k8s CronJob** | A small container running `trino --execute "REFRESH MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant"` on a cron schedule | Default. Lowest ceremony. One CronJob per MV (or one CronJob that iterates a list of MVs from a ConfigMap) |
| **dbt operation / post-hook** | A dbt project with a `run-operation` that issues the REFRESH; called from `dbt run --select tag:hourly_refresh` in a CronJob | You already have a dbt project orchestrating other transformations and want the MV refresh under the same monitoring umbrella |
| **Airflow `TrinoOperator` task** | An Airflow DAG with one task per MV; dependencies between MVs (e.g., the per-tenant MV refreshes only after the daily-fact MV refreshes) | You already run Airflow and need cross-MV dependencies / DAG-level retry / SLA monitoring |

The CronJob is the right starting point — only escalate to dbt-operation or Airflow if you genuinely need the orchestration features. Whichever you pick, **monitor the refresh duration** (per `$snapshots`): if the refresh is starting to take longer than the interval between refreshes, you have a runaway and need to switch to incremental, partition the source, or move the heavy aggregation to a Spark/dbt pipeline.

---

## 4. Freshness, staleness, GRACE PERIOD, and WHEN STALE — the read-time behavior

This is the part engineers most often get wrong, and it's the part the iter408 punt left on the table.

### 4.1 How Trino decides "fresh" vs "stale" at read time

When a query references the MV, the optimizer (per Trino 481 docs):

1. Loads the storage-table snapshot_id and the recorded source snapshot_ids from MV metadata.
2. Compares each source's **current** snapshot_id (the one HMS currently points at) with the recorded value.
3. **All match → MV is FRESH.** Read the storage table directly. Cheap.
4. **Some advanced → MV is STALE.** Now `GRACE PERIOD` and `WHEN STALE` decide what happens next.

This is **snapshot-id based**, not time-based. A stale MV becomes fresh again if (and only if) you refresh it. Wall-clock time only matters via `GRACE PERIOD` (which is a *grace window past the refresh*, not a TTL).

### 4.2 GRACE PERIOD — the grace window past the last refresh

`GRACE PERIOD INTERVAL '<n>' <unit>` says: "for `<n>` <units> after the last refresh, keep using the storage table even if sources have advanced." It is an **opt-in window of staleness tolerance**.

| `GRACE PERIOD` setting | Behavior at read time |
|---|---|
| Not specified (default = infinity) | The MV serves the cached storage table **indefinitely** until manually refreshed, regardless of whether sources have advanced. **Stalest mode possible — use only if you understand it.** |
| `INTERVAL '15' MINUTE` | Within 15 minutes of the last successful refresh, serve cache (treat as fresh). After 15 minutes, if sources have advanced, switch to `WHEN STALE` behavior |
| `INTERVAL '0' SECOND` | Effectively "no grace": as soon as any source advances, treat as stale and apply `WHEN STALE` |

**Practical setting for dashboards:** `GRACE PERIOD INTERVAL '90' MINUTE` if you run REFRESH every hour — the extra 30 minutes covers occasional refresh-job delays without immediately falling through to the heavy query.

### 4.3 WHEN STALE — what happens once the MV is stale AND past grace

| `WHEN STALE` value | Read-time behavior when stale & past grace |
|---|---|
| `INLINE` (default) | The MV is **expanded into the underlying SELECT** — Trino runs the original query against live sources and returns up-to-date data. The dashboard slows down (back to running the full aggregation) but stays correct |
| `FAIL` | The query against the MV **errors out** — "materialized view is stale." The dashboard breaks until someone runs `REFRESH MATERIALIZED VIEW` |

`INLINE` is the safe production default — it degrades gracefully. `FAIL` is only useful when you'd rather a dashboard show "data unavailable" than "slow but correct" — e.g., when the underlying source query is so expensive that running it interactively would harm cluster stability more than a downed dashboard would.

### 4.4 The Iceberg-only smart shortcut (this is the subtle bit)

From the Iceberg connector docs: "if all tables are Iceberg tables, the connector can determine if the data has not changed and continue to use the data from the storage tables, **even after the grace period expired**."

What this means in practice:

- **All-Iceberg MV, no source changes since last refresh:** Even past the grace period, Trino keeps serving from the storage table. The MV is "stale by clock" but proven-unchanged-by-snapshot-ids, so no fallthrough.
- **All-Iceberg MV, source has advanced past grace period:** Falls through per `WHEN STALE`.
- **Federated MV (one or more non-Iceberg sources) past grace period:** Falls through every time — Trino can't prove non-Iceberg sources haven't changed (Postgres doesn't expose snapshot-ids Trino can diff against).

This is why **pure-Iceberg MVs are dramatically more cache-efficient than federated ones**: they get the snapshot-id-proven-fresh shortcut, federated MVs do not.

### 4.5 The four read-time outcomes — at-a-glance

| Source change since refresh? | Within grace period? | All sources Iceberg? | Read-time behavior |
|---|---|---|---|
| No | (any) | (any) | **Serve from storage table** (fresh) |
| Yes | Yes | (any) | **Serve from storage table** (grace) |
| Yes | No | Yes (and snapshot diff shows no actual change to query result) | **Serve from storage table** (Iceberg shortcut) |
| Yes | No | No, or actual change detected | **Apply `WHEN STALE`** — INLINE (fall through to source) or FAIL (error) |

---

## 5. Decision guide — Trino MV vs dbt rollup vs Redis cache

This is the question SaaS engineers actually need answered: "I have a slow dashboard aggregation. Which of these three patterns do I use?" The honest answer depends on three axes: **freshness SLO**, **query shape complexity**, and **operational model**.

### 5.1 The dashboard-aggregations worked example

Concrete setup: per-tenant dashboard at `/dashboards/tenant/:id` shows "events per day for last 30 days, broken down by event type." Backed by an 800M-row Iceberg `events` table, ~250 tenants, dashboard hit by ~20 internal users every weekday morning. Current pain: page-load runs the full GROUP BY, takes 18 seconds, Postgres-backed app times out at 10s.

The three options laid out:

| Pattern | What it looks like in code | Freshness | Operational cost | Right when |
|---|---|---|---|---|
| **Trino MV on Iceberg** | `CREATE MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant ... ; REFRESH MATERIALIZED VIEW ...` scheduled hourly via k8s CronJob. Dashboard hits `SELECT * FROM iceberg.analytics.events_daily_by_tenant WHERE tenant_id = ?` | Up to 1h stale (refresh cadence) | One k8s CronJob to manage, plus Iceberg-maintenance on the storage table (`optimize` / `expire_snapshots` weekly) | The aggregation is a fixed-shape SELECT that lives entirely in Iceberg, you don't need MERGE or watermarked incremental logic, and you want the lowest-ceremony Trino-native option |
| **dbt rollup table** | A dbt model `events_daily_by_tenant.sql` with `{{ config(materialized='incremental', unique_key=['event_date','tenant_id','event_type']) }}` + an incremental MERGE. Scheduled as `dbt run --select events_daily_by_tenant` in a CronJob. Dashboard queries the resulting Iceberg table directly | Up to 1h stale (run cadence) | dbt project / CI / docs, plus Iceberg-maintenance on the rollup table | You already have a dbt project and want the rollup to participate in dbt's lineage / docs / tests, OR the rollup logic needs MERGE / watermarked incremental / multi-step lineage that Trino MV refresh doesn't natively handle |
| **App-side cache (Redis)** | App code: `cache_key = f"dash:{tenant_id}:{date_bucket}"`. On miss, run the Trino query, write result JSON to Redis with TTL 5min. Dashboard hits Redis first, Trino on miss | Sub-minute stale (TTL) | Redis cluster + cache-invalidation logic in app code | The result is small (kilobytes per tenant, not megabytes), the dashboard is read-mostly with high QPS, and freshness SLO is sub-minute — too tight for a refresh-job cadence |

### 5.2 Pick-by-axis decision matrix

| If your primary constraint is... | Pick |
|---|---|
| **Freshness SLO > 5 minutes**, fixed-shape SQL, no MERGE/multi-step lineage | **Trino MV** (lowest ceremony) |
| **Freshness SLO > 5 minutes**, needs MERGE / dbt lineage / multi-step transformations | **dbt rollup** |
| **Freshness SLO < 5 minutes**, result is small per request (KB-MB), high QPS | **Redis cache** |
| **Freshness SLO is sub-second** | **None of these — query Postgres directly, or use a streaming materialized-view layer (Flink, Materialize). Beyond the scope of this stack.** |
| Need both a fresh stable analytical surface AND ad-hoc drill-down | **dbt rollup for the surface + a regular Iceberg dimension for drilldown.** Build the rollup, expose it to the dashboard, leave the source table queryable for drill-down |

### 5.3 What about combining them?

The patterns layer cleanly:

- **Trino MV → Redis** is the right combo for a busy dashboard: MV refresh hourly, Redis TTL 5 minutes, app falls through Redis → MV → underlying SELECT (in that order). The MV absorbs the heavy aggregation cost once an hour; Redis absorbs the high-QPS hot reads.
- **dbt rollup → Redis** is the same shape with dbt managing the rollup table.
- **Trino MV → Trino MV** is technically possible (an MV's underlying SELECT references another MV) but adds refresh-dependency complexity and is rarely worth it — refactor the aggregation into one MV instead.

### 5.4 Anti-patterns to avoid

- **"Trino MV as a substitute for streaming."** MVs are refresh-driven, not change-driven. If you need second-by-second freshness, an MV is not the answer; investigate a streaming engine outside this stack.
- **"Trino MV with `GRACE PERIOD` unset, refreshed once and never again."** The default GRACE PERIOD is infinity — your dashboard will silently keep serving 3-month-old data with no warning. Always set an explicit GRACE PERIOD in production.
- **"Trino MV with non-Iceberg sources for an incremental-heavy workload."** Federated MVs always do full refresh — they don't get the incremental-delta savings. For federated patterns, the dbt rollup pattern is often cheaper (you can implement watermarked incremental against the federated source yourself).
- **"Trino MV with no maintenance schedule on the storage table."** The storage table is a real Iceberg table — it accumulates snapshots, manifests, orphan files. Run the standard maintenance pattern (`optimize` daily, `expire_snapshots` + `remove_orphan_files` weekly) on it, just like any other Iceberg table.

---

## 6. Operational concerns specific to this on-prem k8s stack

### 6.1 The storage table needs Iceberg maintenance — don't forget it

Every `REFRESH MATERIALIZED VIEW` creates a new snapshot on the storage table. A daily-refreshed MV running for a year accumulates 365 snapshots; an hourly-refreshed MV accumulates 8,760. Apply the same maintenance pattern as for any Iceberg table (resource 17):

- **`ALTER TABLE iceberg.analytics."<mv_name>" EXECUTE optimize`** — if the storage table is partitioned and refresh creates many small files per partition, run weekly.
- **`ALTER TABLE iceberg.analytics."<mv_name>" EXECUTE expire_snapshots(retention_threshold => '7d')`** — weekly, keeps the metadata footprint bounded.
- **`ALTER TABLE iceberg.analytics."<mv_name>" EXECUTE remove_orphan_files(retention_threshold => '7d')`** — weekly. (Note: per resource 17, `remove_orphan_files` from Spark is preferred when available because Trino doesn't support `dry_run`.)

Reference the storage table by the MV name itself — Trino routes `ALTER TABLE iceberg.<schema>.<mv_name> EXECUTE optimize` to the storage table behind the scenes.

### 6.2 OPA / authz applies at two levels

- **End-user queries against the MV** need `SELECT` on the view name and the storage table (and `SELECT` on the underlying sources is NOT required if the MV is fresh — reads go straight to the storage table). When the MV falls through to source on stale + INLINE, the user's identity is still used for the underlying SELECT, so source-table SELECT permission IS required for fallthrough.
- **The service principal running `REFRESH MATERIALIZED VIEW`** needs `INSERT` and `DELETE` on the storage table, plus `SELECT` on every underlying source. Grant a dedicated `mv_refresher` role in OPA policy with exactly these permissions; don't reuse a generic admin role for refresh CronJobs.

This is a place where the prod_info.md "external governance document" applies — the specific role names and permissions for MV refresh are defined externally. The general shape (separate refresh-service identity, scoped to MV storage tables + source SELECT) is the right pattern; the exact OPA rule lives elsewhere.

### 6.3 Catalog-level configuration knobs (Iceberg connector)

Set in `etc/catalog/iceberg.properties`:

```properties
# Catalog config for Iceberg materialized views (Trino 467+):

# Storage-table snapshot retention during refresh. The connector
# auto-expires old MV-storage-table snapshots during REFRESH to keep
# metadata bounded — these two control HOW it expires.

iceberg.materialized-views.refresh-snapshot-retention-period=4h
# Snapshots older than this are eligible for auto-expiry during REFRESH.
# Default: 4 hours.

iceberg.materialized-views.refresh-max-snapshots-to-expire=200
# Cap on how many snapshots the connector will expire in a single REFRESH.
# Default: 200. Raise if you have a long-running MV with thousands of
# accumulated snapshots and refreshes are timing out on the metadata
# cleanup step.

# Where the auto-generated storage table goes (per-catalog default):
iceberg.materialized-views.storage-schema=analytics_mv_storage
# Optional. If set, all MVs in this catalog put their storage table in
# this schema instead of the same schema as the view definition. Useful
# for separating user-facing views from implementation-detail storage
# tables in OPA policy.
```

### 6.4 Watch out for the "MV behaves differently between cluster restarts" footgun

The MV's snapshot-id state lives in HMS, so cluster restarts don't lose freshness state. But coordinator caches do — first query against a recently-restarted coordinator may re-check freshness from HMS, taking marginally longer than steady-state. Not a real problem; just expect it.

### 6.5 What happens when you `DROP MATERIALIZED VIEW`

`DROP MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant` removes:
- The view definition from HMS.
- The hidden storage table (as a `DROP TABLE`).
- All snapshots and data files in MinIO referenced by the storage table (subject to your normal expire/orphan cleanup cadence).

There's no "drop view but keep storage table" mode in Trino. If you want to preserve the data, first `CREATE TABLE iceberg.analytics.events_daily_by_tenant_archive AS SELECT * FROM iceberg.analytics.events_daily_by_tenant` then drop the MV.

---

## 7. Quick-reference: side-by-side syntax

| Task | Trino syntax |
|---|---|
| Create MV with grace period and partitioned storage | `CREATE MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant GRACE PERIOD INTERVAL '90' MINUTE WHEN STALE INLINE WITH (format='PARQUET', partitioning=ARRAY['event_date']) AS SELECT ...` |
| Refresh manually | `REFRESH MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant;` |
| Inspect last-refresh time | `SELECT MAX(committed_at) FROM iceberg.analytics."events_daily_by_tenant$snapshots";` |
| Show definition | `SHOW CREATE MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant;` |
| List all MVs in a catalog | `SELECT * FROM system.metadata.materialized_views WHERE catalog_name = 'iceberg';` |
| Change underlying query (keep name) | `CREATE OR REPLACE MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant ... AS SELECT ...` — note: may drop+recreate the storage table; pause refresh job during this |
| Drop MV (and storage table) | `DROP MATERIALIZED VIEW iceberg.analytics.events_daily_by_tenant;` |
| Maintenance on the storage table | `ALTER TABLE iceberg.analytics.events_daily_by_tenant EXECUTE optimize;` (use the MV name — Trino routes to storage) |

---

## 8. Key terms (alphabetical, plain-English)

- **Full refresh** — REFRESH mode that deletes all storage-table data and rewrites it from a complete re-execution of the underlying SELECT. Always used when any source is non-Iceberg or the query shape can't be incrementalized. Same cost as running the SELECT once.
- **GRACE PERIOD** — An optional clause on `CREATE MATERIALIZED VIEW`. Defines how long after the last refresh the cached data is served *even if sources have advanced*. Default infinity (always serve cache).
- **Incremental refresh** — REFRESH mode that diffs source-table snapshot-ids and appends only the deltas to the storage table. Available only when all sources are Iceberg and the query shape supports it. Much cheaper than full refresh for large fact tables.
- **Materialized view (in Trino)** — A view whose result is cached in a real Iceberg table (the "storage table"). Reads hit the cache; refreshes are manual via `REFRESH MATERIALIZED VIEW`. **Iceberg-connector only in OSS Trino 467.**
- **REFRESH MATERIALIZED VIEW** — The SQL command that re-executes the underlying query and updates the storage table. Trino picks incremental vs full automatically. No auto-schedule; you trigger it externally (cron, dbt, Airflow).
- **Snapshot-id-based freshness** — Trino tracks the source tables' `snapshot_id` at refresh time and compares against current on read. If unchanged, MV is fresh; if any advanced, MV is stale (then GRACE PERIOD + WHEN STALE decide what to do). Time-based-only logic is not the model.
- **Stale (MV state)** — A source's snapshot_id has advanced past the value recorded at last refresh. Combined with grace period and WHEN STALE, determines whether the read serves cache, falls through to source, or fails.
- **Storage table** — The hidden Iceberg table backing the MV. Real Iceberg table in MinIO with snapshots, manifests, Parquet files. Needs the same maintenance (optimize / expire / orphan) as any other Iceberg table.
- **WHEN STALE** — Clause on `CREATE MATERIALIZED VIEW` that says what happens once MV is stale AND past grace period. Options: `INLINE` (fall through to underlying query, default) or `FAIL` (error out). No `REFRESH` option exists.

---

## 9. Sources verified against (Trino 481 docs, accurate for 467 too)

- `https://trino.io/docs/current/connector/iceberg.html` — Iceberg connector docs, materialized views section
- `https://trino.io/docs/current/sql/create-materialized-view.html` — `CREATE MATERIALIZED VIEW` SQL syntax
- `https://trino.io/docs/current/sql/refresh-materialized-view.html` — `REFRESH MATERIALIZED VIEW` SQL syntax

For federation + MV interactions (Postgres × Iceberg MVs), see resource 22 section 7.6.
For Iceberg maintenance on the MV storage table, see resource 17.
For when to materialize at all vs other patterns, see resource 06.
