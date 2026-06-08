# Judge Feedback — iter727

Docs verified against trino.io/docs/467 (array.html, datetime.html, aggregate.html, conversion.html) on 2026-06-08.

## Per-question scores

### Q1 — array_min (single smallest value WITHIN an array, no exploding)
- Accuracy: 5 — `array_min(x) → x` verified verbatim on functions/array.html ("Returns the minimum value of input array"); returns the min element directly, NO UNNEST. NULL-propagation + `filter(arr, x -> x IS NOT NULL)` strip-first workaround is correct standard semantics.
- Completeness: 5 — answered exactly the ask; included the NULL gotcha + workaround.
- Clarity: 5 — single clean function, one-row-in/one-row-out framing, no jargon.
- Actionability: 5 — copy-ready SQL, engineer knows exactly what to do.
- Avg: 5.00. Critically: responder did NOT use UNNEST+MIN and did NOT use a LEAST/array-index hack. Clean.

### Q2 — EXTRACT day/month as integer
- Accuracy: 5 — `extract(field FROM x) → bigint` verified; EXTRACT(MONTH/DAY FROM date) returns integer component. All listed fields valid Trino 467: YEAR, QUARTER, MONTH, WEEK, DAY, DAY_OF_MONTH, DAY_OF_WEEK, and DOW is a confirmed alias for DAY_OF_WEEK. No invalid field listed.
- Completeness: 4.5 — answered fully; could have mentioned `month(x)`/`day(x)` shorthand (both exist per docs) as an even terser form, but EXTRACT is the requested "clean way."
- Clarity: 5 — direct, no assumed knowledge.
- Actionability: 5 — copy-ready.
- Avg: 4.875.

### Q3 — boolean → 1/0 for SUM
- Accuracy: 5 — `count_if(is_converted)` verified native ("Returns the number of TRUE input values... equivalent to count(CASE WHEN x THEN 1 END)"). `SUM(CASE WHEN is_converted THEN 1 ELSE 0 END)` valid. "Both identical plans" is fair.
- Completeness: 4 — GAP: the user's LITERAL phrasing was "turn that boolean flag into a 1 or 0." The single most-literal answer is `CAST(is_converted AS integer)` (→ 1/0; standard Trino behavior, well-established though not spelled out verbatim on conversion.html). The responder did NOT show this direct CAST form. NOT over-penalized: count_if + SUM(CASE) both correctly achieve the stated GOAL (summing conversions), and count_if is genuinely the idiomatic Trino choice. But a user who specifically wants the scalar 1/0 expression (e.g. to multiply, or to SUM inline with other expressions) was not handed it.
- Clarity: 5 — clear preferred/fallback structure.
- Actionability: 4.5 — engineer can SUM conversions immediately; minor: no direct cast-to-1/0 scalar if needed inline.
- Avg: 4.625.

### Q4 — COUNT(DISTINCT) total
- Accuracy: 5 — `COUNT(DISTINCT user_id)` exact, no GROUP BY → single row. `approx_distinct` verified (~2.3% standard error per docs; responder's "~2%" is within rounding and fine).
- Completeness: 5 — exact + scale-out approx alternative.
- Clarity: 5 — direct.
- Actionability: 5 — copy-ready.
- Avg: 5.00.

## Overall

| Q | Acc | Comp | Clar | Act | Avg |
|---|-----|------|------|-----|-----|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 4.5 | 5 | 5 | 4.875 |
| Q3 | 5 | 4 | 5 | 4.5 | 4.625 |
| Q4 | 5 | 5 | 5 | 5 | 5.00 |

**OVERALL AVERAGE = 4.875 — PASS** (well above 3.5; no per-Q override).

## array_min/array_max verdict
**STAYS CLOSED.** 2nd consecutive clean datapoint after the iter726 FIX-A. The responder reached straight for `array_min(arr)` (single function, no UNNEST, no LEAST/fixed-index hack), and included the NULL-element gotcha + filter() strip-first workaround. The iter726 canonical in r07 §1a is doing its job — no regression to the iter725 UNNEST+MAX / GREATEST-fixed-index forms. Array-reducer family confirmed closed.

## Teacher action / iter728 flag
- **NO new genuine defect.** All four answers are docs-correct and well above threshold.
- **Minor findability nudge (OPTIONAL, low priority) for iter728:** Q3 completeness — the literal phrasing "turn a boolean into a 1 or 0" is best served by also surfacing `CAST(is_converted AS integer)` → 1/0 as the direct scalar form, alongside count_if (aggregate) and SUM(CASE) (portable). If a boolean→1/0 canonical exists in r23 §best-practices or r02, verify it lists all three (CAST scalar / count_if aggregate / SUM(CASE) portable) and routes by phrasing (scalar-per-row vs count-the-trues). NUDGE, not a fix — Q3 still PASSED at 4.625 and the GOAL was correctly met. Do not churn correct canonical for this.
- Default posture for iter728 absent a fresh defect: NO-OP integrity sweep.
