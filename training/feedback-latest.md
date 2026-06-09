# Judge Feedback — iter810 (FINDABILITY FIX-A verification: concat_ws-columns re-probe + 3 fresh)

**Phase:** extended. Overall **4.50 PASS**. All dialect claims verified against trino.io/docs/467 (string.html, conditional.html, datetime.html, aggregate.html) on 2026-06-09. Production stack confirmed: Trino 467 + Iceberg connector (prod_info.md).

DO NOT bump training/state.json (already 810).

---

## Per-question scores

### Q1 — full_name from title/first/middle/last joined by spaces, skip NULL parts (no double space) — **CONCAT-COLUMNS-SKIP-NULLS RE-PROBE / FIX CHECK**

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Q1 avg** | **5.00** |

**FIX WORKED — concat_ws-columns CLOSED (1st post-fix datapoint).** Responder LED with `concat_ws(' ', title, first_name, middle_name, last_name) AS full_name` and cited the new r07 disambiguator card — NO repeat of the iter809 flounder (no array_agg/CASE single-value collapse, no nonexistent ARRAY_COMPACT, no "if available" hedge, no UNION ALL over-engineering). VERIFIED string.html: *"Any null values provided in the arguments after the separator are skipped"* → `concat_ws(' ', 'Dr.', 'John', NULL, 'Doe')` = `'Dr. John Doe'` (no doubled space). The `NULLIF(col,'')` caveat to also skip empty strings is accurate (empty string is NOT null, so concat_ws keeps it and produces a doubled separator unless wrapped). Clean, correct, leads with the right tool.

### Q2 — first populated of display_name/username/email else 'Anonymous' — **COALESCE FALLBACK CHAIN**

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Q2 avg** | **5.00** |

VERIFIED conditional.html: `coalesce(value1, value2[, ...])` returns first non-null, variadic. `COALESCE(display_name, username, email, 'Anonymous') AS label` is the textbook correct chain — literal `'Anonymous'` tail guarantees a non-null result. The Oracle-NVL-is-2-arg-only contrast is accurate and useful migration context. Standing COALESCE pin holds.

### Q3 — collapse event_timestamp to first of month for monthly GROUP BY — **TRUNCATE TO MONTH**

| Axis | Score |
|---|---|
| Accuracy | 5 |
| Completeness | 5 |
| Clarity | 5 |
| Actionability | 5 |
| **Q3 avg** | **5.00** |

VERIFIED datetime.html: `date_trunc('month', TIMESTAMP '2022-10-20 05:10:00')` = `2022-10-01 00:00:00.000` (first of month, midnight). `date_trunc('month', event_timestamp) AS month_start ... GROUP BY date_trunc('month', event_timestamp)` correct — repeating the expression in GROUP BY (rather than the alias) is the safe Trino idiom. Standing date_trunc pin holds.

### Q4 — per-order has_placed/has_shipped/has_delivered true/false flags from event rows — **PIVOT TO BOOLEAN FLAGS**

| Axis | Score |
|---|---|
| Accuracy | 2.5 |
| Completeness | 3.5 |
| Clarity | 2.5 |
| Actionability | 3.5 |
| **Q4 avg** | **3.00** |

**PRIMARY correct; ALTERNATIVE buggy + redundant; clean idiom missed.**

- **PRIMARY — CORRECT.** `MAX(CASE WHEN event_type='placed' THEN 1 ELSE 0 END) AS has_placed` (+ shipped/delivered) `GROUP BY order_id`: returns 1 if ANY matching event row exists, else 0 (CASE emits 0 for non-matching rows, so an order with no 'placed' row correctly yields MAX=0). Single-pass conditional-aggregation pivot — standing SUM/MAX-CASE-pivot pattern. (Minor: question asked for true/false; MAX(CASE)→1/0 is an integer flag, acceptable but not the literal boolean shape requested.)

- **ALTERNATIVE — BUGGY (DEFECT).** The responder offered `MAX(CASE WHEN event_type='placed' THEN 1 ELSE 0 END) FILTER (WHERE event_type='placed') AS has_placed` and claimed it is an "equivalent, cleaner" form. It is NOT equivalent. VERIFIED aggregate.html (FILTER + empty-input semantics): the FILTER restricts the aggregate to rows where `event_type='placed'`; within those rows CASE is always 1 so MAX=1 — but for an order with NO 'placed' event the FILTER leaves ZERO rows for that aggregate, and an aggregate over zero rows returns **NULL** (docs: aggregates "return null for no input rows"). So `has_placed = NULL` instead of `0`/false for the absent case — DIFFERENT result from the primary, and wrong for the question (a missing event should read false, not null). It is also **redundant**: CASE and FILTER gate on the same predicate (doubly-conditional, nonsensical). Presenting a buggy form as "equivalent/cleaner" is the Accuracy + Clarity hit.

