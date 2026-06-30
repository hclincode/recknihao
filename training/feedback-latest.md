# Judge Feedback — Iteration 1298

**Overall: 4.5625 — PASS. Pure breadth round. Q1 (date_diff('month', signed_up_at, current_timestamp) day-aware drops-fractional canonical, 45 days = 1 month) 5.0 STRONG; Q3 (dbt model versioning 1.6+, `_v1`/`_v2` suffix files, `latest_version` YAML, `ref('m', v=N)`, latest gets unsuffixed alias, `deprecation_date` sunset) 5.0 STRONG; Q4 (Trino has no DUAL — drop FROM; `VALUES(1)` dummy if needed; SYSDATE→current_timestamp; TRUNC(SYSDATE)→date_trunc('day',...); AT TIME ZONE for local-tz; session-tz vs Oracle OS-tz contrast) 5.0 STRONG; Q2 (3.25 INDIVIDUAL FAIL) is the lone drag — TWO-PART per-instance slip: (a) completeness gap (engineer EXPLICITLY asked to inspect "the table's FILE LAYOUT or METADATA to see which files got scanned vs which should have been skipped" — the direct Trino 467 answer is the Iceberg metadata tables `<table>$files` (per-data-file path/size/record_count/partition) and `<table>$partitions` (per-partition file_count/record_count/total_size + partition column min/max), which the responder did NOT mention at all and pivoted entirely to EXPLAIN ANALYZE — a valid secondary lens for "is pruning happening at plan time" but NOT the file-layout inspection the engineer asked for); (b) technical conflation between partition pruning and sorting via a "Before sort: 500GB / After sort by partition column: 2GB" example — partition pruning is driven by `day(partition_col)` transform + WHERE-on-partition-col, NOT by sorting. EXPLAIN ANALYZE constraint-annotation-on-TableScan = pushdown signal IS technically correct (verified via [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/current/sql/explain-analyze.html) — the constraint pushdown shows up as a filterPredicate / constraint annotation on the ScanFilterProject operator). Resource findability check: `$files`/`$partitions` content IS in resources (r10×42 hits, r17×85, r18×17, r05×58, r28×5) — content present, responder didn't reach it under the "file layout / which files scanned" entry-keywords. Per-instance slip on first occurrence; NEW SOFT WATCH only, NO FIX-A. Continuous PASS-loop holds (iter1297 4.547 → iter1298 4.5625, +0.0155). All required topics REMAIN PASSED.**

| Q | Score | Acc | Clar | Prac | Compl | Topic | Result |
|---|---|---|---|---|---|---|---|
| 1 | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 | Analytical query patterns on Iceberg+Trino | STRONG PASS |
| 2 | 3.25 | 3.5 | 4.0 | 3.0 | 2.5 | Query performance regression diagnosis (file layout) | INDIVIDUAL FAIL |
| 3 | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 | Improving complex SQL performance on Trino with dbt | STRONG PASS |
| 4 | 5.0 | 5.0 | 5.0 | 5.0 | 5.0 | Oracle PL/SQL → dbt + Trino SQL migration | STRONG PASS |

## Q1 — `date_diff('month', signed_up_at, current_timestamp)` — 5.0 STRONG PASS

**Responder gave the canonical Trino 467 day-aware tenure-in-months form:**

```sql
SELECT
  customer_id,
  date_diff('month', signed_up_at, current_timestamp) AS tenure_months
FROM customers;
```

Returns BIGINT complete-units; drops fractional months (day-aware: 45 days = 1 month, NOT 2; Jan-15 to Feb-14 = 0; Jan-15 to Feb-15 = 1). MONTHS_BETWEEN (Oracle/Snowflake) maps to `date_diff('month', ...)` in Trino (Oracle MONTHS_BETWEEN returns a NUMBER fractional while date_diff returns BIGINT complete-units — responder did not surface the fractional-vs-integer return-type contrast but the engineer asked for "rounded down" so the integer return is exactly what they want).

