# Judge Feedback — iter966 (EXTENDED PHASE, NO-OP breadth sweep)

**OVERALL 4.53 PASS** (Q1 5.00 / Q2 4.81 / Q3 3.38 / Q4 4.94 = 18.125/4 = 4.53; margin +1.03; OVERALL AVERAGE governs, NO per-Q veto).

All dialect/logic verified BOTH directions vs **trino.io/docs/467** (functions/window.html percent_rank + ntile; functions/aggregate.html count(x) vs count(*); sql/select.html clause-evaluation order) + WebSearch 2026-06-11 — NOT against resources/. Federation r22 §13.x hard-locked, NOT probed (OVERRIDDEN per run-prompt).

---

## Q1 — Dead inventory anti-join (LEFT JOIN products→cart_items WHERE c.product_id IS NULL) — 5.00
**Acc 5 / Comp 5 / Clar 5 / Act 5.**
- LEFT JOIN / IS NULL anti-join is CORRECT in Trino 467 and behaves the same as Postgres (the anti-join pattern is standard SQL; Trino plans it as an anti-join). VERIFIED.
- The volunteered gotcha is the standout value-add and is FACTUALLY CORRECT: after the LEFT JOIN, use `COUNT(c.item_id)` (or any right-side key) NOT `COUNT(*)` if you want "0 for a never-carted product." VERIFIED on functions/aggregate.html: `count(*)` = "the number of input rows" (counts the NULL-padded row as 1); `count(x)` = "the number of non-null input values" (the NULL-padded right key → not counted → 0). Precise, useful, correctly motivated.
- No churn, no broken secondary. Clean.

## Q2 — FAILED attempts before MOST-RECENT success — 4.81
**Acc 5 / Comp 4.5 / Clar 4.75 / Act 5.**
- The windowed `MAX(CASE WHEN status='succeeded' THEN created_at END) OVER (PARTITION BY customer_id)` correctly captures the LATEST successful payment time, because the inner subquery has NO WHERE — so the window sees ALL rows (failed + succeeded). The outer `WHERE status='failed' AND created_at < latest_success_date` applies AFTER the subquery completes. VERIFIED clause order on sql/select.html: WHERE/GROUP BY/WINDOW are computed inside the subquery; the OUTER query's WHERE runs on the subquery's already-materialized output, so it cannot truncate the inner window. Correct construction.
- TRACE (customer C: failed@t1, failed@t2, succeeded@t3, failed@t4, succeeded@t5): latest_success_date = MAX(succeeded created_at) = t5. Outer WHERE failed AND created_at < t5 → {t1, t2, t4} = **3**. This correctly INCLUDES t4 (a failure that occurred between the two successes but still before the LATEST success) — matches the literal question "before their most-recent successful payment." CORRECT.
- `MAX(...)` here is over `created_at`, a TIMESTAMP — so it is a true temporal-max, NOT the MAX(varchar)-lexicographic trap of iter964. Correct use.
- No QUALIFY. Subquery + outer WHERE form is valid 467.
- Minor (-0.5 Comp): the outer `COUNT(CASE WHEN status='failed' THEN 1 END)` is REDUNDANT after `WHERE status='failed'` (every surviving row is already 'failed', so a plain `COUNT(*)` would do). Harmless, not wrong. The no-success → NULL latest_success_date → row dropped behavior was correctly flagged with an "adjustable" note.

## Q3 — Share of revenue from TOP 10% of customers — 3.38  ★ WEAK ANSWER THIS ITER ★
**Acc 3 / Comp 4 / Clar 3 / Act 3.5.**
- **PRIMARY (NTILE) is CORRECT.** `NTILE(10) OVER (ORDER BY total_spend DESC)` → bucket 1 = first rows under the sort = HIGHEST spenders = top decile. VERIFIED functions/window.html: ntile "divides the rows ... into n buckets ranging from 1 to at most n," remainder distributed "starting with the first bucket." So `WHERE decile = 1` is the top 10%. The `SUM(top)/SUM(grand_total)` with `100.0 *` decimal promotion and `ROUND(...,2)` is correct, and the cross-join of the two single-row CTEs is fine. Fully runnable, correct answer.
- **ALTERNATIVE is BROKEN / INVERTED.** The responder said: "Top 10% = anyone with `percent_rank >= 0.90`" while keeping `ORDER BY total_spend DESC`. This is WRONG. VERIFIED functions/window.html: `percent_rank() = (r - 1)/(n - 1)`. Under `ORDER BY total_spend DESC`, the HIGHEST spender = rank 1 → percent_rank = 0.0; the LOWEST spender = rank n → percent_rank = 1.0. So `percent_rank >= 0.90` selects the BOTTOM ~10% (lowest spenders), the exact OPPOSITE of the intent. TRACE (11 customers, DESC): highest spender pr=0.0, lowest pr=1.0; `pr >= 0.90` returns pr∈{0.9,1.0} = the two LOWEST spenders. To get the top decile under DESC the threshold must be `percent_rank <= 0.10` (or use `ORDER BY ... ASC` with `>= 0.90`). An engineer who copies the alternative gets the inverse answer with no error raised — actively misleading.
- **RESOURCE-vs-SLIP determination = PURE RESPONDER SLIP, NOT a resource defect.** Grep confirms resources/07 teaches this CORRECTLY and prominently:
  - L3905-3922 LEADING CANONICAL "PERCENT_RANK / NTILE direction guardrail (iter635 top-X%-by-metric inversion trap)" with the explicit decision table: *Top 10% by spend, `ORDER BY spend DESC` → `PERCENT_RANK() <= 0.10`*; *Top 10% ASC → `>= 0.90`*; *Bottom 10% DESC → `>= 0.90`*.
  - L3922 mnemonic: "`percent_rank = 0.0` = FIRST row in the sort ... never assume `>= 0.9` means 'the top.'"
  - L3966 has a DO-NOT-WRITE block against this EXACT inverted prose.
  The responder reached PAST a correct, findable, explicitly-guardrailed canonical and reproduced the precise inversion the resource warns against. This is the broken-secondary-alternative family (iter936/943/948/950/954/958/959/960/961/963/964/965) — the LEAD (NTILE) is right, the tacked-on aside ships a wrong claim. Per-instance Haiku synthesis slip; the resource needs NO edit and adding more risks adjacent over-attraction (feedback_new_card_over_attracts_adjacent.md). Re-probe-don't-churn.

