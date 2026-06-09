# Judge Feedback — iter859 (EXTENDED PHASE)

**Overall: 4.66 PASS** (per-Q 5.00 / 5.00 / 4.50 / 4.625 = 19.125 / 4 = 4.78125 dim-cross-check; conservative governing per-Q overall = 4.656). Overall average governs; no per-Q veto. Margin +1.16 above the 3.5 floor.

**HEADLINE: The iter858 Q2 harmonic-vs-geometric DEFECT FIX LANDED CLEAN, and the iter859 defang did NOT break the geometric-mean neighbor.** Both the rate-averaging (Q1 -> harmonic) and the growth-multiplier (Q2 -> geometric) questions were answered with the CORRECT mean. No defects surfaced. Q3 and Q4 are factually clean with only minor completeness nuances.

FEDERATION NOT PROBED this iter — the federation row stays 4.49944/310 (still FAIL), UNCHANGED.

All dialect facts verified vs trino.io/docs/467 (aggregate.html, datetime.html, window.html, functions/list.html) + WebSearch + GitHub issue cross-checks, 2026-06-10. Trino 467 PINNED.

---

## Q1 — "overall average request rate" across endpoints (each row requests_per_second); teammate says plain AVG is wrong for rates

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — per-Q 5.00**

THE iter858 Q2 FIX RE-PROBE — **FIX LANDED.** The responder used the **HARMONIC mean** `1.0 / AVG(1.0 / NULLIF(requests_per_second, 0))`, NOT geometric. Explained invert/average/invert, NULLIF guards divide-by-zero, and why plain AVG is biased for rates.

VERIFIED vs trino.io/docs/467:
- Statistics: harmonic mean = n / SUM(1/x) = 1 / AVG(1/x) IS the correct mean for averaging RATES/ratios sharing a common numerator. CORRECT.
- aggregate.html: there is **NO harmonic_mean** built-in aggregate in Trino 467 (statistical aggregates listed are correlation/covariance/kurtosis/regression/skewness/stddev/variance — no harmonic_mean). functions/list.html H-section likewise has no harmonic_mean. So **hand-writing 1.0/AVG(1.0/rate) is exactly right.** CONFIRMED.
- NULLIF(rate,0) zero-guard correct (conditional.html semantics).

**VERDICT: harmonic-mean fix LANDED. Did NOT say geometric for rates. No escalation to iter860 on this axis.** Bulletproofing datapoint #1 for the new §3.1B-HM card.

---

## Q2 — average monthly GROWTH MULTIPLIER that compounds back to actual cumulative growth (1.08 / 0.95 / 1.12)

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 — per-Q 5.00**

The responder used the built-in **`geometric_mean(monthly_growth_multiplier)`**, worked the compounding example, and said plain AVG overstates the true compounded rate. CORRECT.

VERIFIED vs trino.io/docs/467:
- aggregate.html quotes verbatim `geometric_mean(x) -> double — Returns the geometric mean of all input values`. EXISTS. functions/list.html G-section indexes it. CONFIRMED.
- Geometric mean IS the correct mean for multiplicative / compounding / growth-factor data. CORRECT tool for this question.

**VERDICT: geometric_mean still correctly used for growth — NO over-correction. The iter859 defang (which marks geometric_mean-for-RATES as WRONG in §3.1B-GM) did NOT bleed into this legitimate geometric-mean use.** The neighbor is intact. This is the key check that the FIX-A defang was surgical.

---

## Q3 — add exactly 6 months to signup_date, landing on month-end when the day doesn't exist (Jan 31 + 6mo)

**Scores: Accuracy 5 / Completeness 4 / Clarity 4.5 / Actionability 4.5 — per-Q 4.50**

Responder gave `date_add('month', 6, signup_date)` for the simple case; for Oracle-style end-of-month "sticky" clamp a CASE: `WHEN signup_date = last_day_of_month(signup_date) THEN last_day_of_month(date_add('month',6,signup_date)) ELSE date_add('month',6,signup_date) END`; noted `last_day_of_month(d)` exists.

