# Iter1186 Judge Feedback

**Overall verdict: STRONG PASS** (avg **4.59 / 5**, well above 3.5 threshold).

- **Q1 SOFT WATCH CLOSES** — `r27 fiscal-quarter-macro CONCAT-number-cast + macro-vs-intermediate-model recommendation iter1185` cleanly closes on first re-probe. BOTH iter1185 slips fixed: (a) dbt MACRO recommended as the function analog (not intermediate-model mis-rec), and (b) explicit `CAST(tier_number AS varchar)` before `||` with un-cast form defanged as WRONG.
- **Q2 UNDER-ROUTED but VALID** — `map_values` correctly identified; UNNEST+EXISTS and UNNEST+GROUP BY+MAX forms both work; missed the cleaner `any_match(map_values(...), v -> v > 0.9)` one-liner that the iter1183 any_match coverage should have surfaced.
- **Q3 pin-perfect** — single HAVING with two aggregate conditions joined by AND; no subquery needed.
- **Q4 minor approximations** — dynamic filtering correctly named + automatic + INNER/RIGHT-only-not-LEFT/FULL is CORRECT per docs; but missed semi-joins-with-IN (also supported), overstated "needs ANALYZE stats" (DF works at runtime; ANALYZE helps broadcast-decision not DF itself), and the `dynamicFilterSplitsProcessed` EXPLAIN ANALYZE field name is illustrative-not-verbatim (docs show "Dynamic filters:" section in ScanFilterProject nodes).

Total iter1186 score: (5.0 + 4.125 + 5.0 + 4.25) / 4 = **4.59 / 5**.

| Q | Topic | Score | Note |
|---|---|---|---|
| 1 | Oracle PL/SQL → dbt+Trino migration — macro for reusable scalar + Trino concat type-error | 5.0 | **Soft watch CLOSES.** Both iter1185 slips fixed: dbt MACRO recommended as the function analog (not intermediate-model), and CAST(int AS varchar) before `||` with un-cast WRONG form defanged. r13 cited; r27 §7A.3 + §7A.3.1 reached. |
| 2 | SQL best practices — map_values + any_match for threshold check | 4.125 | `map_values` correct; UNNEST+EXISTS and UNNEST+GROUP BY+MAX both work but verbose; missed cleaner `any_match(map_values(...), v -> v > 0.9)` one-liner (any_match was canonicalized iter1183). Correct answer, under-routed phrasing. |
| 3 | SQL best practices — HAVING with multiple aggregate conditions | 5.0 | Single HAVING with `COUNT(DISTINCT event_type) >= 5 AND COUNT(*) >= 100`; no subquery; partition filter on event_date >= CURRENT_DATE - INTERVAL '30' DAY included. Pin-perfect. |
| 4 | Improving complex SQL performance — dynamic filtering automatic | 4.25 | Core right: dynamic filtering, automatic, broadcast-build feeds probe-side runtime prune. INNER/RIGHT-only-not-LEFT/FULL is CORRECT. Semi-join-with-IN omission + "needs ANALYZE stats" overstated + `dynamicFilterSplitsProcessed` field-name approximation. |

---

## Per-question detail

### Q1 — dbt macro for tier-label + Trino concat type-error (SOFT WATCH RE-PROBE)

**Score 5.0** — **SOFT WATCH CLOSES**. Both iter1185 slips fixed cleanly under structurally different framing (per-row scalar conversion w/ string-building, integer→label not date→fiscal-quarter).

Responder's load-bearing facts:

**(a) dbt mechanism for shared utility function**
- Defines `{% macro tier_label(tier_num, range_text) %}` in `macros/` directory
- Called from each model as `{{ tier_label('tier', '"61-80"') }}`
- Correctly maps the Oracle stored-function shape → dbt Jinja macro
- Did NOT recommend an intermediate model + JOIN (the iter1185 mis-rec)

