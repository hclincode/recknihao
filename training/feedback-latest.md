# iter948 — Judge Feedback

**Date**: 2026-06-10
**Phase**: EXTENDED
**Sweep type**: LIGHT FIX-A verification + 2 targeted re-probes (Q1 cohort shape, Q2 HAVING-perf folklore)
**Verdict**: **PASS** — overall avg **3.71875** (margin +0.21875 over 3.5 threshold)

---

## Per-question scores

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | new vs returning DISTINCT customers per month (multi-order schema; iter947 Q3 RE-PROBE) | 4.5 | 4.0 | 4.0 | 4.0 | **4.125** |
| Q2 | HAVING vs WHERE for high-cardinality GROUP BY memory (iter941 + iter946 RE-PROBE; 3rd direct framing) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q3 | AVG discount per campaign (skip NULL / zero discounts) | 4.0 | 3.5 | 4.0 | 4.0 | **3.875** |
| Q4 | products whose price ENDS IN .99 (price-suffix matching) | 2.0 | 2.5 | 2.5 | 2.0 | **2.25** |

**Sum**: 4.125 + 5.00 + 3.875 + 2.25 = **15.25** / 4 = **3.71875 PASS**

---

## TEACHER FIX-A VERDICT — CORRECT, no corruption

**r07 L37 reworded in place**, verified verbatim:

> "What to watch for: if `GROUP BY` has high cardinality (e.g., `GROUP BY user_id` across 50M users), the engine has to keep all distinct groups in memory. To actually cut that memory you must reduce the INPUT rows that reach the aggregation — add a `WHERE` filter on a partition/filter column so fewer rows are read, or pre-aggregate in stages (e.g. a daily rollup table). A `HAVING COUNT(*) > N` does **not** help here: HAVING runs *after* all groups are built, so it only trims the OUTPUT rows, not the in-memory group set the engine had to construct."

**Dialect verification (BOTH directions)**:
- Verified via WebFetch trino.io/docs/467/sql/select.html: HAVING semantics confirmed verbatim — "HAVING filters groups after groups and aggregates are computed" + "eliminates groups that do not satisfy the given conditions." HAVING evaluates AFTER the hash-aggregation build phase, so the per-group working set is already in memory. HAVING only filters OUTPUT rows, NOT the build-side hash table. The corrected text is dialect-accurate.
- WHERE-pre-filter + pre-aggregation as memory remedies = correct per the same docs (WHERE evaluated before grouping).
- NOT a manufactured restriction — this CORRECTS a previously-wrong perf claim ("Add a HAVING COUNT(*) > N to trim" implied HAVING shrinks the grouping memory, which it does not).

**Adjacent content intact** (verified L15-39):
- L33-35 columnar/Iceberg-pruning bullets UNTOUCHED
- L39 date-filter section header + L41 keyword anchor UNTOUCHED
- L25-31 the leading SQL example UNTOUCHED
- No new card created (avoids defang-DO-NOT-WRITE backfire + New-Card-over-attracts-adjacent)

**FIX-A VERDICT = CORRECT & CLEAN**.

---

## Q1 RE-PROBE VERDICT — iter947 entity-vs-row shape slip = ONE-OFF / DID NOT RECUR

The responder this iteration used the CORRECT cohort-dedup shape:
- `first_order` CTE: `SELECT customer_id, DATE_TRUNC('month', MIN(order_date)) AS first_month FROM orders GROUP BY customer_id` — produces ONE ROW PER CUSTOMER (entity dedup via MIN aggregation).
- `new_customers` CTE: `SELECT first_month AS month, COUNT(*) AS new_customers FROM first_order GROUP BY first_month` — because first_order has one row per customer, `COUNT(*)` correctly counts CUSTOMERS not order rows.
- `returning_customers`: correlated subquery `COUNT(DISTINCT o.customer_id) FROM orders o JOIN first_order f ON o.customer_id=f.customer_id WHERE DATE_TRUNC('month', o.order_date) = new_customers.month AND f.first_month < new_customers.month` — explicit COUNT(DISTINCT customer_id) entity dedup.

**Cohort semantics correct**: a customer's first month → counted as new (only). Later month with another order → counted as returning. No double-count of the first month.

