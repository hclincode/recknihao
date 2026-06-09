# Judge Feedback — iter869 (EXTENDED PHASE)

## Verdict: STRONG PASS — overall avg 4.94 (per-Q 5.00 / 5.00 / 5.00 / 4.75 = 19.75/4 = 4.9375; margin +1.44)

Overall average governs; no per-Q veto. Federation NOT probed this iteration — the 4.49944/310 FAIL row is UNCHANGED.

All four questions are pure Trino 467 SQL/dialect; none touch permissions/auth, so prod_info.md (on-prem k8s, MinIO, Trino 467 Iceberg, JWT+OPA) imposes no additional constraint here. Every dialect claim was verified against trino.io/docs/467 via WebFetch on 2026-06-10.

---

## Q1 — Highest-ticket-count department NAME (no ORDER BY/LIMIT hack)

Responder: `max_by(department, cnt)` over an inner `SELECT department, COUNT(*) AS cnt ... GROUP BY department`. Returns the department name paired with the max count, one row, no sort.

VERIFIED vs trino.io/docs/467 functions/aggregate.html: `max_by(x, y)` returns "the value of `x` associated with the maximum value of `y` over all input values." This is exactly the argmax-name pattern — correct. It avoids the ORDER BY ... LIMIT 1 hack as the question demanded, and `max_by` is one of the documented ignore-null EXCEPTIONS so it behaves cleanly. Ties: docs do not specify tie-breaking; `max_by` returns one arbitrary winner on a tie. This is a COMPLETENESS nuance only, not an error — the question asked for "the single highest," and the pattern is the canonical answer.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**
- Note: tie-arbitrariness unmentioned; nuance only, does not justify a ding given the question framing.

## Q2 — Extract hour-of-day 0–23 from a plain TIMESTAMP

Responder: `hour(created_at) AS hour_of_day`, `GROUP BY hour(created_at)`; said `hour()` returns a bigint 0–23 from the value as stored.

VERIFIED vs trino.io/docs/467 functions/datetime.html: `hour(timestamp)` "Returns the hour of the day from `x`. The value ranges from `0` to `23`." Return type bigint. Correct on function, range, and type. Grouping by the expression (not a SELECT alias) is also Trino-legal. Fully correct.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

## Q3 — Replace LEFT JOIN NULLs with a default ('free')

Responder: `COALESCE(s.plan, 'free') AS plan_type`; explained COALESCE returns the first non-NULL, cleaner than CASE WHEN IS NULL.

VERIFIED vs trino.io/docs/467 functions/conditional.html: COALESCE "Returns the first non-null `value` in the argument list. Like a `CASE` expression, arguments are only evaluated if necessary." Correct, and the "cleaner than CASE" framing is accurate. Textbook.

- Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.00**

## Q4 — Filter orders to CURRENT calendar year, auto-updating

Responder: `WHERE year(order_date) = year(current_date)`; explained current_date is evaluated at runtime so it auto-updates.

VERIFIED vs trino.io/docs/467 functions/datetime.html: `year(date)` "Returns the year from `x`" (bigint); `current_date` "Returns the current date as of the start of the query" (date, no parens). The comparison is CORRECT for results and DOES auto-update each calendar year — no hardcoded literal. The responder's runtime/auto-update explanation is accurate.

COMPLETENESS/perf nuance (NOT an accuracy error): wrapping the column in `year(order_date)` applies a function to the partition/predicate column, so Trino cannot use partition pruning or min/max column stats efficiently — it must evaluate `year()` per row. The sargable, pruning-friendly form is a half-open range on the bare column:

```
WHERE order_date >= date_trunc('year', current_date)
  AND order_date <  date_trunc('year', current_date) + INTERVAL '1' YEAR
```

This is equivalent in results, still auto-updating, and lets the Iceberg connector prune partitions / use min-max stats. On the production stack (Trino 467 + Iceberg, large fact tables) this matters for scan cost. The given form is fully correct for correctness; the omission of the sargable alternative is the only gap.

- Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 → **avg 4.75**
- The Completeness ding is for not mentioning the sargable/partition-pruning rewrite — a genuinely valuable nuance for this audience and stack, but a soft ding, not a defect (the answer is correct and runnable).

---

## Topic mapping (rubric)

Touched topic: **SQL query best practices for OLAP** (Q1/Q2/Q3 core SQL; Q4 sargable-predicate angle is the partition-column-in-WHERE / pushdown-breaking-pattern facet of this row). Already PASSED (4.4600 / 153). This iteration is consistent with passing; no status change.

Federation (FAIL, 4.49944/310): NOT probed — row UNCHANGED.

## iter870 Recommendation: DEFAULT NO-OP (durability sweep)

All four answers are dialect-correct and verified. The only soft gap is Q4's missing sargable-rewrite nuance.

- **No FIX-A required.** The Q4 `year(col)=year(current_date)` form is CORRECT for results; this is a completeness nuance, not a defect. Do NOT add a "year(order_date) is WRONG" card — that would be inaccurate.
- OPTIONAL low-priority (only if a future Q4-style answer under-scores on perf): a one-line cross-ref near the current-year/date-filter content noting the sargable half-open `order_date >= date_trunc('year', current_date) AND order_date < ... + INTERVAL '1' YEAR` form for partition pruning. Do NOT churn existing pins to add it; place only at a keyword-findable date-filter landing.
- HOLD all iter534–866 locks. PIN Trino 467. NO federation edits (r22 §13.x ZERO). DO NOT bump training/state.json (already 869/passed).
- Optional fresh adjacents for iter870: sargable date-range vs function-on-column (2nd phrasing) / max_by ties + arbitrary-winner handling / COALESCE empty-string-vs-NULL / hour() on TIMESTAMP WITH TIME ZONE vs plain.
