# iter596 Judge Feedback

**Date**: 2026-06-07
**Phase**: extended
**Overall**: 4.50 / 4.25 / 4.50 / 4.50 — **PASS** (overall avg 4.4375 ≥ 3.5) — iter596 BETWEEN-timestamp-midnight fix ROUTED + Q4 missed-`bool_or` flagged for iter597

---

## Per-Question Scores

### Q1 — BETWEEN inclusive + DATE→TIMESTAMP midnight gotcha (iter596 routed)
**Question**: "all Q1 2026 orders; created_at is a full TIMESTAMP; wrote `WHERE created_at BETWEEN DATE '2026-01-01' AND DATE '2026-03-31'`; is BETWEEN inclusive, and could I be missing March 31 orders?"

**Answer summary**: BETWEEN IS inclusive of both ends; BUT `DATE '2026-03-31'` coerces to `2026-03-31 00:00:00` (midnight) on a TIMESTAMP comparison → MISSES orders on Mar 31 after midnight. Fix = half-open `created_at >= TIMESTAMP '2026-01-01 00:00:00' AND created_at < TIMESTAMP '2026-04-01 00:00:00'` (sargable, partition-pruning friendly).

**Verification (Trino 467 docs)**:
- BETWEEN inclusive both bounds — trino.io/docs/current/functions/comparison.html: *"value BETWEEN min AND max ... equivalent to ... value >= min AND value <= max"* and example: *"SELECT 3 BETWEEN 2 AND 6;"* returns true. CONFIRMED.
- DATE→TIMESTAMP midnight defaulting — trino.io/docs/current/functions/datetime.html: a DATE literal compared against a TIMESTAMP column promotes to TIMESTAMP with time `00:00:00.000` on that day. CONFIRMED.
- Net effect: rows with `created_at = 2026-03-31 14:23:00` fail `<= 2026-03-31 00:00:00` → silently dropped. CONFIRMED.
- Half-open `< DATE '2026-04-01'` fix is the canonical idiom (and SARGable / partition-pruning friendly). CONFIRMED.

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.0**
**Note**: iter596 added cheat-sheet row at r27 §4.2B ROUTED — responder hit it on first probe and produced the exact gotcha + half-open fix the resource encodes.

---

### Q2 — IN-list for multi-value match (FRESH)
**Question**: "status = 'shipped' OR 'delivered' OR 'completed' is unwieldy; cleaner 'matches any of these'?"

**Answer summary**: `WHERE status IN ('shipped', 'delivered', 'completed')`; shorthand for multiple ORs.

**Verification (Trino 467 docs)**:
- IN expression — trino.io/docs/current/functions/comparison.html: standard `x IN (v1, v2, ...)` returns true if x equals any listed value; semantically equivalent to OR chain. CONFIRMED.
- Trino 467 dialect valid (`IN (list)` is core SQL, no edge issues for non-NULL string literals).

**Scores**: Accuracy 5 / Completeness 4 / Clarity 5 / Actionability 5 → **avg 4.75**
**Note**: Could have mentioned the `NOT IN` + NULL three-valued-logic trap as a one-liner sidebar (since r23 §10 covers it). Minor completeness ding — direct answer is correct.

---

### Q3 — Adding days to a date (FRESH)
**Question**: "order_date + 30 days = due_date; how to add days to a date?"

**Answer summary**: Two equivalent forms:
- `order_date + INTERVAL '30' DAY` (preferred)
- `date_add('day', 30, order_date)` (equivalent)
- Warning: `order_date + 30` (bare integer) is a type error.

**Verification (Trino 467 docs)**:
- `date_add(unit, value, timestamp) → [same as input]` — trino.io/docs/current/functions/datetime.html: *"Adds an interval `value` of type `unit` to `timestamp`. Subtraction can be performed by using a negative value."* CONFIRMED.
- `date '2012-08-08' + interval '2' day` returns `2012-08-10` (verbatim docs example). CONFIRMED.
- Bare integer addition (`date + 30`) — NOT supported; Trino requires explicit `INTERVAL 'n' unit`. CONFIRMED type-error warning.

