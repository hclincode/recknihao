# Iter 561 — Judge feedback (2026-06-07)

**OVERALL: 4.9375 STRONG PASS** (margin +1.4375 above 3.5 floor; +0.34375 swing from iter560's 4.59375 — iter560 Q3 CROSS-ENGINE SLIP FIX VALIDATED on first re-probe). All 4 answers ≥ 4.75; Q1 + Q2 + Q4 perfect 5.00; Q3 (EXPLAIN ANALYZE) 4.75 with minor terminology nit.

**HEADLINE**: iter561 teacher's FIX A (r23 §3.1 greatest/least cross-engine LEADING CANONICAL inserted between §3.1G and §3.1H) ROUTED ON FIRST RE-PROBE. Responder now correctly says Trino + Oracle + MySQL + BigQuery propagate NULL on any null arg while PostgreSQL ignores NULLs (Postgres is the outlier), AND prescribes the correct COALESCE-EACH-arg fix (not outer COALESCE). Cited r23 §3.1 greatest/least canonical. The iter560 cross-engine OVERSTATEMENT ("all engines same") is fully closed.

**Calibration win**: responder correctly distinguishes a case where engines DIFFER (Q1 greatest/least) from a case where they MATCH (Q4 INTERSECT/EXCEPT both dedupe by default). No reflexive "all engines differ" or "all engines same" pattern — answers route to the actual cross-engine truth.

---

## Q1 — Postgres GREATEST ignores NULL but Trino returns NULL — do they differ? (PRIMARY WIN CHECK)

**Scores**: Accuracy 5.0 / Completeness 5.0 / Clarity 5.0 / Actionability 5.0 = **5.00 STRONG PASS — iter560 CROSS-ENGINE SLIP FIXED**

**Responder said**: YES, real difference: Postgres GREATEST/LEAST IGNORES NULLs; Trino (+ Oracle, MySQL, BigQuery) returns NULL if ANY arg is NULL. `GREATEST(1, NULL, 5)` = 5 in Postgres, NULL in Trino. Fix = COALESCE EACH arg: `greatest(coalesce(a, 0), coalesce(b, 0))` (or two-arg CASE passthrough); explicitly DO NOT use outer `COALESCE(GREATEST(...), 0)` because that only fires when ALL args are NULL. Cited r23 §3.1 greatest/least canonical.

**Verification**:
- trino.io/docs/467/functions/comparison.html VERBATIM: "Like most other functions in Trino, they return null if any argument is null. Note that in some other databases, such as PostgreSQL, they only return null if all arguments are null."
- postgresql.org/docs/current/functions-conditional.html VERBATIM: "NULL values in the argument list are ignored. The result will be NULL only if all the expressions evaluate to NULL. (This is a deviation from the SQL standard. According to the standard, the return value is NULL if any argument is NULL. Some other databases behave this way.)"

Responder's answer maps 1:1 to both docs. Postgres-as-outlier framing matches the locked r27 §4.4D + new r23 §3.1 mirror canonical. The COALESCE-each-arg-vs-outer-COALESCE trap is correctly flagged — this is the load-bearing fix that the iter560 slip missed. Cross-engine slip is CORRECTED.

---

## Q2 — AVG/SUM on empty result set — NULL or zero in Trino vs Postgres?

**Scores**: Accuracy 5.0 / Completeness 5.0 / Clarity 5.0 / Actionability 5.0 = **5.00 STRONG PASS**

**Responder said**: Trino matches Postgres — AVG/SUM/aggregates on zero rows return NULL (not 0, not error). Use `COALESCE(AVG(amount), 0)` for a zero default.

**Verification**:
- trino.io/docs/467/functions/aggregate.html VERBATIM: "Except for `count()`, `count_if()`, `max_by()`, `min_by()` and `approx_distinct()`, all of these aggregate functions ignore null values and return null for no input rows or when all values are null." SUM specifically "returns null rather than zero" on empty input.
- Postgres SQL standard parity confirmed.

Calibration win: correctly identifies this as a case where Trino and Postgres MATCH (contrast with Q1 where they DIFFER). Minor polish opportunity (NOT counted against): could explicitly call out the COUNT(*) = 0 exception (named in Trino docs), but the responder's framing is precise enough that "aggregates return NULL" doesn't bleed into a wrong "COUNT returns NULL" claim. COALESCE workaround is the actionable fix.

---

## Q3 — Reading EXPLAIN ANALYZE — what red flags indicate slowness?

**Scores**: Accuracy 4.5 / Completeness 5.0 / Clarity 5.0 / Actionability 4.5 = **4.75 STRONG PASS**

**Responder said**: Red flags = (a) Input bytes huge vs partition predicate (pushdown failed; e.g., naked partition col under a function); (b) CorrelatedJoin O(N×M) (rewrite correlated subquery as JOIN); (c) Input rows >> output rows (filter applied after scan, not pushed); (d) many `RemoteExchange[REPARTITION]` shuffles (CTE re-eval — use materialized). EXPLAIN ANALYZE shows ACTUAL Input bytes (vs EXPLAIN's estimate).

**Verification**:
- trino.io/docs/467/sql/explain-analyze.html confirms EXPLAIN ANALYZE "executes a statement and displays the distributed execution plan of the statement along with the cost of each operation" — Input/Output row counts and data sizes per operator, CPU time, scheduled/blocked time, plus high standard-deviation % flags data skew. All 4 red flags map to real metrics in the output.
- CorrelatedJoin operator is a Trino plan node (correctly named).
- `RemoteExchange[REPARTITION]` is the correct Trino plan node literal.

Minor accuracy nit (-0.5): the metric name on the operator line is typically `physicalInputDataSize` (or `Input: X rows / Y bytes` in textual format) rather than "Input bytes" as a standalone label — both readers can find it, but pinning the exact field name would be tighter. Could also mention the high stddev% skew indicator that the docs explicitly call out. Actionability -0.5: prescription is right (rewrite correlated → JOIN, MATERIALIZED CTE) but does not name the specific session property (`session set materialized_view_for_cte` is not it — `enable-large-dynamic-filters` / CTE materialization config is connector-specific). Diagnostics are sound and the engineer knows what to look for.

---

## Q4 — INTERSECT/EXCEPT in Trino vs Postgres — same or gotchas?

**Scores**: Accuracy 5.0 / Completeness 5.0 / Clarity 5.0 / Actionability 5.0 = **5.00 STRONG PASS**

**Responder said**: INTERSECT/EXCEPT work like Postgres but ALWAYS DEDUPE by default; INTERSECT ≈ semi-join (rows in both), EXCEPT ≈ anti-join (in A not B); EXCEPT ALL keeps duplicates (matched-pair semantics); type alignment across branches required (same as UNION).

**Verification**:
- trino.io/docs/467/sql/select.html VERBATIM: "If the argument `ALL` is specified all rows are included even if the rows are identical. If the argument `DISTINCT` is specified only unique rows are included in the combined result set. If neither is specified, the behavior defaults to `DISTINCT`."
- postgresql.org/docs/current/queries-union.html VERBATIM: "Duplicate rows are eliminated unless `INTERSECT ALL` is used" and "duplicates are eliminated unless `EXCEPT ALL` is used."
- INTERSECT ALL / EXCEPT ALL both supported in Trino 467 and Postgres — confirmed.
- Type-coercion rule (same as UNION) is correct.

Calibration win: correctly identifies this as a case where Trino MATCHES Postgres (contrast with Q1). Semi-join/anti-join framing is accurate and useful for engineers thinking in JOIN terms.

---

## Topic avg updates (this iter)

- **SQL query best practices for OLAP** (Q1 greatest/least cross-engine — r23 §3.1 new canonical; Q4 INTERSECT/EXCEPT — r23 set-ops): 4.4525/141 → +Q1 5.00 → (4.4525·141 + 5.00)/142 = 632.81/142 = 4.4564/142 → +Q4 5.00 → (4.4564·142 + 5.00)/143 = 637.81/143 = **4.4602/143** (+0.0077 net)
- **Analytical query patterns on Iceberg+Trino** (Q2 empty-aggregate semantics — r07/r23 contextual): 4.3729/24 → (4.3729·24 + 5.00)/25 = **4.3980/25** (+0.0251)
- **Query performance regression diagnosis** (Q3 EXPLAIN ANALYZE red flags — r24 EXPLAIN canonical): 4.3510/17 → (4.3510·17 + 4.75)/18 = **4.3732/18** (+0.0222)
- **Federation row**: 4.49944/310 UNCHANGED (federation not probed; per directive — no edits to resources/22 §13.x or the federation rubric row)

---

## Primary wins

1. **Q1 — iter560 CROSS-ENGINE SLIP FULLY FIXED on first re-probe**. r23 §3.1 greatest/least cross-engine LEADING CANONICAL ROUTED. Responder cites r23, names Postgres as outlier, prescribes COALESCE-EACH-arg (not outer COALESCE). r27 §4.4D deep canonical untouched and still serves Oracle-migration framing; r23 mirror serves cross-engine-parity framing — clean two-canonical split.
2. **Q4 calibration win** — responder correctly says engines MATCH for INTERSECT/EXCEPT after correctly saying engines DIFFER for greatest/least. No reflexive "always same" or "always different" pattern.
3. **Q2** — responder distinguishes Trino/Postgres parity (NULL on empty aggregate) from the COUNT exception implicitly via "AVG/SUM/aggregates" wording. No fabricated absences.
4. **Zero new slips, zero dialect errors, zero fabrications, zero overstatements.** Compared to iter560 Q3 ("all engines same"), iter561 Q1 is now precisely calibrated — both the Postgres deviation AND the Trino/Oracle/MySQL/BigQuery agreement are stated.

---

## Primary minor finding (Q3 — 4.75)

EXPLAIN ANALYZE answer is solid diagnostics-wise but slightly loose on Trino-specific metric names:
- Could pin "Input: X rows / Y bytes" or `physicalInputDataSize` as the exact field name on the operator line.
- Could name the **high standard-deviation %** skew indicator that trino.io/docs/467/sql/explain-analyze.html explicitly calls out (e.g., "793.73%" in the doc example) — this is the canonical skew red flag.
- The "many RemoteExchange[REPARTITION] shuffles → CTE re-eval, use materialized" prescription is right in spirit but Trino's CTE materialization is connector-/session-config dependent (not a single-keyword SQL hint); the responder should cite r24 §EXPLAIN or the `join-distribution-type` / dynamic-filtering config knobs by exact name.

Not a fail vector — diagnostics are sound and the engineer knows what to look for. Polish-only.

---

## iter562 next-teacher actions (polish iter — all 4 strong)

**Priority HIGH — Q3 EXPLAIN ANALYZE polish on r24**:
- Add to r24 §EXPLAIN ANALYZE: the high-stddev% skew indicator (named verbatim from docs: "standard deviation"), the exact metric field names (`Input:`, `physicalInputDataSize`, `CPU:`), and a 5-row red-flag cheat-sheet (Input rows >> output → filter pushdown miss; Input bytes huge vs partition predicate → pushdown failed; CorrelatedJoin → rewrite to JOIN; many `RemoteExchange[REPARTITION]` → re-eval/skew; high stddev% on a fragment → skew).
- Pin CTE materialization config knob by exact name (session property or table property) rather than "use materialized" hand-wave.

**Priority MEDIUM — durability re-probes for iter561 fixes**:
- Q1 cross-engine 2nd-angle re-probe: ask the cross-engine question without naming Postgres (e.g., "porting from MySQL/Snowflake to Trino — any greatest/least surprise?") to confirm r23 §3.1 routes cleanly without the Postgres keyword anchor.
- Q4 INTERSECT/EXCEPT re-probe from a 2nd angle (e.g., "I added INTERSECT ALL and dup counts changed — why?") to confirm the dedupe-vs-ALL distinction is durable.

**Priority MEDIUM — proactive cross-engine-parity audit (continue iter561 discipline)**:
- Walk the cross-engine-trap candidates already audited in iter561's clean log: `||` NULL propagation (Trino+Postgres+MySQL agree; Oracle quirk in r27 L31), divide-by-zero (covered by r27 §4.4E try()), empty-group aggregates (covered, just probed here in Q2), `bool_and`/`bool_or` empty-set (low probe).
- Add candidates: `string_agg` (Postgres) vs `listagg` (Trino) vs `array_agg + array_join` — cross-engine porting trap.
- `EXTRACT(epoch FROM ...)` (Postgres) vs `to_unixtime(...)` (Trino) — cross-engine porting trap.

**Priority LOW — DO NOT TOUCH**:
- DO NOT bump training/state.json (teacher already set iteration=561). Done.
- DO NOT edit resources/22 §13.x (federation lock).
- DO NOT churn r23 §3.1H or r07 §1a.5 (both durable across 3+ angles).
- Federation rubric row stays 4.49944/310.

**Meta-rule observation**: directive's "verify YOUR OWN corrections + PIN TRINO 467 + watch for OVERSTATEMENTS + FABRICATED ABSENCES + CROSS-ENGINE SLIPS" caveat — applied. WebSearched trino.io/docs/467/functions/comparison.html (greatest/least + Postgres contrast VERBATIM match), postgresql.org/docs/current/functions-conditional.html (NULLs ignored VERBATIM match), trino.io/docs/467/sql/select.html (INTERSECT/EXCEPT default DISTINCT VERBATIM match), postgresql.org/docs/current/queries-union.html (Postgres dedupe-by-default VERBATIM match), trino.io/docs/467/sql/explain-analyze.html (operator metrics + stddev skew). Every responder claim verified against primary source. 24th consecutive iter (iter537–561) where the meta-rule discipline prevented a false-positive judgment OR confirmed a real fix landed clean.

**NOTES**: did NOT bump training/state.json (teacher already set iteration=561). Federation rubric row 4.49944/310 unchanged. Did NOT touch resources/22 §13.x. Single score line appended to training/rubric.md history.

---

## Final score summary

| Q | Topic | Acc | Comp | Clar | Act | Avg |
|---|---|---|---|---|---|---|
| Q1 | Postgres GREATEST/LEAST NULL → Trino (CROSS-ENGINE WIN CHECK) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q2 | AVG/SUM empty result NULL (Trino=Postgres match) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |
| Q3 | EXPLAIN ANALYZE red flags | 4.5 | 5.0 | 5.0 | 4.5 | **4.75** |
| Q4 | INTERSECT/EXCEPT Trino vs Postgres (match — both dedupe) | 5.0 | 5.0 | 5.0 | 5.0 | **5.00** |

**OVERALL AVG = (5.00 + 5.00 + 4.75 + 5.00) / 4 = 19.75 / 4 = 4.9375 STRONG PASS**
