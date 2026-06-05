# Judge Feedback — Iter 489

**Phase**: extended (end-of-iteration feedback only)
**Overall**: 4.031 PASS (~0.531 above 3.5 floor; -0.313 below iter488's 4.344)
**Federation**: NOT probed this iter — 4.49944/310 row HELD per iter472-489+ directive

---

## Headline

**iter488 PRIMARY FIX (not_null_proportion + _dbt_test__audit) CONFIRMED LANDED on Q1 first re-probe.** But two regressions hit Q3 and Q4:

- **REGRESSION 1 (Q3)**: `$snapshots` split-quote form returned — `table."$snapshots"` (wrong) instead of `"table$snapshots"` (correct). This was fixed at iter454 and has re-surfaced.
- **REGRESSION 2 (Q4)**: `{% if execute %}` incremental guard returned — this was fixed at iter452 and has re-surfaced.

Both regressions are load-bearing (paste-and-fail or paste-and-wrong-behavior). Q1 and Q2 are clean.

---

## Per-question breakdown

### Q1 — dbt test WARN if >5% null + store_failures re-probe (4.3125 PASS)

**CORE FIX STATUS: CONFIRMED LANDED.**

- `dbt_utils.not_null_proportion: at_least: 0.95` — CORRECT (not expression_is_true with aggregate)
- `config: severity: warn` — CORRECT
- `store_failures_as: table` — CORRECT
- Failures land in `<target_schema>_dbt_test__audit` — CORRECT (`analytics_dbt_test__audit`)
- Explicitly said do NOT use expression_is_true with COUNT aggregate — CORRECT

**MINOR NUANCE INACCURACY (non-load-bearing)**: Responder said store_failures lets you "see exactly which rows were null" and "join back by primary key to identify problematic records." For `not_null_proportion`, the stored failure is the **aggregate proportion result** (one row: the computed proportion value that breached the threshold), NOT the individual null rows. Confirmed via WebFetch of github.com/dbt-labs/dbt-utils/blob/main/macros/generic_tests/not_null_proportion.sql — the macro returns aggregated proportion statistics per group, not individual records with null values. To capture individual null row failures, use the plain `not_null` test with store_failures.

An engineer looking in `_dbt_test__audit` after running this test will find a single proportion value (e.g., `0.07` meaning 7% were null), not a table of individual rows to join back. This is confusing and creates false expectations, but the test still runs correctly.

- Accuracy 4.0 | Clarity 4.5 | Actionability 4.25 | Completeness 4.5
- **Q1 avg: 4.3125**
- Fab status: ZERO load-bearing fabs. One non-load-bearing nuance error on store_failures output semantics.

### Q2 — Trino percentiles p50/p95 over 100M rows (4.8125 STRONG PASS)

- `approx_percentile(col, 0.5)` — CONFIRMED REAL (trino.io/docs/current/functions/aggregate.html)
- Array form `approx_percentile(col, ARRAY[0.5, 0.95, 0.99])` — CONFIRMED REAL
- PERCENTILE_CONT WITHIN GROUP (ORDER BY) — CONFIRMED NOT in Trino docs (only LISTAGG uses WITHIN GROUP in Trino; no PERCENTILE_CONT listed)
- T-Digest / quantile sketch / memory-bounded — CORRECT class of algorithm
- ~2.3% standard error: NOTE — Trino docs explicitly state 2.3% for `approx_distinct` (HyperLogLog), not explicitly for `approx_percentile`. The resource (r23 line 105) contains "approx_percentile uses a quantile-sketch algorithm with 2.3% standard error (per Trino docs)" — responder citing the resource faithfully. This is a resource inaccuracy, not a responder fabrication. Non-load-bearing for this question.
- ZERO responder fabrications.

- Accuracy 4.5 | Clarity 5.0 | Actionability 5.0 | Completeness 4.75
- **Q2 avg: 4.8125**
- Fab status: ZERO responder fabrications.

### Q3 — Iceberg time-travel + diff (3.6875 PASS)

**CONFIRMED REGRESSION on iter454 $snapshots quoting fix.**

Responder used: `FROM iceberg.analytics.your_table_name."$snapshots"`

This is the SPLIT-QUOTE form: the table name and `$snapshots` suffix are separate identifier tokens. Trino parses this as accessing a field named `$snapshots` from the table `your_table_name` — it will produce either a column-not-found error or schema-mismatch error.

Correct form per WebFetch trino.io/docs/current/connector/iceberg.html:
```sql
SELECT snapshot_id FROM example.testdb."customer_orders$snapshots"
```
The WHOLE table name + `$snapshots` suffix together in ONE pair of double quotes, as a single quoted identifier.

This was explicitly documented as the correct form at iter454 and apparently has re-surfaced. The fix is needed in whatever resource contains the `$snapshots` query examples.

FOR VERSION AS OF `<bigint>`, FOR TIMESTAMP AS OF TIMESTAMP, and EXCEPT-diff patterns are all CORRECT.

- Accuracy 3.0 | Clarity 4.5 | Actionability 3.0 | Completeness 4.25
- **Q3 avg: 3.6875**
- Fab status: ONE confirmed regression — split-quote `table."$snapshots"` (iter454 fix re-surfaced).

### Q4 — Oracle ROWNUM pagination + sequence surrogate key → Trino (3.3125 FAIL)

**CONFIRMED REGRESSION on iter452 is_incremental() guard fix.**

Responder used `{% if execute %}` + `{% if 'event_id' in adapter.get_columns_in_relation(this) %}` as the incremental delta guard.

`{% if execute %}` is WRONG as an incremental guard. Confirmed via WebFetch docs.getdbt.com/reference/dbt-jinja-functions/execute + docs.getdbt.com/docs/build/incremental-models:

- `execute` is True whenever dbt compiles WITH a database connection. This includes `dbt compile`, `dbt docs generate`, etc. It does NOT check if the model is running in incremental mode, if the table already exists, or if `--full-refresh` was passed.
- Using `{% if execute %}` would cause the WHERE filter to attempt to run even during `--full-refresh`, and could attempt `SELECT MAX(...) FROM {{ this }}` when the table doesn't exist yet.

The CANONICAL incremental guard is `{% if is_incremental() %}`, which returns True ONLY when:
1. The materialization is `incremental`
2. The model already exists as a table in the database
3. `--full-refresh` was NOT passed

Canonical example from dbt docs:
```sql
{% if is_incremental() %}
  where event_time >= (select coalesce(max(event_time),'1900-01-01') from {{ this }})
{% endif %}
```

ROWNUM→LIMIT/OFFSET table is CORRECT. `dbt_utils.generate_surrogate_key([...])` is CORRECT (idempotent MD5, real macro). `ROW_NUMBER() OVER(ORDER BY...)` for stable-within-run is CORRECT.

- Accuracy 2.5 | Clarity 4.25 | Actionability 2.5 | Completeness 4.0
- **Q4 avg: 3.3125**
- Fab status: ONE confirmed regression — `{% if execute %}` incremental guard (iter452 fix re-surfaced).

---

## Overall score

| Q | Topic | Acc | Clarity | Action | Complete | Avg |
|---|---|---|---|---|---|---|
| Q1 | dbt test severity + store_failures | 4.0 | 4.5 | 4.25 | 4.5 | 4.3125 |
| Q2 | Trino approx_percentile | 4.5 | 5.0 | 5.0 | 4.75 | 4.8125 |
| Q3 | Iceberg time-travel + diff | 3.0 | 4.5 | 3.0 | 4.25 | 3.6875 |
| Q4 | Oracle ROWNUM + surrogate key + incremental | 2.5 | 4.25 | 2.5 | 4.0 | 3.3125 |
| **Overall** | | **3.5** | **4.5625** | **3.6875** | **4.375** | **4.031** |

**PASS** (4.031 > 3.5, margin +0.531)

---

## Core-fix status (iter488 primary)

**CONFIRMED LANDED** — Q1 re-probe confirms:
- `not_null_proportion: at_least: 0.95` correct (not expression_is_true with aggregate)
- `_dbt_test__audit` schema suffix correct (not `dbt_internal`)
- `severity: warn` correct
- `store_failures_as: table` correct
- DO NOT use expression_is_true with COUNT — correctly stated

One non-load-bearing nuance to fix: store_failures on not_null_proportion stores the aggregate proportion row, not individual null rows.

---

## Fabrications / regressions inventory (iter489)

| # | Q | Class | Severity | Correct fact | Source |
|---|---|---|---|---|---|
| 1 | Q3 | REGRESSION — $snapshots split-quote (iter454 fix re-surfaced) | LOAD-BEARING — SQL error/column-not-found | Correct form: `iceberg.schema."tablename$snapshots"` (whole name + suffix in ONE quote pair) | trino.io/docs/current/connector/iceberg.html |
| 2 | Q4 | REGRESSION — execute-guard instead of is_incremental() (iter452 fix re-surfaced) | LOAD-BEARING — wrong behavior on full-refresh and initial run | Canonical incremental guard: `{% if is_incremental() %}` checks materialization + table-exists + no-full-refresh; `{% if execute %}` is True during compile/docs/run regardless | docs.getdbt.com/reference/dbt-jinja-functions/execute + docs.getdbt.com/docs/build/incremental-models |
| 3 | Q1 | nuance-error — store_failures output semantics (non-load-bearing) | MINOR — wrong expectation for engineer | `not_null_proportion` store_failures stores aggregate proportion result row (one row per group), NOT individual null rows; use plain `not_null` test + store_failures for row-level audit | github.com/dbt-labs/dbt-utils/blob/main/macros/generic_tests/not_null_proportion.sql |

Q2: ZERO fabrications or regressions.

---

## Topic average updates

| Topic | Before | After | Delta |
|---|---|---|---|
| SQL query best practices for OLAP (Q1 dbt test config) | 4.5275/53 | **4.5236/54** | -0.004 |
| Analytical query patterns on Iceberg+Trino (Q2 approx_percentile) | 4.5131/15 | **4.5318/16** | +0.0187 |
| Iceberg table maintenance (Q3 time-travel) | 4.4969/142 | **4.4912/143** | -0.0057 |
| Oracle PL/SQL→dbt+Trino migration (Q4 ROWNUM+surrogate+incremental) | 4.5029/59 | **4.4831/60** | -0.0198 |
| Trino federation / cross-source connectors | 4.49944/310 | **4.49944/310 UNCHANGED** | NOT PROBED |

---

## Teacher actions for iter490

### PRIMARY — Fix the two confirmed regressions

**Fix 1: $snapshots quoting regression (Q3 — Iceberg metadata tables)**

Search resources/ (especially r17 iceberg-table-maintenance.md and any file containing `$snapshots`, `$history`, `$files`, `$manifests`) for ANY occurrence of the split-quote pattern `table_name."$snapshots"` or `<table>."$<suffix>"`.

Install or reinforce the LEADING CANONICAL anchor:

```
CORRECT (one quote pair for the whole identifier):
  SELECT * FROM iceberg.analytics."my_table$snapshots"
  SELECT * FROM iceberg.analytics."my_table$history"
  SELECT * FROM iceberg.analytics."my_table$files"

WRONG (split-quote — column-not-found error in Trino):
  SELECT * FROM iceberg.analytics.my_table."$snapshots"   -- DO NOT WRITE
  SELECT * FROM iceberg.analytics.my_table."$history"     -- DO NOT WRITE
```

DO-NOT-WRITE matrix entry: `table_name."$<suffix>"` form is a SQL error in Trino; the table name and metadata suffix must form a single quoted identifier.

Citation: trino.io/docs/current/connector/iceberg.html (search "customer_orders$snapshots" for the doc example).

This fix was originally applied at iter454. Wherever it was placed, it either got stale, was removed, or the responder's keyword path doesn't lead through it. Verify the fix is in a location that keyword-matches "snapshots", "time travel", "history", "metadata table" queries.

**Fix 2: {% if execute %} incremental guard regression (Q4 — Oracle migration / dbt incremental)**

Search resources/ (especially r27 oracle-plsql-to-dbt-trino.md and r28 complex-sql-performance-trino-dbt.md) for ANY occurrence of `{% if execute %}` used as an incremental guard. Also search for `adapter.get_columns_in_relation` used as an incremental guard.

Install or reinforce the LEADING CANONICAL anchor:

```
CANONICAL incremental guard in dbt:

{% if is_incremental() %}
  where event_time >= (select coalesce(max(event_time), timestamp '1970-01-01 00:00:00') from {{ this }})
{% endif %}

DO NOT WRITE:
  {% if execute %}  -- WRONG: True during compile, docs generate, AND run; does not gate on incremental
  {% if execute and 'col' in adapter.get_columns_in_relation(this) %}  -- WRONG: same class
```

is_incremental() returns True ONLY when:
1. materialized='incremental'
2. the model already exists as a table in the database
3. --full-refresh was NOT passed

Citation: docs.getdbt.com/reference/dbt-jinja-functions/execute (explicit statement: "not the correct guard for incremental models") + docs.getdbt.com/docs/build/incremental-models (canonical example uses is_incremental()).

This fix was originally applied at iter452. Verify it is placed where keywords "incremental", "surrogate key", "Oracle sequence", "ROWNUM" would lead the responder.

### SECONDARY — Add clarifying note on not_null_proportion store_failures semantics

In the dbt test configs section (r27 §6.7A or wherever not_null_proportion is documented):

Add a single-sentence clarifier after the store_failures_as example:

> Note: `not_null_proportion` is an **aggregate test** — when `store_failures_as: table` is set, the audit table contains **one row per group** (or one row total if no `group_by_columns`) showing the computed proportion value, not individual rows where the column was null. To audit which individual rows are null, use the plain `not_null` test with `store_failures_as: table` instead.

This is non-load-bearing but prevents engineer confusion when they open the audit table and find a proportion value instead of row-level failures.

### SECONDARY — breadth design for iter490

- Federation 4.49944/310 row HELD per iter472-489+ directive. DO NOT count any iter490 probe as a federation probe.
- Low-count topics worth additional datapoints:
  - dbt sources / source freshness (3, 4.219) — re-probe loaded_at_field + warn_after/error_after blocking semantics from a 2nd angle
  - dbt model contracts (3, 4.1146) — re-probe contract.enforced + not_null runtime-enforced via Iceberg
  - Storage tiering on Trino+Iceberg+MinIO (2, 4.25) — re-probe MinIO lifecycle `mc ilm tier add` recipe
  - dbt snapshots SCD2 (2, 4.5625) — re-probe dbt_valid_from/dbt_valid_to + check vs timestamp strategy
- Consider a 2nd-angle re-probe on `$snapshots` quoting at iter491-492 to confirm the regression fix landed (iter454 fix landed but apparently re-surfaced; needs 2-probe confirmation after fix).

### Schedule note

5-min cadence — `delaySeconds=300`.

---

## Streak / margin status

- **88th consecutive overall PASS in extended phase.**
- Margin at 4.031 (THIN PASS) — +0.531 above 3.5 floor; -0.313 below iter488's 4.344.
- Q3 3.6875 + Q4 3.3125 dragged overall from what would have been ~4.5625 STRONG PASS.
- **TWO REGRESSIONS confirmed**: both are previously-fixed items that re-surfaced.
  - $snapshots split-quote (iter454 fix) — must reinforce the quoting rule in the right keyword-findable location.
  - {% if execute %} incremental guard (iter452 fix) — must reinforce is_incremental() anchor in the right keyword-findable location.
- **Citation-hygiene status**: Q1 ZERO load-bearing fabs (fix confirmed landed). Q2 ZERO fabs. Q3 one regression. Q4 one regression.
- **Federation**: 4.49944/310 — 25th+ consecutive iteration with the row HELD per iter472-489+ directive.
