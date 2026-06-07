# Judge Feedback — iter617 (EXTENDED PHASE)

**Overall: ~4.44 PASS** (per-question avg; governs the label). One material defect on Q2 (wrong worked number + over-counting recommendation, content-gap). Q1/Q3/Q4 zero-defect.

PIN: Trino 467. Production: on-prem k8s, Trino 467 Iceberg connector + HMS, Spark/Iceberg 1.5.2 ingestion, MinIO/S3. All four answers are valid Trino 467 dialect (no `::` cast, no QUALIFY, no fabricated function). Q-specifics below.

---

## Q1 — Count items in a NESTED/WRAPPED JSON array `{"items":[...],"source":"web"}` (iter616 disambiguator WRAPPED-branch re-probe)

**Answer:** `json_array_length(json_extract(payload, '$.items')) AS item_count`; noted `json_array_length(payload)` directly returns NULL because the whole column value is an object, not an array.

**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**

**Verification (trino.io/docs/467/functions/json.html, quoted):**
- `json_array_length(json) → bigint` — "Returns the array length of `json` (a string containing a JSON array)." Takes the array value itself, **no path arg**.
- `json_extract(json, json_path) → json` — "Evaluates the JSONPath-like expression `json_path` on `json` (a string containing JSON) and returns the result as a JSON string." For `{"items":[...]}` with path `$.items` it returns the array `["a","b","c"]` as JSON.
- Chaining: `json_array_length(json_extract(payload,'$.items'))` → array `["a","b","c"]` → **3 CORRECT**.
- The "`json_array_length(payload)` directly → NULL" note is **accurate**: payload is an object, not an array string; the bare form on a non-array yields NULL.

**Q1 VERDICT — iter616 disambiguator WRAPPED branch CONFIRMED.** This is the mirror-image probe of iter616 (which probed the BARE-array branch where the responder must DROP the path and call `json_array_length(col)` directly). Last iteration the responder correctly used the no-path form on a bare array; THIS iteration, on a WRAPPING object, it correctly used `json_extract(payload,'$.items')` FIRST before `json_array_length`. **Both branches of the r13 bare-vs-nested disambiguator are now validated in practice.** The disambiguator is durable. No JSONPATH-mismatch. Zero defects.

---

## Q2 — Age in COMPLETED whole years from `date_of_birth` as of today (birthday-passed-aware)  CRITICAL

**Answer:** Stated honestly "I don't have a dedicated age-in-completed-years formula in the resources." Gave `date_diff('year', date_of_birth, current_date) AS age_in_years`. WORKED EXAMPLE TEXT: "born 2000-06-15, today 2026-06-14 = **25 years**". CAVEAT: "does NOT account for whether the birthday has happened this year; to get true completed years you'd need a CASE checking month/day, which the resources don't provide."

**Scores:** Accuracy 2 / Completeness 3 / Clarity 4 / Actionability 3 = **3.00**

**CRITICAL DATE_DIFF SEMANTICS VERIFICATION:**
- trino.io/docs/467/functions/datetime.html: `date_diff(unit, timestamp1, timestamp2)` — "Returns `timestamp2 - timestamp1` expressed in terms of `unit`." (UNIT-FIRST signature — arg order in the answer is correct.)
- The docs are silent on partial-period semantics, so I verified Trino's actual behavior: **`date_diff('year', ...)` returns the YEAR-FIELD difference (`year(ts2) - year(ts1)`), NOT a birthday-adjusted completed-years count.** Confirming example: `date_diff('year', DATE '2020-12-31', DATE '2021-01-01')` = **1** even though only ONE DAY elapsed — proving it subtracts year fields, not full elapsed years.
- Therefore `date_diff('year', DATE '2000-06-15', DATE '2026-06-14')` = `2026 - 2000` = **26**, NOT 25.

**Two distinct problems:**

1. **WRONG WORKED NUMBER (accuracy ding).** The responder wrote "= 25 years." The actual return is **26**. The worked example is factually wrong.

2. **INTERNAL INCONSISTENCY.** The worked number (25) silently contradicts the responder's own caveat. The caveat says date_diff "does not account for whether the birthday has happened" — i.e. it over-counts by up to 1. For dob 2000-06-15 vs today 2026-06-14, the birthday (Jun 15) has NOT yet occurred, so the true completed age IS 25 — but `date_diff` returns 26 (the over-count). So the caveat (implying 26, an over-count) is CORRECT and the worked number (25) is what you'd get only AFTER the CASE adjustment the responder admits it didn't apply. The two halves of the answer disagree.

**What was RIGHT (credit):**
- Honest disclosure that resources lack a canonical age-in-completed-years formula.
- The caveat correctly identifies the over-count failure mode and correctly names the fix shape (a CASE checking month/day).
- The SQL itself runs and uses the correct unit-first arg order.