**Trino 467 dialect validity**:
- DATE_TRUNC('month', x) returns first-of-month INCLUDING year (verified prior iters)
- MIN(order_date) GROUP BY customer_id valid
- Scalar correlated subquery in SELECT — verified trino.io/docs/467/sql/select.html notes "Support for correlated subqueries is limited. Not every standard form is supported" but the scalar-subquery-correlated-to-outer-CTE-row form here IS supported (the correlation references a column of the outer SELECT, the inner returns a single scalar via COUNT — standard supported shape).
- COUNT(DISTINCT customer_id) single-arg valid (pin honored).

**Minor dings** (Acc 4.5, others 4.0): correlated-subquery-in-SELECT is less performant than a single JOIN/UNION ALL or `COUNT(DISTINCT) FILTER (WHERE)` approach; for very large `orders` Trino may not push down the correlation efficiently. A cleaner alternative would be `COUNT(DISTINCT customer_id) FILTER (WHERE first_month = order_month)` / `FILTER (WHERE first_month < order_month)` over a single JOIN. Responder didn't show the more performant variant, but the answer is CORRECT.

**RE-PROBE VERDICT**: iter947 Q3 entity-vs-row shape slip CONFIRMED ONE-OFF / DID NOT RECUR. The findable-gap canonical the iter947 feedback recommended (cohort-dedup card) was NOT actioned this iteration (teacher chose to ship only the LIGHT FIX-A r07 L37 reword), yet the responder still produced the correct shape — suggesting the prior iter947 slip was a one-off synthesis miss, not a persistent findable gap. NO escalation needed.

---

## Q2 RE-PROBE VERDICT — HAVING-trims-memory folklore = CLOSED (3rd direct framing came back CLEAN)

Responder explicitly REJECTED the teammate's premise:
> "Your teammate's suggestion is backwards. The memory problem happens BEFORE the HAVING filter runs, not after."

Then walked through execution order:
> "GROUP BY creates all groups in memory (millions of payment_id groups exhaust RAM), HAVING filters which to keep (too late to save memory). Adding the filter won't reduce memory — Trino will still allocate memory for all groups, then discard most."

Prescribed CORRECT remedies:
- WHERE filter BEFORE GROUP BY on a partition column
- partitioning / approx_distinct
- pre-aggregate in dbt

**This is the EXACT framing the reworded r07 L37 teaches.** The FIX-A landed and the responder is now anchored on the correct mental model on a direct, head-on probe.

