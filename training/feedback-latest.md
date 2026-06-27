# Iter1158 — Judge Feedback

**Verdict: STRONG PASS NO-OP. dbt-snapshots/SCD-2 thin row LIFTED.**

Iter average = (5.00 + 5.00 + 4.875 + 4.75) / 4 = **4.90625 STRONG PASS** (margin +1.40625). All four answers source-aligned and copy-pastable. **Q1 lifts the thinnest required-topic row (dbt-snapshots-SCD2 4.1079/18 → 4.1549/19, +0.0470).** No findability gaps, no responder slips, no FIX-A. Sustains the 32-iter strong-pass band.

| Q | Score | Topic touched | Status | Notes |
|---|---|---|---|---|
| Q1 customers history without hand-rolling change detection | **5.00** | dbt snapshots SCD2 (THIN ROW LIFT) | STRONG PASS | Pin-perfect SCD-2 dbt snapshot. `{% snapshot %}` block + config keys correct + 4 dbt_* metadata cols + as-of validity-window predicate canonical. Lifts thinnest row 4.1079→4.1549 (+0.0470). |
| Q2 sum 30-element array per row | **5.00** | SQL best practices OLAP (dialect) | STRONG PASS | Correctly named NO `array_sum` in Trino 467; `reduce(arr, 0, (s,x)->s+x, s->s)` 4-arg signature pin-perfect. |
| Q3 per-customer 3-sigma anomaly in ONE query | **4.875** | Analytical query patterns Iceberg+Trino | PASS | Single-pass `AVG()/STDDEV_POP() OVER (PARTITION BY customer_id)` in SELECT + CASE, NOT in WHERE — correctly avoids window-in-WHERE trap. STDDEV_POP vs STDDEV_SAMP distinction noted. Minor app shave: includes current row in its own baseline (defensible for large datasets but `ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING` is the strictly-historical form). |
| Q4 last-write timestamp + rough row count from Iceberg metadata | **4.75** | Iceberg table maintenance (operational) | PASS | `"events$snapshots"` columns + operation values (`append`/`replace`/`overwrite`/`delete`) + `summary` map keys + `element_at` extraction + quoting rule all correct. Minor completeness shave: didn't flag that `summary` map values are VARCHAR (CAST AS BIGINT needed for arithmetic). Not load-bearing for the engineer's "see when last + roughly how many" framing. |

---

## Q1 — dbt snapshot SCD-2 (THIN ROW LIFT)

### Engineer's framing

`customers` table is overwritten in place (current `subscription_tier` + `billing_address` only). History is lost. Product asks "what tier was customer X on last March?" Want every version of each dimension row preserved over time WITHOUT hand-rolling change detection. Standard built-in dbt way?

### Responder's answer (key shape)

```sql
-- snapshots/customers_snapshot.sql
{% snapshot customers_snapshot %}
  {{ config(
       target_schema='analytics',
       unique_key='customer_id',
       strategy='timestamp',
       updated_at='updated_at'
  ) }}
  SELECT customer_id, subscription_tier, billing_address, updated_at
  FROM {{ source('raw','customers') }}
{% endsnapshot %}
```

Point-in-time query:
```sql
SELECT subscription_tier
FROM {{ ref('customers_snapshot') }}
WHERE customer_id = 'cust_123'
  AND dbt_valid_from <= TIMESTAMP '2025-03-15 12:00:00'
  AND (dbt_valid_to IS NULL OR dbt_valid_to > TIMESTAMP '2025-03-15 12:00:00');
```

Plus the 4 metadata columns: `dbt_scd_id`, `dbt_updated_at`, `dbt_valid_from`, `dbt_valid_to`. Cites r09.

### Source verification

