# Iter679 Judge Feedback — max_recursion_depth FIX-A re-probe (Q1) + 3 durability shapes (Q2/Q3/Q4)

## Verdict: PASS (overall avg 4.875 / 5) — FIX-A CLOSED

The iter678 max_recursion_depth named-wrong-value drift (responder had claimed default=1000 when real Trino 467 default=10, and its own WHERE-guard exceeded the cap) is **CLOSED**. The responder this iter correctly stated default=10, gave the correct SET SESSION sequencing BEFORE the query, raised the cap to 20 to match the depth-15+ expectation, set the WHERE t.level < 20 predicate at-or-under the raised cap, and explicitly stated that exceeding the cap **raises** `NOT_SUPPORTED: Recursion depth limit exceeded` — NOT silent truncation. All three FIX-A target facts (default=10, SET SESSION instruction, error-not-truncate) are now correct.

---

## Per-question scores

### Q1 — WITH RECURSIVE deep tree + max_recursion_depth (FIX-A re-probe)

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5 | Default=10 verified against trino.io/docs/current/sql/select.html verbatim: "recursion depth is fixed, defaults to `10`, and doesn't depend on the actual query results". Error message `NOT_SUPPORTED: Recursion depth limit exceeded` verified via AWS re:Post Athena (same Trino engine). SET SESSION shape valid Trino 467. WITH RECURSIVE structure (anchor + UNION ALL + recursive JOIN) syntactically valid. WHERE t.level < 20 predicate <= raised cap of 20 — correct. |
| Beginner clarity | 5 | Explains default=10, the SET SESSION sequencing, the error mode, and the guard. Mentions quadratic plan growth + closure-table production alternative. |
| Practical applicability | 4 | Engineer can copy the SET SESSION + WITH RECURSIVE shape and run it. Closure-table mention gives a production scale-out path. **Minor nuance:** the base case `WHERE parent_category_id IS NULL` selects **all** roots, but the prompt said "under a GIVEN root category" — the precise form for a single given root would be `WHERE category_id = <given_root_id>`. Not a dialect error, just a slight overscope on the base case. Non-material to the FIX-A target (depth handling), so single-point deduction only. |
| Completeness | 5 | Addresses depth-cap handling, the exact session-property workaround, error behavior, and a hint at production alternatives. |

**Q1 avg: 4.75** | FIX-A re-probe: **CLOSED** (all three target facts now correct: default=10, SET SESSION before query, error-not-truncate).

### Q2 — Self-join unordered pairs

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5 | `u1.user_id < u2.user_id` predicate in the JOIN ON clause is canonical for unordered-pair dedup; the strict-less-than simultaneously excludes mirror pairs (Bob,Alice) AND self-pairs (Alice,Alice). Valid Trino 467 SQL. |
| Beginner clarity | 5 | Explains both eliminations (mirror + self) clearly. |
| Practical applicability | 5 | Engineer copies and runs immediately. |
| Completeness | 5 | Includes ORDER BY for stable output, projects company_id for context. |

**Q2 avg: 5.0**

### Q3 — EXISTS/DISTINCT semi-join (customers with at least one order over $500)

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5 | DISTINCT on customer_id over a JOIN-filter is correct; the simpler `SELECT DISTINCT customer_id FROM orders WHERE amount > 500` is also correct (returns customer_id only — slight signature change but matches "each customer once" intent). GROUP BY ... HAVING MAX(amount) > 500 alternative is also valid Trino 467. |
| Beginner clarity | 5 | Explains why DISTINCT is needed (a customer with multiple big orders would otherwise produce multiple rows). |
| Practical applicability | 5 | Three valid forms offered (JOIN+DISTINCT, single-table DISTINCT, GROUP BY+HAVING). Engineer picks the one matching their projection needs. |
| Completeness | 4 | EXISTS form not shown despite the question explicitly mentioning EXISTS — minor omission of the EXISTS variant (`SELECT customer_id FROM customers c WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id AND o.amount > 500)`). Three alternatives provided is still good coverage. |

**Q3 avg: 4.75**

### Q4 — FULL OUTER JOIN reconciliation

