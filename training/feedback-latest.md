# Iteration 1237 — Judge Feedback

## Verdict

**Overall: 2.91 — FAIL ITERATION. Two critical defects (Q2 broken-mode-query + Q3 outright BAIL on dbt-snapshots when the canonical exists), bracketed by two solid answers (Q1 Iceberg-add-NOT-NULL + Q4 lpad).**

After 20 consecutive 1st-re-probe-CLOSE iterations, the loop hit a stark double-defect iteration: Q2 produces a query that returns the **alphabetically-first** error_code per customer (the EXACT wrong result the engineer was already getting from `MAX(error_code)`, just dressed up differently), and Q3 outright bails — "resources cover materializations (table/view/incremental/ephemeral) but not the snapshot resource type" — when r09 §357 has the dbt-snapshot LEADING CANONICAL with massive keyword anchors AND r27 §290 has a cross-ref to it literally one line above the §3.1 materializations table the responder reached.

**TWO LIGHT FIX-A WARRANTED, both surgical findability fixes (canonicals already exist).** Teacher's pre-flag was correct on Q3 (findability miss, not content gap) and the breakage call on Q2; pre-flag's only partial miss was claiming Q2 had "no dedicated mode-per-group canonical" — r23 §1403 IS that canonical with extensive anchors, so the Q2 FIX-A is also findability + DO-NOT-WRITE-defang of the specific broken shape, not a new canonical.

| Q | Score | Topic | Notes |
|---|---|---|---|
| Q1 | 4.25 | Lakehouse schema design (Iceberg schema-evolution row) | Iceberg ADD NOT NULL rejected on existing-data table; backfill via Spark + downstream enforcement correct; minor: didn't surface dbt `not_null` test as the production-stack canonical enforcement layer; minor framing slip ("Iceberg always adds as NULLABLE regardless of declaration" — Trino 467 actually raises on `NOT NULL`, doesn't silently accept) |
| Q2 | 1.5 | Analytical query patterns on Iceberg+Trino | **BROKEN QUERY** — `COUNT(*) OVER (PARTITION BY customer_id ORDER BY CAST(NULL AS INT))` after `GROUP BY customer_id, error_code` returns DISTINCT-error_code-count-per-customer (constant within customer), so ROW_NUMBER tiebreaks on `error_code ASC` and returns the ALPHABETICALLY-FIRST error_code per customer — same wrong result the engineer already had |
| Q3 | 1.0 | dbt snapshots SCD2 | **OUTRIGHT BAIL** — "resources don't cover dbt snapshot resource type" when r09 §357 LEADING CANONICAL exists with anchors literally including "dbt snapshot"/"SCD2 strategy"/"check_cols"/"dbt_valid_from"/"dbt_valid_to" and r27 §290 cross-refs r09 ONE LINE ABOVE the §3.1 materializations table |
| Q4 | 4.875 | Oracle PL/SQL → dbt+Trino migration | Clean: `lpad(CAST(invoice_id AS VARCHAR), 8, '0')` correct; truncation-to-size caveat correct (VERIFIED [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) — "If size is less than the length of string, the result is truncated to size characters"); `format('%08d', invoice_id)` min-width alternative correct (VERIFIED [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) — example `format('%03d', 8)` → `'008'`) |

---

## Per-question detail

### Q1 — Iceberg ADD COLUMN ... NOT NULL on existing 8-month-old table → 4.25 (Lakehouse schema design topic row)

**VERIFIED facts (via WebSearch + trino.io docs):**

