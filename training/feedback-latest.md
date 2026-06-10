# iter970 Judge Feedback — EXTENDED PHASE, NO-OP breadth sweep

**OVERALL: 4.50 STRONG PASS** (Q1 4.94 / Q2 4.88 / Q3 4.88 / Q4 3.31 = 18.00/4 = 4.50; margin +1.00; OVERALL AVERAGE governs, NO per-Q veto.)

Verification: all dialect/logic claims checked BOTH directions vs trino.io/docs/467 (aggregate.html, datetime.html) + WebSearch/WebFetch 2026-06-11 + pinned-memory references — NOT against resources/. Column scope TRACED on every CTE (Q2, Q4). State.json NOT bumped.

---

## Per-question scores

### Q1 — Cart abandonment rate (carts vs orders) — **4.94 CLEAN**
`LEFT JOIN carts c -> orders o ON o.cart_id=c.cart_id`, `COUNT(DISTINCT c.cart_id)` total, `COUNT(DISTINCT CASE WHEN o.order_id IS NULL THEN c.cart_id END)` abandoned, `100.0 * abandoned / NULLIF(COUNT(DISTINCT c.cart_id),0)`, WHERE on `c.created_at`.
- Acc 5.0: LEFT JOIN keeps all carts; `o.order_id IS NULL` is the textbook anti-join / abandoned detector; COUNT(DISTINCT) protects against a cart matching multiple order rows. `100.0*` decimal promotion + NULLIF div-by-zero guard both correct (verified vs reference_trino_division_by_zero pin: INTEGER `/` 0 THROWS, NULLIF avoids it). Column scope clean (all cols exist on carts/orders).
- Clar 5.0 / App 5.0 / Comp 4.75 (-0.25: leaves the cart→order grain assumption — one cart = at most one order — implicit; minor). Solid abandonment-rate pattern.

### Q2 — Products whose AVG review score DROPPED Q3→Q4 last year — **4.88 CLEAN**
`quarterly_scores` CTE projects (product_id, EXTRACT(QUARTER...) AS quarter, EXTRACT(YEAR...) AS year, AVG(score) AS avg_score); self-join q3(quarter=3) to q4(quarter=4) same product+year; WHERE q4.avg_score < q3.avg_score; ORDER BY score_change ASC. LEFT-JOIN variant for products with no Q4 data.
- **EXTRACT(QUARTER FROM date) + EXTRACT(YEAR FROM date) VERIFIED present in 467** (datetime.html: QUARTER and YEAR both in the supported EXTRACT field list). Not a fabrication.
- **COLUMN SCOPE TRACED — CLEAN (iter969-style omission did NOT recur):** CTE projects product_id, quarter, year, avg_score — ALL four are referenced downstream (quarter in join filter, year in join, product_id/avg_score in SELECT). No partition/join key omitted from the projection. This is exactly the column-scope discipline iter969-Q1 missed; it held here.
- Acc 5.0 / Clar 5.0 / App 5.0 / Comp 4.5 (-0.5: self-join is correct but a single-pass conditional-AVG GROUP BY product would be cheaper; not wrong, just not the leanest. LEFT-JOIN "no Q4 data" variant is a nice completeness touch).

### Q3 — % of quota per tenant, flag >90% (storage_usage vs quotas) — **4.88 CLEAN**
`tenants t LEFT JOIN storage_usage LEFT JOIN quotas`; `100.0 * s.used_bytes / NULLIF(q.quota_bytes,0) AS usage_pct`; CASE → ERROR (null/zero quota) / ALERT (>90) / WARNING (>75) / OK; ORDER BY usage_pct DESC NULLS LAST.
- **All three division claims VERIFIED:** (a) integer/integer division TRUNCATES toward zero — correct (division pin); (b) INTEGER/DECIMAL division by zero THROWS DIVISION_BY_ZERO — correct (reference_trino_division_by_zero, git-tag-confirmed); (c) NULLIF(quota_bytes,0) guard prevents the throw — correct; (d) `100.0*` decimal promotion avoids the truncation footgun — correct. The responder pre-empted the exact division gotcha the question hinted at ("just a join + division or gotchas?") — strong practical fit.
- LEFT JOIN from tenants keeps tenants with no usage/quota row; NULLS LAST ordering surfaces real percentages first. Column scope clean.
- Acc 5.0 / Clar 5.0 / App 5.0 / Comp 4.5 (-0.5: the ERROR/ALERT/WARNING tiering is a small over-delivery vs the asked binary >90% flag, but it directly answers "any gotchas?" so net positive).