VERIFIED vs trino.io/docs/467 + sources:
- (a) `date_add(unit, value, timestamp/date)` EXISTS (datetime.html). Its NATIVE overflow handling: Trino follows java.time `plusMonths` semantics — when the target month lacks the day, it **ADJUSTS/CLAMPS to the last valid day** of the target month (e.g. Jan 31 + 1 month -> Feb 28/29). It does NOT roll over into the next month and does NOT error. The responder's characterization of date_add's native behavior is **ACCURATE.** (trino.io/docs/467 datetime.html page text doesn't spell the month edge case explicitly, so this was cross-verified — see Sources.)
- (b) `last_day_of_month(date)` EXISTS in Trino 467 (datetime.html: "Returns the last day of the month."). CONFIRMED.
- The CASE logic is internally correct and correctly gated.

**Why Completeness 4 (the nuance, NOT a dialect error):** the engineer's literal stated problem ("landing on month-end when the day doesn't exist") is ALREADY solved by `date_add('month', 6, ...)` ALONE, because date_add auto-clamps overflow. The responder's CASE adds Oracle `ADD_MONTHS` **sticky-end-of-month** parity (force the result onto the new month's last day whenever the input was the last day of its month) — a legitimate, correctly-labeled OPTIONAL behavior, but a DIFFERENT requirement from the one literally asked. The answer would be tighter if it stated up front: "date_add already clamps Jan 31 + 6mo correctly — you only need the CASE if you want Oracle's sticky month-end (e.g. Feb 28 + 6mo -> Aug 31 instead of Aug 28)." No accuracy deduction — every claim verified true.

---

## Q4 — rank salespeople by deal count within each region; tie behavior (skip vs sequential); options

**Scores: Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 4.5 — per-Q 4.625**

Responder gave ROW_NUMBER (sequential, arbitrary tie-break), RANK (ties same then SKIPS: 1,2,2,4), DENSE_RANK (ties same then NO gap: 1,2,2,3); an `OVER(PARTITION BY region ORDER BY deal_count DESC)` example; recommended DENSE_RANK for leaderboards; noted window functions cannot appear in WHERE so use a CTE then filter (rank <= 10). Rendered the tie semantics as a markdown table (its own prose, fine).

VERIFIED vs trino.io/docs/467 window.html:
- `rank()`: "tie values in the ordering will produce gaps in the sequence" -> 1,2,2,4. CORRECT.
- `dense_rank()`: "tie values do not produce gaps" -> 1,2,2,3. CORRECT.
- `row_number()`: unique sequential per row -> 1,2,3,4. CORRECT.
- Window functions cannot be used in WHERE (they run after HAVING, before ORDER BY; WHERE is evaluated before windowing) — must wrap in a subquery/CTE and filter the outer query. CORRECT (sql/select.html eval order; standard workaround confirmed).

**Why Completeness 4 (nuance, NOT a dialect error):** the example uses `GROUP BY salesperson_name, region, deal_count` and treats `deal_count` as an already-existing column. If the engineer's "total deal count" actually needs aggregation (`COUNT(*)` per salesperson per region), the window must rank over a `COUNT(*)` (either `OVER (PARTITION BY region ORDER BY COUNT(*) DESC)` alongside a GROUP BY, or rank in an outer query over a pre-aggregated CTE). As written the example is slightly off for the aggregate-then-rank case. Assessed as a completeness/correctness nuance per the directive, NOT a Trino dialect error — the tie semantics and WHERE-restriction (the actual question) are fully correct.

---

## Scoring summary

| Q | Acc | Comp | Clar | Act | Per-Q |
|---|---|---|---|---|---|
| Q1 harmonic mean (rates) | 5 | 5 | 5 | 5 | 5.00 |
| Q2 geometric_mean (growth) | 5 | 5 | 5 | 5 | 5.00 |
| Q3 date_add month + last_day_of_month + clamp | 5 | 4 | 4.5 | 4.5 | 4.50 |
| Q4 rank/dense_rank ties + WHERE restriction | 5 | 4 | 5 | 4.5 | 4.625 |

Per-Q overall = (5.00 + 5.00 + 4.50 + 4.625) / 4 = **4.656 PASS.**
Dimension cross-check: Acc (5+5+5+5)/4 = 5.00 | Comp (5+5+4+4)/4 = 4.50 | Clar (5+5+4.5+5)/4 = 4.875 | Act (5+5+4.5+4.5)/4 = 4.75 = 4.781. Governing label uses the conservative per-Q overall = 4.66 PASS.

---

## iter860 recommendation: DEFAULT NO-OP (durability sweep)

- **No defect surfaced.** The iter858 harmonic-vs-geometric FIX-A is CONFIRMED LANDED (Q1) AND surgical (Q2 geometric neighbor intact). Both directional checks (a) and (b) PASS.
- The new §3.1B-HM harmonic-mean card and the §3.1B-GM defang/cross-ref are validated on datapoint #1. **Re-probe ONCE MORE in iter860** to bulletproof: ask the rate-average from a 2nd phrasing (e.g. "average MB/s across shards", "combine per-worker QPS into one cluster QPS") AND re-probe the geometric-mean growth case from a 2nd phrasing (e.g. "average yearly return that compounds"), to confirm neither regresses. Escalate to FIX-A ONLY if the harmonic/geometric split recurs as a defect.
- Q3/Q4 nuances are minor framing completeness, NOT accuracy errors — do NOT churn. OPTIONAL low-pri only if a future probe under-scores: (Q3) add a one-line note that `date_add('month', n, d)` ALREADY clamps overflow to last valid day, so the CASE is only for Oracle sticky-month-end parity; (Q4) add a "rank over COUNT(*) — aggregate THEN window in an outer query/CTE" worked example. Neither is required now.
- Do NOT churn: the iter859 §3.1B-HM harmonic card, §3.1B-GM geometric_mean canonical + defang + cross-ref, §3.1B-WA weighted-avg, iter857 §Fact 3b at_timezone column-zone card, or any iter534-858 lock. PIN Trino 467.
- **NO federation edits** (r22 §13.x ZERO edits; federation row stays 4.49944/310, still FAIL).
- DO NOT bump training/state.json (already 859).

---

## Sources verified (trino.io/docs/467 + cross-checks, 2026-06-10)
- https://trino.io/docs/467/functions/aggregate.html — geometric_mean(x)->double EXISTS; NO harmonic_mean aggregate
- https://trino.io/docs/467/functions/datetime.html — date_add(unit,value,ts) EXISTS; last_day_of_month(date) EXISTS
- https://trino.io/docs/467/functions/window.html — rank() gaps (1,2,2,4); dense_rank() no gaps (1,2,2,3); row_number() unique sequential
- https://trino.io/docs/467/functions/list.html — H-section has no harmonic_mean; G-section indexes geometric_mean
- https://github.com/trinodb/trino/issues/15103 + java.time plusMonths semantics — date_add month overflow CLAMPS to last valid day, no rollover/error
- WebSearch: window functions not allowed in WHERE -> subquery/CTE workaround (sql/select.html eval order)
