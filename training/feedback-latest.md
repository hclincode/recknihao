# Judge Feedback — iter927 (NO-OP durability sweep: 4 fresh adjacents — GROUP BY COUNT / two-level ROW_NUMBER / CASE-comparison / conditional-AVG before-after)

**Overall: 4.594 PASS** (Q1 5.00 / Q2 5.00 / Q3 5.00 / Q4 3.375 = 18.375/4 = 4.594). OVERALL AVERAGE governs — no per-Q veto. Threshold 3.5 met by +1.094.

Trino 467 PINNED. All dialect claims verified vs trino.io/docs/467 (functions/comparison.html, language/types.html) + WebSearch (AWS re:Post `Cannot apply operator: date < varchar(10)`, Dataminded "7 lessons migrating dbt Snowflake→Trino", Trino issue #7334) 2026-06-10 — NOT against resources/. iter882 verify-first applied BOTH directions.

---

## ★ Q4 VERDICT — BARE-STRING DATE LITERAL = CONFIRMED DIALECT DEFECT (structure correct, literal wrong)

**VERIFIED VERDICT: Trino 467 does NOT implicitly coerce a bare VARCHAR string literal to DATE when compared to a DATE column.** Comparing `review_date` (DATE) `< '2026-05-15'` (bare varchar) raises `TYPE_MISMATCH: Cannot apply operator: date < varchar(10)`. The query as written WILL NOT RUN.

Evidence (multi-source, 2026-06-10):
- trino.io/docs/467 functions/comparison.html: comparison operators require operands of the same/coercible orderable type; BETWEEN operands "must be the same type"; NO varchar→date implicit coercion documented.
- AWS re:Post (Athena/Trino engine): exact error `TYPE_MISMATCH: Cannot apply operator: date < varchar(10)`; fix = `DATE '...'` or `CAST('...' AS DATE)`.
- Dataminded "7 lessons migrating dbt from Snowflake to Trino": "Trino does not do implicit type coercion … instead of `WHERE date_column = '2021-01-01'` you write `WHERE date_column = DATE '2021-01-01'`."
- Trino issue #7334 (timestamp vs varchar) confirms the same strict-typing family.

So the run-prompt's understanding is **CONFIRMED**: bare string requires `DATE '2026-05-15'` (or `CAST('2026-05-15' AS DATE)`). If `review_date` were a TIMESTAMP instead of DATE, the same rule applies — needs `TIMESTAMP '...'` (or `DATE '...'` with the documented date→timestamp coercion). Either way the bare string fails.

**What the responder got RIGHT (the hard part):**
- Conditional-aggregation STRUCTURE is fully correct: `AVG(CASE WHEN review_date < <cutoff> THEN star_rating END)` for the before window, `>=` for after, the difference column, `GROUP BY product_id`, and `HAVING <before> IS NOT NULL AND <after> IS NOT NULL`.
- `AVG(CASE WHEN … THEN x END)` correctly SKIPS the NULLs produced when the CASE has no ELSE (rows outside the window contribute NULL, AVG ignores NULLs) — conditional-average semantics are right (pinned).
- HAVING both-not-null correctly drops products that have reviews on only one side of the cutoff.

**The single defect:** the literal `'2026-05-15'` must be `DATE '2026-05-15'`. One token per occurrence (two occurrences). Structure-correct, literal-wrong → proportional down-score, NOT a hard zero.

**Q4 per-dimension:** Accuracy 2.5 (query raises TYPE_MISMATCH, will not execute as written) / Completeness 4.0 (full structure, only the DATE keyword missing) / Clarity 4.0 (clear explanation but ships a non-runnable literal) / Actionability 3.0 (engineer pastes it, hits an error, must self-fix). Q4 = (2.5+4.0+4.0+3.0)/4 = **3.375**.

### SCOPE-CHECK: RESPONDER SYNTHESIS SLIP, NOT a findable resource gap → re-probe-don't-churn

Resources teach the CORRECT form and explicitly warn against this exact bare-string mistake:
- `resources/28-complex-sql-performance-trino-dbt.md:1047`: table row `WHERE event_date >= '2026-05-30'` (string compared to date) → "Type mismatch — Trino does NOT push when types don't match." → fix `Use DATE '2026-05-30' literal.`
- `resources/28-…:1044`: companion row on `CAST(event_date AS varchar) = '...'` → canonical `WHERE event_date = DATE '2026-05-30'`.
- `DATE '20YY-MM-DD'` correct literals appear **189 times across 16 resource files** (r07 ×35, r22 ×32, r23 ×38, r28 ×19, r27 ×23, …) — the canonical, copy-attractive Trino form.

The bare-string `< '20YY-..'` occurrences that exist in resources are in Spark/ingestion watermark prose, Postgres-pushdown JDBC pass-through, or partition-value illustration (r13, r26, r17) — NOT presented as the canonical Trino DATE-column comparison pattern. The responder synthesized the bare-string form despite the dominant `DATE '...'` canon and r28's explicit WRONG-marking. This is a RESPONDER SYNTHESIS SLIP, not a resource gap.

**Action: re-probe-don't-churn. NO teacher edit, NO "wrong" card (duplicates r28's existing WRONG-marked row + risks defang-backfire). Re-probe a before/after date-window question fresh next sweep to confirm the responder reaches for `DATE '...'`; if the bare string recurs, escalate to a findability anchor (the type-safe-predicate canon may not be keyword-reachable from a plain "average rating before vs after <date>" phrasing).** This is the 1st occurrence of the bare-string-date slip in the recent sweep series — treat as one-off pending re-probe.

