# iter949 Feedback — RE-PROBE sweep (ZERO teacher edits)

**Date**: 2026-06-10
**Phase**: EXTENDED
**Sweep type**: RE-PROBE sweep of iter948 Q4 broken-options-menu slip (price-suffix); teacher made ZERO resource edits

**Overall: 4.875 STRONG PASS** (margin +1.375 over 3.5 threshold)
Per-Q: Q1 4.75 / Q2 4.875 / Q3 4.875 / Q4 5.00 = 19.5 / 4 = 4.875

Dialect verified vs trino.io/docs/467 (functions/math.html, functions/decimal.html, functions/aggregate.html, sql/select.html) + WebSearch + WebFetch 2026-06-10 — NOT against resources/. iter882 verify-BOTH-directions discipline.

---

## Q1 RE-PROBE VERDICT — PRICE-SUFFIX BROKEN-OPTIONS-MENU SLIP = ONE-OFF / SLIP CLOSED

**iter948 Q4 broken-options-menu slip DID NOT RECUR.** Responder LED CLEAN with the single robust form:

`SELECT product_id, price FROM products WHERE mod(price * 100, 100) = 99`

VERIFIED CORRECT:
- mod() supports DECIMAL natively per Trino 467 functions/decimal.html (`x % y` row in DECIMAL operator table) and functions/math.html (`mod(decimal(ap,as), decimal(bp,bs)) → decimal(rp,rs)` signature).
- For DECIMAL price 19.99: `19.99 * 100 = 1999.00` (exact decimal multiplication, scale = xs+ys), `mod(1999.00, 100) = 99.00`, `= 99` → true.
- For 30.00: `mod(3000.00, 100) = 0` → false. For 149.95: `mod(14995.00, 100) = 95` → false. Only `.99` suffix matches.
- No explicit `CAST(... AS BIGINT)` needed for DECIMAL — decimal mod is exact and well-defined per docs.
- `a % b` alternative form correctly noted; both forms documented in 467.

Cast-to-string rejection rationale SOUND: VARCHAR cast formatting non-deterministic (trailing zeros), regex/LIKE slower than arithmetic, no index-on-cast benefit.

**NO ROUND(price, 0) + 0.99 broken option, no syntax-error LIKE chain, no menu of broken alternatives.** The iter948 Q4 menu-with-broken-alternatives slip is CONFIRMED a 1st-instance ONE-OFF and SLIP CLOSED.

Q1 scores: Acc 5 / Comp 4.5 / Clar 4.5 / Act 5 = **4.75** (minor ding: could have shown integer-cents BIGINT cast variant + regexp_like backup, but lead form is the cleanest and dialect-correct).

### DISPOSITION — NO FIX-A (verified-clean one-off despite topic absence)

The iter949 teacher state.json confirms the price-suffix/charm-pricing/fractional-part canonical is ABSENT from all resources. Normally an absent topic + slip = FINDABLE GAP requiring FIX-A. BUT Q1 LED CLEAN here — the responder synthesized the correct robust form (`mod(price*100, 100) = 99`) from general Trino math primitives despite having NO topic-specific canonical to anchor on.

**Decision: NO FIX-A. Do NOT add a price-suffix canonical card.**

Rationale:
1. Verified-clean 1st-instance one-off — RE-PROBE-DON'T-CHURN doctrine applies.
2. Adding a price-suffix card in a dense MOD/ROUND/FLOOR/regex neighborhood risks the New-Card-over-attracts-adjacent regression pattern (memory `feedback_new_card_over_attracts_adjacent.md`) — could pull adjacent "fractional cents", "round-to-dollar", "currency formatting" Qs to the wrong canonical.
3. Defang-DO-NOT-WRITE backfire risk on the broken ROUND-up-then-add form (memory `feedback_defang_donotwrite_snippets.md`).
4. Responder demonstrated synthesis capability — adding a card might constrain future-correct synthesis without providing marginal value.

Threshold for escalation: 2+ further price-suffix recurrences within next ~5 sweeps without intervening clean answer → THEN escalate to LIGHT FIX-A.

---

## Q2 — Scalar subquery overall AVG = CLEAN

Form: `WHERE order_total > (SELECT AVG(order_total) FROM orders) ORDER BY order_total DESC`

VERIFIED valid 467 (sql/select.html scalar subquery section: "A scalar subquery is a non-correlated subquery that returns zero or one row"; example `SELECT name FROM nation WHERE regionkey = (SELECT max(regionkey) FROM region)` mirrors the shape). Decorrelation/once-execution claim accurate — Trino's optimizer materializes the scalar value once, not per-row. AVG ignores NULL natively per aggregate.html.

Q2 scores: Acc 5 / Comp 4.5 / Clar 5 / Act 5 = **4.875** (minor ding: could have noted `>= AVG()` vs `> AVG()` boundary semantics, but the lead form is canonical).