- `{% snapshot name %} ... {% endsnapshot %}` block syntax + `config(target_schema=, unique_key=, strategy='timestamp', updated_at=)` keys correct per [docs.getdbt.com/docs/build/snapshots](https://docs.getdbt.com/docs/build/snapshots). Strategy `'timestamp'` requires the `updated_at=` config — responder satisfies it.
- 4 metadata columns: `dbt_scd_id` (hash of unique_key + change detection inputs), `dbt_updated_at`, `dbt_valid_from`, `dbt_valid_to` (NULL on current/active row) — match docs verbatim.
- Validity-window point-in-time predicate `dbt_valid_from <= D AND (dbt_valid_to IS NULL OR dbt_valid_to > D)` is the standard half-open SCD-2 lookup pattern. Returns exactly one row per `customer_id` at time D.
- dbt 1.9+ moved snapshots to YAML config form, but the SQL-block-with-`{{ config() }}` form is still valid in 1.9+ — no penalty.
- `dbt_is_current` is intentionally NOT in the list — dbt does not write a current-flag column (currency is determined by `dbt_valid_to IS NULL`). Responder correctly does not invent one.
- Cited r09 — appropriate.

### Verdict

**5.00 (Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0).** Pin-perfect SCD-2 snapshot answer with copy-pastable config + as-of query. **This lifts the thinnest required-topic row.**

---

## Q2 — sum 30-element array per row (no array_sum)

### Engineer's framing

Iceberg table with an array column of 30 daily-active-user counts. Want a rolling 30-day sum (one row in, one number out). `array_sum(daily_counts)` not recognized by Trino. Built-in to sum an array, or different approach?

### Responder's answer

```sql
SELECT user_id,
       reduce(daily_counts, 0, (accumulator, x) -> accumulator + x, s -> s) AS rolling_30d_total
FROM iceberg.analytics.user_activity;
```

Explains the 4-arg `reduce` signature: array, initial accumulator (0), combine lambda `(s,x) -> s+x`, finalize lambda `s -> s`. Example `[8, 12, 5] → 25`. Cites r07 §1a.4.

### Source verification

- Trino 467 has NO `array_sum` — verified via known pin `reference_trino_no_array_sum.md` and Trino feature request [trinodb/trino#4346](https://github.com/trinodb/trino/issues/4346) (still open). Responder correctly named the absence.
- `reduce(array, initialState, inputFunction, outputFunction)` 4-arg signature per [trino.io/docs/current/functions/array.html](https://trino.io/docs/current/functions/array.html) — documentation example: `SELECT reduce(ARRAY[5, 20, 50], 0, (s, x) -> s + x, s -> s); -- 75`. Matches responder's form exactly.
- For non-null elements, identity output lambda `s -> s` returns the running total directly. NULL-handling caveat (use `coalesce(x,0)` inside the combine lambda) not mentioned — minor recall ceiling but not load-bearing for the engineer's stated DAU-count scenario where elements are non-null counts.

### Verdict

**5.00 (Acc 5.0 / Clar 5.0 / App 5.0 / Compl 5.0).** Direct pin-perfect canonical. NO array_sum pin holding durably.

---

## Q3 — per-customer 3-sigma anomaly in ONE query

### Engineer's framing

`transactions` table. Flag any transaction where `amount > 3 stddevs above THAT customer's historical average`. Compute per-customer mean+stddev and compare individual rows in ONE query, or need a separate subquery + join back?

### Responder's answer (key shape)

```sql
SELECT
  transaction_id, customer_id, amount,
  AVG(amount) OVER (PARTITION BY customer_id) AS customer_avg,
  STDDEV_POP(amount) OVER (PARTITION BY customer_id) AS customer_stddev,
  CASE
    WHEN amount > AVG(amount) OVER (PARTITION BY customer_id)
              + 3 * STDDEV_POP(amount) OVER (PARTITION BY customer_id)
    THEN 'ANOMALY' ELSE 'normal'
  END AS flag
FROM transactions
WHERE transaction_date >= current_date - INTERVAL '30' DAY
ORDER BY customer_id, transaction_id;
```

Notes STDDEV_POP (population, divides by N) vs STDDEV_SAMP (sample, divides by N-1) — STDDEV_POP appropriate when treating the window as the full population for that customer. Window funcs live in SELECT/CASE only, NOT in WHERE.

### Source verification

- All aggregate functions in Trino 467 can be used as window functions by adding `OVER (...)` per [trino.io/docs/current/functions/window.html](https://trino.io/docs/current/functions/window.html) ("All aggregate functions can be used as window functions by adding the OVER clause").
- `avg(x)`, `stddev_pop(x)`, `stddev_samp(x)` all native at [trino.io/docs/current/functions/aggregate.html](https://trino.io/docs/current/functions/aggregate.html) — `stddev_pop` "returns the population standard deviation", `stddev_samp` "returns the sample standard deviation".
- `OVER (PARTITION BY customer_id)` with no ORDER BY uses default frame `RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING` (the whole partition) — correct shape for "the customer's average across all of their rows in the window".
- Window-function-in-WHERE is invalid in Trino (window functions only allowed in SELECT/ORDER BY). Responder correctly puts the comparison in a `CASE` in SELECT, not as a `WHERE flag = 'ANOMALY'` filter.
- Interpretation caveat: "historical average" technically excludes the current row, which would require `OVER (PARTITION BY customer_id ORDER BY transaction_date ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)` to lag by one. With large per-customer history, the current row's contribution to the mean is negligible (1/N), so the simple form is the canonical practical approach. Minor practical-applicability shave but not load-bearing.
- 30-day WHERE filter scopes "historical" — reasonable interpretation; engineer can adjust the window.

### Verdict

**4.875 (Acc 5.0 / Clar 5.0 / App 4.5 / Compl 5.0).** Clean single-pass canonical with correct SELECT/CASE placement and STDDEV_POP/SAMP distinction.

---

## Q4 — Iceberg $snapshots metadata for last-write diagnostics

### Engineer's framing

Nightly dbt job writes to an Iceberg table; sometimes completes without error yet nothing is written. Want to query the table itself to see (a) when the last commit happened and (b) roughly how many rows were in that last write. Metadata table / built-in Trino+Iceberg mechanism?

### Responder's answer (key shape)

```sql
SELECT snapshot_id, committed_at, operation,
       element_at(summary, 'added-records')    AS rows_added,
       element_at(summary, 'deleted-records')  AS rows_deleted,
       element_at(summary, 'added-data-files') AS files_added
FROM iceberg.analytics."events$snapshots"
ORDER BY committed_at DESC
LIMIT 1;
```

Plus `"events$partitions"` for total record_count/file_count via metadata-only scan. Operations: `append` / `replace` / `overwrite` / `delete`. Quoting rule: whole `"events$snapshots"` in ONE double-quote pair. Cites r17.

### Source verification

Per [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html):
- `$snapshots` columns: `committed_at TIMESTAMP(3) WITH TIME ZONE`, `snapshot_id BIGINT`, `parent_id BIGINT`, `operation VARCHAR`, `manifest_list VARCHAR`, `summary map(VARCHAR, VARCHAR)`. All responder's columns verified.
- Operation values: `append`, `replace`, `overwrite`, `delete` — all four match the responder's list.
- `summary` map keys include `added-data-files`, `added-files-size`, `total-records`, `total-data-files`, `changed-partition-count`, etc. The Iceberg snapshot summary spec also defines `added-records` / `deleted-records` — responder's keys are valid.
- `$partitions` columns: `partition ROW`, `record_count BIGINT`, `file_count BIGINT`, `total_size BIGINT`, `data ROW(...)`. Responder's `record_count`/`file_count` and "metadata-only / no scan" framing correct.
- Whole-token quoting `"table$snapshots"` (one pair) is the documented form per r17 §70-150 CRITICAL QUOTING RULE.
- **Minor completeness shave:** summary map values are `VARCHAR` (not BIGINT). Engineer can `SELECT element_at(summary, 'added-records')` and get a number-looking string for display, but if they want to do arithmetic (`SUM(...)`, `> 1000` predicates) they'd need `CAST(element_at(summary,'added-records') AS BIGINT)`. The "roughly how many rows" framing fits string display, so this isn't load-bearing — but a fully complete answer would have flagged it.

### Verdict

**4.75 (Acc 5.0 / Clar 5.0 / App 4.5 / Compl 4.5).** Clean operational diagnostic answer with correct metadata-table columns, operation set, summary keys, and quoting rule. Only the VARCHAR-vs-arithmetic caveat is missing.

---

## Cross-iteration pattern

Iter1158 is the **5th consecutive strong-pass** in the post-iter1156 recovery band:
- iter1153: 4.40 PASS+LIGHT (contains_sequence)
- iter1154: 3.94 PASS+LIGHT (sessionization final-count)
- iter1155: 4.41 PASS+LIGHT (expire_snapshots caveat #3)
- iter1156: 3.656 THIN PASS+LIGHT (LIKE-ESCAPE bail)
- iter1157: 4.9375 STRONG PASS NO-OP (both watches CLOSE)
- **iter1158: 4.90625 STRONG PASS NO-OP (thin-row LIFT)**

Sustainment band remains healthy. No active FIX-A watches. All canonical anchors and pinned references are holding durably.

### Recommendation

**NO-OP.** No resource edit needed. Continue breadth probing thinnest rows next iter — after Q1's lift, next thinnest required-topic is **storage-tiering 4.1302/12 (+0.6302)**, then **query-perf-basics 4.1893/26 (+0.6893)**, then **cost-considerations 4.3258/24 (+0.8258)**.

### Verified facts referenced

- [dbt snapshot docs — strategies, metadata columns, validity window](https://docs.getdbt.com/docs/build/snapshots)
- [Trino array functions — array.html](https://trino.io/docs/current/functions/array.html) (`reduce(array, initial, combine, finalize)` 4-arg signature; no `array_sum`)
- [Trino window functions — window.html](https://trino.io/docs/current/functions/window.html) (all aggregates usable as window functions)
- [Trino aggregate functions — aggregate.html](https://trino.io/docs/current/functions/aggregate.html) (`stddev_pop` vs `stddev_samp`)
- [Trino Iceberg connector — iceberg.html — metadata tables](https://trino.io/docs/467/connector/iceberg.html) (`$snapshots` columns, operation values, `summary map(VARCHAR,VARCHAR)`; `$partitions` columns)
- [Trino feature request — array_sum function (open)](https://github.com/trinodb/trino/issues/4346)