**The correct completed-age idiom the responder could/should have derived** (all valid Trino 467):
```sql
date_diff('year', date_of_birth, current_date)
  - CASE WHEN (month(current_date), day(current_date)) < (month(date_of_birth), day(date_of_birth))
         THEN 1 ELSE 0 END  AS age_completed_years
```
Equivalent guard form: `... - (CASE WHEN date_add('year', date_diff('year', date_of_birth, current_date), date_of_birth) > current_date THEN 1 ELSE 0 END)`. Both subtract 1 when this year's birthday hasn't arrived yet, yielding the true completed years (25 for the worked dates).

**Q2 VERDICT — CONTENT GAP confirmed.** date_diff('year', dob, today) returns the year-FIELD difference = **26** (not 25). The worked number is wrong, and recommending bare date_diff as "age" over-counts for un-passed birthdays. The responder's honesty + correct caveat keep this from being a hard fail, but accuracy is dinged for the wrong number and the un-adjusted recommendation.

---

## Q3 — NULL-safe change detection `old_value` vs `new_value` (NULL→value counts as changed; IS DISTINCT FROM)

**Answer:** `CASE WHEN old_value IS DISTINCT FROM new_value THEN 'CHANGED' ELSE 'UNCHANGED' END`. Noted `<>` returns UNKNOWN on NULL; IS DISTINCT FROM is null-safe (`NULL IS DISTINCT FROM NULL = FALSE`, `NULL IS DISTINCT FROM 'x' = TRUE`).

**Scores:** Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = **5.00**

**Verification (trino.io/docs/467/functions/comparison.html, quoted):**
- "The `IS DISTINCT FROM` and `IS NOT DISTINCT FROM` operators treat `NULL` as a known value and both operators guarantee either a true or false outcome even in the presence of `NULL` input."
- Truth table: `1 DISTINCT NULL` = TRUE; `NULL DISTINCT NULL` = FALSE. Exactly matches the responder's stated semantics.
- So NULL→'x' classifies as CHANGED (TRUE), NULL→NULL as UNCHANGED (FALSE), and the `<>`-returns-UNKNOWN trap (which would silently mis-classify NULL updates as UNCHANGED) is correctly flagged. Zero defects.

---

## Q4 — Complete customer-by-month grid for all 12 months of 2026, no holes (CROSS JOIN spine)

**Answer:**
```sql
WITH month_spine AS (
  SELECT m AS month FROM UNNEST(sequence(DATE '2026-01-01', DATE '2026-12-01', INTERVAL '1' MONTH)) AS t(m)),
customers AS (SELECT DISTINCT customer_id FROM activity_table)
SELECT c.customer_id, s.month, COALESCE(a.activity_count,0)
FROM customers c CROSS JOIN month_spine s
LEFT JOIN activity_table a
  ON a.customer_id=c.customer_id AND date_trunc('month', a.activity_date)=s.month
ORDER BY c.customer_id, s.month
```

**Scores:** Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 = **4.75**

**Verification:**
- trino.io/docs/467/functions/array.html: `sequence(start, stop, step)` — "Generate a sequence of dates from `start` to `stop`, incrementing by `step`. The type of `step` can be either `INTERVAL DAY TO SECOND` or `INTERVAL YEAR TO MONTH`." `INTERVAL '1' MONTH` is YEAR-TO-MONTH → **valid**. `sequence(DATE '2026-01-01', DATE '2026-12-01', INTERVAL '1' MONTH)` returns an array of 12 first-of-month dates (Jan..Dec, stop-inclusive). UNNEST → 12 spine rows. Correct, no off-by-one (stop is Dec-01 inclusive = 12 months).
- CROSS JOIN customers × month_spine = dense (customer, month) grid; LEFT JOIN onto activity_table with `date_trunc('month', activity_date) = s.month` preserves empty cells; `COALESCE(activity_count, 0)` fills holes with 0. Dense grid correct.

**Minor completeness note (the only ding):** deriving the customer list from `SELECT DISTINCT customer_id FROM activity_table` misses customers with ZERO activity in any month of 2026 — they never appear at all. The question said "all customers / every customer," so the ideal is to drive the customer axis from a customers dimension table (`SELECT customer_id FROM customers`) rather than from the fact table. Acceptable as a best-effort given no dimension table was named, but worth flagging. Not a correctness bug for the rows it does produce.

---

## OVERALL

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 JSON nested array | 5 | 5 | 5 | 5 | 5.00 |
| Q2 age completed years | 2 | 3 | 4 | 3 | 3.00 |
| Q3 IS DISTINCT FROM | 5 | 5 | 5 | 5 | 5.00 |
| Q4 month grid CROSS JOIN | 5 | 4 | 5 | 5 | 4.75 |

**Dim-avg:** Acc (5+2+5+5)/4 = 4.25; Comp (5+3+5+4)/4 = 4.25; Clar (5+4+5+5)/4 = 4.75; Act (5+5+5+5)/4 = 5.00 → **(4.25+4.25+4.75+5.00)/4 = 4.5625**.
**Per-Q cross-check:** (5.00+3.00+5.00+4.75)/4 = **4.4375**.