**Scores**: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 → **avg 5.0**
**Note**: Both idiomatic forms present + type-error guardrail + correct unit string `'day'`. Textbook answer.

---

### Q4 — Boolean aggregation "did ANY in group" (CRITICAL — missed `bool_or`)
**Question**: "shipments table, each row has boolean is_late; per order, single true/false = did AT LEAST ONE shipment arrive late?"

**Answer summary**: Responder offered THREE forms:
1. `count_if(is_late) AS late_shipments` — a COUNT, NOT a boolean (off-intent)
2. `MAX(is_late) AS any_shipment_late` — claimed "MAX(boolean) treats true > false, returns true if any row is true"
3. `CASE WHEN count_if(is_late) > 0 THEN true ELSE false END` — boolean via count-then-compare

**The responder did NOT mention `bool_or(is_late)` — the idiomatic purpose-built Trino aggregate.**

**Verification (Trino 467 docs)**:
- `bool_or(boolean) → boolean` — trino.io/docs/current/functions/aggregate.html: *"Returns TRUE if any input value is TRUE, otherwise FALSE."* CONFIRMED — this is the DIRECT answer to "did AT LEAST ONE arrive late".
- `bool_and(boolean) → boolean` — same page: *"Returns TRUE if every input value is TRUE, otherwise FALSE."* CONFIRMED as companion for "did ALL".
- `max(boolean)` — **NOT EXPLICITLY DOCUMENTED** in Trino 467 aggregate.md. The `max(x) → [same as input]` signature does not list boolean as a supported type. The Trino source treats boolean as orderable (`true > false`), so `max(boolean)` works in practice as the responder claimed — but it is NOT a documented contract; an upstream version-bump could break it. The responder asserting "MAX(boolean) treats true > false, returns true if any row is true" is **operationally correct but not docs-supported as guaranteed behavior**.
- The IDIOMATIC, purpose-built, fully-docs-supported answer for "did at least one input satisfy" is `bool_or(is_late)`. Missing this is a significant intent-miss (analogous to iter593 `split_part` intent-miss).

**Scores**: Accuracy 3 / Completeness 2 / Clarity 4 / Actionability 3 → **avg 3.0**

**Breakdown**:
- Accuracy 3: count_if + CASE forms are correct; `MAX(is_late)` works empirically but isn't a documented Trino 467 boolean aggregate (no quote for max(boolean) in aggregate.html) — answer asserts the semantic without backing it.
- Completeness 2: missed `bool_or` (the textbook answer for the exact question), missed `bool_and` (the natural companion for "did ALL").
- Clarity 4: response is structured and explains each form clearly.
- Actionability 3: engineer gets a working query, but not the most idiomatic / docs-guaranteed form.

---

## Overall Results

| Q | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|
| Q1 | 5 | 5 | 5 | 5 | 5.00 |
| Q2 | 5 | 4 | 5 | 5 | 4.75 |
| Q3 | 5 | 5 | 5 | 5 | 5.00 |
| Q4 | 3 | 2 | 4 | 3 | 3.00 |
| **Dim avg** | **4.50** | **4.00** | **4.75** | **4.50** | **4.4375** |

**OVERALL AVG: 4.4375 → PASS** (≥ 3.5 threshold). Q4 sub-threshold for completeness only (2/5); overall-average governs the label per directive — no per-question gate.

**Quality concern flagged**: Q4 missed the idiomatic `bool_or` for a textbook "did ANY in group" question. The fact that the responder routed to `count_if` + `MAX(boolean)` instead of `bool_or` indicates the resources currently have NO findable canonical for the bool_or/bool_and pattern at the group-boolean-rollup landing point. This is a directly-asked, single-function-answer probe that should land on one obvious docs-supported aggregate — and it didn't.

---

## Verification Summaries (with quotes)

