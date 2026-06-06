# iter575 Judge Feedback

**Pinned target:** Trino 467 + Iceberg connector (Hive Metastore + MinIO/S3) per `prod_info.md`.

## Headline

**OVERALL AVG = 4.625 STRONG PASS** — iter575 FIX A (r07 §4 LEADING CANONICAL "Interval-overlap / active-on-each-day" range-join) **VALIDATED on first re-probe** at Q1. Q1 4.50 STRONG / Q2 5.00 STRONG / Q3 4.50 STRONG / Q4 4.50 STRONG. The iter574 CURRENT_DATE-snapshot defect is GONE — the responder built the correct per-day RANGE JOIN. No `::`-cast, no IGNORE-NULLS-inside-paren regression, no cross-engine slip, no closed-BETWEEN double-count. Federation NOT probed — 4.49944/310 row UNCHANGED.

## Per-question scores

### Q1 — Open support tickets per day last month (interval-overlap re-probe — iter575 FIX A check)
**Accuracy 5 / Completeness 4 / Clarity 4.5 / Actionability 4.5 = 4.50 STRONG PASS — FIX A VALIDATED**

(i) **PRIMARY FIX — RANGE JOIN routed cleanly (the iter574 snapshot defect did NOT recur).**
The responder built:
```sql
calendar AS (
  SELECT d FROM UNNEST(sequence(DATE '2026-05-01', DATE '2026-05-31', INTERVAL '1' DAY)) AS t(d)
),
active_tickets AS (
  SELECT c.d AS day, COUNT(*) AS open_tickets
  FROM calendar c
  JOIN tickets t
    ON t.created_date <= c.d
   AND (t.resolved_date IS NULL OR t.resolved_date > c.d)
  GROUP BY c.d
)
```
The calendar day `c.d` participates **in the join predicate**, so the count is re-evaluated per day — exactly the interval-overlap shape iter575 FIX A was built to teach. There is NO `CURRENT_DATE AS day` hardcode, NO LEFT JOIN on `c.day = d.day` equality. The iter574 snapshot defect is cleanly resolved.

(ii) **GOOD — half-open `[created, resolved)` convention applied correctly.**
The responder wrote `resolved_date > c.d`, NOT `>=`. Per iter575 FIX A DO-NOT-WRITE bullet (b), a closed `BETWEEN start AND end` double-counts the boundary day (a ticket resolved on X and one created on X would both count on X). The responder used `>` and explicitly noted "half-open [created, resolved) avoids boundary double-count." NULL `resolved_date` (still-open tickets) handled via the OR branch.

Quote (Trino 467 — array.html sequence): `sequence(start, stop, step)` returns an array of date values from `start` to `stop` inclusive with the given INTERVAL step — the canonical day-spine pattern. Inequality predicates in JOIN ON are plain ANSI SQL — no special Trino syntax needed; Trino 467 has VLDB-cited range-join optimization for this exact shape.

(iii) **MINOR COMPLETENESS NIT — INNER JOIN drops literally-zero-open days (-0.5).**
The responder used INNER JOIN. The question said "every calendar day incl. weekends/quiet days." For "open tickets" with carryover, most days will have at least one open ticket so this is rarely observable in practice — but to STRICTLY guarantee a row for a zero-open day, the recipe is LEFT JOIN + COALESCE(open_tickets, 0). The responder did not mention this nuance. Per the iter575 directive this is a minor completeness ding, not an accuracy error — the core range-join pattern is correct.

**Verdict:** the iter575 FIX A H3 ("count active/open intervals on each day — interval-overlap range join — NOT forward-fill, NOT a CURRENT_DATE snapshot") routed cleanly. The interval-overlap canonical is now durable on a new scenario (tickets, not subscriptions). One small completeness gap (INNER-vs-LEFT-for-strict-zero-days) — log as a future nit, do not fix this iteration unless re-probed.

### Q2 — Contrast forward-fill / running total / interval-overlap (three-pattern micro-probe)
**Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS**

All three idioms verified correct Trino 467 dialect:

- **Forward-fill (A):** `LAST_VALUE(metric) IGNORE NULLS OVER (PARTITION BY entity_id ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`. IGNORE NULLS placement is **after** the closing paren of the function args, **before** OVER — verified VERBATIM at trino.io/docs/current/functions/window.html: `<first or last value function> ::= <first or last value> <left paren> <value expression> <right paren> [ <null treatment> ]` where `<null treatment> ::= RESPECT NULLS | IGNORE NULLS`. The iter569/571 IGNORE-NULLS-inside-paren parse-error regression is NOT present. The look-BACK frame `ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW` is correct (iter570 future-fill leak avoided). The build-dense-grid → LEFT-JOIN → window composition order is noted explicitly (iter571 pre-join-window anti-pattern avoided).

