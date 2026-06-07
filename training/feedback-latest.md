# iter645 Judge Feedback — 2026-06-08

**Iteration**: 645
**Phase**: extended (default-NO-OP doctrine; iter644 PASS 4.531)
**Verdict**: STRONG PASS

## Per-Question Scores

### Q1 — Bounce rate (% of sessions with exactly ONE event)
- **Accuracy: 5.0** — `ROUND(100.0 * SUM(CASE WHEN event_count = 1 THEN 1 ELSE 0 END) / COUNT(*), 2)` over a per-session COUNT(*) subquery is mathematically correct. The 100.0 literal forces decimal division (avoids integer-truncation-to-0). The `FILTER (WHERE event_count = 1)` alternative is also valid Trino 467 per aggregate.html ("supported for all aggregate functions"). The harmless `WHERE TRUE` is a cosmetic nit. `count_if(event_count = 1)` would be marginally cleaner but is not required.
- **Completeness: 4.5** — both PRIMARY and ALT forms produced; per-session GROUP BY structure correct; two-level aggregation (per-session count, then cross-session share) is the right shape. Minor: no `count_if` mention.
- **Clarity: 4.5** — formula is well-explained; SUM(CASE) idiom is the most beginner-friendly form.
- **Actionability: 5.0** — engineer can drop this in and run it.
- **Per-Q avg: 4.75 STRONG PASS**

### Q2 — Last calendar day of month for invoice_date (leap-year safe)
- **Accuracy: 5.0** — `last_day_of_month(invoice_date)` is a REAL Trino 467 function. **Verified at trino.io/docs/467/functions/datetime.html: "last_day_of_month(x) -> date — Returns the last day of the month."** Built-in, inherently leap-year safe (Feb 2024 -> Feb 29; Feb 2026 -> Feb 28). Responder did NOT fabricate — this is the docs-correct one-function answer. The Oracle name `LAST_DAY` differs (bare `LAST_DAY(dt)` yields "Function 'last_day' not registered") and the Spark/BigQuery/Snowflake `end_of_month` does NOT exist in Trino — both correctly avoided.
- **Completeness: 5.0** — primary answer plus a date_add month-end-preserving variant offered as an alternative.
- **Clarity: 5.0** — one-function answer; can't be simpler.
- **Actionability: 5.0** — drop-in usable.
- **Per-Q avg: 5.0 STRONG PASS — `last_day_of_month` CONFIRMED REAL Trino 467 function**

