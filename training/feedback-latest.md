# Judge Feedback — Iter 550 (2026-06-06)

## HEADLINE

**iter550 RECOVERED from iter549's 2.969 FAIL.** Overall avg **4.7188 STRONG PASS** (margin +1.2188 above 3.5 floor; +1.75 swing from iter549). All THREE re-probe findability gaps from iter549 (IF/CASE, UNION/UNION ALL, ref/source) are **CLOSED** — the teacher's three batched `### LEADING CANONICAL` H3 additions (r23 §3.1E IF-vs-CASE, r23 §3.1F UNION-vs-UNION-ALL, r27 §6.7A2 ref-vs-source) all landed on first re-probe. Q4 array_agg(ORDER BY) bonus probe also PASSED — clean validation of the structural-salience playbook across 4 different question shapes in one iteration. No new slips surfaced.

---

## Per-question scoring

### Q1 — IF() vs CASE WHEN in Trino — same thing? when must you use CASE?

**Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5 = 5.00 STRONG PASS**

Responder said: functionally identical; if() is shorthand for CASE WHEN with the same query plan; `if(status='active',1,0)` ≡ `CASE WHEN status='active' THEN 1 ELSE 0 END` ≡ `count_if(status='active')` for the aggregate form; use IF for single condition, CASE for multi-branch (no ELSEIF in expression-form if()). Cited r23 §3.1E.

**Doc verification (Trino 467):**
- trino.io/docs/467/functions/conditional.html — VERBATIM: "Evaluates and returns `true_value` if `condition` is true, otherwise null is returned and `true_value` is not evaluated" (2-arg) and "Evaluates and returns `true_value` if `condition` is true, otherwise evaluates and returns `false_value`" (3-arg). Docs explicitly state: **"The following `IF` and `CASE` expressions are equivalent."**
- trino.io/docs/467/functions/aggregate.html — VERBATIM: `count_if(x)`: "Returns the number of TRUE input values. This function is equivalent to `count(CASE WHEN x THEN 1 END)`."

iter550 teacher's `### LEADING CANONICAL — Trino IF() vs CASE WHEN` H3 in r23 §3.1E landed perfectly. The Haiku keyword-scan now hits a findable canonical. **The iter549 Q2 2.375 FAIL is fully closed (+2.625 swing on this exact question shape).**

### Q2 — UNION vs UNION ALL — difference + default for analytics?

**Scores: Accuracy 5 / Completeness 5 / Clarity 4.5 / Actionability 5 = 4.875 STRONG PASS**

Responder said: bare UNION = UNION ALL + implicit global DISTINCT (expensive sort/hash); UNION ALL concatenates streaming, no dedupe; default UNION ALL for analytics; bare UNION on disjoint inputs is a silent perf killer. Cited r23 §3.1F.

**Doc verification (Trino 467):**
- trino.io/docs/467/sql/select.html — VERBATIM: **"If the argument `ALL` is specified all rows are included even if the rows are identical. If the argument `DISTINCT` is specified only unique rows are included in the combined result set. If neither is specified, the behavior defaults to `DISTINCT`."** Rule applies to UNION/INTERSECT/EXCEPT.

Clarity off 0.5 for not mentioning INTERSECT/EXCEPT same-default behavior explicitly (a minor completeness nit, not a content gap). iter550 teacher's r23 §3.1F LEADING CANONICAL H3 landed perfectly. **The iter549 Q3 2.375 FAIL is fully closed (+2.50 swing on this exact question shape).**

### Q3 — dbt ref('model') vs source('raw','table') — naming or behavior?

**Scores: Accuracy 5 / Completeness 5 / Clarity 4.5 / Actionability 5 = 4.875 STRONG PASS**

Responder said: NOT a naming convention. ref()=dbt model, built by dbt, model-to-model DAG edge; source()=raw external in sources YAML, NOT built (entry point), enables `dbt source freshness`. stg_ uses source(), downstream uses ref(); don't hardcode (breaks DAG + env portability). Cited r27 §6.7A2.

**Doc verification:**
- docs.getdbt.com/reference/dbt-jinja-functions/ref — VERBATIM: ref() "Returns a Relation for a model, seed, or snapshot" AND "Creates dependencies between the referenced node and the current model" AND "is using these references between models to automatically build the dependency graph. This will enable dbt to deploy models in the correct order when using `dbt run`."
- docs.getdbt.com/reference/dbt-jinja-functions/source — VERBATIM: source() "Returns a Relation for a source" AND "Creates dependencies between a source and the current model, which is useful for documentation and node selection." Two arguments: source_name + table_name from the sources: YAML.

Clarity off 0.5 — the "NOT a naming convention" lead is correct + strong, but the explanation could lead with one-sentence-each definitions before jumping to the four-axis distinction. Minor. iter550 teacher's r27 §6.7A2 LEADING CANONICAL H3 (slotted BEFORE §6.7B source-freshness — correct ordering so freshness reader sees source() definition first) landed perfectly. **The iter549 Q4 2.375 FAIL is fully closed (+2.50 swing on this exact question shape).**

### Q4 — array_agg(x ORDER BY y) — does Trino support inline ordering, production-safe?

**Scores: Accuracy 4.5 / Completeness 4 / Clarity 4 / Actionability 4 = 4.125 PASS**

