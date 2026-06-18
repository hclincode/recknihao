# Judge Feedback — iter1061 (2026-06-18)

Stack: Trino 467 + Iceberg + Hive Metastore + MinIO + Spark + dbt-trino + OPA.
All facts verified BOTH directions against RAW git-tag 467 source + trino.io/docs.

## Overall: 4.13 PASS (overall avg governs; no per-question veto)

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 element_at vs subscript | 5 | 5 | 5 | 5 | 5.00 |
| Q2 RANK gaps vs DENSE_RANK | 5 | 4.875 | 5 | 5 | 4.969 |
| Q3 "every row in group" check | 1 | 1.5 | 3 | 1 | 1.625 |
| Q4 width_bucket bucketing | 5 | 4.75 | 5 | 5 | 4.938 |

Overall = (5.00 + 4.969 + 1.625 + 4.938) / 4 = **4.133 PASS**

---

## Q1 — Safe map key lookup (5.00)
CORRECT and verified. `element_at(map, key)` "Returns value for given key, or NULL if the key is not contained in the map" — the `[]` subscript operator "throws an error if the key is not contained in the map" (both quoted from map.md). COALESCE fallback is the idiomatic next step. Textbook.
Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/map.md

## Q2 — RANK with gaps after ties (4.969)
CORRECT and verified. `rank()`: "tie values in the ordering will produce gaps in the sequence" (matches the user's "two tie for 2nd → next is 4th"). `dense_rank()`: "tie values do not produce gaps." `row_number()`: unique sequential. The pre-aggregated `SUM(amount) ... GROUP BY region, customer_id` subquery feeding `RANK() OVER (PARTITION BY region ORDER BY total_revenue DESC)` is the correct structure. Minor completeness ding only (no NULLS-ordering aside, not required).
Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/window.md

## Q3 — "Does EVERY user on the plan have 'audit_log'?" (1.625) — CRITICAL DEFECT
**VERDICT: BOTH responder HAVING forms are INVALID Trino 467.**

The query is `... GROUP BY plan_type HAVING all_match(ARRAY['audit_log'], x -> contains(feature_flags, x))` (and the `array_except` alternative). Both reference `feature_flags` — a per-ROW column that is NEITHER a grouping key (only `plan_type` is grouped) NOR wrapped in an aggregate. In a GROUP BY query, every column in HAVING must be a grouping column or inside an aggregate; a raw non-grouped column raises:

> 'feature_flags' must be an aggregate expression or appear in GROUP BY clause

Confirmed against Trino HAVING semantics (issue #26915 + the standard GROUP-BY scope rule, which extends the SELECT-list rule to HAVING). The array helper functions themselves (`all_match`, `contains`, `array_except`, `cardinality`) DO exist in 467 — but the construct as written never typechecks. The responder confused a row-level array predicate with a group-level "all rows satisfy X" aggregation.

**The CORRECT construct** for "did every row in the group satisfy a predicate" is the boolean aggregate **`bool_and`** (verified present in 467 aggregate.md: "Returns TRUE if every input value is TRUE, otherwise FALSE"):

```
SELECT plan_type
FROM users
GROUP BY plan_type
HAVING bool_and(contains(feature_flags, 'audit_log'))
```

(`bool_and(all_match(ARRAY['audit_log'], x -> contains(feature_flags, x)))` is an equivalent over-engineered variant for a multi-flag requirement.) `bool_and` is the canonical SQL tool for the universal-quantifier-over-group pattern; `bool_or` is its existential counterpart.

Scoring: Accuracy 1 (does not run), Completeness 1.5 (the actual answer — bool_and — is absent), Clarity 3 (prose is clear, code is wrong), Actionability 1 (engineer who copies either form hits a planner error).

Sources:
- https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/aggregate.md (bool_and / bool_or)
- https://github.com/trinodb/trino/issues/26915 (HAVING scope / must-be-grouped-or-aggregate)

## Q4 — Bucket subscriptions by days-lasted (4.938)
CORRECT and verified. `width_bucket(x, bins_array)` exists in 467 math.md ("Returns the bin number of x according to the bins specified by the array bins ... sorted ascending"). With `ARRAY[30.0, 90.0, 180.0]` (3 boundaries) the result is buckets 0..3: 0=<30, 1=[30,90), 2=[90,180), 3=>=180 — matches the requested 0-30 / 31-90 / 91-180 / over-180 bands (half-open semantics fine). `COALESCE(cancelled_at, current_date)` correctly substitutes today's date for still-active subscriptions so they keep accruing duration. Wrapping labels in a CASE/CTE is the right readability step. Minor completeness ding only (didn't note bins must be doubles — but the literals are already `30.0` doubles, so handled implicitly).
Source: https://raw.githubusercontent.com/trinodb/trino/467/docs/src/main/sphinx/functions/math.md

---

## Source-verified dialect notes this iteration
- `element_at(map,key)` → NULL on miss; `map[key]` subscript → throws on miss. (map.md, both directions confirmed)
- `rank()` produces gaps after ties; `dense_rank()` does not; `row_number()` always unique. (window.md)
- `bool_and(boolean)` / `bool_or(boolean)` exist in 467 — the correct group-level universal/existential quantifier tools. (aggregate.md)
- `width_bucket(x, array)` exists; n boundaries → buckets 0..n, lower-inclusive half-open. (math.md)
- **HAVING rule (Q3 root):** a raw non-grouped column in HAVING is a planner error in 467. This is the recurring "row-predicate masquerading as a group-predicate" trap — the boolean-aggregate (`bool_and`) is the fix, not an array helper inside HAVING.

## Recommendation for teacher
Q3 is a genuine ACCURACY defect, not responder padding: the LEAD answer itself is invalid. Check whether resources teach the **`bool_and`/`bool_or` "every/any row in the group satisfies X" pattern** with a findable keyword anchor (e.g. "for each group, did ALL rows..."). If `all_match`/`array_except` are documented for ALL-of-set membership but `bool_and` is NOT cross-referenced for the across-rows-in-a-group case, the responder will keep reaching for the array helper inside HAVING. Recommend a LIGHT additive card: route "every/all USERS/ROWS in a group satisfy X" → `bool_and(predicate)`; explicitly contrast with the row-level array `all_match` (all ELEMENTS of one array). Re-probe Q3 from a second angle (e.g. "every order in each region was paid") next sweep before considering it closed.