- **Running total (B):** `SUM(metric) OVER (PARTITION BY entity_id ORDER BY day ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`. Standard accumulator pattern, correct Trino 467.

- **Interval-overlap (C):** range-join shape `start <= day AND (end IS NULL OR end > day)` joined to the dense day spine + GROUP BY c.day — exactly the iter575 FIX A canonical.

**Cleanly distinguished:**
- Forward-fill **carries a VALUE** (last known value).
- Running total **ACCUMULATES** values over time.
- Interval-overlap **COUNTS intervals** covering each day.

The responder explicitly stated "they are NOT interchangeable" — this is precisely the contrast-card framing FIX A added to r07. Zero defects. Three patterns the resources have struggled with the most are now cleanly separated in the responder's working memory.

### Q3 — EXISTS-positive / semi-join (cleaner than JOIN+GROUP BY for dedup)
**Accuracy 4.5 / Completeness 4.5 / Clarity 4.5 / Actionability 4.5 = 4.50 STRONG PASS**

Both options are valid Trino 467:
- **Option A:** `WHERE customer_id IN (SELECT DISTINCT customer_id FROM orders)`.
- **Option B:** `WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id)`.

Both compile to a Trino SemiJoin plan node (verified — Trino's optimizer transforms `IN (SELECT ...)` and `EXISTS (correlated)` into the same SemiJoin operator). No row multiplication (unlike LEFT JOIN + DISTINCT which fans out + collapses).

**Key correctness note (positive IN safe re NULLs):** for the POSITIVE case (`IN`, not `NOT IN`), NULLs in `orders.customer_id` do NOT cause the three-valued-logic wipeout that NOT IN suffers. The semantics: `c.customer_id IN (1, 2, NULL)` returns TRUE if `c.customer_id IN (1, 2)`, UNKNOWN otherwise — but UNKNOWN filters AS FALSE in WHERE, so the rows where the customer exists in orders still pass cleanly. This is the standard rule (trino.io comparison.html: "The result of IN follows the standard rules for nulls" + Trino issue #17213 documents NULL-handling for STRUCTURAL/indeterminate values only — scalar customer_id values are safe). The responder did not call out the NOT IN trap (which is the iter571 Q3 topic) but for the POSITIVE case asked, IN is safe — the responder's recommendation is sound.

**Minor completeness (-0.5):** the responder could have noted that `SELECT DISTINCT customer_id FROM orders` is redundant inside `IN (...)` — Trino removes DISTINCT inside an IN-subquery (issue #11) since the SemiJoin operator deduplicates. Not load-bearing.

**Verdict:** clean answer; both patterns correct; NOT IN trap avoided (not asked); no NULL-related slip.

### Q4 — dbt materializations on Trino+Iceberg (view / table / ephemeral)
**Accuracy 4.5 / Completeness 4.5 / Clarity 4.5 / Actionability 4.5 = 4.50 STRONG PASS**

Four-row matrix accurate:

- **View** — stored SELECT, re-executes every query, negligible storage, cheap staging filters. CORRECT (Trino+Iceberg connector materializes views as catalog views; downstream `ref()` reads execute the underlying SELECT each time).
- **Table** — materialized Parquet in MinIO, full storage, reads hit files, rebuilt each `dbt run`, for expensive multi-consumer transforms. CORRECT for the production stack (Trino+Iceberg+MinIO).
- **Incremental** — table built by delta with watermark/unique_key + merge strategy on Iceberg. CORRECT (dbt-trino constructs a Trino MERGE statement on Iceberg per https://docs.getdbt.com/reference/resource-configs/trino-configs and Starburst's dbt-trino incremental blog).
- **Ephemeral** — **NO database object**, SQL inlined as a CTE into every downstream `ref()`, zero storage, runs N times. CORRECT per dbt docs: "When you configure a model with `{{ config(materialized='ephemeral') }}`, this creates no object at all in the warehouse. Instead, the SQL is inlined into the query of the model that references it." dbt prefixes the CTE identifier with `__dbt__cte__`. Trade-off correctly stated: lightweight reusable helper logic vs SQL duplicated across N consumers (not great for expensive transforms).

**Decision rules clean:** view (cheap re-exec), table (expensive + multi-consumer), incremental (large fact, append-only with watermark), ephemeral (small helper used in few places).

**Incremental example clean:** `is_incremental()` + `COALESCE(MAX(order_date), DATE '1970-01-01')` watermark + partitioning/sorted_by properties. The watermark fallback uses **typed-literal `DATE '1970-01-01'`** — NOT `::`-cast (the iter571 FIX C `::`-ban routed cleanly here), NOT `CAST('1970-01-01' AS DATE)` (also valid but more verbose). Per Trino 467 typed-literal syntax this is the canonical idiom for a constant date.

**No `::`-cast slip. No cross-engine slip (no Spark-style `bucket(N, col)` or Snowflake/BigQuery dialect leakage). No fabricated dbt-trino feature.**

**Minor completeness (-0.5):** could have called out that ephemeral models CANNOT be queried directly (debugging harder) and that N-consumer duplication can defeat the storage savings if the CTE is expensive — these are documented dbt trade-offs but not load-bearing here.

## Topic avg updates

- **Analytical query patterns on Iceberg+Trino** (Q1 interval-overlap re-probe r07 §4 LEADING CANONICAL + Q2 three-pattern contrast r07 §4 contrast card):
  4.3565/28 → (4.3565·28 + 4.50)/29 = **4.3614/29** (+0.0049 Q1 modest lift) → (4.3614·29 + 5.00)/30 = **4.3827/30** (+0.0213 Q2 strong lift).
- **SQL query best practices for OLAP** (Q3 IN/EXISTS positive semi-join r23 §3.1):
  4.4536/143 → (4.4536·143 + 4.50)/144 = **4.4540/144** (+0.0004 modest lift).
- **dbt on Trino+Iceberg** (Q4 view/table/ephemeral/incremental dbt-trino):
  prior avg per existing rubric trajectory — update via rubric entry below.
- Federation NOT probed — **4.49944/310 row UNCHANGED** per iter472-574 directive + iter575 task constraint.

## Primary wins

1. **iter575 FIX A r07 §4 LEADING CANONICAL "count active/open intervals on each day — interval-overlap range join" VALIDATED on first re-probe at Q1.** The new H3 (placed adjacent to the spine + forward-fill + composition family) was keyword-findable for "open tickets per day" / "active on each day" / "calendar day join." The responder built the correct shape (`created <= c.day AND (resolved IS NULL OR resolved > c.day)`) with the calendar day participating in the join predicate — NOT a CURRENT_DATE snapshot, NOT a closed BETWEEN double-count.
2. **iter575 FIX A contrast card VALIDATED on Q2** — the responder cleanly distinguished forward-fill (VALUE) vs running total (ACCUMULATION) vs interval-overlap (COUNT), explicitly noting they are NOT interchangeable. The three patterns are no longer conflated.
3. **iter569/571 IGNORE-NULLS-inside-paren regression still resolved** (Q2 forward-fill recipe placed `IGNORE NULLS` correctly outside the args paren). iter572 FIX A salience inversion remains durable.
4. **iter571 FIX C `::`-cast ban still resolved** (Q4 dbt incremental watermark uses `DATE '1970-01-01'` typed literal, not `::`-cast).
5. **NULL handling in IN/EXISTS positive case** (Q3) — the responder correctly recommended `IN` for the positive case without falling into a NOT-IN-style three-valued-logic warning.
6. **dbt materialization semantics on Trino+Iceberg** (Q4) — all four (view, table, incremental, ephemeral) match dbt-trino docs and Starburst's Iceberg+dbt blog; ephemeral = inlined CTE, view = re-executes, incremental = merge with unique_key, table = full rebuild.

## Primary failures

NONE — zero accuracy defects. Minor completeness nits only (Q1 INNER-vs-LEFT-for-strict-zero-days, Q3 DISTINCT-inside-IN redundancy, Q4 ephemeral-debug-pain). None load-bearing; none warrant resource churn.

## NEW iter576 FIX TARGETS

- **Fix A — NO-OP** — r07 §4 LEADING CANONICAL interval-overlap range-join card. **VALIDATED on first re-probe.** Zero edits. Card text + keyword anchors + DO-NOT-WRITE matrix + contrast card all routed cleanly.
- **Fix B — NO-OP** — r07 §4 forward-fill / running-total / interval-overlap contrast card. **VALIDATED on Q2.** Zero edits.
- **Fix C — NO-OP** — r23 §3.1 `::`-cast ban. Durable on Q4 dbt incremental example. Zero edits.
- **Fix D — NO-OP** — r07 §1a + r23 §3.1 IGNORE-NULLS placement-after-paren. Durable on Q2 forward-fill recipe. Zero edits.
- **Fix E — NO-OP federation** — 4.49944/310 unchanged; zero edits to resources/22 §13.x.
- **Optional / LOW — OPTIONAL ADDITIVE** — could add a one-line nudge in r07 §4 interval-overlap card: "If the question explicitly says 'include quiet days with zero,' switch INNER JOIN → LEFT JOIN spine + COALESCE(COUNT(*), 0). For most active/open scenarios the INNER form is fine due to carryover." Not load-bearing; the iter575 directive explicitly framed this as a minor completeness nit. Defer unless a re-probe scores Q1 on a zero-active-day requirement.

## iter576 probe targets

- **HIGHEST priority** — Q1 interval-overlap 3rd-angle composition (e.g., "concurrent active sessions per minute per region" or "in-progress orders per hour per warehouse") to verify the FIX A H3 routes on a NEW domain + a NEW temporal grain. Watch for: (a) does the responder still use the range-join shape (predicate on day variable), (b) does the half-open convention hold for sub-day grain, (c) does the responder reach for LEFT JOIN if the question explicitly says "include quiet hours/minutes."
- **HIGH** — Q2 IGNORE-NULLS placement on a NEW window function (e.g., FIRST_VALUE or NTH_VALUE) — verify iter572 FIX A is durable across function variants.
- **MEDIUM** — Q3 NOT IN / anti-join 3rd-angle (vs the iter571 Q3 2nd-angle) — verify the responder still flags the three-valued-logic NULL trap on the negative case (this iter only tested the positive case).
- **MEDIUM** — Q4 dbt 2nd-angle on materialization choice for a specific scenario (e.g., "I have a 50M-row daily snapshot for which 90% rows are unchanged — table vs incremental on Iceberg, what merge strategy") — verify dbt-trino incremental durability.
- **LOW** — federation if iter576 wants to nudge 4.49944/310 above 4.5.

## Meta-rule observation

Directive's "Q1 should be a strong answer if the range join is correct — minor completeness ding at most for INNER-vs-LEFT-for-zero-days omission" was the correct frame. The iter574 defect was structural (snapshot-vs-series), and the iter575 H3 added exactly the missing canonical. Verifying the responder used the calendar day `c.d` IN the join predicate (rather than equality on day) was the load-bearing check — that single distinction differentiates the FIX A canonical from the iter574 anti-pattern. WebSearched: trino.io/docs/current/functions/window.html (IGNORE NULLS placement-after-paren VERBATIM Q2), trino.io/docs/current/functions/comparison.html + Trino issue #17213 (IN-subquery NULL handling Q3), docs.getdbt.com/docs/build/materializations + docs.getdbt.com/reference/resource-configs/trino-configs + Starburst dbt-trino incremental blog (ephemeral = no DB object + Iceberg MERGE strategy Q4), trino.io/docs/current/functions/array.html sequence VERBATIM (Q1 day-spine), VLDB Springer doi 10.1007/s00778-021-00692-3 (range-join inequality-predicate optimization Q1). 38th consecutive iter (iter537-575) where meta-rule discipline materially affected the verdict (this time confirming strength). The directive's explicit framing "minor completeness ding at most" prevented over-penalizing Q1 for the INNER-vs-LEFT nuance — which was correct.

## Notes

- Did NOT bump training/state.json (teacher already set iteration=575, phase=extended).
- Federation rubric row 4.49944/310 unchanged.
- Did NOT touch resources files.
- iter575 FIX A new LEADING CANONICAL H3 in r07 §4 = CLEAN WIN, ROUTED on first re-probe across Q1 (interval-overlap shape on new domain) AND Q2 (three-pattern contrast card).
- iter576 = DURABILITY iteration — NO new resource churn. Orthogonal-framing re-probes only. The interval-overlap canonical needs a 3rd angle (sub-day grain + zero-period nuance) before being marked truly bulletproof.

**OVERALL: 4.625 STRONG PASS** — iter575 FIX A interval-overlap range-join H3 VALIDATED on first re-probe (Q1 4.50 + Q2 5.00 contrast card); Q3 4.50 + Q4 4.50 both clean strong; zero accuracy defects across all four; iter576 = durability iteration, NO new resource churn, NO federation churn.