| Dim | Score | Reason |
|---|---|---|
| Technical accuracy | 5 | FULL OUTER JOIN keeps every row from both sides; `COALESCE(b.day, p.day)` correctly de-NULLs the join key when a side is missing. Valid Trino 467 (FULL OUTER JOIN with ON predicate + COALESCE is standard). Delta computation with `COALESCE(p.total,0) - COALESCE(b.total,0)` correctly treats missing as zero. |
| Beginner clarity | 5 | Explains why COALESCE is needed on the join key (the side that didn't match has NULL day). |
| Practical applicability | 5 | Engineer can plug in their two daily-totals table names and run it. Bonus delta column for reconciliation use case. |
| Completeness | 5 | Covers the side-by-side, the NULL-where-missing, and gives the delta column for reconciliation. |

**Q4 avg: 5.0**

---

## Overall

| Q | Avg |
|---|---|
| Q1 | 4.75 |
| Q2 | 5.0 |
| Q3 | 4.75 |
| Q4 | 5.0 |
| **Overall** | **4.875** |

Pass threshold ≥ 3.5 — **PASS** by a wide margin.

---

## Teacher feedback (concise)

1. **FIX-A CLOSED — HOLD r27:33 + r27:3593 + r07:456 INOCULATIONS UNTOUCHED in iter680.** All three landing routes (myth-table CONNECT BY row, §7A.1 deep-dive caveat #2, r07:456 §1b CTE inlined Quick fact) are now reinforcing the correct default=10 + error-not-truncate + SET SESSION-before-query facts on both keyword routes (Oracle migration AND CTE-keyword). The named-wrong-value DO-NOT-WRITEs ("defaults to 1000", "default 100", "silently truncates") are doing their job.

2. **Minor non-material nuance on Q1 base case:** the responder seeded the recursion with `WHERE parent_category_id IS NULL` (all roots) rather than `WHERE category_id = <given_root>` (one given root). The FIX-A target was depth handling, which is fully correct. If durability-breadth permits, a future probe could test the "single given root" variant explicitly — but this is **NOT** a regression and **NOT** a FIX target.

3. **Minor non-material nuance on Q3:** responder offered three valid forms (JOIN+DISTINCT, single-table DISTINCT, GROUP BY+HAVING) but did not show the EXISTS form despite the question naming EXISTS. Coverage is still adequate. If next probe pins EXISTS specifically, ensure r07/r23 EXISTS examples are findable.

4. **iter680 recommendation: DEFAULT NO-OP / durability-breadth.** All four answers clean. No FIX needed. Continue probing rotated angles against existing locks (federation crossing 4.5 still the thinnest margin per state — focus durability probes there over the next few iterations).

---

## Dialect verifications performed

- **Q1 default=10**: VERIFIED via trino.io/docs/current/sql/select.html ("recursion depth is fixed, defaults to `10`")
- **Q1 error-not-truncate**: VERIFIED via AWS re:Post (Athena uses Trino engine) — exact message `NOT_SUPPORTED: Recursion depth limit exceeded (10). Use 'max_recursion_depth'`
- **Q1 SET SESSION max_recursion_depth**: VERIFIED valid Trino 467 session property
- **Q2 self-join u1.user_id < u2.user_id**: VERIFIED — strict-less-than predicate in JOIN ON is canonical Trino 467 SQL
- **Q3 SELECT DISTINCT + WHERE filter**: VERIFIED valid Trino 467; alternative EXISTS / GROUP BY HAVING also valid
- **Q4 FULL OUTER JOIN + COALESCE(b.day,p.day)**: VERIFIED valid Trino 467; COALESCE on join key is the standard way to de-NULL after a FULL OUTER

Sources:
- [Trino SELECT — current/467 docs](https://trino.io/docs/current/sql/select.html)
- [AWS re:Post Athena recursive CTE NOT_SUPPORTED error](https://repost.aws/questions/QUhA0fedaZSimRrX4l6RCHfQ/athena-recursive-cte-not-supported-recursion-depth-limit-exceeded-10-use-max-recursion-depth)
