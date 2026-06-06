# Iter571 Judge Feedback

PIN: Trino 467. All verifications run against trino.io/docs/467 (or stable doc text identical across 467-481 where the cited statement has not changed).

## Q1 — Forward-fill composition (MULTI-row-per-bucket re-probe; iter571 FIX A check)

The responder built: `date_spine` (DISTINCT products × DISTINCT event-days) → `latest_per_day` (ROW_NUMBER() OVER (PARTITION BY product_id, date_trunc('day', occurred_at) ORDER BY occurred_at DESC), WHERE rn = 1) → `filled` (LEFT JOIN spine to deduped, then `LAST_VALUE(deduped.stock_count IGNORE NULLS) OVER (PARTITION BY spine.product_id ORDER BY spine.calendar_date ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`).

Point-by-point (verify each):

**(i) GOOD — fanout-safe pre-aggregation.** The deduped CTE collapses many-per-(product,day) events to exactly one row per (product, day) via `ROW_NUMBER() ... ORDER BY occurred_at DESC) = 1` BEFORE the LEFT JOIN. This is functionally equivalent to the canonical `max_by(stock_count, occurred_at) GROUP BY product_id, date_trunc('day', occurred_at)` and PREVENTS the iter570 LEFT-JOIN-fanout defect. CONFIRMED — the iter571 FIX A composition order (dedup-then-join-then-window) landed.

**(ii) GOOD — no pre-join window; look-BACK frame.** No LAST_VALUE / forward-fill window appears in any pre-join CTE. The forward-fill runs ONLY in the final `filled` CTE, AFTER the LEFT JOIN, with frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` (look-BACK), NOT `UNBOUNDED FOLLOWING`. The iter570 anti-pattern (full-frame LAST_VALUE in a pre-join CTE collapsing to a per-entity constant) did NOT recur. CONFIRMED.

**(iii) BAD — REGRESSION — IGNORE NULLS placement parse error.** The responder wrote `LAST_VALUE(deduped.stock_count IGNORE NULLS) OVER (...)`. Per Trino 467 grammar, the null-treatment clause is OUTSIDE the function-args paren and BEFORE `OVER`. Web search verification (trino.io window functions doc): "the IGNORE NULLS clause is placed after the closing parenthesis of the function arguments for LAST_VALUE ... syntax is `LAST_VALUE(column) IGNORE NULLS`." SQL grammar form: `<first or last value function> ::= <first or last value> <left paren> <value expression> <right paren> [ <null treatment> ]`. The responder's form places `IGNORE NULLS` INSIDE the args paren — that produces `mismatched input 'IGNORE'` at parse time. THE QUERY DOES NOT RUN AS WRITTEN. This is the same parse-error bug from iter569 — direct regression even though the iter569 H3 fix is still in r07 §1a / r23.

**(iv) PARTIAL — non-dense spine.** The `date_spine` CTE materializes products × `DISTINCT date_trunc('day', occurred_at)` over the EXISTING stock_changes rows. Days on which NO product had any change are entirely absent from the spine. The question explicitly stated "lots of days with no update" — those zero-event days will be missing from the output. The canonical builds a TRUE dense calendar via `sequence(DATE '2026-01-01', DATE '2026-05-31', INTERVAL '1' DAY)` + `CROSS JOIN UNNEST`. The responder's spine is only as dense as the union of distinct event-days — fine when every day has SOMETHING, broken when whole days have zero events.

### Corrected query (copy/paste)

```sql
WITH date_spine AS (
  SELECT p.product_id, d.day AS calendar_date
  FROM products p
  CROSS JOIN UNNEST(sequence(DATE '2026-01-01', DATE '2026-05-31', INTERVAL '1' DAY)) AS d(day)
),
latest_per_day AS (
  SELECT
    product_id,
    date_trunc('day', occurred_at) AS event_day,
    max_by(stock_count, occurred_at) AS stock_count   -- one row per (product, day)
  FROM stock_changes
  WHERE occurred_at >= DATE '2026-01-01' AND occurred_at < DATE '2026-06-01'
  GROUP BY product_id, date_trunc('day', occurred_at)
)
SELECT
  s.product_id,
  s.calendar_date,
  LAST_VALUE(l.stock_count) IGNORE NULLS OVER (        -- IGNORE NULLS OUTSIDE paren
    PARTITION BY s.product_id
    ORDER BY s.calendar_date
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW   -- look-BACK only
  ) AS last_known_stock
