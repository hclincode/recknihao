# Judge Feedback — Iter 526

**Date**: 2026-06-06
**Phase**: extended
**Overall**: **4.1875 PASS** (margin +0.6875 above 3.5 floor)
**Federation**: NOT probed — row stays 4.49944/310

---

## Per-question scores

### Q1 — UNNEST array with 1-based ORIGINAL array position (funnel order) — 5.000 STRONG PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | `CROSS JOIN UNNEST(step_names) WITH ORDINALITY AS t(step_name, step_position)` correct; ordinality appended LAST; 1-based; LEFT JOIN form also shown; explicit warning NOT to use ROW_NUMBER. |
| Clarity | 5.0 | Crisp framing; worked example with funnel step names. |
| Applicability | 5.0 | Engineer can copy-paste directly. |
| Completeness | 5.0 | Both CROSS and LEFT forms covered; ROW_NUMBER footgun called out. |

**Verification**: trino.io/docs/current/sql/select.html — verbatim "an additional ordinality column is added to the end" and canonical example `SELECT a, b, rownumber FROM UNNEST (ARRAY[2, 5], ARRAY[7, 8, 9]) WITH ORDINALITY AS t(a, b, rownumber);` confirmed.

**ITER525 CANONICAL CONFIRMED GENERALIZED**: r07 §1a WITH ORDINALITY sub-note landed cleanly on second angle (funnel ordering vs original iter525 tag-position framing). Iter524 fab-absence "WITH ORDINALITY is a PostgreSQL feature" is GONE and stays GONE.

---

### Q2 — approx_set precision tighter than 2.3% + merge-must-match — 4.000 PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 4.0 | "No tuning knob in `approx_set` itself" is CORRECT per official Trino docs (only `approx_set(x) → HyperLogLog` exists — no `approx_set(x, e)` overload). However, responder did not mention that `approx_distinct(x, e)` accepts a tunable `e` for one-shot (non-pre-aggregated) queries. Merge-must-match claim ("does NOT need to match") is loose — the official Trino docs do not document a constraint, but well-known HLL semantics + Trino's bucket-count serialization mean mismatched-precision merges are not safe in general. Since no `e` overload exists for `approx_set`, the question is somewhat academic in Trino, so not load-bearing wrong. |
| Clarity | 4.5 | Sketch pattern (`approx_set` + `CAST AS varbinary` + `cardinality(merge(...))`) explained well. |
| Applicability | 3.5 | Engineer learns the sketch route is locked at 2.3% but is not told about `approx_distinct(x, 0.01)` as a precision-tunable alternative for non-pre-aggregated daily-distinct queries. For a billing-reconciliation use case, `approx_distinct(user_id, 0.01)` per day (no pre-agg) targets ~1% SE — a usable middle path that the answer skipped. |
| Completeness | 4.0 | Captured the headline ("sketch precision not tunable") and the exact-COUNT(DISTINCT) fallback. Missed `approx_distinct(x, e)` as the third option. |

**Verification (META-RULE — independent doc check before flagging)**:

- **trino.io/docs/current/functions/hyperloglog.html**: only `approx_set(x) → HyperLogLog` documented. NO second-argument overload.
- **trino.io/docs/current/functions/aggregate.html**: `approx_set(x) → HyperLogLog` only. By contrast, `approx_distinct` HAS two overloads — `approx_distinct(x)` AND `approx_distinct(x, e)` with `e ∈ [0.0040625, 0.26000]`.
- **trinodb/trino GitHub source** (`ApproximateSetAggregation.java`): only `@AggregationFunction("approx_set")` with three @InputFunction overloads (bigint/double/Slice). No `maxStandardError` parameter.
- **trinodb/trino docs source** (`aggregate.md`): only `approx_set(x) -> HyperLogLog` documented.

**REVISION TO BRIEF**: The iter526 task brief asserted "`approx_set(x, e)` accepts an optional 2nd-arg max standard error". This is **NOT supported by current Trino docs or source code**. Per the META-RULE ("verify YOUR OWN corrections before asserting a responder claim is wrong"), I did NOT mark the responder DOWN for the "no tuning knob in approx_set" claim — it is CORRECT. The asymmetry (`approx_distinct(x, e)` exists; `approx_set(x, e)` does NOT) is the actual nuance the responder missed.

