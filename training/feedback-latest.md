# Judge Feedback — Iter 943

**Sweep type**: DEFAULT NO-OP durability sweep (teacher ZERO resource edits this iter; iter943 spot-check only).
**Phase**: extended (passed=true; final_iterations_remaining=0).
**Pin**: Trino 467.

## Per-question scores

| Q | Acc | Comp | Clar | Act | Avg | Notes |
|---|---|---|---|---|---|---|
| Q1 longest-gap (LAG+date_diff+MAX+IS NOT NULL) | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 | Clean textbook |
| Q2 median + below-median users | 2.0 | 3.0 | 3.5 | 3.0 | 2.875 | LEAD correct, SECONDARY fabricated + misattributed-error figure |
| Q3 day-of-week signups format_datetime+GROUP BY | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 | format_datetime(DATE, 'EEEE') OK via coercion |
| Q4 refund rate via LEFT JOIN+COUNT(DISTINCT) | 5.0 | 5.0 | 5.0 | 5.0 | 5.000 | Fan-out de-dup correct, COUNT(*) warning correct |

**Overall avg**: (5.000 + 2.875 + 5.000 + 5.000) / 4 = **4.46875 PASS** (margin +0.96875 over 3.5; overall average GOVERNS, no per-Q veto).

**Federation NOT probed this iter** — 4.49944 / 310 row UNCHANGED.

---

## Q1 — longest gap between consecutive customer orders (5.000 clean)

```sql
WITH gaps AS (
  SELECT customer_id,
         date_diff('day', LAG(created_at) OVER (PARTITION BY customer_id ORDER BY created_at), created_at) AS days_since_prev_order
  FROM orders
)
SELECT customer_id, MAX(days_since_prev_order) AS max_gap_days
FROM gaps
GROUP BY customer_id
HAVING MAX(days_since_prev_order) IS NOT NULL  -- (responder used outer WHERE on the aliased result; functionally same)
ORDER BY max_gap_days DESC;
```

**Verified**:
- `LAG(created_at) OVER (PARTITION BY customer_id ORDER BY created_at)` valid 467 (functions/window.html).
- `date_diff('day', a, b)` day-aware difference returning bigint (functions/datetime.html). LAG first-row → NULL ⇒ date_diff(NULL, ...) → NULL ⇒ MAX skips NULL ⇒ single-order customers come out with NULL max_gap_days, correctly excluded by the outer `WHERE max_gap_days IS NOT NULL`.
- Style nit only (not error): inlining the LAG expression inside date_diff vs naming it as a separate `prev_order_at` column — both compile to the same plan in Trino. No ding.

## Q2 — users with MORE events than the MEDIAN user (2.875 — DIALECT DEFECT in SECONDARY)

### LEAD form (CORRECT)

```sql
WITH user_event_counts AS (SELECT user_id, COUNT(*) AS event_count FROM events GROUP BY user_id),
     percentile_summary AS (SELECT approx_percentile(event_count, 0.5) AS median_event_count FROM user_event_counts)
SELECT uc.user_id, uc.event_count
FROM user_event_counts uc CROSS JOIN percentile_summary ps
WHERE uc.event_count > ps.median_event_count;
```

**LEAD verdict**: VALID Trino 467 (approx_percentile(x, 0.5) is the documented 50th-percentile form per functions/aggregate.html; single-row scalar broadcast via CROSS JOIN is canonical).

### TWO DEFECTS IN THE SAME ANSWER

**Defect A — fabricated SECONDARY "exact median" alternative.**
> `SELECT PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY event_count) AS median_event_count FROM user_event_counts`

This DOES NOT PARSE in Trino 467. Verified against trino.io/docs/467/functions/aggregate.html and git-tag 467 grammar:
- Trino 467 has NO `percentile_cont`, NO `percentile_disc`, NO `median()` builtin.
- `WITHIN GROUP (ORDER BY ...)` syntax exists ONLY for `listagg` — there is no ordered-set-aggregate registration for any percentile function.
- Reader copy-pasting the secondary alternative gets a function-resolution / parse error. The form is a Postgres / Oracle / SQL Server / Snowflake import.

**Defect B — misattributed standard-error figure.**
The answer claims `approx_percentile` has "~2.3% standard error." Verified against trino.io/docs/467/functions/aggregate.html:
- The 2.3% standard-error figure is documented for `approx_distinct` ONLY (HyperLogLog). The exact quoted doc text: *"This function should produce a standard error of 2.3%"* — that statement is in the `approx_distinct` block.
- `approx_percentile` has NO published standard-error figure. It has a tunable accuracy / weight parameter, but no closed-form error guarantee in the docs.

(Cross-check: WebSearch 2026-06-10 confirmed; an earlier WebFetch summary that conflated the two was hallucinated and contradicts both the actual docs and the standing pin in MEMORY.md `reference_trino_approx_percentile_error.md`.)

