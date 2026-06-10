# Iter 935 Feedback — DEFAULT NO-OP durability sweep (teacher ZERO edits)

**Overall**: 4.985 STRONG PASS (Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 4.94 = 19.94/4 = 4.985; margin +1.485 over 3.5 threshold; OVERALL AVERAGE governs, no per-Q veto).

**Federation NOT probed** (4.49944/310 row UNCHANGED).

All dialect claims verified vs trino.io/docs/467 (functions/aggregate.html, functions/window.html, functions/datetime.html, functions/math.html) + Trino git-tag 467 source (MathFunctions.java) via WebFetch/WebSearch 2026-06-10 — NOT against resources/; iter882 verify-first applied BOTH directions.

---

## Per-question scores

### Q1 — count distinct payment methods per customer (3 credit_card + 1 paypal → 2)
**Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = 5.00 CLEAN**

`SELECT customer_id, COUNT(DISTINCT method) FROM payments GROUP BY customer_id` — canonical Trino 467.
- COUNT(DISTINCT x) single-arg with GROUP BY VALID (verified aggregate.html count + standing single-arg pin; multi-arg `COUNT(DISTINCT a,b)` is a parse error, but the question is single-column so not relevant).
- "DISTINCT dedups automatically, no extra work" — TRUE for the user (planner handles uniqueness); efficient framing accurate.
- Worked example (3 credit_card + 1 paypal → 2) correct.

### Q2 — each customer's SECOND-largest order value
**Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = 5.00 CLEAN**

Two-variant answer with subquery + outer WHERE — both dialect-correct.
- **DENSE_RANK semantics verified** (window.html): for [100,100,90,80] returns 1,1,2,3 — so DENSE_RANK rank=2 picks the second-highest DISTINCT value. Framing "second-highest DISTINCT value (ties at top share rank 1)" CORRECT.
- **ROW_NUMBER semantics verified**: 1,2,3,4 unique sequential — picks a single literal "2nd row"; deterministic tiebreaker via secondary ORDER BY (order_id) CORRECT.
- **RANK gap caveat verified ACCURATE**: window.html — "tie values in the ordering will produce gaps in the sequence" → for [100,100,90,80] RANK returns 1,1,3,4 → WHERE rank=2 returns ZERO rows. Responder's warning is exactly right and load-bearing.
- **Subquery wrapping**: REQUIRED in 467 because (a) window-fn alias not usable in same-level WHERE, (b) QUALIFY absent in 467. Responder DID wrap; CORRECT.
- Both framings (DENSE_RANK for distinct-value, ROW_NUMBER for literal row) make the trade-off explicit — strong pedagogy.

### Q3 — % of users with login in last 7 days (2M users, huge login table)
**Acc 5.0 / Comp 5.0 / Clar 5.0 / Act 5.0 = 5.00 CLEAN**

Two forms offered:
1. `WITH active_users AS (SELECT DISTINCT u.user_id FROM users u LEFT JOIN login_events e ON e.user_id=u.user_id AND e.event_time >= CURRENT_TIMESTAMP - INTERVAL '7' DAY WHERE e.user_id IS NOT NULL) SELECT ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM users), 2) FROM active_users`
2. Leaner: `ROUND(100.0 * COUNT(DISTINCT e.user_id) / (SELECT COUNT(*) FROM users), 2) FROM login_events e WHERE e.event_time >= CURRENT_TIMESTAMP - INTERVAL '7' DAY`

