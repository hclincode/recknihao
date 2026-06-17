# Judge Feedback — iter1035

**OVERALL: 4.8125 — PASS** (margin +1.3125 over 3.5 threshold; overall average governs, no per-Q veto)

Verified BOTH directions against RAW git-tag 467 source
(raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/...), NOT resources/.
Prod stack (Trino 467 + Iceberg + MinIO, Hive Metastore) — all 4 fit; no federation/auth angle.

---

## Q1 — week-over-week per customer in ONE query (was 2 queries + app math)
**Acc 5 / Comp 4.75 / Clar 4.75 / App 4.875 → 4.84375 CLEAN**

- `SUM(metric) FILTER (WHERE ...)` conditional aggregation VERIFIED valid 467 syntax:
  aggregate.md — "The `FILTER` keyword can be used to remove rows from aggregation processing
  with a condition expressed using a `WHERE` clause"; form `aggregate_function(...) FILTER (WHERE <condition>)`.
- this_week = `event_date >= date_trunc('week', current_date)`; last_week =
  `>= date_trunc('week', current_date) - INTERVAL '7' DAY AND < date_trunc('week', current_date)` —
  correct half-open windows; both boundaries anchored to the SAME `date_trunc('week')` so they are
  contiguous and non-overlapping regardless of which weekday the week starts on.
  `current_date - INTERVAL '7' DAY` is valid date arithmetic; INTERVAL '7' DAY uses a legal DAY qualifier.
- date_trunc('week') Monday-start (ISO week, Trino day-of-week 1=Monday) — consistent w/ 467; the
  query is correct even if the user's "week" boundary differs because both columns share the anchor.
- Single pass, `GROUP BY customer_id`, no self-join — DIRECTLY eliminates the 2-query + app-layer-math
  pain point. Engineer knows exactly what to do.

## Q2 — sum an array of prices WITHOUT expanding to rows
**Acc 5 / Comp 4.75 / Clar 4.625 / App 4.75 → 4.78125 CLEAN**

- **array_sum FINDING: `array_sum` does NOT exist in Trino 467.** Verified neutrally against
  functions/array.md at the 467 git tag — no `array_sum` function is defined anywhere in the file.
- Therefore `reduce(line_items, 0, (s, price) -> s + price, s -> s)` is the **CANONICAL correct
  approach**, not merely a workaround. The answer is fully correct AND complete; there is NO
  completeness gap for omitting array_sum because the built-in does not exist.
- reduce() 4-arg signature VERIFIED EXACT vs array.md:
  `reduce(array(T), initialState S, inputFunction(S,T,S), outputFunction(S,R)) -> R`.
  Responder's `(line_items, 0, (sum,price)->sum+price, s->s)` matches positionally; identity
  output function `s->s` is correct (docs note "It may be the identity function (`i -> i`)").
- One row in / one row out, no GROUP BY — satisfies "without expanding to rows" exactly.
- ALT `CROSS JOIN UNNEST(line_items) AS t(price)` + SUM + GROUP BY is a VALID alternative
  (the very thing the user wanted to avoid, correctly framed as the fallback). Not a broken-secondary.
- Minor clarity ding only (two paths could mildly distract); nothing inaccurate.

## Q3 — avg days created_at→renewed_at, NULL (not zero/error) on no qualifying rows
**Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75 → 4.8125 CLEAN**

- `date_diff('day', created_at, renewed_at)` VERIFIED → bigint
  (datetime.md `date_diff(unit, timestamp1, timestamp2) -> bigint`).
- `AVG(...) WHERE renewed_at IS NOT NULL` — AVG ignores NULLs and returns NULL on empty input
  VERIFIED: aggregate.md "all of these aggregate functions ignore null values and return null for
  no input rows or when all values are null" → satisfies the "NULL not 0/error" requirement EXACTLY.
- WHERE renewed_at IS NOT NULL is sufficient; even if created_at were NULL, date_diff yields NULL and
  AVG skips it — still safe. Correctly explains no special logic needed. Sound.

## Q4 — split users into 4 equal groups by session length (quartiles)
**Acc 5 / Comp 4.75 / Clar 4.75 / App 4.75 → 4.8125 CLEAN**

- `NTILE(4) OVER (ORDER BY session_duration)` VERIFIED — window.md: "Divides the rows for each window
  partition into `n` buckets ranging from `1` to at most `n`. Bucket values will differ by at most `1`."
  Answers the user's "is there a function?" directly — YES, no manual cutoffs + CASE needed.
- Remainder distribution VERIFIED EXACT: "If the number of rows in the partition does not divide evenly
  into the number of buckets, then the remainder values are distributed one per bucket, starting with
  the first bucket" (docs example 6 rows / 4 buckets → 1 1 2 2 3 4). Responder's "remainder rows go to
  earliest buckets" is correct.
- ASC → bucket 1 = bottom 25%; DESC → bucket 1 = top 25% — correct.
- "NTILE can't be used in WHERE → wrap in CTE then filter" — correct; window functions are not allowed
  in WHERE (evaluated after WHERE/GROUP BY), so a CTE/subquery wrapper is required. Confirmed.

---

## TICS scan
`::` ABSENT all 4. CLEAN — no QUALIFY, no false-semi-join, no fabricated functions (reduce / date_diff /
NTILE / AVG / FILTER all real & verified; array_sum correctly NOT used since it does not exist), no
regex-backslash, no INTERVAL quarter/week (INTERVAL '7' DAY legal), no OFFSET-before-LIMIT, no
broken-secondary (Q2 UNNEST alt is valid), no over-warning folklore.

## Source-verified defects
NONE. All four answers fully correct and verified both directions.

## RECOMMENDATION — DEFAULT NO-OP
Margin +1.3125; all 4 clean; the KEY Q2 array_sum-vs-reduce call resolves in the responder's favor
(reduce is canonical because array_sum does not exist in 467). No source-verified resource defect,
no 2-in-2 same-shape slip. NO resource edit; NO FIX-A; NO git commit.
MUST NOT bump state.json (teacher already at 1035; orchestrator commits).

Re-probe (monitor only): (a) FILTER-conditional-aggregation week-over-week single-pass vs self-join;
(b) reduce() 4-arg array-sum canonical (array_sum absent) vs UNNEST+SUM fallback; (c) date_diff('day')
bigint + AVG-ignores-NULL/returns-NULL-on-empty for the "NULL not zero" requirement; (d) NTILE(n)
quartile/quantile + remainder-to-earliest-buckets + ASC/DESC bucket-1 meaning + window-not-in-WHERE-wrap-CTE.
Federation r22 §13.x hard-locked NOT probed (4.49944/310).
