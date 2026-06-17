# Judge Feedback — iter1019

**OVERALL: 4.65625 / 5 (74.5 / 16) — PASS** (threshold 3.5; margin +1.15625; OVERALL AVERAGE governs, NO per-question veto)

Verified BOTH directions against trino.io/docs/467 (sql/select.html, functions/math.html) + WebSearch — NOT resources/. Production stack (hundreds-of-millions-row `page_views` on Trino 467 + Iceberg + MinIO) fits all 4 answers; no federation/auth angle this iter.

---

## Per-question scores

| Q | Topic | Acc | Comp | Clar | App | Avg |
|---|---|---|---|---|---|---|
| Q1 | NULLS LAST on DESC sort | 5 | 4.75 | 4.75 | 4.75 | **4.8125** |
| Q2 | sign() vs CASE for +/-/0 flag | 5 | 4.5 | 4.75 | 4.75 | **4.75** |
| Q3 | running count reset per calendar year | 5 | 4.75 | 4.5 | 4.75 | **4.71875** |
| Q4 | TABLESAMPLE ~1% no full scan | 3.5 | 4.0 | 3.875 | 4.0 | **3.84375** |

Sum 74.5 / 16 = **4.65625 → PASS**

---

## The 5 resolved verdicts (with citations)

1. **Q4 TABLESAMPLE clause order (PRIORITY) — SECOND example is INVALID.**
   VERIFIED: TABLESAMPLE attaches to the table reference in the FROM clause (`sampledRelation` grammar: `aliasedRelation [ TABLESAMPLE method (percentage) ]`). It CANNOT follow the WHERE clause. The responder's first example `FROM page_views TABLESAMPLE SYSTEM (1) LIMIT 1000` is correct; the SECOND example `FROM page_views WHERE page_view_date = CURRENT_DATE TABLESAMPLE SYSTEM (1) LIMIT 1000` is a **clause-order PARSE ERROR**. Correct form: `FROM page_views TABLESAMPLE SYSTEM (1) WHERE page_view_date = CURRENT_DATE LIMIT 1000`. (Source: trino.io/docs/467/sql/select.html — sampledRelation grammar; corroborated by WebSearch on TABLESAMPLE FROM-clause placement / SampledRelation AST node.)

2. **Q4 SYSTEM vs BERNOULLI — CORRECT.** SYSTEM divides the table into logical segments and selects/skips whole segments (data-skipping, faster, but clustered/biased; result depends on connector storage layout). BERNOULLI selects each row independently with the given probability but scans all physical blocks (no I/O savings). Responder's characterization matches docs exactly. (Source: trino.io/docs/467/sql/select.html.)

3. **Q1 NULL ordering — CORRECT.** Trino default IS `NULLS LAST` regardless of ASC/DESC. `ORDER BY renewed_at DESC NULLS LAST` is correct and the responder correctly contrasts Oracle/Postgres (DESC → NULLS FIRST). (Source: select.html "The default null ordering is NULLS LAST, regardless of the ordering direction.")

4. **Q2 sign() — EXISTS and CORRECT.** `sign(x)` returns -1 / 0 / 1 for negative / zero / positive. Both `CASE WHEN sign(revenue)=1 ...` and plain `CASE WHEN revenue>0 ...` are valid and equivalent. (Source: trino.io/docs/467/functions/math.html — signum.)

5. **Q3 year-reset running count — CORRECT approach.** `PARTITION BY user_id, EXTRACT(YEAR FROM session_start)` resets ROW_NUMBER()/running SUM(1) per calendar year. The prose "window functions alone cannot restart mid-query" is awkward/slightly misleading, but the SQL the responder then provides IS the canonical partition-by-derived-key reset pattern. Verified against window-function frame semantics.

---

## Defects / notes

- **Q4 (the only real defect): broken-secondary example.** Primary example + SYSTEM/BERNOULLI explanation + the "avoid WHERE rand()<0.01 (reads every row)" warning are all CORRECT and well-targeted to the hundreds-of-millions-row scale. The defect is the appended SECOND example placing `TABLESAMPLE` AFTER the WHERE clause — a clause-order parse error. **Classification: broken-secondary-example one-off, NOT a findable resource gap** (broken-secondary family: iter936/943/948/950/954/1013). There is no single resource fix for responder padding-with-an-invalid-variant; correct form must immediately follow the table reference, before WHERE.
- Q3 minor: the "cannot restart mid-query" framing costs a light Clarity point but does not change correctness — the delivered SQL is right.
- Q2 minor: no float-edge note (NaN→NaN, -0.0), immaterial for revenue.
- `::` shorthand absent in all 4. No QUALIFY / no false semi-join / no fabricated functions / no regex-backslash / no INTERVAL-quarter-week / no OFFSET-before-LIMIT.

---

## Recommendation

**DEFAULT NO-OP.** Margin +1.156; 3/4 answers clean including the KEY Q4 primary + SYSTEM/BERNOULLI characterization. The lone Q4 defect is a first-occurrence broken-secondary clause-order slip — a per-instance responder-padding one-off, not a source-verified findable gap and not 2-in-2 recurrence. NO resource edit, NO FIX-A, NO git commit.

**Re-probe (monitor only):**
- (a) TABLESAMPLE clause-order — watch for `WHERE ... TABLESAMPLE` relapse; if it recurs 2-in-2, apply a LIGHT findability nudge (TABLESAMPLE binds to the FROM table reference, before WHERE).
- (b) NULLS LAST default on DESC.
- (c) sign() -1/0/1.
- (d) partition-by-derived-key window reset.

Federation r22 §13.x hard-locked, NOT probed (stays 4.49944 / 310). state.json already at 1019 — orchestrator commits; do not bump.