### Q3 — Top-3 products per category INCLUDING ties at 3rd place
- **Accuracy: 5.0** — **CRITICAL RANK-CONTEXT CHECK CONFIRMED: RANK() OVER (...) WHERE rank <= 3 is the CORRECT choice for inclusive-top-N-with-ties.** Verified at trino.io/docs/467/functions/window.html: RANK ties produce gaps (1,2,2,4); ROW_NUMBER assigns unique sequential numbers (would cut tied rows arbitrarily); DENSE_RANK no-gap (1,2,2,3 — would keep more than N distinct levels' worth). For a 3-way tie at rank 3 (rows ranked 1,2,3,3,3,6), `WHERE rank <= 3` correctly keeps all three rank-3 rows. Responder's explanation that ROW_NUMBER cuts ties while RANK keeps boundary ties is verbatim correct. **This is the contextual FLIP of the iter642/643 single-Nth case** (where DENSE_RANK=N is right for Nth-distinct-largest) — and the responder correctly chose RANK<=N here. The iter643 decision canonical at r23:982-1065 is being READ CONTEXTUALLY, not memorized. Major durability win.
- **Completeness: 5.0** — explicit contrast with ROW_NUMBER (cuts ties) named; tie semantics explained; PARTITION BY category + ORDER BY units_sold DESC structure correct.
- **Clarity: 5.0** — 1,2,2,4 vs 1,2,3,4 contrast is the textbook teaching device.
- **Actionability: 5.0** — engineer can use exactly as-is.
- **Per-Q avg: 5.0 STRONG PASS — RANK<=N contextual selection HELD; iter643 canonical's inverse case routes correctly**

### Q4 — Average session length in minutes (first-to-last event per session, then average)
- **Accuracy: 5.0** — `date_diff('minute', MIN(event_timestamp), MAX(event_timestamp))` with arg order (unit, earlier, later) is correct Trino 467 per datetime.html: `date_diff(unit, t1, t2) -> bigint` returns t2-t1, positive when t2 later. Putting MIN as arg2 and MAX as arg3 produces a positive duration. Two-level aggregation (CTE: per-session duration; outer: AVG across sessions) is the correct shape — direct AVG without per-session GROUP BY would average across all events, not per-session durations. No date-minus-date arithmetic attempted.
- **Completeness: 4.5** — clean two-level CTE; minor missing: no mention of single-event sessions (where MIN=MAX -> 0 minutes; included in AVG correctly but worth flagging as a sentinel value).
- **Clarity: 5.0** — CTE named `session_duration`, projected column `session_minutes`, outer AVG — easy to read.
- **Actionability: 5.0** — drop-in usable.
- **Per-Q avg: 4.875 STRONG PASS**

## Overall

**Per-Q average: (4.75 + 5.0 + 5.0 + 4.875) / 4 = 4.90625**

Dim-avg cross-check:
- Accuracy: (5.0 + 5.0 + 5.0 + 5.0)/4 = 5.0
- Completeness: (4.5 + 5.0 + 5.0 + 4.5)/4 = 4.75
- Clarity: (4.5 + 5.0 + 5.0 + 5.0)/4 = 4.875
- Actionability: (5.0 + 5.0 + 5.0 + 5.0)/4 = 5.0
- Mean of dims: (5.0 + 4.75 + 4.875 + 5.0)/4 = 4.90625 — agrees

**GOVERNING LABEL = STRONG PASS** (overall 4.90625 >= 3.5 by margin +1.40625; no per-Q < 3.5).

## Verifications via WebFetch (trino.io/docs/467)

1. **functions/datetime.html** — confirmed `last_day_of_month(x) -> date` REAL function ("Returns the last day of the month"). Leap-year safe by construction. NOT fabricated.
2. **functions/window.html** — confirmed RANK gap-with-skip (1,2,2,4), ROW_NUMBER unique sequential, DENSE_RANK no-gap (1,2,2,3). RANK<=N is the docs-correct choice for inclusive-top-N-with-ties.
3. **functions/aggregate.html** — confirmed `count_if(x)` exists and equals `count(CASE WHEN x THEN 1 END)`; FILTER (WHERE ...) supported for all aggregate functions; SUM(CASE WHEN ... THEN 1 ELSE 0 END) is equivalent in the share-of-total context.
4. **functions/datetime.html (date_diff)** — confirmed `date_diff(unit, t1, t2) -> bigint` returns t2-t1, positive when t2 later. MIN-as-arg2 / MAX-as-arg3 produces positive minute duration.

## iter645 Durability Signals (KEY DURABILITY WINS)

1. **Contextual RANK/DENSE_RANK/ROW_NUMBER selection HELD (Q3)** — the iter643 decision canonical at r23:982 is being READ CONTEXTUALLY. The responder correctly chose:
   - DENSE_RANK=N for single-Nth-distinct (iter643)
   - RANK<=N for inclusive-top-N-with-ties (iter645)
   - ROW_NUMBER for literal-Nth-row (covered in same canonical)
   This is the durable inverse of the iter642 silent-wrong RANK=N bug — the canonical's three-way decision is now bi-directionally probed and HOLDS.
2. **`last_day_of_month` CONFIRMED REAL Trino 467 function (Q2)** — resources r27:639-717 correctly affirm it; responder did not fabricate or unnecessarily fall back to `date_trunc('month',...) + INTERVAL '1' MONTH - INTERVAL '1' DAY`. Oracle `LAST_DAY` rename and Spark/BigQuery `end_of_month` non-existence correctly avoided.
3. **count_if / SUM(CASE) / FILTER share-of-total all valid (Q1)** — responder offered equivalent forms; all are docs-correct; 100.0 float-division guard applied.
4. **date_diff arg order MIN-as-earlier / MAX-as-later (Q4)** — column-scope discipline (project session_minutes in CTE before outer AVG references it) HOLDS; matches iter641 FIX-A days-between canonical pattern.

## Federation Status

Federation NOT probed this iter. 4.49944/311 row UNCHANGED. None of the 4 questions touch r22 cross-catalog territory.

## Recommendation for iter646

**DEFAULT NO-OP / DURABILITY-BREADTH.** No per-Q < 3.5; lowest per-Q is Q1 at 4.75 (well above floor). All four canonicals durability-confirmed:
- bounce-rate share (count_if / SUM(CASE) / FILTER)
- last_day_of_month (real function, correctly cited)
- top-N-with-ties RANK<=N (contextual inverse of single-Nth DENSE_RANK=N)
- AVG of per-session date_diff('minute',...) two-level aggregation

**DO NOT**:
- Re-edit r23:982-1065 RANK/DENSE_RANK/ROW_NUMBER decision canonical (HOLDS contextually both directions, iter643 PIN + iter645 inverse-probe confirmation)
- Re-edit r27:639-717 last_day_of_month canonical (15 correct affirmations, iter645 probe HELD)
- Re-edit r23:683-737 + r23:1982 count_if canonical (HOLDS for bounce-rate share)
- Re-edit r23:1100-1217 date_diff days/minutes canonical (HOLDS for session-duration two-level)
- Re-edit r22 §13.x federation guardrails (4.49944/311 thin, ZERO probe iter645)
- Rewrite iter534-644 locks
- Add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban), fabricate dayname()/initcap, DISTINCT-ON Postgres-leak (iter634 ban)
- Bump training/state.json (iteration already 645)

**SUGGESTED iter646 FRESH-AREA PROBES** (synthesizable-from-primitives; DO NOT pre-probe with new content):
- Median / approximate-percentile over a metric (approx_percentile primitive at r23 ~L141-159)
- Gap-based session segmentation with LAG threshold (r07 max-gap canonical)
- Distinct-categories-per-customer with HAVING COUNT(DISTINCT) >= N (r07)
- Cross-catalog federation re-probe at a bulletproofed angle (predicate pushdown to PostgreSQL) — IF the run-prompt opts back into federation

## Headline

iter645 = STRONG PASS at 4.90625 — highest overall in recent iterations. The contextual RANK/DENSE_RANK/ROW_NUMBER selection canonical (iter643 PIN) is bi-directionally durable; `last_day_of_month` real-function citation HOLDS; bounce-rate share and session-duration two-level aggregation both canonical-clean. NO FIX-A candidate. Federation row stays 4.49944/311.
