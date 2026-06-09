# Judge Feedback — Iter 846 (EXTENDED PHASE)

**Overall: 4.4375 / 5.00 — PASS** (per-Q 5.00 / 5.00 / 2.75 / 5.00 = 17.75/4; margin +0.9375; overall avg governs, no per-Q veto)

Federation NOT probed (row stays 4.49944/310, still FAIL). Teacher made ZERO edits this iteration (DEFAULT NO-OP durability sweep).

All dialect claims verified against trino.io/docs/467 (math/array/conversion/sql-select) plus WebSearch on division-by-zero behavior, 2026-06-09.

---

## Per-question scores

### Q1 — alias-in-WHERE RE-PROBE — 5.00 (Acc5 / Comp5 / Clar5 / Act5)
`final_price` computed in SELECT, `WHERE final_price > 100` errors "column does not exist".

Responder CORRECTLY:
- Explained WHERE is evaluated BEFORE the SELECT projection, so the alias is not yet computed / does not exist when WHERE runs.
- Marked `WHERE final_price > 100` with ❌ (did NOT reproduce the anti-pattern as runnable copy-bait).
- Gave the CTE fix and filtered the outer query.
- Correctly noted the alias IS allowed in ORDER BY (runs after projection) but NOT in WHERE/GROUP BY/HAVING.

Verified vs sql/select.html eval-order semantics. Clean.

### Q2 — array set ops on two ARRAY columns, one row — 5.00 (Acc5 / Comp5 / Clar5 / Act5)
- `array_intersect(prev,curr)` = overlap, `array_except(curr,prev)` = new, `array_except(prev,curr)` = lost.
- Correctly stated these operate within one row, no UNNEST needed.
- Correctly distinguished from row-level INTERSECT/EXCEPT/UNION operators (which compare two queries).

Verified vs array.html: all three functions exist, each takes two arrays and returns an array (dedup'd). Mapping correct. Clean.

### Q3 — NaN/Infinity cause + detection — 2.75 (Acc2 / Comp3 / Clar4 / Act2)
**REAL ACCURACY DEFECT on the load-bearing claim.**

Correct parts:
- `is_nan(x)`, `is_infinite(x)`, `is_finite(x)` all exist with correct semantics (verified math.html).
- INTEGER/DECIMAL division by zero FAILS the query — correct.
- NaN/Infinity only come from floating-point types — correct.

WRONG parts (the central CAUSE the question asked about):
- "DOUBLE division by zero SUCCEEDS but produces bad values ... returns Infinity (not error)" — **FALSE**. Trino 467 throws `DIVISION_BY_ZERO` for DOUBLE/REAL `/ 0` as well; it does NOT follow IEEE-754. Verified via WebSearch: scientific-notation literals are DOUBLE, and `1.0e0 / 0.0e0` errors rather than returning Infinity. This matches `DoubleOperators.divide` throwing `DIVISION_BY_ZERO`.
- Therefore `CAST(msgs AS double) / sessions` where `sessions = 0` ERRORS — it does NOT return Infinity.
- "`0e0 / 0e0` returns NaN" — **FALSE**, that errors too.
- The summarizing rule "int/decimal → guard BEFORE with NULLIF; double → detect AFTER with is_finite" is **MISLEADING**: double-div-by-zero must ALSO be guarded BEFORE with `NULLIF(denom, 0)`. Detection AFTER does not help because the query has already failed.

The detection functions are valid and NaN/Infinity DO genuinely arise — but from `nan()`, `infinity()`, overflow casts, `sqrt(-1)`, infinity arithmetic, etc. — NOT from double division by zero. The answer mis-attributed the cause.

Root note: this incorrect framing traces back to the resource itself (r23 §4.4H). The iter739/iter740 score-history entries encoded "double/real div-by-zero → inf/nan, detect AFTER" — that resource content is itself docs-wrong. The responder faithfully reproduced a wrong resource. It is still an accuracy defect in the answer, AND it is a resource defect that needs fixing.

### Q4 — graceful cast of messy string — 5.00 (Acc5 / Comp5 / Clar5 / Act5)
- `TRY_CAST(raw_score AS INTEGER)` returns NULL on failure (vs CAST erroring) — correct.
- `COALESCE(TRY_CAST(...), 0)` to default bad rows — correct.
- Postgres-style `expr::type` does not work in Trino — correct.

Verified vs conversion.html (`try_cast` = "Like cast(), but returns null if the cast fails"). Durability re-probe of bulletproofed TRY_CAST — clean.

---

## Key verdicts

**(a) Q1 alias-in-WHERE — CONFIRMED ONE-OFF.** The iter845 Q2 alias-in-WHERE issue was a responder slip, not a durable findability gap. The re-probe from a fresh (price/discount) angle was handled perfectly. Rule is durable and findable (r27 §4.2). NO FIX-A needed for alias-in-WHERE.

**(b) Q3 double-div-by-zero-returns-Infinity — DEFECT (docs-WRONG).** Trino 467 throws `DIVISION_BY_ZERO` for DOUBLE/REAL division by zero just like integer/decimal; it does NOT return Infinity/NaN. The responder's claim is factually incorrect on the load-bearing point, and it originates from incorrect resource content in r23 §4.4H.

---

## iter847 directive — FIX-A (a real defect surfaced)

Not a NO-OP this iteration. Reconcile the r23 §4.4H float-state card IN PLACE:

1. CORRECT the "double/real div-by-zero returns Infinity/NaN, detect AFTER" framing. The truth: **Trino 467 throws `DIVISION_BY_ZERO` for ALL numeric types including DOUBLE/REAL** — guard division-by-zero BEFORE with `NULLIF(denom, 0)` regardless of operand type. Trino does NOT follow IEEE-754 for the `/` operator.
2. DEFANG the "double division by zero returns Infinity (not an error)" claim on its own un-copyable line (do not leave it as copy-bait — see the defang-DO-NOT-WRITE memory lesson).
3. KEEP the (correct) `is_nan`/`is_infinite`/`is_finite` detection canonical, but RE-ANCHOR it to the REAL causes of NaN/Infinity: `nan()`, `infinity()`, overflow CASTs (e.g. casting an out-of-range or 'Infinity' string to double), `sqrt(-1)`, and infinity arithmetic — NOT double-division-by-zero.
4. VERIFY against trino.io/docs/467 (math.html + a direct div-by-zero check) BEFORE writing. PIN Trino 467.

Do NOT churn the Q1 alias-in-WHERE content (r27 §4.2, durable), the Q2 array set-ops card, or the Q4 try_cast card. Reconcile-don't-append: fix the stale §4.4H framing in place rather than adding a contradicting block.

HOLD all iter534-845 locks. Federation r22 untouched (row stays 4.49944/310, still FAIL). DO NOT bump training/state.json (already 846).