**Merge-must-match nuance**: docs do not document an explicit constraint; common HLL implementations require matching bucket count; Trino's HLL stores the bucket count in the serialized form. In practice merging incompatible sketches may downgrade precision. Responder's "does NOT need to match" framing is loose but not load-bearing wrong, since with only `approx_set(x)` available there is no `e` to vary anyway.

**FINDABILITY GAP**: iter525 fixed `approx_distinct(x, e)` 2nd-arg canonical in r07. That sub-note is not finding its way to questions phrased around `approx_set` / sketches / merge. The leading canonical needs a parallel sentence at the `approx_set` keyword anchor explicitly stating: "(a) `approx_set` has NO `e` overload; (b) for tunable precision in non-pre-aggregated queries use `approx_distinct(x, e)` directly; (c) sketches are stuck at ~2.3% default."

---

### Q3 — Oracle NEXT_DAY → Trino, generalized to any weekday — 5.000 STRONG PASS

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 5.0 | `date_add('day', ((5 - day_of_week(contract_start) + 6) % 7) + 1, contract_start)` correct for Friday target_dow=5; ISO numbering 1=Mon..7=Sun verified; strictly-after semantic preserved; generalizes by changing target_dow. |
| Clarity | 5.0 | Worked examples for several weekdays. |
| Applicability | 5.0 | Engineer can plug in any target_dow value. |
| Completeness | 5.0 | Strictly-after edge case covered; ISO convention stated explicitly. |

**Verification**: trino.io/docs/current/functions/datetime.html — `day_of_week(x) → bigint` returns "value ranges from 1 (Monday) to 7 (Sunday)". `date_add(unit, value, ts)` confirmed.

**Re-derivation**: Wed (dow=3) → Fri (target=5): `((5-3+6)%7)+1 = (8%7)+1 = 1+1 = 2` → Wed + 2 = Fri. Fri→Fri same-day edge: `((5-5+6)%7)+1 = (6%7)+1 = 6+1 = 7` → +7 days = next Fri (strictly after).

**ITER525 CANONICAL CONFIRMED GENERALIZED**: r27 §4.x NEXT_DAY block landed on second angle (Friday vs iter525 Monday). Formula generalizes cleanly by `target_dow` substitution.

---

### Q4 — bucket continuous metric into uneven ranges — 2.75 FAIL

| Dim | Score | Notes |
|---|---|---|
| Accuracy | 2.0 | **FABRICATED ABSENCE — load-bearing**: responder claims "resources don't document whether Trino 467 supports a width_bucket() histogram function". WRONG. Trino 467 HAS BOTH overloads: `width_bucket(x, bound1, bound2, n)` (equal-width) AND `width_bucket(x, bins)` (array-bins, uneven). The array-bins form is the EXACT direct answer for the user's uneven ranges (0-30, 30-60, 60-120, 120+). |
| Clarity | 4.0 | CASE WHEN fallback is correctly written. |
| Applicability | 2.5 | Engineer ends up with an 8-line CASE WHEN when `width_bucket(session_duration_seconds, ARRAY[30, 60, 120])` is a one-liner. |
| Completeness | 2.5 | Missed both width_bucket overloads, particularly the array-bins form that maps 1:1 to the user's question. |

**Verification**: trino.io/docs/current/functions/math.html — both signatures documented verbatim:
- `width_bucket(x, bound1, bound2, n) → bigint` — "Returns the bin number of `x` in an equi-width histogram with the specified `bound1` and `bound2` bounds and `n` number of buckets."
- `width_bucket(x, bins) → bigint` — "Returns the bin number of `x` according to the bins specified by the array `bins`. The `bins` parameter must be an array of doubles and is assumed to be in sorted ascending order."

**Correct answer for user's uneven 0-30 / 30-60 / 60-120 / 120+ bins**:
```sql
SELECT width_bucket(session_duration_seconds, ARRAY[30, 60, 120]) AS bucket, COUNT(*)
FROM sessions
GROUP BY 1
ORDER BY 1;
-- bucket 0 = <30, 1 = [30,60), 2 = [60,120), 3 = >=120
```