FROM date_spine s
LEFT JOIN latest_per_day l
  ON l.product_id = s.product_id AND l.event_day = s.calendar_date;
```

Scores: Accuracy 2 (query does not run — IGNORE NULLS parse error; spine non-dense), Completeness 3 (composition order correct; spine completeness gap), Clarity 4 (CTE chain readable, clear naming), Actionability 2 (engineer who copy-pastes hits a parse error). **Avg 2.75.**

## Q2 — `::` cast re-probe (iter571 FIX C check)

Responder correctly identified that the `::` shorthand is NOT supported in Trino 467 (parse error `mismatched input ':'`), and gave three valid alternatives: `CAST(created_at AS DATE)`, `date(created_at)`, typed literal `DATE '2026-06-01'`. Also added the UnwrapCastInComparison nuance: `CAST(event_ts AS DATE) = DATE '...'` still prunes partitions.

Verifications:
- GitHub issue [#23795](https://github.com/trinodb/trino/issues/23795) "Cast operator `::`" is OPEN — feature request to add `x::type` as alternative syntax for `CAST(x AS type)`. Not merged. CONFIRMED — `::` is NOT in the Trino 467 grammar.
- Trino 467 conversion functions confirm `CAST(x AS type)` and `date(x)` are valid; the typed-literal form `DATE 'YYYY-MM-DD'` is documented under language/types.
- UnwrapCastInComparison rule confirmed via Trino blog (2023/04/11/date-predicates.html) and PR #11170: "rewrites CAST(ts_column AS DATE) OP date_literal to a range expression on ts_column, with dropping the cast to allow for further optimizations such as pushdown into connectors."

All three statements are accurate. FIX C VALIDATED.

Scores: Accuracy 5, Completeness 5, Clarity 5, Actionability 5. **Avg 5.0.**

## Q3 — NOT IN trap / anti-join

Responder explained SQL three-valued logic (NULL comparisons → UNKNOWN), warned that NOT IN with any NULL in the IN-list returns zero rows silently. Recommended `NOT EXISTS (...)` and `LEFT JOIN ... WHERE o.customer_id IS NULL` as safe alternatives. Said NOT EXISTS converts to a SemiJoin in Trino.

Verifications:
- NULL + NOT IN three-valued-logic gotcha: standard SQL behavior, applies to Trino 467 (Trino follows standard 3VL).
- NOT EXISTS and LEFT-JOIN-IS-NULL anti-join: both standard, both correct.
- Minor nit: NOT EXISTS in Trino typically compiles to an ANTI-join (or anti-SemiJoin) node, not a plain SemiJoin (a SemiJoin is the IN/EXISTS positive form; NOT EXISTS is the anti variant). EXPLAIN typically shows `SemiJoinNode` with type `SOURCE` and `filter` for the anti case, or in newer planners just labels it `ANTI`. The responder's "SemiJoin" framing is close but imprecise — engineer reading EXPLAIN may see `LEFT` join + filter or `Anti` rather than `SemiJoin`. Small docking on accuracy.

Scores: Accuracy 4 (SemiJoin label slightly off vs anti-join), Completeness 5, Clarity 5, Actionability 5. **Avg 4.75.**

## Q4 — CASE tier bucketing

Responder: pre-aggregated `SUM(amount) GROUP BY customer_id` subquery, then outer query `CASE WHEN total_spent < 100 THEN 'low' WHEN total_spent < 1000 THEN 'medium' ELSE 'high' END AS spending_tier`, `GROUP BY spending_tier`, `ORDER BY CASE spending_tier WHEN 'low' THEN 1 ...`. Also offered `width_bucket(total_spent, 0, 10000, 3)` for equal-width buckets.

Verifications:
- CASE bucketing + GROUP BY by output alias is valid Trino 467 (Trino accepts GROUP BY by alias in many cases; if engine quibbles, re-stating the CASE is a robust fallback — responder did not call this out, minor completeness gap).
- `width_bucket(x, bound1, bound2, n)` is real Trino 467 math function. Confirmed: "function width_bucket(double, double, double, bigint) returns bigint" — "Returns the bin number of x in an equi-width histogram with the specified bound1 and bound2 bounds and n number of buckets."
- Ordering by an explicit CASE in ORDER BY is standard SQL and works in Trino 467.

Scores: Accuracy 5, Completeness 4 (could have noted the alias-vs-restate nuance for portability), Clarity 5, Actionability 5. **Avg 4.75.**

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 forward-fill | 2 | 3 | 4 | 2 | 2.75 |
| Q2 `::` cast | 5 | 5 | 5 | 5 | 5.00 |
| Q3 NOT IN / anti-join | 4 | 5 | 5 | 5 | 4.75 |
| Q4 CASE tier | 5 | 4 | 5 | 5 | 4.75 |

**Overall avg = (2.75 + 5.00 + 4.75 + 4.75) / 4 = 4.3125 → PASS** (overall avg >= 3.5).

But the PASS is materially weakened by Q1's parse-error regression: a query that the responder confidently presents and which DOES NOT RUN is the worst kind of failure mode in production — engineer copy-pastes and hits an opaque `mismatched input 'IGNORE'` error.

## Iter572 directive — STOP the recurring `LAST_VALUE(x IGNORE NULLS)` regression

This is the SECOND occurrence of the IGNORE-NULLS-inside-paren bug (iter569 also). The iter566 H3 + iter569 reinforcement clearly didn't make the WRONG token salient enough. Three teacher actions for iter572:

1. **HIGH — make the copy-paste canonical the most-salient artifact in r07 §4 COMBINED CANONICAL.** Currently the H3 explains the rule THEN shows a query. Invert: put the COMPLETE copy-paste query (using `sequence()`+UNNEST for the spine + `max_by` for the dedup + `LAST_VALUE(col) IGNORE NULLS OVER (... ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)` in a single fenced block) FIRST, immediately under the topic header, with a one-line note "copy this; do not retype the IGNORE NULLS clause." The responder is grabbing structure from the most-prominent code block in scope — give it a correct one to grab.

2. **HIGH — tighter DO-NOT-WRITE with the EXACT WRONG token.** Add a new DO-NOT-WRITE bullet in r07 §1a (the existing IGNORE NULLS placement H3) and ALSO in r23 §3.1 of the form:
   - DO NOT WRITE: `LAST_VALUE(col IGNORE NULLS) OVER (...)` <- parse error `mismatched input 'IGNORE'`
   - DO NOT WRITE: `FIRST_VALUE(col IGNORE NULLS) OVER (...)` <- same
   - DO NOT WRITE: `LAG(col IGNORE NULLS) OVER (...)` <- same
   - WRITE: `LAST_VALUE(col) IGNORE NULLS OVER (...)` — null-treatment is OUTSIDE the args paren, BEFORE `OVER`.
   - Quote the Trino 467 grammar verbatim: `<first or last value function> ::= <first or last value> <left paren> <value expression> <right paren> [ <null treatment> ]`.
   Use the literal WRONG tokens above so keyword-grep from the responder lands on them.

3. **MEDIUM — true-dense-spine reminder.** In the same r07 §4 canonical, add a one-line callout under the spine CTE: "DO NOT build the spine from `SELECT DISTINCT date_trunc('day', event_ts) FROM facts` — days with zero events will be missing. Use `sequence(start, end, INTERVAL '1' DAY)` + `CROSS JOIN UNNEST` for a truly dense calendar." Verified per Trino datetime docs: `sequence(start, stop, step)` with INTERVAL DAY TO SECOND is the canonical dense-date generator.

No federation, no r22, no churn elsewhere. Pure r07 §4 + r23 §3.1 surgical reinforcement.

Sources verified:
- [Trino window functions doc (IGNORE NULLS grammar)](https://trino.io/docs/current/functions/window.html)
- [Trino PR #1244 — IGNORE/RESPECT NULLS clause](https://github.com/trinodb/trino/pull/1244)
- [Trino issue #23795 — Cast operator `::` (OPEN)](https://github.com/trinodb/trino/issues/23795)
- [Trino blog — date predicates / UnwrapCastInComparison](https://trino.io/blog/2023/04/11/date-predicates.html)
- [Trino PR #11170 — unwrap TIMESTAMP→DATE cast](https://github.com/trinodb/trino/pull/11170)
- [Trino math functions — width_bucket](https://trino.io/docs/current/functions/math.html)
- [Trino datetime functions — sequence](https://trino.io/docs/current/functions/datetime.html)