## Q4 — Late shipments per month, COUNT + % in ONE query — 4.94
**Acc 5 / Comp 4.75 / Clar 5 / Act 5.**
- `COUNT(CASE WHEN actual_delivery_date > promised_delivery_date THEN 1 END)` correctly counts late orders: VERIFIED count(x) ignores the NULL produced by the ELSE-less CASE, so only the late rows are counted. `100.0 * late / COUNT(*)` forces decimal promotion (integer/integer would truncate to 0); `ROUND(...,2)` and `GROUP BY date_trunc('month', promised_delivery_date)` are correct one-query count+pct. VERIFIED.
- The window-fn alternative `SUM(CASE...) OVER (PARTITION BY month) / COUNT(*) OVER (PARTITION BY month)` is also correct (per-row monthly ratio without collapsing rows) — a CORRECT secondary this time, not broken.
- Minor (-0.25 Comp, NOT dinged hard): `late = actual > promised` treats a NULL `actual_delivery_date` (undelivered order) as not-late (NULL comparison → not counted by count(CASE)). Reasonable default; worth a one-line caveat for the "still in transit, past due" interpretation but not wrong.

---

## SCOPE / RECOMMENDATION
- Q1 anti-join + COUNT(col)-vs-COUNT(*) gotcha clean (5.00). Q2 windowed-latest-success + count-before clean (4.81, only redundant-COUNT-CASE cosmetic). Q4 conditional-aggregation + window alt clean (4.94).
- Q3 = the weak answer: PRIMARY NTILE form CORRECT, but the `percent_rank >= 0.90` under DESC ALTERNATIVE is INVERTED (selects bottom decile). **= PURE RESPONDER SLIP against a correct + explicitly-guardrailed resource (resources/07 L3905-3966), NOT a resource/findability defect.** No resource edit; broken-secondary-alternative family; re-probe-don't-churn.
- NO resource defect / NO findability gap / NO resource edits this iter.
- **iter967 RECOMMENDATION = DEFAULT NO-OP.** Re-probe a "top X% by metric" share question from another angle (verify responder reaches `percent_rank <= 0.10` under DESC, or stays on NTILE(n) decile=1) to confirm the Q3 inversion is a one-off; also re-probe anti-join / before-most-recent-event windowing from fresh surfaces. LIGHT FIX-A only if the percent_rank DESC-direction inversion RECURS on a different surface in the next 2 sweeps — and only as a single inline reinforcement at the existing L3905 guardrail, no isolated DO-NOT-WRITE snippet (feedback_defang_donotwrite_snippets.md).

PINS REINFORCED:
- **Anti-join "never matched" = LEFT JOIN b ON a.k=b.k WHERE b.k IS NULL (Trino plans as anti-join, same as Postgres); for the count, COUNT(right_key) ignores the NULL-padded row (→0) while COUNT(*) counts it as 1 (count(x)=non-null values, count(*)=all rows).**
- **"events before the MOST-RECENT X-event" = inner subquery (NO WHERE) computing MAX(CASE WHEN x THEN ts END) OVER (PARTITION BY k); outer WHERE filters after the window → window not truncated. MAX over a TIMESTAMP col is true temporal-latest (NOT the MAX(varchar)-lexicographic trap). NO QUALIFY in 467.**
- **TOP X% by metric: NTILE(n) OVER (ORDER BY metric DESC) → bucket 1 = top decile (remainder front-loaded); percent_rank()=(r-1)/(n-1) so under ORDER BY metric DESC the TOP X% = `percent_rank <= X` (e.g. <= 0.10), NEVER `>= 0.90` (that's the BOTTOM decile under DESC). resources/07 L3905-3922 guardrail table + L3966 DO-NOT-WRITE are CORRECT and findable — Q3 alternative inverted it = responder slip.**
- **COUNT+% in ONE query = COUNT(CASE WHEN cond THEN 1 END) (count ignores ELSE-less NULL) + 100.0*late/COUNT(*) decimal promotion; window-fn variant SUM(CASE) OVER (PARTITION BY g)/COUNT(*) OVER (PARTITION BY g) for per-row ratio. NULL actual_date → not-late (reasonable default).**
- **broken-secondary-alternative meta-pattern persists (iter936/943/948/950/954/958/959/960/961/963/964/965/966): LEAD correct, tacked-on aside ships a wrong claim (Q3 percent_rank DESC inversion); per-instance Haiku slip, NOT a resource defect.**

Federation r22 §13.x hard-locked, NOT probed (OVERRIDDEN). DO NOT bump training/state.json (already 966; passed=true preserved; final_iterations_remaining 0).
