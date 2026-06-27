# Iter1183 Judge Feedback

**Overall verdict:** **STRONG PASS** (one minor grain shave on Q3).

**Iter1182 WATCH `r17 register_table table_location-not-metadata_file FIX-A iter1182`: CLOSES on first re-probe.**
Q1 responder used the verified Trino 467 form: `table_location => 's3a://bucket/path/to/events'` (the table BASE DIRECTORY) + optional `metadata_file_name => '00042-abc123.metadata.json'` (BARE filename), with explicit defang "Do NOT pass a path to metadata.json itself" and explicit "the table BASE DIRECTORY (containing metadata/)". No `metadata_file` (Spark's arg) and no `metadata_location` (HMS column name) regression. Matches r17 §244 / §3848-3853 / §3864-3867 FIX-A spec verbatim. Verified against [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) — Trino's example uses `schema_name`, `table_name`, `table_location` (directory), and the optional `metadata_file_name` for pinning. Watch CLOSES.

Total iter1183 score: (5.0 + 4.875 + 4.0 + 4.75) / 4 = **4.65625 / 5**

| Q | Topic | Score | Note |
|---|---|---|---|
| 1 | Iceberg maintenance — `register_table` recovery from MinIO after plain DROP TABLE | 5.0 | **WATCH RE-PROBE PASS.** Correct 467 form (`table_location` = DIRECTORY, optional `metadata_file_name` = BARE filename); explicit defang of "metadata.json path as the arg" misconception; cites r17 line 244. Engineer can copy-paste and run. |
| 2 | Analytical query patterns — array predicate without UNNEST via `none_match` | 4.875 | Pin-perfect canonical: `WHERE none_match(features, f -> starts_with(f, 'beta_'))` returns true iff zero elements start with `beta_`. Lambda explained. Valid `array_intersect`-based alternative for known-set case. Verified at trino.io array.html. |
| 3 | Analytical query patterns — cumulative distinct entities over time (running new-customers) | 4.0 | Pattern correct (first-appearance cohort + `SUM(...) OVER (ORDER BY ... ROWS UNBOUNDED PRECEDING)`); correctly explained `COUNT(DISTINCT) OVER` is unsupported in Trino 467 and `SUM(COUNT(DISTINCT)) OVER` double-counts. **MINOR SHAVE — grain mismatch on literal ask**: engineer asked for one point per calendar DAY, responder used `DATE_TRUNC('month', MIN(order_date))` (monthly grain). Pattern identical at day grain (just `DATE(MIN(order_date))` or `date_trunc('day', ...)`) so engineer can adapt, but the literal ask wasn't honored. |
| 4 | Improving complex SQL with dbt — `on_schema_change` for incremental Iceberg model with new column | 4.75 | Values + default + per-option behavior correct per [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models): `ignore` (DEFAULT — new column NOT added to target), `fail` (halt), `append_new_columns` (recommended add-only via ALTER TABLE ADD COLUMN, then MERGE), `sync_all_columns` (add AND drop, destructive). MINOR Acc shave: "silent data loss" framing slightly overstates — existing data isn't deleted, the new column is just absent from the target / dropped from the incremental SELECT — practical implication accurate. |

---

## Per-question detail

### Q1 — Re-attach dropped Iceberg table via `register_table` (WATCH RE-PROBE)

**Score 5.0** — WATCH `r17 register_table table_location-not-metadata_file FIX-A iter1182` **CLOSES**.

Responder's call:
```
CALL iceberg.system.register_table(
  schema_name   => 'your_schema',
  table_name    => 'events',
  table_location => 's3a://bucket/path/to/events'
  -- optional: metadata_file_name => '00042-abc123.metadata.json'
)
```

Every load-bearing fact correct:
- `table_location` = the table BASE DIRECTORY (the folder that contains `metadata/`), NOT a metadata.json path
- Trino 467 auto-discovers latest `metadata.json` when `metadata_file_name` is omitted
- Optional `metadata_file_name` takes the BARE filename only (no path)
- Explicit defang: "Do NOT pass a path to metadata.json itself"
- Cites r17 line 244

Verified against [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html) `register_table` procedure:
> `CALL example.system.register_table(schema_name => 'testdb', table_name => 'customer_orders', table_location => 'hdfs://...')`
> "In addition, you can provide a file name to register a table with specific metadata... metadata_file_name => '00003-409702ba-...metadata.json'"

The iter1182 misconception (`metadata_location =>` or `metadata_file =>` taking a full S3 path) is fully absent. No churn risk. r17 §244 / §3848-3853 / §3864-3867 LIGHT FIX-A landed.

### Q2 — `none_match` for "no element matches" without UNNEST

**Score 4.875** — pin-perfect.

`WHERE none_match(features, f -> starts_with(f, 'beta_'))`

Verified at [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html):
- `none_match(array(T), function(T, boolean)) → boolean` — returns `true` if the predicate is false for every element (empty arrays → `true`)
- `any_match` / `all_match` complete the family
- `starts_with(s, sub)` is native in Trino 467 (per pinned reference_trino_starts_with_ends_with.md)

Alternative `cardinality(array_intersect(features, ARRAY['beta_admin','beta_export']))=0` is a valid alternative for the known-finite-set case (different semantic — doesn't catch arbitrary `beta_*` strings, but explicitly framed by responder for a "known set" case). Lambda syntax explained.

Minor completeness ceiling: did not name `filter(features, f -> starts_with(f, 'beta_'))` returning the matching subset for diagnosis — recall ceiling, not load-bearing.

### Q3 — Running count of new distinct customers per DAY (MINOR GRAIN SHAVE)

**Score 4.0**.

Pattern correct:
1. CTE `first_order`: per-customer first-order timestamp via `MIN(order_date) GROUP BY customer_id`
2. CTE `new_per_period`: count of new customers per period
3. Final: `SUM(new_customers) OVER (ORDER BY order_period ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` for monotonic cumulative count

Correctly explained:
- `COUNT(DISTINCT col) OVER (ORDER BY ...)` is unsupported in Trino 467 (analysis error "DISTINCT in window function parameters not yet supported" — verified via [trinodb/trino#7885](https://github.com/trinodb/trino/issues/7885))
- `SUM(COUNT(DISTINCT customer_id)) OVER` double-counts re-purchasers
- First-appearance-cohort + running-SUM is the correct cumulative-distinct technique (each entity counted ONCE at first appearance, running sum is monotonic-non-decreasing as required)

**MINOR SHAVE — GRAIN MISMATCH ON LITERAL ASK** (-1.0 weighted across dims):
The engineer explicitly asked for "one point per calendar DAY". The responder used `DATE_TRUNC('month', MIN(order_date)) AS first_month` and produced a MONTHLY cumulative series. The pattern is identical at day grain — `DATE_TRUNC('day', MIN(order_date))` (or `DATE(MIN(order_date))` since `order_date` is presumably a DATE) — but the responder did not address the day-grain ask. Engineer must transpose `'month'` → `'day'` themselves. Knowledgeable engineer adapts trivially, but a beginner reading the answer verbatim ships a monthly chart when they asked for daily.

Not a resource defect (pattern is the canonical one); responder framing slip on grain. Recall ceiling on grain matching. NO RESOURCE FIX — adding a "match grain to ask" defang risks over-attractor on neighbor cohort/time-series questions.

### Q4 — dbt `on_schema_change` for incremental Iceberg model

**Score 4.75**.

Per [docs.getdbt.com/docs/build/incremental-models](https://docs.getdbt.com/docs/build/incremental-models) verified verbatim:

| Value | Behavior on added column |
|---|---|
| `ignore` (DEFAULT) | "this column will not appear in your target table" — new column dropped from incremental SELECT, target unchanged |
| `fail` | "Triggers an error message when the source and target schemas diverge" |
| `append_new_columns` | "Append new columns to the existing table. Note that this setting does not remove columns from the existing table that are not present in the new data" |
| `sync_all_columns` | "Adds any new columns to the existing table, and removes any columns that are now missing" |

Responder's recommendation (`append_new_columns` for additive Iceberg fact-table evolution) is the production-stack-correct choice — Iceberg supports `ALTER TABLE ADD COLUMN` as metadata-only, and `append_new_columns` matches that semantics (add-only, no destructive drops). Default `ignore` behavior (new column silently absent from target) accurately described.

MINOR Acc shave (-0.25): "silent data LOSS" overstates. The existing rows are intact; the new column's data is simply not loaded into the target (dropped from the incremental SELECT) until `on_schema_change` is set. "Silent column drop" or "silent data NOT loaded" is the precise framing. Practical impact for engineer is identical (set `on_schema_change='append_new_columns'`), so framing slip not load-bearing.

Did not name dbt's caveat that `on_schema_change` does NOT backfill historical rows for newly-added columns (per dbt docs: "None of the on_schema_change behaviors backfill values in old records for newly added columns. If you need to populate those values, we recommend running manual updates, or triggering a `--full-refresh`."). Recall ceiling, not load-bearing for the asked question.

---

## Watches status

- `r17 register_table table_location-not-metadata_file FIX-A iter1182` — **CLOSED on first re-probe** (Q1). 15 of last 15 watches closed first re-probe.

## No new watches opened.

Q2/Q4 clean and source-verified. Q3 grain shave is a per-instance responder framing slip, not source-defect (per `feedback_responder_broken_secondary_alternative.md` / recall-ceiling family), no resource fix.

## Topic rubric updates

| Topic | Prior | New | Delta |
|---|---|---|---|
| Iceberg table maintenance (Q1) | 4.4581/202 | 4.4608/203 | +0.0027 |
| Analytical query patterns (Q2+Q3) | 4.5337/132 | 4.5322/134 | -0.0015 |
| Improving complex SQL on Trino with dbt (Q4) | 4.5634/29 | 4.5696/30 | +0.0062 |

All required topics remain PASSED with margin >0.9.