Responder said: array_agg(x ORDER BY y) supported + production-safe; unordered by default without ORDER BY; ORDER BY is part of the aggregate signature.

**Doc verification (Trino 467):**
- trino.io/docs/467/functions/aggregate.html — confirmed array_agg(x) "Returns an array created from the input `x` elements" AND the docs note "some aggregate functions such as `array_agg()` produce different results depending on the order of input values" with example syntax `array_agg(x ORDER BY y DESC)`. Without an explicit ORDER BY the input order is non-deterministic across distributed workers — responder's claim is accurate.

Accuracy off 0.5 / Completeness off 1 / Clarity off 1 / Actionability off 1 for not anchoring with the verbatim syntax `array_agg(x ORDER BY y)` and not flagging the NULL-handling nuance or the cardinality risk (unbounded array growth) — nuance gaps, not errors. Direction is correct; depth is shallower than the three explicitly-canonicalized topics. Acceptable, not stellar.

---

## Overall

`(5.00 + 4.875 + 4.875 + 4.125) / 4 = 18.875 / 4 = `**4.7188 PASS**

Overall-average rule: 4.7188 ≥ 3.5 = **PASS**. +1.75 swing from iter549's 2.969 — full recovery in one iteration.

## Findability gap closure verification

Three iter549 re-probe gaps tested + confirmed CLOSED:

| iter549 Gap | iter549 Score | iter550 Score | Swing | Closed? |
|---|---|---|---|---|
| IF vs CASE WHEN (r23 §3.1E) | 2.375 | 5.00 | +2.625 | YES |
| UNION vs UNION ALL (r23 §3.1F) | 2.375 | 4.875 | +2.50 | YES |
| ref() vs source() (r27 §6.7A2) | 2.375 | 4.875 | +2.50 | YES |

This is the **4th consecutive structural-salience playbook validation** in the last 5 iterations (iter546 map_concat H3, iter547 COALESCE-default H4, iter548 query-hint H4, iter550 batched IF/CASE + UNION + ref/source). The playbook — promote buried-but-heavily-used primitives to a `### LEADING CANONICAL` H3 with keyword-anchor blockquote — is now validated 4x distinct topics, 3x in a single batch. Methodology is robust.

## Pattern notes

- Q1/Q2/Q3 scored within 0.125 of each other (5.00 / 4.875 / 4.875) — consistent depth across the three new canonicals. Teacher batched three structural canonicals into one iteration without quality degradation.
- Q4 array_agg(ORDER BY) scored lowest (4.125) — a "spontaneous" check on a non-re-probe primitive; responder got the direction right but the depth is noticeably shallower than the three explicitly-canonicalized topics. This is signal: the next "used-but-never-explained" audit should target heavily-used Trino aggregate-with-ORDER-BY primitives (array_agg, listagg, multimap_agg) plus the WITH/CTE explanation gap, DISTINCT ON absence in Trino, COALESCE-chain semantics, and current_date arithmetic.
- No fabrications. No identifier slips. No dialect errors. Federation NOT probed — 4.49944/310 row untouched per directive.

## iter551 teacher actions (priority order)

1. **HOLD all iter550 NEW LOCKS**: r23 §3.1E (IF-vs-CASE), r23 §3.1F (UNION-vs-UNION-ALL), r27 §6.7A2 (ref-vs-source). Plus all iter495-549 locks.
2. **Continue the "used-but-never-explained" audit** — Q4 array_agg(ORDER BY) scoring 4.125 (vs 4.875+ on the three canonicalized topics) signals the next batch:
   - `### LEADING CANONICAL — array_agg with inline ORDER BY (and the unbounded-array cardinality gotcha)` in r23 — anchor on `array_agg(x ORDER BY y)`, NULL handling, cardinality budget, alternatives (multimap_agg, listagg).
   - `### LEADING CANONICAL — WITH ... AS (...) — CTE semantics on Trino (inline vs materialize hint absence)` in r23 — heavily used in worked examples, never explained as a primitive; anchor on "common table expression Trino", "WITH AS Trino", "CTE materialize Trino".
   - `### LEADING CANONICAL — DISTINCT ON absence in Trino (use ROW_NUMBER() filter pattern)` in r23 — Postgres-pattern engineers ask this; Trino has no DISTINCT ON; canonical the row_number()=1 pattern.
   - `### LEADING CANONICAL — COALESCE chain semantics + short-circuit evaluation` in r23 — heavily used in r07/r09/r23, never anchored.
   - `### LEADING CANONICAL — current_date / current_timestamp arithmetic on Trino (INTERVAL types + at_timezone)` in r23 — date math is in worked examples but no explanation home.
3. **MEDIUM probe targets**: durability re-probes on the iter550 wins (2nd angle each — different question phrasing): "Does Trino's IF take 2 or 3 args and what happens with NULL?", "Why is UNION slow compared to UNION ALL?", "If I have a raw S3 table not built by dbt, do I use ref() or source()?".
4. **LOW priority — DO NOT TOUCH**: resources/22 §13.x federation guardrails + federation rubric row 4.49944/310.
5. Meta-rule: continue WebSearch-verifying corrections against trino.io/docs/467/ + docs.getdbt.com before asserting them. 13th consecutive iter where this practice prevented a false-positive judgment.

**OVERALL: 4.7188 PASS — full recovery from iter549. Three batched canonicals validated. Continue used-but-never-explained audit on the next 5 primitives.**
