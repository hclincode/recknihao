# Iter668 Judge Feedback

**Iteration**: 668
**Phase**: extended (durability-breadth)
**Questions evaluated**: 4
**Dialect verification**: WebFetch against trino.io/docs/467 (iceberg connector, datetime functions, window functions, select syntax)

---

## Per-question scoring (Accuracy / Completeness / Clarity / Actionability, 1–5)

### Q1 — CTAS with month-partitioning from orders

**Answer recap**: `CREATE TABLE iceberg.analytics.monthly_orders WITH (partitioning = ARRAY['month(order_date)']) AS SELECT order_date, customer_id, amount FROM iceberg.analytics.orders WHERE order_date >= DATE '2026-01-01';` plus prose noting WITH placement and that without WITH the table is unpartitioned.

**Dialect verification (trino.io/docs/467/connector/iceberg.html)**: Docs verbatim show `partitioning = ARRAY['month(order_date)']` as the canonical form; `month(ts)` is a documented partition transform; WITH-properties on CTAS is supported. Property name `partitioning` confirmed (NOT `partitioned_by` which is Hive-connector dialect). All clean.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5 | Exact docs form. `partitioning` property correct, `month()` transform correct, WITH-clause-then-AS placement correct. |
| Completeness | 4 | Has the canonical statement + the "without WITH → unpartitioned" callout. Could have noted that the partition column doesn't need to appear bare in the SELECT (it already does via `order_date`), but not material. |
| Clarity | 4 | Statement is self-explanatory; prose names the three things CTAS does (creates, partitions, populates) in one breath. |
| Actionability | 5 | Engineer can paste-and-go; only adjustment is column list / date filter. |
| **Avg** | **4.50** | |

### Q2 — Schema evolution: add nullable VARCHAR `loyalty_tier`, what do old rows return

**Answer recap**: `ALTER TABLE iceberg.analytics.orders ADD COLUMN loyalty_tier VARCHAR;` — metadata-only, near-instant, schema-only, old rows NULL at read time, no rewrite/downtime.

**Dialect verification**: Trino 467 Iceberg connector docs confirm `ADD COLUMN` is part of safe schema evolution (add/drop/reorder/rename). NULL-for-old-rows is the documented Iceberg behavior for nullable adds (Iceberg spec — fields not present in older data files read as NULL because the read uses the current schema mapped onto old files by field-id, and absent field-ids resolve to NULL). Syntax `ADD COLUMN <name> <type>` correct; `VARCHAR` is a valid Trino type. All clean.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5 | Syntax correct, metadata-only claim correct, NULL-for-old-rows correct. |
| Completeness | 4 | Hits all four facets the question asks for (syntax, no rewrite, near-instant, old-rows NULL). Could have noted: this is safe BECAUSE the column is nullable — adding NOT NULL would either need a default or be rejected. Minor gap, not penalty-worthy. |
| Clarity | 5 | One sentence per concept, no jargon assumed. |
| Actionability | 5 | Engineer runs the DDL and ships. |
| **Avg** | **4.75** | |

### Q3 — First-order cohort-month + customer count

**Answer recap**: CTE `customer_first_order` computes per-customer `date_trunc('month', MIN(order_date))`; outer GROUP BY `first_order_month` + COUNT(*).

**Dialect verification (trino.io/docs/467/functions/datetime.html)**: `date_trunc('month', timestamp_or_date)` returns first-of-month — confirmed by docs example. `MIN(order_date) GROUP BY customer_id` is plain aggregation. `date_trunc('month', MIN(order_date))` is a valid expression — `MIN()` is the aggregate, `date_trunc` wraps the aggregate result, no nested-aggregate issue. Outer GROUP BY on the CTE column is standard. All clean.

**Flag** (prose-only, per directive): The responder's prose loosely called the outer GROUP BY a "nested aggregation" — but the SQL is a correct two-level CTE pattern, NOT an actual nested aggregate like `AVG(COUNT(...))`. The SQL is correct; only the label is loose. Per directive, I assess the SQL, not the label — no score deduction, just a teacher-side coaching note (see below).

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5 | SQL is correct Trino 467. CTE structure is the canonical cohort-month pattern. |
| Completeness | 4 | Has both required pieces (cohort assignment + customer count). ORDER BY first_order_month is included. Could have noted that this counts cohort *size* only and that adding retention bands would require a second join — but that's beyond what was asked. |
| Clarity | 3 | The loose "nested aggregation" label could confuse a beginner who then googles the wrong term. SQL itself is clear. |
| Actionability | 5 | Engineer pastes and gets the cohort table. |
| **Avg** | **4.25** | |

### Q4 — Consecutive-days login streak >= 3 (gaps-and-islands)

**Answer recap**: Three-CTE gaps-and-islands:
1. `daily_logins` — DISTINCT user_id, login_date (with cosmetic ORDER BY)
2. `login_with_gap` — `date_diff('day', LAG(login_date) OVER (PARTITION BY user_id ORDER BY login_date), login_date)`
3. `runs` — `SUM(CASE WHEN days_since_last_login = 1 OR days_since_last_login IS NULL THEN 0 ELSE 1 END) OVER (PARTITION BY user_id ORDER BY login_date)` as `run_id`
Final: `SELECT DISTINCT user_id FROM runs GROUP BY user_id, run_id HAVING COUNT(*) >= 3`.

