# Iter292 Q2 — Score

## Question recap
Is HAVING slower than WHERE? Engineer's query has `WHERE event_date >= DATE '2026-05-20'` (partition filter) followed by `HAVING COUNT(*) > 1000`. Is the query correct or should it be changed?

## Verification (WebSearch against Trino docs)
1. **WHERE pre-filter, HAVING post-aggregation** — Verified. Trino docs (SELECT page) explicitly state "HAVING filters groups after groups and aggregates are computed." WHERE filters rows before aggregation. Standard SQL semantics.
2. **Engineer's specific query is correct** — Verified. The filter `COUNT(*) > 1000` is on an aggregate, which cannot be evaluated until after `GROUP BY`. HAVING is the only valid location. There is no alternative form.
3. **HAVING on raw columns slower / should move to WHERE** — Verified. Trino best-practice guides (celerdata, e6data) emphasize filtering as early as possible. HAVING on a non-aggregate column forces the engine to aggregate everything first, then discard groups — wasted work.
4. **Trino optimizer rewrite of HAVING to WHERE** — No documented automatic predicate-pushdown rule that moves a non-aggregate HAVING predicate into WHERE. The user has to do it manually. The answer correctly avoids claiming such an optimization exists.

## Scores

| Dimension | Score | Reasoning |
|---|---|---|
| Technical accuracy | 5 | Order of evaluation correct. Verdict on engineer's query (already correct, no alternative) is accurate. The bad/good pair on `tenant_id IN (...)` correctly illustrates the trap. EXPLAIN ANALYZE + Physical Input redirection is the right diagnostic. No factual errors. |
| Beginner clarity | 5 | Direct opening verdict ("already the right pattern"). Two-row rule table makes the principle obvious. Side-by-side BAD/GOOD code with inline comments. Engineer's exact query reproduced with annotations explaining why each clause is correct. Zero unexplained jargon. |
| Practical applicability | 5 | Engineer immediately knows: (a) their query needs no change, (b) when HAVING would be wrong (non-aggregate predicate), (c) what to do if it still feels slow (EXPLAIN ANALYZE + check Physical Input + verify partition pruning). Concrete next action provided. |
| Completeness | 5 | Covers: execution order, the bad HAVING pattern, the engineer's query verdict, why no alternative exists for aggregate predicates, and the next diagnostic step if performance is still off. Cross-references partition pruning resource for the "still slow" branch. Nothing missing. |

**Average: 5.0 / 5 — PASS**

## Notes
- The answer's structure (Short answer → Rule table → Trap → Your query → If still slow → Summary) is exemplary for this style of question. Confirms the user's intuition immediately, then teaches the surrounding rule, then redirects to the actual likely culprit.
- Correctly resists the temptation to suggest an "optimization" where none exists. `COUNT(*) > 1000` genuinely has no pre-aggregation form.
- The summary's three bullets are the takeaway every reader needs.
- Fits production environment (Trino 467 + Iceberg). Partition column example `event_date` matches the engineer's actual query and the Iceberg partitioning patterns covered elsewhere in resources.

## Rubric update
SQL query best practices for OLAP: partition column in WHERE, avoid SELECT *, approximate functions, EXPLAIN verification, type-safe predicates, avoiding pushdown-breaking patterns — adds another strong data point (HAVING vs WHERE pattern). Prior avg 4.355 across 6 questions; new running avg (4.355*6 + 5.0) / 7 = **4.448** across 7 questions. Status: PASSED.