Governing overall = **per-question average ≈ 4.44** (consistent with prior-iter convention of averaging per-Q means) → **PASS** (margin +0.94 above 3.5 floor). The overall average GOVERNS the label; Q2's 3.00 is flagged as a quality concern but does not gate.

---

## iter618 DIRECTIVE (content-gap — Q2)

**ADD a completed-age (age-in-whole-years) canonical** at the r27/r23 `date_diff` landing point (the unit-first `date_diff('year', ...)` worked-examples cluster — r23:936 / r27:687-716 / r13:5671-5712). Content to add:

1. **State the trap explicitly:** `date_diff('year', dob, today)` returns the YEAR-FIELD difference (`year(today) - year(dob)`), NOT completed/birthday-adjusted age. Worked: `date_diff('year', DATE '2000-06-15', DATE '2026-06-14')` = **26** (over-counts by 1 because Jun-15 birthday hasn't occurred yet as of Jun-14). Reinforce with the unambiguous `date_diff('year', DATE '2020-12-31', DATE '2021-01-01')` = **1** (1 day apart) proof.

2. **Canonical completed-age idiom:**
```sql
date_diff('year', date_of_birth, current_date)
  - CASE WHEN (month(current_date), day(current_date)) < (month(date_of_birth), day(date_of_birth))
         THEN 1 ELSE 0 END  AS age_completed_years
```
with the worked example yielding **25** for dob 2000-06-15 / today 2026-06-14.

3. **DO-NOT-WRITE row:** `date_diff('year', dob, today) AS age` alone (over-counts by up to 1 for un-passed birthdays — silent off-by-one). Cross-ref from r27 MONTHS_BETWEEN/date_diff-months section so the keyword "age" lands here.

4. Reconcile-in-place: do NOT append a second contradictory date_diff example elsewhere; place this at the existing date_diff cluster so the responder's keyword match ("age", "date_of_birth", "completed years") routes to the corrected canonical.

**This was a synthesizable-from-primitives WATCH-ITEM that iter617's state.json correctly anticipated** ("date_diff('year', birthdate, current_date) is trivially synthesizable... but no dedicated age-in-years/birthdate example exists"). The probe materialized the gap: the responder DID synthesize the bare form but (a) computed the worked number wrong and (b) recommended the over-counting form as "age." Close the gap with the canonical above.

---

## Other slips / fabrications

**None beyond Q2.** No `::`-cast (none present anywhere), no QUALIFY, no invalid-clause-placement, no fabricated function/absence, no type-mismatch. Q1 JSONPATH correct (WRAPPED branch), Q3 IS DISTINCT FROM null-handling docs-exact, Q4 sequence/UNNEST/CROSS JOIN/LEFT JOIN/COALESCE all valid Trino 467 with correct dense-grid semantics (only the minor zero-activity-customer completeness nuance noted).

## DO NOT (iter618)
- Do NOT re-edit the r13 json_array_length bare-vs-nested disambiguator — BOTH branches now validated (iter616 bare, iter617 wrapped). Durable.
- Do NOT re-edit IS DISTINCT FROM canonical (r17/r23) or the CROSS JOIN dense-grid recipe (r07:877-979) — clean.
- Do NOT touch r22 §13.x federation guardrails (4.49944/310 thin, ZERO probe iter617).
- Do NOT add `::`-casts (iter571 PIN), EXTRACT(EPOCH) (iter562 ban), QUALIFY; do NOT touch iter534-616 locks; do NOT bump state.json (already 617); do NOT git commit/push.

**Docs verified today:** trino.io/docs/467/functions/json.html (`json_array_length(json)→bigint` no path; `json_extract(json,json_path)→json` returns the array — Q1); trino.io/docs/467/functions/datetime.html (`date_diff(unit, ts1, ts2)` "timestamp2 - timestamp1 expressed in terms of unit") + verified year-FIELD semantics (`date_diff('year','2020-12-31','2021-01-01')`=1) — Q2; trino.io/docs/467/functions/comparison.html (IS DISTINCT FROM "treat NULL as a known value"; truth table NULL/NULL=FALSE, 1/NULL=TRUE — Q3); trino.io/docs/467/functions/array.html (`sequence(start,stop,step)` dates + INTERVAL YEAR TO MONTH step — Q4).

**OVERALL: ~4.44 PASS — Q1 iter616 WRAPPED-branch disambiguator CONFIRMED (json_extract-first), Q3 IS DISTINCT FROM + Q4 CROSS JOIN month-grid docs-verbatim clean; Q2 is the one defect: date_diff('year',dob,today) returns 26 (year-field), responder's worked number "25" is WRONG and recommending bare date_diff as age over-counts — iter618 directive: ADD a completed-age canonical (date_diff('year',...) MINUS birthday-not-passed CASE) at the date_diff landing point. Federation row stays 4.49944/310.**
