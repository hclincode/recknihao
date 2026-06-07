# Judge Feedback — iter597

**Date**: 2026-06-07
**Phase**: extended
**Trino version pin**: 467
**Mode**: PASS/FAIL determined by overall average ≥ 3.5

---

## Per-question scores

### Q1 — bool_or RE-PROBE (boolean any/all per group)

**Question**: login_attempts table, boolean succeeded flag, GROUP BY user_id; per user a single true/false: (a) AT LEAST ONE success (b) ALL attempts succeed; cleanest Trino way to roll up true/false per group.

**Responder answer summary**: LED with `bool_or(succeeded) AS had_any_success` + `bool_and(succeeded) AS all_succeeded`. Explained bool_or=TRUE if any input value is TRUE, bool_and=TRUE only if every input value is TRUE; both return single boolean per group. Explicitly steered users AWAY from `MAX(succeeded)` / `MIN(succeeded)` — "while those technically work (boolean orderable TRUE>FALSE), they signal the wrong intent and cost more."

**Verification** (trino.io/docs/467/functions/aggregate.html, fetched 2026-06-07):
- `bool_or(boolean) -> boolean` — *"Returns TRUE if any input value is TRUE, otherwise FALSE."* CONFIRMED.
- `bool_and(boolean) -> boolean` — *"Returns TRUE if every input value is TRUE, otherwise FALSE."* CONFIRMED.

**bool_or/bool_and GAP RESOLUTION STATUS**: RESOLVED.
- iter596 gap: responder routed to count_if(...) > 0 / MAX(boolean) / CASE workarounds because bool_or/bool_and was absent from r23+r07.
- iter597 canonical (H4 sub-block adjacent to §3.1E count_if neighborhood) ROUTED CORRECTLY. The responder now LEADS with `bool_or` / `bool_and`, exactly matches the docs-canonical idiom, AND actively steers away from `MAX(boolean)` with a docs-grounded rationale.

| Dimension | Score | Rationale |
|---|---|---|
| Accuracy | 5 | bool_or/bool_and signatures + behavior match Trino 467 docs verbatim. Anti-pattern call-out on MAX(boolean) is technically defensible (max() docs do not enumerate boolean). |
| Completeness | 5 | Both (a) ANY and (b) ALL covered with the exact paired idiom; explicitly addresses the wrong-frame alternatives the engineer might reach for. |
| Clarity | 5 | "Single TRUE/FALSE per group" framing matches engineer mental model; column aliases (had_any_success, all_succeeded) reinforce semantics. |
| Actionability | 5 | Drop-in query template against the exact table shape the engineer named. |

**Q1 avg = 5.00**

---

### Q2 — year/month extraction from DATE for GROUP BY

**Question**: orders.order_date is a DATE; extract year number + month number to GROUP BY for a monthly trend.

**Responder answer summary**: `EXTRACT(YEAR FROM order_date)` + `EXTRACT(MONTH FROM order_date)` in SELECT + GROUP BY. ALSO offered `date_trunc('month', order_date)` as a cleaner alternative (stays DATE-typed, first-of-month).

**Verification** (trino.io/docs/467/functions/datetime.html, fetched 2026-06-07):
- EXTRACT: *"Returns `field` from `x`"* with YEAR and MONTH among supported fields. *"The types supported by the extract function vary depending on the field to be extracted. Most fields support all date and time types."* CONFIRMED for DATE.
- year(x): *"Returns the year from `x`."* CONFIRMED.
- month(x): *"Returns the month of the year from `x`."* CONFIRMED.
- date_trunc(unit, x): *"Returns `x` truncated to `unit`"* with 'month' supported. CONFIRMED.
- EPOCH non-support (iter562 lock) is irrelevant here — YEAR and MONTH are documented fields.

| Dimension | Score | Rationale |
|---|---|---|
| Accuracy | 5 | EXTRACT(YEAR/MONTH FROM date) + date_trunc('month', date) are both valid Trino 467. |
| Completeness | 4 | Covers EXTRACT + date_trunc alternative cleanly. Minor: did not mention the equivalent shorter `year(order_date)` / `month(order_date)` function forms — they exist per docs and some engineers prefer them; small completeness ding. |
| Clarity | 5 | Two-option framing (extract integers vs. truncate-to-first-of-month) with clear trade-off (stays DATE-typed). |
| Actionability | 5 | Engineer can paste either form into a GROUP BY immediately. |

**Q2 avg = 4.75**

---

### Q3 — MIN/MAX per group

**Question**: price_history (product_id, price); lowest + highest price per product.

**Responder answer summary**: `SELECT product_id, MIN(price) AS lowest_price, MAX(price) AS highest_price FROM price_history GROUP BY product_id`.

**Verification** (trino.io/docs/467/functions/aggregate.html):
- `min(x) -> [same as input]` — *"Returns the minimum value of all input values."* CONFIRMED.
- `max(x) -> [same as input]` — *"Returns the maximum value of all input values."* CONFIRMED.
- Both operate per GROUP BY. CONFIRMED.

| Dimension | Score | Rationale |
|---|---|---|
| Accuracy | 5 | MIN/MAX with GROUP BY is the textbook docs-canonical idiom. |
| Completeness | 5 | Question is narrow; the answer addresses both metrics in one query. |
| Clarity | 5 | Aliases match the question wording. |
| Actionability | 5 | Drop-in query. |

**Q3 avg = 5.00**

---

### Q4 — IS NOT NULL filter

**Question**: customers.email often NULL (incomplete signups); exclude rows where email has no value.

