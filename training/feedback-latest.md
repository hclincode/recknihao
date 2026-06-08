# Judge Feedback — iter694

**Phase**: extended | **Iteration**: 694 | **Verdict**: PASS (overall avg 3.75 >= 3.5) — two answers flagged as critically weak

The overall average crosses the 3.5 pass threshold thanks to two strong answers (Q3/Q4 at 5.00) but **both Q1 and Q2 surfaced executable correctness problems** that would ship broken SQL to production. Per the run directive the OVERALL AVERAGE governs PASS/FAIL with no per-Q quality-gate override — so this iteration is labeled PASS, but the weak answers are flagged in prose below for iter695 follow-up.

---

## Per-question scores

| Q | Accuracy | Completeness | Clarity | Actionability | Avg |
|---|---|---|---|---|---|
| Q1 cumulative-distinct (FIX-A re-probe) | 2 | 3 | 3 | 2 | 2.50 |
| Q2 first-and-last per group | 1 | 3 | 4 | 2 | 2.50 |
| Q3 Iceberg time-travel | 5 | 5 | 5 | 5 | 5.00 |
| Q4 hour-of-day distribution | 5 | 5 | 5 | 5 | 5.00 |

Per-dimension averages: Accuracy 3.25 | Completeness 4.00 | Clarity 4.25 | Actionability 3.50
**Overall grand avg = (3.25 + 4.00 + 4.25 + 3.50) / 4 = 3.75** → PASS by threshold.

---

## Q1 — Cumulative-distinct products by month (FIX-A RE-PROBE) — 2.50

**Responder's SQL** (paraphrased):
```sql
WITH first_order AS (
  SELECT product_id, DATE_TRUNC('month', created_at) AS first_month
  FROM order_items
  GROUP BY product_id, DATE_TRUNC('month', created_at)   -- ← BUG
),
new_per_month AS (
  SELECT first_month AS order_month, COUNT(*) AS new_products
  FROM first_order GROUP BY first_month
)
SELECT order_month, new_products,
       SUM(new_products) OVER (ORDER BY order_month
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
            AS cumulative_distinct_products
FROM new_per_month ORDER BY order_month;
```

### Explicit verdict — defang vs correctness

- **COUNT(DISTINCT) OVER regression: CLOSED.** The iter694 defang of Pattern A4's DO-NOT-WRITE cells worked: the responder did NOT copy the banned `COUNT(DISTINCT product_id) OVER (...)` snippet this iteration. It correctly reached for the running-SUM-of-first-appearances outer shape. The inline `-- ❌ WRONG ... DO NOT COPY` self-documenting markers on banned cells did their job.
- **Cumulative-distinct correctness: REGRESSED-AGAIN via a NEW failure mode.** The `first_order` CTE keys on BOTH `product_id` AND `DATE_TRUNC('month', created_at)` — yielding one row per (product, EVERY active month), not one row per product at its first month. The alias `first_month` is a misnomer. A product ordered in Jan AND Feb produces 2 rows; `new_per_month` then counts that product twice; the running `SUM(...) OVER` double-counts every multi-month product. Output = "cumulative active-period instances," NOT "cumulative distinct products."

The responder's own prose said "the key is MIN(created_at) GROUP BY product_id — each product appears exactly once at its first-order month" — **but the SQL contradicts the prose**: there is no MIN() and the GROUP BY adds the month key.

**Correct first_order CTE:**
```sql
SELECT product_id, DATE_TRUNC('month', MIN(created_at)) AS first_month
FROM order_items
GROUP BY product_id        -- GROUP BY product_id ONLY
```

Net for iter694 on Pattern A4: same bug class as iter692 Q4 (double-counts multi-period entities), reached via a mangled GROUP BY instead of via COUNT(DISTINCT) OVER. The iter694 defang closed the COUNT(DISTINCT) OVER path but the cumulative-distinct correctness still FAILS. **PARTIAL close + new failure mode.**

## Q2 — First-and-last per group — 2.50

**Responder's SQL** used `QUALIFY ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date) = 1` as a dedup wrapper.

**Verdict — QUALIFY is NOT supported in Trino 467 (parse error).** Verified against trino.io: QUALIFY is a Snowflake / BigQuery / DuckDB clause; Trino has not added it (Starburst community thread requesting QUALIFY remains open; Trino 467 release notes added DISTINCT in windowed aggregates and windowed LISTAGG but no QUALIFY). The query fails at parse stage before execution.

The `first_value(amount) OVER (PARTITION BY customer_id ORDER BY order_date ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING)` and matching `last_value` expressions with the full frame are correct, but the QUALIFY dedup kills the whole query.

**Correct Trino 467 forms** (either or both):

A) `min_by` / `max_by` — single GROUP BY, no window, no dedup wrapper:
```sql
SELECT customer_id,
       min_by(amount, order_date) AS first_order_amount,
       max_by(amount, order_date) AS last_order_amount
FROM orders
GROUP BY customer_id
ORDER BY customer_id;
```

B) Subquery / CTE then `WHERE rn = 1`:
```sql
SELECT customer_id, first_order_amount, last_order_amount
FROM (
  SELECT customer_id,
         first_value(amount) OVER (PARTITION BY customer_id ORDER BY order_date
              ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS first_order_amount,
         last_value(amount)  OVER (PARTITION BY customer_id ORDER BY order_date
              ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) AS last_order_amount,
         ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date) AS rn
  FROM orders
)
WHERE rn = 1
ORDER BY customer_id;
```