**Dialect verification**:
- `LAG(col) OVER (PARTITION BY ... ORDER BY ...)` — Trino 467 window function docs: confirmed, returns NULL for rows outside the partition (first row → NULL).
- `date_diff('day', from, to)` — Trino 467 datetime docs: confirmed, signature is `date_diff(unit, ts1, ts2)` returning `ts2 - ts1` in unit. Order matches the answer (`LAG` first = older, `login_date` second = newer → positive day gap for consecutive days).
- First-row behavior: `LAG(login_date) → NULL`, so `date_diff('day', NULL, login_date) → NULL`. The CASE explicitly maps NULL to 0 (no increment), so the first day of each user's history starts at `run_id = 0`. Correct.
- Island logic: `days_since_last_login = 1` (consecutive) maps to 0 (no increment) → same `run_id`. Any gap > 1 maps to 1 → `run_id` increments → new island. Correct.
- `SUM(CASE ...) OVER (PARTITION BY user_id ORDER BY login_date)` — Trino 467 window docs confirm running-sum pattern. Default frame `RANGE UNBOUNDED PRECEDING` is fine because the CASE expression is deterministic per row and the `login_date` ordering is unique-per-user post-DISTINCT. No peer-row lumping issue. Correct.
- `SELECT DISTINCT user_id FROM runs GROUP BY user_id, run_id HAVING COUNT(*) >= 3` — valid Trino 467. GROUP BY collapses to one row per (user, island); HAVING filters islands of length >= 3; SELECT DISTINCT dedupes users who have multiple qualifying streaks. `user_id` is in the GROUP BY clause so it is a legal SELECT target. (Note: a WebFetch summarizer claimed this combo is "not valid" — that's a misread; SELECT DISTINCT combined with GROUP BY is standard ANSI SQL and works on Trino. The DISTINCT here is semantically meaningful, not redundant, because rows are grouped by (user_id, run_id) but selected as user_id only.)
- Cosmetic ORDER BY inside `daily_logins` CTE — allowed-but-ignored in Trino; not material. Window functions in subsequent CTEs do their own ORDER BY.

All clean. The whole pattern produces the correct answer.

| Dim | Score | Reason |
|---|---|---|
| Accuracy | 5 | Every operator, every CASE branch, every window frame, every final aggregation — correct on Trino 467. The NULL-first-row handling via OR-IS-NULL in the CASE is the right defensive pattern. |
| Completeness | 5 | All four CTE roles explained in prose (dedupe → gap → island-id → length filter). Final SELECT DISTINCT explained as the multi-streak dedupe. |
| Clarity | 4 | Gaps-and-islands is intrinsically dense; the per-CTE prose helps. A beginner would still want a tiny worked-example table walk-through, but the prose names every piece. |
| Actionability | 5 | Drop-in for `logins(user_id, login_date)`; engineer changes `>= 3` to tune the streak length. |
| **Avg** | **4.75** | |

---

## Overall

| Q | Avg |
|---|---|
| Q1 CTAS-partitioning | 4.50 |
| Q2 schema-evolution add-nullable | 4.75 |
| Q3 cohort-month + count | 4.25 |
| Q4 consecutive-days streak | 4.75 |
| **Overall** | **4.5625** |

**Verdict**: **PASS** (4.5625 >> 3.5 threshold).

All four SQL bodies are valid Trino 467 dialect, the schema-evolution claim is consistent with Iceberg spec and Trino 467 connector docs, and the gaps-and-islands answer is correct in every detail (LAG/NULL handling, CASE branch logic, running-sum island-id, GROUP BY + SELECT DISTINCT final). No verified-false claim in any of the four responses.

---

## Flagged (prose-only, no score deduction)

- **Q3 loose label**: "nested aggregation" was used to describe the two-level CTE+outer-GROUP-BY pattern, but a true nested aggregate (`AVG(COUNT(...))`) is something Trino actually rejects. Per directive, the SQL is what's scored — and the SQL is correct — but a teacher-side coaching tweak would help a beginner who googles the loose term.
- **Q4 cosmetic ORDER BY**: The `ORDER BY user_id, login_date` inside `daily_logins` is parsed-but-ignored by Trino (CTEs aren't ordered; only the outermost SELECT is). Not wrong, just inert. Not penalty-worthy.

---

## Teacher feedback (concise + actionable)

**No edits required this iter.** All four answers cleared the threshold with margin, dialect verification against trino.io/docs/467 confirmed every claim, and the iter668 r27:4122 rollback fix from this iter's grep-verify pass is consistent with the answers above (none of which touch rollback).

**Minor coaching opportunities** (optional, NOT required for pass):
1. **Cohort-pattern label hygiene (Q3-class)**: in the cohort-month resource, add a one-line callout: *"This is a two-level CTE pattern (per-customer aggregate, then per-month count). It is NOT a nested aggregate — Trino rejects `AVG(COUNT(...))`; you must use a CTE or subquery to stage the inner aggregate."* That removes the "nested aggregation" mis-labelling risk for future responder runs.
2. **Cosmetic ORDER BY in CTE (Q4-class)**: in the gaps-and-islands resource, a one-line tip — *"ORDER BY inside a CTE is parsed-but-ignored in Trino; put ORDER BY only on the final SELECT, or on the OVER() of the window function where it actually drives the computation."* Low-priority; cosmetic ORDER BY doesn't break anything.

**Recommendation for iter669**: **DEFAULT NO-OP / durability-breadth**. Continue the grep-verify pattern over fresh adjacent areas (suggested: UPDATE / DELETE on Iceberg, MERGE syntax, REPLACE TABLE vs CREATE OR REPLACE, transactional semantics on Trino 467). Leave all current locks (federation, day_of_week-name, Spark-CALL→Trino-ALTER-TABLE-EXECUTE engine-dialect fix, DataSize-unit-suffix, ROWS-vs-RANGE, percent-of-grand-total, r27:4122 rollback CALL form) untouched. No commit/push pressure; the four-answer pass is comfortable.