**INCONSISTENCY ANCHOR**: Responder used `width_bucket` CORRECTLY in iter523 Q2 (equal-width form). The function is not yet a leading canonical in resources/, so findability is fragile to question phrasing. Iter523's success was probably opportunistic.

---

## Overall iter526 PASS/FAIL

**OVERALL AVG** = (5.000 + 4.000 + 5.000 + 2.75) / 4 = 16.75 / 4 = **4.1875 PASS**

- Margin: +0.6875 above 3.5 floor
- Q1 + Q3 second-angle re-probes: both 5.000 — iter525 canonicals (WITH ORDINALITY at r07 §1a, NEXT_DAY at r27 §4.x) confirmed durable.
- Q2 mid-PASS (4.000): mostly accurate but missed the `approx_distinct(x, e)` cross-link from the `approx_set` keyword anchor.
- Q4 FAIL (2.75): fab-absence on `width_bucket` despite responder having used it correctly in iter523 — pure findability gap.

---

## Topic average updates

**SQL query best practices for OLAP** (current 4.5045/76 — Q1 UNNEST WITH ORDINALITY + Q2 approx_set + Q4 width_bucket all map here per analytical-pattern/aggregate-functions/math-functions cluster precedent):
- New: (4.5045 × 76 + 5.000 + 4.000 + 2.75) / 79 = (342.342 + 11.75) / 79 = 354.092 / 79 = **4.4822/79** (-0.0223 — Q4 fab-absence drags net negative)

**Oracle PL/SQL → dbt + Trino SQL migration** (current 4.5123/90 — Q3 NEXT_DAY generalization maps here):
- New: (4.5123 × 90 + 5.000) / 91 = (406.107 + 5.000) / 91 = 411.107 / 91 = **4.5176/91** (+0.0053 — Q3 above topic-avg lift)

**Federation row**: 4.49944/310 UNCHANGED per directive.

---

## Concrete next-teacher actions for iter527

### FIX A (HIGH — findability) — r07 approx_set/HLL block reconcile-in-place
**Location**: At the existing r07 approx_distinct canonical (the iter525 sub-note that added `approx_distinct(x, e)`). RECONCILE — do not append duplicate.

**Add a parallel `approx_set` sub-note** with these load-bearing rules:
1. **`approx_set` has NO `e` overload** — only `approx_set(x) → HyperLogLog`. Source: trino.io/docs/current/functions/hyperloglog.html (single signature) + aggregate.html (same).
2. **Sketches stored as varbinary are stuck at the default ~2.3% standard error**. There is NO `approx_set(x, e)` overload to tighten precision at sketch-creation time.
3. **For tunable precision without pre-aggregation**: use `approx_distinct(x, e)` directly on the slice (e.g. `approx_distinct(user_id, 0.01)` per day) — this gives ~1% SE without sketches/merge.
4. **Merge semantics**: `merge()` aggregates HyperLogLog structures. Trino does not document a constraint that all input sketches must share the same parameters, but well-known HLL semantics require matching bucket count; since only one `approx_set` precision exists in Trino, this is academic in practice — but engineers should NOT assume cross-Trino-version or cross-implementation sketch portability with mismatched bucket counts.
5. **If 2.3% is too loose AND you need pre-aggregation**: there is no way in Trino 467 — fall back to exact `COUNT(DISTINCT)` or use `approx_distinct(x, e)` on the daily slice without storing sketches.

**Keyword anchors**: "approx_set precision Trino / HLL sketch tighter than 2.3 / approx_set max standard error / approx_set e parameter / sketch precision Trino HyperLogLog / merge sketches different precision Trino / tighter than default HLL Trino / sketch billing reconciliation Trino / approx_set tuning knob".

**DO-NOT-WRITE bans**:
- "`approx_set(x, e)` accepts a maxStandardError second argument" — FALSE (the iter526 brief erroneously asserted this; no such overload exists).
- "`approx_set` precision is fully tunable in Trino 467" — FALSE.
- "Sketches with different precision can always be merged safely regardless of how they were built" — too strong; common HLL implementations require matching bucket count.