---

## Q1 — count customers per acquisition source — 5.00

`SELECT acquisition_source, COUNT(*) AS customer_count FROM customers GROUP BY acquisition_source` + NULL-bucket caveat (rows with NULL acquisition_source form their own group, COUNT(*) counts them; COUNT(acquisition_source) would skip NULLs). VERIFIED select.html GROUP BY + aggregate.html COUNT(*); NULL-group behavior correct (pinned). One row per source. Acc/Comp/Clar/Act 5.0.

## Q2 — highest single-day total sales per store — 5.00

Two-level: `WITH daily_sales AS (SELECT store_id, sale_date, SUM(amount) AS daily_total FROM sales GROUP BY store_id, sale_date) SELECT … FROM (SELECT *, ROW_NUMBER() OVER (PARTITION BY store_id ORDER BY daily_total DESC) AS rank FROM daily_sales) WHERE rank = 1` + the simpler `SELECT store_id, MAX(daily_total) FROM daily_sales GROUP BY store_id` form. VERIFIED window.html ROW_NUMBER OVER(PARTITION/ORDER) valid; select.html GROUP BY; no QUALIFY in 467 (correctly used the subquery+WHERE rewrite, not QUALIFY). Both forms answer "highest single-day total per store" — the MAX form returns just the value, the ROW_NUMBER form lets you also surface the sale_date. Tie note (multiple days at the max → ROW_NUMBER picks one) is apt. Acc/Comp/Clar/Act 5.0.

## Q3 — flag accounts over licensed seat limit — 5.00

`CASE WHEN active_seats > licensed_seats THEN 'over_limit' WHEN active_seats = licensed_seats THEN 'at_limit' ELSE 'under_limit' END` + COALESCE NULL-guard note + `WHERE active_seats > licensed_seats` filter-only variant. VERIFIED comparison.html: integer `>`/`=` comparison valid; three-valued-logic note CORRECT (if either column is NULL the comparison is UNKNOWN, the row falls through to ELSE/`under_limit`, so COALESCE(active_seats,0)/COALESCE(licensed_seats,…) is the right guard when NULLs are possible). Acc/Comp/Clar/Act 5.0.

---

## iter928 directive — DEFAULT NO-OP with ONE re-probe flag

- **iter927 = DEFAULT NO-OP on resources.** Q1/Q2/Q3 dialect-clean. Q4 structure correct; the ONLY defect (bare-string date literal) is a RESPONDER SYNTHESIS SLIP on CLEAN resources (r28:1047 explicitly WRONG-marks it; `DATE '...'` canon ×189). Teacher ZERO edits. NO "wrong" card, NO FIX-A this iter (duplicates r28 + defang-backfire risk).
- **DO re-probe** a before/after date-window / date-column comparison question next sweep (e.g. "revenue before vs after a launch date", "tickets opened after <date>") to confirm the responder emits `DATE '...'` not a bare string. If the bare string RECURS (2nd instance), THEN escalate to a findability anchor pulling the type-safe-predicate / `DATE '...'`-literal canon toward plain before/after-date phrasings.
- **Do NOT mark wrong:** Q1 GROUP BY acquisition_source + COUNT(*) + NULL-bucket; Q2 daily-SUM CTE → ROW_NUMBER PARTITION BY store_id top-day OR MAX(daily_total) GROUP BY store_id; Q3 CASE seat-limit comparison + COALESCE/3VL guard; Q4 conditional-AVG before/after STRUCTURE + HAVING both-not-null (all correct). The ONLY thing wrong in Q4 is the missing `DATE` keyword on the literal.
- **PIN (verified this iter):** Trino 467 requires `DATE '2026-05-15'` (or `CAST('2026-05-15' AS DATE)`) to compare against a DATE column — bare varchar literal raises `Cannot apply operator: date < varchar(10)`, NO implicit varchar→date coercion. Same applies to TIMESTAMP columns (`TIMESTAMP '...'`).
- Federation (4.49944/310) remains the only un-passed row — bulletproofed angles only. Do NOT touch any iter534-926 pin. PIN 467. NO federation edits. DO NOT bump training/state.json (already passed; overall 4.594 PASS holds).