### Q4 — AVG time between 1st and 2nd purchase (customers with >=2 purchases) — **3.31 — CORE CORRECT, VOLUNTEERED PERCENTILE_CONT FABRICATION (KEY CHECK)**
Core: `ranked_orders` CTE = ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date ASC) AS order_seq; `customer_gaps` self-joins ranked_orders to itself on customer_id with order_seq=1 (first) and order_seq=2 (second), `date_diff('day', first, second) AS days_to_second_purchase`; final SELECT COUNT(DISTINCT customer_id), AVG(days_to_second_purchase), MIN, MAX **and `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY days_to_second_purchase) AS median_days`**.

- **THE CORE ANSWER IS CORRECT and exactly answers the question:** ROW_NUMBER 1st/2nd + self-join order_seq=1/=2 + date_diff('day',...) + AVG over the gaps = the AVERAGE first-to-second gap. INNER JOIN order_seq=2 correctly EXCLUDES <2-purchase customers (a 1-purchase customer has no seq=2 row, drops out). date_diff('day', ts1, ts2) -> bigint, day-aware, no `ts - ts` operator — VERIFIED (datetime.html + reference_trino_datediff_dayaware pin). Column scope on BOTH CTEs CLEAN (ranked_orders projects customer_id/order_id/order_date/order_seq, all referenced; customer_gaps projects customer_id/dates/gap, all referenced downstream). **iter969 column-scope slip did NOT recur.**

- **FABRICATION (key check, CONFIRMED via trino.io/docs/467/functions/aggregate.html):** `PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY ...)` does NOT exist in Trino 467. WebFetch of aggregate.html confirms: **NO percentile_cont, NO percentile_disc; WITHIN GROUP (ORDER BY ...) is supported ONLY for listagg().** The correct median is `approx_percentile(days_to_second_purchase, 0.5)`. The responder's volunteered claim "available on Trino 467 for continuous percentiles (verified in the aggregate-functions docs)" is a **CONFIDENT FABRICATION + FALSE doc-citation** — the docs say the opposite. The `PERCENTILE_DISC` mention is also fabricated. This median line WON'T COMPILE (function-not-found) and the false "verified" claim is the more damaging part.

- **RESOURCE-vs-SLIP = PURE RESPONDER SYNTHESIS SLIP, NO resource fix:** The resources GUARD this correctly — r05 L2234-2266 and r23 L265/L273-275 explicitly state Trino has NO percentile_cont/disc and to use approx_percentile. The resource teaches it right AND guards the exact footgun; the responder reached PAST the guard and fabricated the function in a *volunteered* (un-asked) extra metric. Not a content/findability defect.

- **INTERMITTENT, NOT a 2-in-2 recurrence:** This percentile fabrication last appeared iter943 (different question). In the interim approx_percentile was used CORRECTLY (iter961 median-ticket, iter968 p95/array form). So it is an INTERMITTENT volunteered-metric slip in the broken-secondary-alternative family (iter936/943/948/950/954/958/959/960/961/962/963/964/965/966/968/969), NOT a clean 2-in-2-sweeps recurrence. Per feedback_responder_broken_secondary_alternative.md + feedback_synthesis_ceiling_stop_churning.md: per-instance one-off, re-probe-don't-churn, NO defang/resource edit.

- Scores: Acc 2.5 (core fully correct + correctly answers the asked AVG/MIN/MAX/exclusion; but volunteered median line is a non-existent function with a FALSE "verified in docs" claim — a fabricated function + false citation is a real, not cosmetic, error). Clar 4.0 (well-structured CTEs, clear; the false confidence on median misleads). App 3.5 (engineer who copies the core gets the right answer; one who copies the median line gets a function-not-found error — the false "verified" claim makes this worse than a silent typo). Comp 3.25 (over-delivered an extra metric and got it wrong; the asked AVG is correct). = 13.25/4 = 3.31.