### FIX B (HIGH — fab-absence prevention) — r07 NEW LEADING CANONICAL for `width_bucket` (both overloads)
**Location**: r07 §1a analytical patterns / aggregate-helpers block. NEW canonical (not yet a leading canonical — responder's iter526 fab-absence + iter523 opportunistic correctness shows findability is fragile).

**Add a `width_bucket` block** with these load-bearing rules:
1. **`width_bucket(x, bound1, bound2, n) → bigint`** — equal-width histogram. Returns 1..n for in-range; 0 below bound1; n+1 above bound2.
2. **`width_bucket(x, bins) → bigint`** — explicit bins (uneven widths!). `bins` is an ascending-sorted ARRAY of doubles. Returns 0 for x < bins[1]; i for x in [bins[i], bins[i+1]); cardinality(bins) for x >= bins[last].
3. **For UNEVEN buckets like 0-30 / 30-60 / 60-120 / 120+, use the array-bins overload** — NOT a CASE WHEN ladder, NOT the equal-width form:
   ```sql
   SELECT width_bucket(session_duration_seconds, ARRAY[30, 60, 120]) AS bucket, COUNT(*)
   FROM sessions GROUP BY 1 ORDER BY 1;
   ```
4. CAST array element type if needed (`ARRAY[30.0, 60.0, 120.0]` or `CAST(ARRAY[30, 60, 120] AS ARRAY<DOUBLE>)`).
5. Worked examples for BOTH overloads: equal-width (0-1000 in 10 buckets) + uneven (session-duration 30/60/120 boundaries).

**Keyword anchors**: "Trino bucket continuous metric / Trino histogram function / Trino width_bucket / Trino uneven buckets / Trino range bucketize / Trino group by range buckets / alternative to CASE WHEN bucket Trino / Trino bin numbers histogram / bucket session duration Trino / width_bucket array bins Trino".

**DO-NOT-WRITE bans**:
- "Trino 467 doesn't have a width_bucket function" — FALSE.
- "width_bucket only supports equal-width buckets" — FALSE (array-bins overload exists).
- "For uneven buckets you must use CASE WHEN in Trino" — FALSE (array-bins overload is the canonical path).

### POLISH (LOW) — r17 expire_snapshots → remove_orphan_files cross-ref
Iter525's polish suggestion stands but is LOW priority; r17 already covers `remove_orphan_files` thoroughly per the iter526 state.json grep. No action needed unless a future re-probe shows the cross-ref is load-bearing.

### Iter527 probe targets
- **width_bucket array-bins RE-PROBE** (HIGH — "histogram of latencies into custom buckets [50, 100, 500, 1000] ms — Trino function?" verifies FIX B array-bins canonical lands + fab-absence does not reappear).
- **width_bucket equal-width 2nd angle** (HIGH — "bucket scores 0-100 into 10 equal-width buckets and count — Trino?" verifies FIX B equal-width form holds).
- **approx_set + approx_distinct(x, e) cross-link 2nd angle** (HIGH — "do I use approx_set or approx_distinct if I want 1% standard error?" verifies FIX A's sketch-no-tuning / approx_distinct-yes-tuning asymmetry lands).
- **approx_set merge cross-version safety 2nd angle** (MEDIUM — "can I merge HLL sketches built with different Trino versions?" verifies FIX A's bucket-count caveat lands).
- **UNNEST WITH ORDINALITY 3rd angle** (LOW — well-bulletproofed; only re-probe if findability slips).
- **NEXT_DAY 3rd angle** (LOW — well-bulletproofed; only re-probe if a non-Mon/Fri target raises an edge case).
- **Federation stays UNPROBED** (LOW — row stays 4.49944/310).

---

## Streak / momentum note

- Iter525 (4.984 STRONG PASS) → Iter526 (4.1875 PASS) — streak preserved at 122nd consecutive overall PASS in extended phase, but margin tightened from +1.484 to +0.6875 because of the Q4 width_bucket fab-absence.
- Q1 + Q3 second-angle re-probes both 5.000 — iter525 canonicals durable.
- Q2 + Q4 reveal the same META-PATTERN: **leading canonicals at one keyword (e.g. `approx_distinct`) do NOT auto-extend to adjacent keywords (`approx_set`, `width_bucket`)** unless the teacher places parallel anchor text. This is the iter527 priority.
