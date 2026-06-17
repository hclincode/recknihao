# Judge Feedback — iter1007

**OVERALL: 4.0781 (65.25/16) — PASS** (margin +0.5781; OVERALL AVERAGE governs, no per-Q veto)

Verified BOTH directions against trino.io/docs/467 (sql/select.html, functions/window.html, functions/comparison.html) + GitHub issues (trinodb/trino #7553, sqlglot #1754) — NOT resources/. Prod stack (Trino 467 Iceberg + Hive Metastore on-prem MinIO + Spark + dbt) — all 4 questions fit; no federation/auth angle. Federation r22 §13.x hard-locked, NOT probed (stays 4.49944/310).

---

## Per-question scores

| Q | Topic | Acc | Comp | Clar | App | Subtotal |
|---|---|---|---|---|---|---|
| Q1 | pagination (page 4 @ 25/pg) | 1.5 | 2.5 | 2.5 | 1.5 | 8.00 |
| Q2 | self-join employee+manager | 5.0 | 4.75 | 4.75 | 4.75 | 19.25 |
| Q3 | BETWEEN inclusive endpoints | 5.0 | 4.5 | 4.75 | 4.5 | 18.75 |
| Q4 | NTILE(4) spend quartiles | 5.0 | 4.75 | 4.75 | 4.75 | 19.25 |

**Total = 65.25 / 16 = 4.0781 → PASS**

---

## Q1 — pagination — ★ DOUBLE DEFECT (2.0 avg) — ★ SECOND CONSECUTIVE ITERATION

Two independent false claims, plus the headline answer is backwards relative to the question ("different from Postgres?").

### Defect 1 — LIMIT-before-OFFSET is a PARSE ERROR (clause order)
Responder wrote: `SELECT * FROM orders ORDER BY created_at DESC LIMIT 25 OFFSET 75;` and asserted "Trino uses the EXACT SAME syntax as Postgres for pagination."

**VERDICT: WRONG — this is a Trino 467 PARSE ERROR.** The Trino 467 SELECT synopsis fixes the clause order as:
```
[ ORDER BY ... ]
[ OFFSET count [ ROW | ROWS ] ]
[ LIMIT { count | ALL } ]
[ FETCH { FIRST | NEXT } [ count ] { ROW | ROWS } { ONLY | WITH TIES } ]
```
OFFSET MUST precede LIMIT. The documented example is `ORDER BY x OFFSET 2 LIMIT 2`. `LIMIT n OFFSET m` (Postgres/MySQL order) throws `mismatched input 'OFFSET'` (trinodb/trino #7553 — offset-after-limit not supported; sqlglot #1754 — "Trino throws error if offset comes after limit").

**CORRECT FORM: `SELECT * FROM orders ORDER BY created_at DESC OFFSET 75 LIMIT 25;`**

Compounding: the question explicitly asks whether pagination is "different from Postgres." The clause ORDER is a genuine PG→Trino difference, and the responder asserted the reverse — "EXACT SAME syntax as Postgres" — which is exactly backwards and would actively mislead the engineer into shipping a query that fails to parse.

### Defect 2 — FETCH FIRST/NEXT IS supported (second false claim)
Responder gotcha: "if your library tries `LIMIT 25 FETCH NEXT`, that's Oracle/SQL Server syntax and Trino doesn't support it."

**VERDICT: WRONG — Trino 467 DOES support `FETCH { FIRST | NEXT } [count] { ROW | ROWS } { ONLY | WITH TIES }`** (it is listed directly in the SELECT synopsis, immediately after LIMIT). The "Trino doesn't support it" claim is false. (The garbled `LIMIT 25 FETCH NEXT` token combo the responder invented is indeed invalid, but the standalone FETCH FIRST/NEXT clause is fully supported — so the blanket "Trino doesn't support it" is incorrect.)

The only correct part of Q1 is the ORDER-BY-before-pagination determinism point. Both the canonical query and the FETCH claim are wrong → Acc 1.5 / Comp 2.5 / Clar 2.5 / App 1.5.

### ★ RECURRENCE ALERT — 2-in-2
This is the **SECOND consecutive iteration** the responder produced LIMIT-before-OFFSET (iter1006 Q4 was the FIRST). Per state.json, the teacher landed a FIX-A at r27 §pagination L1912 in iter1006 (canonical `OFFSET 50 LIMIT 50` + warning that LIMIT-before-OFFSET is a parse error). **The responder still produced the wrong order in iter1007**, plus a NEW false FETCH-support claim. This crosses the 2-in-2-same-direction threshold flagged in iter1006's re-probe plan.

**Recommended FIX-A (orchestrator, PHASE 6):**
- Verify whether the iter1006 r27 L1912 pagination canonical is FINDABLE from generic pagination keywords (page/skip/offset/LIMIT) — the responder did not pull it, so it is either not keyword-magnetic enough or sits only in the Oracle-migration resource (r27) where pagination keywords may not route. Consider a copy-attractive canonical in the general analytical/SQL-best-practices resource (r07/r23) too.
- Make the copy-attractive block: `ORDER BY created_at DESC OFFSET 75 LIMIT 25` with inline un-copyable defang `-- WRONG: LIMIT 25 OFFSET 75 → parse error 'mismatched input OFFSET' in Trino 467; OFFSET must precede LIMIT (≠ Postgres/MySQL order)`.
- ADD a FETCH FIRST/NEXT note: `FETCH FIRST/NEXT n ROWS ONLY IS supported in Trino 467 (after LIMIT in clause order)` — to kill the new "Trino doesn't support FETCH" folklore before it recurs.
- Per memory [New Card Over-Attracts Adjacent]: pair with the existing OFFSET cost-model content; do not let a new pagination card steal the keyset/seek-pagination Q.

---

## Q2 — self-join (employee + manager) — CLEAN (4.75)
`SELECT e.employee_id, e.name AS employee_name, m.name AS manager_name FROM employees e LEFT JOIN employees m ON e.manager_id = m.employee_id` — **VERIFIED CORRECT.** Self-join with two aliases of one physical table is correct; LEFT JOIN correctly preserves managerless (top-level) employees with NULL manager_name; INNER JOIN to drop them is the right contrast. "Two aliases = two logical references to the same physical table" is an accurate, beginner-friendly explanation. Acc 5.0 / Comp 4.75 / Clar 4.75 / App 4.75.

## Q3 — BETWEEN endpoints — CLEAN (4.6875)
`amount BETWEEN 10 AND 100` ⇔ `amount >= 10 AND amount <= 100`, **both endpoints inclusive — VERIFIED CORRECT** (comparison.html: BETWEEN equivalent to `>= min AND <= max`). The exclusive rewrite (`amount >= 10 AND amount < 100`) is correct and useful. Acc 5.0 / Comp 4.5 / Clar 4.75 / App 4.5.

## Q4 — NTILE(4) quartiles — CLEAN (4.8125)
`NTILE(4) OVER (ORDER BY total_spend DESC)` for 4 equal tiers — **VERIFIED CORRECT.** window.html: rows divided into n buckets numbered 1..n, bucket sizes differ by at most 1; remainder distributed one per bucket **starting with the first bucket** (doc example 6 rows/4 buckets → 1 1 2 2 3 4). Responder's "EARLIEST buckets get the extra rows; 101 users → bucket1=26, bucket4=25" is exactly right. With DESC ordering, bucket 1 = top spenders — correct. CTE structure and final ORDER BY are clean. Acc 5.0 / Comp 4.75 / Clar 4.75 / App 4.75.

---

## TICS summary
- `::` cast shorthand: ABSENT all 4 (ban double-locked r23 §3.1C + r27 §4.4A; not exercised; iter1003 one-off not recurred).
- No QUALIFY / false-semi-join / MAX-varchar / GREATEST-LEAST-NULL / date-minus-integer / INTERVAL-quarter-week / regex-backslash / broken-secondary-alternative this sweep.
- ★ Active TIC = **OFFSET/LIMIT clause-order inversion** (Postgres-prior import → Trino parse error) — Q1 only, now SECOND consecutive occurrence (iter1006 Q4 → iter1007 Q1). Imported-prior family. NOW escalated from one-off to 2-in-2 → FIX-A warranted.
- ★ NEW TIC = **"Trino doesn't support FETCH FIRST/NEXT"** folklore — Q1, first occurrence; fold a corrective note into the same pagination FIX-A.

## Recommendation
**LIGHT FIX-A on pagination** (orchestrator PHASE 6): the LIMIT-before-OFFSET error has now recurred 2-in-2 despite the iter1006 r27 L1912 fix, indicating a FINDABILITY gap (responder isn't routing to the r27 pagination card) — add/verify a keyword-magnetic OFFSET-before-LIMIT canonical reachable from generic pagination keywords (likely r07/r23, not just r27), plus a FETCH-FIRST-IS-supported note. Do NOT churn the correct keyset/cost-model content. Re-probe pagination again next sweep to confirm the responder picks `OFFSET m LIMIT n` and drops the FETCH folklore. Q2/Q3/Q4 clean — no action. MUST NOT bump state.json (already 1007; orchestrator commits).