## Q3 — Iceberg time-travel — 5.00

`FOR TIMESTAMP AS OF TIMESTAMP '2026-06-07 00:00:00 UTC'` plus mentions of `FOR VERSION AS OF <snapshot_id>` and the `"orders$snapshots"` metadata table to look up snapshot IDs. All verified valid Trino 467 Iceberg connector syntax. Production-fit (on-prem Trino 467 + Iceberg 1.5.2 + HMS + MinIO).

## Q4 — Hour-of-day distribution — 5.00

`EXTRACT(HOUR FROM order_time)` + `GROUP BY` + `ORDER BY hour_of_day`. Verified valid Trino 467 (both `EXTRACT(HOUR FROM ts)` and `hour(ts)` are supported and return 0-23). Clear, complete, actionable.

---

## Pattern A4 canonical-clarity assessment (for iter695 planning)

The iter694 state.json describes the canonical at r07:2062-2092 as:
- preamble noting both `COUNT(DISTINCT) OVER` and `SUM(COUNT(DISTINCT)) OVER` are BANNED — "the recipe below is the ONLY correct shape"
- ✅ COPY THIS marker as the FIRST line inside the fenced block
- shape: `WITH first_order ... MIN(order_date) ... → COUNT(*) GROUP BY first_month → SUM(new_customers) OVER (ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)`

If that canonical truly shows `DATE_TRUNC('month', MIN(order_date)) AS first_month` with `GROUP BY customer_id` ONLY — emphasized via ✅ COPY THIS — then the responder's mangling (dropping MIN, adding month to GROUP BY) is **responder-composition-weakness**: the Haiku correctly borrowed the OUTER running-SUM shape but synthesized the inner CTE without anchoring to the canonical's GROUP BY structure. This is a known Haiku synthesis-from-template defect (the keyword match likely lands on the outer SUM(...) OVER line and synthesis drifts from the inner CTE).

If r07:2062-2092 visually de-emphasizes the MIN()+GROUP-BY-key-only constraint, a tiny canonical tightening is warranted.

## QUALIFY-banned findability assessment

The responder emitted QUALIFY confidently, indicating either no QUALIFY DO-NOT-WRITE inoculation exists in resources/, or one exists but is not keyword-anchored to "first row per group / dedup to one row per partition / top-N per group" question shapes. Either way QUALIFY surfaced as a real **findable-but-missing gap** worth a small iter695 inoculation.

---

## Recommendations for iter695

**Q1 (cumulative-distinct first_order CTE)** — likely **responder-composition-weakness** if Pattern A4's canonical is already clear (the state.json description suggests it is). The COUNT(DISTINCT) OVER defang closed the iter693 regression cleanly; the inner-CTE mangling is a Haiku synthesis defect, not a resource defect. **DEFAULT: NO-OP on Pattern A4** unless a fresh inspection of r07:2062-2092 shows MIN()+GROUP-BY-key-only is not visually prominent. If a small tightening is warranted, add a one-line WHY directly above the `MIN(created_at)`/`GROUP BY product_id` line in the canonical:
```
-- ⚠️ GROUP BY entity_id ONLY (no time-grain key). MIN(created_at) collapses
-- each entity to its first-appearance period. Adding the month to GROUP BY
-- ⇒ one row per active period ⇒ running-SUM double-counts multi-period entities.
```

**Q2 (QUALIFY-banned)** — this is a **findable-but-missing gap**. Recommend folding a tiny QUALIFY inoculation into iter695:
- Add a 4-6 line entry in r07 (analytical query patterns) and r23/r25 (SQL best practices) under keyword anchors: `QUALIFY`, `QUALIFY ROW_NUMBER`, `first row per group dedup`, `top-N per group`, `latest row per customer`.
- Content: "Trino 467 has NO QUALIFY clause — parse error. QUALIFY is Snowflake / BigQuery / DuckDB only. Trino dedup pattern: wrap window in subquery/CTE then `WHERE rn = 1`. For first/last-value per group prefer `min_by(value, ts)` / `max_by(value, ts)` GROUP BY key (no window needed)."
- Use the same self-documenting inline-comment marker style on any QUALIFY example: `QUALIFY rn = 1   -- ❌ WRONG: Trino 467 has NO QUALIFY (parse error) — DO NOT COPY` so keyword-matching copy yields a broken/commented line.

**Single highest-value iter695 edit**: the QUALIFY inoculation. The Q1 inner-CTE mangling is a known Haiku composition limit on an already-clear canonical and further markup likely hits diminishing returns.

---

## Score-history line (append to rubric.md)

`| 694 | 3.75 PASS | Q1 cumulative-distinct double-counts via mangled GROUP BY (dropped MIN, added month-key) — COUNT(DISTINCT) OVER defang CLOSED but correctness REGRESSED-via-new-mechanism; Q2 QUALIFY parse-fails in Trino 467 (Snowflake/BigQuery clause, not Trino); Q3 FOR TIMESTAMP AS OF valid; Q4 EXTRACT(HOUR FROM ts) valid |`
