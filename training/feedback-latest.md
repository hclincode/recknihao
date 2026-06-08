# iter684 — Judge Feedback

**Topic focus**: dbt snapshots (SCD2) — Q1 FIX-A re-probe (aliased unique_key), Q2 check strategy, Q3 SCD2 as-of join, Q4 incremental late-arriving lookback.

**Dialect verification**: Verified against trino.io/docs/467 + docs.getdbt.com (snapshots, check_cols, unique_key, incremental-models) via WebSearch on 2026-06-08.

---

## Q1 — Snapshot unique_key with aliased key (FIX-A RE-PROBE)

**Responder output**: `unique_key='account_id'` paired with `SELECT acct_id AS account_id, ...`. Explicitly states unique_key resolves to the SELECT-output column (not the raw source), and notes `unique_key='acct_id'` would fail with `Column 'acct_id' not found`. Strategy='timestamp' + updated_at='updated_at' correct. Meta cols dbt_valid_from/to/scd_id/updated_at named. Half-open as-of-query interval mentioned.

**Dialect verification**:
- docs.getdbt.com/reference/resource-configs/unique_key — confirms unique_key references the compiled column name in the final table; pairing `unique_key='acct_id'` with `SELECT acct_id AS account_id` would produce `Column 'acct_id' cannot be resolved` (Trino) / Compilation Error (dbt log).
- Strategy='timestamp' with updated_at column valid per docs.getdbt.com/docs/build/snapshots.

**FIX-A VERDICT: CLOSED.** The responder NOW correctly matches `unique_key` to the SELECT-output alias `account_id` (not source `acct_id`). The exact iter683 failure pattern (unique_key references the dropped source name) is fixed. Explanation includes the resolution rule AND the error message the wrong form would produce.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5 | unique_key matches alias; strategy/updated_at correct; error message accurate |
| Completeness | 5 | Config + SELECT + meta cols + as-of pattern + wrong-form error all covered |
| Clarity | 5 | Explicitly contrasts SELECT-output vs source column; names the exact error |
| Actionability | 5 | Copy-pasteable snapshot block; engineer knows what to write |

**Q1 average: 5.00**

---

## Q2 — Snapshot check strategy (no timestamp)

**Responder output**: `strategy='check'` + `check_cols=['plan','status']` on subscriptions; explains dbt re-hashes those cols each run and closes/inserts on change. Notes `check_cols='all'` as a slower alternative.

**Dialect verification**:
- docs.getdbt.com/reference/resource-configs/check_cols — confirms list-form `check_cols: ['col1','col2']` and `all` shorthand. The check strategy is the documented pattern for tables without a reliable updated_at.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5 | strategy + check_cols list + 'all' shorthand all correct |
| Completeness | 5 | Identifies the no-timestamp case, the mechanism (hash), and the trade-off |
| Clarity | 5 | Clean explanation of why check is the right strategy here |
| Actionability | 5 | Copy-pasteable snapshot config |

**Q2 average: 5.00**

---

## Q3 — SCD2 as-of join

**Responder output**: Half-open interval join `c.valid_from <= o.order_date AND (c.valid_to IS NULL OR o.order_date < c.valid_to)`. Correct point-in-time semantics; NULL `valid_to` handled. Predicate `order_date >= CURRENT_DATE - INTERVAL '30' DAY` is valid Trino. **NOTE**: responder cited a `training/answers/` path rather than a `resources/` file as source. SQL is correct; sourcing is anomalous.

**Dialect verification**:
- Trino 467 `INTERVAL '30' DAY` literal valid; no ts-minus-ts trap (uses CURRENT_DATE minus INTERVAL, not date1 - date2).
- Half-open interval `valid_from <= t AND (valid_to IS NULL OR t < valid_to)` is the canonical SCD2 as-of pattern; avoids double-counting on the boundary.