**Verified via pinned `reference_trino_datediff_dayaware`** (git-tag DateTimeFunctions.java 467): date_diff('month'/'year'/etc) is day-aware complete-units, drops fractional. Pin-aligned. **Verified via WebFetch of [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)**: date_diff returns BIGINT, "expressed in terms of unit". Direct match.

Acc 5.0 (function name + arg order + day-aware semantics + return type all correct + matches pin), Clar 5.0 (clean one-liner), Prac 5.0 (copy-pasteable), Compl 5.0 (could add `MONTHS_BETWEEN` returns fractional NUMBER while date_diff returns BIGINT complete-units, but "rounded down" was the engineer's exact phrasing so integer is what they want; not a load-bearing omission).

No imported-prior, no broken-secondary, no over-warning, no fabrication. Analytical query patterns on Iceberg+Trino topic 4.4789/211 → **4.4809/212 PASSED** (+0.0020, margin +0.9809).

## Q2 — Iceberg partition pruning + file layout inspection — 3.25 INDIVIDUAL FAIL

**The DEFECT — two-part slip on the file-layout-inspection framing.**

Engineer: "Iceberg 500M rows partitioned by day; one-week filter still took 8 min. How do I inspect the table's FILE LAYOUT or METADATA to see which files got scanned vs which should have been skipped?"

Responder went straight to EXPLAIN ANALYZE:
- `EXPLAIN ANALYZE SELECT COUNT(*) ... WHERE day_partition >= DATE ... AND < DATE ...;`
- Find the TableScan node; look at Input: rows/bytes (bytes read from MinIO)
- A `constraint = day_partition >= ...` annotation INSIDE the TableScan = pruning IS working
- Plan shows number of files read
- Compared "Before sort/optimization: 500GB vs After sort by partition column: 2GB"
- Framed constraint annotation as "Trino's predicate-pushdown signature (unlike Spark PushedFilters)"

**PART A — COMPLETENESS GAP**: the engineer's EXPLICIT cue was "inspect the table's FILE LAYOUT or METADATA" — the canonical Trino 467 entry-point for this is the Iceberg metadata tables, NOT the planner. **Verified via WebFetch of [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/current/connector/iceberg.html)** this iter:

- `<schema>."<table>$files"` — per-data-file: `file_path`, `file_size_in_bytes`, `record_count`, `partition` (mapping of partition column names to values), `file_format`, `column_sizes` (Iceberg column ID → byte size)
- `<schema>."<table>$partitions"` — per-partition aggregate: `partition` mapping, `file_count` (files in partition), `record_count`, `total_size` (bytes of all files in partition), `data` (min/max + null counts per partition column)
- Also `$snapshots`, `$manifests`, `$history`, `$properties`, `$metadata_log_entries`, `$refs` all exposed

For an 8-min one-week query where pruning IS working at plan-time, the natural file-layout diagnosis is:

```sql
-- Per-partition aggregate: small-files / fat-partitions in the 7 days?
SELECT partition, file_count, record_count, total_size, total_size/file_count AS avg_file_bytes
FROM iceberg.analytics."events$partitions"
WHERE <partition-day in the queried week>
ORDER BY file_count DESC;

-- Per-data-file inspection if a partition looks off (delete-file rewrite candidates, etc.)
SELECT file_path, file_size_in_bytes, record_count
FROM iceberg.analytics."events$files"
WHERE <partition column> = DATE '2024-...'
ORDER BY file_size_in_bytes ASC;
```

For 500M rows × 7 days, file_count >> 1 per day or avg_file_bytes << 64MB strongly suggests small-files inflation (one of the most common "pruning works but still slow" root causes). Responder mentioned none of this.

**PART B — TECHNICAL CONFLATION**: the "Before sort: 500GB vs After sort by partition column: 2GB" example **conflates sorting with partition pruning**. These are TWO DIFFERENT mechanisms:

1. **Partition pruning** is driven by `day(partition_col)` (or equivalent identity/transform) + WHERE-on-partition-col at PLAN time. The metadata.json + manifests carry partition-summary stats; the planner skips partitions whose summary doesn't satisfy the WHERE predicate. Sorting plays NO role here.
2. **Within-file data skipping** (the "sort by partition column" framing implies this) is a different mechanism — Parquet row-group min/max statistics let Trino skip row groups inside a data file that don't satisfy the predicate. Sorting by the WHERE column CAN improve this for non-partition columns (locality of values within row groups).

Sorting by the partition column ITSELF does effectively nothing for partition pruning because the day() transform already groups data into per-day files; what the responder described as "After sort by partition column: 2GB" is actually what `day()` partitioning + a WHERE predicate gives you at plan time, with no sort.

**PART C — what IS correct in the responder's answer**: the EXPLAIN ANALYZE + TableScan + constraint annotation framing IS a legitimate secondary lens for "is the planner pushing my predicate down" (verified at [trino.io/docs/467/sql/explain-analyze.html](https://trino.io/docs/current/sql/explain-analyze.html) — the ScanFilterProject operator shows the pushed-down predicate). For a "did pruning happen" verification at PLAN time it's fine. Where it falls short is the engineer asked about FILE LAYOUT (storage layer), not the plan; EXPLAIN ANALYZE shows you bytes/rows scanned but doesn't surface which specific files / which partitions / why each partition was the size it was.

**Resource findability check**: `$files` / `$partitions` content IS plentiful in resources — r10 (lakehouse-partitioning) 42 hits, r17 (iceberg-table-maintenance) 85 hits, r18 (query-performance-regression) 17 hits, r05 (multi-tenant-analytics) 58 hits, r13 (postgres-to-iceberg) 9, r28 (complex-sql-perf) 5, r22 federation 3, r16 cost-considerations 13, r11 storage-sizing 9. The content IS findable in principle but the responder did not reach it under the engineer's specific "FILE LAYOUT / METADATA inspection of a slow partitioned one-week query" entry-keywords. The responder's EXPLAIN ANALYZE pivot suggests the "slow query diagnosis" keyword routing dominated over the "file layout / metadata" keyword.

**Classification**: per-instance findability + technical-conflation slip on the file-layout-inspection framing. NOT a resource defect (content is present + correct in r10/r17/r18). Per pinned `feedback_synthesis_ceiling_stop_churning.md` discipline + `feedback_new_card_over_attracts_adjacent.md` regression risk: NO FIX-A on first occurrence; SOFT WATCH only.

**NEW SOFT WATCH `iter1298-Q2 metadata-tables-for-file-layout + sort-vs-pruning-conflation`**: re-probe 4-8 iters under "inspect file layout / which files scanned / Iceberg metadata tables on slow partitioned query / verify partition pruning happened" framings; if 2+ recurrences escalate to LIGHT FIX-A reconcile-in-place at r18 §perf-triage or r10 §partition-design to add a leading routing card ("engineer asked for 'file layout' / 'which files scanned' / 'metadata' → reach for `$files` + `$partitions` first, EXPLAIN ANALYZE second"). Watch the sort-vs-pruning conflation as a separate axis — re-probe under "should I sort my partitioned table to make pruning faster" framings to see if the framing recurs as an active error or was just per-instance imprecise language.

Acc 3.5 (EXPLAIN ANALYZE + constraint annotation IS correct for plan-time pushdown verification; the sort-vs-pruning conflation is a technical error worth flagging; the file-count-from-plan reference is correct but limited), Clar 4.0 (readable, but the sort-vs-pruning framing muddles the mental model), Prac 3.0 (engineer who asked for FILE LAYOUT got a planner answer; for the 8-min real diagnostic they would not reach the small-files-in-7-partitions root cause via EXPLAIN ANALYZE alone), Compl 2.5 ($files/$partitions metadata tables — the canonical Trino 467 file-layout-inspection answer — completely omitted).

Query performance regression diagnosis topic 4.1286/25 → **4.0948/26 PASSED** (−0.0338, margin +0.5948 — thinnest near-bottom passing topic remains, but still well above 3.5).

## Q3 — dbt model versioning (1.6+) — 5.0 STRONG PASS

**Responder gave the canonical dbt model-versioning setup:**

```
models/marts/fct_user_activity_v1.sql   -- old logic, materialized as fct_user_activity_v1
models/marts/fct_user_activity_v2.sql   -- new logic for new segment, materialized as fct_user_activity_v2 AND aliased as fct_user_activity (latest)
```

```yaml
# models/marts/_schema.yml
models:
  - name: fct_user_activity
    latest_version: 2
    versions:
      - v: 2
        config:
          materialized: table
      - v: 1
        config:
          materialized: table
        deprecation_date: '2025-03-31'   # announce sunset
```

```sql
-- Downstream consumers
{{ ref('fct_user_activity') }}          -- → latest (v2)
{{ ref('fct_user_activity', v=1) }}     -- → pinned to v1
{{ ref('fct_user_activity', v=2) }}     -- → pinned to v2
```

Lifecycle: Trino materializes BOTH `_v1` + `_v2` tables; `latest_version` gets the unsuffixed alias `fct_user_activity` so unpinned `ref()` consumers get the latest. After `deprecation_date`, delete `_v1.sql` to remove the old version.

**Verified via WebFetch of [docs.getdbt.com/docs/collaborate/govern/model-versions](https://docs.getdbt.com/docs/collaborate/govern/model-versions)** this iter — every responder claim matches docs verbatim:
- Introduced in dbt Core 1.6 with `deprecation_date` as first-class
- `_v<version>` suffix file naming required
- `latest_version` YAML defaults to numerically-highest if unspecified; only ONE latest at a time
- `ref('model', v=N)` pinning syntax (also `version=N` long form)
- Unpinned `ref('model')` → latest_version
- Lifecycle table (prerelease/latest/old): latest version aliased with unsuffixed relation name; old version materializes only as `_v<N>`
- `deprecation_date` announces sunset; consumers receive warnings before that date

Acc 5.0 (dbt-core 1.6+ correct, file-suffix correct, latest_version + versions YAML correct, ref(v=N) correct, unsuffixed-alias behavior correct, deprecation_date correct), Clar 5.0 (clean two-file + YAML + ref-usage walk-through), Prac 5.0 (engineer knows exactly how to create v2 without breaking v1 consumers), Compl 5.0 (covered file naming + YAML config + ref pinning + deprecation lifecycle; could mention `dbt run --select fct_user_activity.v2` selector + `version:latest` selector but not load-bearing).

No imported-prior, no broken-secondary, no over-warning, no fabrication. Improving complex SQL performance on Trino with dbt topic 4.4602/93 → **4.4660/94 PASSED** (+0.0058, margin +0.9660).

## Q4 — Oracle DUAL → Trino — 5.0 STRONG PASS

**Responder gave the canonical Trino-no-DUAL migration map:**

- **Trino has NO DUAL** — drop `FROM DUAL` entirely
- `SELECT 1 FROM DUAL` → `SELECT 1;`
- `SELECT SYSDATE FROM DUAL` → `SELECT current_timestamp;`
- `SELECT TRUNC(SYSDATE) FROM DUAL` → `SELECT date_trunc('day', current_timestamp);` or `SELECT current_date;`
- If a row-source FROM is genuinely needed: `SELECT 1 FROM (VALUES (1)) AS t(x)`
- ET version: `SELECT current_timestamp AT TIME ZONE 'America/New_York';`

Semantic caveat (responder surfaced): `current_timestamp` is **session-TZ-aware** — returns `timestamp(3) with time zone` scoped to the session timezone (set via session property or JDBC connection). Oracle `SYSDATE` returns the **database server's OS-local time without TZ info** — these differ when the user's session timezone differs from the DB server's OS timezone. For UTC-anchored values, use `current_timestamp AT TIME ZONE 'UTC'`.

**Verified at [trino.io/docs/467/functions/datetime.html](https://trino.io/docs/current/functions/datetime.html)** + [trino.io/docs/467/sql/select.html](https://trino.io/docs/current/sql/select.html): current_timestamp returns timestamp(3) with time zone; AT TIME ZONE conversion documented; FROM clause is in square brackets in the SELECT synopsis = optional. The current_timestamp / current_date / current_time set is well documented + standard SQL. VALUES is a valid row-source.

Acc 5.0 (no DUAL correct, optional FROM correct, VALUES(1) dummy correct, SYSDATE→current_timestamp correct, TRUNC→date_trunc('day') correct, AT TIME ZONE conversion correct, session-TZ vs OS-TZ contrast correct), Clar 5.0 (clean parallel Oracle/Trino mapping), Prac 5.0 (engineer's existing Oracle migration patterns map directly), Compl 5.0 (covered DUAL elimination + SYSDATE + TRUNC + AT TIME ZONE + session-vs-OS semantics; could add `current_date` returns DATE not TIMESTAMP and `SYSTIMESTAMP` Oracle equivalent → current_timestamp for fractional seconds + TZ, but minor recall ceiling).

No imported-prior assumed-absence (responder did not wrongly claim DUAL might exist in Trino or that FROM is required), no broken-secondary, no over-warning, no fabrication. Oracle PL/SQL → dbt + Trino SQL migration topic 4.4982/271 → **4.5000/272 PASSED** (+0.0018, margin +1.0000).

## Carries / Watches

- **NEW SOFT WATCH `iter1298-Q2 metadata-tables-for-file-layout + sort-vs-pruning-conflation`**: re-probe 4-8 iters under "inspect file layout / which files scanned / Iceberg metadata tables on slow partitioned query / verify partition pruning" framings; LIGHT FIX-A at 2+ recurrences (r18 §perf-triage or r10 §partition-design reconcile-in-place: leading routing card "FILE LAYOUT / WHICH FILES → reach for `$files` + `$partitions` first; EXPLAIN ANALYZE second"; defang sort-vs-pruning conflation).
- CARRY iter1297-Q4 Oracle-GROUP-BY-leniency false-premise endorsement.
- CARRY iter1296-Q1 CONTAINS+GROUP-BY-no-bool_or secondary.
- CARRY iter1296-Q3 singular-test-omitted.
- CARRY iter1295-Q2 FIRST_VALUE-priming.
- CARRY iter1294-Q4 ROWNUM-per-group.
- CARRY iter1290-Q3 small-files-routing.
- CARRY iter1289-Q2 position-delete-Spark-vs-Trino.
- CARRY iter1289-Q4 LPAD-RPAD-false-divergence.
- CARRY iter1284-Q1 perf-triage queries-JOIN-tasks recipe (HARD→SOFT downgraded; every 8-12 iters).
- CARRY iter1284-Q3 delete+insert-not-built-in slip.

## Pattern observation

Continuous PASS-loop holds (iter1297 4.547 → iter1298 4.5625, +0.0155). Q1/Q3/Q4 all clean 5.0 STRONG with pin-aligned canonicals reaching cleanly on first sweep — date_diff-day-aware, dbt-model-versioning-1.6+, no-DUAL/AT-TIME-ZONE — three of the most stable canonical reach patterns in the current set. Q2 is the lone drag: a TWO-PART per-instance slip (findability + technical conflation) on an unusual "FILE LAYOUT inspection" framing that is the most direct entry-point for `$files`/`$partitions` reach. Resource content IS plentiful for metadata-tables across 9 files but doesn't anchor under the specific "file layout / which files scanned / partition pruning verification" entry-keywords the engineer used. The sort-vs-pruning conflation is concerning if it represents an underlying mental-model confusion in the responder rather than per-instance imprecise language — needs re-probe to disambiguate. NOT urgent (single instance, content present); SOFT WATCH + re-probe pattern is the right discipline per `feedback_synthesis_ceiling_stop_churning.md` (don't churn the resource on first occurrence).

Training in closed-deadline posture (training deadline 2026-06-30 23:59 CST = today). Continuous-PASS-loop preserving the bulletproofed clean-topic set is the dominant strategy; one SOFT WATCH addition + zero resource edits is the appropriate end-of-window stance. ALL required topics REMAIN PASSED.
