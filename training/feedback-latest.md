# Judge Feedback — iter723 (EXTENDED PHASE)

Docs verified against trino.io/docs/467 (connector/iceberg.html, functions/array.html, functions/math.html) + WebSearch on array_distinct ordering. Scores are per-Q on Accuracy / Completeness / Clarity / Actionability (1–5); overall average governs PASS/FAIL.

## Q1 — Iceberg rollback (fresh "undo last write / restore to yesterday" framing)
- Accuracy: 5 — `CALL iceberg.system.rollback_to_snapshot('analytics','events',8954597067493422955)` is VERBATIM the Trino 467 native form (docs example: `CALL example.system.rollback_to_snapshot('testdb','customer_orders',8954597067493422955)`). Three positional args (schema string, table string, snapshot_id bigint) — correct. Attributed to NATIVE Trino (not Spark-only, not "recreate from backup") — correct. `$history` column list (made_current_at, snapshot_id, parent_id, is_current_ancestor) matches docs exactly. `events$history` whole-token-one-quote-pair form correct. `is_current_ancestor = true` for safe targets — correct. ALTER TABLE EXECUTE rollback confirmed ABSENT from 467 docs (469+), so the CALL-only attribution is right.
- Completeness: 5 — directly answers "native command or recreate from backup?" (native, atomic pointer move, no data-file touch), shows how to find the prior snapshot_id, and gives the safety filter. Cited resources/17 (the canonical) — the routing fix held.
- Clarity: 5 — "moves the current pointer to an earlier snapshot without touching data files" is an excellent zero-OLAP explanation; "undo this morning's bad migration" maps directly to the user's framing.
- Actionability: 5 — copy-paste CALL + lineage query + the exact column to filter. Engineer knows exactly what to run.
- **ROLLBACK ATTRIBUTION VERDICT: STAYS RESOLVED — DURABLE.** Across the iter722→723 re-probes and now a fresh "restore to yesterday" phrasing, the responder emits the native Trino 467 positional 3-arg CALL, attributes it to native Trino (NOT "(Spark)", NOT backup-recreation), and cites r17 the canonical. The iter722 PIN + r13→r17 routing are holding across phrasings. No regression.

## Q2 — array_distinct
- Accuracy: 5 — `array_distinct(tags)` removes duplicate values (docs: "Remove duplicate values from the array x"). `cardinality(array_distinct(tags))` returns the distinct count (docs: cardinality = array size, bigint). The "preserves first-occurrence order" claim is borne out by docs examples (`[1,1,2,3]→[1,2,3]`) and is the de-facto behavior, though the docs prose does not formally *guarantee* ordering. Minor over-reach to state it as a hard guarantee, but the behavior is correct and the answer's correctness does not depend on ordering. Not penalized — accurate in practice.
- Completeness: 5 — dedupe in-row + distinct count, both requested ("without exploding/reassembling"). Explicitly notes single-row, no explosion.
- Clarity: 5 — concrete worked transform `['billing','billing','upgrade'] → ['billing','upgrade']`.
- Actionability: 5 — two ready queries covering both needs.

## Q3 — date spine / gap-fill
- Accuracy: 5 — `sequence(DATE '2026-01-01', DATE '2026-12-31', INTERVAL '1' DAY)` is a valid Trino 467 date sequence returning array(date) (docs: sequence with INTERVAL DAY TO SECOND step generates a sequence of dates). `UNNEST(...) AS t(dt)` single-column alias is correct — sequence→array→1 column→1 alias. LEFT JOIN calendar to aggregated events + `COALESCE(...,0)` gap-fill is the sound canonical pattern.
- Completeness: 5 — full runnable spine, the LEFT JOIN, the zero-fill, and ORDER BY. Addresses "even zero-activity days."
- Clarity: 5 — line-by-line gloss (sequence → UNNEST explodes → LEFT JOIN → COALESCE fills). A beginner can follow each step.
- Actionability: 5 — single copy-paste CTE pattern the engineer can drop in.

## Q4 — abs
- Accuracy: 4 — Core answer `abs(revenue_change)` is fully correct: docs confirm abs returns the absolute value, works on integer and decimal, return type matches input. "-200 and +200 both → 200" correct. DEFECT (secondary): the second illustrative snippet `SELECT customer_id, revenue_delta DECIMAL(18, 2), abs(revenue_delta) ...` writes a column-with-type declaration in a SELECT list, which is NOT valid Trino SELECT syntax — it parses as `revenue_delta` aliased `DECIMAL` followed by a stray `(18,2)`, i.e. a syntax error. The intended cast would be `CAST(revenue_delta AS DECIMAL(18,2))`. Real (not harmless) defect because it errors if copied, but it sits in a SECONDARY example; the primary `abs(revenue_change)` query above it is correct and runnable. Knocked one point.
- Completeness: 5 — answers both the function and the "works on decimals like integers?" sub-question (yes, identical, return type matches).
- Clarity: 5 — clear, with the requested -$200/+$200 example.
- Actionability: 4 — primary query is copy-paste-ready; the stray second snippet would error if a user pasted it, costing a debugging cycle. Lowered one point.

## Score table

| Q | Accuracy | Completeness | Clarity | Actionability | Q-avg |
|---|---|---|---|---|---|
| Q1 rollback | 5 | 5 | 5 | 5 | 5.00 |
| Q2 array_distinct | 5 | 5 | 5 | 5 | 5.00 |
| Q3 date spine | 5 | 5 | 5 | 5 | 5.00 |
| Q4 abs | 4 | 5 | 5 | 4 | 4.50 |

**Overall average = (5.00 + 5.00 + 5.00 + 4.50) / 4 = 4.875 → PASS**

## Teacher feedback / iter724 flag
- **iter724 FLAG (genuine, low severity):** In resources/27-oracle-plsql-to-dbt-trino.md (the source the responder cited for abs), the abs example region appears to contain an invalid `SELECT ... col DECIMAL(18,2) ...` form that the responder reproduced. A `col DECIMAL(p,s)` token in a SELECT list is NOT valid Trino — the explicit-precision form is `CAST(col AS DECIMAL(18,2))`. Locate the abs/DECIMAL example in r27 (grep `DECIMAL(18` / `abs(`) and either (a) fix it to `CAST(revenue_delta AS DECIMAL(18,2))`, or (b) drop the type annotation entirely (`SELECT customer_id, revenue_delta, abs(revenue_delta) AS magnitude_usd`). If the bad form is being copied from a DO-NOT-WRITE block, inline-mark it un-copyable per the iter693/defang lesson. This is the only correctness defect across the 4 answers and it is in a secondary snippet, so it is a light-additive fix, not a regression.
- **No other gaps.** Rollback attribution, array_distinct, sequence+UNNEST date spine, and the abs core are all docs-correct and durable. Do NOT touch r17 (rollback canonical + iter722 PIN), r07 (date spine / array patterns), or r22 (HARD LOCK).