**Responder answer summary**: `WHERE email IS NOT NULL`; explained NULL three-valued logic — comparing to NULL with `=` or `!=` yields UNKNOWN/NULL, not TRUE, so the row is filtered out; must use IS NOT NULL / IS NULL, not `!= NULL` / `<> NULL`. dbt note about applying the filter per model or in an ephemeral upstream.

**Verification** (trino.io/docs/467/functions/comparison.html):
- *"The `IS NULL` and `IS NOT NULL` operators test whether a value is null (undefined). Both operators work for all data types."* CONFIRMED.
- Three-valued logic: docs implicitly confirm via the IS DISTINCT FROM truth table — `=` and `<>` against NULL yield NULL (not TRUE/FALSE), which the WHERE clause treats as "not true" → row excluded. CONFIRMED.

| Dimension | Score | Rationale |
|---|---|---|
| Accuracy | 5 | IS NOT NULL semantics + 3-valued logic correctly stated; the `!= NULL` anti-pattern call-out is canonical. |
| Completeness | 5 | Covers the operator, the underlying logic, the anti-pattern, AND the dbt application (model filter / ephemeral upstream). |
| Clarity | 5 | "Comparing to NULL → UNKNOWN → row filtered" is the clearest possible framing for a beginner. |
| Actionability | 5 | Engineer knows the exact WHERE clause + where to put it in dbt. |

**Q4 avg = 5.00**

---

## Overall summary

| Q | Avg |
|---|---|
| Q1 (bool_or re-probe) | 5.00 |
| Q2 (year/month extraction) | 4.75 |
| Q3 (MIN/MAX per group) | 5.00 |
| Q4 (IS NOT NULL filter) | 5.00 |

**Overall average = (5.00 + 4.75 + 5.00 + 5.00) / 4 = 4.9375**

**Verdict: PASS (4.9375 >= 3.5)**

---

## bool_or / bool_and gap resolution status

**RESOLVED.** The iter597 canonical (H4 sub-block adjacent to §3.1E in resources/23-sql-best-practices-olap.md) routed correctly on the very first re-probe:
- Responder LEADS with `bool_or(succeeded)` and `bool_and(succeeded)` — no detour through count_if(...) > 0 or MAX(boolean).
- Responder actively warns AGAINST `MAX(succeeded)` / `MIN(succeeded)` with a wrong-intent + cost rationale.
- The exact column aliases mirror the iter597 canonical's worked example shape (`bool_or(is_late) AS any_late` -> `bool_or(succeeded) AS had_any_success`).
- The findability concern (keyword anchors block adjacent to count_if neighborhood, NOT a §3.1E rewrite) confirmed effective: the boolean question routed to bool_or even though the surrounding §3.1E count_if content was preserved untouched.

The iter596 (4.4375 PASS but Q4 = 3.00 boolean-aggregation gap) issue is closed.

---

## Notes / slips

None. All four answers are docs-canonical Trino 467, fit the on-prem stack (Trino 467 + Iceberg + Hive Metastore on MinIO), and would translate cleanly into a dbt model.

Minor note (not a slip, not a score deduction beyond Q2 completeness 4):
- Q2 could optionally mention `year(order_date)` / `month(order_date)` as equivalent shorter forms. Not a gap to act on — both EXTRACT and date_trunc are valid and the engineer can pick. Only flag if a future re-probe shows the responder rejecting `year()` / `month()` as invalid.

---

## Next-teacher actions for iter598

**PRIMARY DIRECTIVE — NO-OP on bool_or/bool_and**:
The iter597 fix landed perfectly. DO NOT touch the §3.1E count_if neighborhood, DO NOT touch the new bool_or/bool_and H4 sub-block, DO NOT rewrite §3.1E or §11. The canonical is routing as intended on the re-probe.

**FIX A (HIGH, but contingent)**: NO-OP this iteration. The four answers all scored >= 4.75; there is no adjacent gap large enough to justify churn. Do NOT manufacture an edit. If iter598 questions surface a new wrong-frame or fabricated-feature slip, treat that as Fix A; otherwise hold.

**FIX B (LOWER, opportunistic, defer unless needed)**: If a future re-probe of EXTRACT(YEAR/MONTH FROM date) shows the responder rejecting the `year(date)` / `month(date)` short forms, add a one-line equivalence note in the §3.1-or-adjacent date-extract neighborhood quoting docs:
- year(x) — "Returns the year from x."
- month(x) — "Returns the month of the year from x."
DO NOT preemptively add this. Wait for a probe that confirms a gap.

**CONSTRAINTS to carry forward**:
- iter534-597 locks PRESERVED, including the new bool_or/bool_and H4 canonical at §3.1E neighborhood (UNTOUCHED).
- r22 §13.x federation guardrails UNTOUCHED (federation rubric row stays 4.49944/310).
- ::-cast ban, EXTRACT-EPOCH ban, ILIKE-not-native, NOT-IN-NULL, MAX-vs-max_by, bucket(col,N) column-first, and all other dialect locks PRESERVED.
- Reconcile-in-place rule: any iter598 edit must fix/remove stale contradictory content in the SAME file; never just append. Near-threshold topics need consistently-accurate answers.
- Trino dialect: every SQL example must be valid Trino 467 (no QUALIFY, no ::-cast, no EXTRACT EPOCH, etc.).
- All examples must fit the on-prem stack: Trino 467 + Iceberg 1.5.2 + Hive Metastore on bare-metal MinIO, JWT auth, OPA authz.

**Confidence**: HIGH that iter597 is a clean PASS with the bool_or gap resolved. The teacher's single targeted edit (H4 adjacent to §3.1E, not a rewrite) achieved exactly the intended routing change without disturbing the count_if canonical that has been stable for many iterations.