- **CLEAN IDIOM MISSED.** The genuinely cleaner, true/false-shaped, docs-canonical idiom is `bool_or(event_type='placed') AS has_placed` (+ shipped/delivered) — VERIFIED aggregate.html: `bool_or(boolean)` *"Returns TRUE if any input value is TRUE, otherwise FALSE"* → true/false per order, FALSE (not NULL) for an order with no matching event (the non-matching rows ARE input rows that evaluate the predicate to FALSE). Equivalently `COUNT(*) FILTER (WHERE event_type='placed') > 0`. This idiom exists in resources at **r23 §3.1 lines 1099-1136** (`bool_or`/`bool_and` card, fully docs-canonical, with an explicit "prefer bool_or over MAX(bool_col)" rule) — the responder never reached it. It cited r07's metric-summing pivot card (lines 1196-1230) where the FILTER predicate gates on the *pivot key* and CASE returns the *metric* (a correct equivalence for SUM-of-metric), then mis-transplanted that shape onto a boolean presence-check by gating BOTH the CASE and the FILTER on the same predicate. Findability gap: the boolean-flag pivot keyword path (has_X true/false per group) is NOT routed to the r23 bool_or card.

---

## Verdicts

**(a) Is concat_ws-columns CLOSED?** YES — Q1 fix WORKED. Responder led with `concat_ws(' ', col, col, ...)`, cited the new r07 §1a.2 disambiguator, correct skips-nulls + NULLIF-empty caveat, zero repeat of the iter809 flounder. 1st clean post-fix datapoint. CLOSED (needs 1 more phrasing to BULLETPROOF).

**(b) Q4 verdict.** PRIMARY `MAX(CASE WHEN cond THEN 1 ELSE 0 END) GROUP BY order_id` is CORRECT (0/1, 0 for absent). The offered ALTERNATIVE `MAX(CASE...) FILTER (WHERE same-cond)` is a DEFECT: returns **NULL not 0/false** for orders lacking the event (empty FILTER → NULL aggregate, verified), and is redundant (CASE+FILTER both gate the same predicate). The clean boolean-flag idiom the responder should have led with is `bool_or(event_type='placed') AS has_placed` (true/false, docs-canonical, present at r23 §3.1:1099-1136) — or `COUNT(*) FILTER (WHERE cond) > 0`. User CAN get a working answer (primary), but the offered "cleaner" alternative is wrong-and-misleading.

**(c) iter811 designation — LIGHT INOCULATION FIX-A.** The boolean-flag pivot card warrants a fix. Two reasons: (1) the clean `bool_or` idiom is buried at r23 §3.1, not surfaced at the r07 pivot landing where the responder lands for "per-order has_X flags"; (2) the responder synthesized a NULL-returning redundant MAX(CASE)+FILTER and called it equivalent — this exact anti-pattern needs an inline defang. Recommended:
   1. At r07 (boolean-flag pivot landing, near the §pivot card ~line 1196-1230), add a `bool_or(pred) AS has_X` CANONICAL boolean-flag-pivot block ("per-group did-ANY-event-happen true/false flags") + cross-ref to r23 §3.1:1099-1136. Make `bool_or(event_type='placed')` the copy-attractive one-liner for true/false flags.
   2. Inline-DEFANG the redundant `MAX(CASE WHEN cond THEN 1 ELSE 0 END) FILTER (WHERE cond)` form: mark it WRONG/un-copyable, state explicitly it returns **NULL (not 0/false)** for groups with no matching row AND is doubly-conditional. Per the Defang-DO-NOT-WRITE memory: make the bool_or block the copy-attractive canonical, the buggy combo un-copyable.
   3. Note the distinction: in the metric-summing pivot the FILTER gates the *pivot key* while CASE returns the *metric* (correct/equivalent); the boolean-flag case must NOT double-gate on the same predicate.
   PRESERVE the iter810 concat_ws disambiguator (working), COALESCE pin, date_trunc pin, r23 §3.1 bool_or card.

---

## Overall

(5.00 + 5.00 + 5.00 + 3.00) / 4 = **4.50 PASS**.

concat_ws-columns FIX WORKED / CLOSED. Q2/Q3 clean (standing pins hold). Q4 primary correct but offered alternative is a buggy redundant MAX(CASE)+FILTER (NULL-not-0 for absent); `bool_or(cond)` is the clean boolean-flag idiom and should be surfaced/canonicalized in iter811.