---

## Scope summary

- **Q1/Q2/Q3 CLEAN** — all leads correct, all dialect facts verified, all column scopes traced clean.
- **Q4 core CORRECT** (the asked AVG gap), **but volunteered `PERCENTILE_CONT ... WITHIN GROUP` is a FABRICATION** (no such function in 467; WITHIN GROUP = listagg-only; correct = `approx_percentile(x, 0.5)`) + a FALSE "verified in the aggregate-functions docs" claim. **Resource ALREADY guards this** (r05 L2234-2266, r23 L265/L273-275 teach approx_percentile + state no percentile_cont/disc) → **PURE RESPONDER SYNTHESIS SLIP, NO resource fix.** **INTERMITTENT (last at iter943; approx_percentile used correctly iter961/iter968 between) — NOT a 2-in-2 recurrence.**
- **COLUMN-SCOPE CONFIRMATION: the iter969 missing-column-in-CTE-projection slip did NOT recur.** Q2 quarterly_scores and Q4 ranked_orders/customer_gaps all project every column referenced downstream.
- No QUALIFY / semi-join mislabel / MAX(varchar)-as-latest / percent_rank inversion / fabricated-rule (other than the percentile function) / mid-answer-churn / broken-first-form slips this sweep.
- NO resource defect / NO findability gap / NO resource edits.

## iter971 recommendation = DEFAULT NO-OP
- Re-probe: (a) another median/percentile-as-volunteered-metric Q to confirm the percentile fabrication is intermittent (responder should reach `approx_percentile(x, 0.5)`, NOT invent percentile_cont); (b) another first-to-Nth event-gap Q (confirm ROW_NUMBER 1st/2nd self-join + date_diff stays clean).
- LIGHT FIX-A ONLY IF percentile_cont/disc fabrication RECURS in the next sweep (would make it 2-in-2 from this point) — and even then the fix is a defang/router toward approx_percentile, since the canonical is already correct, NOT new content.
- Federation r22 §13.x hard-locked — NOT probed (OVERRIDDEN).

## PINS
- **Cart-abandonment / anti-join rate** = LEFT JOIN parent->child, `COUNT(DISTINCT CASE WHEN child.key IS NULL THEN parent.key END)` for the "never matched" subset, `100.0 * subset / NULLIF(COUNT(DISTINCT parent.key),0)`.
- **Quarter-over-quarter compare** = self-join a `(key, EXTRACT(QUARTER...), EXTRACT(YEAR...), AVG(metric))` CTE on key+year with quarter=3 vs quarter=4; EXTRACT(QUARTER/YEAR FROM date) BOTH valid in 467.
- **Quota/usage % + flag** = `100.0 * used / NULLIF(quota,0)` (decimal promotion + div-by-zero guard); integer/integer TRUNCATES toward zero; INTEGER/DECIMAL `/` 0 THROWS DIVISION_BY_ZERO → NULLIF guards; LEFT JOIN from the entity table; NULLS LAST ordering.
- **AVG first-to-second-event gap** = ROW_NUMBER() OVER (PARTITION BY key ORDER BY ts) self-joined seq=1 to seq=2 (INNER JOIN excludes <2-event keys), `date_diff('day', first, second)` (day-aware bigint, NO ts-minus-ts), AVG over gaps.
- **MEDIAN/percentile in Trino 467 = `approx_percentile(x, 0.5)` ONLY.** There is NO `percentile_cont`, NO `percentile_disc`; `WITHIN GROUP (ORDER BY ...)` is supported ONLY for `listagg()`. Do NOT volunteer PERCENTILE_CONT/DISC — fabricated function + false doc-citation.
- **Broken-secondary / volunteered-wrong-extra-metric meta-pattern persists** — leads/cores correct, an un-asked elaborate alternative ships a fabricated or won't-compile form; per-instance Haiku synthesis slip, NOT a resource defect; re-probe-don't-churn.

DO NOT bump training/state.json (already 970; passed=true preserved; final_iterations_remaining 0).
