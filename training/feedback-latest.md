# iter791 — Judge Feedback (DEFAULT NO-OP / durability-breadth sweep)

**Sweep type:** Teacher made ZERO resource edits. 4 fresh adjacent probes (modulo even/odd, upper-case, multi-condition CASE bucket, current-year filter). Key check = Q3 date subtraction in Trino 467.

**All dialect facts verified against trino.io/docs/467 (datetime.html, string.html) + WebSearch 2026-06-09.**

---

## Per-question scores

### Q1 — MODULO even/odd A/B bucketing
`CASE WHEN user_id % 2 = 0 THEN 'Bucket A (even)' ELSE 'Bucket B (odd)' END`; `%` modulo operator; `user_id % 10` for 10 buckets. Cites r07.

- Accuracy **5** — VERIFIED: Trino 467 has the `%` modulo operator and `mod(n, m)` function for integers; `user_id % 2 = 0` correctly tests even. CLEAN.
- Completeness **5** — even/odd covered, plus N-bucket generalization (`% 10`).
- Clarity **5** — names the operator, plain even/odd labels.
- Actionability **5** — drop-in CASE expression.
- **Q1 avg = 5.00**

### Q2 — UPPERCASE country_code
`upper(country_code) AS country_code_uppercase`; `upper('us')='US'`, `upper('Us')='US'`. Cites r27.

- Accuracy **5** — VERIFIED vs string.html: `upper(string) -> varchar` uppercases; `lower()` is the sibling. CLEAN.
- Completeness **5** — shows mixed-case input handled.
- Clarity **5** — concrete `'us'→'US'` example.
- Actionability **5** — direct.
- **Q2 avg = 5.00**

### Q3 — MULTI-CONDITION delivery-speed bucket (KEY CHECK)
`CASE WHEN (delivery_date - order_date) <= 1 THEN 'Express' WHEN (delivery_date - order_date) <= 3 THEN 'Standard' ELSE 'Slow' END`. Cites r07.

- Accuracy **2.5** — **DIALECT DEFECT.** The CASE/threshold STRUCTURE is correct (cascading `<=` with the smallest bound first is the right ordering and correctly yields 0-1 Express / 2-3 Standard / 4+ Slow). BUT the day-count expression `delivery_date - order_date` is **WRONG Trino 467 dialect** — see verdict below. The query as written does NOT compile.
- Completeness **4** — offered both inline and CTE variants; the bucket boundaries are complete and correctly ordered. Docked because both variants carry the same broken day-computation.
- Clarity **4.5** — clear labels, CTE alias `days_to_deliver` is readable.
- Actionability **2.5** — an engineer who pastes this gets a type/operator error, not a working query.
- **Q3 avg = 3.375**

### Q4 — CURRENT-YEAR filter (auto-rolls)
`WHERE year(order_date) = year(current_date)`; `year()`→bigint; `current_date` (no parens); auto-rolls. Alt `EXTRACT(YEAR FROM order_date) = EXTRACT(YEAR FROM current_date)`. Cites r07 + r23.

- Accuracy **5** — VERIFIED vs datetime.html: `year(date) -> bigint`, `current_date` valid (no parens), `EXTRACT(YEAR FROM ...)` equivalent. Filter correctly selects the current calendar year and auto-rolls Jan 1. CLEAN for correctness.
- Completeness **4** — correct, but MISSES the sargability nuance (see note b). Not a defect — a completeness improvement.
- Clarity **5** — explains `year()` returns bigint, current_date parens-free, auto-roll behavior.
- Actionability **5** — drop-in WHERE clause.
- **Q4 avg = 4.75**

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 5.00 |
| Q2 | 5.00 |
| Q3 | 3.375 |
| Q4 | 4.75 |

**Overall avg = (5.00 + 5.00 + 3.375 + 4.75) / 4 = 4.53125 → PASS** (overall governs; no single-Q veto).

---

## (a) Q3 DATE-SUBTRACTION VERDICT — DEFECT

**`delivery_date - order_date` is NOT valid Trino 467 dialect for a day count.**