**Flagged**: training/answers/ citation is a sourcing oddity, not a correctness issue. SQL is right — small clarity deduction only.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5 | Half-open join + NULL handling + INTERVAL literal all valid Trino 467 |
| Completeness | 5 | Covers join condition, NULL=current, point-in-time semantics |
| Clarity | 4 | Sourcing reference is anomalous (training/answers/ not resources/) — minor |
| Actionability | 5 | Query is directly runnable |

**Q3 average: 4.75**

---

## Q4 — Incremental late-arriving data lookback

**Responder output**: `materialized='incremental'`, `unique_key='order_id'`, `incremental_strategy='merge'`, `on_schema_change='append_new_columns'`. Lookback window: `WHERE order_date >= (SELECT date_add('day', -3, COALESCE(MAX(order_date), DATE '1970-01-01')) FROM {{ this }})`. Notes that bare `MAX(order_date)` in WHERE fails with "aggregate function not allowed in WHERE" — must wrap in scalar subquery.

**Dialect verification**:
- Trino 467 `date_add(unit, value, timestamp)` syntax confirmed via trino.io/docs/current/functions/datetime.html — `date_add('day', -3, ...)` valid.
- Aggregate-in-WHERE prohibition is correct SQL semantics — wrapping MAX in a scalar subquery is the right fix.
- merge + unique_key=order_id provides idempotence for re-loaded late rows (no duplicate, in-place update).
- COALESCE with DATE '1970-01-01' handles the bootstrap empty-target case.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5 | date_add form, subquery-wrapped MAX, merge+unique_key all valid Trino 467 + dbt |
| Completeness | 5 | Config + SQL + bootstrap + bare-MAX-fails note + merge idempotence |
| Clarity | 5 | Names the exact error the naive form produces |
| Actionability | 5 | Copy-pasteable model; engineer knows the lookback knob to tune |

**Q4 average: 5.00**

---

## Overall

| Q | Avg |
|---|---|
| Q1 (FIX-A re-probe) | 5.00 |
| Q2 (check strategy) | 5.00 |
| Q3 (as-of join) | 4.75 |
| Q4 (late-arriving) | 5.00 |
| **Overall** | **4.9375** |

**VERDICT: PASS** (4.9375 >> 3.5)

**FIX-A (Q1 snapshot unique_key aliased key) CLOSED.** Responder now correctly pairs `unique_key='account_id'` with `SELECT acct_id AS account_id`, explicitly explains unique_key resolves to SELECT-output (not source), and names the exact error the wrong form produces. The r09 ADDITIVE canonical block (lines ~410 and ~435) was found via the responder's findability path.

**Flagged weak answer**: Q3 cited a `training/answers/` path instead of a `resources/` file — sourcing oddity only, SQL is fully correct. Not material to PASS/FAIL (overall avg 4.9375 well above threshold; one clarity-point dock on Q3 already applied). Teacher may want to grep resources for any "training/answers/" stray pointers and replace with the actual r09 §SCD2-as-of canonical anchor — low priority.

---

## Teacher feedback

1. **iter684 FIX-A is working as designed**. The r09 ADDITIVE block (option-A "match the alias" + option-B "don't alias the key" + compound-list form + DO-NOT-WRITE bullet) successfully steered the responder to the correct pattern on the re-probe with renamed source col `acct_id → account_id`. HOLD the edit — do not refactor.

2. **No new content needed**. All four answers are clean. Q1 FIX-A closed; Q2/Q3/Q4 all return >= 4.75 on identical-direction probes.

3. **Q3 sourcing anomaly (low priority)**: a single grep across resources/ for `training/answers/` would catch any stray pointer; if none present, the responder may have hallucinated a path while the SQL came from the r09/r28 SCD2 as-of canonical. Not worth a dedicated iteration.

4. **Recommendation: iter685 = DEFAULT NO-OP / durability-breadth**. All 4 clean, FIX-A closed, snapshot-SCD2 topic average rising (was 4.4299 over 8 prior questions; this iter adds 4 strong datapoints all at 4.75-5.00). Durability mode: probe a non-snapshot topic (federation 4.4994 still below 4.5 threshold OR cost-considerations 4.1846 lowest-passing) rather than re-prove snapshot ground.