**Folklore tally**: iter941 Q1 (SLIP #1) → iter946 Q4 secondary aside (SLIP #2) → iter947 Q1 HAVING-perf MONITOR (CLEAN) → **iter948 Q2 (CLEAN, post-FIX-A)**. The 3rd direct framing came back clean WITH the resource fix in place. **FOLKLORE CLOSED**. No further FIX-A needed; the latent source (r07 L37) has been neutralized.

---

## Q3 — solid but not perfect (3.875)

AVG ignores NULL natively (verified aggregate.html — "avg() does not include null values in the count") is correctly stated. The three options framework (keep zeros / exclude both / COALESCE-wrap with > 0 filter) covers the policy spectrum reasonably. Minor gaps:
- No mention of the obvious `AVG(discount_amount) FILTER (WHERE discount_amount > 0) GROUP BY campaign_id` single-pass form — more idiomatic than option C's COALESCE wrap.
- Option C `COALESCE(AVG(...),0) WHERE discount_amount > 0` will never return NULL if any row matches the WHERE so the COALESCE only fires when the campaign has zero matching rows; this is a subtle edge case worth a one-liner.
- Could have noted GROUP BY campaign_id explicitly in each option.

Not a defect, just a slightly incomplete menu. PASS comfortably.

---

## Q4 — MENU WITH BROKEN ALTERNATIVES — significant defect (2.25)

The responder gave a 4-option menu for "find products whose price ends in .99". Verifying each option BOTH directions against trino.io/docs/467/functions/math.html and functions/regexp.html:

### Option A: `WHERE price - FLOOR(price) = 0.99`
- For **DECIMAL** price: exact decimal arithmetic — works correctly. Recommendable.
- For **DOUBLE/REAL** price: IEEE-754 float — 149.99 is NOT exactly representable. `149.99 - 149.0` in floating point yields something like 0.9899999999999949, NOT exactly 0.99. The equality `= 0.99` will FAIL.
- **DEFECT**: responder recommends A for "DECIMAL/DOUBLE" — the DOUBLE recommendation is WRONG (float-equality fragility unmentioned). Should have warned: "only safe for DECIMAL; for DOUBLE use ABS(price - FLOOR(price) - 0.99) < 1e-9 or cast to DECIMAL first."

### Option B: `WHERE ROUND(price, 2) = CAST(ROUND(price, 0) AS DECIMAL) + 0.99`
- ROUND in Trino uses HALF-UP rounding (standard rounding-to-nearest). `ROUND(149.99, 0)` = **150** (because .99 rounds UP to next integer), NOT 149.
- Therefore `CAST(ROUND(149.99, 0) AS DECIMAL) + 0.99` = `150 + 0.99` = **150.99**.
- And `ROUND(149.99, 2)` = `149.99`.
- `149.99 = 150.99` is **FALSE** for the exact prices the predicate is supposed to MATCH.
- **DEFECT**: Option B is LOGICALLY BROKEN. It FILTERS OUT every .99 price (the inverse of what's requested). Should have used `FLOOR(price)` not `ROUND(price, 0)`.

### Option C: `WHERE price CAST(price AS VARCHAR) LIKE '%.99' OR CAST(price AS VARCHAR) LIKE '%.99%'`
- `price CAST(price AS VARCHAR)` is a SYNTAX ERROR — stray bare-`price` token before CAST has no operator and no comma. Trino will fail to parse.
- Even if the syntax error is fixed: `LIKE '%.99%'` over-matches — it would match "1.9999" (contains ".99"), "21.995" (contains ".99"), etc. The trailing `%` defeats the suffix-match intent.
- `LIKE '%.99'` alone would be the correct suffix match; the OR with `'%.99%'` defeats it.
- **DEFECT**: Option C is BROKEN (syntax error + over-match).

### Option D: `WHERE regexp_like(CAST(price AS VARCHAR), '\.99$')`
- Anchored end-of-string match works (verified regexp.html: "anchoring the pattern using `^` and `$`"); `\.` matches literal dot.
- For **DECIMAL(_,2)** price: CAST→VARCHAR yields "149.99" reliably → regex matches → correct.
- For **DOUBLE/REAL** price: CAST(double AS VARCHAR) representation can show "149.99" or rare scientific notation for very large/small values — mostly OK, edge cases possible.
- Minor concern: Trino regex string literals canonically use DOUBLE backslash per reference_trino_regex_backslash memory pin; `'\.99$'` may parse as a single `.` (since `\.` in a SQL string often passes through, but Trino's preferred form is `'\\.99$'`). Either form produces a regex pattern of `\.99$` which is correct semantically. Not a hard defect.
- **REASONABLE for DECIMAL; OK-ish for DOUBLE.**

### Q4 menu defect scoping
- **Option A**: correct-for-DECIMAL, mis-recommended for DOUBLE (no float-equality warning).
- **Option B**: LOGICALLY BROKEN — ROUND-up bug; filters OUT the exact prices it should match.
- **Option C**: SYNTAX ERROR + over-match — would not even parse.
- **Option D**: OK-for-DECIMAL, OK-ish for DOUBLE — reasonable.

A reader scanning the menu and copying B or C would ship broken code. Even copying A on DOUBLE would silently return empty results. Only D (and A on DECIMAL) work reliably. Scoring substantially down: Acc 2.0 (two LOGICALLY BROKEN options + one float-fragility miss), Comp 2.5 (4 options but 2 are wrong, missing simpler `MOD(CAST(price * 100 AS BIGINT), 100) = 99` idiom which is the cleanest for DECIMAL), Clar 2.5 (menu format encourages copying any option without understanding which actually works), Act 2.0 (copying B or C = broken query; A on DOUBLE = silent empty results).

**Q4 disposition**: RESPONDER SLIP — the menu format produced two broken alternatives (B logically broken, C syntax error) that the resources almost certainly do not teach as canonical price-suffix matching forms. Probable findable-gap interaction: resources/23 §3.1C and resources/27 (cited by responder) likely teach modulo / regex idioms in passing but lack a leading FINDABLE canonical for "price ends in .99" / "fractional-part matching" / "price-point detection." Without a strong findable canonical, the responder synthesized options from generic ROUND/CAST/LIKE primitives and produced broken ones.

**RECOMMENDATION for iter949**:
- **Light FIX-A consideration**: add a small canonical card for "find rows where a DECIMAL value ends in a specific fractional part / price-point matching" with the leading idiom `WHERE MOD(CAST(price * 100 AS BIGINT), 100) = 99` (exact for DECIMAL/integer-cents) + secondary `WHERE regexp_like(CAST(price AS VARCHAR), '\.99$')` (DECIMAL safe) + explicit WRONG-mark on `ROUND(price, 0) + 0.99` (rounds UP, breaks for .99) + explicit WRONG-mark on float-equality `price - FLOOR(price) = 0.99` for DOUBLE.
- **Re-probe Q4 next sweep** with a fresh price-suffix/fractional-part question to confirm whether the slip is a one-off synthesis miss (no FIX-A needed) or persistent (FIX-A justified). If 1st-instance, prefer RE-PROBE-DON'T-CHURN given the dense ROUND/FLOOR/regex neighborhood and New-Card-over-attracts-adjacent risk.
- DO NOT touch the Q1/Q2 areas (both clean this iter).

---

## Defect scoping summary

| Item | Verdict |
|---|---|
| Teacher FIX-A r07 L37 reword | CORRECT — dialect-verified, adjacent content intact, NOT a manufactured restriction |
| Q1 cohort shape (iter947 RE-PROBE) | SLIP CLOSED — one-off, DID NOT RECUR |
| Q2 HAVING-trims-memory folklore (3rd direct framing) | CLOSED — FIX-A landed, responder explicitly rejects the folklore on direct probe |
| Q3 AVG discount | minor completeness gaps, no defect |
| Q4 price-ends-in-.99 menu | RESPONDER SLIP (1st instance) — Option B logically broken (ROUND-up bug), Option C syntax error + over-match, Option A mis-recommended for DOUBLE; possible findable-gap interaction |

**Federation row (4.49944/310)**: NOT probed this sweep. UNCHANGED.

---

## iter949 recommendation

**DEFAULT NO-OP / RE-PROBE-DON'T-CHURN** for Q4 (1st-instance synthesis slip; dense ROUND/FLOOR/regex neighborhood makes a new card risky for adjacent regressions). Re-probe with a fresh price-suffix or fractional-part question; if defect recurs, escalate to LIGHT FIX-A canonical card per recommendation above.

**Lock all current FIX-A**: r07 L37 reword has landed correctly and the HAVING-trims-memory folklore is closed at 3rd direct framing. PRESERVE the iter534-948 pin inventory; NO federation edits, NO percentile-card edits, NO PARTITIONED-BY defang card, NO new HAVING-perf defang card, NO new cohort-dedup card (iter947 recommendation deprecated — Q1 RE-PROBE CLEAN shows responder doesn't need it).

**Pins reinforced this iter**:
- HAVING runs AFTER aggregation per select.html — does NOT reduce GROUP BY working-set memory; memory reduction = WHERE pre-filter OR staged pre-aggregation. **iter948 LIGHT FIX-A r07 L37 reword CONFIRMED holding on 3rd direct framing.**
- Cohort dedup: one-row-per-customer via `MIN(order_date) GROUP BY customer_id` + COUNT(*) on the dedup CTE counts CUSTOMERS not orders; `COUNT(DISTINCT customer_id)` in correlated subquery / `FILTER (WHERE ...)` for the returning split. iter947 slip ONE-OFF.
- ROUND(double/decimal, 0) is half-up to nearest integer (ROUND(149.99, 0) = 150); for "round-toward-zero" use TRUNCATE(x); for floor use FLOOR(x). Don't substitute ROUND for FLOOR in fractional-part extraction.
- float-equality on DOUBLE is fragile (149.99 not exactly representable); CAST-to-DECIMAL or integer-cents arithmetic for exact matches.
- LIKE '%.99' is suffix match; '%.99%' is over-broad (matches any substring containing ".99").
- regexp_like(s, '\.99$') anchored-end match; `\.` matches literal dot; regex backslash via Trino docs uses '\\' (double-backslash) canonical though `'\.'` often passes through.
- Scalar correlated subquery in SELECT list valid in Trino 467 for the standard outer-row-referencing shape; perf consideration only.

PIN 467. DO NOT bump training/state.json (already 948; passed=true preserved; overall 3.71875 PASS holds).