All facts VERIFIED:
- **INTERVAL '7' DAY**: DAY is a valid INTERVAL qualifier in 467 (types.html / SqlBase.g4 intervalField = YEAR|MONTH|DAY|HOUR|MINUTE|SECOND); subtraction `timestamp − interval` supported (datetime.html operator examples).
- **CURRENT_TIMESTAMP returns TIMESTAMP WITH TIME ZONE** (verified datetime.html: "Returns the current timestamp with time zone…").
- **TIMESTAMP → TIMESTAMP WITH TIME ZONE implicit coercion EXISTS in 467** (iter916 pinned fact, git-tag TypeCoercion.java) — so `e.event_time (plain TIMESTAMP) >= CURRENT_TIMESTAMP - INTERVAL '7' DAY (TIMESTAMP WITH TIME ZONE)` does NOT raise a type error; the comparison runs.
- **LEFT JOIN ... WHERE right.user_id IS NOT NULL = semi-join idiom**: valid; the move-filter-into-ON is what keeps the JOIN matching only recent events while the IS NOT NULL filters non-matchers. (Slight inefficiency vs `WHERE EXISTS` / `INNER JOIN` since LEFT JOIN preserves all users then filters — the leaner login_events-only form sidesteps this.)
- **DISTINCT dedup** correct (a user with multiple events counted once).
- **100.0 decimal-promo** correct (BIGINT/BIGINT would truncate; LEADING 100.0 forces decimal arithmetic before division — standing pin).
- **Partition pruning on event_time** callout accurate (bare-column on partition col is sargable).
- Both forms valid; the leaner form is correctly framed as the perf-conscious choice for "huge login table".

### Q4 — average rating rounded to nearest HALF-point (4.2→4.0, 4.4→4.5)
**Acc 5.0 / Comp 4.75 / Clar 5.0 / Act 5.0 = 4.94 CLEAN**

`SELECT product_id, ROUND(AVG(rating) * 2.0) / 2.0 AS rating_rounded_to_half FROM reviews GROUP BY product_id`

- **Round-to-nearest-half idiom arithmetically correct**: 4.2*2=8.4→ROUND=8→8/2.0=4.0 ✓; 4.4*2=8.8→ROUND=9→9/2.0=4.5 ✓; 3.75*2=7.5→ROUND=8→8/2.0=4.0 ✓ — all three worked examples land.
- **ROUND uses HALF_UP** verified vs git-tag 467 source `core/trino-main/src/main/java/io/trino/operator/scalar/MathFunctions.java`: single-arg `round(double)` delegates to `Math.round` (HALF_UP); decimal variants explicitly use `RoundingMode.HALF_UP`. Responder's "rounds half-up" claim is documentation/source verified, and the 3.75→4.0 example demonstrates it (7.5 rounds UP to 8 under HALF_UP).
- **ROUND signatures**: both `round(x)` (nearest integer) and `round(x, d)` (d decimal places) exist (math.html).
- **Pedagogical quibble (Comp 4.75)**: the "use 2.0 not 2 to avoid int truncation" warning is technically loose — AVG(rating) returns double regardless, and `double * integer` widens to double in Trino (no truncation at this step); the actual risk would only appear if BOTH operands of `/` were integers. So `2.0` is best practice for clarity but not load-bearing here. Harmless, slight over-caution; not a defect. Minor -0.25 on Comp for the technically-imprecise reason given, not for the practice itself.

---

## Critical-checks crosswalk (verified BOTH directions per iter882 verify-first)

