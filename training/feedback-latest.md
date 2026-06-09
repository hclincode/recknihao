# Judge Feedback — iter811 (LIGHT INOCULATION FIX-A: bool_or boolean-flag-pivot)

**Date**: 2026-06-09
**Phase**: extended
**Verification**: every dialect claim checked against trino.io/docs/467 (aggregate / conditional / comparison / select .html). Resources NOT treated as ground truth. Production stack confirmed: Trino 467 + Iceberg connector (prod_info.md).

DO NOT bump training/state.json (already 811).

---

## Per-question scores

### Q1 — Boolean-flag pivot RE-PROBE (ever_logged_in / ever_purchased / ever_ticketed from event rows)
Answer: `bool_or(event_name='logged_in') AS has_logged_in` (+ made_purchase / opened_ticket) `GROUP BY user_id` — TRUE if any row in the group satisfies the predicate. Cites r23 bool_or card.

- Accuracy: **5** — Verified aggregate.html: `bool_or(boolean)` returns TRUE if any input is true, FALSE if none (over a non-empty group). `bool_or(event_name='logged_in') GROUP BY user_id` is exactly the ever-flag; users with no such event get FALSE (not NULL). Clean.
- Completeness: **5** — Covers all three flags, the GROUP BY, and the any-row-satisfies semantics.
- Clarity: **5** — Plain-language "TRUE if any row satisfies"; no assumed OLAP knowledge.
- Actionability: **5** — Drop-in query the engineer can run.
- **Per-Q avg: 5.00 CLEAN**

**FIX CHECK — WORKED.** The responder LED with `bool_or` and cited the bool_or card. It did NOT reach for the iter810 buggy `MAX(CASE)+FILTER` (which returns NULL-not-0 for absent events) nor the redundant CASE+FILTER double-gate. This is the 1st post-fix datapoint for the boolean-flag-pivot defect. The r07 bool_or pivot card + the defang of MAX(CASE)+FILTER landed correctly.

### Q2 — Earlier of two dates (effective_date = earlier of due_date, completed_date, across columns)
Answer: `least(due_date, completed_date) AS effective_date` — row-wise min across columns (vs MIN() aggregate across rows); notes NULL-propagation (least returns NULL if any arg NULL); COALESCE(col, DATE '9999-12-31') sentinel to skip NULLs. Cites r27 §4.4D.

- Accuracy: **5** — Verified comparison.html: `least(v1,...,vN)` returns the smallest value row-wise across arguments; "return null if any argument is null" (Trino, explicitly contrasted with Postgres which only nulls if ALL are null). The NULL-propagation caveat and the COALESCE-sentinel workaround are both correct and idiomatic.
- Completeness: **5** — Addresses across-columns-vs-across-rows distinction AND the NULL edge case the engineer would hit.
- Clarity: **5** — least-vs-MIN() framing is exactly the beginner confusion to pre-empt.
- Actionability: **5** — Both the simple form and the NULL-tolerant form given.
- **Per-Q avg: 5.00 CLEAN** (standing greatest/least-row-wise-NULL-if-any pin reinforced)

### Q3 — Dedup exact duplicate rows (no primary key)
Answer: `SELECT DISTINCT * FROM staging_table;` and `CREATE TABLE ... AS SELECT DISTINCT *` to persist. Cites r13.

- Accuracy: **5** — Verified select.html: DISTINCT includes only unique rows; `SELECT DISTINCT *` = one row per unique full-row combination = exact-duplicate removal. CTAS-with-DISTINCT persists. Correct.
- Completeness: **5** — Covers both the inspect query and the persist path.
- Clarity: **5** — Direct, no jargon.
- Actionability: **5** — Runnable as-is; CTAS form fits the prod export workflow.
- **Per-Q avg: 5.00 CLEAN** (standing SELECT-DISTINCT-dedup pin)

### Q4 — Numeric → label buckets (response_time_ms: fast <100 / ok 100-500 / slow >500)
Answer: `CASE WHEN response_time_ms < 100 THEN 'fast' WHEN response_time_ms <= 500 THEN 'ok' ELSE 'slow' END` — first-match top-to-bottom; notes if() for 2-way. Cites r23 IF/CASE.

- Accuracy: **5** — Verified conditional.html: searched CASE evaluates conditions top-to-bottom, returns first true match. Boundaries correct: `<100`→'fast'; the `<=500` branch only fires for values not already consumed by `<100`, so 100-500 (inclusive of 500) maps to 'ok'; ELSE (>500) maps to 'slow'. if() 2-way note accurate.
- Completeness: **5** — Handles the inclusive boundary at 500 correctly and explains first-match ordering.
- Clarity: **5** — Top-to-bottom-first-match is the key mental model and it is stated.
- Actionability: **5** — Drop-in.
- **Per-Q avg: 5.00 CLEAN** (standing CASE-WHEN-tiering-first-match pin)

---

## Overall

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 5 | 5 | 5 | 5.00 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**Overall avg: 5.00 — STRONG PASS** (threshold 3.5)

All four docs-verified clean against trino.io/docs/467. No new defect surfaced.

---

## Teacher feedback

(a) **Is boolean-flag-pivot CLOSED? YES.** Q1 fix worked — 1st post-fix datapoint. The responder led with `bool_or(pred) AS has_X` from the new r07 pivot-landing card and did NOT regress to the iter810 buggy `MAX(CASE)+FILTER` (NULL-not-0 absent) form, which is now inline-defanged. CLOSED. Per the two-angle rule, one more boolean-flag-pivot re-probe from a different phrasing (e.g. true/false vs 1/0, or with an empty group) is recommended before treating it as fully bulletproofed.

(b) **iter812 designation: DEFAULT NO-OP / durability-breadth sweep.** No open defect. Recommended: 2nd-angle re-probe of boolean-flag-pivot (bool_or with a 1/0 phrasing or empty-group edge to confirm FALSE-not-NULL behavior) + 3 fresh adjacent topics. PRESERVE: r07 bool_or pivot card + MAX(CASE)+FILTER defang / r27 §4.4D least-greatest-NULL card / r13 SELECT DISTINCT dedup / r23 IF-CASE tiering card, plus the full iter534-810 pin inventory.

DO NOT bump training/state.json (teacher already set it to 811).