- Trino's behavior: since [trinodb/trino PR #13673](https://github.com/trinodb/trino/pull/13673) (release 393, Aug 2022), Trino **disallows** `ALTER TABLE ADD COLUMN ... NOT NULL` on Iceberg tables — engineer's parse error matches expected. Earlier the constraint was silently ignored ([issue #13587](https://github.com/trinodb/trino/issues/13587)); the PR fixed this by rejecting at parse time. Trino 467 inherits the disallow behavior.
- `ALTER TABLE ... SET NOT NULL` on existing columns: NOT supported on the Iceberg connector in Trino 467 (no documented form on [trino.io/docs/467/connector/iceberg.html](https://trino.io/docs/467/connector/iceberg.html)).
- Iceberg spec ([iceberg.apache.org/docs/latest/evolution/](https://iceberg.apache.org/docs/latest/evolution/)): added columns are assigned a new field-ID and existing data files leave the value as NULL on read — metadata-only operation. Iceberg v3 adds default-value support but the production stack here is Iceberg 1.5.2, so v3 defaults don't apply.

**Responder's answer:**

Core correct: ADD COLUMN is metadata-only; can't retroactively enforce NOT NULL on existing data; backfill via Spark; enforce via downstream view / app logic.

**Shaves:**

1. **Framing slip** — wrote "Iceberg always adds columns as NULLABLE regardless of declaration" — slightly misleading because Trino 467 actually **raises a parse error** on `NOT NULL` rather than silently coercing to nullable. The engineer's own observation ("VARCHAR NOT NULL errored") was the right evidence; responder should match that mental model rather than imply silent coercion.
2. **Missing production-stack enforcement idiom** — "downstream app logic / Trino view WHERE data_center IS NOT NULL" is correct but the canonical idiom on this dbt-trino stack is **dbt `not_null` test** (per r-contracts; this stack uses dbt for transformations per prod_info.md). The dbt `not_null` test in `schema.yml` would catch any rows with NULL `data_center` at `dbt build` time — exactly the runtime enforcement the engineer is looking for.
3. **Didn't mention CTAS-and-swap** — for an 8-month-old events table, if the engineer truly needs schema-level NOT NULL on the new column, the production move is: backfill via Spark → CTAS a new table with the NOT NULL constraint baked in (`CREATE TABLE ... AS SELECT *, COALESCE(data_center, 'unknown') AS data_center_new FROM old_table`) → swap. Optional but worth surfacing.

**No FIX-A.** Core answer correct, shaves are recall-ceiling not resource-defect. r09 §SCD canonical and r17 maintenance canonical both cover this material. Watch label: `iter1237 Q1 add-NOT-NULL-on-Iceberg framing-could-name-dbt-not_null-test`: re-probe under "how do I enforce non-null on a new column on this stack" framing; 4-8 iters.

---

### Q2 — Mode per group (MOST FREQUENT error_code) → 1.5 (Analytical query patterns topic row)

**VERIFIED: the responder's query IS broken as the teacher pre-flagged.**

The responder wrote:
```sql
WITH counted AS (
  SELECT customer_id, error_code,
         COUNT(*) OVER (PARTITION BY customer_id ORDER BY CAST(NULL AS INT)) AS freq
  FROM api_errors
  WHERE occurred_at >= current_date - INTERVAL '7' DAY
    AND occurred_at < current_date
  GROUP BY customer_id, error_code
),
ranked AS (
  SELECT customer_id, error_code, freq,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY freq DESC, error_code ASC) AS rn
  FROM counted
)
SELECT customer_id, error_code, freq FROM ranked WHERE rn = 1;
```

**Why it's broken (verified semantics):**

1. After `GROUP BY customer_id, error_code`, the row set is one row per `(customer_id, error_code)` pair — value type is "did this (customer, error_code) appear at all this week" (boolean-shaped), NOT the count.
2. `COUNT(*) OVER (PARTITION BY customer_id ORDER BY CAST(NULL AS INT))` then counts rows in each `customer_id` partition. With `ORDER BY CAST(NULL AS INT)` and Trino's default RANGE frame `BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW`, all NULL-tied "peers" are included in each row's frame → `freq` = **total rows in the partition = number of DISTINCT error_codes per customer** (constant within customer).
3. `ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY freq DESC, error_code ASC)` — since `freq` is constant within each customer, the `freq DESC` ordering is fully tied; tiebreaker is `error_code ASC` → returns the **alphabetically-first** error_code per customer.
4. **End result: same wrong answer as the `MAX(error_code)` the engineer was trying to avoid**, just from the opposite end of the alphabet (`MAX` gives last, this gives first). The query produces a valid-looking result that's NOT the mode.

**The correct forms (all exist in resources/):**

The mode-per-group canonical IS in r23 §1403–1426 with extensive keyword anchors:

```sql
-- ✅ r23 §1411 LEADING CANONICAL — single most-ordered category per customer (the mode):
SELECT customer_id,
       max_by(product_category, cnt) AS top_category
FROM (
    SELECT customer_id, product_category, COUNT(*) AS cnt
    FROM iceberg.analytics.orders
    GROUP BY customer_id, product_category
)
GROUP BY customer_id;
```

For Q2's literal scenario the correct shape would be `max_by(error_code, cnt)` over a `COUNT(*) GROUP BY (customer_id, error_code)` subquery, with the weekly WHERE clause hoisted into the inner SELECT.

Alternatively, the equivalent `ROW_NUMBER` form the responder reached for but got wrong:

```sql
-- Equivalent rank=1 form (also correct):
WITH per_pair AS (
  SELECT customer_id, error_code, COUNT(*) AS freq   -- plain aggregate, NOT a window function
  FROM api_errors
  WHERE occurred_at >= current_date - INTERVAL '7' DAY
    AND occurred_at < current_date
  GROUP BY customer_id, error_code
),
ranked AS (
  SELECT customer_id, error_code, freq,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY freq DESC, error_code ASC) AS rn
  FROM per_pair
)
SELECT customer_id, error_code, freq FROM ranked WHERE rn = 1;
```

The single character difference between this correct form and the responder's broken form is: **plain `COUNT(*) AS freq` aggregate** instead of `COUNT(*) OVER (PARTITION BY ...) AS freq` window function. The window form computes the wrong thing once GROUP BY collapses to one row per pair.

**Teacher pre-flag CORRECTION on content gap:** Teacher said "there is NO dedicated mode/most-frequent-per-group canonical in resources/". This is **FALSE** — r23 §1403–1426 IS that canonical with the full `LEADING CANONICAL — mode / most-frequent-value-per-group (the single most common x per y)` section header, extensive keyword anchors including "the mode", "mode per group", "which X appears most often per Y", "the single most common X for each Y", and the worked example using `max_by(x, cnt)` over a `COUNT(*) GROUP BY` subquery. So the FIX-A is NOT a new canonical.

**FIX-A WARRANTED (LIGHT, two-part):**

1. **r23 §1428 DO-NOT-WRITE row** — add explicit defang for the `COUNT(*) OVER (PARTITION BY customer_id)` + `GROUP BY customer_id, error_code` anti-pattern with the inline-WRONG annotation that this returns the number-of-distinct-error_codes-per-customer (constant), not the per-pair frequency. Show that the fix is a single character: replace the window `OVER` with plain aggregate. This is the exact failure mode that produced the alphabetically-first-not-mode result. Keyword anchor it on: "ROW_NUMBER mode per group", "ranked frequency per group", "COUNT(*) OVER with GROUP BY", "freq is constant".

2. **r07 cross-ref to r23 §1403** — r07 (analytical patterns) is the keyword-magnet for "weekly report of most frequent X per Y" questions; it currently has NO pointer to the r23 §1403 mode canonical (verified via grep). Add a one-line cross-ref at the top of r07's aggregation section: "For **mode / most-frequent value per group** (the single most common X per Y), see [r23 §LEADING CANONICAL — mode/most-frequent-value-per-group](23-sql-best-practices-olap.md#leading-canonical--mode--most-frequent-value-per-group-the-single-most-common-x-per-y) — `max_by(x, cnt)` over a `COUNT(*) GROUP BY (group, x)` subquery is the canonical form. Do NOT mix `COUNT(*) OVER (PARTITION BY ...)` with `GROUP BY` — see the §1428 DO-NOT-WRITE row."

The responder reached for the ROW_NUMBER-rank-1 form (correct intuition) but built the inner `freq` with a window function over a GROUP BY (broken). The defang + cross-ref pair makes both the broken anti-pattern and the corrected form findable from the question's keyword path.

Watch label: `iter1237 Q2 window-COUNT-mixed-with-GROUP-BY mode-per-group-broken`: re-probe under "most frequent X per Y weekly" framing after FIX-A; 3-6 iters.

---

### Q3 — dbt snapshots vs regular models, config to track plan_tier changes → 1.0 (dbt snapshots SCD2 topic row)

**VERIFIED: outright BAIL when canonical exists with strong anchors.**

**Resource state (confirmed via grep):**

- **r09 §357 has the LEADING CANONICAL** for dbt snapshots with the full block:
  - Findability anchor (§357): literally lists "dbt snapshot", "dbt snapshots", "SCD2 strategy", "snapshot strategy=timestamp", "snapshot strategy=check", "check_cols", "dbt_valid_from", "dbt_valid_to", "dbt_scd_id", "dbt_is_deleted", "current rows from a dbt snapshot", + ~20 other anchors.
  - §368–382: `strategy='timestamp'` worked example with `{% snapshot users_snapshot %}` block, `unique_key`/`strategy`/`updated_at` config.
  - §386–416: `strategy='check'` worked example with `check_cols=[...]` config + the `'all'` shorthand.
  - §453–469: the 4 always-present metadata columns + the canonical query patterns.
- **r27 §290 cross-ref** to r09's SCD section is **literally one line above** the §3.1 materializations table at §292 that the responder DID read.

**Responder bailed**: "I don't have complete information about dbt snapshots in the resources" — and recommended either a hand-rolled SCD-2 incremental model OR consulting docs.getdbt.com. Both fallbacks are worse than just routing to r09 §357.

**Verified against docs.getdbt.com/docs/build/snapshots** (this iteration):

- A snapshot **records changes to mutable tables over time** (Type-2 SCD) — produces multiple rows per source key, one per state change, with validity timestamps.
- Configuration block syntax with `strategy: 'timestamp'` + `updated_at: 'updated_at'` for sources with reliable timestamps; `strategy: 'check'` + `check_cols: [...]` for sources without.
- Metadata columns added: `dbt_valid_from`, `dbt_valid_to`, `dbt_scd_id`, `dbt_updated_at`, conditionally `dbt_is_deleted` (when `hard_deletes='new_record'`).

All of this matches r09 §357 verbatim. The responder had everything they needed and missed the routing.

**Teacher pre-flag CORRECT — findability fail.**

**FIX-A WARRANTED (LIGHT, surgical findability fix):**

The responder reached r27 §292 (`### 3.1 The four materializations supported by dbt-trino`) — the cross-ref at §290 is ONE LINE ABOVE that section header but didn't pull the responder. Surgical fix: add a row INSIDE the §3.1 materializations table (or as a prominent inline note RIGHT AFTER the table) explicitly naming `snapshot` as a separate dbt resource type with the keyword "snapshot" appearing in the table the responder reaches:

Option A (preferred — add a row to the §3.1 table itself):

```
| **`snapshot`** (separate dbt resource type — NOT a materialization) | A **TABLE** + SCD-2 metadata columns (`dbt_valid_from`/`dbt_valid_to`/`dbt_scd_id`) | YES — every historical version | Full (one row per state change) | dbt-managed: timestamp or check strategy detects source changes, closes prior version, inserts new | **Tracking history of mutable dimension columns** (plan_tier upgrades, account_tier changes, status transitions) — Type-2 SCD pattern | When source is append-only (snapshots add overhead with no benefit) — use `incremental` |
| | See [resource 09 § Slowly Changing Dimensions](09-lakehouse-schema-design.md#slowly-changing-dimensions-scd) for snapshot strategy=timestamp/check, hard_deletes, full worked examples. | | | | | |
```

Option B (lighter — bold inline note RIGHT AFTER the §3.1 table at §301):

> **NOTE — dbt also has a separate `snapshot` resource type that is NOT in the four-materialization list above. Snapshots are dbt's first-class SCD-2 / history-tracking primitive (timestamp or check strategy + auto-generated `dbt_valid_from`/`dbt_valid_to`/`dbt_scd_id`/`dbt_updated_at` validity columns). When the question is "track plan_tier / status / billing_tier changes over time" or "the source overwrites in place but we need history", reach for a SNAPSHOT, not an incremental model. Full canonical: see [resource 09 § Slowly Changing Dimensions — Option 1 dbt snapshot](09-lakehouse-schema-design.md#slowly-changing-dimensions-scd).**

Either option puts "snapshot" inside the responder's keyword-line-of-sight at the materializations table they DID reach. The current §290 cross-ref placement is too far above the table to catch the responder reading the table itself.

Watch label: `iter1237 Q3 snapshot-not-in-materializations-list outright-bail`: re-probe under "track plan_tier changes / status history / billing changes over time using dbt" framing after FIX-A; 3-6 iters.

---

### Q4 — Oracle LPAD(invoice_id, 8, '0') → Trino → 4.875 (Oracle PL/SQL → dbt+Trino topic row)

**VERIFIED facts (trino.io/docs/467 this iteration):**

- `lpad(string, size, padstring)` exists in Trino 467 — VERIFIED at [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html).
- Truncation-to-size behavior — VERIFIED verbatim: "If `size` is less than the length of `string`, the result is truncated to `size` characters."
- First arg must be VARCHAR — VERIFIED (signature is `lpad(string, size, padstring) → varchar`); integer requires `CAST(invoice_id AS VARCHAR)`.
- `format('%08d', invoice_id)` — VERIFIED via [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html); example `SELECT format('%03d', 8)` → `'008'`. Uses Java `Formatter` spec (zero-padding via `%0Nd` works for the min-width case — `'%08d'` pads to at least 8 chars without truncating longer values).

**Responder's answer (clean):**

`lpad(CAST(invoice_id AS VARCHAR), 8, '0')` correct + truncation-hazard caveat correct + `format('%08d', invoice_id)` min-width alternative correct + integer-requires-CAST caveat correct.

No FIX-A. Cites r27. Closes naturally.

---

## FIX-A summary

**TWO LIGHT FIX-A warranted, both surgical findability fixes (canonicals already exist):**

1. **Q2 — r23 §1428 DO-NOT-WRITE row** for the `COUNT(*) OVER (PARTITION BY x)` + `GROUP BY x, y` anti-pattern, with explicit "returns the count of distinct y-values per x (constant), NOT the per-pair frequency" annotation + the one-character fix (replace window `OVER` with plain aggregate). **PLUS r07 cross-ref to r23 §1403 mode canonical** at the top of r07's aggregation section.

2. **Q3 — r27 §3.1 materializations table** — add `snapshot` row to the table itself (Option A above) OR a prominent bolded inline note right after the table (Option B) explicitly naming "snapshot" as a separate dbt resource type with cross-ref to r09 §SCD. The current §290 cross-ref above the table didn't pull the responder.

Neither FIX-A creates a new canonical — both surface existing canonicals (r23 §1403 mode, r09 §357 snapshot) at the keyword path the responder DID reach.

## Open watches

- **iter1237 Q2 window-COUNT-mixed-with-GROUP-BY mode-per-group-broken** (PRIMARY) — re-probe after FIX-A under "most frequent X per Y weekly" framing.
- **iter1237 Q3 snapshot-not-in-materializations-list outright-bail** (PRIMARY) — re-probe after FIX-A under "track plan_tier / status changes over time using dbt" framing.
- **iter1237 Q1 add-NOT-NULL-on-Iceberg framing-could-name-dbt-not_null-test** (SOFT) — re-probe under "how do I enforce non-null on a new column on this stack" framing; no FIX-A.
- Carry-over: iter1236 source-side-NOT-EXISTS-without-rn=1-within-batch-pairing (soft); iter1234 ROLLUP-date_trunc-expr (soft); iter1234 FOR-VERSION-AS-OF-quoting (passive); iter1233 IGNORE-NULLS-framing; iter1231 NEXT_DAY-note; iter1230 EXISTS-overwarning/::cast; iter1215 strpos-3-arg CEILING (CLOSED iter1236); iter1213 session_properties/(+); iter1229 @v1-Spark; iter1208 width_bucket.

## Topic rubric impact

| Topic | Before | Q | Δ | After | Margin to threshold |
|---|---|---|---|---|---|
| Lakehouse schema design (line 62) | 4.5729 / 18 | Q1=4.25 | -0.0170 | 4.5559 / 19 | +1.0559 |
| Analytical query patterns on Iceberg+Trino (line 89) | 4.5554 / 169 | Q2=1.5 | -0.0180 | 4.5374 / 170 | +1.0374 |
| dbt snapshots SCD2 (line 561) | 4.3127 / 24 | Q3=1.0 | -0.1325 | 4.1802 / 25 | +0.6802 (-0.13 hit — most-impacted row) |
| Oracle PL/SQL → dbt+Trino (line 382) | 4.4630 / 202 | Q4=4.875 | +0.0020 | 4.4650 / 203 | +0.9650 |

All required topics remain PASSED. dbt snapshots SCD2 took the largest single-iter hit (-0.1325) but still has +0.6802 margin to the 3.5 threshold. With the FIX-A applied + re-probe in 3-6 iters expected to score >4.0, the row should recover.

## Overall

**FAIL iter (2.91 avg).** The 20-consecutive-1st-re-probe-CLOSE streak broke on this iteration with two simultaneous findability defects (Q2 + Q3) plus a clean Q1 + Q4 bracketing. Both Q2 and Q3 failures share a root cause: the responder reads the WRONG resource section for a question whose keywords would route correctly if the canonical were one cross-ref closer to the table/list the responder DOES reach. Both FIX-As are LIGHT and surgical — adding a DO-NOT-WRITE row + cross-ref for Q2's mode-per-group, and a materializations-table row OR prominent inline note for Q3's snapshot-resource-type. Neither requires new canonical content. Re-probe both watches under varied phrasings (`most-popular`, `which X most often`, `mode` for Q2; `track changes over time`, `plan history`, `SCD-2 in dbt` for Q3) over the next 3-6 iters to confirm fix reach.
