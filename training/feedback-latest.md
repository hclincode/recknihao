# Iter 511 Judge Feedback — 2026-06-06 (EXTENDED PHASE)

## Overall: 4.7969 STRONG PASS — Q1 LPAD-cast fix LANDED CLEAN; Q2 has a TERMINOLOGY error (anti-join should be semi-join)

**Federation NOT probed** this iter (per directive). Federation rubric row stays **4.49944/310** UNTOUCHED.

OVERALL AVG = (4.9375 + 4.4375 + 4.9375 + 4.875) / 4 = 19.1875 / 4 = **4.7969 STRONG PASS** (margin +1.2969 above 3.5 floor). 110th consecutive overall PASS in extended phase. Margin slightly below iter510's +1.4219 due to the Q2 anti-join-vs-semi-join terminology nit (-1.25 Accuracy on Q2 dominated the drop).

---

## Per-question scores

### Q1 — LPAD on numeric (iter510 Q2 LPAD-cast re-probe) — **4.9375 STRONG PASS clean**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | `lpad(varchar, bigint, varchar) → varchar` signature CORRECT (verified verbatim against trino.io/docs/current/functions/string.html). Trino-no-implicit-numeric→string-coercion rule CORRECT. Oracle LPAD auto-coercion contrast CORRECT. Fix `LPAD(CAST(invoice_number AS VARCHAR), 8, '0')` parses cleanly Trino 467. Result `'00000042'` CORRECT (8-char zero-padded). |
| Clarity | 5.0 | Direct CAST-first pattern + Oracle-vs-Trino implicit-coercion explanation lands in <5 sentences. No unexplained jargon. |
| Practical | 5.0 | One-line drop-in fix. Engineer can paste verbatim. "Always CAST(col AS VARCHAR) first / NO bare lpad on numeric" is the right takeaway. |
| Completeness | 4.75 | Covers the fix, the root cause (no implicit coercion), the Oracle-vs-Trino contrast, the always-CAST rule. -0.25 for no explicit error-message quote ("Unexpected parameters (bigint, integer, varchar(1)) for function lpad. Expected: lpad(varchar, bigint, varchar)") that would have nailed the symptom→fix mapping; non-load-bearing. |

**LPAD-cast fix LANDED**: The responder NOW writes `LPAD(CAST(invoice_number AS VARCHAR), 8, '0')` (cast applied) and correctly attributes the Trino-strict / no-implicit-coercion-vs-Oracle root cause. **This is THE key check for iter511** — iter510 Q2 wrote bare `lpad(account_id, 10, '0')` AND called Oracle→Trino LPAD "identical syntax"; iter511 responder fixed BOTH defects. Teacher's iter511 r27 line 868 reconcile-in-place edit (replaced "Identical." with `lpad(varchar, bigint, varchar)` signature + "MUST `CAST` first" + DO-NOT-WRITE example + cross-ref to §7A.3.1) is **EXERCISED AND CONFIRMED LANDED**. Bulletproofing payoff achieved.

### Q2 — INTERSECT vs INNER JOIN — **4.4375 PASS with ONE TERMINOLOGY ERROR**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 3.75 | INTERSECT supported in Trino CORRECT (trino.io/docs/current/sql/select.html confirms set ops). Set-semantics dedup CORRECT. INTERSECT ALL preserves duplicates CORRECT. INNER JOIN better when you need columns from both sides CORRECT. **TERMINOLOGY ERROR**: claim "INTERSECT is implemented as a hash-based ANTI-JOIN internally" is WRONG. INTERSECT returns rows present in BOTH inputs — that's **SEMI-JOIN** semantics. An **ANTI-JOIN** returns rows in the LEFT NOT in the right (that's EXCEPT / NOT EXISTS / NOT IN). Trino's actual planner uses a SemiJoin operator (or aggregate/mark-distinct in some plans) for INTERSECT — confirmed by trinodb/trino PR #5981 "Set operators EXCEPT and INTERSECT may use the same Semi Join physical operators" + O'Reilly Trino Definitive Guide. The mislabel could mislead an engineer reading EXPLAIN ("why isn't there an AntiJoin node?"). -1.25 Accuracy. |
| Clarity | 4.75 | Clean explanation of set-semantics + ALL variant + when-to-use-JOIN-instead. -0.25 for not defining "anti-join" / "semi-join" terms inline (which made the mislabel hit harder). |
| Practical | 4.75 | Engineer gets a working pattern (INTERSECT for both-lists, INTERSECT ALL for dup-preserving, JOIN for column-projecting). -0.25 because the wrong perf-note framing ("comparable to inner join because anti-join") could lead to wrong EXPLAIN expectations. |
| Completeness | 4.5 | Covers supported, dedup vs ALL, JOIN-when-columns-needed. -0.5 for no NULL-handling callout (INTERSECT treats NULLs as equal for matching, unlike `=`) — non-load-bearing for the question as asked but a useful nuance. |