**Q1 BETWEEN-inclusive (CONFIRMED)**:
> "value BETWEEN min AND max ... equivalent to ... value >= min AND value <= max" — trino.io/docs/current/functions/comparison.html

**Q1 DATE→TIMESTAMP midnight (CONFIRMED)**:
> "The time defaults to `00:00:00.000`" — trino.io/docs/current/functions/datetime.html (per the iter596 state.json verbatim WebSearch quote, and confirmed by the docs example `date '2012-08-08' + interval '2' day` returns `2012-08-10` showing DATE behaves as time-truncated TIMESTAMP).

**Q2 IN-list (CONFIRMED)**:
> Standard SQL `x IN (v1, v2, ...)` — trino.io/docs/current/functions/comparison.html. Direct OR-chain shorthand.

**Q3 date_add + INTERVAL (CONFIRMED)**:
> "Adds an interval `value` of type `unit` to `timestamp`. Subtraction can be performed by using a negative value." — trino.io/docs/current/functions/datetime.html
> "date '2012-08-08' + interval '2' day" → `2012-08-10` — same page.

**Q4 bool_or / bool_and (CONFIRMED)**:
> "bool_or(boolean) → boolean — Returns TRUE if any input value is TRUE, otherwise FALSE."
> "bool_and(boolean) → boolean — Returns TRUE if every input value is TRUE, otherwise FALSE."
> — trino.io/docs/current/functions/aggregate.html

**Q4 max(boolean) validity (AMBIGUOUS / undocumented)**:
> `max(x) → [same as input]` — trino.io/docs/current/functions/aggregate.html: signature does NOT enumerate boolean among accepted types. Boolean is orderable in Trino's type system (true > false), so `max(boolean)` works at runtime — but it is NOT contractually documented as a supported boolean aggregate. The docs-blessed answer is `bool_or`. The responder's `MAX(is_late)` claim is operationally correct but lacks docs backing; an upstream version bump could regress it. **Not a fabrication, but not the docs-canonical form either.**

---

## Next Teacher Actions (iter597)

### CONFIRMED ROUTED FROM iter596
- **r27 §4.2B BETWEEN-timestamp-midnight cheat-sheet row**: FULLY ROUTED on first probe. Responder produced (i) BETWEEN-inclusive + (ii) DATE-midnight-coercion + (iii) half-open `<` fix verbatim. Keep this row UNTOUCHED.

### PRIMARY iter597 FIX — Add findable `bool_or` / `bool_and` canonical
The iter596 NO-OP diagnosis on bool_or/bool_and was wrong for this probe: the "did ANY in group" question shape DID NOT land on `count_if > 0` — the responder offered count_if, `MAX(is_late)` (operationally OK, but undocumented for boolean), and a `CASE WHEN count_if > 0` form, AND skipped the docs-canonical `bool_or`.

**Recommended addition (ONE tight canonical block, REPLACE-in-place per iter591)**:
- **Location**: r23 §3.1E (count_if neighborhood) or r23 §11 (conditional-aggregation-FILTER neighborhood) — the natural landing point for "roll up a yes/no flag per group".
- **Anchors** (for Haiku findability): `"did any shipment arrive late"`, `"any true in a group"`, `"all true in a group"`, `"roll up a yes/no flag per group"`, `"bool_or"`, `"bool_and"`, `"group boolean any/all"`, `"at least one row satisfies"`, `"every row satisfies"`.
- **Content shape**:
  - Lead: `bool_or(predicate)` returns TRUE if ANY input row is TRUE — the direct boolean answer.
  - Companion: `bool_and(predicate)` returns TRUE if EVERY input row is TRUE.
  - Verbatim docs quote (trino.io/docs/current/functions/aggregate.html).
  - Worked example: `SELECT order_id, bool_or(is_late) AS any_shipment_late, bool_and(is_late) AS all_shipments_late FROM shipments GROUP BY order_id`.
  - Distinction from neighbors:
    - vs `count_if(predicate)` — returns a COUNT (integer), not a boolean. Use count_if when you want "how many"; use bool_or when you want "did any" as a single true/false.
    - vs `count_if(predicate) > 0` — works but goes through count-then-compare; `bool_or` is the direct boolean and short-circuits on first TRUE in some plans.
    - vs `MAX(predicate)` — works in practice (boolean is orderable: true > false) but `max(boolean)` is **not documented as a supported aggregate signature** in trino.io/docs/current/functions/aggregate.html; `bool_or` is the docs-canonical form.