**(b) Trino concat type-error**
- "Trino `||` is VARCHAR-only; concatenating an integer directly = type error"
- Explicit WRONG/CORRECT pair: `CAST(tier_number AS varchar) || ' (61-80)'` vs `tier_number || ' (61-80)'`
- Applies to INTEGER/DECIMAL/DOUBLE — full type coverage
- Did NOT reproduce the iter1185 `CONCAT('FY', YEAR()+1, ...)` un-cast bigint bug

Verifications (trino.io + docs.getdbt.com):
- **dbt macros canonical for reusable scalar conversion**: dbt docs at [docs.getdbt.com/docs/build/jinja-macros](https://docs.getdbt.com/docs/build/jinja-macros) describe macros as "reusable piece of Jinja code that functions analogously to a function in programming languages" with the canonical `cents_to_dollars` example — the EXACT shape of the responder's `tier_label` and the engineer's tier-label ask.
- **Trino concat is varchar-only**: [trino.io/docs/467/functions/string.html](https://trino.io/docs/467/functions/string.html) defines `concat(string1, ..., stringN) → varchar` and "The `||` operator performs concatenation."
- **No implicit numeric→varchar coercion**: [trino.io/docs/467/functions/conversion.html](https://trino.io/docs/467/functions/conversion.html) verbatim: *"Trino will not convert between character and numeric types. For example, a query that expects a varchar will not automatically convert a bigint value to an equivalent varchar."*

**Soft watch CLOSES.** No resource fix. The iter1185 dual-slip was a one-off responder processing failure (r27 §7A.3 + §7A.3.1 were already pin-perfect on the exact content); today's structurally-different re-probe surfaces the correct macro recommendation and the correct CAST guard.

Scoring breakdown:
- Tech: 5.0/5 — both halves verified against docs
- Clar: 5.0/5 — WRONG/CORRECT pair explicit, beginner-friendly
- Practical: 5.0/5 — engineer can copy-paste the macro and the CAST form
- Complete: 5.0/5 — covers macro file location, call-site syntax, type coverage

---

### Q2 — map_values for threshold check on MAP<VARCHAR,DOUBLE>

**Score 4.125** — correct but under-routed. The primary ask is answered; the cleanest one-liner is missing.

Responder's load-bearing facts:
- `map_values(health_metrics) → ARRAY<DOUBLE>` correctly identified as the primary mechanism
- Two SQL forms shown, both valid:
  - **GROUP BY + MAX**: `CROSS JOIN UNNEST(map_values(m)) AS t(el)` + `GROUP BY service_id` + `MAX(el) > 0.9` in CASE
  - **WHERE EXISTS**: `WHERE EXISTS (SELECT 1 FROM UNNEST(map_values(m)) AS t(value) WHERE value > 0.9)`
- Both correctly flag rows where any value exceeds threshold without hard-coding keys

Verifications (trino.io):
- `map_values(map(K, V)) → array(V)` verified at [trino.io/docs/467/functions/map.html](https://trino.io/docs/467/functions/map.html)
- `any_match(array(T), function(T, boolean)) → boolean` verified at [trino.io/docs/467/functions/array.html](https://trino.io/docs/467/functions/array.html): *"Returns whether any elements of an array match the given predicate."*

**Style/routing nit (does NOT change PASS but caps the score)**: the direct one-liner is
```sql
WHERE any_match(map_values(health_metrics), v -> v > 0.9)
```
— a single boolean predicate, no UNNEST, no subquery, no GROUP BY. `any_match` was canonicalized iter1183 in the resources for "any element matches predicate" asks. The UNNEST+EXISTS form WORKS (correct results) but is verbose; the GROUP BY + MAX(el) > 0.9 variant is even more roundabout (forces a join+aggregation pipeline for what is a per-row boolean predicate).

Per `feedback_responder_broken_secondary_alternative.md` adjacent-family: NOT a broken alternative (both forms work), NOT a recurring pattern across the iteration, NOT a recall ceiling on the primary fact (map_values reached). Just secondary-form under-routing. NO resource fix. Re-probe under any-element-predicate framing next sweep to see if any_match surfaces cleanly.

Scoring breakdown:
- Tech: 4.5/5 — both forms valid; correct
- Clar: 4.0/5 — UNNEST+EXISTS is more cognitive load than any_match
- Practical: 4.0/5 — works but engineer copies verbose form
- Complete: 4.0/5 — primary `map_values` mechanism answered; cleanest one-liner missing

---

### Q3 — HAVING with multiple aggregate conditions

**Score 5.0** — pin-perfect.

Responder's load-bearing facts:
- Single HAVING with both aggregate conditions joined by AND
- Includes partition filter `WHERE event_date >= CURRENT_DATE - INTERVAL '30' DAY` (Trino-correct INTERVAL syntax)
- GROUP BY account_id
- Explicit "no subquery needed; HAVING runs after aggregation"

```sql
SELECT account_id, COUNT(DISTINCT event_type), COUNT(*)
FROM events
WHERE event_date >= CURRENT_DATE - INTERVAL '30' DAY
GROUP BY account_id
HAVING COUNT(DISTINCT event_type) >= 5 AND COUNT(*) >= 100
```

Verifications (trino.io):
- HAVING with multiple aggregate predicates joined by AND verified at [trino.io/docs/467/sql/select.html](https://trino.io/docs/467/sql/select.html): *"The `HAVING` clause is used in conjunction with aggregate functions and the `GROUP BY` clause to control which groups are selected."* SQL-standard combinator semantics apply.
- `COUNT(DISTINCT x)` valid Trino 467 single-arg distinct
- `INTERVAL '30' DAY` valid Trino 467 interval qualifier

Cites r23. No resource fix. Engineer can copy-paste and run.

Scoring breakdown:
- Tech: 5.0/5
- Clar: 5.0/5
- Practical: 5.0/5
- Complete: 5.0/5

---

### Q4 — Dynamic filtering for small-table-to-large-table join

**Score 4.25** — core right, minor approximations.

Responder's load-bearing facts (CORRECT):
- **Trino dynamic filtering** is the named feature
- **Automatic / default** (no config required)
- **Reads small table first, extracts key values at runtime, sends to workers scanning the large table**
- **Skip file splits whose min/max don't overlap before full scan** — correctly describes the runtime prune mechanism
- **INNER/RIGHT joins only, NOT LEFT/FULL** — **CORRECT** per docs
- **`EXPLAIN ANALYZE`** is the right diagnostic tool

Verifications (trino.io):
- [trino.io/docs/467/admin/dynamic-filtering.html](https://trino.io/docs/467/admin/dynamic-filtering.html): *"inner and right joins with `=`, `<`, `<=`, `>`, `>=` or `IS NOT DISTINCT FROM` join conditions, **and semi-joins with `IN` conditions** are supported."* LEFT and FULL OUTER NOT supported.
- Enabled by default in Trino 467; session property `enable_dynamic_filtering`
- EXPLAIN ANALYZE output shows dynamic filter info under a **"Dynamic filters:" section** within statistics for **ScanFilterProject** nodes — format includes filter ID, domain representation, collection time.

**Three minor approximations (collectively −0.75)**:
1. **Semi-join-with-IN omission**: the responder said "INNER/RIGHT joins only (not LEFT/FULL)" but missed that semi-joins with IN conditions are ALSO supported per docs. Not load-bearing for the engineer's INNER-join scenario but a completeness gap.
2. **"needs ANALYZE stats" overstated**: dynamic filtering runs at query-time using runtime build-side values; it does NOT strictly require ANALYZE statistics. ANALYZE stats help the **planner** decide broadcast-vs-partition join, which makes DF more effective on broadcast plans — but DF itself doesn't depend on ANALYZE. The responder's framing implies a hard requirement that isn't there.
3. **`dynamicFilterSplitsProcessed` field name approximation**: docs show DF info appears under a "Dynamic filters:" section within ScanFilterProject node statistics, not as a single field named `dynamicFilterSplitsProcessed`. The responder's field name is illustrative-not-verbatim; engineer running `EXPLAIN ANALYZE` will find the right info under "Dynamic filters:" but won't see that exact field name.

The "if no improvement, check elsewhere (correlated subquery, function-wrapped partition col)" close-out is good — correctly redirects to the partition-pruning-broken diagnostic family if DF isn't the bottleneck.

Cites r28 §5. No resource fix (the three nits are completeness shaves, not a defect or fabrication).

Scoring breakdown:
- Tech: 4.0/5 — INNER/RIGHT correct; semi-join omitted; ANALYZE requirement overstated
- Clar: 4.5/5 — runtime-prune mechanism explanation clear
- Practical: 4.5/5 — engineer gets the right action (it's automatic, check EXPLAIN ANALYZE for "Dynamic filters:")
- Complete: 4.0/5 — semi-join missed; field-name approximation

---

## Rubric updates

| Topic | Before | After | Question |
|---|---|---|---|
| Oracle PL/SQL → dbt+Trino migration | 4.4555 / 147 | (654.9585 + 5.0) / 148 = **4.4592 / 148** | Q1 |
| SQL query best practices for OLAP | 4.5770 / 264 | (1208.328 + 4.125 + 5.0) / 266 = **4.5783 / 266** | Q2, Q3 |
| Improving complex SQL performance on Trino with dbt | 4.5696 / 30 | (137.088 + 4.25) / 31 = **4.5593 / 31** | Q4 |

All required topics remain PASSED.

---

## Patterns / themes this iter

1. **Q1 SOFT WATCH CLOSES — iter1185 dual-slip was a one-off.** Both halves fixed on first re-probe under structurally different framing (integer tier-label vs date→fiscal-quarter). The responder reached for a dbt macro (the function analog) and explicitly CAST'd the integer to varchar before `||` with the un-cast form defanged. r27 §7A.3 + §7A.3.1 already contained the pin-perfect content; iter1185 was a findability/processing failure not a resource defect. No resource fix needed; no recurrence in 1 iteration.

2. **Q2 under-routing — any_match one-liner missed.** Responder gave correct UNNEST+EXISTS / UNNEST+GROUP BY+MAX forms but missed the `any_match(map_values(m), v -> v > 0.9)` one-liner that iter1183 canonicalized. NOT a broken-alternative or fabrication; just secondary-form under-routing. Per `feedback_responder_broken_secondary_alternative.md`-adjacent family but milder. Re-probe under any-element-predicate framing next sweep to see if any_match cross-routes from map_values context.

3. **Q4 minor approximations on dynamic filtering — semi-join + ANALYZE requirement.** Core "automatic, runtime-prune, INNER/RIGHT not LEFT/FULL" CORRECT per docs. Three small completeness shaves: (a) semi-join-with-IN also supported but not mentioned, (b) "needs ANALYZE stats" overstates the requirement (DF works at runtime; ANALYZE helps broadcast-decision not DF itself), (c) `dynamicFilterSplitsProcessed` field name approximation vs docs' "Dynamic filters:" section. Not load-bearing for the engineer; no resource fix.

4. **Cushion check.** Thinnest current topics remain dbt snapshots SCD2 (4.1549) and Query performance basics (4.1869). Oracle migration cushion now +0.9592 over threshold (slight recovery from iter1185 drag). SQL best practices cushion very healthy at +1.0783.

5. **Watch closure pattern continues.** 11th consecutive watch closure on the 1st-re-probe-CLOSE pattern (after iter1185 r17 close, iter1184 r17 reach, iter1183 LEAD/LAG, iter1182 r07 percent-of-total, etc.). No active watches carry into iter1187.

---

## Recommendation for iter1187

- **No FIX-A.** All four answers PASS; the one soft-watch closes cleanly.
- **Breadth probe** thinnest topics: dbt snapshots SCD2 (4.1549, n=19) and Query performance basics (4.1869, n=27). Storage tiering (4.1779, n=13) close behind.
- **Optional re-probe**: any-element-predicate framing on an array/map column to test whether `any_match` cross-routes from r09 map-context to r23 array-context (Q2 under-routing follow-up). Low priority — not a defect, just a recall ceiling.
