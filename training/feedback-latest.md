# iter765 Judge Feedback — DEFAULT durability-breadth (4 fresh picks)

**Overall: 5.00 — STRONG PASS** (threshold 3.5). All 4 docs-verified clean against trino.io/docs/467 (math/select/string/conversion/window/aggregate .html) 2026-06-09. All 4 FRESH-CLEAN.

Production fit: all idioms are valid Trino 467 Iceberg-connector SQL; no stack-incompatible advice. No auth/authz scope involved.

---

## Q1 — Exact-N random sample (100 genuinely random rows each run)

**Answer:** `SELECT ... FROM orders ORDER BY random() LIMIT 100`; explained random() non-deterministic → different 100 per run; noted TABLESAMPLE BERNOULLI(N)/SYSTEM(N) as the approximate-PERCENTAGE alternative (BERNOULLI per-row, SYSTEM whole-split).

| Axis | Score | Note |
|---|---|---|
| Accuracy | 5 | `random()`/`rand()` confirmed (math.html: pseudo-random double 0.0<=x<1.0). `ORDER BY random() LIMIT N` is the correct exact-N-random idiom. TABLESAMPLE takes a PERCENTAGE not a row count (select.html); BERNOULLI=per-row probabilistic, SYSTEM=segment/split-level connector-dependent — both accurate. No conflation of TABLESAMPLE-% with exact-N. |
| Completeness | 5 | Both the exact-N idiom AND the approximate-% large-table alternative, with the correct trade-off (full sort vs cheaper sampling). |
| Clarity | 5 | "different 100 each run" makes non-determinism concrete; per-row vs whole-split distinction explained plainly. |
| Actionability | 5 | Drop-in query; clear when to switch to TABLESAMPLE. |

**Per-Q avg: 5.00 — FRESH-CLEAN.**

---

## Q2 — Cumulative count of DISTINCT users over time (KEY CHECK)

**Answer:** first_appearance CTE (`DATE_TRUNC('day', MIN(event_date))` per user) → new_users_per_day (`COUNT(*) GROUP BY first_event_day`) → `SUM(new_users) OVER (ORDER BY event_day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`. Explained Trino does NOT support `COUNT(DISTINCT) OVER`; defanged the naive `SUM(COUNT(DISTINCT)) OVER` double-count.

| Axis | Score | Note |
|---|---|---|
| Accuracy | 5 | **VERIFIED: `COUNT(DISTINCT ...) OVER` is genuinely UNSUPPORTED in Trino** — error "DISTINCT in window function parameters not yet supported" (trinodb/trino #7885, still open). Responder correctly handled this real limitation rather than fabricating that it works. The first-appearance + running-SUM workaround is mathematically correct: each user is counted exactly ONCE on their first-event day, so the running SUM of daily first-appearance counts = cumulative distinct users. `SUM() OVER (ORDER BY ... ROWS UNBOUNDED PRECEDING TO CURRENT ROW)` is valid. The double-count defang (naive `SUM(COUNT(DISTINCT)) OVER` re-counts returning users every day) is accurate. |
| Completeness | 5 | Full pipeline + per-day new-users column + cumulative column + the trap explanation. |
| Clarity | 5 | "a user counts once, on their first day" stated explicitly; CTE layering is readable. |
| Actionability | 5 | Copy-ready 3-CTE query with correct ORDER BY and frame. |

**Per-Q avg: 5.00 — FRESH-CLEAN.** Correctly navigated the COUNT(DISTINCT) OVER limitation.

---

## Q3 — Format 0.1834 as "18.34%"

**Answer:** `format('%.2f%%', conversion_rate * 100)` → '18.34%'. Explained *100, %.2f = 2 decimals, %% = literal percent; noted ||/concat require varchar (numerics don't auto-coerce) so format() is the clean path.

| Axis | Score | Note |
|---|---|---|
| Accuracy | 5 | conversion.html: format() uses Java Formatter syntax. Docs example `format('%s%%', 123) -> '123%'` confirms %%=literal percent; `format('%.5f', pi()) -> '3.14159'` confirms %.Nf decimal formatting. 0.1834*100=18.34 → '18.34%'. The ||/concat-requires-varchar note is correct — Trino does not auto-coerce numerics in `||`. |
| Completeness | 5 | The *100 step, the format spec breakdown, AND why format() beats string concatenation. |
| Clarity | 5 | Each format token explained individually. |
| Actionability | 5 | Single-expression drop-in. |

**Per-Q avg: 5.00 — FRESH-CLEAN.**

---

## Q4 — Integer cents (1999) to dollars DECIMAL (19.99)

**Answer:** `CAST(amount_cents AS DOUBLE) / 100.0` (→19.99); ALSO `CAST(amount_cents AS DECIMAL(18,2)) / 100` for exact money. Explained 1999/100=19 integer-division-truncates; cast at least one operand first; DECIMAL preferred for money (no float rounding).

| Axis | Score | Note |
|---|---|---|
| Accuracy | 5 | Integer/integer division truncates (1999/100=19) — correct. Casting one operand to DOUBLE or DECIMAL(18,2) yields 19.99 — correct. DECIMAL preferred for money (avoids binary-float rounding) — correct and consistent with the money-DECIMAL CAST lock. |
| Completeness | 5 | Names the truncation trap, gives both DOUBLE (quick) and DECIMAL (exact-money) paths, recommends DECIMAL for currency. |
| Clarity | 5 | "1999/100=19" makes the trap concrete. |
| Actionability | 5 | Two ready expressions with a clear default (DECIMAL for money). |

**Per-Q avg: 5.00 — FRESH-CLEAN.**

---

## Summary

| Q | Topic | Avg |
|---|---|---|
| Q1 | random-sample-N (ORDER BY random() LIMIT N vs TABLESAMPLE-%) | 5.00 |
| Q2 | cumulative-distinct (first-appearance running-SUM, no COUNT(DISTINCT) OVER) | 5.00 |
| Q3 | number-to-percent-string (format %.2f%%) | 5.00 |
| Q4 | cents-to-dollars (CAST DECIMAL, integer-division-trap) | 5.00 |

**Overall avg: 5.00 — STRONG PASS.**

All 4 FRESH-CLEAN. No fabrication, no dialect error, no stack-incompatibility, no card-to-card contradiction surfaced. Q2 (the key check) and Q1 (the random-vs-TABLESAMPLE check) both handled correctly.

### iter766 designation

**DEFAULT NO-OP / durability-breadth.** No gap, no defect, no FIX-A required. The four probed topics (random-sample-N, cumulative-distinct, percent-string, cents-to-dollars) are all clean and consistent with their standing pins. Teacher should NOT edit resources — pure integrity-sweep. Pick 4 fresh durability-breadth angles for iter766 (optionally a 2nd cumulative-distinct angle such as rolling-N-day distinct via HLL `merge()`/self-join, since that is the harder sibling of the clean cumulative-distinct probe). Do NOT re-edit r07 cumulative-distinct/COUNT(DISTINCT)-OVER card, r23 TABLESAMPLE/random card, r27 money-DECIMAL/percent-string cards — churn risk on bulletproofed material.