| Claim | Direction | Verdict | Source |
|---|---|---|---|
| COUNT(DISTINCT col) single-arg + GROUP BY valid | suspicious-claim | CONFIRMED valid | aggregate.html, count single-arg pin |
| DENSE_RANK (1,1,2,3) / RANK gap (1,1,3,4) / ROW_NUMBER (1,2,3,4) | suspicious-claim | CONFIRMED verbatim | window.html quoted descriptions |
| Window-alias NOT usable in same-level WHERE (needs subquery); QUALIFY absent in 467 | "that's wrong" instinct | CONFIRMED responder's subquery is required | standing pin (QUALIFY absent in 467) |
| INTERVAL '7' DAY valid; CURRENT_TIMESTAMP − INTERVAL works | suspicious-claim | CONFIRMED valid | datetime.html operator examples, types.html intervalField |
| TIMESTAMP → TIMESTAMP WITH TIME ZONE implicit coercion EXISTS in 467 | "that's wrong" instinct check | CONFIRMED (iter916 pin, git-tag TypeCoercion.java) — comparison does NOT error | standing pin |
| LEFT JOIN/IS NULL semi-join + DISTINCT dedup + 100.0 decimal-promo | suspicious-claim | CONFIRMED all valid | standing pins |
| ROUND(x*2.0)/2.0 round-to-nearest-half arithmetically correct | suspicious-claim | CONFIRMED for all 3 worked examples | math.html + worked verification |
| ROUND single-arg rounds HALF_UP | suspicious-claim | CONFIRMED via git-tag MathFunctions.java (Math.round + RoundingMode.HALF_UP) | source + standing CAST-to-int HALF_UP pin |
| ROUND(x) and ROUND(x,d) both exist | suspicious-claim | CONFIRMED | math.html |
| "*2 not *2.0 would truncate" warning | "that's wrong" instinct check | TECHNICALLY LOOSE (double*int widens to double) — harmless over-caution NOT defect | math.html implicit widening |

---

## Scope tags

- **NO RESOURCE DEFECT** — no resource taught anything wrong.
- **NO RESPONDER SLIP on taught content** — every dialect claim verified accurate; subquery-wrap correctly applied (no QUALIFY in 467); RANK-gap warning load-bearing and right; HALF_UP rounding source-confirmed.
- **NO FINDABLE GAP** — Q4 "*2.0 avoids int truncation" is a minor pedagogical looseness, NOT a missing card / NOT a dialect defect / NOT load-bearing for correctness (worked examples all land regardless). Resources teach 100.0 decimal-promo + ROUND idioms extensively; adding a "double widens through int" card would risk New-Card-Over-Attracts-Adjacent regression for zero correctness gain.

---

## Iter 936 directive

**iter936 = DEFAULT NO-OP / durability-breadth**. Teacher ZERO edits warranted.

- All 4 dialect-clean; QUARTER/WEEK INTERVAL family (iter933 ADD-A-QUARTER card) NOT touched this iter, continues cool-down per New-Card-Over-Attracts-Adjacent lesson (skipped 2 sweeps now).
- Optional low-priority re-probes (SKIP if duplicative):
  - **Top-K-per-group (K>2)** variants: "third-highest order" / "top 5 per category" to keep DENSE_RANK vs ROW_NUMBER distinction durable.
  - **Last-N-days percent active** variants with explicit CAST(event_time AS TIMESTAMP WITH TIME ZONE) — confirm responder doesn't add an UNNECESSARY CAST (iter916 coercion-exists pin).
  - **Round-to-arbitrary-step**: round-to-nearest-0.25 (ROUND(x*4)/4) or round-to-nearest-5 (ROUND(x/5)*5) — confirm responder generalizes the *N/divide-by-N idiom.
  - **COUNT(DISTINCT ROW(a,b))** distinct-combinations re-probe (iter925 slip arc).
- Federation (4.49944/310) only un-passed row — bulletproofed angles only.
- PRESERVE full iter534-934 pin inventory.
- PIN 467.
- NO federation edits.
- **DO NOT bump training/state.json** (already 935; passed=true preserved; overall 4.985 STRONG PASS holds).

PRESERVED PINS (TOUCHED THIS ITER, all confirmed): COUNT(DISTINCT x) single-arg; DENSE_RANK/RANK/ROW_NUMBER semantics + RANK-gap-zero-rows; QUALIFY absent in 467 (subquery required); INTERVAL qualifiers = YMD-HMS only (DAY valid); CURRENT_TIMESTAMP = TIMESTAMP WITH TIME ZONE; TIMESTAMP→TIMESTAMP WITH TIME ZONE coercion EXISTS in 467; LEFT JOIN/IS NULL semi-join idiom; 100.0 decimal-promo avoids integer-division truncation; ROUND single-arg + ROUND(x,d) HALF_UP rounding (git-tag MathFunctions.java).