**CORRECTION TO DELIVER TO TEACHER**: INTERSECT plans as a **SEMI-JOIN** (rows in both inputs), **NOT** an anti-join. ANTI-JOIN is the physical form for EXCEPT / NOT EXISTS / NOT IN (rows in left not in right). The two are opposite-direction filters and confusing them is a meaningful technical error.

### Q3 — CTE re-execution + break into dbt models — **4.9375 STRONG PASS clean**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | Trino INLINES CTEs (no result caching / materialization) — CORRECT per techjogging.com Trino CTE writeup + trinodb/trino issue #19115 + #28085 confirming Trino 467 still has no `WITH ... AS MATERIALIZED` hint (that's PostgreSQL). Referenced N times = evaluated N times — CORRECT. "Materialize as a dbt model + ref() it" — the canonical workaround, CORRECT and matches the production stack (dbt-trino supported). Single-use CTE fine — CORRECT (one reference = one execution either way; just a readability win). |
| Clarity | 5.0 | "Inlined not materialized" + the N-references = N-executions framing nails the mental model in two sentences. |
| Practical | 5.0 | Decision rule is concrete: expensive + multi-ref → break into dbt model + `{{ ref() }}`; single-ref → leave as CTE. Engineer can apply immediately. |
| Completeness | 4.75 | -0.25 for no explicit "Trino 467 has no `WITH ... AS MATERIALIZED` hint (that's PostgreSQL); don't expect an inline materialization knob to exist" callout — useful for an engineer migrating from Postgres habits. Non-load-bearing. |

### Q4 — late-arriving data in hourly incremental dbt model — **4.875 STRONG PASS**

| Dim | Score | Reasoning |
|---|---|---|
| Accuracy | 5.0 | `incremental_strategy='merge'` + `unique_key='event_id'` + `is_incremental()` guard + `date_add('day', -3, COALESCE(MAX(created_at), TIMESTAMP '1970-01-01'))` lookback subquery — ALL valid Trino 467 / dbt-trino. `date_add('day', -3, ts)` signature CORRECT (verified `date_add(varchar, bigint, timestamp(p)) → timestamp(p)` per trino.io/docs/current/functions/datetime.html). COALESCE-with-epoch-fallback watermark CORRECT (handles empty-target-on-first-incremental-run). Merge-makes-reprocessing-idempotent CORRECT. Pattern matches docs.getdbt.com lookback-window canonical for late-arriving data verbatim. |
| Clarity | 4.75 | -0.25 for not explicitly walking through WHY the subquery wrapping `{{ this }}` works on incremental runs only (the `is_incremental()` guard is mentioned but the new-engineer might still wonder how it short-circuits on first run). |
| Practical | 5.0 | Drop-in config + WHERE clause. Engineer can paste verbatim. Tune-lookback-to-lateness + full-refresh-fallback gives the operational escape hatch. |
| Completeness | 4.75 | Covers lookback, merge, unique_key, watermark fallback, tuning, full-refresh escape. -0.25 for no microbatch-strategy callout (dbt 1.9+ microbatch is an alternative to manual lookback) — not load-bearing for this specific question but a useful "modern alternative" nudge. |

---

## Topic average updates

| Topic | Before | After | Delta |
|---|---|---|---|
| SQL query best practices for OLAP (Q1 LPAD-cast re-probe + Q2 INTERSECT + Q3 CTE-inlining map here) | 4.5613/63 | (4.5613·63 + 4.9375 + 4.4375 + 4.9375)/66 = 301.6694/66 = **4.5707/66** | +0.0094 |
| Oracle PL/SQL → dbt + Trino SQL migration (Q1 LPAD reads as Oracle→Trino migration; Q4 dbt incremental migration pattern map here) | 4.5381/75 | (4.5381·75 + 4.9375 + 4.875)/77 = 350.1700/77 = **4.5476/77** | +0.0095 |
| Improving complex SQL performance on Trino with dbt (Q3 CTE-break-into-models is the canonical perf rewrite; Q4 incremental tuning is materialization tuning) | 4.5840/11 | (4.5840·11 + 4.9375 + 4.875)/13 = 60.2365/13 = **4.6336/13** | +0.0496 |

Federation rubric row UNTOUCHED at **4.49944/310** per directive.

---

## Iter512 probe targets

1. **INTERSECT semi-join 2nd-angle re-probe (HIGH)** — verifies teacher lands a fix for the anti-join→semi-join terminology error. Ask something like: "I read in EXPLAIN that my INTERSECT query has a SemiJoin node — is that expected? Some sources say INTERSECT uses anti-joins. Which is right?" Verifies whether the responder now correctly says SEMI-JOIN (rows in both) vs ANTI-JOIN (rows in left not right) and attributes the physical plan to SemiJoin.
2. **LPAD numeric-cast 3rd-angle (LOW)** — iter511 just landed Q1, but one more probe at a slightly different angle (e.g., `RPAD` on a `DECIMAL(18,2)` column, or chain `CAST` + `LPAD` inside a CONCAT) would confirm bulletproofing extends past INTEGER. Optional.
3. **CTE inlining + Trino-has-no-WITH-AS-MATERIALIZED (MEDIUM)** — re-probe to verify responder still gets "no MATERIALIZED hint in Trino 467 (that's PostgreSQL)" right and the dbt-model + ref() workaround.
4. **Late-arriving microbatch alternative (MEDIUM)** — probe whether responder can also recommend dbt 1.9+ microbatch strategy as an alternative to manual lookback windows, since iter511 only covered the manual lookback pattern.
5. **Federation STAYS UNPROBED (LOW)** — per locked directive, federation rubric row at 4.49944/310 stays untouched.

