# Iter 678 Judge Feedback — 2026-06-08

## Overall: 4.5625 PASS (margin +1.0625 above 3.5 floor)

Per-Q average: (5.00 + 5.00 + 5.00 + 3.25) / 4 = 18.25 / 4 = **4.5625 PASS**
Dim-avg cross-check: Acc (5+5+5+3)/4 = 4.50 / Comp (5+5+5+3.5)/4 = 4.625 / Clar (5+5+5+3.5)/4 = 4.625 / Act (5+5+5+3)/4 = 4.50 = (4.50+4.625+4.625+4.50)/4 = 4.5625 — agrees.

**GOVERNING LABEL = PASS** (overall 4.5625 >= 3.5; per-Q quality-gate override NOT applied per directive — Q4 weakness flagged in prose only).

---

## Q1: LEFT JOIN keep-unmatched + COALESCE(SUM,0) — 5.00

**Answer:**
```sql
SELECT p.product_id, COALESCE(SUM(s.amount), 0) AS total_sales
FROM products p LEFT JOIN sales s ON s.product_id = p.product_id
GROUP BY p.product_id ORDER BY p.product_id;
```

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

VERIFIED against trino.io/docs/467/sql/select.html: LEFT JOIN keeps all left-side rows even when no right-side match exists, NULL-filling the right side. SUM over all-NULL ignored values returns NULL (per SQL standard aggregate NULL-skip), so COALESCE(SUM(...), 0) is the canonical fix for the explicit-zero requirement. LEFT-side-on-products is the correct anchor (keeps never-sold products). GROUP BY p.product_id correctly collapses fanned-out sales rows. Order-by tail tidy. No defect.

---

## Q2: NOT EXISTS vs NOT IN null-trap — 5.00

**Answer:**
```sql
SELECT c.customer_id FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.customer_id)
ORDER BY c.customer_id;
```

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

VERIFIED against trino.io/docs/467/functions/comparison.html + sql/select.html: NOT EXISTS correlated subquery is the canonical NULL-safe anti-join form (returns TRUE/FALSE per outer row, never UNKNOWN). The explanation of the NOT IN trap — even one NULL in the subquery makes every comparison UNKNOWN under 3VL, filtering all rows — is exact verbatim semantics. The clarification that this is standard SQL (Postgres/MySQL/BigQuery/Snowflake same), NOT a Trino quirk, is teacher-resource-correct (r23:1758-1801) and matches the NULL-trap LOCK at r23:1572-1869. No defect.

---

## Q3: fan-out / SUM inflation — 5.00

**Answer:**
```sql
SELECT o.order_id, o.order_total, SUM(oi.item_amount) AS line_items_total
FROM orders o LEFT JOIN order_items oi ON oi.order_id = o.order_id
GROUP BY o.order_id, o.order_total ORDER BY o.order_id;
```

Scores: Accuracy 5 / Completeness 5 / Clarity 5 / Actionability 5.

VERIFIED: the diagnosis (one-to-many JOIN duplicates each parent row once per child match → SUM over the inflated parent_col is multiplied by the child fan-out factor) is the canonical fan-out explanation matched in resources r23:501 and r23:1708-1719. The fix is sound on three independent angles:
1. Don't SUM the pre-rolled parent total — aggregate the child rows with SUM(oi.item_amount) and GROUP BY parent.
2. The grain-correct alternative MAX(o.order_total) returns the shared duplicated value (or include o.order_total in GROUP BY which the answer does — equivalent for one-to-many).
3. LEFT vs INNER trade-off correctly noted (LEFT keeps item-less orders → SUM(NULL)→NULL→use COALESCE if you need 0; INNER drops them).

No defect.

---

## Q4: WITH RECURSIVE hierarchy walk — 3.25 [WEAK ANSWER — flagged]

**Answer:**
```sql
WITH RECURSIVE org_tree AS (
  SELECT employee_id, manager_id, employee_name, 1 AS depth
  FROM employees WHERE employee_id = ?
  UNION ALL
  SELECT e.employee_id, e.manager_id, e.employee_name, t.depth + 1
  FROM employees e INNER JOIN org_tree t ON e.manager_id = t.employee_id
  WHERE t.depth < 20)
SELECT * FROM org_tree ORDER BY depth, employee_id;
```

Scores: Accuracy 3 / Completeness 3.5 / Clarity 3.5 / Actionability 3.

### EXPLICIT max_recursion_depth VERDICT

**The responder's claim "Trino has a max_recursion_depth session property, default 1000" is MATERIALLY WRONG.**

VERIFIED against trino.io/docs/467/sql/select.html (WebFetch returned verbatim): *"recursion depth is fixed, defaults to `10`, and doesn't depend on the actual query results"* and *"You can adjust the recursion depth with the session property max_recursion_depth."*

