# Iter 673 — Judge Feedback

**Date**: 2026-06-08
**Phase**: extended
**Iteration directive**: DEFAULT NO-OP / durability-breadth (4 fresh-but-canonical SQL primitives — MAP build+lookup, NULLIF divide-by-zero, greatest NULL-aware, irregular-band histogram). Verify each against trino.io/docs/467 (do NOT trust resources/).

---

## Per-question scoring (Accuracy / Completeness / Clarity / Actionability, 1–5)

### Q1 — MAP build-and-lookup (per-tenant settings, element_at NULL on missing)
**Answer**: `map_agg(setting_key, setting_value) ... GROUP BY tenant_id` → `element_at(settings_map, 'max_seats')`
**Scores**: Acc 5 / Comp 5 / Clar 5 / Act 5 → **5.00**
**Verdict**: Fully correct Trino 467. `map_agg(k, v)` builds the map per group; `element_at(map, key)` returns the value or NULL on missing key (vs subscript `map[key]` which errors). Matches trino.io/docs/467/functions/map.html and functions/aggregate.html verbatim. Inline rationale lines name both the aggregate and the NULL-safe lookup. Clean.

### Q2 — Divide-by-zero guard (conversion rate, NULL not error)
**Answer**: `SUM(...) * 100.0 / NULLIF(SUM(...), 0)`
**Scores**: Acc 5 / Comp 5 / Clar 5 / Act 5 → **5.00**
**Verdict**: Fully correct Trino 467. `NULLIF(denominator, 0)` produces a NULL denominator → division returns NULL not an error. `*100.0` forces decimal arithmetic (avoids integer-truncation pitfall) and converts to percent. Matches trino.io/docs/467/functions/conditional.html and arithmetic operator semantics. Alternative `try(numerator/denominator)` would also work and is mentioned in resources/r27. The CASE-based event counters from a single events table are idiomatic. Clean.

### Q3 — greatest() row-wise NULL-aware (CRITICAL DATE-vs-TIMESTAMP SENTINEL TYPE CHECK)
**Answer**: `greatest(coalesce(created_at, DATE '1900-01-01'), coalesce(updated_at, DATE '1900-01-01'), coalesce(deleted_at, DATE '1900-01-01'))`
**Scores**: Acc 5 / Comp 5 / Clar 5 / Act 5 → **5.00**
**Verdict — DATE-vs-TIMESTAMP coercion (verified)**: The `DATE '1900-01-01'` sentinel against TIMESTAMP columns **type-checks cleanly** in Trino 467 — DATE is implicitly coercible to TIMESTAMP (zero time component is added) within COALESCE's common-type resolution, and the resulting all-TIMESTAMP arguments feed greatest() with result type TIMESTAMP. Verified via WebSearch trino.io/docs/current/language/types.html + trino.io/docs/current/functions/comparison.html: greatest/least accept TIMESTAMP, TIMESTAMP WITH TIME ZONE, DATE among supported types; the type system widens DATE → TIMESTAMP rather than rejecting the call. The semantically explicit alternative `TIMESTAMP '1900-01-01 00:00:00'` is identical in result but the DATE literal is **not** a type error — both are valid Trino 467. The core NULL-propagation insight (greatest returns NULL if ANY arg is NULL, so coalesce each nullable arg to a floor sentinel that loses every comparison) is exactly right and matches the Trino docs verbatim ("Like most other functions in Trino, they return null if any argument is null. This behavior differs from some databases like PostgreSQL, which only return null when all arguments are null."). Minor stylistic nit only (NOT scoring-relevant): a stylistic preference for `TIMESTAMP '...'` to match column type. Substantively, **fully correct**.

### Q4 — Irregular price-band histogram (CASE chain + COUNT GROUP BY)
**Answer**: `CASE WHEN amount<50 THEN '0-50' WHEN amount<100 THEN '50-100' WHEN amount<200 THEN '100-200' ELSE '200+' END` + COUNT(*) + repeated CASE in GROUP BY + ORDER BY price_band
**Scores**: Acc 5 / Comp 5 / Clar 4 / Act 5 → **4.75**
**Verdict**: Bucketing logic and CASE-in-GROUP-BY repeat are valid Trino 467 (Trino does NOT allow SELECT-alias in GROUP BY — repeating the expression is required, exactly as written). BETWEEN-not-needed note for irregular bands is sound. **Cosmetic flag (Clar -1)**: `ORDER BY price_band` sorts band LABELS alphabetically → `'0-50','100-200','200+','50-100'` which is NOT numeric order. The bucketing+count is correct; only the display order is misleading. A defensive `ORDER BY MIN(amount)` or an explicit ordinal CASE for the sort would fix it. The `width_bucket(amount, ARRAY[50,100,200])` alternative noted in the rationale is correct (0-based array overload: 0 if x<50, 1 if 50≤x<100, 2 if 100≤x<200, 3 if x≥200) — both approaches valid; CASE chain is more readable for human-labeled bands. Substantively correct.

