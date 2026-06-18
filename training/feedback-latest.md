# Judge Feedback — iter1054

**Overall: 4.7890625 → PASS** (margin +1.289 over 3.5 threshold)

Per-question: Q1 4.375 / Q2 4.9375 / Q3 4.9375 / Q4 4.90625

Verified BOTH directions against RAW git-tag 467 source (raw.githubusercontent.com/trinodb/trino/467/docs/...) and trino.io/docs, NOT resources/. RAW source dispositive. Federation NOT probed (hard-locked).

---

## Q1 — approx-distinct distinct-users-per-event-type this month — 4.375 PASS

Scores: Accuracy 4 / Completeness 4 / Clarity 5 / Actionability 4.5

**The actual ask is answered correctly.** `approx_distinct(user_id) GROUP BY event_type` is the right tool for a fast approximate distinct count on a dashboard:
- aggregate.md (467 RAW): approx_distinct "Returns the approximate number of distinct input values," an approximation of count(DISTINCT x), documented **2.3% standard error** (standard deviation of the approximately-normal error distribution). VERIFIED. (Note: the doc does not name HyperLogLog for approx_distinct specifically — HLL is named under approx_set — but HLL is the underlying impl; calling it HLL is accurate, just not doc-literal. No ding.)
- `SET SESSION distinct_aggregations_strategy='pre_aggregate'` is a LEGAL 467 session property (PRE_AGGREGATE strategy for multiple distinct aggregations; verified vs optimizer-properties docs). Offering it as the exact-count fallback is reasonable.
- Nightly HLL sketch table + "2.3% not for billing-critical" caveat are sound, useful extras.

**FINDING (1) — Q1 date-window off-by-one-month (this-month vs last-month):** The WHERE filter
```
event_date >= DATE_TRUNC('month', current_date) - INTERVAL '1' MONTH
AND event_date <  DATE_TRUNC('month', current_date)
```
selects `[start of PREVIOUS month, start of current month)` = the **previous complete month**, NOT "THIS month" as asked. For "this month" the correct filter is:
```
event_date >= DATE_TRUNC('month', current_date)   -- start of current month, through now
```
The DATE_TRUNC + INTERVAL '1' MONTH arithmetic itself is VALID Trino (datetime.md confirms date_trunc('month',...) → first of month; `date + INTERVAL '1' MONTH` valid). This is purely a window-boundary logic slip, not a dialect error.

**Severity = per-instance minor slip.** The technique that was actually requested (faster approximate distinct) is correct and complete; only the month window is off by one. Dings Accuracy and Completeness one tier each; does NOT cause a FAIL and is NOT a resource defect (it is a one-off logic mistake on a specific date predicate, not a taught-wrong pattern). Monitor; re-probe a "this month" window next sweep. Escalate only if the same DATE_TRUNC - INTERVAL '1' MONTH "this month" off-by-one recurs 2-in-2.

## Q2 — average days-active before cancellation, cancelled-only — 4.9375 PASS

Scores: Accuracy 5 / Completeness 4.875 / Clarity 5 / Actionability 4.875