---

## Concrete next-teacher actions

### 1. (PRIMARY, LOAD-BEARING) Fix the INTERSECT anti-join → semi-join terminology error in resources

**Where**: Find the resource that documents INTERSECT/EXCEPT set operations on Trino (likely r07 analytical query patterns or r23 dialect/translation matrix). Grep for "anti-join" + "INTERSECT" to locate the source of the confusion if it exists in resources/.

**What to write**: A clear callout that:
- INTERSECT returns rows in BOTH inputs → **semi-join** semantics (matches `WHERE EXISTS (SELECT 1 FROM B WHERE B.x = A.x)`).
- EXCEPT returns rows in LEFT NOT in RIGHT → **anti-join** semantics (matches `WHERE NOT EXISTS (...)` / `NOT IN`).
- Trino's physical planner for INTERSECT uses a SemiJoin operator (or aggregate/mark-distinct in some plans) — confirmed by trinodb/trino PR #5981: "Set operators EXCEPT and INTERSECT may use the same Semi Join physical operators".
- DO-NOT-WRITE example: "INTERSECT is implemented as an anti-join" (this is the bug — it's a semi-join).
- Keyword anchors for findability: "INTERSECT semi-join", "EXCEPT anti-join", "INTERSECT plan", "INTERSECT EXPLAIN SemiJoin node", "set operation join type Trino".

**Why load-bearing**: An engineer reading the responder's wrong answer and running EXPLAIN will see a SemiJoin node (not AntiJoin) and get confused, OR they'll incorrectly reason that "INTERSECT = anti-join = expensive" and avoid it. The mislabel could distort optimization decisions.

### 2. (SECONDARY, OPTIONAL) Cross-reference the dbt 1.9+ microbatch strategy at the late-arriving lookback canonical

Q4 answer was strong but only covered the manual lookback pattern. dbt 1.9+ introduced `incremental_strategy='microbatch'` which natively handles the lookback + per-batch boundary problem. Adding a 2-3 line cross-ref ("see also: microbatch strategy for natively-managed lookback windows") at the lookback canonical would future-proof the answer.

### 3. (TERTIARY, OPTIONAL) Add a one-line "no WITH ... AS MATERIALIZED in Trino 467 (that's PostgreSQL)" callout

Q3 answer was clean but didn't pre-empt the engineer who knows Postgres CTE materialization hints and wonders if Trino has one. A 1-line callout at the CTE canonical would prevent a future probe from hitting this gap.

---

## Federation guardrails

§13.x federation guardrails in resources/22 NOT TOUCHED. Federation rubric row stays **4.49944/310**. Federation not probed in iter511.

---

## Score history append

Iter511 score line appended to `training/rubric.md` score history below the iter510 entry.

---

## Sources (WebSearch verification)

- [String functions and operators — Trino Documentation](https://trino.io/docs/current/functions/string.html) — verified `lpad(varchar, bigint, varchar) → varchar` signature, first arg MUST be varchar.
- [SELECT — Trino Documentation](https://trino.io/docs/current/sql/select.html) — verified INTERSECT, INTERSECT ALL, EXCEPT supported set operations + WITH clause inlining behavior.
- [Optimize execution for output duplicates insensitive joins — trinodb/trino PR #5981](https://github.com/trinodb/trino/pull/5981) — confirms "Set operators EXCEPT and INTERSECT may use the same Semi Join physical operators" (not anti-join).
- [Common Table Expressions in Trino — techjogging](https://techjogging.com/common-table-expressions-in-trino.html) — verified CTEs are inlined, referenced N times = executed N times.
- [Does trino support CTE Materialization? — trinodb/trino issue #28085](https://github.com/trinodb/trino/issues/28085) — confirms Trino 467 still has NO `WITH ... AS MATERIALIZED` hint.
- [Date and time functions and operators — Trino Documentation](https://trino.io/docs/current/functions/datetime.html) — verified `date_add(varchar, bigint, timestamp(p)) → timestamp(p)` signature.
- [Incremental patterns for near real-time data — dbt Developer Hub](https://docs.getdbt.com/best-practices/how-we-handle-real-time-data/2-incremental-patterns) — verified lookback-window pattern with `is_incremental()` + `dateadd(..., -N, max(...))` for late-arriving data.
- [About incremental strategy — dbt Developer Hub](https://docs.getdbt.com/docs/build/incremental-strategy) — verified `merge` strategy + `unique_key` semantics in dbt-trino.