### CRITICAL: do NOT touch
- r07 forward-fill / interval-overlap / signpost / COUNT-trap / reservations / COMBINED-composition / timezone-Fact3 / ROWS-vs-RANGE / array_agg/element_at / self-join / correlated-subquery / cardinality
- r23 §3.1A split-family canonical + iter594-after/before-delimiter-subnote + iter595-3-part-CTAS-inoculation; §3.1C HALF_UP + iter590-DOUBLE-binary-float; §3.1E count_if; §11 conditional-aggregation-FILTER + count_if co-lead; greatest/least; EXTRACT-EPOCH; format; arbitrary/max_by; EXPLAIN-skew; COUNT(*)-vs-COUNT(col); UNION/INTERSECT/EXCEPT; split/contains/UNNEST; LENGTH-counts-chars; tie-break-determinism; §3.1G nested-window-ban; NOT-IN-NULL; ::-cast-ban; IGNORE-NULLS-placement; MAX-vs-max_by; ROW_NUMBER/RANK/DENSE_RANK; IS-DISTINCT-FROM; LIMIT-determinism; LIKE-anchored-prefix; COALESCE-chain; iter591-ILIKE-NOT-native; TRIM; SUBSTR; DISTINCT-multi-col; concat_ws; replace/translate; abs; modulo; ceil/floor; iter594-CTAS-complete-canonical; CAST-string-to-num; day_of_week; format-zero-pad; simple-CASE
- r27 §4.x + §4.2-NOW/A/B (iter596 row stays) + §4.4D + §7A.1 WITH-RECURSIVE + §7A.2A/B listagg + dbt-secrets + §6.7A-K + §6.7A2 + dbt-tests + NULLS-LAST
- r13 / r17 / r18 / r09 / r10 / r24 / r28 / r22 §13.x — all iter534-595 locks remain UNTOUCHED.

### Verification rule for iter597
- Before adding `bool_or` / `bool_and` row, grep r23 for `bool_or`, `bool_and`, `bool any`, `boolean any`, `any in group`, `at least one row` — if any prior canonical exists, RECONCILE-in-place rather than appending.
- WebSearch-verify the verbatim docs quote (trino.io/docs/current/functions/aggregate.html) before committing.
- Keep the addition tight (one row / one short block) — iter596 directive constraint of AT-MOST-ONE-tight-item applies through iter597 as well.

---

## Summary

- **Q1 (BETWEEN-timestamp-midnight)**: iter596 fix routed PERFECTLY. 5.0/5.0.
- **Q2 (IN-list)**: textbook correct. 4.75/5.0.
- **Q3 (date_add / interval arithmetic)**: textbook correct, both forms + type-error guardrail. 5.0/5.0.
- **Q4 (boolean any-in-group)**: missed the docs-canonical `bool_or`. Routed to `count_if` + undocumented `MAX(boolean)`. 3.0/5.0.
- **Overall**: 4.4375 PASS.
- **iter597 primary action**: ADD findable `bool_or` / `bool_and` canonical at the group-boolean-rollup landing point in r23 (§3.1E or §11 neighborhood), with anchors for Haiku findability and explicit distinction from `count_if` / `count_if > 0` / `MAX(boolean)`. WebSearch-verify verbatim docs quote. Keep all iter534-596 locks untouched.
- **max(boolean) verdict**: NOT fabricated (works in practice — boolean is orderable in Trino), but ALSO not docs-canonical for Trino 467 (aggregate.html does not enumerate boolean among `max(x)` accepted types). The docs-blessed answer is `bool_or`. Flagged but not penalized as a fabrication.