---

## Q3 — AVG quantity per line whole-table = CLEAN

Form: `SELECT AVG(quantity) AS avg_qty_per_line FROM order_items` (+ optional `COUNT(*)` context variant).

VERIFIED valid 467 — scalar aggregate without GROUP BY returns a single-row whole-table average. AVG ignores NULL natively per aggregate.html quote: "Except for count(), count_if(), max_by(), min_by() and approx_distinct(), all of these aggregate functions ignore null values and return null for no input rows or when all values are null." Plus the avg()-specific line "avg() does not include null values in the count."

No-GROUP-BY-needed reasoning correct (whole-table single scalar; GROUP BY only required when partitioning into groups).

Q3 scores: Acc 5 / Comp 4.5 / Clar 5 / Act 5 = **4.875** (minor ding: could have noted NULL-vs-zero policy choice for completeness, but the question asks for the straight per-line average and the answer is correct).

---

## Q4 — GROUP BY + HAVING COUNT(*) >= 50 = CLEAN (correct HAVING-on-aggregate usage)

Form: `SELECT shipping_method, COUNT(*) AS order_count FROM orders GROUP BY shipping_method HAVING COUNT(*) >= 50 ORDER BY order_count DESC`

VERIFIED valid 467 — HAVING on aggregate predicate is its CANONICAL use (filtering on aggregate result; cannot use WHERE because WHERE runs before aggregation). ORDER BY can reference SELECT alias per sql/select.html.

**CRITICAL CHECK PASSED: Responder did NOT repeat the "HAVING trims memory" folklore.** This is legitimate HAVING-on-aggregate usage (filtering output groups by a count threshold), NOT the misapplied "HAVING reduces grouping memory" claim. The pedagogy correctly framed WHERE-before-grouping (row filter) vs HAVING-after-aggregation (group filter on aggregate value). r07 L37 reconciled framing (iter948 LIGHT FIX-A) HOLDS — folklore stays at 2 historical instances (iter941 Q1 + iter946 Q4 secondary), zero new recurrences.

Q4 scores: Acc 5 / Comp 5 / Clar 5 / Act 5 = **5.00**.

---

## SCOPE / DECISIONS

- **NO RESOURCE DEFECT** detected.
- **NO RESPONDER SLIP** detected. Q1 broken-options-menu confirmed one-off; Q2/Q3/Q4 textbook clean.
- **NO FINDABLE GAP** requiring action (price-suffix absent topic synthesized correctly = no card needed).
- **NO FIX-A.** Teacher should remain ZERO-edit / NO-OP for iter950.
- **NO federation probe** per standing constraint (resources/22 §13.x hard-locked).

## RE-PROBE PLAN for iter950

- Continue rotating fresh angles on the still-locked-but-monitored families: HAVING-perf folklore (3rd direct framing CLEAN at iter948 Q2; one more clean answer locks it), price-suffix synthesis (1 clean answer here; 1-2 more clean answers solidify the one-off conclusion).
- Probe dense neighborhoods that share lexical surface with the price-suffix canonical (fractional-part matching, round-to-dollar, currency formatting) to verify NO adjacent regression from synthesis pathway.
- Continue avoiding federation-probe variations outside the bulletproofed angles.

## PINS REINFORCED

- `mod(decimal, decimal) → decimal` valid 467; `%` operator valid on DECIMAL per functions/decimal.html operator table.
- For DECIMAL price: `mod(price * 100, 100) = 99` is exact and clean (no CAST needed); for DOUBLE/REAL: integer-cents via CAST is safer.
- Scalar subquery in WHERE valid + decorrelated (runs once per query, not per row).
- AVG ignores NULL natively (no GROUP BY needed for whole-table scalar).
- GROUP BY + HAVING COUNT(*) >= N is CANONICAL HAVING-on-aggregate usage (NOT the same as the "HAVING trims memory" folklore — that one specifically claims HAVING reduces aggregation working-set memory, which it does not).
- ORDER BY can reference SELECT alias.
- ROUND(x, 0) half-up to nearest (ROUND(149.99, 0) = 150) — do NOT use ROUND-to-dollar + 0.99 for suffix matching.
- HAVING runs after aggregation per sql/select.html.
- r07 L37 reconciled framing HOLDS (iter948 LIGHT FIX-A confirmed durable on iter948 Q2 + iter949 Q4 indirect surface).
- Federation row 4.49944/310 UNCHANGED; bulletproofed angles only.

PIN 467. PRESERVE full iter534-948 pin inventory. NO federation edits, NO percentile-card edits, NO PARTITIONED-BY defang card, NO INTERVAL-qualifier edits, NO HAVING-perf defang card, NO price-suffix canonical card (verified-clean one-off).

DO NOT bump training/state.json (orchestrator handles that).