Fully correct. `AVG(date_diff('day', started_at, cancelled_at)) WHERE cancelled_at IS NOT NULL`:
- datetime.md (467 RAW): date_diff('day', ts1, ts2) → bigint, **complete-units / day-aware**, returns timestamp2 - timestamp1 in whole days. VERIFIED.
- aggregate.md: avg() **ignores NULL values and returns NULL for no input rows** — so the WHERE cancelled_at IS NOT NULL correctly restricts to cancelled subs and avoids counting still-active as zero; AVG-ignores-NULL explanation is accurate. VERIFIED.
- The `AVG(date_diff('day', date(started_at), date(cancelled_at)))` calendar-day variant is sound (casts to date so partial days don't shift the count). Good completeness.

No errors.

## Q3 — users with ≥1 flag starting with literal "beta_", no unnest — 4.9375 PASS

Scores: Accuracy 5 / Completeness 4.875 / Clarity 5 / Actionability 4.875

Both forms correct and the broken-secondary did NOT recur:
- `any_match(feature_flags, flag -> starts_with(flag, 'beta_'))` — array.md: any_match returns boolean true if ≥1 element matches the predicate. IDEAL for the ≥1-match ask. VERIFIED.
- `cardinality(filter(feature_flags, flag -> starts_with(flag, 'beta_'))) > 0` — filter returns the matching-elements array, cardinality its size; >0 ⇔ at least one match. Valid equivalent. VERIFIED.
- string.md (467 RAW): starts_with(string, substring) → boolean, "tests whether substring is a **prefix**" — a LITERAL prefix, NOT a wildcard. Responder correctly states this and that it is not a wildcard, so the literal underscore in "beta_" is matched literally. VERIFIED.

**FINDING (2) — Q3 broken-secondary LIKE aside did NOT recur (clean re-probe AGAIN).** No bare `LIKE 'beta_%'` "if you prefer" alternative was offered. `_` is a single-char wildcard in LIKE (comparison.md), so `'beta_%'` would over-match `'betaX...'` and is NOT equivalent to a literal-`beta_` prefix; correctly NOT suggested. This is the **3rd consecutive clean re-probe** after the iter1052/iter1053 clean runs (and well past the iter1037/iter1051 occurrences). The iter1051-noted "escalate if it recurs a 3rd time" streak does NOT advance — it has reversed. FIX-A (r23 §653 bare-column LIKE literal-`_`/`%` caveat + r07 ~L759 filter-lambda literal-prefix) is durable. Score HIGH, watch stays passive.

## Q4 — order-amount histogram into 5 buckets, no huge CASE — 4.90625 PASS

Scores: Accuracy 4.875 / Completeness 4.875 / Clarity 5 / Actionability 4.875

`width_bucket(order_amount, ARRAY[25.0, 50.0, 100.0, 250.0]) AS bucket_id GROUP BY 1` is the right "no huge CASE" tool:
- math.md (467 RAW) + verified boundary semantics: width_bucket(x, bins) with bins sorted ascending returns the bin number; for **n bounds you get n+1 buckets**, lower-bound-INCLUSIVE:
  - x < 25 → **0**
  - 25 ≤ x < 50 → **1**
  - 50 ≤ x < 100 → **2**
  - 100 ≤ x < 250 → **3**
  - x ≥ 250 → **4**
  VERIFIED (n+1 buckets, 0 for below first bound, n+1 for ≥ last bound, lower-inclusive).

**FINDING (3) — Q4 width_bucket CASE labels complete AND correct (contrast iter1046).** The CASE label form maps:
`0 → '$0-25', 1 → '$25-50', 2 → '$50-100', 3 → '$100-250', 4 → '$250+'`
Every label matches its bucket EXACTLY against the verified 0..4 mapping. This is a clean improvement over iter1046, where buckets 3-4 were mislabeled '$50+'. All five labels present and correct this time. Score HIGH.

(Trivial nit: using ARRAY[25.0,...] DECIMAL literals vs DECIMAL order_amount is fine; width_bucket coerces to double internally — no correctness impact. Tiny Accuracy shade only.)

---

## Clean-bill checklist (none present)
No `::`-cast misuse, no QUALIFY, no false semi-join, no fabricated function, no regex-backslash error, no INTERVAL quarter/week, no OFFSET-before-LIMIT inversion, no over-warning folklore, no broken-secondary alternative.

## RECOMMENDATION — DEFAULT NO-OP

Margin +1.289. No source-verified resource defect and no 2-in-2 same-shape slip.
- Q1 date-window off-by-one-month = per-instance logic slip on a date predicate, NOT a taught-wrong pattern → monitor, re-probe a "this month" window; do NOT churn resources.
- Q3 broken-secondary LIKE = 3rd consecutive non-recurrence → FIX-A durable, watch passive.
- Q4 width_bucket labels = complete+correct, iter1046 regression not reproduced.

NO resource edit; NO commit. MUST NOT bump state.json (already 1054).