### Disposition — Q2 SCOPE = RESPONDER SLIP (regression vs iter934)

This is NOT a findable gap. Resources teach both facts findably and prominently:

- **r23 (sql-best-practices) L267–273, L316, L2240** — explicit anchors *"no exact percentile-VALUE function (no percentile_cont / percentile_disc / median)"* + *"Trino's docs publish NO standard-error figure for"* approx_percentile (in the same paragraph). Anchor keywords include "exact percentile Trino", "PERCENTILE_CONT Trino", "approx_percentile accuracy parameter".
- **r05 (multi-tenant-analytics) L2234 CRITICAL SQL FOOTGUN card** — a copy-magnetic WRONG-marked `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY x)` block paired with the CORRECT `approx_percentile(x, 0.5)` replacement and a one-liner *"WITHIN GROUP syntax is supported only for `listagg` — not for any percentile function. Writing it against Trino fails at parse time with a cryptic syntax error."* L2263 also explicitly states `MEDIAN(x)` does not exist.

The responder got BOTH of these correct as recently as iter934 (rubric L72: *"NO percentile_cont/percentile_disc/percentile-WITHIN-GROUP CONFIRMED ABSENT in 467 ... refusing to fabricate a number is exactly right"*). The cards are dense, well-anchored, and copy-attractive. The LEAD this iter was correct; the slip is in the SECONDARY "by the way, here is the exact alternative" paragraph the responder synthesized as a courtesy — and it imported the foreign-dialect form the resource explicitly WRONG-marks, while also lifting the 2.3% number from the neighboring approx_distinct entry.

This is the classic Haiku synthesis pattern: lead canonical correct, secondary "for completeness" import wrong. Resources already inoculate against this with copy-magnetic WRONG-marks; the inoculation is being applied in the LEAD but not in the SECONDARY.

### iter944 recommendation — RE-PROBE-DON'T-CHURN, NO FIX-A

**Do NOT add a new "percentile defang" card.** The defang already exists in r23 AND r05 in copy-magnetic prominent form, with the exact WRONG and CORRECT pair the responder needed. Adding a third copy risks:
1. New-Card over-attracts-adjacent regression (the percentile defang is dense; another card could pull a neighbor like geometric_mean / harmonic_mean / approx_distinct itself into the wrong neighborhood).
2. Defang-DO-NOT-WRITE backfire (the wrong form is already shown defanged in r05 L2241; copying it into a third card increases the surface area of the literal wrong-form text that the Haiku responder reads raw).

**Recommended iter944**:
- DEFAULT NO-OP / ZERO edits. State counter: **1st recurrence of percentile_cont/2.3% slip since iter934 clean**. Two further recurrences without intervening clean answer ⇒ escalate to a dedicated "percentile router" card.
- **Targeted re-probe in iter944**: ask a median / percentile question phrased to elicit BOTH a primary AND a secondary alternative — e.g., *"Show me the median order value per tenant — give me both the approximate Trino-native form and any exact alternative if one exists."* Goal: verify whether the responder leads with `approx_percentile` AND correctly refuses the "exact alternative" (says "Trino has no exact percentile-value function; approx_percentile is it") rather than fabricating PERCENTILE_CONT WITHIN GROUP. If the responder again offers a fabricated exact form ⇒ 2nd recurrence ⇒ different recommendation may apply.
- Also re-probe: standalone approx_percentile question asking "what is the error tolerance / accuracy" — see whether responder attaches "2.3%" again (which would be a 2nd recurrence of misattribution).

## Q3 — day-of-week with most signups (5.000 clean)

```sql
SELECT format_datetime(signup_date, 'EEEE') AS day_of_week, COUNT(*) AS signup_count
FROM signups
GROUP BY format_datetime(signup_date, 'EEEE')
ORDER BY signup_count DESC;
```

**Verified**:
- `format_datetime(timestamp, format)` is documented in functions/datetime.html and uses JodaTime DateTimeFormat patterns; `'EEEE'` returns the full English day name ("Monday" … "Sunday"). Joda symbol confirmed.
- `signup_date` typed as DATE works because Trino 467 has implicit DATE → TIMESTAMP coercion (per pinned reference_trino_timestamp_tz_coercion.md and the TypeCoercion git-tag source) — no explicit CAST needed.
- GROUP BY repeats the day-name expression (not the alias) — required by select.html; correct.
- Per-bucket-count shape is correct: 7 rows (one per weekday), each with COUNT(*) of signups that day. The pinned GROUP-BY-output-shape rule is honored — no unique key inside the GROUP BY (which would have collapsed COUNT(*) to 1).
- Numeric variant adding `day_of_week(signup_date)` (returns 1=Mon..7=Sun, also accepts DATE) is a valid sort-stable alternative — both forms work.

No ding. The pinned iter941/942 GROUP-BY-shape locks held cleanly here.