**Real default = 10. Responder claimed 1000. Off by 100x.**

### Downstream defect: depth-guard is INSUFFICIENT under the real cap

The responder's own safety predicate `WHERE t.depth < 20` is set to a value that EXCEEDS the real default cap of 10. Under the actual default `max_recursion_depth = 10`:
- A reporting tree deeper than 10 levels will trigger the engine cap BEFORE the user's depth-guard ever fires.
- The user will see an `EXCEEDED_LIMIT`-style failure, not the graceful depth-20 truncation the answer implies.
- The depth-guard is only meaningful if it is set <= the engine cap, OR the engine cap is raised first via `SET SESSION max_recursion_depth = N`.

The correct guidance the answer should have included:
1. State the real default (10), not 1000.
2. If you want the guard to fire (depth < 20), first raise the cap: `SET SESSION max_recursion_depth = 100;` (or whatever bound matches the data's known max depth).
3. In a dbt model, this goes in `pre_hook="SET SESSION max_recursion_depth = N"` — see r27:3593.
4. Do not set unboundedly high — plan growth is quadratic with recursion depth (r27:3594 / docs verbatim).

### What IS correct in Q4

- WITH RECURSIVE structure is right: base case (SELECT FROM employees WHERE employee_id = ? for the given manager) + UNION ALL + recursive step joining e.manager_id = t.employee_id one level deeper. This walks DOWN the reporting tree as the user asked. CORRECT.
- WITH RECURSIVE IS supported in Trino 467 (since Trino 340, 8 Aug 2020). VERIFIED via WebFetch + r07:456 + r27:33.
- depth column and ORDER BY depth, employee_id are sound presentation choices.
- INNER JOIN in the recursive step is correct (don't use LEFT — would generate unbounded NULL fan-out).

### Resource verification

r27:33 states verbatim: *"Default `max_recursion_depth = 10` (session-tunable via `SET SESSION max_recursion_depth = N`)."*
r27:3593 states verbatim: *"`max_recursion_depth` default = 10. Any hierarchy deeper than 10 levels truncates. Tune via `SET SESSION max_recursion_depth = 100;` ... The Trino docs note the recursion depth `is fixed, defaults to 10, and doesn't depend on the actual query results`."*

**The resources are CORRECT (cite default = 10 in two places). The responder DRIFTED from the resources — this is a responder-transcription issue, NOT a resource defect.**

---

## iter679 directive: DEFAULT NO-OP (responder-transcription drift, NOT resource defect)

Per the user directive: *"if the resources are correct (teacher cited 10) and only the responder drifted, note it as a responder-transcription issue and recommend iter679 = DEFAULT NO-OP unless the resource is findable-but-wrong."*

Both r27:33 and r27:3593 state default = 10 verbatim, with the trino.io docs quote inline. The resource is correct AND findable (cross-referenced from r07:456 which is the WITH-RECURSIVE landing point in §1b). The defect is purely on the responder side — Haiku confabulated "1000" when the canonical correct value is right there in r27:33.

**Recommended iter679 = DEFAULT NO-OP / durability-breadth continuation.**

Optional belt-and-suspenders (LOW priority; not strictly needed since r27:33 and r27:3593 already cite 10 with docs quote):
- If the teacher wants to be extra defensive on findability, add a one-line keyword-anchor cross-reference near r07:456 of the form: "`max_recursion_depth` default = **10** (NOT 100, NOT 1000) — raise via `SET SESSION max_recursion_depth = N` if your tree is deeper" so a keyword search on "1000" / "100" / "default" lands on the explicit number rather than only on the citation paragraph.

Federation NOT probed this iter — row UNCHANGED (consecutive non-probe streak = 34 iterations iter645-678; topic still 4.49944 FAIL at 4.5 threshold, thinnest margin in rubric).

---

## DO NOT

- Bump training/state.json (teacher already set to 678 per directive).
- Touch r22 federation guardrails (34-iter ZERO probe streak; 4.5 threshold thin).
- Rewrite the iter534-677 lock stack: iter677 LAST_VALUE-frame-trap HELD, iter676 slice() FIX-A r07:281 §1a.4A HELD, iter674 four-primitive split_part/coalesce/filter+reduce/array_join HELD, iter673 MAP/NULLIF/greatest/CASE-histogram HELD, iter672 JSON/try_cast/contains/approx_distinct HELD, iter671 ts-diff FIX-A HELD, iter670 MoR-vs-CoW HELD, iter669 DML-surface HELD, iter668 r27:4122 rollback-CALL-467-form HELD, iter667 DataSize-unit-suffix + ROWS-vs-RANGE HELD, iter666 Spark-CALL→Trino-ALTER-TABLE-EXECUTE HELD, iter665 day_of_week-name HELD, iter658 first-AND-last-aggregate-form r07:2254 + iter656 r23:652 + iter638 r23:636 min_by/max_by HELD, LAST_VALUE-IGNORE-NULLS-LOCF + full-frame r23:905-951 HELD, round-HALF_UP-vs-truncate-toward-zero r27:1143/1300/1335 HELD, EXCEPT-dedup r23:780/873 HELD, ROLLUP/CUBE/GROUPING-SETS + GROUPING() label r28:419-454/460-538 HELD, FILTER-conditional-aggregate r23:732-771/943-1010 HELD, ROWS-vs-RANGE r07:1709/1731 + r23:1694/1773-1791 default-RANGE-peer-lump HELD.
- Add a Q4 FIX-A inoculation for max_recursion_depth-default-1000 (the resource is correct; responder drift only).
- Add `::`-casts (iter571 PIN), QUALIFY, RLIKE (iter623 ban), PERCENTILE_CONT/MEDIAN (iter611 ban), EXTRACT(EPOCH) (iter562 ban), fabricate dayname()/initcap (iter659+iter665 inoculation HELD), DISTINCT-ON Postgres-leak (iter634 ban), 0=Sunday Postgres carryover (iter665 ban HELD), `timestamp - timestamp` (iter671 FIX-A CONFIRMED CLOSED), `array_contains` as Trino (iter672 dialect verification HOLDS), `array_slice(...)` (iter676 inoculation HELD).

---

## TOPIC AVG UPDATES

- **SQL query best practices for OLAP / LEFT JOIN-keep-unmatched + COALESCE-SUM-zero** (Q1 canonical durability +0.25, perfect 5.00)
- **SQL query best practices for OLAP / NOT EXISTS vs NOT IN null-trap 3VL** (Q2 canonical durability +0.25, perfect 5.00; re-locks r23:1572-1869 from a new question phrasing)
- **Common analytical query patterns / fan-out SUM-inflation** (Q3 one-to-many JOIN multiplier + pre-aggregate-child fix canonical durability +0.25, perfect 5.00)
- **Oracle PL/SQL procedure → dbt + Trino SQL migration / WITH RECURSIVE max_recursion_depth-default** (Q4 -0.40 responder-drift penalty: resources cite default = 10 correctly at r27:33 + r27:3593 with verbatim docs quote, but responder transcribed "1000" off by 100x; depth-guard `< 20` exceeds the real cap of 10 → would error on trees > 10 unless `SET SESSION max_recursion_depth` is raised first; recursive STRUCTURE itself correct)

---

## Meta-note

iter678 confirms three of four answers (Q1/Q2/Q3) perfect 5/5/5/5 on the canonical anti-join / null-trap / fan-out trio — the resources hold cleanly on every angle probed. Q4 is the lone deviation: the WITH-RECURSIVE structure is correct but a specific factual claim about a session-property default value drifted by 100x from what the resources state verbatim. Because the resources r27:33 and r27:3593 BOTH cite the correct default (10) with the docs quote, this is a **responder transcription failure, not a resource gap**, so the correct iter679 response is DEFAULT NO-OP (do not chase a FIX-A for content that is already correct and findable; chasing it would risk over-tuning the resource and adding churn for a Haiku-side hallucination that may not repeat).

Trajectory iter656→678 (4.625 → 4.375 → 5.00 → 4.875 → 4.21875 → 4.875 → 5.000 → 5.000 → 4.5625 → 5.000 → 3.656 → 4.5625 → 4.5625 → 4.375 → 4.125 → 4.9375 → 5.000 → 4.9375 → 5.000 → 4.500 → 4.875 → 4.78 → 4.5625) shows sustained 4.5+ across nine of last ten iterations with iter678 sitting at the +1.06 margin — still well above floor despite one weak answer in the spread.

**OVERALL: 4.5625 PASS — three perfect 5.00 (LEFT-JOIN + COALESCE-SUM / NOT EXISTS NULL-safe / fan-out diagnosis-and-fix) + one weak Q4 (WITH-RECURSIVE structure correct but max_recursion_depth default claim wrong: responder said 1000, real default is 10 per trino.io/docs/467, would cause runtime error on trees deeper than 10 since the user's depth<20 guard exceeds the engine cap); resources r27:33 + r27:3593 cite default=10 correctly with docs quote, so this is responder-transcription drift NOT a resource defect; iter679 recommended DEFAULT NO-OP / durability-breadth continuation; consider federation re-probe (34-iter ZERO streak, thinnest rubric margin).**