Verified vs trino.io/docs/467/functions/datetime.html + WebSearch:
- Trino does **not** support `date - date` returning an integer day count (that is PostgreSQL behavior). The `-` operator on temporal types in Trino is for `date/timestamp - INTERVAL`, not `date - date`. Subtracting two DATE values does not yield a bigint, so `(delivery_date - order_date) <= 1` is a type/operator error — the query will not run as written.
- **CORRECT canonical form:** `date_diff('day', order_date, delivery_date)` → bigint day count (docs: `date_diff('day', DATE '2020-03-01', DATE '2020-03-02')` = 1). Argument order matters: `date_diff(unit, earlier, later)` returns `later - earlier`, so `date_diff('day', order_date, delivery_date)` gives positive days-to-deliver.

  Correct query:
  ```sql
  CASE
    WHEN date_diff('day', order_date, delivery_date) <= 1 THEN 'Express'
    WHEN date_diff('day', order_date, delivery_date) <= 3 THEN 'Standard'
    ELSE 'Slow'
  END AS delivery_speed
  ```

**Responder-slip vs resource-defect: RESPONDER SLIP. Resources are CLEAN.**
- r07 (`resources/07-analytical-query-patterns.md`) uses `date_diff('day', ...)` consistently and NEVER shows a bare `date - date` day-count form. Evidence:
  - `resources/07-analytical-query-patterns.md:1095-1097` — day-bucketing inside CASE using `date_diff('day', f.first_event_at, e.event_time) BETWEEN 1 AND 7 ...` (the exact pattern Q3 should have modeled).
  - `:906`, `:910`, `:1109`, `:1119`, `:1123`, `:1173`, `:1177-1178` — all use `date_diff(unit, d1, d2)`.
  - A repo-wide grep for bare date-minus-date day counts returned NO hits in any resource.
- The responder fabricated `delivery_date - order_date` by importing a Postgres/Oracle prior rather than copying the `date_diff` idiom that r07 plainly shows. The cited resource does NOT contain the broken form.

## (b) Q4 SARGABILITY NOTE (correct, but improvable — NOT a defect)

`year(order_date) = year(current_date)` is correct and auto-rolls, but **wrapping `order_date` in `year()` defeats partition pruning / predicate pushdown** on a large Iceberg table (Trino cannot push a function-wrapped column predicate to the connector / cannot prune partitions on `order_date`). The sargable form scans far less:
```sql
WHERE order_date >= date_trunc('year', current_date)
  AND order_date <  date_trunc('year', current_date) + INTERVAL '1' YEAR
```
This keeps the bare column on the left so Iceberg can prune year/month partitions. The responder's answer is CORRECT for correctness; this is a completeness/performance improvement, not counted as a defect.

## (c) iter792 designation — DEFAULT NO-OP / durability-breadth sweep

- Q3 defect traces to a **responder slip**, not a resource defect (resources clean — r07 shows `date_diff('day', ...)` at lines 1095-1097 and throughout). Per the reconcile/churn-risk policy, do NOT edit r07: it already contains the correct canonical and a churn-edit risks regressing well-covered date-diff content.
- No open resource defect; no new imprecision in resources.
- **Optional light additive findability nudge (only if `date - date` recurs 2+ more times):** if a future probe again shows the responder reaching for bare `date - date` on a days-between question, add a defang anchor near the r07 date-diff card: keyword anchors "days between two dates / days to deliver / elapsed days / difference between dates → `date_diff('day', earlier, later)`; Trino has NO `date - date` day-count (Postgres-only)". Hold for now — single datapoint.
- Suggested fresh adjacent probes for iter792: `date_diff` age-in-days direct phrasing (to bulletproof against the date-minus-date slip), `least()` row-wise min, NULLIF divide-by-zero guard, `mod()` function-form vs `%` operator.
- PRESERVE: r07 modulo/CASE-bucket/year-filter cards, r27 upper/lower card, r07/r23 current-year filter cards — all verified clean, churn risk.