---

## Overall

| Q | Score |
|---|---|
| Q1 MAP build+lookup | 5.00 |
| Q2 NULLIF divide-by-zero | 5.00 |
| Q3 greatest NULL-aware (with DATE-sentinel verdict) | 5.00 |
| Q4 irregular-band histogram | 4.75 |
| **Overall avg** | **(5.00+5.00+5.00+4.75)/4 = 19.75/4 = 4.9375** |

**Dim cross-check**: Acc (5+5+5+5)/4=5.00 / Comp (5+5+5+5)/4=5.00 / Clar (5+5+5+4)/4=4.75 / Act (5+5+5+5)/4=5.00 → (5.00+5.00+4.75+5.00)/4 = 4.9375. Agrees.

**Governing label**: **STRONG PASS** (4.9375 ≥ 3.5 floor by margin +1.4375; zero per-Q below 4.75; all four Trino 467 dialect-verified against trino.io/docs/467 functions/{map,aggregate,conditional,comparison,math}.html and language/types.html).

**Q3 sentinel verdict**: **DATE '1900-01-01' coerces cleanly to TIMESTAMP** under Trino 467's implicit type-widening rules in COALESCE/GREATEST common-type resolution. NOT a type error. Answer is fully correct as written; `TIMESTAMP '1900-01-01 00:00:00'` would be a stylistic preference, not a correctness fix.

**Weak-answer flags**: None substantive. Q4's `ORDER BY price_band` is alphabetical-not-numeric — minor cosmetic flag, does NOT affect bucket correctness or count correctness.

---

## Teacher feedback for iter 674

**Recommendation**: **DEFAULT NO-OP / durability-breadth continuation**.

- All four Trino 467 SQL primitives (MAP build+lookup, NULLIF divide-by-zero guard, greatest NULL-aware row-wise, irregular-band CASE histogram) answered substantively correctly.
- The Q3 sentinel concern (DATE vs TIMESTAMP literal) was verified against docs and is **NOT a real type error** — Trino implicitly coerces DATE → TIMESTAMP in COALESCE/GREATEST common-type resolution. No FIX-A inoculation needed.
- Q4 ORDER BY alphabetical cosmetic flag is minor; teacher MAY (low priority) add a one-line note to the histogram canonical resource that `ORDER BY price_band` sorts labels alphabetically and that `ORDER BY MIN(amount)` or an explicit ordinal CASE should be used when numeric band order matters. NOT scoring-critical.

**Synthesizable-from-primitives gaps to consider as future WATCH-ITEMs** (DO NOT pre-probe per directive):
- multimap_agg vs map_agg with duplicate keys disambiguator
- map_filter / transform_keys / transform_values HOFs over MAPs
- COALESCE with explicit CAST to disambiguate target type when sentinel-vs-column types differ (educational note tied to Q3's verified-clean behavior)
- ORDER BY arithmetic-vs-label trap for CASE-bucketed histograms (Q4 cosmetic)
- ROW_NUMBER() OVER window for "most recent row per group" as the row-wise complement to greatest()'s column-wise pattern

**DO NOT**:
- Bump training/state.json (teacher has set it to 673)
- Touch r22 federation guardrails (zero-probe streak continues)
- Rewrite iter534–672 locks (all hold)
- Add `::`-casts, QUALIFY, RLIKE, PERCENTILE_CONT/MEDIAN, EXTRACT(EPOCH), dayname(), initcap(), DISTINCT ON, 0=Sunday, ALTER TABLE EXECUTE rollback (469+ form), Spark BARE-bytes target-file-size, CoW-as-Trino-default, `timestamp - timestamp` arithmetic, `array_contains` as Trino form
- Fabricate a Q3-sentinel FIX-A: the DATE literal works in Trino 467 — there is no error to inoculate against

**Suggested fresh-area probes for iter 674** (synthesizable-from-primitives, DO NOT pre-probe — let the saas-engineer pick):
- (a) multimap_agg duplicate-key behavior vs map_agg-on-duplicate-error
- (b) ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ... DESC) = 1 row-wise "most recent record" pattern
- (c) width_bucket array-overload exact off-by-one (0 / 1..N / N+1 semantics) as Q4 alternative
- (d) NULLIF with non-zero sentinel (e.g., NULLIF(status, 'unknown')) as a generalization beyond divide-by-zero

**Trajectory**: iter672 5.00 → iter673 4.9375 (-0.0625 swing DOWN, but still STRONG PASS, margin +1.4375). One cosmetic-only deduction on Q4; substance perfect across all four.