## Q4 — refund rate per product (5.000 clean)

```sql
SELECT oi.product_id,
       COUNT(DISTINCT oi.order_id) AS total_orders,
       COUNT(DISTINCT CASE WHEN r.order_id IS NOT NULL THEN oi.order_id END) AS refunded_orders,
       ROUND(100.0 * COUNT(DISTINCT CASE WHEN r.order_id IS NOT NULL THEN oi.order_id END)
                   / COUNT(DISTINCT oi.order_id), 2) AS refund_rate_pct
FROM order_items oi LEFT JOIN refunds r ON oi.order_id = r.order_id
GROUP BY oi.product_id
ORDER BY refund_rate_pct DESC;
```

**Verified**:
- `COUNT(DISTINCT col)` single-arg form is the only valid 467 shape (pinned COUNT-DISTINCT-single-arg). The order_items fan-out (3 item-rows per 1 order) is correctly collapsed by COUNT(DISTINCT oi.order_id) — without DISTINCT, COUNT(*) would over-count the denominator 3x. Responder explicitly calls out this trap with the correct numerical example — strong pedagogy.
- LEFT JOIN preserves rows in order_items with no refunds; refund_rate numerator uses `CASE WHEN r.order_id IS NOT NULL` to count only matched orders. COUNT(DISTINCT) on the CASE expression correctly de-dupes.
- `100.0` decimal-promo correctly avoids integer division collapsing to 0 (Division pin).
- `ROUND(x, 2)` half-up rounding (pinned CAST-to-integer-rounds family); produces percent-with-2-decimals.
- LEFT JOIN + ON-clause join predicate is the canonical anti-join-preserving shape; no WHERE-on-right-side trap (which would convert it to inner join).

Clean. No ding.

---

## Scope summary

- **No resource defect** in any of the 4 areas probed (Q1 LAG/date_diff/MAX, Q2 percentile family — resources r23 + r05 are excellent and findable, Q3 format_datetime+day-name, Q4 LEFT JOIN + COUNT(DISTINCT) fan-out).
- **Responder slip on Q2 secondary**: fabricated PERCENTILE_CONT WITHIN GROUP alternative + 2.3% misattributed to approx_percentile. Both rules are findably taught and were applied correctly at iter934. 1st recurrence in the percentile family.
- **No findable gap** — the percentile defang cards in r05 L2234 and r23 L267–293 are copy-magnetic and well-anchored.

## iter944 plan (recommended)

- **DEFAULT NO-OP — teacher ZERO edits.** Do NOT churn r05/r23 percentile cards; they are dense and dialect-correct. Adding a third percentile defang card risks New-Card / defang backfire (per markdown-pipe-trap + defang-DO-NOT-WRITE lessons).
- **Targeted re-probe** of percentile family in iter944:
  1. Median / percentile question explicitly asking for "approximate AND exact alternative if one exists" — verify responder declines to fabricate PERCENTILE_CONT.
  2. Standalone approx_percentile accuracy-question — verify responder does NOT attach "2.3% standard error" (which is approx_distinct only).
- **Escalation threshold**: a dedicated "Trino percentile = approx_percentile ONLY; no percentile_cont/disc/WITHIN-GROUP-except-listagg; no published error figure; 2.3% is approx_distinct-only" router card is warranted ONLY if the slip recurs across 2+ further sweeps without intervening clean answer.
- Federation (4.49944 / 310) only un-passed row — bulletproofed angles only if probed, no edits.
- Preserve the full iter534–942 pin inventory; NO federation edits, NO percentile-card edits.
- PIN Trino 467.
- DO NOT bump training/state.json (already at 943; passed=true; overall 4.46875 PASS holds).

## Pins reinforced this iter (no new pins)

- Trino 467 percentile = `approx_percentile(x, p)` ONLY. NO `percentile_cont` / `percentile_disc` / `median()`. `WITHIN GROUP (ORDER BY …)` exists ONLY for `listagg`, not for any percentile function.
- `approx_percentile` has NO published standard-error figure (tunable accuracy / weight param). 2.3% is documented for `approx_distinct` ONLY.
- DATE → TIMESTAMP implicit coercion EXISTS in Trino 467 ⇒ `format_datetime(signup_date_DATE, 'EEEE')` and `day_of_week(signup_date_DATE)` both work without CAST.
- GROUP-BY output shape — GROUP BY the bucket / grouping expression ONLY for per-bucket count; do not include a unique key.
- LEFT JOIN fan-out de-dup via `COUNT(DISTINCT join_key)`; predicates on right-side belong in ON, not WHERE.
- `100.0` decimal-promo on percent formulas (avoid integer-division → 0).
- `ROUND(x, n)` half-up.
- `date_diff(unit, a, b)` day-aware / complete-units (drops fractional).
- LAG/LEAD: first-row LAG → NULL; date_diff(NULL, …) → NULL; MAX skips NULL.
